import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/nym_theme.dart';
import 'features/i18n/app_strings_catalog.dart';
import 'features/commands/command_i18n.dart';
import 'features/i18n/i18n.dart';
import 'features/i18n/localization_service.dart';
import 'features/mesh/mesh_controller.dart';
import 'features/notifications/notification_route_target.dart';
import 'features/notifications/notification_routing.dart';
import 'features/onboarding/boot_gate.dart';
import 'features/share/share_intake.dart';
import 'services/notification_service.dart';
import 'services/platform/background_connectivity.dart';
import 'services/platform/background_refresh.dart';
import 'services/platform/deep_link_target.dart';
import 'services/platform/deep_links.dart';
import 'state/app_state.dart';
import 'state/nostr_controller.dart';
import 'state/settings_provider.dart';

/// Root application widget. Resolves the active Nymchat theme from settings +
/// platform brightness and rebuilds the whole app when either changes.
class NymchatApp extends ConsumerStatefulWidget {
  const NymchatApp({super.key});

  @override
  ConsumerState<NymchatApp> createState() => _NymchatAppState();
}

class _NymchatAppState extends ConsumerState<NymchatApp>
    with WidgetsBindingObserver {
  DeepLinkService? _deepLinks;
  StreamSubscription<String>? _payloadSub;
  ShareIntake? _shareIntake;

  /// OS-level keep-alive for the "Stay Connected in Background" setting. Only
  /// runs while the app is actually backgrounded WITH the setting on; it is
  /// released on every resume so a foregrounded app never carries the
  /// notification (Android) or an open background task (iOS).
  final BackgroundConnectivityService _backgroundConnectivity =
      BackgroundConnectivityService();

  /// iOS-only catch-up: with no push provider, a `BGAppRefresh` window is the
  /// only chance a suspended app gets to notice what arrived and notify about
  /// it. No-op on Android, where the foreground service keeps the socket open
  /// and events arrive live.
  final BackgroundRefreshService _backgroundRefresh = BackgroundRefreshService();

  /// Lets sign-out clear any dialogs/modals pushed above the boot gate. The
  /// remount (keyed [BootGate]) replaces the gate's content, but pushed routes
  /// live on the navigator above `home` and must be popped explicitly.
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initLocalization();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncBrightness());
    // Platform integration is wired from the root widget so it runs without
    // editing main.dart (which another agent owns). Deferred past the first
    // frame so the controller + providers are ready before any link dispatches.
    WidgetsBinding.instance.addPostFrameCallback((_) => _initPlatform());
  }

  /// Boots deep links, notifications and the share sheet.
  ///
  /// Every step is guarded INDIVIDUALLY. They used to share one try/catch, so a
  /// throw from the deep-link plugin (the first step) skipped notification
  /// setup entirely and the app ran with no notifications and no way to notice.
  Future<void> _initPlatform() async {
    if (!mounted) return;
    final controller = ref.read(nostrControllerProvider);

    // 1) Deep links: cold-start + streamed `app_links` URLs.
    DeepLinkService? deepLinks;
    try {
      deepLinks = DeepLinkService(NostrControllerDeepLinkTarget(controller));
      _deepLinks = deepLinks;
      await deepLinks.start();
    } catch (e) {
      debugPrint('[Platform] deep links skipped: $e');
    }

    // 2) Local notifications. This is the whole notification pipeline: events
    //    this device decrypted itself are posted by the OS, with no push
    //    provider in between. A tap carries either a notification-route payload
    //    (PM / group / channel) or a Nymchat URL.
    try {
      final notifications = NotificationService();
      await notifications.initialize();
      _payloadSub = notifications.payloadStream.listen(_openNotification);
      final initialPayload = notifications.takeInitialPayload();
      if (initialPayload != null && initialPayload.isNotEmpty) {
        _openNotification(initialPayload);
      }
      // Ask the OS for the permission the notifications need. Android 13+ and
      // iOS both post NOTHING without a runtime grant, and neither the manifest
      // entry nor the in-app toggle implies one — without this call every
      // notification the app raised was silently dropped by the system.
      // `ensurePermission` re-prompts nobody: a user who already answered gets
      // the standing answer back.
      if (ref.read(settingsProvider).notificationsEnabled) {
        unawaited(notifications.ensurePermission());
      }
      // iOS background catch-up. Registered whether or not notifications are on
      // right now, so switching them on later needs no relaunch; the catch-up
      // itself re-checks the setting before doing anything.
      _backgroundRefresh.start(
        () => ref.read(nostrControllerProvider).runBackgroundCatchUp(),
      );
    } catch (e) {
      debugPrint('[Platform] notifications skipped: $e');
    }

    // 3) OS share sheet: text/URLs/media shared into the app open a
    //    destination picker (channel / PM / group). Self-guards on
    //    unsupported platforms.
    try {
      final shareIntake = ShareIntake(ref: ref, navKey: _navKey);
      _shareIntake = shareIntake;
      await shareIntake.start();
    } catch (e) {
      debugPrint('[Platform] share intake skipped: $e');
    }
  }

  /// Handles a tapped notification: a notification-route payload opens the
  /// conversation it came from, anything else is tried as a deep link.
  void _openNotification(String payload) {
    try {
      final target = decodeNotificationPayload(payload);
      if (target != null) {
        openNotificationRoute(
          target,
          AppNotificationRouteTarget(
            controller: ref.read(nostrControllerProvider),
            appState: ref.read(appStateProvider.notifier),
            container: ProviderScope.containerOf(context, listen: false),
          ),
        );
        return;
      }
      _deepLinks?.handleUrl(payload);
    } catch (e) {
      debugPrint('[Platform] notification tap ignored: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _payloadSub?.cancel();
    _deepLinks?.dispose();
    _shareIntake?.dispose();
    unawaited(_backgroundConnectivity.stop());
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _syncBrightness();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On resume, re-hydrate the open conversation from D1 (the PWA backfills the
    // active channel on `visibilitychange`). Guarded so a missing controller in
    // tests/headless never throws.
    if (state == AppLifecycleState.resumed) {
      // Foreground again: the OS keep-alive has nothing left to protect, and
      // holding it would leave the Android notification up while the user is
      // looking at the app.
      unawaited(_backgroundConnectivity.stop());
      try {
        ref.read(nostrControllerProvider).onAppResumed();
      } catch (_) {}
      return;
    }

    // Backgrounded / hidden / inactive. With "Stay Connected in Background" on
    // we ask the OS to keep the relay sockets and the mesh radio running and
    // leave the geo-relay keep-alive pinging; otherwise we pause it so it
    // doesn't fire reconnects off-screen (the PWA's `document.hidden` skip).
    var keepAlive = false;
    try {
      keepAlive = ref.read(settingsProvider).backgroundConnectivity;
    } catch (_) {
      // No settings store (tests) — behave as before: pause everything.
    }
    // Started at the FIRST sign of leaving (`inactive`), not once we are fully
    // `paused`: Android 12+ refuses to start a foreground service from the
    // background, and by `onStop` the app can already count as background. A
    // transient `inactive` (a permission dialog, the app switcher) that returns
    // to `resumed` releases it again immediately, so the cost of starting early
    // is at worst a brief notification. `detached` is teardown: release it
    // there, or the notification would outlive the process that justifies it.
    if (keepAlive && state != AppLifecycleState.detached) {
      var mesh = false;
      try {
        mesh = ref.read(settingsProvider).meshEnabled;
      } catch (_) {}
      unawaited(_backgroundConnectivity.start(mesh: mesh));
    } else {
      unawaited(_backgroundConnectivity.stop());
    }
    // Ask iOS for a catch-up window while we are away. Requested on the way
    // out because a task request is only useful once the app is suspended, and
    // re-requested after each window fires (the native side does that).
    var notificationsOn = false;
    try {
      notificationsOn = ref.read(settingsProvider).notificationsEnabled;
    } catch (_) {}
    if (notificationsOn && state != AppLifecycleState.detached) {
      unawaited(_backgroundRefresh.schedule());
    }
    try {
      ref
          .read(nostrControllerProvider)
          .onAppPaused(keepConnectionsAlive: keepAlive);
    } catch (_) {}
  }

  void _syncBrightness() {
    final b = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    ref.read(platformBrightnessProvider.notifier).state = b;
  }

  /// Wires the static-text localizer: loads the persisted UI language's cache
  /// and, whenever a batch of translations lands, bumps [i18nVersionProvider]
  /// so the whole tree rebuilds and re-reads [tr]. Guarded so the absence of a
  /// KV store (never happens in the real app, but keeps this defensive) can't
  /// crash startup.
  void _initLocalization() {
    try {
      final kv = ref.read(keyValueStoreProvider);
      final lang = ref.read(settingsProvider).uiLanguage;
      LocalizationService.instance.onChanged = () {
        if (!mounted) return;
        ref.read(i18nVersionProvider.notifier).state++;
      };
      LocalizationService.instance.configure(kv: kv, language: lang);
      // Returning user already in a non-English language: sweep the full UI
      // catalog in the background to fill any strings not cached from a prior
      // session (or newly added by an app update). Deferred so it doesn't
      // compete with boot; cheap when everything is already cached.
      if (LocalizationService.instance.isActive) {
        LocalizationService.instance.prime(commandSourcePhrases());
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (mounted) LocalizationService.instance.sweep(kAppStringsCatalog);
        });
      }
    } catch (_) {
      // No KV override (e.g. some tests) — stay in English, tr() is a no-op.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(nymColorsProvider);
    final bootEpoch = ref.watch(bootEpochProvider);
    // Keep the Bluetooth mesh alive app-wide so it starts at launch when the
    // setting is enabled (and reacts to toggles) rather than only when the mesh
    // screen is open. The controller no-ops on unsupported platforms.
    ref.watch(meshControllerProvider);
    // Rebuild the whole tree when a batch of UI-string translations lands (or
    // the language changes), so every `tr()` call re-reads the fresh cache.
    ref.watch(i18nVersionProvider);
    // Drive the localizer from the persisted setting: a language change (from
    // the onboarding picker or Settings) reloads that language's cache and
    // pre-translates the on-screen strings.
    ref.listen<String>(settingsProvider.select((s) => s.uiLanguage), (_, next) {
      LocalizationService.instance.setLanguage(next);
    });
    // Turning "Stay Connected in Background" off — here or on another device,
    // whose change arrives through the settings sync — releases the keep-alive
    // immediately rather than at the next resume.
    ref.listen<bool>(
      settingsProvider.select((s) => s.backgroundConnectivity),
      (_, next) {
        if (!next) unawaited(_backgroundConnectivity.stop());
      },
    );
    // Notifications off: stop asking iOS for catch-up windows there is nothing
    // to do in. Turning them back on re-requests one at the next background
    // transition, and asks the OS for permission from the panel toggle.
    ref.listen<bool>(
      settingsProvider.select((s) => s.notificationsEnabled),
      (_, next) {
        if (!next) unawaited(_backgroundRefresh.cancel());
      },
    );
    // Sign-out bumps the boot generation (nostr_controller `signOut`). Pop any
    // dialogs/modals stacked above the gate so the freshly-keyed BootGate below
    // (re-running the setup-needed check) is what the user lands on.
    ref.listen<int>(bootEpochProvider, (_, __) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navKey.currentState?.popUntil((r) => r.isFirst);
      });
    });
    return MaterialApp(
      title: 'Nymchat',
      navigatorKey: _navKey,
      debugShowCheckedModeBanner: false,
      theme: buildNymThemeData(colors),
      // Native status/navigation-bar sync (`settings.js applyColorMode`,
      // 1049-1064): tint the bars `#f5f5f2` (light) / `#000000` (dark) and flip
      // the icon brightness so they stay legible per mode. `AnnotatedRegion`
      // re-applies whenever the resolved brightness changes.
      builder: (context, child) {
        final isLight = colors.isLight;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
            statusBarIconBrightness:
                isLight ? Brightness.dark : Brightness.light,
            systemNavigationBarColor:
                isLight ? const Color(0xFFF5F5F2) : const Color(0xFF000000),
            systemNavigationBarIconBrightness:
                isLight ? Brightness.dark : Brightness.light,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      // The boot gate decides first-run setup vs. the shell (setup-modal-init.js
      // + checkSavedConnection), then mounts HomeShell + the first-run tutorial.
      // Keyed on the boot generation so sign-out remounts a pristine gate.
      home: BootGate(key: ValueKey(bootEpoch)),
    );
  }
}

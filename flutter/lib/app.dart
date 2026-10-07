import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/calls/call_platform.dart';
import 'features/calls/call_providers.dart';
import 'features/calls/call_wake.dart';
import 'features/calls/ring_setting.dart';
import 'core/theme/nym_theme.dart';
import 'features/accounts/account_host.dart';
import 'features/ai_consent/ai_consent.dart';
import 'features/i18n/app_strings_catalog.dart';
import 'features/commands/command_i18n.dart';
import 'features/chat_lock/chat_lock_providers.dart';
import 'features/chat_lock/chat_lock_ui.dart';
import 'features/group_tools/group_tools_providers.dart' show groupToolsContext;
import 'features/group_tools/group_tools_ui.dart' show joinCallLinkFlow;
import 'features/groups/group_invite_confirm.dart';
import 'features/i18n/i18n.dart';
import 'features/i18n/localization_service.dart';
import 'features/mesh/mesh_controller.dart';
import 'features/notifications/notification_route_target.dart';
import 'features/notifications/notification_routing.dart';
import 'features/onboarding/boot_gate.dart';
import 'features/share/share_intake.dart';
import 'features/toasts/event_toast_center.dart';
import 'features/toasts/event_toast_wiring.dart';
import 'models/group.dart';
import 'services/notification_service.dart';
import 'services/platform/background_connectivity.dart';
import 'services/platform/background_refresh.dart';
import 'services/platform/deep_link_target.dart';
import 'services/platform/heartbeat.dart';
import 'services/platform/deep_links.dart';
import 'state/app_state.dart';
import 'state/nostr_controller.dart';
import 'state/settings_provider.dart';
import 'widgets/common/nym_tooltip.dart';
import 'widgets/common/toast_host.dart';

/// Root widget; rebuilds when the theme setting or platform brightness changes.
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

  /// Background keep-alive, held only while backgrounded with the setting on and released on every resume.
  late final BackgroundConnectivityService _backgroundConnectivity;

  /// iOS-only catch-up via `BGAppRefresh`, the only chance a suspended app gets to notify; no-op on Android.
  final BackgroundRefreshService _backgroundRefresh =
      BackgroundRefreshService();

  HeartbeatService? _heartbeat;

  /// Lets sign-out pop dialogs pushed above the boot gate, which the keyed remount doesn't replace.
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    registerAiConsentPrompter(_navKey);
    _backgroundConnectivity = ref.read(backgroundConnectivityServiceProvider);
    WidgetsBinding.instance.addObserver(this);
    _initLocalization();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncBrightness());
    // Deferred past the first frame so the controller and providers are ready before any link dispatches.
    WidgetsBinding.instance.addPostFrameCallback((_) => _initPlatform());
  }

  /// Boots deep links, notifications and the share sheet, each guarded individually so one failure can't skip the rest.
  Future<void> _initPlatform() async {
    if (!mounted) return;
    final controller = ref.read(nostrControllerProvider);

    // Registered regardless of the notification setting; the catch-up re-checks it.
    _backgroundRefresh.start(() async {
      final caught =
          await ref.read(nostrControllerProvider).runBackgroundCatchUp();
      try {
        await ref.read(accountsProvider)?.runInactiveProbes();
      } catch (_) {}
      return caught;
    });

    _startHeartbeat();
    unawaited(_startRing());

    _wireGroupTools();
    _wireChatLock();
    installEventToasts(ProviderScope.containerOf(context, listen: false),
        () => _navKey.currentContext);
    DeepLinkService? deepLinks;
    try {
      deepLinks = DeepLinkService(NostrControllerDeepLinkTarget(controller,
          confirmInvite: _confirmGroupInvite));
      _deepLinks = deepLinks;
      await deepLinks.start();
    } catch (e) {
      debugPrint('[Platform] deep links skipped: $e');
    }

    // Local notifications posted by the OS for events this device decrypted; no push provider.
    try {
      final notifications = NotificationService();
      await notifications.initialize();
      _payloadSub = notifications.payloadStream.listen(_openNotification);
      final initialPayload = notifications.takeInitialPayload();
      if (initialPayload != null && initialPayload.isNotEmpty) {
        _openNotification(initialPayload);
      }
      // Android 13+ and iOS post nothing without a runtime grant; this doesn't re-prompt anyone who answered.
      if (ref.read(settingsProvider).notificationsEnabled) {
        unawaited(notifications.ensurePermission());
      }
    } catch (e) {
      debugPrint('[Platform] notifications skipped: $e');
    }

    // OS share sheet intake; self-guards on unsupported platforms.
    try {
      final shareIntake = ShareIntake(ref: ref, navKey: _navKey);
      _shareIntake = shareIntake;
      await shareIntake.start();
    } catch (e) {
      debugPrint('[Platform] share intake skipped: $e');
    }
  }

  /// A route payload opens its conversation; anything else is tried as a deep link.
  void _openNotification(String payload) {
    if (payload.startsWith(kAccountPayloadPrefix)) {
      final id = payload.substring(kAccountPayloadPrefix.length);
      try {
        unawaited(ref.read(accountsProvider)?.switchTo(id));
      } catch (_) {}
      return;
    }
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

  void _wireChatLock() {
    try {
      final service = ref.read(chatLockProvider);
      installChatLockPrompter(service, () => _navKey.currentContext);
      installChatLockGate(ref.read(appStateProvider.notifier), service);
    } catch (e) {
      debugPrint('[Platform] chat lock skipped: ${e.runtimeType}');
    }
  }

  void _wireGroupTools() {
    groupToolsContext = () => _navKey.currentContext;
    callLinkHandler = (token) {
      final ctx = _navKey.currentContext;
      if (ctx != null && ctx.mounted) unawaited(joinCallLinkFlow(ctx, token));
    };
  }

  Future<bool> _confirmGroupInvite(GroupInviteToken token) async {
    final navContext = _navKey.currentContext;
    if (navContext == null || !navContext.mounted) return false;
    return confirmGroupInviteJoin(navContext, token);
  }

  Future<void> _startRing() async {
    try {
      ref.read(callServiceProvider);
      final platform = ref.read(callPlatformProvider);
      final reg = ref.read(ringRegistrationProvider);
      reg.nativeSupported = await platform.ringSupported();
      final self = ref.read(nostrControllerProvider).identity?.pubkey ?? '';
      if (reg.supported && reg.enabledFor(self)) {
        await platform.ringEnable(ringNativeStrings());
      }
    } catch (e) {
      debugPrint('[Platform] ring skipped: ${e.runtimeType}');
    }
  }

  void _startHeartbeat() {
    if (!HeartbeatService.isSupported) return;
    try {
      final heartbeat = HeartbeatService(kv: ref.read(keyValueStoreProvider));
      _heartbeat = heartbeat;
      if (ref.read(settingsProvider).backgroundConnectivity) {
        _setHeartbeat(true);
      }
    } catch (e) {
      debugPrint('[Platform] heartbeat skipped: ${e.runtimeType}');
    }
  }

  void _setHeartbeat(bool on) {
    final heartbeat = _heartbeat;
    if (heartbeat == null) return;
    unawaited(heartbeat.setEnabled(on).catchError((Object e) {
      debugPrint('[Platform] heartbeat ${on ? 'on' : 'off'} failed: ${e.runtimeType}');
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.dispose();
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
    // Re-hydrate the open conversation from D1 on resume.
    try {
      ref.read(appStateProvider.notifier).setAppVisible(
          state == AppLifecycleState.resumed ||
              state == AppLifecycleState.inactive);
    } catch (_) {}
    if (state == AppLifecycleState.resumed) {
      // Release the keep-alive so the Android notification isn't up while in the foreground.
      unawaited(_backgroundConnectivity.stop());
      try {
        ref.read(nostrControllerProvider).onAppResumed();
      } catch (_) {}
      final heartbeat = _heartbeat;
      if (heartbeat != null) {
        unawaited(heartbeat.resume().catchError((Object _) {}));
      }
      return;
    }

    // With "Stay Connected in Background" keep sockets and mesh running; otherwise pause the keep-alive.
    try {
      ref.read(nostrControllerProvider).flushPendingGroupReactions();
    } catch (_) {}
    try {
      ref.read(nostrControllerProvider).flushPendingDeposits();
    } catch (_) {}
    var keepAlive = false;
    try {
      keepAlive = ref.read(settingsProvider).backgroundConnectivity;
    } catch (_) {
      // No settings store (tests): pause everything.
    }
    // Start at `inactive`, since Android 12+ refuses to start a foreground service from the background; release on `detached`.
    if (keepAlive && state != AppLifecycleState.detached) {
      var mesh = false;
      try {
        mesh = ref.read(settingsProvider).meshEnabled;
      } catch (_) {}
      unawaited(_backgroundConnectivity.start(mesh: mesh));
    } else {
      unawaited(_backgroundConnectivity.stop());
    }
    // Request an iOS catch-up window on the way out; native re-requests after each fires.
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

  /// Loads the UI language cache and bumps [i18nVersionProvider] as translations land; guarded against a missing store.
  void _initLocalization() {
    try {
      final kv = ref.read(keyValueStoreProvider);
      final lang = ref.read(settingsProvider).uiLanguage;
      LocalizationService.instance.onChanged = () {
        if (!mounted) return;
        ref.read(i18nVersionProvider.notifier).state++;
      };
      LocalizationService.instance.configure(kv: kv, language: lang);
      // Returning non-English user: sweep the full catalog in the background, deferred past boot.
      if (LocalizationService.instance.isActive) {
        LocalizationService.instance.prime(commandSourcePhrases());
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (mounted) LocalizationService.instance.sweep(kAppStringsCatalog);
        });
      }
    } catch (_) {
      // No KV override (some tests): stay in English.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(nymColorsProvider);
    final bootEpoch = ref.watch(bootEpochProvider);
    // Keep the mesh alive app-wide so it follows the setting from launch; no-op on unsupported platforms.
    ref.watch(meshControllerProvider);
    // Rebuild the whole tree when translations land so every `tr()` re-reads the cache.
    ref.watch(i18nVersionProvider);
    ref.listen<String>(settingsProvider.select((s) => s.uiLanguage), (_, next) {
      LocalizationService.instance.setLanguage(next);
    });
    // Turning the setting off anywhere, including via sync, releases the keep-alive immediately.
    ref.listen<bool>(
      settingsProvider.select((s) => s.backgroundConnectivity),
      (_, next) {
        if (!next) unawaited(_backgroundConnectivity.stop());
        _setHeartbeat(next);
      },
    );
    // Notifications off: stop requesting iOS catch-up windows.
    ref.listen<bool>(
      settingsProvider.select((s) => s.notificationsEnabled),
      (_, next) {
        if (!next) unawaited(_backgroundRefresh.cancel());
      },
    );
    // Sign-out bumps the boot generation; pop stacked dialogs so the user lands on the fresh gate.
    ref.listen<int>(bootEpochProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navKey.currentState?.popUntil((r) => r.isFirst);
      });
    });
    return MaterialApp(
      title: 'Nymchat',
      navigatorKey: _navKey,
      navigatorObservers: [EventToastCenter.instance.observer],
      debugShowCheckedModeBanner: false,
      theme: buildNymThemeData(colors),
      // Tint system bars per color mode and flip icon brightness so they stay legible.
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
          child: NymTooltipWarmth(
            child: PrivacyShield(
                child: ToastHost(child: child ?? const SizedBox.shrink())),
          ),
        );
      },
      // Keyed on the boot generation so sign-out remounts a pristine gate.
      home: BootGate(key: ValueKey(bootEpoch)),
    );
  }
}

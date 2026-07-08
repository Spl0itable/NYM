import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/nym_theme.dart';
import 'features/onboarding/boot_gate.dart';
import 'services/firebase_messaging_service.dart';
import 'services/notification_service.dart';
import 'services/platform/deep_link_target.dart';
import 'services/platform/deep_links.dart';
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

  /// Lets sign-out clear any dialogs/modals pushed above the boot gate. The
  /// remount (keyed [BootGate]) replaces the gate's content, but pushed routes
  /// live on the navigator above `home` and must be popped explicitly.
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncBrightness());
    // Platform integration is wired from the root widget so it runs without
    // editing main.dart (which another agent owns). Deferred past the first
    // frame so the controller + providers are ready before any link dispatches.
    WidgetsBinding.instance.addPostFrameCallback((_) => _initPlatform());
  }

  /// Boots deep links + push wiring. Each piece guards itself so a missing
  /// platform channel (tests, web, de-Googled builds) no-ops gracefully — the
  /// whole body is wrapped so a missing plugin never breaks app startup.
  Future<void> _initPlatform() async {
    if (!mounted) return;
    try {
      final controller = ref.read(nostrControllerProvider);
      final target = NostrControllerDeepLinkTarget(controller);

      // 1) Deep links: cold-start + streamed `app_links` URLs.
      final deepLinks = DeepLinkService(target);
      _deepLinks = deepLinks;
      await deepLinks.start();

      // 2) Local notifications + a notification-tap → deep-link route. A tapped
      //    push carries a Nymchat URL payload; route it through the same
      //    dispatcher so it lands on the right channel/PM/group.
      final notifications = NotificationService();
      await notifications.initialize();
      _payloadSub = notifications.payloadStream.listen(deepLinks.handleUrl);
      final initialPayload = notifications.takeInitialPayload();
      if (initialPayload != null && initialPayload.isNotEmpty) {
        deepLinks.handleUrl(initialPayload);
      }

      // 3) FCM push: integrates the existing wrapper. No-ops gracefully when
      //    Firebase isn't available in this build.
      await FirebaseMessagingService().initialize(
        onDeepLink: deepLinks.handleUrl,
        showLocalNotification: notifications.showNotification,
      );
    } catch (e, st) {
      // Platform plugins are absent in widget tests and on unsupported
      // platforms; never let that crash the app.
      debugPrint('[Platform] init skipped: $e\n$st');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _payloadSub?.cancel();
    _deepLinks?.dispose();
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
      try {
        ref.read(nostrControllerProvider).onAppResumed();
      } catch (_) {}
    } else {
      // Backgrounded / hidden / inactive: pause the geo-relay keep-alive so it
      // doesn't fire reconnects off-screen (the PWA's `document.hidden` skip).
      try {
        ref.read(nostrControllerProvider).onAppPaused();
      } catch (_) {}
    }
  }

  void _syncBrightness() {
    final b = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    ref.read(platformBrightnessProvider.notifier).state = b;
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(nymColorsProvider);
    final bootEpoch = ref.watch(bootEpochProvider);
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

import 'dart:async';

import 'package:flutter/material.dart';
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

  void _syncBrightness() {
    final b = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    ref.read(platformBrightnessProvider.notifier).state = b;
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(nymColorsProvider);
    return MaterialApp(
      title: 'Nymchat',
      debugShowCheckedModeBanner: false,
      theme: buildNymThemeData(colors),
      // The boot gate decides first-run setup vs. the shell (setup-modal-init.js
      // + checkSavedConnection), then mounts HomeShell + the first-run tutorial.
      home: const BootGate(),
    );
  }
}

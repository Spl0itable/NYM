import 'package:flutter/foundation.dart';

/// FCM push wrapper.
///
/// This build does **not** bundle the `firebase_messaging` / `firebase_core`
/// plugins (kept out to avoid a hard Google Play Services dependency, so the app
/// runs on de-Googled devices). The wrapper therefore self-guards: when Firebase
/// is unavailable it no-ops gracefully, while still exposing the integration
/// surface the rest of the app wires into (a deep-link router + a local
/// notification presenter). When the Firebase plugins + a valid
/// `google-services.json` / `GoogleService-Info.plist` are added, the guarded
/// `_firebaseAvailable` path below is where real `FirebaseMessaging` calls go.
// TODO(verify): no `google-services.json` (Android) / `GoogleService-Info.plist`
// (iOS) is present in this repo and the `firebase_messaging` package is not in
// pubspec.yaml, so initialization is a guarded no-op. Add both (and the plugins)
// to enable real push.

/// Signature for routing a tapped/received push that carries a Nymchat URL into
/// the deep-link dispatcher (`DeepLinkService.handleUrl`).
typedef DeepLinkHandler = bool Function(String url);

/// Signature for surfacing a push via the local-notification path
/// (`NotificationService.showNotification`).
typedef LocalNotificationPresenter = Future<void> Function({
  required String title,
  required String body,
  String? payload,
});

class FirebaseMessagingService {
  static final FirebaseMessagingService _instance =
      FirebaseMessagingService._internal();
  factory FirebaseMessagingService() => _instance;
  FirebaseMessagingService._internal();

  bool _isInitialized = false;

  /// Whether real Firebase messaging is available in this build. Always false
  /// here because the plugins + config aren't bundled; gated as a single switch
  /// so the wiring is ready when they are.
  // TODO(verify): flip to a real availability check (Firebase.apps.isNotEmpty)
  // once firebase_core/firebase_messaging are added to pubspec.yaml.
  static const bool _firebaseAvailable = false;

  DeepLinkHandler? _onDeepLink;
  LocalNotificationPresenter? _showLocalNotification;

  /// Initialize FCM. Requests permission, gets the token, and registers
  /// foreground/background/tap handlers — each guarded so a build without
  /// Firebase (or without Google Play Services) no-ops rather than throwing.
  ///
  /// * [onDeepLink] routes a push's `link`/`url` payload through the deep-link
  ///   dispatcher (so a tapped push lands on the right channel/PM/group).
  /// * [showLocalNotification] surfaces a foreground push via the local
  ///   notification path, carrying the deep-link URL as its tap payload.
  Future<void> initialize({
    DeepLinkHandler? onDeepLink,
    LocalNotificationPresenter? showLocalNotification,
  }) async {
    _onDeepLink = onDeepLink;
    _showLocalNotification = showLocalNotification;

    if (_isInitialized) return;
    _isInitialized = true;

    if (!_firebaseAvailable) {
      if (kDebugMode) {
        debugPrint('[FCM] Firebase not bundled in this build — push disabled. '
            'App works without Google Play Services.');
      }
      return;
    }

    // ----- Real-Firebase path (compiled out until the plugins are added) -----
    // The block below documents the intended wiring; it is unreachable while
    // [_firebaseAvailable] is false so it imposes no plugin dependency.
    //
    //   await Firebase.initializeApp();
    //   final messaging = FirebaseMessaging.instance;
    //   await messaging.requestPermission();           // + permission_handler
    //   final token = await messaging.getToken();      // register with backend
    //   FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    //   FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpenedApp);
    //   FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
    //   final initial = await messaging.getInitialMessage();
    //   if (initial != null) _onMessageOpenedApp(initial);
  }

  /// Request the FCM registration token. Returns null when Firebase isn't
  /// available (so callers can skip backend registration).
  Future<String?> getToken() async {
    if (!_firebaseAvailable) {
      if (kDebugMode) {
        debugPrint('[FCM] getToken: Firebase not available — returning null.');
      }
      return null;
    }
    // return FirebaseMessaging.instance.getToken();
    return null;
  }

  /// Routes a push data payload (a `{title, body, link|url}` map) the way the
  /// onMessage / onMessageOpenedApp handlers would. Exposed (and used in tests)
  /// so the foreground/tap behaviour is verifiable without a live Firebase.
  ///
  /// * On a foreground message: surface a local notification carrying the
  ///   deep-link URL as its payload (tapping it later re-enters [routeTap]).
  /// * On a tapped message (`opened == true`): route the link immediately.
  Future<void> routeMessage(
    Map<String, dynamic> data, {
    bool opened = false,
  }) async {
    final link = (data['link'] ?? data['url'] ?? '').toString();
    final title = (data['title'] ?? 'Nymchat').toString();
    final body = (data['body'] ?? '').toString();

    if (opened) {
      if (link.isNotEmpty) _onDeepLink?.call(link);
      return;
    }
    // Foreground: present via the local-notification path with the link as the
    // tap payload (NotificationService routes payload taps to the dispatcher).
    await _showLocalNotification?.call(
      title: title,
      body: body,
      payload: link.isEmpty ? null : link,
    );
  }

  /// Routes a notification-tap payload (a Nymchat URL) into the deep-link
  /// dispatcher. Returns true if the URL was a recognized link.
  bool routeTap(String payload) => _onDeepLink?.call(payload) ?? false;
}

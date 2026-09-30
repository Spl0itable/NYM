import 'package:flutter/foundation.dart';

/// FCM push wrapper that no-ops while the Firebase plugins are not bundled, keeping de-Googled devices working.
// TODO(verify): add the Firebase plugins and google-services config to enable real push.

/// Routes a push's Nymchat URL into the deep-link dispatcher.
typedef DeepLinkHandler = bool Function(String url);

/// Surfaces a push via the local-notification path.
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

  /// Always false while the Firebase plugins and config are not bundled.
  // TODO(verify): switch to a real availability check (Firebase.apps.isNotEmpty) once the plugins land.
  static const bool _firebaseAvailable = false;

  DeepLinkHandler? _onDeepLink;
  LocalNotificationPresenter? _showLocalNotification;

  /// Initializes FCM with each step guarded, so a build without Firebase or Play Services no-ops.
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
  }

  /// The FCM token, or null when Firebase is unavailable.
  Future<String?> getToken() async {
    if (!_firebaseAvailable) {
      if (kDebugMode) {
        debugPrint('[FCM] getToken: Firebase not available — returning null.');
      }
      return null;
    }
    return null;
  }

  /// Routes a `{title, body, link|url}` payload: foreground shows a notification, a tap routes the link.
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
    // Foreground: show a local notification whose tap payload is the link.
    await _showLocalNotification?.call(
      title: title,
      body: body,
      payload: link.isEmpty ? null : link,
    );
  }

  /// Routes a tapped notification's URL; true when it was a recognized link.
  bool routeTap(String payload) => _onDeepLink?.call(payload) ?? false;
}

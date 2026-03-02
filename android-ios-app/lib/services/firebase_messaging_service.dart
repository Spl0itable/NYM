import 'package:flutter/foundation.dart';

/// Placeholder for Firebase Messaging service
/// Firebase Messaging has been removed to avoid Google Play Services requirement
/// The app now works on all Android devices, including de-Googled phones
class FirebaseMessagingService {
  static final FirebaseMessagingService _instance = FirebaseMessagingService._internal();
  factory FirebaseMessagingService() => _instance;
  FirebaseMessagingService._internal();

  bool _isInitialized = false;

  /// Initialize - currently a no-op since Firebase Messaging is not included
  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    if (kDebugMode) {
      print('Firebase Messaging not included - app works without Google Play Services');
    }
  }

  /// Request FCM token - returns null as Firebase is not included
  Future<String?> getToken() async {
    if (kDebugMode) {
      print('Firebase Messaging not available - no Google Play Services dependency');
    }
    return null;
  }
}

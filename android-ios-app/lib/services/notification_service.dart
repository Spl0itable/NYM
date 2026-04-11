import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  final _payloadStreamController = StreamController<String>.broadcast();
  String? _initialPayload;
  int _notificationIdCounter = 0;
  final Random _random = Random();

  Stream<String> get payloadStream => _payloadStreamController.stream;

  String? takeInitialPayload() {
    final payload = _initialPayload;
    _initialPayload = null;
    return payload;
  }

  Future<void> initialize() async {
    if (kIsWeb) {
      return;
    }
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestSoundPermission: false,
      requestBadgePermission: false,
      requestAlertPermission: false,
    );
    const settings = InitializationSettings(android: androidSettings, iOS: iosSettings);
    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          _payloadStreamController.add(payload);
        }
      },
    );
    final launchDetails = await _notifications.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      _initialPayload = launchDetails?.notificationResponse?.payload;
    }
  }

  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (kIsWeb) {
      return;
    }
    // Generate unique notification ID to prevent notifications from replacing each other
    final notificationId = _generateUniqueId();
    
    const androidDetails = AndroidNotificationDetails(
      'nymchat_channel',
      'Nymchat Notifications',
      channelDescription: 'Notifications from Nymchat PWA',
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    
    debugPrint('[NotificationService] Showing notification: id=$notificationId, title=$title, payload=$payload');
    await _notifications.show(notificationId, title, body, details, payload: payload);
  }
  
  int _generateUniqueId() {
    // Combine counter with random component to ensure uniqueness
    _notificationIdCounter = (_notificationIdCounter + 1) % 100000;
    return _notificationIdCounter + _random.nextInt(100000) * 100000;
  }
}

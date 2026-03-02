import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  final _payloadStreamController = StreamController<String>.broadcast();
  String? _initialPayload;

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
      requestSoundPermission: true,
      requestBadgePermission: true,
      requestAlertPermission: true,
    );
    const settings = InitializationSettings(android: androidSettings, iOS: iosSettings);
    await _notifications.initialize(
      settings: settings,
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
    await requestPermissions();
  }

  Future<void> requestPermissions() async {
    if (kIsWeb) {
      return;
    }
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
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
    const androidDetails = AndroidNotificationDetails(
      'nymchat_channel',
      'Nymchat Notifications',
      channelDescription: 'Notifications from Nymchat PWA',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    await _notifications.show(id: 0, title: title, body: body, notificationDetails: details, payload: payload);
  }
}

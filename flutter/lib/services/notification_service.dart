import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Selects the Android channel and alert weight.
enum NotificationKind {
  message,

  mention,

  activity,
}

enum NotificationPermission {
  granted,

  /// Declined or turned off in system settings; nothing posted will show.
  denied,

  /// No notification surface here (web, desktop, test host).
  unsupported,
}

/// Local notifications for events decrypted on this device; no push provider ever sees who messages whom.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final _payloadStreamController = StreamController<String>.broadcast();
  String? _initialPayload;
  int _notificationIdCounter = 0;
  final Random _random = Random();
  bool _initialized = false;

  /// Tap payloads from notifications opened while the app was running.
  Stream<String> get payloadStream => _payloadStreamController.stream;

  /// The payload of the notification that launched the app, consumed once.
  String? takeInitialPayload() {
    final payload = _initialPayload;
    _initialPayload = null;
    return payload;
  }

  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  Future<void> initialize() async {
    if (!isSupported) return;
    if (_initialized) return;
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    // Don't request authorization at startup: iOS gives one prompt, so ask when it makes sense.
    const iosSettings = DarwinInitializationSettings(
      requestSoundPermission: false,
      requestBadgePermission: false,
      requestAlertPermission: false,
    );
    const settings =
        InitializationSettings(android: androidSettings, iOS: iosSettings);
    await _notifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          _payloadStreamController.add(payload);
        }
      },
    );
    _initialized = true;
    final launchDetails =
        await _notifications.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      _initialPayload = launchDetails?.notificationResponse?.payload;
    }
  }

  /// Shows the system prompt the first time and returns the OS decision; safe to call repeatedly.
  Future<NotificationPermission> requestPermission() async {
    if (!isSupported) return NotificationPermission.unsupported;
    try {
      await initialize();
      if (Platform.isAndroid) {
        final android =
            _notifications.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        if (android == null) return NotificationPermission.unsupported;
        final granted = await android.requestNotificationsPermission();
        // Null means the plugin could not ask; fall back to what the OS reports.
        if (granted == true) return NotificationPermission.granted;
        final enabled = await android.areNotificationsEnabled();
        return enabled == true
            ? NotificationPermission.granted
            : NotificationPermission.denied;
      }
      final ios = _notifications.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios == null) return NotificationPermission.unsupported;
      final granted = await ios.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted == true
          ? NotificationPermission.granted
          : NotificationPermission.denied;
    } catch (e) {
      debugPrint('[NotificationService] permission request failed: $e');
      return NotificationPermission.denied;
    }
  }

  /// What the OS currently allows, without prompting.
  Future<NotificationPermission> permissionStatus() async {
    if (!isSupported) return NotificationPermission.unsupported;
    try {
      await initialize();
      if (Platform.isAndroid) {
        final android =
            _notifications.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        final enabled = await android?.areNotificationsEnabled();
        return enabled == true
            ? NotificationPermission.granted
            : NotificationPermission.denied;
      }
      final ios = _notifications.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final options = await ios?.checkPermissions();
      return (options?.isEnabled ?? false)
          ? NotificationPermission.granted
          : NotificationPermission.denied;
    } catch (e) {
      debugPrint('[NotificationService] permission check failed: $e');
      return NotificationPermission.denied;
    }
  }

  /// Requests permission only when not already granted.
  Future<NotificationPermission> ensurePermission() async {
    final status = await permissionStatus();
    if (status == NotificationPermission.granted) return status;
    return requestPermission();
  }

  /// Posts a notification; a [conversationKey] replaces and groups that conversation's notification.
  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
    String? conversationKey,
    NotificationKind kind = NotificationKind.message,
    bool presentWhileOpen = true,
  }) async {
    if (!isSupported) return;
    await initialize();

    // Unkeyed notifications get a unique id so they never replace another.
    final notificationId = conversationKey == null || conversationKey.isEmpty
        ? _generateUniqueId()
        : conversationKey.hashCode & 0x7fffffff;

    final androidDetails = NotificationService.androidDetails(
      title: title,
      body: body,
      conversationKey: conversationKey,
      kind: kind,
    );
    final iosDetails = darwinDetails(
      conversationKey: conversationKey,
      presentWhileOpen: presentWhileOpen,
    );
    final details =
        NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _notifications.show(
        id: notificationId,
        title: title,
        body: body,
        notificationDetails: details,
        payload: payload);
  }

  static AndroidNotificationDetails androidDetails({
    required String title,
    required String body,
    String? conversationKey,
    NotificationKind kind = NotificationKind.message,
  }) {
    final channel = _channelFor(kind);
    return AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: channel.importance,
      priority: kind == NotificationKind.activity
          ? Priority.defaultPriority
          : Priority.high,
      enableVibration: kind != NotificationKind.activity,
      playSound: true,
      styleInformation: BigTextStyleInformation(body, contentTitle: title),
      autoCancel: true,
      groupKey: conversationKey,
      visibility: NotificationVisibility.private,
    );
  }

  static DarwinNotificationDetails darwinDetails({
    String? conversationKey,
    bool presentWhileOpen = true,
  }) =>
      DarwinNotificationDetails(
        presentAlert: presentWhileOpen,
        presentBanner: presentWhileOpen,
        presentList: true,
        presentBadge: true,
        presentSound: presentWhileOpen,
        threadIdentifier: conversationKey,
      );

  static Future<void> cancelEverything() async {
    if (!isSupported) return;
    try {
      await _instance._notifications.cancelAll();
    } catch (_) {}
  }

  Future<void> cancelConversation(String conversationKey) async {
    if (!isSupported || conversationKey.isEmpty) return;
    try {
      await _notifications.cancel(id: conversationKey.hashCode & 0x7fffffff);
    } catch (_) {
      // Nothing posted for it, or plugin unavailable.
    }
  }

  static const Set<String> _badgeChannels = {
    'nym_messages',
    'nym_mentions',
    'nym_activity',
  };

  static List<int> staleNotificationIds(
      List<ActiveNotification> active, Set<String> unreadKeys) {
    final out = <int>[];
    for (final n in active) {
      final id = n.id;
      if (id == null || !_badgeChannels.contains(n.channelId)) continue;
      final key = n.groupKey ?? '';
      if (key.startsWith('account-')) continue;
      final keep = key.isEmpty ? unreadKeys.isNotEmpty : unreadKeys.contains(key);
      if (!keep) out.add(id);
    }
    return out;
  }

  Future<void> cancelReadConversations(Set<String> unreadKeys) async {
    if (!isSupported || !Platform.isAndroid) return;
    try {
      final android = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return;
      final active = await android.getActiveNotifications();
      for (final id in staleNotificationIds(active, unreadKeys)) {
        await _notifications.cancel(id: id);
      }
    } catch (_) {}
  }

  /// One Android channel per kind, since a channel's importance is fixed at creation.
  static _Channel _channelFor(NotificationKind kind) {
    switch (kind) {
      case NotificationKind.message:
        return const _Channel(
          'nym_messages',
          'Messages',
          'Private messages and group chats.',
          Importance.high,
        );
      case NotificationKind.mention:
        return const _Channel(
          'nym_mentions',
          'Mentions',
          'When someone mentions you in a channel.',
          Importance.high,
        );
      case NotificationKind.activity:
        return const _Channel(
          'nym_activity',
          'Reactions and zaps',
          'Reactions, zaps and other activity on your messages.',
          Importance.defaultImportance,
        );
    }
  }

  int _generateUniqueId() {
    _notificationIdCounter = (_notificationIdCounter + 1) % 100000;
    return _notificationIdCounter + _random.nextInt(100000) * 100000;
  }
}

class _Channel {
  const _Channel(this.id, this.name, this.description, this.importance);
  final String id;
  final String name;
  final String description;
  final Importance importance;
}

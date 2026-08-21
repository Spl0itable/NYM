import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// What a notification is about. Selects the Android channel (so the user can
/// tune each kind in system settings) and the alert weight.
enum NotificationKind {
  /// A PM or group message addressed to us.
  message,

  /// An @-mention in a public channel.
  mention,

  /// A reaction, zap, or other low-urgency social signal.
  activity,
}

/// The OS-level result of asking to post notifications.
enum NotificationPermission {
  /// The OS will display what we post.
  granted,

  /// The user declined, or turned notifications off in system settings.
  /// Nothing we post will be shown until they change that.
  denied,

  /// No notification surface here (web / desktop / test host).
  unsupported,
}

/// Posts OS notifications for events the app decrypted itself.
///
/// Nymchat has no push provider: there is no FCM and no APNs registration, so
/// nothing about who is messaging whom ever reaches a third party. Every
/// notification originates from an event this device received over its own
/// relay socket or the Bluetooth mesh and decrypted locally, which is also why
/// PMs and group chats can show real content — the plaintext only ever exists
/// here.
///
/// The OS still has to agree to display them, and that is a runtime grant on
/// both platforms: Android 13+ requires POST_NOTIFICATIONS, and iOS shows
/// nothing at all until `requestAuthorization` has been accepted. Neither is
/// implied by the manifest/Info.plist entries, so [requestPermission] has to be
/// called before any of this is visible — see [ensurePermission].
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

  /// Tap payloads (see `notification_routing.dart`) from notifications the user
  /// opened while the app was already running.
  Stream<String> get payloadStream => _payloadStreamController.stream;

  /// The payload of the notification that launched the app, consumed once.
  String? takeInitialPayload() {
    final payload = _initialPayload;
    _initialPayload = null;
    return payload;
  }

  /// Whether this platform can post notifications at all.
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
    // Authorization is deliberately NOT requested here. Asking during startup
    // spends the one prompt iOS gives us before the user has any idea what it
    // is for; [requestPermission] asks at a moment that makes sense instead
    // (enabling notifications, or the first launch that has an identity).
    const iosSettings = DarwinInitializationSettings(
      requestSoundPermission: false,
      requestBadgePermission: false,
      requestAlertPermission: false,
    );
    const settings =
        InitializationSettings(android: androidSettings, iOS: iosSettings);
    await _notifications.initialize(
      settings,
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

  /// Asks the OS for permission to post notifications, showing the system
  /// prompt the first time. Returns what the OS decided.
  ///
  /// Android: POST_NOTIFICATIONS (API 33+; older versions report granted).
  /// iOS: alert + badge + sound authorization. On both, a user who has already
  /// answered gets no second prompt — the OS returns the standing answer, so
  /// this is safe to call whenever notifications are switched on.
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
        // Null means the plugin could not ask (no attached activity); fall back
        // to what the OS reports, which is the truth that matters.
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

  /// What the OS currently allows, without prompting. Used to tell the user
  /// their notifications are switched on in the app but blocked by the system.
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

  /// Requests permission only when the OS has not already granted it, so a
  /// caller can be sure notifications are deliverable without re-prompting a
  /// user who said yes long ago.
  Future<NotificationPermission> ensurePermission() async {
    final status = await permissionStatus();
    if (status == NotificationPermission.granted) return status;
    return requestPermission();
  }

  /// Posts a notification.
  ///
  /// [conversationKey] is the conversation this belongs to (PM peer, group id,
  /// channel). Passing one makes the notification REPLACE the previous one for
  /// that conversation instead of stacking a fresh copy per message, and groups
  /// the conversation's notifications together on both platforms — the
  /// behaviour every messaging app has. Without one, each call stacks.
  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
    String? conversationKey,
    NotificationKind kind = NotificationKind.message,
  }) async {
    if (!isSupported) return;
    await initialize();

    // A stable per-conversation id updates the existing notification; anything
    // unkeyed falls back to a unique id so it cannot silently replace another.
    final notificationId = conversationKey == null || conversationKey.isEmpty
        ? _generateUniqueId()
        : conversationKey.hashCode & 0x7fffffff;

    final channel = _channelFor(kind);
    final androidDetails = AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: channel.importance,
      priority: kind == NotificationKind.activity
          ? Priority.defaultPriority
          : Priority.high,
      enableVibration: kind != NotificationKind.activity,
      playSound: true,
      // Long messages are readable when expanded instead of ellipsized.
      styleInformation: BigTextStyleInformation(body, contentTitle: title),
      // Tapping dismisses; the app routes to the conversation from the payload.
      autoCancel: true,
      groupKey: conversationKey,
      // The lock screen shows that a message arrived, not what it said —
      // decrypted content should not be readable over someone's shoulder.
      visibility: NotificationVisibility.private,
    );
    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      // iOS groups by thread, which is how a conversation stays one stack.
      threadIdentifier: conversationKey,
    );
    final details =
        NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _notifications.show(notificationId, title, body, details,
        payload: payload);
  }

  /// Clears the notification(s) for a conversation the user has now read.
  Future<void> cancelConversation(String conversationKey) async {
    if (!isSupported || conversationKey.isEmpty) return;
    try {
      await _notifications.cancel(conversationKey.hashCode & 0x7fffffff);
    } catch (_) {
      // Nothing posted for it / plugin unavailable.
    }
  }

  /// Android notification channels, one per [NotificationKind], so the user can
  /// silence reactions without silencing PMs. A channel's importance is fixed
  /// at creation by Android, which is why these are distinct ids rather than
  /// one channel whose importance we vary.
  _Channel _channelFor(NotificationKind kind) {
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
    // Combine counter with random component to ensure uniqueness
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

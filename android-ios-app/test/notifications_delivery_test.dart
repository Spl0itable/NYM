// The chain from a decrypted event to an OS notification: what `notify()`
// hands the platform layer, and the gates it applies on the way.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/features/notifications/notification_routing.dart';
import 'package:nym_bar/features/notifications/notifications_service.dart';
import 'package:nym_bar/services/notification_service.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for the platform layer so the test sees exactly what would be
/// handed to flutter_local_notifications.
class _FakeLocal implements NotificationService {
  final posted = <Map<String, Object?>>[];
  final cancelled = <String>[];
  final _payloads = StreamController<String>.broadcast();

  @override
  Stream<String> get payloadStream => _payloads.stream;

  @override
  String? takeInitialPayload() => null;

  @override
  Future<void> initialize() async {}

  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.granted;

  @override
  Future<NotificationPermission> permissionStatus() async =>
      NotificationPermission.granted;

  @override
  Future<NotificationPermission> ensurePermission() async =>
      NotificationPermission.granted;

  @override
  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
    String? conversationKey,
    NotificationKind kind = NotificationKind.message,
  }) async {
    posted.add({
      'title': title,
      'body': body,
      'payload': payload,
      'conversationKey': conversationKey,
      'kind': kind,
    });
  }

  @override
  Future<void> cancelConversation(String conversationKey) async =>
      cancelled.add(conversationKey);
}

class _SilentPlayer implements TonePlayer {
  @override
  Future<void> play(String name, Uint8List wav) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const peer =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  late ProviderContainer container;
  late _FakeLocal local;
  late NotificationsService svc;

  Future<void> boot({Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(Map<String, Object>.from(prefs));
    final kv = await KeyValueStore.open();
    container = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(kv)],
    );
    addTearDown(container.dispose);
    local = _FakeLocal();
    late NotificationsService built;
    final probe = Provider<NotificationsService>((ref) {
      built = NotificationsService(ref, local: local, player: _SilentPlayer());
      return built;
    });
    container.read(probe);
    svc = built;
  }

  test('a PM notification carries its tap route and conversation key',
      () async {
    await boot();
    await svc.notify(
      title: 'alice',
      body: 'hello from a PM',
      context: NotifyContext(
        senderPubkey: peer,
        eventId: 'evt-1',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        payload: encodeNotificationPayload(
            type: 'pm', route: peer, senderPubkey: peer),
        conversationKey:
            notificationConversationKey(historyType: 'pm', route: peer),
        kind: NotificationKind.message,
      ),
    );

    expect(local.posted, hasLength(1));
    final n = local.posted.single;
    expect(n['title'], 'alice');
    expect(n['body'], 'hello from a PM');
    expect(n['kind'], NotificationKind.message);
    // Tapping it must be able to open the conversation — a null payload was
    // what made a tapped notification land nowhere.
    final decoded = decodeNotificationPayload(n['payload']! as String)!;
    expect(decoded.type, 'pm');
    expect(decoded.route, peer);
    // …and a second message from the same peer replaces this entry.
    expect(n['conversationKey'], 'pm:$peer');
  });

  test('a quote reply shows the reply, not the quoted message', () async {
    // The raw content leads with the recipient's own words; a notification that
    // previewed those would say nothing about what was actually replied.
    expect(
      notificationBodyFor('> @luxas#ab12: my original message\n\nnice one'),
      'nice one',
    );
    expect(
      notificationBodyFor('> @luxas: a\n> b\n\nagreed, and more'),
      'agreed, and more',
    );
    // A bare quote with no reply text keeps its content rather than going out
    // with an empty body.
    expect(
      notificationBodyFor('> @luxas#ab12: just this'),
      '> @luxas#ab12: just this',
    );
    expect(notificationBodyFor('plain message'), 'plain message');
  });

  test('notifications disabled in-app posts nothing', () async {
    await boot(prefs: {StorageKeys.notificationsEnabled: 'false'});
    await svc.notify(
      title: 'alice',
      body: 'hello',
      context: NotifyContext(
        senderPubkey: peer,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    expect(local.posted, isEmpty);
  });

  test('a message older than the alert window posts nothing', () async {
    await boot();
    await svc.notify(
      title: 'alice',
      body: 'yesterday',
      context: NotifyContext(
        senderPubkey: peer,
        eventId: 'old-1',
        timestampMs: DateTime.now()
            .subtract(const Duration(hours: 25))
            .millisecondsSinceEpoch,
      ),
    );
    expect(local.posted, isEmpty);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/notifications/notification_routing.dart';
import 'package:nym_bar/services/notification_service.dart';

/// Records where a tapped notification would open.
class _RecordingTarget implements NotificationRouteTarget {
  String? channel;
  String? pm;
  String? group;
  String? thread;

  /// Order matters: a thread only opens once its conversation has, so the
  /// recorder keeps the sequence rather than just the last call.
  final List<String> calls = [];

  @override
  void openChannel(String c) {
    channel = c;
    calls.add('channel');
  }

  @override
  void openPM(String pubkey) {
    pm = pubkey;
    calls.add('pm');
  }

  @override
  void openGroup(String groupId) {
    group = groupId;
    calls.add('group');
  }

  @override
  void openThread(String threadRoot) {
    thread = threadRoot;
    calls.add('thread');
  }
}

void main() {
  const peer =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const root =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  group('notification tap payload', () {
    test('round-trips the fields the routing needs', () {
      final payload = encodeNotificationPayload(
        type: 'pm',
        route: peer,
        senderPubkey: peer,
      );
      final decoded = decodeNotificationPayload(payload)!;
      expect(decoded.type, 'pm');
      expect(decoded.route, peer);
      expect(decoded.senderPubkey, peer);
    });

    test('survives empty route/sender halves', () {
      final decoded =
          decodeNotificationPayload(encodeNotificationPayload(type: 'group'))!;
      expect(decoded.type, 'group');
      expect(decoded.route, '');
      expect(decoded.senderPubkey, '');
    });

    test('carries the thread a notification came from', () {
      final decoded = decodeNotificationPayload(encodeNotificationPayload(
        type: 'channel',
        route: 'u4pruy',
        senderPubkey: peer,
        threadRoot: root,
      ))!;
      expect(decoded.threadRoot, root);
    });

    test('a payload written before threads still decodes', () {
      // The thread half is read positionally, so an older three-field payload
      // must decode to "no thread" rather than throwing.
      final decoded = decodeNotificationPayload('nymnotif:pm|$peer|$peer')!;
      expect(decoded.type, 'pm');
      expect(decoded.route, peer);
      expect(decoded.threadRoot, '');
    });

    test('ignores anything that is not one of ours', () {
      // Deep-link URLs reach the same tap handler and must fall through to it.
      expect(decodeNotificationPayload('https://nymchat.app/#9q8y'), isNull);
      expect(decodeNotificationPayload(''), isNull);
      expect(decodeNotificationPayload('nymnotif:'), isNull);
    });
  });

  group('openNotificationRoute', () {
    test('a PM opens the sender conversation', () {
      final t = _RecordingTarget();
      expect(
        openNotificationRoute(
            const NotificationRoute(type: 'pm', route: peer, senderPubkey: peer),
            t),
        true,
      );
      expect(t.pm, peer);
      expect(t.group, isNull);
      expect(t.channel, isNull);
    });

    test('a group message opens the group, not the sender', () {
      final t = _RecordingTarget();
      openNotificationRoute(
        const NotificationRoute(
            type: 'group', route: 'group-123', senderPubkey: peer),
        t,
      );
      expect(t.group, 'group-123');
      expect(t.pm, isNull);
    });

    test('a channel mention opens the channel', () {
      final t = _RecordingTarget();
      openNotificationRoute(
        const NotificationRoute(
            type: 'channel', route: '9q8y', senderPubkey: peer),
        t,
      );
      expect(t.channel, '9q8y');
      expect(t.pm, isNull);
    });

    test('a reaction opens the reactor PM', () {
      final t = _RecordingTarget();
      openNotificationRoute(
        const NotificationRoute(type: 'reaction', senderPubkey: peer),
        t,
      );
      expect(t.pm, peer);
    });

    test('a call routes by what its route holds', () {
      final byPeer = _RecordingTarget();
      openNotificationRoute(
          const NotificationRoute(type: 'call', route: peer), byPeer);
      expect(byPeer.pm, peer);

      final byGroup = _RecordingTarget();
      openNotificationRoute(
          const NotificationRoute(type: 'call', route: 'group-9'), byGroup);
      expect(byGroup.group, 'group-9');
    });

    test('a thread notification opens the thread, after its conversation', () {
      final t = _RecordingTarget();
      expect(
        openNotificationRoute(
          const NotificationRoute(
              type: 'channel', route: 'u4pruy', threadRoot: root),
          t,
        ),
        isTrue,
      );
      expect(t.channel, 'u4pruy');
      expect(t.thread, root);
      // The thread view takes over the conversation's message list, so the
      // conversation has to be open first.
      expect(t.calls, ['channel', 'thread']);
    });

    test('a PM/group thread notification opens its thread too', () {
      final pmTarget = _RecordingTarget();
      openNotificationRoute(
        const NotificationRoute(type: 'pm', route: peer, threadRoot: root),
        pmTarget,
      );
      expect(pmTarget.calls, ['pm', 'thread']);

      final groupTarget = _RecordingTarget();
      openNotificationRoute(
        const NotificationRoute(type: 'group', route: 'g1', threadRoot: root),
        groupTarget,
      );
      expect(groupTarget.calls, ['group', 'thread']);
    });

    test('an ordinary message opens no thread', () {
      final t = _RecordingTarget();
      openNotificationRoute(
        const NotificationRoute(type: 'channel', route: 'u4pruy'),
        t,
      );
      expect(t.thread, isNull);
      expect(t.calls, ['channel']);
    });

    test('a route that opens nothing never opens a thread either', () {
      final t = _RecordingTarget();
      expect(
        openNotificationRoute(
          const NotificationRoute(type: 'channel', route: '', threadRoot: root),
          t,
        ),
        isFalse,
      );
      expect(t.calls, isEmpty);
    });

    test('routes nowhere rather than guessing when the target is empty', () {
      final t = _RecordingTarget();
      expect(openNotificationRoute(const NotificationRoute(type: 'pm'), t),
          false);
      expect(openNotificationRoute(const NotificationRoute(type: 'group'), t),
          false);
      expect(t.pm, isNull);
      expect(t.group, isNull);
      expect(t.channel, isNull);
    });
  });

  group('presentation keys', () {
    test('each kind posts on its own Android channel', () {
      // So silencing reactions cannot silence private messages.
      expect(notificationKindFor('pm'), NotificationKind.message);
      expect(notificationKindFor('group'), NotificationKind.message);
      expect(notificationKindFor('channel'), NotificationKind.mention);
      expect(notificationKindFor('mention'), NotificationKind.mention);
      expect(notificationKindFor('reaction'), NotificationKind.activity);
      expect(notificationKindFor('anything-else'), NotificationKind.message);
    });

    test('a conversation key collapses one conversation into one entry', () {
      final first =
          notificationConversationKey(historyType: 'pm', route: peer);
      final second =
          notificationConversationKey(historyType: 'pm', route: peer);
      expect(first, second);
      expect(
        notificationConversationKey(historyType: 'pm', route: peer),
        isNot(notificationConversationKey(historyType: 'group', route: peer)),
      );
    });
  });
}

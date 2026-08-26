import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/features/groups/group_logic.dart';
import 'package:nym_bar/features/pms/pm_logic.dart';
import 'package:nym_bar/models/group.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_mapper.dart';
import 'package:nym_bar/state/app_state.dart';

const _rootId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

NostrEvent _chanMsg(int ts,
        {String? id, List<List<String>> extraTags = const []}) =>
    NostrEvent(
      id: id ?? 'ev_$ts',
      pubkey: 'author_pk',
      createdAt: ts,
      kind: EventKind.namedChannel,
      tags: [
        ['d', 'room'],
        ['n', 'alice'],
        ...extraTags,
      ],
      content: 'msg@$ts',
    );

Message _msg(String id, int ts, {String? threadRoot, String? nymMessageId}) =>
    Message(
      id: id,
      pubkey: 'author_pk',
      author: 'alice',
      content: 'msg',
      createdAt: ts,
      threadRoot: threadRoot,
      nymMessageId: nymMessageId,
    );

void main() {
  const now = 1700000000;

  setUp(() => appThreadsEnabled = true);
  tearDown(() => appThreadsEnabled = true);

  group('channel thread tags (NIP-10 marked e-tag)', () {
    test('a marked root e-tag maps to Message.threadRoot', () {
      final m = EventMapper.channelMessage(
        _chanMsg(now, extraTags: [
          ['e', _rootId, '', 'root'],
        ]),
        selfPubkey: 'self',
      );
      expect(m!.threadRoot, _rootId);
    });

    test('a reply marker is accepted when no root marker exists', () {
      final m = EventMapper.channelMessage(
        _chanMsg(now, extraTags: [
          ['e', _rootId, '', 'reply'],
        ]),
        selfPubkey: 'self',
      );
      expect(m!.threadRoot, _rootId);
    });

    test('unmarked or non-hex e-tags never hide a message behind a root', () {
      final unmarked = EventMapper.channelMessage(
        _chanMsg(now, extraTags: [
          ['e', _rootId],
        ]),
        selfPubkey: 'self',
      );
      expect(unmarked!.threadRoot, isNull);
      final bogus = EventMapper.channelMessage(
        _chanMsg(now, extraTags: [
          ['e', 'not-an-event-id', '', 'root'],
        ]),
        selfPubkey: 'self',
      );
      expect(bogus!.threadRoot, isNull);
    });
  });

  group('PM/group thread tags (nymthread rumor tag)', () {
    test('buildPmRumor threads the marker through extraTags and maps back',
        () {
      final rumor = PmLogic.buildPmRumor(
        selfPubkey: 'sender_pk',
        recipientPubkey: 'peer_pk',
        content: 'a reply',
        nymMessageId: 'REPLY-ID',
        extraTags: [
          ['nymthread', 'ROOT-NYM-ID'],
        ],
      );
      final mapped = PmLogic.mapPmRumor(
        rumor: {
          'kind': rumor.kind,
          'pubkey': rumor.pubkey,
          'created_at': rumor.createdAt,
          'tags': rumor.tags,
          'content': rumor.content,
        },
        wrapId: 'wrap1',
        selfPubkey: 'peer_pk',
        senderVerified: true,
      );
      expect(mapped!.threadRoot, 'ROOT-NYM-ID');
    });

    test('buildGroupMessageRumor carries the nymthread tag', () {
      final group = Group(
        id: 'gid',
        name: 'g',
        members: const ['a_pk', 'b_pk'],
        createdBy: 'a_pk',
      );
      final rumor = GroupLogic.buildGroupMessageRumor(
        group: group,
        selfPubkey: 'a_pk',
        content: 'reply',
        nymMessageId: 'REPLY-ID',
        ephemeralPk: 'eph_pk',
        extraTags: [
          ['nymthread', 'ROOT-NYM-ID'],
        ],
      );
      expect(
        rumor.tags.any((t) => t.length > 1 &&
            t[0] == 'nymthread' &&
            t[1] == 'ROOT-NYM-ID'),
        isTrue,
      );
    });
  });

  group('flat-view filtering (visibleMessagesFor)', () {
    test('replies collapse into their thread when the root is present', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(appStateProvider.notifier)..goLive('self', 'me#0001');
      n.switchView(const ChatView.channel('room'));
      n.state.messages['#room'] = [
        _msg(_rootId, now),
        _msg('b' * 64, now + 1, threadRoot: _rootId),
        _msg('c' * 64, now + 2),
      ];
      final visible = visibleMessagesFor(n.state, '#room');
      expect(visible.map((m) => m.id),
          [_rootId, 'c' * 64]); // reply hidden, order kept
      expect(threadReplyCounts(n.state, '#room')[_rootId], 1);
      expect(
          threadRepliesFor(n.state, '#room', _rootId).single.id, 'b' * 64);
      expect(threadRootMessage(n.state, '#room', _rootId)!.id, _rootId);
    });

    test('a reply whose root is absent still renders inline (never lost)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(appStateProvider.notifier)..goLive('self', 'me#0001');
      n.switchView(const ChatView.channel('room'));
      n.state.messages['#room'] = [
        _msg('b' * 64, now, threadRoot: 'd' * 64),
      ];
      expect(visibleMessagesFor(n.state, '#room').length, 1);
    });

    test('disabling threads restores the classic flat view', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(appStateProvider.notifier)..goLive('self', 'me#0001');
      n.switchView(const ChatView.channel('room'));
      n.state.messages['#room'] = [
        _msg(_rootId, now),
        _msg('b' * 64, now + 1, threadRoot: _rootId),
      ];
      appThreadsEnabled = false;
      expect(visibleMessagesFor(n.state, '#room').length, 2);
      expect(threadReplyCounts(n.state, '#room'), isEmpty);
    });
  });

  group('thread keys and eligibility', () {
    test('PM/group messages key on nymMessageId, channels on the event id',
        () {
      final pm = Message(
          id: 'wrap',
          pubkey: 'p',
          author: 'a',
          content: 'x',
          createdAt: now,
          isPM: true,
          nymMessageId: 'NYM-ID');
      expect(threadKeyForMessage(pm), 'NYM-ID');
      expect(threadKeyForMessage(_msg('e' * 64, now)), 'e' * 64);
    });

    test('optimistic ids and replies are not eligible roots', () {
      expect(threadEligibleRoot(_msg('e' * 64, now)), isTrue);
      expect(threadEligibleRoot(_msg('_optim_x', now)), isFalse);
      expect(
          threadEligibleRoot(_msg('e' * 64, now, threadRoot: _rootId)),
          isFalse);
    });
  });

  test('threadRoot survives the Message JSON round-trip (cache restore)', () {
    final m = _msg('b' * 64, now, threadRoot: _rootId);
    final back = Message.fromJson(m.toJson());
    expect(back.threadRoot, _rootId);
  });
}

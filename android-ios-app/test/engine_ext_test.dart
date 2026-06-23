import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/gift_wrap.dart' as giftwrap;
import 'package:nym_bar/core/crypto/keys.dart' as keys;
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/features/channels/channel_manager.dart';
import 'package:nym_bar/features/polls/poll_logic.dart';
import 'package:nym_bar/features/zaps/zap_logic.dart';
import 'package:nym_bar/models/channel.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

/// Pure engine-extension tests (no sockets): reactions, polls, channel sort,
/// zaps, and call-signal gift-wrap round-trip. Mirrors the PWA behavior in
/// reactions.js / polls.js / channels.js / zaps.js verbatim.

NostrEvent _reaction({
  required String messageId,
  required String emoji,
  required String reactor,
  required int ts,
  bool remove = false,
}) =>
    NostrEvent(
      id: 'rx_${reactor}_${emoji}_$ts',
      pubkey: reactor,
      createdAt: ts,
      kind: 7,
      tags: [
        ['e', messageId],
        ['p', 'author'],
        ['k', '20000'],
        if (remove) ['action', 'remove'],
      ],
      content: emoji,
    );

void main() {
  group('reactions', () {
    test('toggle add then remove updates tally + latest-by-ts wins', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');

      // Two reactors add 🔥, then one removes — count reflects the live set.
      n.ingestEvent(_reaction(
          messageId: 'm1', emoji: '🔥', reactor: 'alice', ts: 100));
      n.ingestEvent(_reaction(
          messageId: 'm1', emoji: '🔥', reactor: 'bob', ts: 101));
      var tally = n.state.reactions['m1']!;
      expect(tally.single.emoji, '🔥');
      expect(tally.single.count, 2);
      expect(tally.single.userReacted, isFalse);

      // An OUT-OF-ORDER stale remove (ts 99 < add ts 100) must be ignored.
      n.ingestEvent(_reaction(
          messageId: 'm1', emoji: '🔥', reactor: 'alice', ts: 99, remove: true));
      expect(n.state.reactions['m1']!.single.count, 2);

      // A newer remove (ts 102 > add ts 100) removes alice.
      n.ingestEvent(_reaction(
          messageId: 'm1', emoji: '🔥', reactor: 'alice', ts: 102, remove: true));
      tally = n.state.reactions['m1']!;
      expect(tally.single.count, 1);

      // Removing the last reactor drops the message entry entirely.
      n.ingestEvent(_reaction(
          messageId: 'm1', emoji: '🔥', reactor: 'bob', ts: 103, remove: true));
      expect(n.state.reactions.containsKey('m1'), isFalse);
    });

    test('self reaction marks userReacted', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.applyReaction(
          messageId: 'm2', emoji: '👍', reactor: 'selfpk', removed: false);
      expect(n.state.reactions['m2']!.single.userReacted, isTrue);
    });

    test('reaction with an unsupported k tag is ignored', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      // k=1 is a plain note from another Nostr app — not one of our message
      // kinds (20000/23333/1059/14), so the reaction must not register.
      n.ingestEvent(NostrEvent(
        id: 'rxbad',
        pubkey: 'alice',
        createdAt: 100,
        kind: 7,
        tags: [
          ['e', 'm9'],
          ['k', '1'],
        ],
        content: '🔥',
      ));
      expect(n.state.reactions.containsKey('m9'), isFalse);

      // A supported k tag (group rumor = 14) does register.
      n.ingestEvent(NostrEvent(
        id: 'rxok',
        pubkey: 'alice',
        createdAt: 101,
        kind: 7,
        tags: [
          ['e', 'm9'],
          ['k', '14'],
        ],
        content: '🔥',
      ));
      expect(n.state.reactions['m9']!.single.count, 1);
    });

    test('reaction from a blocked user is dropped', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.blockUser('mallory');
      n.ingestEvent(_reaction(
          messageId: 'm10', emoji: '👎', reactor: 'mallory', ts: 100));
      expect(n.state.reactions.containsKey('m10'), isFalse);
    });
  });

  group('polls', () {
    NostrEvent pollEvent(String id, String geohash, {int? expiration}) =>
        NostrEvent(
          id: id,
          pubkey: 'creator',
          createdAt: 1000,
          kind: 30078,
          tags: [
            ['d', 'nym-poll-abcd1234'],
            ['t', 'nym-poll'],
            ['n', 'creator#beef'],
            ['g', geohash],
            ['poll_question', 'Best color?'],
            ['poll_option', '0', 'Red'],
            ['poll_option', '1', 'Blue'],
            if (expiration != null) ['expiration', '$expiration'],
          ],
          content: 'Best color?',
        );

    NostrEvent voteEvent(String pollId, String voter, int idx,
            {String id = ''}) =>
        NostrEvent(
          id: id.isEmpty ? 'vote_${voter}_$idx' : id,
          pubkey: voter,
          createdAt: 1001,
          kind: 30078,
          tags: [
            ['d', 'nym-poll-vote-$pollId'],
            ['t', 'nym-poll-vote'],
            ['e', pollId],
            ['n', '$voter#abcd'],
            ['g', '9q8y'],
            ['response', '$idx'],
          ],
          content: '',
        );

    test('publish poll tags shape (PollLogic.buildPollEvent)', () {
      final rumor = PollLogic.buildPollEvent(
        pubkey: 'creator',
        nym: 'creator#beef',
        geohash: '9q8y',
        question: 'Best color?',
        options: ['Red', 'Blue', 'Green'],
        pollId8: 'abcd1234',
        nowSec: 5,
      );
      expect(rumor.kind, 30078);
      expect(rumor.content, 'Best color?');
      expect(rumor.tags[0], ['d', 'nym-poll-abcd1234']);
      expect(rumor.tags[1], ['t', 'nym-poll']);
      expect(rumor.tags[2], ['n', 'creator#beef']);
      expect(rumor.tags[3], ['g', '9q8y']);
      expect(rumor.tags[4], ['poll_question', 'Best color?']);
      expect(rumor.tags[5], ['poll_option', '0', 'Red']);
      expect(rumor.tags[6], ['poll_option', '1', 'Blue']);
      expect(rumor.tags[7], ['poll_option', '2', 'Green']);

      final vote = PollLogic.buildVoteEvent(
        pubkey: 'voter',
        nym: 'voter#abcd',
        geohash: '9q8y',
        pollId: 'pollid',
        optionIndex: 1,
        nowSec: 5,
      );
      expect(vote.tags[0], ['d', 'nym-poll-vote-pollid']);
      expect(vote.tags[1], ['t', 'nym-poll-vote']);
      expect(vote.tags[2], ['e', 'pollid']);
      expect(vote.tags.last, ['response', '1']);
      expect(vote.content, '');
    });

    test('vote dedup: one per pubkey, first wins', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.ingestPoll(pollEvent('p1', '9q8y'));
      n.ingestPollVote(voteEvent('p1', 'alice', 0));
      n.ingestPollVote(voteEvent('p1', 'alice', 1)); // 2nd vote ignored
      expect(n.state.polls['p1']!.votes['alice'], 0);
      expect(n.state.polls['p1']!.votesFor(0), 1);

      // Duplicate event id is deduped before counting.
      n.ingestPollVote(voteEvent('p1', 'bob', 1, id: 'dup'));
      n.ingestPollVote(voteEvent('p1', 'carol', 0, id: 'dup'));
      expect(n.state.polls['p1']!.votes.containsKey('carol'), isFalse);
    });

    test('buffered vote applies when poll arrives', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      // Vote arrives before the poll → buffered.
      n.ingestPollVote(voteEvent('p2', 'alice', 1));
      expect(n.state.polls.containsKey('p2'), isFalse);
      // Poll arrives → buffered vote is replayed.
      n.ingestPoll(pollEvent('p2', '9q8y'));
      expect(n.state.polls['p2']!.votes['alice'], 1);
    });

    test('expired poll/vote are skipped', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 10;
      n.ingestPoll(pollEvent('p3', '9q8y', expiration: past));
      expect(n.state.polls.containsKey('p3'), isFalse);
    });
  });

  group('channel sort', () {
    ChannelEntry ch(String name, {String geohash = ''}) =>
        ChannelEntry(channel: name, geohash: geohash);

    test(
        'priority: nymchat first, active second, pinned band, then activity '
        '(pinned ordered by activity, NOT alphabetically — matches PWA)', () {
      final channels = [
        ch('zebra'),
        ch('nymchat'),
        ch('active-ch'),
        ch('bravo'),
        ch('alpha'),
      ];
      final ctx = ChannelSortContext(
        activeKey: 'active-ch',
        pinned: {'bravo', 'alpha'},
        // Within the pinned band the PWA falls through to activity desc, so
        // bravo (more recent) must sort ahead of alpha even though it is later
        // alphabetically. zebra is unpinned and sorts last.
        lastActivity: {'#bravo': 900, '#alpha': 100, '#zebra': 500},
        unreadCounts: {},
      );
      final sorted = ChannelManager.sortChannels(channels, ctx)
          .map((c) => c.key)
          .toList();
      // nymchat → active → pinned(by activity desc) → unpinned by activity.
      expect(sorted, ['nymchat', 'active-ch', 'bravo', 'alpha', 'zebra']);
    });

    test('proximity sorts geohash channels by distance when enabled', () {
      // SF user; #9q8y (SF) is closer than #u (Europe).
      final channels = [ch('u', geohash: 'u'), ch('9q8y', geohash: '9q8y')];
      final ctx = ChannelSortContext(
        activeKey: '',
        pinned: const {},
        lastActivity: const {},
        unreadCounts: const {},
        sortByProximity: true,
        userLocation: const UserLocation(lat: 37.77, lng: -122.41),
      );
      final sorted = ChannelManager.sortChannels(channels, ctx)
          .map((c) => c.key)
          .toList();
      expect(sorted.first, '9q8y');
    });

    test('activity desc then unread desc tiebreak', () {
      final channels = [ch('a'), ch('b'), ch('c')];
      final ctx = ChannelSortContext(
        activeKey: '',
        pinned: const {},
        lastActivity: {'#a': 100, '#b': 100, '#c': 200},
        unreadCounts: {'#a': 5, '#b': 1},
      );
      final sorted = ChannelManager.sortChannels(channels, ctx)
          .map((c) => c.key)
          .toList();
      expect(sorted, ['c', 'a', 'b']); // c highest activity; a>b on unread
    });

    test('#nymchat can neither be pinned nor hidden (PWA no-op)', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      // togglePin('nymchat') is a no-op: the default channel is never added to
      // the pinned set (channels.js togglePin early-returns for 'nymchat').
      expect(n.togglePin('nymchat'), isFalse);
      expect(n.state.pinnedChannels.contains('nymchat'), isFalse);
      // hideChannel('nymchat') is rejected (toggleHideChannel early-returns).
      expect(n.hideChannel('nymchat'), isFalse);
      expect(n.state.hiddenChannels.contains('nymchat'), isFalse);
      // A normal channel pins/hides as usual.
      n.addChannel('lounge');
      expect(n.togglePin('lounge'), isTrue);
      expect(n.state.pinnedChannels.contains('lounge'), isTrue);
      expect(n.hideChannel('lounge'), isTrue);
      expect(n.state.hiddenChannels.contains('lounge'), isTrue);
    });
  });

  group('zaps', () {
    test('zap-request builder tags (9734, e/p/amount/relays/k)', () {
      final r = ZapLogic.buildZapRequest(
        pubkey: 'me',
        recipientPubkey: 'recip',
        amountSats: 21,
        relays: ['r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6'],
        messageId: 'msg1',
        originalKind: '23333',
        comment: 'nice',
        nowSec: 5,
      );
      expect(r.kind, 9734);
      expect(r.content, 'nice');
      expect(r.tags.first, ['e', 'msg1']);
      expect(r.tags.firstWhere((t) => t[0] == 'p'), ['p', 'recip']);
      expect(r.tags.firstWhere((t) => t[0] == 'amount'),
          ['amount', '21000']); // millisats
      // relays tag capped at 5.
      final relaysTag = r.tags.firstWhere((t) => t[0] == 'relays');
      expect(relaysTag.length, 6); // 'relays' + 5 urls
      expect(r.tags.last, ['k', '23333']);
    });

    test('profile zap omits e tag and tags k=0', () {
      final r = ZapLogic.buildZapRequest(
        pubkey: 'me',
        recipientPubkey: 'recip',
        amountSats: 100,
        relays: const ['r0'],
        nowSec: 5,
      );
      expect(r.tags.any((t) => t[0] == 'e'), isFalse);
      expect(r.tags.last, ['k', '0']);
    });

    test('parseAmountFromBolt11 decodes magnitudes', () {
      expect(ZapLogic.parseAmountFromBolt11('lnbc210n1abc'), 21);
      expect(ZapLogic.parseAmountFromBolt11('lnbc1u1xyz'), 100);
      expect(ZapLogic.parseAmountFromBolt11('notanbolt'), isNull);
    });

    test('receipt bolt11 dedup (lowercased) — no double count', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      NostrEvent receipt(String bolt11, String id) => NostrEvent(
            id: id,
            pubkey: 'provider',
            createdAt: 1000,
            kind: 9735,
            tags: [
              ['e', 'msg1'],
              ['p', 'author'],
              ['bolt11', bolt11],
            ],
            content: '',
          );
      n.ingestZapReceipt(receipt('LNBC210N1ABC', 'r1'));
      // Same payment echoed with a different case + event id → deduped.
      n.ingestZapReceipt(receipt('lnbc210n1abc', 'r2'));
      final z = n.state.zaps['msg1']!;
      expect(z.totalSats, 21);
      expect(z.zapperCount, 1);
    });
  });

  group('call signaling', () {
    test('kind-25053 rumor round-trips through gift-wrap unwrap', () async {
      final senderSk = keys.generatePrivateKey();
      final senderPub = keys.getPublicKeyHex(senderSk);
      final recipSk = keys.generatePrivateKey();
      final recipPub = keys.getPublicKeyHex(recipSk);

      final rumor = UnsignedEvent(
        pubkey: senderPub,
        createdAt: 1000,
        kind: 25053,
        tags: [
          ['p', recipPub],
        ],
        content: '{"type":"offer","sdp":"v=0"}',
      );

      final wrap = giftwrap.nip59Wrap(
        rumor: rumor,
        senderPrivkey: senderSk,
        recipientPubkey: recipPub,
      );
      expect(wrap.kind, 1059);

      final res = await giftwrap.unwrapGiftWrap(wrap, [
        (sk: recipSk, bitchat: false),
      ]);
      expect(res, isNotNull);
      expect((res!.rumor['kind'] as num).toInt(), 25053);
      expect(res.rumor['content'], '{"type":"offer","sdp":"v=0"}');
      // NIP-59 seal authenticity: seal.pubkey == rumor author.
      expect(res.seal.pubkey, senderPub);
      expect(res.rumor['pubkey'], senderPub);
      expect(schnorr.verifyEvent(res.seal), isTrue);
    });
  });
}

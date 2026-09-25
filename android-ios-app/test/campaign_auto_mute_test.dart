import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/features/globe/geohash_channel.dart';
import 'package:nym_bar/features/messages/cross_content_flood.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

NostrEvent _geo(String id, String content,
        {required String pubkey, required int createdAtSec}) =>
    NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAtSec,
      kind: EventKind.geoChannel,
      tags: [
        ['g', 'dr5r'],
        ['n', 'someone'],
      ],
      content: content,
    );

void main() {
  const self = 'self_pk';
  int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  String para(int n) =>
      'yep the same long paragraph that keeps coming round the channel every '
      'minute with a fresh nonce on the end and nothing else changed ghdr5c${n}n15';

  AppStateNotifier fresh() {
    crossContentFlood = CrossContentFlood();
    return AppStateNotifier()
      ..goLive(self, 'me#0001')
      ..setProxyMode(false);
  }

  int visible(AppStateNotifier n) =>
      n.state.messages['#dr5r']
          ?.where((m) => !n.state.isMessageFiltered(m))
          .length ??
      0;

  group('campaign auto-mute through channel ingest', () {
    test('the fourth copy is dropped, the key is muted, earlier copies hide',
        () {
      final n = fresh();
      final muted = <String>[];
      n.onAutoMuted = (pk, _) => muted.add(pk);
      final t = nowSec();
      for (var i = 0; i < 3; i++) {
        n.ingestEvent(_geo('e$i', para(694 + i),
            pubkey: 'aubrey', createdAtSec: t - 120 + i * 30));
      }
      expect(n.state.messages['#dr5r']!.length, 2);
      expect(muted, ['aubrey']);
      expect(n.state.isAutoMuted('aubrey'), isTrue);
      expect(visible(n), 0);
      n.ingestEvent(_geo('e3', para(697), pubkey: 'aubrey', createdAtSec: t));
      n.ingestEvent(_geo('e4', 'something new entirely',
          pubkey: 'aubrey', createdAtSec: t));
      expect(n.state.messages['#dr5r']!.length, 2);
      expect(muted.length, 1, reason: 'an extension is not a new mute');
    });

    test('a backfilled wall is not exempt', () {
      final n = fresh();
      final t = nowSec();
      for (var i = 0; i < 4; i++) {
        n.ingestEvent(
            _geo('h$i', para(1331 + i),
                pubkey: 'izzy', createdAtSec: t - 3600 + i * 30),
            historical: true);
      }
      expect(n.state.isAutoMuted('izzy'), isTrue);
      expect(visible(n), 0);
    });

    test('friends, verified bots and self are never muted', () {
      final n = fresh();
      n.state.friends.add('pal');
      final t = nowSec();
      for (var i = 0; i < 6; i++) {
        n.ingestEvent(
            _geo('f$i', para(i), pubkey: 'pal', createdAtSec: t - 60 + i * 5));
      }
      expect(n.state.isAutoMuted('pal'), isFalse);
      expect(n.state.messages['#dr5r']!.length, 6);
      expect(n.autoMuteUser(self), isFalse);
      expect(n.autoMuteUser('pal'), isFalse);
    });

    test('a manual unblock, an expiry and hydration', () {
      final n = fresh();
      expect(n.autoMuteUser('spammer'), isTrue);
      expect(n.autoMuteUser('spammer'), isFalse);
      expect(n.state.isAutoMuted('spammer'), isTrue);
      expect(n.clearAutoMute('spammer'), isTrue);
      expect(n.state.isAutoMuted('spammer'), isFalse);

      final past = DateTime.now().subtract(const Duration(hours: 25));
      n.autoMuteUser('lapsed', now: past);
      expect(n.state.isAutoMuted('lapsed'), isFalse);

      final soon = DateTime.now().millisecondsSinceEpoch + 60000;
      n.hydrateAutoMuted({'kept': soon, 'gone': soon - 120000});
      expect(n.state.isAutoMuted('kept'), isTrue);
      expect(n.state.autoMutedUsers.containsKey('gone'), isFalse);
    });

    test('a nonce-stamped short line is caught from the same key', () {
      final n = fresh();
      final t = nowSec();
      for (var i = 0; i < 7; i++) {
        n.ingestEvent(_geo('s$i', 'message gh6gc8${3 + i}n1',
            pubkey: 'wren', createdAtSec: t - 420 + i * 60));
      }
      expect(n.state.isAutoMuted('wren'), isTrue);
      expect(n.state.messages['#dr5r']!.length, 3);
      expect(visible(n), 0);
    });

    test('muting a key takes its messages out of the badge and the sort',
        () {
      final n = fresh();
      n.switchView(const ChatView.channel('elsewhere'));
      final t = nowSec();
      n.ingestEvent(
          _geo('ok', 'a normal line', pubkey: 'yara', createdAtSec: t - 600));
      final before = n.state.channelLastActivity['#dr5r'];
      expect(before, (t - 600) * 1000);
      for (var i = 0; i < 3; i++) {
        n.ingestEvent(_geo('sp$i', para(50 + i),
            pubkey: 'aubrey', createdAtSec: t - 120 + i * 30));
      }
      expect(n.state.isAutoMuted('aubrey'), isTrue);
      expect(n.state.unreadCounts['#dr5r'], 1);
      expect(n.state.channelLastActivity['#dr5r'], before);
    });

    test('blocking a key does the same', () {
      final n = fresh();
      n.switchView(const ChatView.channel('elsewhere'));
      final t = nowSec();
      n.ingestEvent(
          _geo('ok', 'a normal line', pubkey: 'yara', createdAtSec: t - 600));
      n.ingestEvent(_geo('b1', 'hi there', pubkey: 'blocky', createdAtSec: t));
      expect(n.state.unreadCounts['#dr5r'], 2);
      expect(n.state.channelLastActivity['#dr5r'], t * 1000);
      n.blockUser('blocky');
      expect(n.state.unreadCounts['#dr5r'], 1);
      expect(n.state.channelLastActivity['#dr5r'], (t - 600) * 1000);
    });

    test('a hidden message neither raises activity nor lists a channel', () {
      final n = fresh();
      n.switchView(const ChatView.channel('elsewhere'));
      n.blockUser('blocky');
      final t = nowSec();
      n.ingestEvent(NostrEvent(
        id: 'g1',
        pubkey: 'blocky',
        createdAt: t,
        kind: EventKind.geoChannel,
        tags: [
          ['g', 'u4pr'],
          ['n', 'someone'],
        ],
        content: 'hello there',
      ));
      expect(n.state.channelLastActivity.containsKey('#u4pr'), isFalse);
      expect(n.state.channels.any((c) => c.key == 'u4pr'), isFalse);
      expect(n.state.unreadCounts['#u4pr'], isNull);
    });

    test('a muted key does not heat the map', () {
      final n = fresh();
      final t = nowSec();
      n.ingestEvent(
          _geo('m0', 'a normal line', pubkey: 'yara', createdAtSec: t - 60));
      for (var i = 0; i < 5; i++) {
        n.ingestEvent(_geo('mx$i', 'message gh6gc8${3 + i}n1',
            pubkey: 'wren', createdAtSec: t - 50 + i));
      }
      int heat() => buildGeohashChannels(n.state, windowHours: 24)
          .firstWhere((p) => p.geohash == 'dr5r')
          .messages;
      expect(n.state.isAutoMuted('wren'), isTrue);
      expect(heat(), 1);
      n.clearAutoMute('wren');
      expect(heat(), 4);
    });

    test('a muted key does not count toward unread', () {
      final n = fresh();
      final t = nowSec();
      n.ingestEvent(_geo('u0', para(1), pubkey: 'x', createdAtSec: t));
      final m = n.state.messages['#dr5r']!.single;
      expect(n.state.countsTowardUnread(m), isTrue);
      n.autoMuteUser('x');
      expect(n.state.countsTowardUnread(m), isFalse);
    });
  });
}

/// A geohash channel must read as one wherever it was registered from.
///
/// Registration happens from a dozen places and several only ever have the
/// channel NAME — a Bluetooth-mesh delivery, a synced joined-key list, a column
/// seed, the named-channel discovery pass. Whichever landed first decided the
/// entry for the rest of the session, so the sidebar said "Not a geohash" for a
/// real geohash channel (and its typing/receipt events went out on the named
/// `d` tag) depending only on which transport got there first.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/channel.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/state/app_state.dart';

ChannelEntry _entryFor(AppStateNotifier n, String key) =>
    n.state.channels.firstWhere((c) => c.key == key);

Message _meshMsg(String channel) => Message(
      id: 'mesh-1',
      author: 'peer',
      pubkey: 'p' * 64,
      content: 'gm',
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      channel: channel,
      eventKind: 20000,
      viaMesh: true,
    );

void main() {
  group('geohash identity', () {
    test('an explicit geohash is kept', () {
      final e = ChannelEntry(channel: 'u4pruy', geohash: 'u4pruy');
      expect(e.isGeohash, isTrue);
      expect(e.geohashKey, 'u4pruy');
      expect(e.key, 'u4pruy');
      expect(e.storageKey, '#u4pruy');
    });

    test('a name-only registration still reads as a geohash', () {
      final e = ChannelEntry(channel: 'u4pruy');
      expect(e.isGeohash, isTrue,
          reason: 'the name IS the geohash — the caller just had no field '
              'to put it in');
      expect(e.geohashKey, 'u4pruy');
      expect(e.key, 'u4pruy', reason: 'identity is unchanged');
      expect(e.storageKey, '#u4pruy');
    });

    test('a named channel stays named', () {
      final e = ChannelEntry(channel: 'bitcoin');
      expect(e.isGeohash, isFalse, reason: 'i and o are not geohash digits');
      expect(e.geohashKey, '');
      expect(e.key, 'bitcoin');
    });

    test('the default channel is never a geohash', () {
      final e = ChannelEntry(channel: kDefaultChannel);
      expect(e.isGeohash, isFalse);
      expect(e.geohashKey, '');
    });

    test('a bogus geohash field does not make a named channel geographic', () {
      // The synced-settings apply used to stamp every joined key as a geohash.
      final e = ChannelEntry(channel: 'bitcoin', geohash: 'bitcoin');
      expect(e.isGeohash, isFalse);
      expect(e.geohashKey, '');
      expect(e.key, 'bitcoin', reason: 'identity survives the correction');
    });

    test('it agrees with the wire, always', () {
      for (final name in ['u4pruy', 'bitcoin', 'nymchat', '9q8y', 'dev']) {
        expect(ChannelEntry(channel: name).isGeohash, channelWire(name).isGeohash,
            reason: '$name must render as whatever it is sent as');
      }
    });
  });

  // The PWA's equivalent fix broke every named channel: there, the geohash
  // field doubles as the row's ROUTING key, so deriving it emptied the key for
  // kind-23333 channels — their storage key stopped matching `#name` and their
  // posts fell back to #nymchat. Here `key`/`storageKey` are derived from the
  // same answer, so they must come out byte-identical to the old
  // `geohash.isNotEmpty` rule for every shape of entry.
  group('identity is untouched by the derivation', () {
    const cases = <List<String>>[
      ['bitcoin', 'bitcoin'],
      ['bitcoin', ''],
      ['u4pruy', 'u4pruy'],
      ['u4pruy', ''],
      [kDefaultChannel, ''],
      [kDefaultChannel, kDefaultChannel],
      ['dev', 'dev'],
      ['dev', ''],
      ['crew', ''],
      ['news', 'news'],
    ];

    for (final c in cases) {
      final label = '${c[0]}/${c[1].isEmpty ? '-' : c[1]}';
      test('$label keys the same as before', () {
        final e = ChannelEntry(channel: c[0], geohash: c[1]);
        final wasGeo = c[1].isNotEmpty;
        expect(e.key, (wasGeo ? c[1] : c[0]).toLowerCase());
        expect(e.storageKey, '#${wasGeo ? c[1] : c[0]}');
      });
    }

    test('and every entry routes on the kind its key implies', () {
      for (final c in cases) {
        final e = ChannelEntry(channel: c[0], geohash: c[1]);
        expect(e.isGeohash, channelWire(e.key).isGeohash,
            reason: '${c[0]}/${c[1]} must render as what it is sent as');
      }
    });
  });

  group('registration paths agree', () {
    test('a mesh-delivered geohash channel is not registered as named', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.ingestMeshChannelMessage(_meshMsg('u4pruy'), channelKey: '#u4pruy');
      expect(_entryFor(n, 'u4pruy').isGeohash, isTrue);
    });

    test('and a mesh-delivered named channel is not made geographic', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.ingestMeshChannelMessage(_meshMsg('bitcoin'), channelKey: '#bitcoin');
      expect(_entryFor(n, 'bitcoin').isGeohash, isFalse);
    });

    test('a name-only addChannel matches a geohash-passing one', () {
      final a = AppStateNotifier()..goLive('selfpk', 'me#0001');
      a.addChannel('u4pruy');
      final b = AppStateNotifier()..goLive('selfpk', 'me#0001');
      b.addChannel('u4pruy', geohash: 'u4pruy');
      expect(_entryFor(a, 'u4pruy').isGeohash, _entryFor(b, 'u4pruy').isGeohash);
      expect(_entryFor(a, 'u4pruy').geohashKey,
          _entryFor(b, 'u4pruy').geohashKey);
    });

    test('whichever transport arrives first, the answer is the same', () {
      // Mesh first, then the relay copy.
      final meshFirst = AppStateNotifier()..goLive('selfpk', 'me#0001');
      meshFirst.ingestMeshChannelMessage(_meshMsg('u4pruy'),
          channelKey: '#u4pruy');
      meshFirst.addChannel('u4pruy', geohash: 'u4pruy');

      // Relay first, then the mesh copy.
      final relayFirst = AppStateNotifier()..goLive('selfpk', 'me#0001');
      relayFirst.addChannel('u4pruy', geohash: 'u4pruy');
      relayFirst.ingestMeshChannelMessage(_meshMsg('u4pruy'),
          channelKey: '#u4pruy');

      expect(_entryFor(meshFirst, 'u4pruy').isGeohash, isTrue);
      expect(_entryFor(relayFirst, 'u4pruy').isGeohash, isTrue);
      expect(meshFirst.state.channels.where((c) => c.key == 'u4pruy').length, 1,
          reason: 'and it is still one channel, not two');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/core/utils/nym_utils.dart';
import 'package:nym_bar/models/channel.dart';
import 'package:nym_bar/models/message.dart';

void main() {
  group('Channel wire', () {
    test('geohash channel maps to kind 20000 / g tag', () {
      final w = channelWire('u10h8');
      expect(w.isGeohash, true);
      expect(w.kind, EventKind.geoChannel);
      expect(w.tag, 'g');
    });

    test('named channel maps to kind 23333 / d tag', () {
      final w = channelWire('bitcoin');
      expect(w.isGeohash, false);
      expect(w.kind, EventKind.namedChannel);
      expect(w.tag, 'd');
    });

    test('default #nymchat is treated as a named channel', () {
      final w = channelWire('nymchat');
      expect(w.isGeohash, false);
      expect(w.kind, EventKind.namedChannel);
    });

    test('isValidGeohash rejects a/i/l/o and >12 chars', () {
      expect(isValidGeohash('u10h8'), true);
      expect(isValidGeohash('aaa'), false); // 'a' not in alphabet
      expect(isValidGeohash('0123456789bcd'), false); // 13 chars
    });
  });

  group('Geohash codec', () {
    test('encode/decode round-trips near the original point', () {
      // San Francisco ~ 9q8yy
      final gh = encodeGeohash(37.7749, -122.4194, precision: 7);
      final c = decodeGeohash(gh);
      expect((c.lat - 37.7749).abs() < 0.05, true);
      expect((c.lng - (-122.4194)).abs() < 0.05, true);
    });

    test('known geohash prefix decodes near SF', () {
      final c = decodeGeohash('9q8yy');
      expect((c.lat - 37.75).abs() < 0.2, true);
      expect((c.lng + 122.4).abs() < 0.3, true);
    });
  });

  group('Haversine', () {
    test('SF to NYC is ~4130 km', () {
      final d = calculateDistance(37.7749, -122.4194, 40.7128, -74.0060);
      expect(d > 4000 && d < 4200, true);
    });
  });

  group('Nym suffix utils', () {
    const pk =
        'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';
    test('suffix is last 4 hex of pubkey', () {
      expect(getPubkeySuffix(pk), 'a8df');
    });
    test('strip removes trailing #xxxx', () {
      expect(stripPubkeySuffix('satoshi#a8df'), 'satoshi');
      expect(stripPubkeySuffix('plain'), 'plain');
    });
    test('display form combines base + suffix', () {
      // a hex suffix is stripped and replaced; a non-hex tail is kept
      expect(getNymFromPubkey('satoshi#0000', pk), 'satoshi#a8df');
      expect(getNymFromPubkey('satoshi', pk), 'satoshi#a8df');
    });
    test('PM conversation key is sorted and pm-prefixed', () {
      final k1 = getPMConversationKey('bbb', 'aaa');
      final k2 = getPMConversationKey('aaa', 'bbb');
      expect(k1, k2);
      expect(k1, 'pm-aaa-bbb');
    });
  });

  group('Message ordering', () {
    Message m(int createdAt, int ms, int seq) => Message(
          id: '$createdAt-$ms-$seq',
          author: 'a',
          pubkey: 'p',
          content: 'c',
          createdAt: createdAt,
          ms: ms,
          seq: seq,
        );
    test('orders by created_at, then ms (when both real), then seq', () {
      expect(compareMessages(m(10, 0, 0), m(11, 0, 0)) < 0, true);
      // `ms` is the FULL millisecond timestamp (Date.now()), > created_at*1000.
      // For created_at=10s the base is 10000ms; a real ms tag exceeds it.
      expect(compareMessages(m(10, 10500, 1), m(10, 10200, 2)) > 0, true);
      // ms ignored when one lacks a real tag (0 or <= created_at*1000):
      // falls back to arrival seq.
      expect(compareMessages(m(10, 0, 1), m(10, 10999, 2)) < 0, true);
      // A ms value at/below the second boundary is NOT a real tag (matches
      // PWA `_hasRealMsTag`): both fall back to seq.
      expect(compareMessages(m(10, 500, 1), m(10, 200, 2)) < 0, true);
      expect(compareMessages(m(10, 10000, 2), m(10, 10000, 1)) > 0, true);
    });
  });
}

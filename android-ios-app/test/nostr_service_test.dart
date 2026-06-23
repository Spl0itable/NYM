import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_mapper.dart';
import 'package:nym_bar/services/nostr/nym_generator.dart';

void main() {
  const self =
      '0000000000000000000000000000000000000000000000000000000000001a2b';
  const other =
      '11111111111111111111111111111111111111111111111111111111deadbeef';

  group('EventMapper.channelMessage', () {
    test('maps a geohash channel message (kind 20000)', () {
      final e = NostrEvent(
        id: 'evt1',
        pubkey: other,
        createdAt: 1700000000,
        kind: EventKind.geoChannel,
        tags: [
          ['n', 'satoshi'],
          ['ms', '1700000000123'],
          ['g', '9q8y'],
        ],
        content: 'hello geohash',
      );
      final m = EventMapper.channelMessage(e, selfPubkey: self);
      expect(m, isNotNull);
      expect(m!.geohash, '9q8y');
      expect(m.channel, isNull);
      expect(m.eventKind, EventKind.geoChannel);
      expect(m.author, 'satoshi#beef'); // suffix = last 4 hex of pubkey
      expect(m.ms, 1700000000123);
      expect(m.isOwn, false);
      expect(EventMapper.channelKeyOf(e), '#9q8y');
    });

    test('maps a named channel message (kind 23333) and detects ownership', () {
      final e = NostrEvent(
        id: 'evt2',
        pubkey: self,
        createdAt: 1700000001,
        kind: EventKind.namedChannel,
        tags: [
          ['n', 'me'],
          ['d', 'bitcoin'],
        ],
        content: 'gm',
      );
      final m = EventMapper.channelMessage(e, selfPubkey: self);
      expect(m, isNotNull);
      expect(m!.channel, 'bitcoin');
      expect(m.isOwn, true);
      expect(EventMapper.channelKeyOf(e), '#bitcoin');
    });

    test('returns null for a non-channel kind', () {
      final e = NostrEvent(
        pubkey: other,
        createdAt: 1700000000,
        kind: EventKind.reaction,
        content: '🔥',
      );
      expect(EventMapper.channelMessage(e, selfPubkey: self), isNull);
    });

    test('returns null when geohash tag is missing', () {
      final e = NostrEvent(
        pubkey: other,
        createdAt: 1700000000,
        kind: EventKind.geoChannel,
        content: 'no g tag',
      );
      expect(EventMapper.channelMessage(e, selfPubkey: self), isNull);
    });
  });

  group('EventMapper.profile', () {
    test('parses kind-0 metadata', () {
      final e = NostrEvent(
        pubkey: other,
        createdAt: 1700000000,
        kind: EventKind.profile,
        content: jsonEncode({
          'name': 'satoshi',
          'about': 'building',
          'picture': 'https://x/y.png',
          'lud16': 'sat@walletofsatoshi.com',
        }),
      );
      final p = EventMapper.profile(e);
      expect(p, isNotNull);
      expect(p!.name, 'satoshi');
      expect(p.lightningAddress, 'sat@walletofsatoshi.com');
      expect(p.kind0Ts, 1700000000);
    });

    test('returns null on invalid JSON', () {
      final e = NostrEvent(
        pubkey: other,
        createdAt: 1,
        kind: EventKind.profile,
        content: 'not json',
      );
      expect(EventMapper.profile(e), isNull);
    });
  });

  group('EventMapper.reaction', () {
    test('parses kind-7 with e tag and remove action', () {
      final add = NostrEvent(
        pubkey: other,
        createdAt: 1,
        kind: EventKind.reaction,
        tags: [
          ['e', 'msg1'],
          ['k', '20000'],
        ],
        content: '🔥',
      );
      final r = EventMapper.reaction(add)!;
      expect(r.messageId, 'msg1');
      expect(r.emoji, '🔥');
      expect(r.removed, false);

      final rem = NostrEvent(
        pubkey: other,
        createdAt: 2,
        kind: EventKind.reaction,
        tags: [
          ['e', 'msg1'],
          ['action', 'remove'],
        ],
        content: '🔥',
      );
      expect(EventMapper.reaction(rem)!.removed, true);
    });
  });

  group('NymGenerator', () {
    test('fancy style produces adjective_noun#suffix', () {
      final g = NymGenerator(Random(42));
      final nym = g.generate(other);
      expect(nym.endsWith('#beef'), true);
      expect(nym.contains('_'), true);
      final base = nym.split('#').first;
      final parts = base.split('_');
      expect(NymGenerator.adjectives.contains(parts[0]), true);
      expect(NymGenerator.nouns.contains(parts[1]), true);
    });

    test('simple style produces nymNNNN#suffix', () {
      final g = NymGenerator(Random(1));
      final nym = g.generate(other, style: 'simple');
      expect(RegExp(r'^nym\d{4}#beef$').hasMatch(nym), true);
    });
  });
}

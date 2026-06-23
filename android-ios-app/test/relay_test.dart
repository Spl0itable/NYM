import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/relay/relay_connection.dart';
import 'package:nym_bar/services/relay/relay_message.dart';
import 'package:nym_bar/services/relay/relay_pool.dart';

void main() {
  group('NostrFilter.toJson', () {
    test('emits kinds, since, and #-prefixed tag keys, omits nulls', () {
      final filter = NostrFilter(
        kinds: [1059, 20000],
        since: 1700000000,
        tags: {
          'p': ['abc'],
          'e': ['def'],
          'k': ['14'],
        },
      );
      final json = filter.toJson();

      expect(json['kinds'], [1059, 20000]);
      expect(json['since'], 1700000000);
      expect(json['#p'], ['abc']);
      expect(json['#e'], ['def']);
      expect(json['#k'], ['14']);

      // Nulls / empties omitted.
      expect(json.containsKey('ids'), isFalse);
      expect(json.containsKey('authors'), isFalse);
      expect(json.containsKey('until'), isFalse);
      expect(json.containsKey('limit'), isFalse);
    });

    test('accepts tag keys with or without leading #', () {
      final filter = NostrFilter(tags: {
        '#g': ['nymchat'],
        'd': ['general'],
      });
      final json = filter.toJson();
      expect(json['#g'], ['nymchat']);
      expect(json['#d'], ['general']);
    });

    test('omits empty tag value lists', () {
      final filter = NostrFilter(kinds: [1], tags: {'p': []});
      final json = filter.toJson();
      expect(json.containsKey('#p'), isFalse);
    });

    test('round-trips through fromJson', () {
      final filter = NostrFilter(
        ids: ['id1'],
        authors: ['au1'],
        kinds: [7],
        since: 100,
        until: 200,
        limit: 10,
        tags: {
          'e': ['ev1'],
          't': ['nym-presence'],
        },
      );
      final back = NostrFilter.fromJson(filter.toJson());
      expect(back.ids, ['id1']);
      expect(back.authors, ['au1']);
      expect(back.kinds, [7]);
      expect(back.since, 100);
      expect(back.until, 200);
      expect(back.limit, 10);
      expect(back.tags['e'], ['ev1']);
      expect(back.tags['t'], ['nym-presence']);
    });
  });

  group('RelayMessage.parse', () {
    test('parses EVENT', () {
      final raw = jsonEncode([
        'EVENT',
        'sub1',
        {
          'id': 'eventid',
          'pubkey': 'pk',
          'created_at': 123,
          'kind': 1,
          'tags': [
            ['p', 'recipient']
          ],
          'content': 'hi',
          'sig': 'sig',
        },
      ]);
      final msg = RelayMessage.parse(raw);
      expect(msg, isA<EventMessage>());
      final em = msg as EventMessage;
      expect(em.subId, 'sub1');
      expect(em.event.id, 'eventid');
      expect(em.event.kind, 1);
      expect(em.event.tags.first, ['p', 'recipient']);
    });

    test('parses OK true/false', () {
      final ok = RelayMessage.parse(jsonEncode(['OK', 'id1', true, '']));
      expect(ok, isA<OkMessage>());
      expect((ok as OkMessage).accepted, isTrue);
      expect(ok.id, 'id1');

      final rejected = RelayMessage.parse(
          jsonEncode(['OK', 'id2', false, 'blocked: pow']));
      expect((rejected as OkMessage).accepted, isFalse);
      expect(rejected.message, 'blocked: pow');
    });

    test('parses EOSE', () {
      final msg = RelayMessage.parse(jsonEncode(['EOSE', 'sub9']));
      expect(msg, isA<EoseMessage>());
      expect((msg as EoseMessage).subId, 'sub9');
    });

    test('parses NOTICE', () {
      final msg = RelayMessage.parse(jsonEncode(['NOTICE', 'rate limited']));
      expect(msg, isA<NoticeMessage>());
      expect((msg as NoticeMessage).message, 'rate limited');
    });

    test('parses CLOSED', () {
      final msg = RelayMessage.parse(
          jsonEncode(['CLOSED', 'sub3', 'auth-required: nope']));
      expect(msg, isA<ClosedMessage>());
      final cm = msg as ClosedMessage;
      expect(cm.subId, 'sub3');
      expect(cm.reason, 'auth-required: nope');
    });

    test('returns null on malformed / unknown frames', () {
      expect(RelayMessage.parse('not json'), isNull);
      expect(RelayMessage.parse('{}'), isNull);
      expect(RelayMessage.parse(jsonEncode([])), isNull);
      expect(RelayMessage.parse(jsonEncode(['WAT', 'x'])), isNull);
    });
  });

  group('Frame building round-trips', () {
    test('REQ round-trips through jsonDecode', () {
      final filter = NostrFilter(kinds: [1], tags: {
        'p': ['me']
      });
      final frame = RelayFrame.req('subA', [filter]);
      final decoded = jsonDecode(frame) as List;
      expect(decoded[0], 'REQ');
      expect(decoded[1], 'subA');
      expect((decoded[2] as Map)['kinds'], [1]);
      expect((decoded[2] as Map)['#p'], ['me']);
    });

    test('EVENT round-trips through jsonDecode', () {
      final event = NostrEvent(
        id: 'evid',
        pubkey: 'pk',
        createdAt: 9,
        kind: 20000,
        tags: [
          ['g', 'nymchat']
        ],
        content: 'hello',
        sig: 'sig',
      );
      final frame = RelayFrame.event(event);
      final decoded = jsonDecode(frame) as List;
      expect(decoded[0], 'EVENT');
      final ev = decoded[1] as Map;
      expect(ev['id'], 'evid');
      expect(ev['kind'], 20000);
      expect(ev['content'], 'hello');
    });

    test('CLOSE round-trips through jsonDecode', () {
      final frame = RelayFrame.close('subZ');
      final decoded = jsonDecode(frame) as List;
      expect(decoded, ['CLOSE', 'subZ']);
    });
  });

  group('computeBackoff', () {
    test('is monotonic up to the cap', () {
      Duration? prev;
      for (var attempt = 0; attempt < 12; attempt++) {
        final d = computeBackoff(
          attempt,
          base: const Duration(milliseconds: 1000),
          cap: const Duration(milliseconds: 30000),
        );
        if (prev != null) {
          expect(d.inMilliseconds, greaterThanOrEqualTo(prev.inMilliseconds));
        }
        prev = d;
      }
    });

    test('respects the cap', () {
      for (var attempt = 0; attempt < 100; attempt++) {
        final d = computeBackoff(
          attempt,
          base: const Duration(milliseconds: 1000),
          cap: const Duration(milliseconds: 30000),
        );
        expect(d.inMilliseconds, lessThanOrEqualTo(30000));
      }
    });

    test('first attempt equals base', () {
      final d = computeBackoff(0,
          base: const Duration(milliseconds: 1000),
          cap: const Duration(milliseconds: 30000));
      expect(d.inMilliseconds, 1000);
    });

    test('grows by the 1.5 factor before the cap', () {
      final a0 = computeBackoff(0, base: const Duration(milliseconds: 1000));
      final a1 = computeBackoff(1, base: const Duration(milliseconds: 1000));
      final a2 = computeBackoff(2, base: const Duration(milliseconds: 1000));
      expect(a1.inMilliseconds, 1500);
      expect(a2.inMilliseconds, 2250);
      expect(a0.inMilliseconds, 1000);
    });

    test('negative attempt clamps to base', () {
      final d = computeBackoff(-5, base: const Duration(milliseconds: 1000));
      expect(d.inMilliseconds, 1000);
    });
  });

  group('EventDeduper', () {
    test('emits an id only once across duplicate sources', () {
      final deduper = EventDeduper();
      // Two fake sources feeding the same event id.
      final fromRelayA = deduper.add('shared-event-id');
      final fromRelayB = deduper.add('shared-event-id');
      expect(fromRelayA, isTrue);
      expect(fromRelayB, isFalse);
      expect(deduper.length, 1);
    });

    test('distinct ids both pass', () {
      final deduper = EventDeduper();
      expect(deduper.add('a'), isTrue);
      expect(deduper.add('b'), isTrue);
      expect(deduper.length, 2);
    });

    test('evicts oldest when over capacity', () {
      final deduper = EventDeduper(maxIds: 3);
      deduper.add('a');
      deduper.add('b');
      deduper.add('c');
      deduper.add('d'); // triggers eviction of 'a'
      expect(deduper.length, 3);
      expect(deduper.contains('a'), isFalse);
      expect(deduper.contains('d'), isTrue);
    });
  });

  group('generateSubId', () {
    test('produces a non-empty base36 string', () {
      final id = generateSubId();
      expect(id, isNotEmpty);
      expect(RegExp(r'^[0-9a-z]+$').hasMatch(id), isTrue);
    });
  });
}

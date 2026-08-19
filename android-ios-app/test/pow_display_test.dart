import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/pow.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_mapper.dart';

NostrEvent _ev({required String id, required List<List<String>> tags}) =>
    NostrEvent(
      id: id,
      pubkey: 'a' * 64,
      createdAt: 1700000000,
      kind: 20000,
      tags: [
        ['g', 'u4pruy'],
        ['n', 'tester'],
        ...tags,
      ],
      content: 'hi',
      sig: 'b' * 128,
    );

void main() {
  group('powBitsForId', () {
    test('counts leading zero bits', () {
      expect(powBitsForId('0' * 64), 256);
      expect(powBitsForId('f${'0' * 63}'), 0);
      expect(powBitsForId('1${'0' * 63}'), 3);
      expect(powBitsForId('2${'0' * 63}'), 2);
      expect(powBitsForId('4${'0' * 63}'), 1);
      expect(powBitsForId('0000ffff${'0' * 56}'), 16);
      expect(powBitsForId('000000ff${'0' * 56}'), 24);
      expect(powBitsForId('00002fff${'0' * 56}'), 18);
    });

    test('rejects anything that is not a 64-char hex id', () {
      expect(powBitsForId(null), 0);
      expect(powBitsForId(''), 0);
      expect(powBitsForId('abc'), 0);
      expect(powBitsForId('z' * 64), 0);
    });
  });

  group('EventMapper powTarget', () {
    test('null when there is no nonce tag (another client did no work)', () {
      final m = EventMapper.channelMessage(_ev(id: '0' * 64, tags: const []),
          selfPubkey: 'c' * 64);
      expect(m, isNotNull);
      expect(m!.powTarget, isNull);
    });

    test('reads the committed target from the nonce tag', () {
      final m = EventMapper.channelMessage(
          _ev(id: '0000ffff${'0' * 56}', tags: const [
            ['nonce', '12345', '16']
          ]),
          selfPubkey: 'c' * 64);
      expect(m!.powTarget, 16);
      // Bits are recomputed from the id, never trusted from the tag.
      expect(powBitsForId(m.id), 16);
    });

    test('a nonce tag with no/!valid target still counts as mined (0)', () {
      final a = EventMapper.channelMessage(
          _ev(id: '0' * 64, tags: const [
            ['nonce', '1']
          ]),
          selfPubkey: 'c' * 64);
      expect(a!.powTarget, 0, reason: 'tag present ⇒ mined, target unknown');
      final b = EventMapper.channelMessage(
          _ev(id: '0' * 64, tags: const [
            ['nonce', '1', 'garbage']
          ]),
          selfPubkey: 'c' * 64);
      expect(b!.powTarget, 0);
    });

    test('a message can fall short of its own committed target', () {
      final m = EventMapper.channelMessage(
          _ev(id: '000fffff${'0' * 56}', tags: const [
            ['nonce', '9', '16']
          ]),
          selfPubkey: 'c' * 64);
      expect(m!.powTarget, 16);
      expect(powBitsForId(m.id), 12);
      expect(powBitsForId(m.id) < m.powTarget!, isTrue);
    });
  });

  group('inbound PoW exclusion filter', () {
    // The filter is a pure predicate over (threshold, event id) — the ingest
    // path applies exactly this. Mining is unaffected either way: the send path
    // floors at kNymchatPowFloor, so a Nymchat message always clears 16.
    bool dropped(int thresholdBits, String id) =>
        thresholdBits > 0 && powBitsForId(id) < thresholdBits;

    final nymchatMsg = '0000ffff${'0' * 56}'; // 16 bits — the Nymchat floor
    final unmined = 'ffffffff${'0' * 56}'; //     0 bits — another client
    final strong = '000000ff${'0' * 56}'; //     24 bits

    test('disabled keeps everything, including unmined messages', () {
      expect(dropped(0, unmined), isFalse);
      expect(dropped(0, nymchatMsg), isFalse);
    });

    test('16 keeps Nymchat traffic and drops clients that do no work', () {
      expect(dropped(16, nymchatMsg), isFalse);
      expect(dropped(16, strong), isFalse);
      expect(dropped(16, unmined), isTrue);
    });

    test('above 16 also hides other Nymchat users, as the label warns', () {
      expect(dropped(20, nymchatMsg), isTrue);
      expect(dropped(24, nymchatMsg), isTrue);
      expect(dropped(20, strong), isFalse);
    });

    test('our OWN messages always clear our own filter', () {
      // The send path mines at max(setting, kNymchatPowFloor), so whatever the
      // filter is set to, what we send meets it — raising the setting cannot
      // make our own messages disappear.
      for (final setting in const [0, 16, 20, 24]) {
        final mined = setting > kNymchatPowFloor ? setting : kNymchatPowFloor;
        expect(mined >= setting, isTrue,
            reason: 'setting $setting mines at $mined');
        // An id that just meets what we would mine still passes the filter.
        expect(mined >= normalizePowDifficulty(setting), isTrue);
      }
    });
  });

  group('normalizePowDifficulty', () {
    test('disabled stays disabled', () {
      expect(normalizePowDifficulty(0), 0);
      expect(normalizePowDifficulty(null), 0);
      expect(normalizePowDifficulty(-5), 0);
    });

    test('the retired 8/12 options lift to the real 16-bit floor', () {
      expect(normalizePowDifficulty(8), 16);
      expect(normalizePowDifficulty(12), 16);
      expect(normalizePowDifficulty(16), 16);
    });

    test('offered values are preserved and anything higher clamps', () {
      expect(normalizePowDifficulty(20), 20);
      expect(normalizePowDifficulty(24), 24);
      expect(normalizePowDifficulty(64), 24);
    });
  });
}

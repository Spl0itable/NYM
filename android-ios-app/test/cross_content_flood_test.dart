import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/pow.dart' show validatedPowBits;
import 'package:nym_bar/features/messages/cross_content_flood.dart';

void main() {
  group('cross-sender content flood', () {
    late CrossContentFlood f;
    final t0 = DateTime.fromMillisecondsSinceEpoch(1000000);
    setUp(() => f = CrossContentFlood());

    const spam =
        'Claim your free airdrop now at this link, limited slots available';

    test('three copies pass, the fourth is held', () {
      expect(f.isFlooding(spam, now: t0), isFalse);
      expect(f.isFlooding(spam, now: t0), isFalse);
      expect(f.isFlooding(spam, now: t0), isFalse);
      expect(f.isFlooding(spam, now: t0), isTrue);
    });

    test('the key is the CONTENT, so a fresh sender does not reset it', () {
      // Nothing here mentions a pubkey. That is the point: the per-pubkey
      // tracker is what a spammer defeats by rotating keys.
      for (var i = 0; i < 3; i++) {
        f.isFlooding(spam, now: t0);
      }
      expect(f.isFlooding(spam, now: t0), isTrue);
    });

    test('it refills at one every two seconds', () {
      for (var i = 0; i < 4; i++) {
        f.isFlooding(spam, now: t0);
      }
      expect(f.isFlooding(spam, now: t0.add(const Duration(seconds: 2))), isFalse);
      expect(f.isFlooding(spam, now: t0.add(const Duration(seconds: 2))), isTrue);
      expect(f.isFlooding(spam, now: t0.add(const Duration(minutes: 1))), isFalse);
    });

    test('a different payload has its own allowance', () {
      for (var i = 0; i < 4; i++) {
        f.isFlooding(spam, now: t0);
      }
      expect(
          f.isFlooding(
              'Completely different message that is also long enough to count',
              now: t0),
          isFalse);
    });

    // The false positives this design has to avoid.
    test('short messages are exempt', () {
      for (final s in ['gm', 'hello everyone', '🎉', 'wb']) {
        for (var i = 0; i < 8; i++) {
          expect(f.isFlooding(s, now: t0), isFalse, reason: s);
        }
      }
    });

    test('empty and null are safe', () {
      expect(f.isFlooding(null, now: t0), isFalse);
      expect(f.isFlooding('', now: t0), isFalse);
    });

    test('per-victim tracking parameters do not split the bucket', () {
      const base = 'Check out this amazing opportunity https://spam.example/x';
      expect(f.isFlooding('$base?ref=aaa', now: t0), isFalse);
      expect(f.isFlooding('$base?ref=bbb', now: t0), isFalse);
      expect(f.isFlooding('$base?ref=ccc', now: t0), isFalse);
      expect(f.isFlooding('$base?ref=ddd', now: t0), isTrue);
    });

    test('case and spacing are not evasion', () {
      const base = 'Buy now before the presale ends and the price goes up';
      expect(f.isFlooding(base, now: t0), isFalse);
      expect(f.isFlooding(base.toUpperCase(), now: t0), isFalse);
      expect(f.isFlooding(base.replaceAll(' ', '   '), now: t0), isFalse);
      expect(f.isFlooding(base, now: t0), isTrue);
    });

    test('the bucket map stays bounded', () {
      final small = CrossContentFlood(maxBuckets: 50);
      for (var i = 0; i < 400; i++) {
        small.isFlooding('distinct payload number $i padded out to length',
            now: t0.add(Duration(milliseconds: i)));
      }
      expect(small.length, lessThanOrEqualTo(50));
    });
  });

  group('validated proof of work', () {
    List<List<String>> nonce(int target) => [
          ['nonce', '1234', '$target']
        ];
    String id(int zeros) => '0' * zeros + 'f' * (64 - zeros);

    test('a met commitment scores its target', () {
      expect(validatedPowBits(nonce(16), id(4)), 16);
    });

    test('an unmet commitment scores nothing', () {
      expect(validatedPowBits(nonce(16), id(2)), 0);
    });

    test('extra luck earns no extra credit', () {
      // The hole this closes: a spammer mining a cheap target produces a lucky
      // high-zero id every so often, and counting zeros alone waves it through.
      expect(validatedPowBits(nonce(8), id(8)), 8);
    });

    test('no nonce tag scores nothing', () {
      expect(validatedPowBits(const [], id(8)), 0);
      expect(validatedPowBits(const [
        ['g', 'u4pruy']
      ], id(8)), 0);
    });

    test('a nonce tag with no target scores nothing', () {
      expect(validatedPowBits(const [
        ['nonce', '1234']
      ], id(8)), 0);
    });

    test('a nonsense or absurd target scores nothing', () {
      expect(validatedPowBits(const [
        ['nonce', '1', 'abc']
      ], id(8)), 0);
      expect(validatedPowBits(nonce(9999), id(16)), 0);
      expect(validatedPowBits(nonce(0), id(16)), 0);
    });

    test('our own 16-bit miner clears a 16-bit floor', () {
      expect(validatedPowBits(nonce(16), id(4)) >= 16, isTrue);
    });

    test('an 8-bit client does not, however lucky', () {
      expect(validatedPowBits(nonce(8), id(2)) >= 16, isFalse);
      expect(validatedPowBits(nonce(8), id(6)) >= 16, isFalse);
    });
  });
}

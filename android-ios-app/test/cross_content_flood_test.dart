import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/pow.dart' show validatedPowBits;
import 'package:nym_bar/features/messages/cross_content_flood.dart';

void main() {
  group('repeated-payload campaign control', () {
    late CrossContentFlood f;
    final t0 = DateTime.fromMillisecondsSinceEpoch(1000000);
    setUp(() => f = CrossContentFlood());

    String para(Object n, String w) =>
        'yep the same long paragraph about the $w thing that keeps coming '
        'round the channel every minute with a fresh nonce on the end ghdr5c${n}n15';
    String link(int n) =>
        'https://news.example/stories/684535056-court-docket-august-24-28'
        '?fbclid=IwY$n ghdr5c${n}n2';
    String short(int n) =>
        'yeah i hear he is still trying to figure it out ghdr5c${n}n3';

    CampaignVerdict at(String text, String pk, int i, {DateTime? base}) {
      final t = (base ?? t0).add(Duration(seconds: 20 * i));
      return f.check(text, pk, createdAtMs: t.millisecondsSinceEpoch, now: t);
    }

    test('a nonce and a swapped word do not make a new payload', () {
      final r = [
        for (var i = 0; i < 5; i++)
          at(para(694 + i, i.isOdd ? 'absolutely' : 'fucking'), 'aubrey', i)
      ];
      expect(r.take(3).any((v) => v.flood), isFalse);
      expect(r[3].flood, isTrue, reason: 'the fourth copy is held');
      expect(r[2].mute, isTrue, reason: 'three from one key mutes it');
    });

    test('a short payload whose nonce sat inside the old hash is caught', () {
      final r = [for (var i = 0; i < 4; i++) at(short(1331 + i), 'izzy', i)];
      expect(r.take(3).any((v) => v.flood), isFalse);
      expect(r[3].flood, isTrue);
    });

    test('a link-only payload is fingerprinted by the link', () {
      final r = [for (var i = 0; i < 4; i++) at(link(1331 + i), 'haley', i)];
      expect(r.take(3).any((v) => v.flood), isFalse);
      expect(r[3].flood, isTrue);
    });

    test('an interleaved rotation is held from the fourth cycle on', () {
      var held = 0;
      final muted = <String>{};
      for (var cycle = 0; cycle < 5; cycle++) {
        for (var p = 0; p < 20; p++) {
          final t = t0.add(Duration(seconds: (cycle * 20 + p) * 3));
          final v = f.check(para('${cycle}x$p', 'topic-$p'), 'persona-$p',
              createdAtMs: t.millisecondsSinceEpoch, now: t);
          if (cycle >= 3 && v.flood) held++;
          if (v.mute) muted.add('persona-$p');
        }
      }
      expect(held, 40);
      expect(muted.length, 20, reason: 'every persona key ends up muted');
    });

    test('a backfilled wall counts by event time', () {
      final now = DateTime.fromMillisecondsSinceEpoch(9000000);
      final r = [
        for (var i = 0; i < 4; i++)
          f.check(para(700 + i, 'x'), 'aubrey',
              createdAtMs: 5000000 + i * 30000, now: now)
      ];
      expect(r[3].flood, isTrue);
      expect(r[2].mute, isTrue);
    });

    test('rotating the key does not rotate the limit', () {
      final r = [
        for (var i = 0; i < 6; i++) at(para(100 + i, 'x'), 'key-$i', i)
      ];
      expect(r[2].flood, isFalse);
      expect(r[3].flood, isTrue);
      expect(r[5].flood, isTrue);
      expect(r.any((v) => v.mute), isFalse,
          reason: 'no key is muted for posting it once');
      final again = at(para(200, 'x'), 'key-0', 7);
      expect(again.mute, isTrue,
          reason: 'a key back for a second copy of a held payload is muted');
    });

    test('the window is fifteen minutes, not two seconds', () {
      for (var i = 0; i < 3; i++) {
        final t = t0.add(Duration(minutes: 4 * i));
        f.check(para(1, 'x'), 'a',
            createdAtMs: t.millisecondsSinceEpoch, now: t);
      }
      final t13 = t0.add(const Duration(minutes: 13));
      expect(
          f
              .check(para(2, 'x'), 'b',
                  createdAtMs: t13.millisecondsSinceEpoch, now: t13)
              .flood,
          isTrue);
      final later = t13.add(const Duration(minutes: 15, milliseconds: 1));
      expect(
          f
              .check(para(3, 'x'), 'b',
                  createdAtMs: later.millisecondsSinceEpoch, now: later)
              .flood,
          isFalse);
    });

    // The false positives this design has to avoid.
    test('short messages are exempt', () {
      for (final s in [
        'gm',
        'hello everyone',
        '🎉',
        'wb',
        'gm gm gm ghdr5c694n15'
      ]) {
        for (var i = 0; i < 8; i++) {
          expect(f.check(s, 'p$i', now: t0).flood, isFalse, reason: s);
        }
      }
    });

    test('a nonce-stamped short line from one key is muted at the fourth', () {
      final r = [
        for (var i = 0; i < 6; i++) at('message gh6gc8${3 + i}n1', 'wren', i)
      ];
      expect(r.take(3).any((v) => v.mute || v.flood), isFalse);
      expect(r[3].mute, isTrue);
      expect(r[3].flood, isTrue);
      expect(r[5].mute, isTrue);
    });

    test('the same stamped line from different keys is not a campaign', () {
      for (var i = 0; i < 6; i++) {
        expect(at('message gh6gc8${3 + i}n1', 'p$i', i).flood, isFalse);
      }
    });

    test('a short line repeated verbatim, or without a stamp, is left alone',
        () {
      for (var i = 0; i < 8; i++) {
        expect(at('day 1', 'k', i).mute, isFalse);
        expect(at('lol', 'k', i).mute, isFalse);
        expect(at('gm gm gm', 'k', i).mute, isFalse);
      }
    });

    test('a one-word template is not a stamped campaign', () {
      for (var i = 0; i < 8; i++) {
        expect(at('m${1000 + i}', 'k', i).mute, isFalse);
        expect(at('msg@${1700000000 + i}', 'k', i).mute, isFalse);
        expect(at('score ${i * 3}', 'k', i).mute, isFalse);
      }
    });

    test('a stamped repeat outside the window does not count', () {
      for (var i = 0; i < 3; i++) {
        final t = t0.add(Duration(minutes: 4 * i));
        f.check('message gh6gc8${i}n1', 'k',
            createdAtMs: t.millisecondsSinceEpoch, now: t);
      }
      final later = t0.add(const Duration(minutes: 31));
      expect(
          f
              .check('message gh6gc89n1', 'k',
                  createdAtMs: later.millisecondsSinceEpoch, now: later)
              .mute,
          isFalse);
    });

    test('empty and null are safe', () {
      expect(f.check(null, 'p', now: t0), CampaignVerdict.none);
      expect(f.check('', 'p', now: t0), CampaignVerdict.none);
    });

    test('per-victim tracking parameters do not split the payload', () {
      const base = 'Check out this amazing opportunity https://spam.example/x';
      expect(f.check('$base?ref=aaa', 'k1', now: t0).flood, isFalse);
      expect(f.check('$base?ref=bbb', 'k2', now: t0).flood, isFalse);
      expect(f.check('$base?ref=ccc', 'k3', now: t0).flood, isFalse);
      expect(f.check('$base?ref=ddd', 'k4', now: t0).flood, isTrue);
    });

    test('case and spacing are not evasion', () {
      const base = 'Buy now before the presale ends and the price goes up';
      expect(f.check(base, 'k1', now: t0).flood, isFalse);
      expect(f.check(base.toUpperCase(), 'k2', now: t0).flood, isFalse);
      expect(
          f.check(base.replaceAll(' ', '   '), 'k3', now: t0).flood, isFalse);
      expect(f.check(base, 'k4', now: t0).flood, isTrue);
    });

    test('two long messages sharing a few words are not the same payload', () {
      const x = 'anyone know a good place for coffee near the station that '
          'opens early on a sunday morning';
      const y = 'anyone know a good mechanic near the station, my car started '
          'making a noise on sunday morning';
      for (var i = 0; i < 4; i++) {
        f.check(x, 'k$i', now: t0);
      }
      expect(f.check(y, 'k9', now: t0).flood, isFalse);
    });

    test('the cluster index stays bounded', () {
      final small = CrossContentFlood(maxClusters: 50);
      for (var i = 0; i < 400; i++) {
        small.check(
            'distinct payload number $i padded out to length with words w$i',
            'k$i',
            now: t0.add(Duration(milliseconds: i)));
      }
      expect(small.length, lessThanOrEqualTo(50));
    });

    test('the fingerprint drops digit tokens and mentions, keeps links', () {
      expect(
          CrossContentFlood.campaignTokens(
              'Hey @bob, see https://a.example/p?x=1 now!! ghdr5c1n2 1000%'),
          ['hey', 'see', 'https://a.example/p', 'now']);
    });

    test('fnv1a32 matches the PWA reference vectors', () {
      expect(CrossContentFlood.fnv1a32(''), 0x811c9dc5);
      expect(CrossContentFlood.fnv1a32('a'), 0xe40c292c);
      expect(CrossContentFlood.fnv1a32('foobar'), 0xbf9cf968);
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
      expect(
          validatedPowBits(const [
            ['g', 'u4pruy']
          ], id(8)),
          0);
    });

    test('a nonce tag with no target scores nothing', () {
      expect(
          validatedPowBits(const [
            ['nonce', '1234']
          ], id(8)),
          0);
    });

    test('a nonsense or absurd target scores nothing', () {
      expect(
          validatedPowBits(const [
            ['nonce', '1', 'abc']
          ], id(8)),
          0);
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

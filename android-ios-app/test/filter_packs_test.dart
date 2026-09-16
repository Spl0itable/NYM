// Filter packs on the native client, run against the SAME corpus as the PWA's
// scripts/test-filter-packs.mjs and asserting the same verdicts.
//
// That shared corpus is the point of this file. The pack selection syncs
// across devices, so a matcher that behaves differently here is a message
// hidden on the laptop and visible on the phone with nothing to explain the
// difference — and Dart has no String.normalize(), so the two normalizers are
// separate code that has to agree by test rather than by construction.
//
// A false positive matters more than a miss. A missed swear word is a swear
// word; a false positive is a person whose ordinary message vanished and who
// has no way to find out why.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/filter/filter_packs.dart';

void main() {
  setUpAll(() {
    FilterPacks.resetForTest();
    for (final id in kFilterPackIds) {
      final raw = File('assets/data/filter-packs/$id.json').readAsStringSync();
      FilterPacks.loadFromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
  });

  setUp(() => FilterPacks.setActive(kFilterPackIds));

  String? hit(String text, {String? nym}) => FilterPacks.match(text, nym: nym);
  bool isClean(String text, {String? nym}) => hit(text, nym: nym) == null;

  group('normalization', () {
    test('lowercases and strips punctuation', () {
      expect(FilterPacks.normalize('Hello, World!').norm, 'hello world');
    });
    test('strips diacritics', () {
      expect(FilterPacks.normalize('café NAÏVE').norm, 'cafe naive');
    });
    test('folds fullwidth', () {
      expect(FilterPacks.normalize('ＦＵＬＬ').norm, 'full');
    });
    test('drops zero-width and soft hyphens', () {
      expect(FilterPacks.normalize('fu​ck').norm, 'fuck');
      expect(FilterPacks.normalize('fu­ck').norm, 'fuck');
    });
    test('maps cyrillic lookalikes', () {
      expect(FilterPacks.normalize('huеllo').norm, 'huello');
    });
    test('deletes mid-word separators', () {
      expect(FilterPacks.normalize('f.u.c.k').norm, 'fuck');
      expect(FilterPacks.normalize('s-h-i-t').norm, 'shit');
    });
    test('keeps sentence dots as separators', () {
      expect(FilterPacks.normalize('End. Start').norm, 'end start');
    });
    test('joins spaced-out runs', () {
      expect(FilterPacks.normalize('f u c k off').joined, contains('fuck'));
    });
    test('leaves two-letter runs alone', () {
      expect(FilterPacks.normalize('a b test').joined, '');
    });
    test('handles empty input', () {
      expect(FilterPacks.normalize('').norm, '');
      expect(FilterPacks.normalize(null).norm, '');
    });
  });

  group('caught however it is written', () {
    const forms = [
      'fuck this', 'FUCK THIS', 'fuuuuck', 'f u c k', 'f.u.c.k', 'f-u-c-k',
      'fu​ck', 'ｆｕｃｋ', 'fück', 'phuck', 'fck off', 'what the fuck',
      'sh1t', 'sh!t', r'$hit', 'shiiit', 's h i t', 'bullsh1t',
      'b!tch', 'b1tch', 'biatch', r'a$$hole', '@sshole', 'a s s h o l e',
      'motherfucker', 'm0therfucker', 'cunt', 'kunt', 'd1ckhead',
    ];
    for (final f in forms) {
      test('catches "$f"', () => expect(hit(f), 'profanity'));
    }

    test('catches non-Latin lists', () {
      // Each of these missed until terms were normalized by the same pipeline
      // as the text: the homoglyph fold rewrites Cyrillic, and decomposing
      // Hangul or kana would split them into pieces the pack never carries.
      expect(hit('vete a la mierda'), 'profanity', reason: 'es');
      expect(hit('du arschloch'), 'profanity', reason: 'de');
      expect(hit('иди на хуй'), 'profanity', reason: 'ru');
      expect(hit('你这个傻逼'), 'profanity', reason: 'zh');
      expect(hit('お前はバカだ'), 'profanity', reason: 'ja');
      expect(hit('씨발 뭐야'), 'profanity', reason: 'ko');
      expect(hit('ไอ้เหี้ย'), 'profanity', reason: 'th');
      expect(hit('يا كس'), 'profanity', reason: 'ar');
    });
  });

  group('the Scunthorpe suite', () {
    const innocent = [
      'I grew up in Scunthorpe and moved to Penistone',
      'The assassin was assigned to assess the assets',
      'Please assist with the assessment and assume the association is assured',
      'That is a classic bass guitar in a glass case on the grass',
      'Massive class, we will pass the password to the passenger',
      'Harassment training is mandatory; the compass is in the embassy',
      'Put the cocktail on the cockpit table next to the cockroach',
      'A peacock and a woodcock walked into Cockermouth',
      'The analysis by the analyst used analytics and an analogy',
      'The canal is banal but the arsenal is not',
      'I ordered shiitake mushrooms and a casserole',
      'My therapist recommended grapefruit and scraped drapes',
      'Uranus is visible under the circumstances if you accumulate data',
      'The document from Cumbria mentions a cucumber and a cummings quote',
      'Dickens and Dickinson are in the dictionary; I predict a dictation',
      'Titanic had a titular titan with a competitive appetite',
      'Sussex, Essex, Middlesex and Wessex are counties',
      'Nigeria and Niger are different; do not denigrate or snigger',
      'The bassoon and the bassinet are in the pistachio room',
      'Compassion and passion are not passive; the assembly assorted the asparagus',
      'Potassium and molasses do not mix; that is a sassy casserole',
      'We should surpass the cutlass record with a cassette',
      'Shuttlecock practice is at the Hancock building',
      'Kudos on the kumquat; the knickers are in the drawer',
      'I need to scrap the scrapbook after the fracking debate',
      'The incumbent will succumb to cumulative pressure',
    ];
    for (final s in innocent) {
      test('clean: ${s.substring(0, s.length < 40 ? s.length : 40)}',
          () => expect(hit(s), isNull));
    }
  });

  group('this app\'s own vocabulary is not shilling', () {
    const normal = [
      'zap me 1000 sats please',
      'my lightning node is down, the invoice failed',
      'bitcoin is at a new high today',
      'what relay are you on? my npub is in my profile',
      'I moved my sats to cold storage on a hardware wallet',
      'the mempool is congested, fees are high',
      'cashu and fedimint are both ecash',
      'taproot and PSBT are underrated',
      'nostr relays keep dropping my events',
      'I self custody everything, seed backup is in a safe',
      'halving is next year, block times are steady',
      'the shop takes sats, I bought flair with a zap',
      'utxo consolidation before fees go up',
      'check out this nostr gem of a client',
      'the NFT mint conversation is boring',
    ];
    for (final s in normal) {
      test('clean: ${s.substring(0, s.length < 36 ? s.length : 36)}',
          () => expect(hit(s), isNull));
    }

    test('the shill itself is caught', () {
      expect(hit('this is the next 100x gem, presale is live'), 'crypto');
      expect(hit('ape in before it moons, liquidity locked and dev doxxed'), 'crypto');
      expect(hit(r'$PEPE about to pump, buy now'), 'crypto');
    });
  });

  group('scam shapes, in any language', () {
    const scams = [
      'please send me your seed phrase to restore',
      'enter your 12 word recovery phrase here',
      'verify your wallet at this link',
      'send 0.1 BTC and receive 0.2 back guaranteed',
      'guaranteed returns of 20% daily',
      r'earn $500 per day from home',
      'DM me for more profit details',
      'join https://t.me/cryptopumpgroup now',
      'transfer to 0x742d35Cc6634C0532925a3b844Bc454e4438f44e',
      'claim your free airdrop tokens now',
      'first 100 people get double their money',
      'we recover your lost funds, refund agent here',
    ];
    for (final s in scams) {
      test('caught: ${s.substring(0, s.length < 36 ? s.length : 36)}',
          () => expect(hit(s), 'scams'));
    }

    const notScams = [
      'I lost my seed, thankfully I had a backup written down',
      'my wallet app crashed, had to restore from my own notes',
      'the airdrop discussion was interesting',
      'what do you think about investment in general',
      'telegram is a decent messenger',
      'support was helpful when I emailed them',
      'I earn a living as a developer',
      'the giveaway last year was fun',
      'lnbc1500n1ps... here is my invoice',
    ];
    for (final s in notScams) {
      test('clean: ${s.substring(0, s.length < 36 ? s.length : 36)}',
          () => expect(hit(s), isNull));
    }
  });

  group('politics without hiding ordinary words', () {
    test('catches what the pack is for', () {
      expect(hit('typical republican nonsense'), 'politics');
      expect(hit('what trump said yesterday'), 'politics');
      expect(hit('the woke agenda strikes again'), 'politics');
    });

    const ordinary = [
      'the state of the code is fine',
      'we had a party for the release',
      'please vote on the poll in the channel',
      'the left side of the screen is broken',
      'that is the right approach',
      'our policy is to ship on Fridays',
      'the government API is slow today',
      'freedom of choice matters in software',
      'a good debate about relays',
      'march is a busy month',
    ];
    for (final s in ordinary) {
      test('clean: ${s.substring(0, s.length < 34 ? s.length : 34)}',
          () => expect(hit(s), isNull));
    }
  });

  group('the symbol rules, which cut both ways', () {
    test('a trailing bang does not break the match', () {
      // Converting it would normalize "fuck!" to "fucki" and the term would
      // then MISS — an over-eager normalizer costs catches, not just quiet.
      expect(hit('fuck!'), 'profanity');
    });
    test('nor damage a clean word', () {
      expect(isClean('Hello World!'), isTrue);
      expect(isClean('yes!!!'), isTrue);
    });
    test('a price stays a price', () {
      expect(isClean(r'that costs $20 and $5 shipping'), isTrue);
    });
    test('a dollar next to a letter still converts', () {
      expect(hit(r'$hit'), 'profanity');
      expect(hit(r'a$$hole'), 'profanity');
    });
    test('an email is not mangled into a match', () {
      expect(isClean('write to a@b.com about it'), isTrue);
    });
    test('a pipe table is clean', () {
      expect(isClean('| name | value |'), isTrue);
    });
  });

  group('nicknames', () {
    test('catches a run-together nym', () {
      expect(hit('hello there', nym: 'fuckbot'), 'profanity');
      expect(hit('hi', nym: 'sh1tp0ster'), 'profanity');
    });
    test('but not a real name that contains one', () {
      // The substring list is deliberately short so these survive it.
      for (final n in ['Cassidy', 'Shiitake', 'Penistone', 'bassist', 'assange', 'analyst']) {
        expect(hit('hi everyone', nym: n), isNull, reason: n);
      }
    });
  });

  group('only enabled packs fire', () {
    test('a disabled pack does not match', () async {
      await FilterPacks.setActive(['politics']);
      expect(hit('fuck this'), isNull);
      expect(hit('typical republican nonsense'), 'politics');
    });
    test('no packs means no matching at all', () async {
      await FilterPacks.setActive(const []);
      expect(hit('fuck this'), isNull);
    });
    test('unknown ids are ignored', () async {
      await FilterPacks.setActive(['nonsense']);
      expect(FilterPacks.active, isEmpty);
    });
  });

  group('robustness', () {
    test('a long message does not hang', () {
      final long = 'lorem ipsum dolor sit amet ' * 2000;
      final sw = Stopwatch()..start();
      expect(hit(long), isNull);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });
    test('null and empty are safe', () {
      expect(FilterPacks.match(null), isNull);
      expect(hit(''), isNull);
    });
    test('emoji and urls are clean', () {
      expect(isClean('🎉🎉🎉'), isTrue);
      expect(isClean('https://example.com/some/path'), isTrue);
    });
    test('their own app name is clean', () {
      expect(isClean('joined the channel via bitchat'), isTrue);
    });
  });
}

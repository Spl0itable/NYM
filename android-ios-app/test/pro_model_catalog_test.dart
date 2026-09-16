// The Pro model catalog is served live by the model-catalog worker, which
// mirrors Cloudflare's model docs into D1 hourly. These cover the parsing and
// resolution the client does on that payload — in particular that a model key
// a user pinned before a version bump still resolves, and that every failure
// path lands on the list compiled into the binary rather than an empty picker.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/i18n/i18n.dart';
import 'package:nym_bar/features/nymbot/brand_marks.dart';
import 'package:nym_bar/features/nymbot/brand_tile.dart';
import 'package:nym_bar/features/nymbot/nymbot_models.dart';

/// A worker `models` payload shaped like the real one.
Map<String, dynamic> _payload() => {
      'source': 'catalog',
      'models': [
        {
          'key': 'claude-fable-5-1',
          'label': 'Claude Fable 5.1',
          'model': 'anthropic/claude-fable-5.1',
          'credits': 2,
          'max': 16,
          'description': 'Anthropic\'s next model in the Fable family.',
          'author': 'Anthropic',
          'authorSlug': 'anthropic',
          'vision': true,
          'reasoning': true,
          'tools': true,
          'context': 1000000,
          'priced': true,
        },
        {
          'key': 'claude-opus-5',
          'label': 'Claude Opus 5',
          'model': 'anthropic/claude-opus-5',
          'credits': 1,
          'max': 8,
          'author': 'Anthropic',
          'authorSlug': 'anthropic',
          'priced': true,
        },
        {
          'key': 'gemini-3-6-flash',
          'label': 'Gemini 3.6 Flash',
          'model': 'google/gemini-3.6-flash',
          'credits': 1,
          'max': 3,
          'author': 'Google',
          'authorSlug': 'google',
          'priced': false,
        },
        {
          'key': 'deepseek-v4-pro-0813',
          'label': 'deepseek-v4-pro-0813',
          'model': '@cf/deepseek-ai/deepseek-v4-pro-0813',
          'credits': 1,
          'max': 3,
          'author': 'DeepSeek',
          'authorSlug': 'deepseek',
          'reasoning': true,
          'tools': true,
          'hosting': 'cloudflare-hosted',
          'priced': true,
        },
      ],
      'groups': [
        {
          'author': 'Anthropic',
          'authorSlug': 'anthropic',
          'keys': ['claude-fable-5-1', 'claude-opus-5'],
        },
        {
          'author': 'Google',
          'authorSlug': 'google',
          'keys': ['gemini-3-6-flash'],
        },
        {
          'author': 'DeepSeek',
          'authorSlug': 'deepseek',
          'keys': ['deepseek-v4-pro-0813'],
        },
      ],
      'aliases': {
        'claude-fable': 'claude-fable-5-1',
        'claude-opus': 'claude-opus-5',
        'gemini-flash': 'gemini-3-6-flash',
        // The third-party DeepSeek row is retired in the overrides table; its
        // replacedBy rides down to the client as an ordinary alias.
        'deepseek-v4-pro': 'deepseek-v4-pro-0813',
      },
      'usdPerCredit': 0.01,
      'minChargeCredits': 1,
    };

void main() {
  group('ProModelCatalog.fromJson', () {
    test('parses models, groups and aliases', () {
      final cat = ProModelCatalog.fromJson(_payload());
      expect(cat.models, hasLength(4));
      expect(cat.source, 'catalog');
      expect(cat.isEmpty, isFalse);

      final fable = cat.models.first;
      expect(fable.key, 'claude-fable-5-1');
      expect(fable.label, 'Claude Fable 5.1');
      expect(fable.modelId, 'anthropic/claude-fable-5.1');
      expect(fable.baseCredits, 2);
      expect(fable.max, 16);
      expect(fable.vision, isTrue);
      expect(fable.reasoning, isTrue);
      expect(fable.tools, isTrue);
      expect(fable.context, 1000000);
      expect(fable.description, isNotEmpty);
    });

    // Cloudflare-hosted models run on the worker's AI binding rather than
    // going out through the gateway, so the client has to be able to tell them
    // apart — the picker badges them, and DeepSeek is only reachable that way.
    test('a Cloudflare-hosted model is parsed and flagged as one', () {
      final cat = ProModelCatalog.fromJson(_payload());
      final ds = cat.byKey('deepseek-v4-pro-0813')!;
      expect(ds.hosting, 'cloudflare-hosted');
      expect(ds.cloudflareHosted, isTrue);
      expect(ds.modelId, startsWith('@cf/'));
      expect(cat.byKey('claude-opus-5')!.cloudflareHosted, isFalse);
    });

    test('a @cf/ id alone marks a model Cloudflare-hosted', () {
      // An older worker sends no hosting field; the id still settles it.
      final cat = ProModelCatalog.fromJson({
        'models': [
          {'key': 'x', 'label': 'X', 'model': '@cf/meta/llama', 'credits': 1},
        ],
      });
      expect(cat.byKey('x')!.hosting, isEmpty);
      expect(cat.byKey('x')!.cloudflareHosted, isTrue);
    });

    test('a pin on a retired third-party model follows its replacement', () {
      final cat = ProModelCatalog.fromJson(_payload());
      expect(cat.byKey('deepseek-v4-pro')!.modelId,
          '@cf/deepseek-ai/deepseek-v4-pro-0813');
    });

    test('a model Cloudflare prices only in its dashboard is flagged', () {
      final cat = ProModelCatalog.fromJson(_payload());
      expect(cat.byKey('gemini-3-6-flash')!.priced, isFalse);
      // Absent means "assume priced", so an older worker never greys the list.
      final older = ProModelCatalog.fromJson({
        'models': [
          {'key': 'x', 'label': 'X', 'credits': 1},
        ],
      });
      expect(older.byKey('x')!.priced, isTrue);
    });

    test('drops entries with no key and reports an empty payload', () {
      final cat = ProModelCatalog.fromJson({
        'models': [
          {'label': 'nameless'},
          {'key': 'ok', 'label': 'Ok', 'credits': 1},
        ],
      });
      expect(cat.models, hasLength(1));
      expect(ProModelCatalog.fromJson({'models': []}).isEmpty, isTrue);
      expect(ProModelCatalog.fromJson({}).isEmpty, isTrue);
    });

    test('survives a garbage payload instead of throwing', () {
      expect(ProModelCatalog.fromJson({'models': 'nope'}).isEmpty, isTrue);
      expect(
          ProModelCatalog.fromJson({
            'models': ['not a map', 42],
          }).isEmpty,
          isTrue);
    });

    test('round-trips through JSON, which is how it is cached', () {
      final cat = ProModelCatalog.fromJson(_payload());
      final again = ProModelCatalog.fromJson(cat.toJson());
      expect(again.models.map((m) => m.key), cat.models.map((m) => m.key));
      expect(again.aliases, cat.aliases);
      expect(again.grouped().map((g) => g.key),
          ['Anthropic', 'Google', 'DeepSeek']);
      expect(again.byKey('claude-opus')!.key, 'claude-opus-5');
    });
  });

  group('ProModelCatalog.byKey', () {
    final cat = ProModelCatalog.fromJson(_payload());

    test('resolves an exact key', () {
      expect(cat.byKey('claude-opus-5')!.label, 'Claude Opus 5');
    });

    test('resolves a key pinned before a version bump, via the alias map', () {
      expect(cat.byKey('claude-opus')!.key, 'claude-opus-5');
      expect(cat.byKey('claude-fable')!.key, 'claude-fable-5-1');
      expect(cat.byKey('gemini-flash')!.key, 'gemini-3-6-flash');
    });

    test('resolves a retired built-in alias through the live list', () {
      // kProModelAliases maps claude-opus-4.8 -> claude-opus, and the live
      // alias map carries claude-opus -> claude-opus-5.
      expect(cat.byKey('claude-opus-4.8')!.key, 'claude-opus-5');
    });

    test('resolves a full model id', () {
      expect(cat.byKey('anthropic/claude-fable-5.1')!.key, 'claude-fable-5-1');
    });

    test('is case- and whitespace-insensitive', () {
      expect(cat.byKey('  Claude-Opus  ')!.key, 'claude-opus-5');
    });

    test('returns null for an unknown key rather than guessing', () {
      expect(cat.byKey('no-such-model'), isNull);
      expect(cat.byKey(''), isNull);
    });
  });

  group('grouping', () {
    test('groups in the order the worker returned them', () {
      final grouped = ProModelCatalog.fromJson(_payload()).grouped();
      expect(grouped.map((g) => g.key), ['Anthropic', 'Google', 'DeepSeek']);
      expect(grouped.first.value.map((m) => m.key),
          ['claude-fable-5-1', 'claude-opus-5']);
    });

    test('a group naming a model that is gone drops just that row', () {
      final p = _payload();
      (p['groups'] as List)[1] = {
        'author': 'Google',
        'authorSlug': 'google',
        'keys': ['gemini-3-6-flash', 'vanished-model'],
      };
      final grouped = ProModelCatalog.fromJson(p).grouped();
      expect(grouped[1].value.map((m) => m.key), ['gemini-3-6-flash']);
    });

    test('a group left with nothing is omitted entirely', () {
      final p = _payload();
      (p['groups'] as List)[1] = {
        'author': 'Google',
        'authorSlug': 'google',
        'keys': ['vanished-model'],
      };
      expect(ProModelCatalog.fromJson(p).grouped().map((g) => g.key),
          ['Anthropic', 'DeepSeek']);
    });

    test('no groups means one unnamed group holding everything', () {
      final grouped = kProModelCatalogFallback.grouped();
      expect(grouped, hasLength(1));
      expect(grouped.single.key, '');
      expect(grouped.single.value, hasLength(kProModels.length));
    });
  });

  group('the built-in fallback', () {
    test('is the compiled-in list and resolves its own keys', () {
      expect(kProModelCatalogFallback.isEmpty, isFalse);
      expect(kProModelCatalogFallback.models, same(kProModels));
      expect(kProModelCatalogFallback.byKey('claude-opus')!.label,
          'Claude Opus 5');
      // Retired keys still resolve off the built-in alias table.
      expect(kProModelCatalogFallback.byKey('codex')!.key, 'gpt-5');
    });

    test('a model with no published rate keeps the flat per-reply label', () {
      final fable = kProModelCatalogFallback.byKey('claude-fable')!;
      expect(fable.baseCredits, 2);
      expect(fable.metered, isFalse);
      expect(fable.priceLabel,
          'from 2 Pro credits, up to 16 for max-length replies');
      final haiku = kProModelCatalogFallback.byKey('claude-haiku')!;
      expect(haiku.priceLabel, '1 Pro credit/reply');
    });
  });

  group('what a reply is charged on', () {
    ProModel priced(Map<String, dynamic> extra) =>
        ProModel.fromJson({'key': 'm', 'label': 'M', 'credits': 1, ...extra});

    test('a model the catalog prices quotes its per-token rates', () {
      final m = priced({
        'inUsdPerMTok': 7.875,
        'outUsdPerMTok': 39.375,
        'cacheReadUsdPerMTok': 0.788,
      });
      expect(m.metered, isTrue);
      expect(m.priceLabel,
          r'$7.875/M in, $39.375/M out, $0.788/M cached');
    });

    test('without a cached rate it says only what it knows', () {
      final m = priced({'inUsdPerMTok': 2, 'outUsdPerMTok': 10});
      expect(m.priceLabel, r'$2.0/M in, $10.0/M out');
    });

    test('half a rate pair is not metered, so the flat price stands', () {
      expect(priced({'inUsdPerMTok': 2}).metered, isFalse);
      expect(priced({'outUsdPerMTok': 10}).metered, isFalse);
      expect(priced({'inUsdPerMTok': 2}).priceLabel, '1 Pro credit/reply');
    });

    test('the rates survive a round trip through storage', () {
      final m = priced({'inUsdPerMTok': 5, 'outUsdPerMTok': 25});
      final back = ProModel.fromJson(m.toJson());
      expect(back.inUsdPerMTok, 5);
      expect(back.outUsdPerMTok, 25);
      expect(back.priceLabel, m.priceLabel);
    });
  });

  // Rates alone answer "how is this billed" but not "what will this cost me",
  // which is the question a credit balance actually raises. Every surface
  // quotes the same nominal turn so the four of them cannot disagree.
  group('what a turn costs', () {
    ProModel priced(Map<String, dynamic> extra) =>
        ProModel.fromJson({'key': 'm', 'label': 'M', 'credits': 1, ...extra});

    test('the worker\'s pricing scalars are parsed, not dropped', () {
      final cat = ProModelCatalog.fromJson(_payload());
      expect(cat.usdPerCredit, 0.01);
      expect(cat.minChargeCredits, 1);
    });

    test('and survive the round trip through storage', () {
      final cat = ProModelCatalog.fromJson(_payload());
      final back = ProModelCatalog.fromJson(cat.toJson());
      expect(back.usdPerCredit, cat.usdPerCredit);
      expect(back.minChargeCredits, cat.minChargeCredits);
    });

    test('a payload without them degrades to no estimate rather than a wrong one',
        () {
      final cat = ProModelCatalog.fromJson({'models': []});
      expect(cat.usdPerCredit, 0);
      final m = priced({'inUsdPerMTok': 15.75, 'outUsdPerMTok': 78.75});
      expect(m.turnCredits(cat.usdPerCredit, cat.minChargeCredits), isNull);
      expect(m.turnLabel(cat.usdPerCredit, cat.minChargeCredits),
          '1 Pro credit/reply');
    });

    test('the estimate is the nominal turn at the published rates', () {
      final m = priced({'inUsdPerMTok': 15.75, 'outUsdPerMTok': 78.75});
      // 3000 * 15.75 + 700 * 78.75 = 102,375 millionths of a dollar, and a
      // credit is a cent.
      expect(m.turnCredits(0.01, 1), closeTo(10.2375, 1e-9));
      expect(m.turnLabel(0.01, 1), '~10.24 credits a turn');
    });

    test('a cheap model quotes the minimum charge, not less than it', () {
      final m = priced({'inUsdPerMTok': 0.3, 'outUsdPerMTok': 1.2});
      expect(m.turnCredits(0.01, 1), 1);
      expect(m.turnLabel(0.01, 1), '~1 credit a turn');
    });

    test('the rates are a line of their own, so neither has to be shortened',
        () {
      final m = priced({
        'inUsdPerMTok': 15.75,
        'outUsdPerMTok': 78.75,
        'cacheReadUsdPerMTok': 0.39375,
      });
      expect(m.ratesLabel(),
          r'$15.75/M in, $78.75/M out, $0.39375/M cached');
      expect(m.priceLine(0.01, 1),
          r'~10.24 credits a turn · $15.75/M in, $78.75/M out, $0.39375/M cached');
    });

    test('a model with no published rate has no rates line at all', () {
      final m = priced({});
      expect(m.ratesLabel(), isNull);
      expect(m.priceLine(0.01, 1), '1 Pro credit/reply');
    });

    test('the built-in fallback quotes flat prices, since it carries no rates',
        () {
      final cat = kProModelCatalogFallback;
      expect(cat.usdPerCredit, 0);
      final haiku = cat.byKey('claude-haiku')!;
      expect(haiku.priceLine(cat.usdPerCredit, cat.minChargeCredits),
          '1 Pro credit/reply');
    });
  });

  group('the maker of a model is drawn', () {
    test('a known maker has its own mark, from the shared table', () {
      expect(BrandMarks.of('anthropic'), isNotNull);
      expect(BrandMarks.of('openai'), isNotNull);
      expect(BrandMarks.of('cloudflare'), isNotNull,
          reason: 'most of the catalog is Cloudflare-hosted');
      expect(BrandMarks.marks.length, greaterThan(20));
    });

    test('the slugs Cloudflare ships resolve to the maker that made the model', () {
      expect(BrandMarks.of('meta-llama'), same(BrandMarks.of('meta')));
      expect(BrandMarks.of('deepseek-ai'), same(BrandMarks.of('deepseek')));
      expect(BrandMarks.of('mistral'), same(BrandMarks.of('mistralai')));
      expect(BrandMarks.of('llava-hf'), same(BrandMarks.of('huggingface')));
    });

    test('a maker with no mark still gets a tile, told apart by colour', () {
      expect(BrandMarks.of('pruna'), isNull);
      expect(BrandMarks.initials('pruna'), 'PR');
      expect(BrandMarks.initials('black-forest-labs'), 'BF',
          reason: 'one letter per word reads better than the first two');
      expect(BrandMarks.tintFor('pruna'), isNot(BrandMarks.tintFor('krea')));
    });

    test('every mark parses to the geometry it declares', () {
      for (final entry in BrandMarks.marks.entries) {
        final paths = entry.value.paths.map(SvgPath.parse).toList();
        expect(paths.length, entry.value.paths.length, reason: entry.key);
        var bounds = paths.first.getBounds();
        for (final path in paths.skip(1)) {
          bounds = bounds.expandToInclude(path.getBounds());
        }
        expect(bounds.width, greaterThan(0), reason: entry.key);
        expect(bounds.height, greaterThan(0), reason: entry.key);
      }
    });
  });

  group('a fraction of a credit', () {
    test('is printed as one, and never as zero', () {
      expect(creditFigure(12), '12');
      expect(creditFigure(0), '0');
      expect(creditFigure(null), '\u2026');
      expect(creditFigure(0.394), '0.39');
      expect(creditFigure(0.4), '0.4');
      expect(creditFigure(4.46), '4.46');
      expect(creditFigure(49.55), '49.55',
          reason: 'a large balance has to show a sub-credit spend');
      expect(creditFigure(0.004), '<0.01');
    });

    test('a balance reads the worker fractional field, else the whole one', () {
      final metered = BotBalance.fromJson({
        'balance': 12, 'balanceCredits': 11.6,
        'proBalance': 3, 'proBalanceCredits': 2.4,
      });
      expect(metered.balance, 11.6);
      expect(metered.proBalance, 2.4);
      final older = BotBalance.fromJson({'balance': 12, 'proBalance': 3});
      expect(older.balance, 12);
      expect(older.proBalance, 3);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/nymbot/bot_commands.dart';
import 'package:nym_bar/features/nymbot/nymbot_models.dart';
import 'package:nym_bar/features/nymbot/nymbot_providers.dart';

void main() {
  group('parseBotCommand', () {
    test('splits ?ask hello -> (ask, "hello")', () {
      final p = parseBotCommand('?ask hello');
      expect(p, isNotNull);
      expect(p!.name, 'ask');
      expect(p.args, 'hello');
      expect(p.isKnown, isTrue);
    });

    test('keeps multi-word + inner spacing in args', () {
      final p = parseBotCommand('?ask  hello   world ');
      expect(p!.name, 'ask');
      expect(p.args, 'hello   world');
    });

    test('lower-cases the command keyword but preserves arg case', () {
      final p = parseBotCommand('?ASK Hello World');
      expect(p!.name, 'ask');
      expect(p.args, 'Hello World');
    });

    test('command with no args yields empty args', () {
      final p = parseBotCommand('?flip');
      expect(p!.name, 'flip');
      expect(p.args, isEmpty);
    });

    test('8ball is a valid keyword', () {
      final p = parseBotCommand('?8ball will it rain');
      expect(p!.name, '8ball');
      expect(p.args, 'will it rain');
      expect(p.isKnown, isTrue);
    });

    test('btc alias price resolves to the same command', () {
      expect(parseBotCommand('?price')!.command?.name, 'btc');
      expect(parseBotCommand('?bitcoin')!.command?.name, 'btc');
    });

    test('non-command text returns null', () {
      expect(parseBotCommand('hello'), isNull);
      expect(parseBotCommand('?'), isNull);
      expect(parseBotCommand(''), isNull);
    });

    test('unknown ?foo parses but is not known', () {
      final p = parseBotCommand('?foo bar');
      expect(p, isNotNull);
      expect(p!.name, 'foo');
      expect(p.isKnown, isFalse);
    });
  });

  group('isBotCommand / isNymbotMention', () {
    test('isBotCommand detects a leading ? + keyword', () {
      expect(isBotCommand('?ask hi'), isTrue);
      expect(isBotCommand('  ?define entropy'), isTrue);
      expect(isBotCommand('?'), isFalse);
      expect(isBotCommand('? ask'), isFalse);
      expect(isBotCommand('not a command'), isFalse);
    });

    test('isNymbotMention detects @Nymbot anywhere, case-insensitive', () {
      expect(isNymbotMention('@Nymbot what is nostr'), isTrue);
      expect(isNymbotMention('hey @nymbot help'), isTrue);
      expect(isNymbotMention('ping @NYMBOT'), isTrue);
      expect(isNymbotMention('nymbot without at'), isFalse);
      expect(isNymbotMention('email me@nymbotz.com'), isFalse);
    });

    test('stripNymbotMention returns the question text', () {
      expect(stripNymbotMention('@Nymbot what is nostr'), 'what is nostr');
      expect(stripNymbotMention('hey @nymbot help'), 'hey help');
    });
  });

  group('command catalogue', () {
    // Every command the worker (`functions/api/bot.js`) actually dispatches.
    // Note: `?roll` is in the README but has NO worker handler, so it is
    // intentionally absent from the catalogue. `?changelog` is a real worker
    // command (aliases release(s)/version(s)) and must be present.
    const readmeCommands = [
      // AI & Knowledge
      'ask', 'define', 'translate', 'news',
      // Games & Fun
      'trivia', 'joke', 'riddle', 'wordplay', 'flip', '8ball', 'pick',
      // Utility
      'math', 'units', 'time', 'btc',
      // Channel Activity
      'who', 'summarize', 'top', 'last', 'seen',
      // Credits (private Nymbot chat)
      'balance', 'buy', 'model', 'git', 'gift', 'transfer',
      // Info
      'help', 'about', 'nostr', 'changelog',
    ];

    test('contains every README command', () {
      for (final name in readmeCommands) {
        expect(lookupBotCommand(name), isNotNull,
            reason: 'missing command ?$name');
      }
    });

    test('contains the credit ops as credit commands', () {
      for (final name in ['balance', 'buy', 'model', 'git', 'gift', 'transfer']) {
        final cmd = lookupBotCommand(name);
        expect(cmd, isNotNull);
        expect(cmd!.creditCommand, isTrue, reason: '?$name should be a credit op');
      }
    });

    test('?help is marked free/local', () {
      expect(lookupBotCommand('help')!.isFree, isTrue);
    });

    test('catalogue has no duplicate command names', () {
      final names = kBotCommands.map((c) => c.name).toList();
      expect(names.toSet().length, names.length);
    });
  });

  group('<think> reasoning extraction', () {
    test('splits <think>r</think>answer', () {
      final reply = splitReasoning('<think>r</think>answer');
      expect(reply.reasoning, 'r');
      expect(reply.text, 'answer');
      expect(reply.hasReasoning, isTrue);
    });

    test('no think tag -> null reasoning, full text', () {
      final reply = splitReasoning('just an answer');
      expect(reply.reasoning, isNull);
      expect(reply.text, 'just an answer');
      expect(reply.hasReasoning, isFalse);
    });

    test('multi-line + multiple blocks concatenated', () {
      final reply = splitReasoning(
          '<think>first\nline</think>A<think>second</think>B');
      expect(reply.reasoning, 'first\nline\n\nsecond');
      expect(reply.text, 'AB');
    });

    test('case-insensitive tags', () {
      final reply = splitReasoning('<THINK>r</Think>answer');
      expect(reply.reasoning, 'r');
      expect(reply.text, 'answer');
    });

    test('reasoning is truncated at the cap', () {
      final long = 'x' * (BotReply.kReasoningMaxChars + 100);
      final reply = splitReasoning('<think>$long</think>ans');
      expect(reply.reasoning!.length,
          lessThanOrEqualTo(BotReply.kReasoningMaxChars + 40));
      expect(reply.reasoning, contains('reasoning truncated'));
    });
  });

  group('Pro model list', () {
    test('matches the README exactly, in order', () {
      final labels = kProModels.map((m) => m.label).toList();
      expect(labels, [
        'Claude Fable 5',
        'Claude Opus 4.8',
        'Claude Sonnet 4.6',
        'Claude Haiku 4.5',
        'GPT-5.1',
        'GPT-5 mini',
        'GPT-5.1 Codex',
      ]);
    });

    test('keys + ids + Fable base cost', () {
      expect(kProModels.map((m) => m.key).toList(), [
        'claude-fable',
        'claude-opus',
        'claude-sonnet',
        'claude-haiku',
        'gpt-5',
        'gpt-5-mini',
        'codex',
      ]);
      final fable = kProModels.firstWhere((m) => m.key == 'claude-fable');
      expect(fable.modelId, 'anthropic/claude-fable-5');
      expect(fable.baseCredits, 2);
      // All non-Fable models have base 1.
      for (final m in kProModels.where((m) => m.key != 'claude-fable')) {
        expect(m.baseCredits, 1, reason: '${m.key} base credits');
      }
    });

    test('lookupProModel resolves key, label, loose, and off', () {
      expect(lookupProModel('claude-opus')!.label, 'Claude Opus 4.8');
      expect(lookupProModel('Claude Opus 4.8')!.key, 'claude-opus');
      expect(lookupProModel('opus')!.key, 'claude-opus');
      expect(lookupProModel('off'), isNull);
      expect(lookupProModel(''), isNull);
    });
  });

  group('credit tiers', () {
    test('sats per credit: standard 10, pro 100', () {
      expect(CreditTier.standard.satsPerCredit, 10);
      expect(CreditTier.pro.satsPerCredit, 100);
      expect(CreditTier.standard.wire, 'standard');
      expect(CreditTier.pro.wire, 'pro');
    });
  });

  group('BotBalance parsing', () {
    test('reads standard + pro fields', () {
      final b = BotBalance.fromJson({
        'balance': 42,
        'totalPurchased': 100,
        'totalUsed': 58,
        'proBalance': 7,
        'proTotalPurchased': 10,
        'proTotalUsed': 3,
      });
      expect(b.balance, 42);
      expect(b.proBalance, 7);
      expect(b.totalUsed, 58);
      expect(b.proTotalUsed, 3);
    });
  });

  group('GitConfig wire', () {
    test('serialises provider + token + repo + allowWrites', () {
      const cfg = GitConfig(
        provider: GitProvider.github,
        host: 'github.com',
        token: 'ghp_secret',
        repo: 'owner/repo',
        branch: 'main',
        allowWrites: true,
      );
      final w = cfg.toWire();
      expect(w['provider'], 'github');
      expect(w['token'], 'ghp_secret');
      expect(w['repo'], 'owner/repo');
      expect(w['branch'], 'main');
      expect(w['allowWrites'], isTrue);
    });

    test('omits empty branch', () {
      const cfg = GitConfig(
        provider: GitProvider.gitea,
        host: 'codeberg.org',
        token: 't',
        repo: 'o/r',
      );
      expect(cfg.toWire().containsKey('branch'), isFalse);
      expect(GitProvider.gitea.defaultHost, 'codeberg.org');
    });
  });
}

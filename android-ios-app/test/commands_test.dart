import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/autocomplete/autocomplete_queries.dart';
import 'package:nym_bar/features/autocomplete/autocomplete_triggers.dart';
import 'package:nym_bar/features/commands/action_rate_limit.dart';
import 'package:nym_bar/features/commands/command_handler.dart';
import 'package:nym_bar/features/commands/command_palette.dart';
import 'package:nym_bar/features/commands/command_registry.dart';
import 'package:nym_bar/models/channel.dart';
import 'package:nym_bar/models/user.dart';

/// Slash command + autocomplete tests — verify the Flutter port matches the PWA
/// (`js/modules/commands.js` + `js/modules/autocomplete.js`, docs/specs/03
/// §7–§8): parser/alias resolution, formatting wire text, context gating, the
/// shared action rate limit, and the four autocomplete query engines.

/// A spy [CommandEngine]: records sent content + system messages, and exposes
/// the context flags so gating + dispatch can be asserted without an engine.
class _SpyEngine implements CommandEngine {
  _SpyEngine({this.inPM = false, this.inGroup = false, Map<String, User>? users})
      : users = users ?? {};

  @override
  bool inPM;
  @override
  bool inGroup;
  @override
  String selfPubkey = 'self0000';
  @override
  Map<String, User> users;

  final List<String> sent = [];
  final List<String> systems = [];

  @override
  void sendToCurrentTarget(String content) => sent.add(content);
  @override
  void systemMessage(String text) => systems.add(text);

  // Engine actions — record the call so dispatch can be asserted.
  final List<String> joined = [];
  bool didClear = false;
  bool didLeave = false;
  bool didQuit = false;
  String? nick;
  bool didWho = false;
  String? away;
  bool didBack = false;
  bool didShare = false;
  String? blockArg;
  String? unblockArg;

  @override
  void join(String channel) => joined.add(channel);
  @override
  void clear() => didClear = true;
  @override
  void leave() => didLeave = true;
  @override
  void quit() => didQuit = true;
  @override
  void setNick(String newNym) => nick = newNym;
  @override
  void who() => didWho = true;
  @override
  void setAway(String message) => away = message;
  @override
  void clearAway() => didBack = true;
  @override
  void share() => didShare = true;
  @override
  void block(String arg) => blockArg = arg;
  @override
  void unblock(String arg) => unblockArg = arg;
}

User _user(String pubkey, String nym,
        {Set<String>? channels, UserStatus status = UserStatus.online}) =>
    User(
      pubkey: pubkey,
      nym: nym,
      status: status,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
      channels: channels,
    );

void main() {
  group('parser + alias resolution', () {
    test('splits cmd / args like handleCommand', () {
      final p = parseCommand('/join #9q5 extra');
      expect(p.token, '/join');
      expect(p.args, '#9q5 extra');
      expect(p.spec!.id, 'join');
    });

    test('args is empty for a bare command', () {
      expect(parseCommand('/who').args, '');
    });

    test('token is lowercased', () {
      expect(parseCommand('/JOIN nym').spec!.id, 'join');
    });

    test('all 7 single-letter aliases resolve to their command', () {
      expect(resolveCommand('/j')!.id, 'join');
      expect(resolveCommand('/w')!.id, 'who');
      expect(resolveCommand('/b')!.id, 'bold');
      expect(resolveCommand('/i')!.id, 'italic');
      expect(resolveCommand('/s')!.id, 'strike');
      expect(resolveCommand('/c')!.id, 'code');
      expect(resolveCommand('/q')!.id, 'quote');
    });

    test('unknown command is unknown', () {
      expect(parseCommand('/shrug').isKnown, isFalse);
    });

    test('registry matches the PWA: 33 commands + 7 aliases', () {
      // The `this.commands` object in commands.js (setupCommands) defines 33
      // canonical commands + 7 single-letter aliases. The §7 prose says "34"
      // but its own enumerated list also contains 33 — the source is ground
      // truth, so the port mirrors 33. See the registry coverage note.
      expect(kCommandSpecs.length, 33);
      final aliasCount =
          kCommandSpecs.fold<int>(0, (n, s) => n + s.aliases.length);
      expect(aliasCount, 7);
    });
  });

  group('formatting commands produce the right wire text', () {
    late _SpyEngine engine;
    late CommandDispatcher d;
    setUp(() {
      engine = _SpyEngine();
      d = CommandDispatcher(engine: engine);
    });

    test('/bold x -> **x**', () {
      d.handle('/bold x');
      expect(engine.sent.single, '**x**');
    });

    test('/b x (alias) -> **x**', () {
      d.handle('/b x');
      expect(engine.sent.single, '**x**');
    });

    test('/italic x -> *x*', () {
      d.handle('/italic x');
      expect(engine.sent.single, '*x*');
    });

    test('/strike x -> ~~x~~', () {
      d.handle('/strike x');
      expect(engine.sent.single, '~~x~~');
    });

    test('/quote x -> > x', () {
      d.handle('/quote x');
      expect(engine.sent.single, '> x');
    });

    test('/code x -> fenced block', () {
      d.handle('/code hello');
      expect(engine.sent.single, '```\nhello\n```');
    });

    test('/me x -> /me x sent verbatim', () {
      d.handle('/me waves');
      expect(engine.sent.single, '/me waves');
    });

    test('empty formatting arg shows usage, sends nothing', () {
      d.handle('/bold');
      expect(engine.sent, isEmpty);
      expect(engine.systems.single, 'Usage: /bold text');
    });
  });

  group('context gating', () {
    test('/kick is rejected outside a group', () {
      final engine = _SpyEngine(inGroup: false);
      var kicked = false;
      final d = CommandDispatcher(
        engine: engine,
        hooks: CommandHooks(kick: (_) => kicked = true),
      );
      d.handle('/kick @bob');
      expect(kicked, isFalse);
      expect(engine.systems.single,
          'You must be in a group conversation to use this command.');
    });

    test('/poll is rejected in a PM', () {
      final engine = _SpyEngine(inPM: true);
      var opened = false;
      final d = CommandDispatcher(
        engine: engine,
        hooks: CommandHooks(openPoll: () => opened = true),
      );
      d.handle('/poll');
      expect(opened, isFalse);
      expect(engine.systems.single,
          'Polls can only be created in channels, not in private messages.');
    });

    test('/who is rejected in a PM', () {
      final engine = _SpyEngine(inPM: true);
      CommandDispatcher(engine: engine).handle('/who');
      expect(engine.didWho, isFalse);
      expect(engine.systems.single, '/who only works in public channels.');
    });

    test('/kick is allowed inside a group and resolves the target', () {
      final bobPk = 'b' * 60 + 'beef';
      final engine = _SpyEngine(
        inGroup: true,
        users: {bobPk: _user(bobPk, 'bob')},
      );
      String? kickedPk;
      final d = CommandDispatcher(
        engine: engine,
        hooks: CommandHooks(kick: (pk) => kickedPk = pk),
      );
      d.handle('/kick @bob');
      expect(kickedPk, bobPk);
    });
  });

  group('action-command rate limit (3 / 30s, 60s cooldown)', () {
    test('4th action within 30s is blocked', () {
      var t = 0;
      final limiter = ActionCommandRateLimiter(now: () => t);
      final engine = _SpyEngine();
      final d = CommandDispatcher(engine: engine, rateLimiter: limiter);

      d.handle('/me a'); // 1
      d.handle('/me b'); // 2
      d.handle('/me c'); // 3
      expect(engine.sent.length, 3);

      d.handle('/me d'); // 4 — blocked
      expect(engine.sent.length, 3);
      expect(engine.systems.last, 'Too many action commands. Try again in 60s');
    });

    test('the rate limit is shared across /me, /slap, /hug', () {
      final bobPk = 'b' * 60 + 'beef';
      var t = 0;
      final limiter = ActionCommandRateLimiter(now: () => t);
      final engine = _SpyEngine(users: {bobPk: _user(bobPk, 'bob')});
      final d = CommandDispatcher(engine: engine, rateLimiter: limiter);

      d.handle('/me a');
      d.handle('/slap @bob');
      d.handle('/hug @bob');
      expect(engine.sent.length, 3);

      d.handle('/me d'); // 4th across the trio — blocked
      expect(engine.sent.length, 3);
    });

    test('after the window slides, actions are allowed again', () {
      var t = 0;
      final limiter = ActionCommandRateLimiter(now: () => t);
      final engine = _SpyEngine();
      final d = CommandDispatcher(engine: engine, rateLimiter: limiter);
      d.handle('/me a');
      d.handle('/me b');
      d.handle('/me c');
      t = 31000; // past the 30s window
      d.handle('/me d');
      expect(engine.sent.length, 4);
    });
  });

  group('dispatch to engine actions', () {
    test('/j (alias) joins', () {
      final engine = _SpyEngine();
      CommandDispatcher(engine: engine).handle('/j #nymchat');
      expect(engine.joined.single, '#nymchat');
    });

    test('/clear, /leave, /quit, /back, /share, /who', () {
      final engine = _SpyEngine();
      final d = CommandDispatcher(engine: engine);
      d.handle('/clear');
      d.handle('/leave');
      d.handle('/quit');
      d.handle('/back');
      d.handle('/share');
      d.handle('/who');
      expect(engine.didClear, isTrue);
      expect(engine.didLeave, isTrue);
      expect(engine.didQuit, isTrue);
      expect(engine.didBack, isTrue);
      expect(engine.didShare, isTrue);
      expect(engine.didWho, isTrue);
    });

    test('/nick + /brb pass their args', () {
      final engine = _SpyEngine();
      final d = CommandDispatcher(engine: engine);
      d.handle('/nick alice');
      d.handle('/brb lunch');
      expect(engine.nick, 'alice');
      expect(engine.away, 'lunch');
    });

    test('/slap resolves and builds the trout mention', () {
      final bobPk = 'b' * 60 + 'beef';
      final engine = _SpyEngine(users: {bobPk: _user(bobPk, 'bob')});
      CommandDispatcher(engine: engine).handle('/slap @bob');
      expect(engine.sent.single,
          '/me slaps @bob#beef around a bit with a large trout 🐟');
    });
  });

  group('command palette filtering', () {
    test('/b matches bold (alias prefix)', () {
      final rows = buildPaletteRows('/b');
      final ids = paletteCommands(rows).map((s) => s.id).toSet();
      expect(ids.contains('bold'), isTrue);
    });

    test('palette groups under categories in order', () {
      final rows = buildPaletteRows('/');
      // First header should be the first non-empty category (channels).
      final firstHeader = rows.firstWhere((r) => r is PaletteHeader);
      expect((firstHeader as PaletteHeader).label, 'Public Channels');
    });

    test('no match hides the palette (empty rows)', () {
      expect(buildPaletteRows('/zzz'), isEmpty);
    });

    test('formatCommandDisplay collapses aliases', () {
      expect(formatCommandDisplay(resolveCommand('/bold')!), '/bold, /b');
    });
  });

  group('trigger detection at the caret', () {
    test('@ run opens mentions', () {
      final t = detectTrigger('hi @sa');
      expect(t.kind, TriggerKind.mention);
      expect(t.query, 'sa');
    });
    test('# run opens channels', () {
      final t = detectTrigger('go #9q');
      expect(t.kind, TriggerKind.channel);
      expect(t.query, '9q');
    });
    test(': run opens emoji', () {
      final t = detectTrigger('nice :fir');
      expect(t.kind, TriggerKind.emoji);
      expect(t.query, 'fir');
    });
    test('backslash run opens kaomoji', () {
      final t = detectTrigger(r'shrug \Con');
      expect(t.kind, TriggerKind.kaomoji);
      expect(t.query, 'Con');
    });
    test('leading / opens the command palette', () {
      expect(detectTrigger('/jo').kind, TriggerKind.command);
    });
    test('a space closes the token', () {
      expect(detectTrigger('@bob ').kind, TriggerKind.none);
    });
  });

  group('autocomplete query engines (max 8, ranking)', () {
    test('@sa filters users to matching base#suffix', () {
      final users = {
        'aaaa1111${'0' * 56}': _user('aaaa1111${'0' * 56}', 'sam'),
        'bbbb2222${'0' * 56}': _user('bbbb2222${'0' * 56}', 'sally'),
        'cccc3333${'0' * 56}': _user('cccc3333${'0' * 56}', 'dave'),
      };
      final res = queryMentions(
        users: users,
        search: 'sa',
        currentChannelKey: 'nymchat',
      );
      final names = res.map((r) => r.baseNym).toSet();
      expect(names, containsAll(<String>['sam', 'sally']));
      expect(names.contains('dave'), isFalse);
      // Insert text is @base#suffix + space.
      expect(res.first.insertText, startsWith('@'));
      expect(res.first.insertText, endsWith(' '));
    });

    test('mentions rank channel members before others', () {
      final memberPk = 'a' * 60 + '0001';
      final otherPk = 'b' * 60 + '0002';
      final users = {
        otherPk: _user(otherPk, 'zoe'),
        memberPk: _user(memberPk, 'amy', channels: {'9q'}),
      };
      final res = queryMentions(
        users: users,
        search: '',
        currentChannelKey: '9q',
      );
      expect(res.first.pubkey, memberPk); // channel member first
    });

    test('# filters channels and includes seed geohashes', () {
      final res = queryChannels(
        search: '9q',
        channels: [ChannelEntry(channel: '9q8y', geohash: '9q8y')],
        messageChannelCounts: const {},
        currentKey: 'nymchat',
      );
      final names = res.map((r) => r.name).toSet();
      expect(names.contains('9q'), isTrue); // from kCommonGeohashes
      expect(names.contains('9q8y'), isTrue);
      expect(res.every((r) => r.name.startsWith('9q')), isTrue);
      expect(res.first.insertText, '#${res.first.name} ');
    });

    test(':fir resolves to the fire emoji', () {
      final res = queryEmoji(search: 'fir');
      expect(res.any((e) => e.emoji == '🔥'), isTrue);
      expect(res.first.insertText, endsWith(' '));
    });

    test('emoji results are capped at 8', () {
      final res = queryEmoji(search: 'a');
      expect(res.length, lessThanOrEqualTo(8));
    });

    test('mention results are capped at 8', () {
      final users = <String, User>{
        for (var i = 0; i < 20; i++)
          '${i.toString().padLeft(60, '0')}aa0$i':
              _user('${i.toString().padLeft(60, '0')}aa0$i', 'user$i'),
      };
      final res = queryMentions(
        users: users,
        search: 'user',
        currentChannelKey: 'nymchat',
      );
      expect(res.length, 8);
    });

    test('kaomoji filters by category label', () {
      final sections = queryKaomoji(search: 'joy');
      expect(sections.length, 1);
      expect(sections.single.label, 'Joy');
      expect(kaomojiInsertText('(◕‿◕)'), '(◕‿◕) ');
    });
  });
}

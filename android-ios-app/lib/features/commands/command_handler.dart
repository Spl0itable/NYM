// Slash-command dispatcher — the effectful half of the command system. Ports
// `handleCommand` + every `cmd*` handler (commands.js) into engine calls on the
// [NostrController], with context gating, the shared action rate limit, and a
// system-message sink that mirrors `displaySystemMessage`.
//
// Commands that open modals owned by OTHER agents (poll editor, nick/zap
// dialogs, group/invite pickers) are wired through optional callback hooks
// rather than hard dependencies — when a hook is unset the handler reports the
// usage/system message exactly as the PWA would, but does not crash. See the
// CommandHooks fields + their TODO(verify) notes.

import '../../core/utils/nym_utils.dart';
import '../../models/user.dart';
import '../i18n/i18n.dart';
import 'action_rate_limit.dart';
import 'command_registry.dart';
import 'help_output.dart';

/// The effects a command can request. The controller supplies these; the
/// handler never reaches into app_state directly (it is not an owner of it).
abstract class CommandEngine {
  /// Current view context.
  bool get inPM;
  bool get inGroup;

  /// Self identity (for self-target checks).
  String get selfPubkey;

  /// All known users (for `@nym` / `nym#xxxx` / hex resolution).
  Map<String, User> get users;

  /// Sends [content] to the current conversation surface
  /// (`_sendToCurrentTarget`).
  void sendToCurrentTarget(String content);

  /// Surfaces a system message in the active conversation
  /// (`displaySystemMessage`).
  void systemMessage(String text);

  // Direct engine actions (each maps to an existing controller method).
  void join(String channel);

  /// `/clear` — `cmdClear` (commands.js:689-692): empties the rendered
  /// conversation (`messagesContainer.innerHTML = ''`), THEN shows the
  /// 'Chat cleared' system line.
  void clear();
  void leave();
  void quit();
  void setNick(String newNym);
  void who();
  void setAway(String message);
  void clearAway();
  void share();
  void block(String arg);
  void unblock(String arg);
}

/// Optional UI/modal hooks for commands whose effect is owned by another agent.
/// Unset hooks degrade gracefully (the handler shows the same system text the
/// PWA shows when the surface isn't available).
class CommandHooks {
  const CommandHooks({
    this.openPoll,
    this.openPm,
    this.openZap,
    this.invite,
    this.openShare,
    this.createGroup,
    this.addMember,
    this.groupInfo,
    this.kick,
    this.ban,
    this.unban,
    this.addMod,
    this.removeMod,
    this.transferOwner,
    this.openDevNsecChallenge,
  });

  /// `/poll` → open the poll editor modal (polls agent). TODO(verify): modal
  /// owned by another agent; wire when available.
  final void Function()? openPoll;

  /// `/pm <resolved pubkey>` → open/create the PM thread.
  final void Function(String pubkey, String nym)? openPm;

  /// `/zap <resolved pubkey>` → open the zap modal (zaps agent). TODO(verify).
  final void Function(String pubkey, String nym)? openZap;

  /// `/invite <arg>` → channel-invite / startGroupFromPM / addMemberToGroup.
  /// TODO(verify): group/PM invite flow spans pms/groups agents.
  final void Function(String arg)? invite;

  /// `/share` → `shareChannel()` (channels.js:411-427): opens the Share
  /// Channel modal (`#shareModal`) with `origin+pathname#<channel||'nymchat'>`
  /// in the readonly input, auto-selected. The modal is [ShareChannelModal]
  /// (features/channels/channel_share.dart), owned by the channels UI.
  final void Function()? openShare;

  /// `/group <@u1 @u2 [name]>` → resolve members + createGroup.
  final void Function(List<String> memberPubkeys, String name)? createGroup;

  /// `/addmember <arg>` → add to current group / startGroupFromPM.
  final void Function(String arg)? addMember;

  /// `/groupinfo` → list members by role.
  final void Function()? groupInfo;

  // Group moderation (groups agent). Each resolves the target then acts.
  final void Function(String pubkey)? kick;
  final void Function(String pubkey)? ban;
  final void Function(String pubkey)? unban;
  final void Function(String pubkey)? addMod;
  final void Function(String pubkey)? removeMod;
  final void Function(String pubkey)? transferOwner;

  /// `/nick <reserved>` → the developer-nsec challenge modal
  /// (`showDevNsecModal('nick')` → `applyDeveloperIdentity` on success,
  /// commands.js:614-626). The hook owns the whole outcome: verify → switch
  /// the running session to the developer identity + the "Identity verified…"
  /// line, cancel → the PWA's 'Nickname change cancelled.' line. Unset
  /// (headless/tests) → the engine's reserved gate aborts with the same
  /// cancellation message.
  final void Function()? openDevNsecChallenge;
}

/// Resolves a `@nym` / `nym#xxxx` / 64-hex target to a pubkey + display nym, or
/// null. Mirrors the matching logic shared by cmdSlap/cmdHug/cmdInvite: strip a
/// leading `@`, accept a raw hex pubkey, else match base nym (case-insensitive)
/// optionally constrained by a `#suffix`.
class ResolvedTarget {
  const ResolvedTarget(this.pubkey, this.nym);
  final String pubkey;
  final String nym;
}

final RegExp _hex64Re = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

ResolvedTarget? resolveTarget(String raw, Map<String, User> users) {
  final input = raw.trim().replaceFirst(RegExp(r'^@'), '');
  if (input.isEmpty) return null;

  if (_hex64Re.hasMatch(input)) {
    final pk = input.toLowerCase();
    final u = users[pk];
    return ResolvedTarget(pk, u?.nym ?? 'nym#${pk.substring(pk.length - 4)}');
  }

  final hashIndex = input.indexOf('#');
  final searchNym = hashIndex == -1 ? input : input.substring(0, hashIndex);
  final searchSuffix = hashIndex == -1 ? null : input.substring(hashIndex + 1);

  final matches = <ResolvedTarget>[];
  users.forEach((pubkey, user) {
    final cleanNym = stripPubkeySuffix(user.nym);
    if (cleanNym.toLowerCase() == searchNym.toLowerCase()) {
      if (searchSuffix != null) {
        if (pubkey.endsWith(searchSuffix)) {
          matches.add(ResolvedTarget(pubkey, cleanNym));
        }
      } else {
        matches.add(ResolvedTarget(pubkey, cleanNym));
      }
    }
  });

  if (matches.isEmpty) return null;
  return matches.first;
}

/// Dispatches parsed slash commands to engine effects.
class CommandDispatcher {
  CommandDispatcher({
    required this.engine,
    this.hooks = const CommandHooks(),
    ActionCommandRateLimiter? rateLimiter,
  }) : rateLimiter = rateLimiter ?? ActionCommandRateLimiter();

  final CommandEngine engine;

  /// Modal/UI hooks. Mutable so the controller can register them after the UI
  /// mounts (via [hooksOverride]).
  CommandHooks hooks;
  final ActionCommandRateLimiter rateLimiter;

  /// Swaps in a new hook set (used by the controller's setCommandHooks).
  set hooksOverride(CommandHooks value) => hooks = value;

  /// Routes [line] (a `/cmd args` string). Returns true if it was a command
  /// (known or not) and therefore should NOT be published as a message.
  bool handle(String line) {
    final parsed = parseCommand(line);
    final spec = parsed.spec;
    if (spec == null) {
      engine.systemMessage(
          tr('Unknown command: {cmd}', {'cmd': parsed.token}));
      return true;
    }

    // Context gate (the PWA enforces this inside each handler).
    if (!isAllowedIn(spec, inPM: engine.inPM, inGroup: engine.inGroup)) {
      engine.systemMessage(_gateMessage(spec));
      return true;
    }

    _dispatch(spec, parsed.args);
    return true;
  }

  String _gateMessage(CommandSpec spec) {
    switch (spec.id) {
      case 'who':
        return tr('/who only works in public channels.');
      case 'poll':
        return tr(
            'Polls can only be created in channels, not in private messages.');
      case 'groupinfo':
      case 'kick':
      case 'ban':
      case 'unban':
      case 'addmod':
      case 'removemod':
      case 'transferowner':
        return tr('You must be in a group conversation to use this command.');
      default:
        return tr('This command is not available here.');
    }
  }

  void _dispatch(CommandSpec spec, String args) {
    switch (spec.id) {
      case 'help':
        // `showHelp()` (commands.js:522-546): the full categorized listing —
        // title, per-category headers, "/name, /alias — desc" rows, and the
        // five footer lines — posted as a system message. The styled
        // `.help-output` rendering is [HelpOutputBlock] (help_output.dart);
        // this emits the identical content through the plain-text sink.
        engine.systemMessage(buildHelpMessageText());
      case 'join':
        if (args.isEmpty) {
          engine.systemMessage(tr(
              'Usage: /join #channel (e.g., /join #9q5, /join #nymchat, or /join nym)'));
          return;
        }
        engine.join(args.trim());
      case 'pm':
        _pm(args);
      case 'nick':
        if (args.isEmpty) {
          engine.systemMessage(tr('Usage: /nick newnym'));
          return;
        }
        engine.setNick(args.trim());
      case 'who':
        engine.who();
      case 'clear':
        engine.clear();
      case 'leave':
        engine.leave();
      case 'quit':
        engine.quit();
      case 'me':
        _action(args, () {
          if (args.isEmpty) {
            engine.systemMessage(tr('Usage: /me action'));
            return false;
          }
          return true;
        }, () => spec.formatter!(args));
      case 'slap':
        _actionTarget(args, 'slap',
            tr('Usage: /slap nym, /slap nym#xxxx, or /slap [pubkey]'),
            (mention) => '/me slaps $mention around a bit with a large trout 🐟');
      case 'hug':
        _actionTarget(args, 'hug',
            tr('Usage: /hug nym, /hug nym#xxxx, or /hug [pubkey]'),
            (mention) => '/me gives $mention a warm hug 🫂');
      case 'bold':
      case 'italic':
      case 'strike':
      case 'code':
      case 'quote':
        if (args.isEmpty) {
          engine.systemMessage(tr('Usage: {cmd} text', {'cmd': spec.name}));
          return;
        }
        engine.sendToCurrentTarget(spec.formatter!(args));
      case 'brb':
        if (args.isEmpty) {
          engine.systemMessage(
              tr('Usage: /brb message (e.g., /brb lunch, back in 30)'));
          return;
        }
        engine.setAway(args.trim());
      case 'back':
        engine.clearAway();
      case 'zap':
        _zap(args);
      case 'poll':
        // `/poll` → the poll editor modal (polls agent). When no hook is wired
        // (headless/tests) this degrades to nothing, matching the prior no-op.
        hooks.openPoll?.call();
      case 'share':
        // `cmdShare` → `shareChannel()` (channels.js:411-427) opens the Share
        // Channel modal — works even in PM mode (URL falls back to the current
        // channel or 'nymchat'). Prefer the modal hook; engine.share() is the
        // headless fallback.
        if (hooks.openShare != null) {
          hooks.openShare!();
        } else {
          engine.share();
        }
      case 'block':
        engine.block(args);
      case 'unblock':
        if (args.isEmpty) {
          engine.systemMessage(tr(
              'Usage: /unblock nym, /unblock nym#xxxx, /unblock [pubkey], or /unblock #channel'));
          return;
        }
        engine.unblock(args);
      case 'invite':
        _hookOrSystem(hooks.invite, args, tr('Usage: /invite @nym'));
      case 'group':
        _group(args);
      case 'addmember':
        _hookOrSystem(hooks.addMember, args, tr('Usage: /addmember @nym'));
      case 'groupinfo':
        hooks.groupInfo?.call();
      case 'kick':
        _modTarget(args, hooks.kick, tr('Usage: /kick @nym (or hex pubkey)'),
            blockSelf: tr("You can't kick yourself."));
      case 'ban':
        _modTarget(args, hooks.ban, tr('Usage: /ban @nym (or hex pubkey)'),
            blockSelf: tr("You can't ban yourself."));
      case 'unban':
        _modTarget(args, hooks.unban, tr('Usage: /unban @nym (or hex pubkey)'));
      case 'addmod':
        _modTarget(
            args, hooks.addMod, tr('Usage: /addmod @nym (or hex pubkey)'));
      case 'removemod':
        _modTarget(args, hooks.removeMod,
            tr('Usage: /removemod @nym (or hex pubkey)'));
      case 'transferowner':
        _modTarget(args, hooks.transferOwner,
            tr('Usage: /transferowner @nym (or hex pubkey)'),
            blockSelf: tr("You're already the owner."));
      default:
        engine.systemMessage(tr('Unknown command: {cmd}', {'cmd': spec.name}));
    }
  }

  // --- helpers --------------------------------------------------------------

  void _pm(String args) {
    if (args.isEmpty) {
      engine.systemMessage(
          tr('Usage: /pm @nym, /pm nym#xxxx, or /pm [pubkey]'));
      return;
    }
    final t = resolveTarget(args, engine.users);
    if (t == null) {
      engine.systemMessage(tr('User {user} not found', {'user': args.trim()}));
      return;
    }
    if (t.pubkey == engine.selfPubkey) {
      engine.systemMessage(tr("You can't PM yourself"));
      return;
    }
    if (hooks.openPm != null) {
      hooks.openPm!(t.pubkey, t.nym);
    }
  }

  void _zap(String args) {
    if (args.isEmpty) {
      engine.systemMessage(
          tr('Usage: /zap @nym, /zap nym#xxxx, or /zap [pubkey]'));
      return;
    }
    final t = resolveTarget(args, engine.users);
    if (t == null) {
      engine.systemMessage(tr('User {user} not found', {'user': args.trim()}));
      return;
    }
    if (t.pubkey == engine.selfPubkey) {
      // PWA cmdZap blocks self-zapping via the command (zaps.js:1947/2007).
      // Self-zapping your own MESSAGE via the badge is still allowed elsewhere.
      engine.systemMessage(tr("You can't zap yourself"));
      return;
    }
    hooks.openZap?.call(t.pubkey, t.nym);
  }

  void _group(String args) {
    // Resolve every @token (excluding self) then hand to createGroup. A
    // trailing non-@ token list tail is treated as the optional name.
    final tokens = args.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    final members = <String>[];
    final nameParts = <String>[];
    for (final tok in tokens) {
      if (tok.startsWith('@') || _hex64Re.hasMatch(tok)) {
        final t = resolveTarget(tok, engine.users);
        if (t != null && t.pubkey != engine.selfPubkey) {
          members.add(t.pubkey);
        }
      } else {
        nameParts.add(tok);
      }
    }
    if (hooks.createGroup != null) {
      hooks.createGroup!(members, nameParts.join(' '));
    }
  }

  void _action(
      String args, bool Function() validate, String Function() build) {
    if (!validate()) return;
    final rl = rateLimiter.check();
    if (!rl.allowed) {
      engine.systemMessage(rl.message!);
      return;
    }
    engine.sendToCurrentTarget(build());
  }

  void _actionTarget(String args, String verb, String usage,
      String Function(String mention) build) {
    if (args.isEmpty) {
      engine.systemMessage(usage);
      return;
    }
    final rl = rateLimiter.check();
    if (!rl.allowed) {
      engine.systemMessage(rl.message!);
      return;
    }
    final t = resolveTarget(args, engine.users);
    // Use a full @nym#suffix mention when resolved (avatar/flair render);
    // otherwise the bare typed nym (cmdSlap/cmdHug fallback).
    final mention = t != null
        ? '@${stripPubkeySuffix(t.nym)}#${getPubkeySuffix(t.pubkey)}'
        : '@${args.trim().replaceFirst(RegExp(r'^@'), '')}';
    engine.sendToCurrentTarget(build(mention));
  }

  void _modTarget(
      String args, void Function(String pubkey)? hook, String usage,
      {String? blockSelf}) {
    if (args.trim().isEmpty) {
      engine.systemMessage(usage);
      return;
    }
    final t = resolveTarget(args, engine.users);
    if (t == null) {
      engine.systemMessage(tr(
          'User @{user} not found. Try @nym#xxxx or a hex pubkey.',
          {'user': args.trim().replaceFirst(RegExp(r'^@'), '')}));
      return;
    }
    if (blockSelf != null && t.pubkey == engine.selfPubkey) {
      engine.systemMessage(blockSelf);
      return;
    }
    hook?.call(t.pubkey);
  }

  void _hookOrSystem(
      void Function(String arg)? hook, String args, String usage) {
    if (hook != null) {
      hook(args);
    } else if (args.trim().isEmpty) {
      engine.systemMessage(usage);
    }
  }
}

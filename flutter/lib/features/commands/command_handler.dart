// Slash-command dispatcher; modal-opening commands go through optional hooks and degrade to the PWA's system text when unset.

import '../../core/utils/nym_utils.dart';
import '../../models/user.dart';
import '../i18n/i18n.dart';
import '../messages/format/nym_format.dart' show NymFormat;
import 'action_rate_limit.dart';
import 'command_i18n.dart';
import 'command_registry.dart';
import 'help_output.dart';

/// Effects a command can request; the handler never touches app_state directly.
abstract class CommandEngine {
  bool get inPM;
  bool get inGroup;

  String get selfPubkey;

  /// All known users, for `@nym`, `nym#xxxx` and hex resolution.
  Map<String, User> get users;

  void sendToCurrentTarget(String content);

  void systemMessage(String text);

  void join(String channel);

  /// Empties the rendered conversation, then shows 'Chat cleared'.
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

/// Optional UI hooks for commands whose surface lives elsewhere; unset hooks degrade gracefully.
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
    this.addAdmin,
    this.removeAdmin,
    this.transferOwner,
    this.openDevNsecChallenge,
    this.openTimestampPicker,
  });

  final void Function()? openPoll;

  final void Function(String pubkey, String nym)? openPm;

  final void Function(String pubkey, String nym)? openZap;

  /// `/invite <arg>`: channel invite, startGroupFromPM, or addMemberToGroup.
  final void Function(String arg)? invite;

  /// `/share` opens [ShareChannelModal].
  final void Function()? openShare;

  /// `/group <@u1 @u2 [name]>`: resolve members, then create the group.
  final void Function(List<String> memberPubkeys, String name)? createGroup;

  /// `/addmember <arg>`: add to the current group or startGroupFromPM.
  final void Function(String arg)? addMember;

  final void Function()? groupInfo;

  // Group moderation; each resolves the target, then acts.
  final void Function(String pubkey)? kick;
  final void Function(String pubkey)? ban;
  final void Function(String pubkey)? unban;
  final void Function(String pubkey)? addMod;
  final void Function(String pubkey)? removeMod;
  final void Function(String pubkey)? addAdmin;
  final void Function(String pubkey)? removeAdmin;
  final void Function(String pubkey)? transferOwner;

  /// `/nick <reserved>`: the hook owns verification and the outcome; unset, the reserved gate aborts as canceled.
  final void Function()? openDevNsecChallenge;

  final void Function()? openTimestampPicker;
}

/// Resolves `@nym`, `nym#xxxx` or 64-hex to a pubkey and display nym, or null.
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

class CommandDispatcher {
  CommandDispatcher({
    required this.engine,
    this.hooks = const CommandHooks(),
    ActionCommandRateLimiter? rateLimiter,
  }) : rateLimiter = rateLimiter ?? ActionCommandRateLimiter();

  final CommandEngine engine;

  /// Mutable so the controller can register hooks after the UI mounts.
  CommandHooks hooks;
  final ActionCommandRateLimiter rateLimiter;

  set hooksOverride(CommandHooks value) => hooks = value;

  /// Routes a `/cmd args` line; true if it was a command (known or not) and must not be published.
  bool handle(String line) {
    // Localized command tokens resolve to canonical ones before dispatch.
    final parsed = parseCommand(canonicalizeCommandInput(line));
    final spec = parsed.spec;
    if (spec == null) {
      engine.systemMessage(tr('Unknown command: {cmd}', {'cmd': parsed.token}));
      return true;
    }

    // Context gate.
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
      case 'groupinfo':
      case 'kick':
      case 'ban':
      case 'unban':
      case 'addmod':
      case 'removemod':
      case 'addadmin':
      case 'removeadmin':
      case 'transferowner':
        return tr('You must be in a group conversation to use this command.');
      default:
        return tr('This command is not available here.');
    }
  }

  void _dispatch(CommandSpec spec, String args) {
    switch (spec.id) {
      case 'help':
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
        _actionTarget(
            args,
            'slap',
            tr('Usage: /slap nym, /slap nym#xxxx, or /slap [pubkey]'),
            (mention) =>
                '/me slaps $mention around a bit with a large trout 🐟');
      case 'hug':
        _actionTarget(
            args,
            'hug',
            tr('Usage: /hug nym, /hug nym#xxxx, or /hug [pubkey]'),
            (mention) => '/me gives $mention a warm hug 🫂');
      case 'bold':
      case 'italic':
      case 'underline':
      case 'strike':
      case 'spoiler':
      case 'subtext':
      case 'code':
      case 'quote':
        if (args.isEmpty) {
          engine.systemMessage(tr('Usage: {cmd} text', {'cmd': spec.name}));
          return;
        }
        engine.sendToCurrentTarget(spec.formatter!(args));
      case 'timestamp':
        if (args.trim().isEmpty) {
          hooks.openTimestampPicker?.call();
          return;
        }
        final parsed = NymFormat.parseTimestampInput(args);
        if (parsed == null) {
          engine.systemMessage(tr(
              'Usage: /timestamp YYYY-MM-DD HH:MM [t|T|d|D|f|F|R], or /timestamp with no arguments to pick a date'));
          return;
        }
        engine.sendToCurrentTarget(parsed.tag);
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
        // No-op when no hook is wired.
        hooks.openPoll?.call();
      case 'share':
        // Works even in PM mode; engine.share() is the headless fallback.
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
      case 'addadmin':
        _modTarget(
            args, hooks.addAdmin, tr('Usage: /addadmin @nym (or hex pubkey)'));
      case 'removeadmin':
        _modTarget(args, hooks.removeAdmin,
            tr('Usage: /removeadmin @nym (or hex pubkey)'));
      case 'transferowner':
        _modTarget(args, hooks.transferOwner,
            tr('Usage: /transferowner @nym (or hex pubkey)'),
            blockSelf: tr("You're already the owner."));
      default:
        engine.systemMessage(tr('Unknown command: {cmd}', {'cmd': spec.name}));
    }
  }

  void _pm(String args) {
    if (args.isEmpty) {
      engine
          .systemMessage(tr('Usage: /pm @nym, /pm nym#xxxx, or /pm [pubkey]'));
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
      // Self-zap is blocked only via the command; zapping your own message badge is allowed.
      engine.systemMessage(tr("You can't zap yourself"));
      return;
    }
    hooks.openZap?.call(t.pubkey, t.nym);
  }

  void _group(String args) {
    // Resolve every @token except self; a trailing non-@ tail is the optional name.
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

  void _action(String args, bool Function() validate, String Function() build) {
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
    // Full @nym#suffix mention when resolved, else the bare typed nym.
    final mention = t != null
        ? '@${stripPubkeySuffix(t.nym)}#${getPubkeySuffix(t.pubkey)}'
        : '@${args.trim().replaceFirst(RegExp(r'^@'), '')}';
    engine.sendToCurrentTarget(build(mention));
  }

  void _modTarget(String args, void Function(String pubkey)? hook, String usage,
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

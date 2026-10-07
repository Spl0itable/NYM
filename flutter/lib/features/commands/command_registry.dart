// Pure slash-command data and parse layer; effects live in the controller, dispatched on [CommandSpec.id].

import '../nymbot/bot_commands.dart';

/// Where a command may run; gated declaratively so the palette can still list everything.
enum CommandContext {
  /// Runs anywhere.
  all,

  /// Public channels only; rejected in PM or group.
  channel,

  /// Channel-only like [channel], kept distinct to match the spec's "channels only".
  channelOnly,

  /// Group conversations only.
  groupOnly,
}

/// Palette and `/help` categories, in PWA order.
enum CommandCategory { channels, pms, groups, formatting, misc }

const Map<CommandCategory, String> kCommandCategoryLabels = {
  CommandCategory.channels: 'Public Channels',
  CommandCategory.pms: 'Private Messages',
  CommandCategory.groups: 'Groups',
  CommandCategory.formatting: 'Formatting',
  CommandCategory.misc: 'Misc',
};

const List<CommandCategory> kCommandCategoryOrder = [
  CommandCategory.channels,
  CommandCategory.pms,
  CommandCategory.groups,
  CommandCategory.formatting,
  CommandCategory.misc,
];

/// One command; [aliases] are single-letter shortcuts resolving to the same [id].
class CommandSpec {
  const CommandSpec({
    required this.id,
    required this.name,
    required this.desc,
    required this.category,
    this.aliases = const [],
    this.context = CommandContext.all,
    this.takesArgs = false,
    this.formatter,
  });

  /// Stable dispatch id (the PWA `cmd*` method name without the prefix).
  final String id;

  /// Canonical token including the leading slash (`/join`).
  final String name;

  final String desc;

  final CommandCategory category;

  /// Slash-prefixed aliases (`['/j']`).
  final List<String> aliases;

  final CommandContext context;

  /// Whether it takes arguments; completion then inserts a trailing space.
  final bool takesArgs;

  /// For formatting commands, maps the raw arg to the exact wire text (`/bold x` -> `**x**`); null otherwise.
  final String Function(String args)? formatter;
}

/// The 33 canonical commands with the PWA's descriptions, categories, aliases and context gates.
const List<CommandSpec> kCommandSpecs = [
  CommandSpec(
    id: 'help',
    name: '/help',
    desc: 'Show all commands',
    category: CommandCategory.misc,
  ),
  CommandSpec(
    id: 'join',
    name: '/join',
    desc: 'Join channel',
    category: CommandCategory.channels,
    aliases: ['/j'],
    takesArgs: true,
  ),
  CommandSpec(
    id: 'pm',
    name: '/pm',
    desc: 'Send private message',
    category: CommandCategory.pms,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'nick',
    name: '/nick',
    desc: 'Change nickname',
    category: CommandCategory.misc,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'who',
    name: '/who',
    desc: 'Show active users',
    category: CommandCategory.channels,
    aliases: ['/w'],
    context: CommandContext.channel,
  ),
  CommandSpec(
    id: 'clear',
    name: '/clear',
    desc: 'Clear conversation',
    category: CommandCategory.misc,
  ),
  CommandSpec(
    id: 'me',
    name: '/me',
    desc: 'Action message',
    category: CommandCategory.misc,
    takesArgs: true,
    // `/me x` is sent verbatim.
    formatter: _meFormatter,
  ),
  CommandSpec(
    id: 'bold',
    name: '/bold',
    desc: 'Bold text (**text**)',
    category: CommandCategory.formatting,
    aliases: ['/b'],
    takesArgs: true,
    formatter: _boldFormatter,
  ),
  CommandSpec(
    id: 'italic',
    name: '/italic',
    desc: 'Italic text (*text*)',
    category: CommandCategory.formatting,
    aliases: ['/i'],
    takesArgs: true,
    formatter: _italicFormatter,
  ),
  CommandSpec(
    id: 'underline',
    name: '/underline',
    desc: 'Underline text (__text__)',
    category: CommandCategory.formatting,
    aliases: ['/u'],
    takesArgs: true,
    formatter: _underlineFormatter,
  ),
  CommandSpec(
    id: 'strike',
    name: '/strike',
    desc: 'Strikethrough text (~~text~~)',
    category: CommandCategory.formatting,
    aliases: ['/s'],
    takesArgs: true,
    formatter: _strikeFormatter,
  ),
  CommandSpec(
    id: 'spoiler',
    name: '/spoiler',
    desc: 'Spoiler text (||text||)',
    category: CommandCategory.formatting,
    takesArgs: true,
    formatter: _spoilerFormatter,
  ),
  CommandSpec(
    id: 'subtext',
    name: '/subtext',
    desc: 'Small dimmed text (-# text)',
    category: CommandCategory.formatting,
    takesArgs: true,
    formatter: _subtextFormatter,
  ),
  CommandSpec(
    id: 'timestamp',
    name: '/timestamp',
    desc: "Timestamp in each reader's time zone",
    category: CommandCategory.formatting,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'code',
    name: '/code',
    desc: 'Code block (`code`)',
    category: CommandCategory.formatting,
    aliases: ['/c'],
    takesArgs: true,
    formatter: _codeFormatter,
  ),
  CommandSpec(
    id: 'quote',
    name: '/quote',
    desc: 'Quote text (> quote)',
    category: CommandCategory.formatting,
    aliases: ['/q'],
    takesArgs: true,
    formatter: _quoteFormatter,
  ),
  CommandSpec(
    id: 'brb',
    name: '/brb',
    desc: 'Set away message',
    category: CommandCategory.misc,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'back',
    name: '/back',
    desc: 'Clear away message',
    category: CommandCategory.misc,
  ),
  CommandSpec(
    id: 'search',
    name: '/search',
    desc: 'Search this chat',
    category: CommandCategory.misc,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'zap',
    name: '/zap',
    desc: 'Zap profile',
    category: CommandCategory.misc,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'block',
    name: '/block',
    desc: 'Block user/#channel',
    category: CommandCategory.pms,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'unblock',
    name: '/unblock',
    desc: 'Unblock user/#channel',
    category: CommandCategory.pms,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'invite',
    name: '/invite',
    desc: 'Invite to chat',
    category: CommandCategory.pms,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'group',
    name: '/group',
    desc: 'Create private group',
    category: CommandCategory.groups,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'addmember',
    name: '/addmember',
    desc: 'Add group member',
    category: CommandCategory.groups,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'groupinfo',
    name: '/groupinfo',
    desc: 'Show group members',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
  ),
  CommandSpec(
    id: 'share',
    name: '/share',
    desc: 'Share #channel URL',
    category: CommandCategory.channels,
    // No context gate: share works in PM mode too.
  ),
  CommandSpec(
    id: 'leave',
    name: '/leave',
    desc: 'Leave conversation',
    category: CommandCategory.pms,
  ),
  CommandSpec(
    id: 'poll',
    name: '/poll',
    desc: 'Create poll',
    category: CommandCategory.channels,
  ),
  CommandSpec(
    id: 'kick',
    name: '/kick',
    desc: 'Remove member (owner/mod)',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'ban',
    name: '/ban',
    desc: 'Ban member (owner/admin/mod)',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'unban',
    name: '/unban',
    desc: 'Unban member (owner/admin/mod)',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'addmod',
    name: '/addmod',
    desc: 'Promote to moderator (owner/admin)',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'addadmin',
    name: '/addadmin',
    desc: 'Promote to admin (owner)',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'removeadmin',
    name: '/removeadmin',
    desc: 'Remove admin (owner)',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'removemod',
    name: '/removemod',
    desc: 'Remove moderator (owner/admin)',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'transferowner',
    name: '/transferowner',
    desc: 'Change group ownership',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'slap',
    name: '/slap',
    desc: 'Slap someone with a trout 🐟',
    category: CommandCategory.misc,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'hug',
    name: '/hug',
    desc: 'Give someone a warm hug 🫂',
    category: CommandCategory.misc,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'quit',
    name: '/quit',
    desc: 'Disconnect from Nymchat',
    category: CommandCategory.misc,
  ),
];

// Public `?` palette rows derived from [kBotCommands], flat and excluding the PM-only credit commands.

/// One public `?` palette row: token with its `?` prefix and description.
class BotPaletteCommand {
  const BotPaletteCommand({required this.command, required this.desc});

  final String command;

  final String desc;
}

/// Public `?` palette catalog in catalog order, without credit/PM-only commands.
final List<BotPaletteCommand> kBotPaletteCommands = [
  for (final c in kBotCommands)
    if (!c.creditCommand)
      BotPaletteCommand(command: '?${c.name}', desc: c.description),
];

/// Rows whose `?cmd` starts with the lowercased input, in catalog order; empty hides the palette.
List<BotPaletteCommand> buildBotPaletteRows(String input) {
  final needle = input.toLowerCase();
  return [
    for (final c in kBotPaletteCommands)
      if (c.command.startsWith(needle)) c,
  ];
}

// Exact strings the PWA's formatting commands send.
String _meFormatter(String args) => '/me $args';
String _boldFormatter(String args) => '**$args**';
String _italicFormatter(String args) => '*$args*';
String _underlineFormatter(String args) => '__${args}__';
String _strikeFormatter(String args) => '~~$args~~';
String _spoilerFormatter(String args) => '||$args||';
String _subtextFormatter(String args) => '-# $args';
String _codeFormatter(String args) => '```\n$args\n```';
String _quoteFormatter(String args) => '> $args';

/// The action commands that share the rate limit.
const Set<String> kActionCommandIds = {'me', 'slap', 'hug'};

/// Every canonical name and alias -> its [CommandSpec].
final Map<String, CommandSpec> _byToken = _buildTokenIndex();

Map<String, CommandSpec> _buildTokenIndex() {
  final map = <String, CommandSpec>{};
  for (final spec in kCommandSpecs) {
    map[spec.name] = spec;
    for (final a in spec.aliases) {
      map[a] = spec;
    }
  }
  return map;
}

class ParsedCommand {
  const ParsedCommand({
    required this.token,
    required this.args,
    required this.spec,
  });

  final String token;

  /// Everything after the first space, rejoined with single spaces; empty if none.
  final String args;

  /// Alias-collapsed spec, or null if unknown.
  final CommandSpec? spec;

  bool get isKnown => spec != null;
}

/// Splits on spaces like the PWA: lowercased first token, rest rejoined as args.
ParsedCommand parseCommand(String command) {
  final parts = command.split(' ');
  final token = parts[0].toLowerCase();
  final args = parts.length > 1 ? parts.sublist(1).join(' ') : '';
  return ParsedCommand(token: token, args: args, spec: _byToken[token]);
}

CommandSpec? resolveCommand(String token) => _byToken[token.toLowerCase()];

/// Whether [text] routes to the command handler instead of being published.
bool isCommandLine(String text) => text.startsWith('/');

List<CommandSpec> visibleCommands() => kCommandSpecs;

/// `"/join, /j"` display form.
String formatCommandDisplay(CommandSpec spec) {
  if (spec.aliases.isEmpty) return spec.name;
  return '${spec.name}, ${spec.aliases.join(', ')}';
}

/// channel/channelOnly reject PMs and groups; groupOnly rejects all but a group.
bool isAllowedIn(CommandSpec spec,
    {required bool inPM, required bool inGroup}) {
  switch (spec.context) {
    case CommandContext.all:
      return true;
    case CommandContext.channel:
    case CommandContext.channelOnly:
      return !inPM && !inGroup;
    case CommandContext.groupOnly:
      return inGroup;
  }
}

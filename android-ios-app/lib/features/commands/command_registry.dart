// Slash-command registry — a 1:1 port of `js/modules/commands.js`
// `setupCommands()` + `handleCommand()` (docs/specs/03 §7).
//
// This file is the PURE data + parse layer: it knows every command, its
// aliases, category, description, the context it is allowed to run in, and how
// formatting commands transform their argument into wire text. The side
// effects (joining channels, opening PMs, publishing, etc.) live in the
// controller, which dispatches on [CommandSpec.id] — see
// `command_handler.dart`. Keeping the registry side-effect-free makes the
// parser, alias resolution, gating, and formatting unit-testable without a
// running engine (test/commands_test.dart).

import '../nymbot/bot_commands.dart';

/// Where a command is allowed to run, mirroring the "Context" column of the
/// §7 table. The PWA enforces this inside each `cmd*` handler (e.g. `/who`
/// errors in PMs, `/poll` errors in PM/group, group-only commands require an
/// active group). We model the gate declaratively so the controller can reject
/// before dispatching and the palette can still show everything (the PWA lists
/// all commands regardless of context).
enum CommandContext {
  /// Runs anywhere (channel, PM, or group).
  all,

  /// Public-channel only (`/who`). Rejected in PM/group.
  channel,

  /// Channel-only AND never in a PM (`/poll`). Same as [channel] for gating
  /// but kept distinct to match the §7 "channels only" wording.
  channelOnly,

  /// Group conversation only (`/groupinfo`, `/kick`, `/ban`, `/unban`,
  /// `/addmod`, `/removemod`, `/transferowner`). Rejected outside a group.
  groupOnly,
}

/// The category buckets used by the command palette + `/help`, in PWA order
/// (`commandCategories`, commands.js:324).
enum CommandCategory { channels, pms, groups, formatting, misc }

/// Category display labels, verbatim from `commandCategories` (commands.js:324).
const Map<CommandCategory, String> kCommandCategoryLabels = {
  CommandCategory.channels: 'Public Channels',
  CommandCategory.pms: 'Private Messages',
  CommandCategory.groups: 'Groups',
  CommandCategory.formatting: 'Formatting',
  CommandCategory.misc: 'Misc',
};

/// Ordered category list (palette/help iterate in this order).
const List<CommandCategory> kCommandCategoryOrder = [
  CommandCategory.channels,
  CommandCategory.pms,
  CommandCategory.groups,
  CommandCategory.formatting,
  CommandCategory.misc,
];

/// A single command definition. The canonical key is [name] (e.g. `/join`).
/// [aliases] are single-letter shortcuts that resolve to the same [id].
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

  /// Stable dispatch id (matches the PWA `cmd*` method, sans prefix).
  final String id;

  /// Canonical command token including the leading slash (`/join`).
  final String name;

  /// One-line description (palette/help). Verbatim from the PWA registry.
  final String desc;

  final CommandCategory category;

  /// Slash-prefixed aliases (`['/j']`).
  final List<String> aliases;

  final CommandContext context;

  /// Whether the command consumes an argument string (drives palette
  /// completion inserting a trailing space, and usage hints).
  final bool takesArgs;

  /// For formatting commands (`/bold`, `/italic`, …): turns the raw arg into
  /// the exact wire text the PWA sends (`/bold x` → `**x**`). Null otherwise.
  final String Function(String args)? formatter;
}

/// The full command table — the 33 canonical commands `setupCommands()`
/// (commands.js:282) defines (the §7 prose says "34" but its own enumerated
/// list, and the authoritative `this.commands` object, both have 33), with the
/// same descriptions, categories, aliases, and the §7 context gates.
const List<CommandSpec> kCommandSpecs = [
  // --- misc ---------------------------------------------------------------
  CommandSpec(
    id: 'help',
    name: '/help',
    desc: 'Show all commands',
    category: CommandCategory.misc,
  ),
  // --- channels -----------------------------------------------------------
  CommandSpec(
    id: 'join',
    name: '/join',
    desc: 'Join channel',
    category: CommandCategory.channels,
    aliases: ['/j'],
    takesArgs: true,
  ),
  // --- pms ----------------------------------------------------------------
  CommandSpec(
    id: 'pm',
    name: '/pm',
    desc: 'Send private message',
    category: CommandCategory.pms,
    takesArgs: true,
  ),
  // --- misc ---------------------------------------------------------------
  CommandSpec(
    id: 'nick',
    name: '/nick',
    desc: 'Change nickname',
    category: CommandCategory.misc,
    takesArgs: true,
  ),
  // --- channels -----------------------------------------------------------
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
    // `/me x` is sent verbatim as `/me x` (rendered "* nym x *").
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
    id: 'strike',
    name: '/strike',
    desc: 'Strikethrough text (~~text~~)',
    category: CommandCategory.formatting,
    aliases: ['/s'],
    takesArgs: true,
    formatter: _strikeFormatter,
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
    id: 'zap',
    name: '/zap',
    desc: 'Zap profile',
    category: CommandCategory.misc,
    takesArgs: true,
  ),
  // --- pms ----------------------------------------------------------------
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
  // --- groups -------------------------------------------------------------
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
  // --- channels -----------------------------------------------------------
  CommandSpec(
    id: 'share',
    name: '/share',
    desc: 'Share #channel URL',
    category: CommandCategory.channels,
    // No context gate: `cmdShare` → `shareChannel()` (channels.js:411-427)
    // runs even in PM mode — the URL falls back to
    // `currentChannel || 'nymchat'`.
  ),
  // --- pms ----------------------------------------------------------------
  CommandSpec(
    id: 'leave',
    name: '/leave',
    desc: 'Leave conversation',
    category: CommandCategory.pms,
  ),
  // --- channels -----------------------------------------------------------
  CommandSpec(
    id: 'poll',
    name: '/poll',
    desc: 'Create poll',
    category: CommandCategory.channels,
    context: CommandContext.channelOnly,
  ),
  // --- groups -------------------------------------------------------------
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
    desc: 'Ban member (owner/mod)',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'unban',
    name: '/unban',
    desc: 'Unban member (owner)',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'addmod',
    name: '/addmod',
    desc: 'Promote to moderator (owner)',
    category: CommandCategory.groups,
    context: CommandContext.groupOnly,
    takesArgs: true,
  ),
  CommandSpec(
    id: 'removemod',
    name: '/removemod',
    desc: 'Remove moderator (owner)',
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
  // --- misc ---------------------------------------------------------------
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

// --- Public `?` Nymbot command palette ------------------------------------
// The `?`-prefixed bot command palette reuses the SAME `#commandPalette` surface
// as `/`, but with the PUBLIC bot command set (`showBotCommandPalette`,
// commands.js:436). Unlike `/`, the bot list is FLAT (no category headers) and
// renders in catalogue order, the first row pre-selected, filtered by
// `cmd.startsWith(input.toLowerCase())` where `cmd` includes its `?` prefix.
//
// We DERIVE the rows from the real bot-command catalogue (`kBotCommands` in
// features/nymbot/bot_commands.dart) rather than duplicating the list. The
// public channel palette excludes the "Credits (private Nymbot chat)" group
// (`?balance/?buy/?model/?git/?gift/?transfer`) — those are PM-only and live in
// the bot's private chat (`botPMCommands`), not the public `?` palette.

/// One selectable row of the public `?` bot-command palette: the command token
/// (including the leading `?`, e.g. `?flip`) and its one-line description. This
/// is the bot-command analogue of [CommandSpec] for the shared palette surface.
class BotPaletteCommand {
  const BotPaletteCommand({required this.command, required this.desc});

  /// The full command token shown as `.command-name`, including `?` (`?flip`).
  final String command;

  /// `.command-desc` text (the catalogue's README description).
  final String desc;
}

/// The public `?` palette catalogue, derived from [kBotCommands] in
/// catalogue order with the credit/PM-only commands filtered out. Built once.
final List<BotPaletteCommand> kBotPaletteCommands = [
  for (final c in kBotCommands)
    if (!c.creditCommand)
      BotPaletteCommand(command: '?${c.name}', desc: c.description),
];

/// Filters the public bot palette for [input] (the raw `?needle`). Mirrors
/// `showBotCommandPalette` (commands.js:442-443): a command matches when its
/// `?cmd` token starts with the lower-cased input. Returns the rows in
/// catalogue order, or an empty list when nothing matches (hide the palette).
List<BotPaletteCommand> buildBotPaletteRows(String input) {
  final needle = input.toLowerCase();
  return [
    for (final c in kBotPaletteCommands)
      if (c.command.startsWith(needle)) c,
  ];
}

// Formatting transforms — exact strings the PWA's cmd* handlers send.
String _meFormatter(String args) => '/me $args';
String _boldFormatter(String args) => '**$args**';
String _italicFormatter(String args) => '*$args*';
String _strikeFormatter(String args) => '~~$args~~';
String _codeFormatter(String args) => '```\n$args\n```';
String _quoteFormatter(String args) => '> $args';

/// The three action commands that share the rate limit (`/me`, `/slap`,
/// `/hug`) — `_checkActionCommandRateLimit` in commands.js.
const Set<String> kActionCommandIds = {'me', 'slap', 'hug'};

/// Lookup table: every canonical name AND alias → its [CommandSpec]. Built once.
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

/// Result of parsing a raw `/cmd args` line.
class ParsedCommand {
  const ParsedCommand({
    required this.token,
    required this.args,
    required this.spec,
  });

  /// The lowercased command token as typed (`/j`).
  final String token;

  /// Everything after the first space, joined back with single spaces — exactly
  /// `parts.slice(1).join(' ')` in the PWA. Empty string if no args.
  final String args;

  /// The resolved spec (alias-collapsed), or null if unknown.
  final CommandSpec? spec;

  bool get isKnown => spec != null;
}

/// Parses a slash-command line the way `handleCommand` does:
/// `parts = command.split(' ')`, `cmd = parts[0].toLowerCase()`,
/// `args = parts.slice(1).join(' ')`. Alias resolution is via the token index.
ParsedCommand parseCommand(String command) {
  final parts = command.split(' ');
  final token = parts[0].toLowerCase();
  final args = parts.length > 1 ? parts.sublist(1).join(' ') : '';
  return ParsedCommand(token: token, args: args, spec: _byToken[token]);
}

/// Resolves a token (canonical or alias) to its spec, or null.
CommandSpec? resolveCommand(String token) => _byToken[token.toLowerCase()];

/// Whether [text] should be routed to the command handler instead of being
/// published — the PWA checks `content.startsWith('/')` (messages.js:2367).
bool isCommandLine(String text) => text.startsWith('/');

/// Visible command entries for palette/help (the PWA hides `aliasOf` rows;
/// here every [CommandSpec] is already canonical, so all are visible).
List<CommandSpec> visibleCommands() => kCommandSpecs;

/// `"/join, /j"` display form (`_formatCommandDisplay`, commands.js:351).
String formatCommandDisplay(CommandSpec spec) {
  if (spec.aliases.isEmpty) return spec.name;
  return '${spec.name}, ${spec.aliases.join(', ')}';
}

/// True if [spec] may run in the given context. Mirrors the per-handler guards:
/// channel/channelOnly reject PMs+groups; groupOnly rejects everything but a
/// group.
bool isAllowedIn(CommandSpec spec, {required bool inPM, required bool inGroup}) {
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

/// Nymbot public `?` command catalog and parser; every command, randomness included, is computed by the worker.
library;

/// Top-level sections matching the README's bot command headings.
enum BotCommandGroup {
  aiKnowledge,
  gamesFun,
  utility,
  channelActivity,
  credits,
  info,
}

class BotCommand {
  const BotCommand({
    required this.name,
    required this.group,
    required this.usage,
    required this.description,
    this.aliases = const [],
    this.creditCommand = false,
    this.isFree = false,
  });

  /// Canonical keyword without the leading `?`, e.g. `ask`.
  final String name;

  final BotCommandGroup group;

  /// Usage signature as written in the README, e.g. `?ask <question>`.
  final String usage;

  final String description;

  /// Extra keywords the worker also accepts.
  final List<String> aliases;

  /// True for commands that operate on the paid 1:1 Nymbot chat.
  final bool creditCommand;

  /// Metadata only: the worker also answers `?help`, and nothing else is free.
  final bool isFree;

  /// True when [token] (lowercased, no `?`) names this command.
  bool matches(String token) => token == name || aliases.contains(token);
}

/// The full ordered catalog.
const List<BotCommand> kBotCommands = [
  BotCommand(
    name: 'ask',
    group: BotCommandGroup.aiKnowledge,
    usage: '?ask <question>',
    description: "Ask the AI anything (also triggered via @Nymbot <question>)",
  ),
  BotCommand(
    name: 'define',
    group: BotCommandGroup.aiKnowledge,
    usage: '?define <word>',
    description:
        "Look up a word's definition, part of speech, and example usage",
  ),
  BotCommand(
    name: 'translate',
    group: BotCommandGroup.aiKnowledge,
    usage: '?translate <text>',
    description:
        'Translate text (auto-detects language; English translates to Spanish)',
  ),
  BotCommand(
    name: 'news',
    group: BotCommandGroup.aiKnowledge,
    usage: '?news',
    description: 'Latest breaking news headlines',
  ),

  BotCommand(
    name: 'trivia',
    group: BotCommandGroup.gamesFun,
    usage: '?trivia [category]',
    description:
        'Trivia questions (categories: general, history, science, crypto, nostr)',
  ),
  BotCommand(
    name: 'joke',
    group: BotCommandGroup.gamesFun,
    usage: '?joke',
    description: 'Random tech or Bitcoin themed joke',
  ),
  BotCommand(
    name: 'riddle',
    group: BotCommandGroup.gamesFun,
    usage: '?riddle',
    description: 'Random riddle (reply to answer)',
  ),
  BotCommand(
    name: 'wordplay',
    group: BotCommandGroup.gamesFun,
    usage: '?wordplay [mode]',
    description:
        'Word games (modes: wordle, anagram, scramble; reply to guess)',
  ),
  BotCommand(
    name: 'flip',
    group: BotCommandGroup.gamesFun,
    usage: '?flip',
    description: 'Flip a coin',
  ),
  BotCommand(
    name: '8ball',
    group: BotCommandGroup.gamesFun,
    usage: '?8ball <question>',
    description: 'Magic 8-ball',
  ),
  BotCommand(
    name: 'pick',
    group: BotCommandGroup.gamesFun,
    usage: '?pick <option1> <option2> ...',
    description: 'Randomly pick from a list of options',
  ),

  BotCommand(
    name: 'math',
    group: BotCommandGroup.utility,
    usage: '?math <expression>',
    description: 'Calculate a math expression',
  ),
  BotCommand(
    name: 'units',
    group: BotCommandGroup.utility,
    usage: '?units <value> <from> to <to>',
    description: 'Unit converter (e.g. ?units 10 km to mi)',
  ),
  BotCommand(
    name: 'time',
    group: BotCommandGroup.utility,
    usage: '?time',
    description: 'Current UTC time and Unix timestamp',
  ),
  BotCommand(
    name: 'btc',
    group: BotCommandGroup.utility,
    usage: '?btc',
    description: 'Current Bitcoin price',
    aliases: ['bitcoin', 'price'],
  ),

  BotCommand(
    name: 'who',
    group: BotCommandGroup.channelActivity,
    usage: '?who',
    description: 'Who is active in the current channel',
  ),
  BotCommand(
    name: 'summarize',
    group: BotCommandGroup.channelActivity,
    usage: '?summarize',
    description: 'Summary of the current channel discussion',
  ),
  BotCommand(
    name: 'top',
    group: BotCommandGroup.channelActivity,
    usage: '?top',
    description: 'Top channels by recent message activity',
  ),
  BotCommand(
    name: 'last',
    group: BotCommandGroup.channelActivity,
    usage: '?last [N]',
    description: 'Last N messages across channels (default 10, max 25)',
  ),
  BotCommand(
    name: 'seen',
    group: BotCommandGroup.channelActivity,
    usage: '?seen <nym|@mention|pubkey>',
    description: 'Where and when a nym was last seen',
  ),

  BotCommand(
    name: 'balance',
    group: BotCommandGroup.credits,
    usage: '?balance',
    description: 'Show your standard and Pro credit balances',
    creditCommand: true,
  ),
  BotCommand(
    name: 'buy',
    group: BotCommandGroup.credits,
    usage: '?buy',
    description: 'Buy credits over Lightning (Standard/Pro switch)',
    creditCommand: true,
  ),
  BotCommand(
    name: 'model',
    group: BotCommandGroup.credits,
    usage: '?model [name|off]',
    description:
        'Pick a Pro frontier model for replies, or switch back to standard routing',
    creditCommand: true,
  ),
  BotCommand(
    name: 'gift',
    group: BotCommandGroup.credits,
    usage: '?gift @nym',
    description: 'Gift credits to another user',
    creditCommand: true,
  ),
  BotCommand(
    name: 'transfer',
    group: BotCommandGroup.credits,
    usage: '?transfer @nym',
    description: 'Transfer your credits (standard and Pro) to another user',
    creditCommand: true,
  ),
  BotCommand(
    name: 'anon',
    group: BotCommandGroup.credits,
    usage: '?anon',
    description:
        'Chat from a throwaway key Nymbot can never link to your nym',
    creditCommand: true,
    isFree: true,
  ),

  // `?help` appears in two README groups; listed once here.
  BotCommand(
    name: 'help',
    group: BotCommandGroup.info,
    usage: '?help',
    description: 'List all available bot commands',
    isFree: true,
  ),
  BotCommand(
    name: 'about',
    group: BotCommandGroup.info,
    usage: '?about',
    description: 'About Nymchat',
  ),
  BotCommand(
    name: 'nostr',
    group: BotCommandGroup.info,
    usage: '?nostr',
    description: 'Random Nostr protocol tips',
  ),
  BotCommand(
    name: 'changelog',
    group: BotCommandGroup.info,
    usage: '?changelog [version]',
    description:
        'Latest Nymchat release notes (?changelog <version> for a specific release)',
    aliases: ['release', 'releases', 'version', 'versions'],
  ),
];

final Map<String, BotCommand> _kByToken = {
  for (final c in kBotCommands) ...{
    c.name: c,
    for (final a in c.aliases) a: c,
  },
};

class ParsedBotCommand {
  const ParsedBotCommand({
    required this.name,
    required this.args,
    this.command,
  });

  final String name;

  /// Everything after the command token, trimmed; empty when none.
  final String args;

  /// The catalog match, or null for an unrecognized keyword.
  final BotCommand? command;

  bool get isKnown => command != null;
}

/// Parses `?ask hello world` into `(ask, "hello world")`, or null; keyword lowercased, args kept verbatim.
ParsedBotCommand? parseBotCommand(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('?')) return null;
  final body = trimmed.substring(1);
  if (body.isEmpty) return null;

  final match = RegExp(r'^(\S+)\s*([\s\S]*)$').firstMatch(body);
  if (match == null) return null;
  final name = match.group(1)!.toLowerCase();
  final args = (match.group(2) ?? '').trim();

  return ParsedBotCommand(
    name: name,
    args: args,
    command: _kByToken[name],
  );
}

/// Looks up a command by keyword or alias; null when unknown.
BotCommand? lookupBotCommand(String keyword) =>
    _kByToken[keyword.toLowerCase().replaceFirst('?', '')];

/// Whether [keyword], with or without `?`, is a recognized command.
bool isKnownBotCommand(String keyword) => lookupBotCommand(keyword) != null;

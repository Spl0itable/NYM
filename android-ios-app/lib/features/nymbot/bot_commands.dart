/// Nymbot public `?` command catalogue + parser.
///
/// 1:1 port of the client-visible command set enumerated in `README.md`
/// ("### Bot Commands", lines 176-219) and the client surface in
/// `docs/specs/04-features.md` §11.1. The authoritative worker that backs every
/// command is `functions/api/bot.js` (POST `/api/bot`).
///
/// IMPORTANT — local vs server (verified against `functions/api/bot.js`):
/// every public command, including `?flip`/`?8ball`/`?pick`, is computed
/// **server-side**. The worker owns the randomness:
///   * `handleFlip()`      — `Math.random() < 0.5 ? "Heads!" : "Tails!"`
///   * `handleEightBall()` — `Math.floor(Math.random() * responses.length)`
///   * `handlePick()`      — `Math.floor(Math.random() * options.length)`
/// So there is no client-local command path: each `?cmd` is dispatched to the
/// worker. (Note: `?roll` is in the README but has no worker handler — it would
/// return "Unknown command" — so it is intentionally omitted here.) The worker
/// also answers `?help` server-side, so [BotCommand.isFree] is metadata only.
library;

/// Top-level grouping used by the README's "### Bot Commands" headings, so the
/// help/command UI can mirror the same sections.
enum BotCommandGroup {
  aiKnowledge, // "AI & Knowledge"
  gamesFun, // "Games & Fun"
  utility, // "Utility"
  channelActivity, // "Channel Activity"
  credits, // "Credits (private Nymbot chat)"
  info, // "Info"
}

/// A single public `?` command as advertised in the README.
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

  /// The canonical command keyword, e.g. `ask` (no leading `?`).
  final String name;

  /// README section this command lives under.
  final BotCommandGroup group;

  /// Usage signature exactly as written in the README, e.g. `?ask <question>`.
  final String usage;

  /// Human description (README text after the dash).
  final String description;

  /// Extra keywords the worker also accepts (verified in `bot.js` dispatch:
  /// `?btc`→`bitcoin`/`price`, `?changelog`→`release(s)`/`version(s)`).
  final List<String> aliases;

  /// True for the "Credits (private Nymbot chat)" group — these operate on the
  /// paid 1:1 chat (balance/buy/model/git/gift/transfer) rather than a channel.
  final bool creditCommand;

  /// True when the command produces a free, local guide and never bills credits
  /// (`?help`). All other commands round-trip to the worker.
  final bool isFree;

  /// True when [other] (a lower-cased token without `?`) names this command.
  bool matches(String token) =>
      token == name || aliases.contains(token);
}

/// The full, ordered catalogue. Order + wording mirror README lines 178-219.
const List<BotCommand> kBotCommands = [
  // --- AI & Knowledge ---------------------------------------------------------
  BotCommand(
    name: 'ask',
    group: BotCommandGroup.aiKnowledge,
    usage: '?ask <question>',
    description:
        "Ask the AI anything (also triggered via @Nymbot <question>)",
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

  // --- Games & Fun ------------------------------------------------------------
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

  // --- Utility ----------------------------------------------------------------
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

  // --- Channel Activity -------------------------------------------------------
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

  // --- Credits (private Nymbot chat) -----------------------------------------
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
    name: 'git',
    group: BotCommandGroup.credits,
    usage: '?git',
    description:
        'Connect a git repo (GitHub/GitLab/Gitea) so Pro replies can read the '
        'code and optionally commit, branch, and open PRs',
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

  // --- Info -------------------------------------------------------------------
  // `?help` appears twice in the README (Credits group + Info group). It is a
  // single command; we list it once under Info and mark it free/local.
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

/// Fast lookup map (name + aliases → command).
final Map<String, BotCommand> _kByToken = {
  for (final c in kBotCommands) ...{
    c.name: c,
    for (final a in c.aliases) a: c,
  },
};

/// A parsed `?command args` invocation.
class ParsedBotCommand {
  const ParsedBotCommand({
    required this.name,
    required this.args,
    this.command,
  });

  /// The command keyword (lower-cased, no `?`), e.g. `ask`.
  final String name;

  /// Everything after the command token, trimmed. Empty string when none.
  final String args;

  /// The matched [BotCommand] from the catalogue, or null when the keyword is
  /// not a recognised Nymbot command (the worker may still answer, but the
  /// client treats unknown `?foo` conservatively).
  final BotCommand? command;

  /// True when the keyword is a recognised README command.
  bool get isKnown => command != null;
}

/// Parses a raw message such as `?ask hello world` into `(ask, "hello world")`.
///
/// Returns null when [text] is not a `?` command (does not start with `?`, or is
/// just `?`). Splits on the **first** run of whitespace, matching the worker's
/// `command`/`args` split. The keyword is lower-cased (worker dispatch uses
/// `command.toLowerCase()`); args preserve original case and inner spacing.
ParsedBotCommand? parseBotCommand(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('?')) return null;
  final body = trimmed.substring(1);
  if (body.isEmpty) return null;

  // Split keyword from args on the first whitespace run.
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

/// Looks up a command by keyword (or alias). Null when unknown.
BotCommand? lookupBotCommand(String keyword) =>
    _kByToken[keyword.toLowerCase().replaceFirst('?', '')];

/// Whether [keyword] (with or without `?`) is a recognised README command.
bool isKnownBotCommand(String keyword) =>
    lookupBotCommand(keyword) != null;

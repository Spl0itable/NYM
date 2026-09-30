// Localized input aliases for `/` and `?` commands; canonical English tokens stay internal and on the wire.

import '../i18n/i18n.dart';
import '../i18n/localization_service.dart';
import '../nymbot/bot_commands.dart';
import '../nymbot/nymbot_models.dart';
import 'command_registry.dart';

/// English phrases that translate better than the bare token; null means never translate.
const Map<String, String?> kCommandSourcePhrase = {
  '/pm': 'private message',
  '/nick': 'nickname',
  '/me': 'action',
  '/brb': 'be right back',
  '/addmember': 'add member',
  '/groupinfo': 'group info',
  '/addmod': 'add moderator',
  '/removemod': 'remove moderator',
  '/transferowner': 'transfer owner',
  '?wordplay': 'word play',
  '?changelog': 'change log',
  '?8ball': null,
  '?btc': null,
  '?nostr': null,
};

/// Multi-character, non-alias canonical tokens from both vocabularies, in registry order.
List<String> canonicalCommandTokens() {
  final out = <String>[];
  final seen = <String>{};
  void add(String token) {
    if (token.length <= 2 || !seen.add(token)) return;
    out.add(token);
  }

  for (final spec in kCommandSpecs) {
    add(spec.name);
  }
  for (final c in kBotCommands) {
    add('?${c.name}');
  }
  // The PM-only set isn't in the public catalog.
  for (final c in kBotPMCommands) {
    add(c.name);
  }
  return out;
}

/// The English phrase translated for [token], or null when it must stay as-is.
String? commandSourcePhrase(String token) {
  if (kCommandSourcePhrase.containsKey(token)) {
    return kCommandSourcePhrase[token];
  }
  return token.substring(1);
}

/// Every source phrase for [LocalizationService] to pre-translate once a language is chosen.
List<String> commandSourcePhrases() => [
      for (final token in canonicalCommandTokens())
        if (commandSourcePhrase(token) != null) commandSourcePhrase(token)!,
    ];

/// Folds a translated phrase into a single typeable token.
String commandSlug(String text) {
  final lowered = text.trim().toLowerCase();
  return lowered.replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '');
}

/// Strips accents so an alias can also be typed without them.
String commandDeaccent(String token) {
  // No NFD normalizer in core Dart, so fold the accented letters these vocabularies produce.
  const folds = {
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ō': 'o', 'ø': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
    'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y', 'š': 's', 'ž': 'z', 'ğ': 'g',
    'ı': 'i', 'ş': 's', 'ć': 'c', 'č': 'c', 'ł': 'l', 'ń': 'n', 'ż': 'z',
    'ź': 'z', 'ě': 'e', 'ř': 'r', 'ů': 'u', 'ą': 'a', 'ę': 'e',
  };
  final buf = StringBuffer();
  for (final ch in token.split('')) {
    buf.write(folds[ch] ?? ch);
  }
  return buf.toString();
}

class CommandAliases {
  const CommandAliases(this.local, this.lookup);

  /// canonical token -> localized display token.
  final Map<String, String> local;

  /// typed token -> canonical token.
  final Map<String, String> lookup;

  static const CommandAliases empty =
      CommandAliases(<String, String>{}, <String, String>{});
}

/// Built from the current localization cache; cheap enough to call per keystroke.
CommandAliases commandAliases() {
  if (!LocalizationService.instance.isActive) return CommandAliases.empty;
  final tokens = canonicalCommandTokens();
  final reserved = <String>{
    for (final spec in kCommandSpecs) ...[spec.name, ...spec.aliases],
    for (final c in kBotCommands) ...[
      '?${c.name}',
      for (final a in c.aliases) '?$a',
    ],
    for (final c in kBotPMCommands) c.name,
  };
  final local = <String, String>{};
  final lookup = <String, String>{};

  void claim(String slug, String canonical) {
    if (slug.length < 2) return;
    final full = canonical[0] + slug;
    if (reserved.contains(full) || lookup.containsKey(full)) return;
    lookup[full] = canonical;
    final bare = canonical[0] + commandDeaccent(slug);
    if (bare != full && !reserved.contains(bare) && !lookup.containsKey(bare)) {
      lookup[bare] = canonical;
    }
  }

  for (final token in tokens) {
    final source = commandSourcePhrase(token);
    if (source == null) continue;
    final translated = tr(source);
    if (translated.isEmpty || translated == source) continue;
    final slug = commandSlug(translated);
    if (slug.isEmpty || slug == token.substring(1)) continue;
    local[token] = token[0] + slug;
    claim(slug, token);
    // A multi-word translation also answers to its first word.
    final first = commandSlug(translated.trim().split(RegExp(r'\s+')).first);
    if (first.isNotEmpty && first != slug) claim(first, token);
  }
  return CommandAliases(local, lookup);
}

String localizedCommandToken(String canonical) =>
    commandAliases().local[canonical] ?? canonical;

/// Canonical token for typed input, or null; English names and aliases win over localized ones.
String? resolveCommandToken(String typed) {
  final t = typed.toLowerCase();
  if (resolveCommand(t) != null) return resolveCommand(t)!.name;
  final bot = resolveBotCommandToken(t);
  if (bot != null) return bot;
  final aliases = commandAliases();
  return aliases.lookup[t] ?? aliases.lookup[commandDeaccent(t)];
}

/// `?token` to canonical `?name` for the bot vocabulary, or null.
String? resolveBotCommandToken(String typed) {
  if (!typed.startsWith('?')) return null;
  final name = typed.substring(1).toLowerCase();
  for (final c in kBotCommands) {
    if (c.name == name || c.aliases.contains(name)) return '?${c.name}';
  }
  return null;
}

/// Rewrites a leading localized command token to canonical English, leaving arguments untouched.
String canonicalizeCommandInput(String text) {
  final m = RegExp(r'^([/?])(\S+)').firstMatch(text);
  if (m == null) return text;
  final typed = '${m.group(1)}${m.group(2)}';
  final canonical = resolveCommandToken(typed);
  if (canonical == null || canonical == typed.toLowerCase()) return text;
  return canonical + text.substring(m.group(0)!.length);
}

/// `{typed, canonical}` when input opens with a localized command, so the worker can normalize it too.
Map<String, String>? commandAliasHint(String text) {
  final m = RegExp(r'^\s*([/?]\S+)').firstMatch(text);
  if (m == null) return null;
  final typed = m.group(1)!;
  final canonical = resolveCommandToken(typed);
  if (canonical == null || canonical == typed.toLowerCase()) return null;
  return {'typed': typed, 'canonical': canonical};
}

/// Rewrites canonical tokens inside rendered text so shown names match what the app accepts.
String localizeCommandTokensIn(String text) {
  final aliases = commandAliases();
  if (aliases.local.isEmpty || text.isEmpty) return text;
  return text.replaceAllMapped(
    RegExp(r'(^|[\s(<>`*_;])([/?])([a-zA-Z0-9]{3,})\b'),
    (m) {
      final canonical = '${m.group(2)}${m.group(3)!.toLowerCase()}';
      final local = aliases.local[canonical];
      return local == null ? m.group(0)! : '${m.group(1)}$local';
    },
  );
}

/// `"/unirse, /j"` display form; single-letter shortcuts stay English.
String localizedCommandDisplay(CommandSpec spec) {
  final name = localizedCommandToken(spec.name);
  if (spec.aliases.isEmpty) return name;
  return '$name, ${spec.aliases.join(', ')}';
}

/// [buildBotPaletteRows] that also matches and shows localized names.
List<BotPaletteCommand> buildLocalizedBotPaletteRows(String input) {
  final aliases = commandAliases();
  if (aliases.local.isEmpty) return buildBotPaletteRows(input);
  final needle = input.toLowerCase();
  return [
    for (final c in kBotPaletteCommands)
      if (c.command.startsWith(needle) ||
          (aliases.local[c.command] ?? c.command).startsWith(needle))
        BotPaletteCommand(
          command: aliases.local[c.command] ?? c.command,
          desc: c.desc,
        ),
  ];
}

// Localized aliases for the `/` and `?` command vocabularies.
//
// Canonical command tokens stay English everywhere internally and on the wire
// (dispatch ids, the /api/bot payload, the mesh). This layer only adds *input
// aliases* in the active UI language plus localized display names, so a user
// can type /unirse or ?chiste and still reach the join handler. Both the
// English and the localized form are always accepted. Mirrors
// `js/modules/command-i18n.js` in the PWA.

import '../i18n/i18n.dart';
import '../i18n/localization_service.dart';
import '../nymbot/bot_commands.dart';
import '../nymbot/nymbot_models.dart';
import 'command_registry.dart';

/// Short English phrases that translate better than the bare token. A null
/// value means "never translate" (proper nouns and abbreviations).
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
  '?git': null,
  '?nostr': null,
};

/// Every canonical token worth translating: multi-character, non-alias entries
/// from both vocabularies, in registry order.
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
  // The PM-only set (?image, ?speak, ?clear) isn't in the public catalogue.
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

/// Every source phrase the command vocabularies need, for [LocalizationService]
/// to pre-translate as soon as a language is chosen.
List<String> commandSourcePhrases() => [
      for (final token in canonicalCommandTokens())
        if (commandSourcePhrase(token) != null) commandSourcePhrase(token)!,
    ];

/// Folds a translated phrase into something typeable as a single token.
String commandSlug(String text) {
  final lowered = text.trim().toLowerCase();
  return lowered.replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '');
}

/// Strips combining marks so an alias can also be typed without accents.
String commandDeaccent(String token) {
  // Dart has no NFD normalizer in core, so fold the accented letters the
  // command vocabularies actually produce.
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

/// The alias tables for the active language.
class CommandAliases {
  const CommandAliases(this.local, this.lookup);

  /// canonical token → localized display token.
  final Map<String, String> local;

  /// typed token → canonical token.
  final Map<String, String> lookup;

  static const CommandAliases empty =
      CommandAliases(<String, String>{}, <String, String>{});
}

/// Builds the alias tables from whatever the localization cache currently
/// holds. Cheap (map lookups only) and safe to call per keystroke; entries
/// appear as their translations land.
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

/// Localized display token for a canonical command, or the canonical one.
String localizedCommandToken(String canonical) =>
    commandAliases().local[canonical] ?? canonical;

/// Canonical token for something the user typed, or null when unknown. English
/// names and aliases always win over a localized alias.
String? resolveCommandToken(String typed) {
  final t = typed.toLowerCase();
  if (resolveCommand(t) != null) return resolveCommand(t)!.name;
  final bot = resolveBotCommandToken(t);
  if (bot != null) return bot;
  final aliases = commandAliases();
  return aliases.lookup[t] ?? aliases.lookup[commandDeaccent(t)];
}

/// `?token` → canonical `?name` for the bot vocabulary, or null.
String? resolveBotCommandToken(String typed) {
  if (!typed.startsWith('?')) return null;
  final name = typed.substring(1).toLowerCase();
  for (final c in kBotCommands) {
    if (c.name == name || c.aliases.contains(name)) return '?${c.name}';
  }
  return null;
}

/// Rewrites a leading localized command token back to canonical English,
/// leaving the arguments untouched.
String canonicalizeCommandInput(String text) {
  final m = RegExp(r'^([/?])(\S+)').firstMatch(text);
  if (m == null) return text;
  final typed = '${m.group(1)}${m.group(2)}';
  final canonical = resolveCommandToken(typed);
  if (canonical == null || canonical == typed.toLowerCase()) return text;
  return canonical + text.substring(m.group(0)!.length);
}

/// `{typed, canonical}` when raw input opens with a localized command, so the
/// worker can normalize the same text server-side. Null otherwise.
Map<String, String>? commandAliasHint(String text) {
  final m = RegExp(r'^\s*([/?]\S+)').firstMatch(text);
  if (m == null) return null;
  final typed = m.group(1)!;
  final canonical = resolveCommandToken(typed);
  if (canonical == null || canonical == typed.toLowerCase()) return null;
  return {'typed': typed, 'canonical': canonical};
}

/// Rewrites canonical tokens inside rendered text (Nymbot help, system
/// messages) so the names shown match what the app accepts.
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

/// `"/unirse, /j"` display form — [formatCommandDisplay] with the canonical
/// name swapped for its localized alias. Single-letter shortcuts stay English.
String localizedCommandDisplay(CommandSpec spec) {
  final name = localizedCommandToken(spec.name);
  if (spec.aliases.isEmpty) return name;
  return '$name, ${spec.aliases.join(', ')}';
}

/// [buildBotPaletteRows] that also matches localized names and shows them.
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

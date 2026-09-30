// Detects which composer autocomplete (`@ # : \`) or command palette (`/`, `?`) is live at the caret.

/// [command] is the `/` palette; [botCommand] the `?` Nymbot palette.
enum TriggerKind { none, mention, channel, emoji, kaomoji, command, botCommand }

/// A detected trigger: kind, needle after the trigger char, and the trigger char's index for splicing.
class TriggerMatch {
  const TriggerMatch(this.kind, this.query, this.triggerIndex);
  const TriggerMatch.none()
      : kind = TriggerKind.none,
        query = '',
        triggerIndex = -1;

  final TriggerKind kind;
  final String query;
  final int triggerIndex;

  bool get isActive => kind != TriggerKind.none;
}

// Each trigger needs a leading `(?:^|\s)` boundary; the mention needle includes `#` so `@name#xxxx` stays live.
final RegExp _mentionRe = RegExp(r'(?:^|\s)@([^\s]*)$');
final RegExp _channelRe = RegExp(r'(?:^|\s)#([^\s]*)$');
final RegExp _kaomojiRe = RegExp(r'(?:^|\s)\\([a-z]*)$', caseSensitive: false);
// Only evaluated when none of the above match.
final RegExp _emojiRe =
    RegExp(r'(?:^|\s):([a-z0-9_+\-]*)$', caseSensitive: false);

/// Whole-line `/` and `?` open palettes; in the bot PM the `?` palette stays live past a space for subcommands.
TriggerMatch detectTrigger(String text, {int? caret, bool botPM = false}) {
  final c =
      (caret == null || caret < 0 || caret > text.length) ? text.length : caret;
  final before = text.substring(0, c);

  // Command palette only while still typing the command token.
  if (before.startsWith('/') && !before.contains(' ')) {
    return TriggerMatch(TriggerKind.command, before, 0);
  }

  // Public `?` set has no subcommands so it hides after a space; the bot PM set keeps firing.
  if (before.startsWith('?') && (botPM || !before.contains(' '))) {
    return TriggerMatch(TriggerKind.botCommand, before, 0);
  }

  // Precedence: mention > channel > kaomoji > emoji; index derives from needle length since the match may include a space.
  TriggerMatch? match(RegExp re, TriggerKind kind) {
    final m = re.firstMatch(before);
    if (m == null) return null;
    final needle = m.group(1) ?? '';
    final triggerIdx = before.length - needle.length - 1;
    return TriggerMatch(kind, needle, triggerIdx);
  }

  return match(_mentionRe, TriggerKind.mention) ??
      match(_channelRe, TriggerKind.channel) ??
      match(_kaomojiRe, TriggerKind.kaomoji) ??
      match(_emojiRe, TriggerKind.emoji) ??
      const TriggerMatch.none();
}

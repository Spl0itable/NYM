// Active-trigger detection at the caret — decides which of the four composer
// autocompletes (`@` `#` `:` `\`) or the `/` command palette is live, given the
// current input text + caret offset.
//
// Mirrors how the PWA's `handleInputChange` inspects the text before the caret
// (`refreshAutocompleteIfOpen` / `refreshChannelAutocompleteIfOpen`, and the
// colon/backslash regexes in `selectSpecificEmojiAutocomplete` /
// `selectKaomoji`). Each trigger fires only on a contiguous run of allowed
// characters immediately preceding the caret, and a space "closes" the token.

/// Which dropdown is active.
enum TriggerKind { none, mention, channel, emoji, kaomoji, command }

/// A detected trigger: its kind, the search needle (text after the trigger
/// char), and the index of the trigger char in the source string (so the
/// selection can splice a replacement).
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

// Trigger regexes mirror `handleInputChange` (ui-context.js:1671-1707) EXACTLY,
// including the leading `(?:^|\s)` boundary the PWA requires before each trigger
// char (so e.g. an email's `@` mid-token does not open the mention dropdown) and
// the `[^\s]*` needle (which, for mentions, deliberately includes `#` so
// `@name#xxxx` keeps the mention dropdown live).
final RegExp _mentionRe = RegExp(r'(?:^|\s)@([^\s]*)$');
final RegExp _channelRe = RegExp(r'(?:^|\s)#([^\s]*)$');
// Kaomoji run after a backslash (`/(?:^|\s)\\([a-z]*)$/i`).
final RegExp _kaomojiRe = RegExp(r'(?:^|\s)\\([a-z]*)$', caseSensitive: false);
// Emoji shortcode run after a colon (`/(?:^|\s):([a-z0-9_+-]*)$/i`). Only
// evaluated when none of the above match (the PWA's `else` branch).
final RegExp _emojiRe = RegExp(r'(?:^|\s):([a-z0-9_+\-]*)$', caseSensitive: false);

/// Detects the active trigger for [text] at caret [caret] (defaults to end).
///
/// The command palette wins when the WHOLE input is a `/…` line (the PWA shows
/// the palette whenever the input starts with `/`), since slash commands are a
/// line-level concept rather than a caret token. Otherwise we look at the run
/// of characters ending at the caret and pick the nearest trigger.
TriggerMatch detectTrigger(String text, {int? caret}) {
  final c = (caret == null || caret < 0 || caret > text.length)
      ? text.length
      : caret;
  final before = text.substring(0, c);

  // Command palette: input begins with '/' and has no space yet OR is still on
  // the command token. The PWA shows the palette for `/…` while typing the
  // command word; once a space is typed it stops re-showing (selectCommand
  // appends the space + hides). We mirror "still typing the command token".
  if (before.startsWith('/') && !before.contains(' ')) {
    return TriggerMatch(TriggerKind.command, before, 0);
  }

  // Fixed precedence, matching the PWA's if/else chain in handleInputChange:
  // mention > channel > kaomoji > emoji (emoji only in the final `else`). The
  // needle is group(1); the trigger-char index is one position before the
  // needle (the regex's `(?:^|\s)` prefix may include a leading space, so we
  // derive the index from the needle length rather than `m.start`).
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

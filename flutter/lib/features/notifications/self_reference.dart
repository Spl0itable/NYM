/// Pure checks for whether an inbound message refers to the user, taking [nym] and [suffix] directly.
library;

/// True when [content] @-mentions the user outside quoted lines; `@nym#other` (a different suffix) doesn't count.
bool mentionsSelf({
  required String content,
  required String nym,
  required String suffix,
}) {
  if (content.isEmpty || nym.isEmpty) return false;
  final scrubbed = content
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('>'))
      .join('\n');
  final esc = RegExp.escape(nym);
  final sfx = RegExp.escape(suffix);
  // `@nym` followed by our `#suffix` or a boundary that isn't a different suffix.
  final tail = sfx.isNotEmpty
      ? '(?:#$sfx\\b|(?!#[0-9a-f]{4})(?:\\b|\$))'
      : '(?!#[0-9a-f]{4})(?:\\b|\$)';
  return RegExp('@$esc$tail', caseSensitive: false).hasMatch(scrubbed);
}

/// True when [content] quote-replies to the user's message; only a top-level quote's attribution line counts.
bool quotesSelf({
  required String content,
  required String nym,
  required String suffix,
}) {
  if (content.isEmpty || nym.isEmpty) return false;
  for (final line in content.split('\n')) {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith('>')) continue;
    // Strip exactly one quote marker, so nested quotes fail the `@` test below.
    final inner = trimmed.substring(1).trim();
    if (!inner.startsWith('@')) continue;
    final colon = inner.indexOf(':');
    if (colon < 0) continue;
    if (_isSelfAuthor(inner.substring(1, colon).trim(),
        nym: nym, suffix: suffix)) {
      return true;
    }
  }
  return false;
}

/// Accepts `nym`, `nym#suffix` and doubled `nym#suffix#suffix`; rejects a different suffix.
bool _isSelfAuthor(String author, {required String nym, required String suffix}) {
  var label = author.trim();
  if (label.isEmpty) return false;
  final hash = label.indexOf('#');
  if (hash < 0) {
    return label.toLowerCase() == nym.toLowerCase();
  }
  final base = label.substring(0, hash);
  if (base.toLowerCase() != nym.toLowerCase()) return false;
  if (suffix.isEmpty) return true;
  // The suffix may repeat (`#ab12#ab12`); every segment must be ours.
  final tail = label.substring(hash + 1).split('#');
  return tail.every((s) => s.toLowerCase() == suffix.toLowerCase());
}

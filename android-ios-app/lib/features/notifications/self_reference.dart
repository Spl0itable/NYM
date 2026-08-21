/// Does an inbound message refer to ME? The two ways it can, kept pure and
/// testable because getting either wrong silently costs a notification.
///
/// Both take the recipient's [nym] (without its `#suffix`) and [suffix] rather
/// than reading identity state, so they can be exercised directly.
library;

/// True when [content] @-mentions the user OUTSIDE any quoted line.
///
/// Quoted lines are excluded on purpose: if someone quotes a message that
/// mentioned you, the mention belongs to the original conversation, not to
/// them addressing you. (What that exclusion must NOT swallow is a quote OF
/// your message — see [quotesSelf].)
///
/// A bare `@nym` matches, as does `@nym#suffix` carrying the user's own
/// suffix; `@nym#other` — a different person who happens to share the base
/// name — does not.
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
  // `@nym` followed by `#suffix` OR a boundary that isn't a *different*
  // #abcd suffix (mirrors `_getMentionPattern`'s tail).
  final tail = sfx.isNotEmpty
      ? '(?:#$sfx\\b|(?!#[0-9a-f]{4})(?:\\b|\$))'
      : '(?!#[0-9a-f]{4})(?:\\b|\$)';
  return RegExp('@$esc$tail', caseSensitive: false).hasMatch(scrubbed);
}

/// True when [content] is a quote reply to a message the user WROTE.
///
/// A quote reply carries the quoted message as `> @author: text` (the composer
/// builds exactly that at send, and the renderer parses it back), so the only
/// trace of who is being replied to lives inside a quoted line — precisely
/// where [mentionsSelf] refuses to look. Without this, replying to someone by
/// quoting them, rather than by typing their name, notified them of nothing.
///
/// Only the attribution line of a TOP-LEVEL quote counts. A nested quote
/// (`> > @me: …`, someone quoting a message that quoted me) is a second-hand
/// reference and does not notify, matching how an @-mention inside a quote is
/// ignored.
bool quotesSelf({
  required String content,
  required String nym,
  required String suffix,
}) {
  if (content.isEmpty || nym.isEmpty) return false;
  for (final line in content.split('\n')) {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith('>')) continue;
    // Strip exactly ONE quote marker: what remains for a nested quote still
    // starts with '>', so it fails the `@` test below and is skipped.
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

/// Whether a quote's author label names the user. Accepts `nym`, `nym#suffix`
/// and the doubled `nym#suffix#suffix` the renderer also tolerates; rejects a
/// same-named stranger carrying a different suffix.
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
  // Everything after the base may repeat the suffix (`#ab12#ab12`); every
  // segment present must be ours.
  final tail = label.substring(hash + 1).split('#');
  return tail.every((s) => s.toLowerCase() == suffix.toLowerCase());
}

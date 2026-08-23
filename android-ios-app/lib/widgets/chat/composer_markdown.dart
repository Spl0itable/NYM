// composer_markdown.dart — the grammar behind the composer's live formatting.
//
// The message field renders its own markdown: `**bold**` shows as bold, `# ` as
// a heading, a fence as a code block, and the markers themselves are painted at
// zero size so they disappear without leaving the draft. Keeping them in the
// text is what makes the whole thing safe — `TextEditingController.text` stays
// byte-for-byte what the user will send, so every offset the field reports and
// every offset the toolbar computes still address the same string.
//
// No marker is ever shown. An INCOMPLETE construct is still plain text, so
// typing "**" gives the feedback that something was opened; the markers vanish
// at the keystroke that closes the run. A marker that cannot be seen also
// cannot be edited by hand, so deleting one is handled structurally instead —
// see [richMarkerDelete].
//
// The grammar is a direct port of `_richParseFormat` in the PWA's
// `js/modules/rich-compose.js`, which in turn mirrors the message renderer
// ([NymFormat] here, `formatMessage` there): same regexes, same precedence. What
// the field shows is what recipients get.

import 'package:flutter/services.dart'
    show TextEditingValue, TextInputFormatter, TextSelection;
import 'package:flutter/painting.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_theme.dart' show kMonoFont;

/// What a [RichRun] stands for.
enum RichRunKind {
  /// Literal draft text — the leaf of the tree.
  text,

  /// An inline construct: bold, italic, strike, inline code.
  inline,

  /// A line-prefixed construct: a heading or a quote.
  line,

  /// A fenced code block.
  fence,
}

/// One node of the parse tree, addressed by offsets into the draft.
///
/// Every node covers a contiguous `[start, end)` slice, siblings are contiguous
/// and non-overlapping, and a construct's [children] cover exactly the slice
/// between its [open] and [close] markers. That is what lets the renderer emit
/// spans whose combined length equals the draft's length — the invariant the
/// field's caret arithmetic depends on.
class RichRun {
  const RichRun({
    required this.kind,
    required this.type,
    required this.start,
    required this.end,
    this.open = '',
    this.close = '',
    this.reveal = const [],
    this.emptyBody = false,
    this.children = const [],
  });

  const RichRun.text(this.start, this.end)
      : kind = RichRunKind.text,
        type = 'text',
        open = '',
        close = '',
        reveal = const [],
        emptyBody = false,
        children = const [];

  final RichRunKind kind;

  /// `bold`, `italic`, `strike`, `code`, `codeblock`, `h1`…`h3`, `quote`.
  final String type;

  final int start;
  final int end;

  /// The opening delimiter (`**`, `# `, ` ``` `), hidden while the caret is away.
  final String open;

  /// The closing delimiter. Empty for a line prefix and for an unterminated fence.
  final String close;

  /// Caret ranges (inclusive on both ends) that bring this run's markers back
  /// into view.
  ///
  /// Nothing reveals. Inline runs used to bring their markers back whenever the
  /// caret was anywhere inside them, and while you are typing a run the caret
  /// is always inside it — so the field showed "**bold**" for the whole time it
  /// took to write, and only hid the asterisks once the caret moved away. That
  /// is a preview, not a WYSIWYG composer. Block markers never revealed for
  /// their own reasons: what a heading, a quote or a code block IS reads off
  /// its own styling, showing the prefix again would shift the line every time
  /// the caret passed the start of it, and revealing a fence would undo the
  /// empty block the user had just opened by typing it.
  ///
  /// Kept as a list rather than deleted outright so the renderer stays
  /// data-driven and one line from being able to reveal something again.
  /// [richMarkerDelete] is how markers are edited.
  final List<List<int>> reveal;

  /// A fenced block with nothing in it yet. It still has to be visible, or
  /// three backticks would look like they did nothing.
  final bool emptyBody;

  final List<RichRun> children;

  bool get isText => kind == RichRunKind.text;

  /// True when [caretStart]…[caretEnd] touches one of the [reveal] ranges.
  bool revealedAt(int caretStart, int caretEnd) {
    if (caretStart < 0 || caretEnd < 0) return false;
    final lo = caretStart < caretEnd ? caretStart : caretEnd;
    final hi = caretStart < caretEnd ? caretEnd : caretStart;
    for (final r in reveal) {
      if (hi >= r[0] && lo <= r[1]) return true;
    }
    return false;
  }
}

// A fenced block, closed or still open. The trailing alternative takes `*`
// rather than `+` so three backticks on their own are already a block: the
// composer opens an empty one the moment you type them, the way Slack does,
// instead of waiting for the first character of code.
final RegExp _rxFence = RegExp(r'```[\s\S]*?```|```[\s\S]*$');

const List<(String, String)> _linePrefixes = [
  ('h3', '### '),
  ('h2', '## '),
  ('h1', '# '),
  ('quote', '> '),
];

/// Ordered by precedence: when two constructs start at the same offset the
/// earlier entry wins, reproducing the sequential replace order the renderer
/// uses (`_parseInline`, nym_format.dart).
final List<_InlineSpec> _inlineSpecs = [
  _InlineSpec('code', RegExp(r'`([^`]+?)`'), '`', '`', leaf: true),
  _InlineSpec('bold', RegExp(r'\*\*(.+?)\*\*'), '**', '**'),
  _InlineSpec('bold', RegExp(r'(?<!\w)__(.+?)__(?!\w)'), '__', '__'),
  _InlineSpec('italic', RegExp(r'(?<![:/])\*([^*\s][^*]*)\*'), '*', '*'),
  _InlineSpec('italic', RegExp(r'(?<![:/\w])_([^_\s][^_]*)_(?!\w)'), '_', '_'),
  _InlineSpec('strike', RegExp(r'~~(.+?)~~'), '~~', '~~'),
];

class _InlineSpec {
  _InlineSpec(this.type, this.rx, this.open, this.close, {this.leaf = false});
  final String type;
  final RegExp rx;
  final String open;
  final String close;

  /// Inline code takes no nested formatting.
  final bool leaf;
}

/// Nesting past this depth is left as plain text. Four covers every combination
/// the toolbar can produce and bounds the work done on every keystroke.
const int _maxDepth = 4;

/// First match of [rx] lying wholly inside `[from, to)`. Matching runs against
/// the whole draft rather than a substring so the lookbehinds above still see
/// the real preceding character.
Match? _firstMatch(RegExp rx, String text, int from, int to) {
  var pos = from;
  while (pos < to) {
    Match? m;
    for (final candidate in rx.allMatches(text, pos)) {
      m = candidate;
      break;
    }
    if (m == null || m.start >= to) return null;
    if (m.end <= to) return m;
    pos = m.start + 1;
  }
  return null;
}

List<RichRun> _parseInline(String text, int from, int to, int depth) {
  final out = <RichRun>[];
  var pos = from;
  while (pos < to) {
    Match? best;
    _InlineSpec? spec;
    if (depth < _maxDepth) {
      for (final s in _inlineSpecs) {
        final m = _firstMatch(s.rx, text, pos, to);
        if (m != null && (best == null || m.start < best.start)) {
          best = m;
          spec = s;
        }
      }
    }
    if (best == null || spec == null) {
      out.add(RichRun.text(pos, to));
      break;
    }
    if (best.start > pos) out.add(RichRun.text(pos, best.start));
    final start = best.start;
    final end = best.end;
    final innerStart = start + spec.open.length;
    final innerEnd = end - spec.close.length;
    out.add(RichRun(
      kind: RichRunKind.inline,
      type: spec.type,
      start: start,
      end: end,
      open: spec.open,
      close: spec.close,
      reveal: const [],
      children: spec.leaf
          ? (innerEnd > innerStart
              ? [RichRun.text(innerStart, innerEnd)]
              : const <RichRun>[])
          : _parseInline(text, innerStart, innerEnd, depth + 1),
    ));
    pos = end;
  }
  return out;
}

/// Everything outside a fenced block: line prefixes first (they only count at a
/// real line start), then inline constructs within each line.
void _parseFlow(String text, int from, int to, List<RichRun> out) {
  var pos = from;
  while (pos < to) {
    var nl = text.indexOf('\n', pos);
    if (nl == -1 || nl >= to) nl = to;
    final lineStart = pos, lineEnd = nl;
    var handled = false;
    if (lineStart == 0 || text[lineStart - 1] == '\n') {
      for (final (type, mark) in _linePrefixes) {
        if (lineEnd - lineStart <= mark.length) continue;
        if (!text.startsWith(mark, lineStart)) continue;
        out.add(RichRun(
          kind: RichRunKind.line,
          type: type,
          start: lineStart,
          end: lineEnd,
          open: mark,
          reveal: const [],
          children: _parseInline(text, lineStart + mark.length, lineEnd, 0),
        ));
        handled = true;
        break;
      }
    }
    if (!handled && lineEnd > lineStart) {
      out.addAll(_parseInline(text, lineStart, lineEnd, 0));
    }
    if (lineEnd < to) out.add(RichRun.text(lineEnd, lineEnd + 1));
    pos = lineEnd + 1;
  }
}

/// Parses [text] into the run tree the composer paints.
List<RichRun> parseRichFormat(String text) {
  final out = <RichRun>[];
  if (text.isEmpty) return out;
  var pos = 0;
  for (final m in _rxFence.allMatches(text)) {
    if (m.start > pos) _parseFlow(text, pos, m.start, out);
    final start = m.start, end = m.end;
    // The renderer also formats an unterminated trailing fence, which has no
    // closing marker to hide.
    final body = m[0]!;
    final closed = body.length >= 6 && body.endsWith('```');
    final innerEnd = closed ? end - 3 : end;
    out.add(RichRun(
      kind: RichRunKind.fence,
      type: 'codeblock',
      start: start,
      end: end,
      open: '```',
      close: closed ? '```' : '',
      reveal: const [],
      emptyBody: innerEnd <= start + 3,
      children: innerEnd > start + 3
          ? [RichRun.text(start + 3, innerEnd)]
          : const <RichRun>[],
    ));
    pos = end;
  }
  if (pos < text.length) _parseFlow(text, pos, text.length, out);
  return out;
}

/// The edit a Backspace/Delete next to a hidden marker should make.
///
/// A marker painted at zero size has no caret position of its own, so the plain
/// single-character delete would chew through it invisibly — one press turning
/// "```" into "``" and the block back into two stray backticks, or "**bold**"
/// into "*bold**", which re-parses as something the user never asked for.
/// Instead the delete acts on the construct: Backspace at the start of a
/// heading's or quote's body removes the prefix, and either key against the
/// edge of a fence or an inline run unwraps it, keeping the text inside.
///
/// Unwrapping removes BOTH markers. Taking only the one the caret is against
/// would leave the other stranded as literal text, so a single Backspace would
/// both strip the formatting and leave "**" behind to be deleted separately.
///
/// Returns the value to apply, or null to let the plain character delete
/// stand.
TextEditingValue? richMarkerDelete(String text, int caret,
    {required bool forward}) {
  if (text.isEmpty || caret < 0 || caret > text.length) return null;

  TextEditingValue apply(List<List<int>> ranges, int newCaret) {
    // Highest offset first so the earlier ranges keep their indices.
    final sorted = [...ranges]..sort((a, b) => b[0].compareTo(a[0]));
    var out = text;
    for (final r in sorted) {
      out = out.substring(0, r[0]) + out.substring(r[1]);
    }
    return TextEditingValue(
      text: out,
      selection: TextSelection.collapsed(offset: newCaret),
    );
  }

  // Innermost first, so the tightest formatting at the caret is the one that
  // comes off: in "***x***" a Backspace should drop one level, not both.
  final nodes = <RichRun>[];
  void walk(List<RichRun> list) {
    for (final n in list) {
      walk(n.children);
      nodes.add(n);
    }
  }

  walk(parseRichFormat(text));

  for (final n in nodes) {
    if (n.kind == RichRunKind.line) {
      final markEnd = n.start + n.open.length;
      final hit = forward ? caret == n.start : caret == markEnd;
      if (hit) {
        return apply([
          [n.start, markEnd]
        ], n.start);
      }
    } else if (n.kind == RichRunKind.fence || n.kind == RichRunKind.inline) {
      if (n.open.isEmpty) continue;
      final openEnd = n.start + n.open.length;
      final closed = n.close.isNotEmpty;
      final closeStart = closed ? n.end - n.close.length : n.end;
      // The caret sits at one of the run's two inner edges — the only two
      // places a hidden marker is adjacent to visible text — or just outside.
      final atEnd = forward ? caret == closeStart : caret == n.end;
      final atStart = forward ? caret == n.start : caret == openEnd;
      if (!atStart && !(closed && atEnd)) continue;
      // Keep the caret where the text it was against ended up.
      final newCaret = atEnd ? n.start + (closeStart - openEnd) : n.start;
      return apply([
        [n.start, openEnd],
        if (closed) [closeStart, n.end],
      ], newCaret);
    }
  }
  return null;
}

/// Intercepts a single-character delete that would land inside a hidden block
/// marker and replaces it with [richMarkerDelete]'s edit. Everything else — a
/// selection, an insertion, a multi-character replacement — passes through
/// untouched.
class RichMarkerDeleteFormatter extends TextInputFormatter {
  const RichMarkerDeleteFormatter();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.length != oldValue.text.length - 1) return newValue;
    if (!oldValue.selection.isValid || !oldValue.selection.isCollapsed) {
      return newValue;
    }
    final caret = oldValue.selection.baseOffset;
    final next = newValue.selection.baseOffset;
    final bool forward;
    if (next == caret - 1) {
      forward = false;
    } else if (next == caret) {
      forward = true;
    } else {
      return newValue;
    }
    return richMarkerDelete(oldValue.text, caret, forward: forward) ?? newValue;
  }
}

/// True when [runs] contains anything to paint. A draft of plain text parses to
/// a single text run, and the field can then take the framework's fast path.
bool hasRichFormat(List<RichRun> runs) {
  for (final r in runs) {
    if (!r.isText) return true;
  }
  return false;
}

// --- painting ----------------------------------------------------------------

/// The style a run's body paints with, layered over [base].
///
/// Deliberately close to the message renderer's own treatment, with one
/// exception: a quote is dimmed rather than given a left rule, because a rule
/// would need a widget and a widget occupies a caret slot the draft does not
/// have a character for.
TextStyle richRunStyle(TextStyle base, String type, NymColors c) {
  final size = base.fontSize ?? 14;
  switch (type) {
    case 'bold':
      return base.copyWith(fontWeight: FontWeight.w700);
    case 'italic':
      return base.copyWith(fontStyle: FontStyle.italic);
    case 'strike':
      return base.copyWith(decoration: TextDecoration.lineThrough);
    case 'code':
    case 'codeblock':
      // `div.message-input .rich-md-code/.rich-md-codeblock` (styles-chat.css):
      // mono, a shade smaller, on a tinted ground.
      return base.copyWith(
        fontFamily: kMonoFont,
        fontSize: size * 0.92,
        backgroundColor: c.isLight
            ? const Color(0x0F000000)
            : const Color(0x14FFFFFF),
      );
    case 'h1':
      return base.copyWith(fontWeight: FontWeight.w700, fontSize: size * 1.3);
    case 'h2':
      return base.copyWith(fontWeight: FontWeight.w700, fontSize: size * 1.16);
    case 'h3':
      return base.copyWith(fontWeight: FontWeight.w700, fontSize: size * 1.06);
    case 'quote':
      return base.copyWith(color: c.textDim);
    default:
      return base;
  }
}

/// The style a delimiter paints with.
///
/// Hidden, it is drawn at a size no display can resolve — the characters are
/// still in the draft and still occupy their own caret offsets, they just take
/// up no space. Revealed, it is the real thing at the field's own size, dimmed
/// and stripped of the run's weight, slant and strike so it reads as scaffolding
/// rather than content.
///
/// [keepSpace] is the one exception: the fences of an EMPTY code block are drawn
/// at full size in transparent ink, so the block still occupies a box the user
/// can see. There is nothing else in it to give it width, and three backticks
/// have to look like they did something.
TextStyle richMarkStyle(TextStyle base, TextStyle fieldStyle, bool revealed,
    NymColors c,
    {bool keepSpace = false}) {
  if (!revealed) {
    return base.copyWith(
      fontSize: keepSpace ? (fieldStyle.fontSize ?? 14) : 0.01,
      letterSpacing: 0,
      wordSpacing: 0,
      color: const Color(0x00000000),
      decoration: TextDecoration.none,
    );
  }
  return base.copyWith(
    fontSize: fieldStyle.fontSize ?? 14,
    fontWeight: FontWeight.w400,
    fontStyle: FontStyle.normal,
    decoration: TextDecoration.none,
    color: c.textDim.withValues(alpha: 0.6),
  );
}

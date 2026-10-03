// Live composer markdown grammar; markers stay in the text (painted at zero size) so offsets match what is sent.

import 'package:flutter/services.dart'
    show TextEditingValue, TextInputFormatter, TextSelection;
import 'package:flutter/painting.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_theme.dart' show kMonoFont;

enum RichRunKind {
  text,

  inline,

  line,

  fence,
}

/// One parse-tree node over `[start, end)`; siblings are contiguous so rendered span lengths equal the draft's.
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

  final String type;

  final int start;
  final int end;

  final String open;

  /// Empty for a line prefix and for an unterminated fence.
  final String close;

  /// Caret ranges that reveal this run's markers; currently always empty, kept so the renderer stays data-driven.
  final List<List<int>> reveal;

  /// An empty fenced block must still be visible, or three backticks would look like they did nothing.
  final bool emptyBody;

  final List<RichRun> children;

  bool get isText => kind == RichRunKind.text;

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

// `*` rather than `+` so three bare backticks already open a block.
final RegExp _rxFence = RegExp(r'```[\s\S]*?```|```[\s\S]*$');

const List<(String, String)> _linePrefixes = [
  ('h3', '### '),
  ('h2', '## '),
  ('h1', '# '),
  ('subtext', '-# '),
  ('quote', '> '),
];

final RegExp _rxListPrefix = RegExp(r'^(\t| {2,})?([-*]|\d{1,9}\.) (?=\S)');

(String, String)? _linePrefixAt(String text, int lineStart, int lineEnd) {
  for (final (type, mark) in _linePrefixes) {
    if (lineEnd - lineStart <= mark.length) continue;
    if (!text.startsWith(mark, lineStart)) continue;
    return (type, mark);
  }
  final m = _rxListPrefix.firstMatch(text.substring(lineStart, lineEnd));
  if (m == null) return null;
  final nested = m[1] != null ? '2' : '';
  if (m[2] == '-' || m[2] == '*') return ('ulist$nested', m[0]!);
  return ('olist$nested', '');
}

final RegExp _rxComposerTimestamp = RegExp(r'<t:(-?\d{1,17})(?::([tTdDfFR]))?>');

bool _validTimestamp(Match m) {
  final n = int.tryParse(m[1]!);
  return n != null && n.abs() <= 8640000000000;
}

/// Ordered by precedence, matching the renderer's sequential replace order.
final List<_InlineSpec> _inlineSpecs = [
  _InlineSpec('code', RegExp(r'`([^`]+?)`'), '`', '`', leaf: true),
  _InlineSpec('timestamp', _rxComposerTimestamp, '', '',
      atom: true, accept: _validTimestamp),
  _InlineSpec('spoiler', RegExp(r'\|\|([^\s|](?:[^\n]*?[^\s|])??)\|\|'), '||', '||'),
  _InlineSpec('bold', RegExp(r'\*\*(.+?)\*\*'), '**', '**'),
  _InlineSpec('underline', RegExp(r'(?<!\w)__(.+?)__(?!\w)'), '__', '__'),
  _InlineSpec('italic', RegExp(r'(?<![:/])\*([^*\s][^*]*)\*'), '*', '*'),
  _InlineSpec('italic', RegExp(r'(?<![:/\w])_([^_\s][^_]*)_(?!\w)'), '_', '_'),
  _InlineSpec('strike', RegExp(r'~~(.+?)~~'), '~~', '~~'),
];

class _InlineSpec {
  _InlineSpec(this.type, this.rx, this.open, this.close,
      {this.leaf = false, this.atom = false, this.accept});
  final String type;
  final RegExp rx;
  final String open;
  final String close;

  final bool leaf;
  final bool atom;
  final bool Function(Match)? accept;
}

/// Deeper nesting is left as plain text; bounds per-keystroke work.
const int _maxDepth = 4;

/// Matches against the whole draft so the lookbehinds still see the real preceding character.
Match? _firstMatch(RegExp rx, String text, int from, int to,
    [bool Function(Match)? accept]) {
  var pos = from;
  while (pos < to) {
    Match? m;
    for (final candidate in rx.allMatches(text, pos)) {
      m = candidate;
      break;
    }
    if (m == null || m.start >= to) return null;
    if (m.end <= to && (accept == null || accept(m))) return m;
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
        final m = _firstMatch(s.rx, text, pos, to, s.accept);
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
    if (spec.atom) {
      out.add(RichRun(
        kind: RichRunKind.inline,
        type: spec.type,
        start: start,
        end: end,
        open: best[0]!,
        reveal: const [],
      ));
      pos = end;
      continue;
    }
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

/// Line prefixes count only at a real line start; inline constructs are parsed within each line.
void _parseFlow(String text, int from, int to, List<RichRun> out) {
  var pos = from;
  while (pos < to) {
    var nl = text.indexOf('\n', pos);
    if (nl == -1 || nl >= to) nl = to;
    final lineStart = pos, lineEnd = nl;
    var handled = false;
    if (lineStart == 0 || text[lineStart - 1] == '\n') {
      final prefix = _linePrefixAt(text, lineStart, lineEnd);
      if (prefix != null) {
        final (type, mark) = prefix;
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
      }
    }
    if (!handled && lineEnd > lineStart) {
      out.addAll(_parseInline(text, lineStart, lineEnd, 0));
    }
    if (lineEnd < to) out.add(RichRun.text(lineEnd, lineEnd + 1));
    pos = lineEnd + 1;
  }
}

List<RichRun> parseRichFormat(String text) {
  final out = <RichRun>[];
  if (text.isEmpty) return out;
  var pos = 0;
  for (final m in _rxFence.allMatches(text)) {
    if (m.start > pos) _parseFlow(text, pos, m.start, out);
    final start = m.start, end = m.end;
    // The renderer also formats an unterminated trailing fence, which has no closing marker.
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

/// Delete beside a hidden marker unwraps the whole construct; null lets the plain delete stand.
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

  // Innermost first, so a Backspace drops one formatting level, not all.
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
      if (n.open.isEmpty) continue;
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
      final atEnd = forward ? caret == closeStart : caret == n.end;
      final atStart = forward ? caret == n.start : caret == openEnd;
      if (!atStart && !(closed && atEnd)) continue;
      final newCaret = atEnd ? n.start + (closeStart - openEnd) : n.start;
      return apply([
        [n.start, openEnd],
        if (closed) [closeStart, n.end],
      ], newCaret);
    }
  }
  return null;
}

/// Routes a single-character delete that would land in a hidden marker through [richMarkerDelete].
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

/// Plain text parses to one run, letting the field take the framework's fast path.
bool hasRichFormat(List<RichRun> runs) {
  for (final r in runs) {
    if (!r.isText) return true;
  }
  return false;
}

/// Quotes are dimmed rather than ruled, since a rule widget would take a caret slot with no character.
TextStyle richRunStyle(TextStyle base, String type, NymColors c) {
  final size = base.fontSize ?? 14;
  switch (type) {
    case 'bold':
      return base.copyWith(fontWeight: FontWeight.w700);
    case 'italic':
      return base.copyWith(fontStyle: FontStyle.italic);
    case 'strike':
      return base.copyWith(decoration: TextDecoration.lineThrough);
    case 'underline':
      return base.copyWith(decoration: TextDecoration.underline);
    case 'spoiler':
      return base.copyWith(
        backgroundColor: c.isLight
            ? const Color(0x1F000000)
            : c.textDim.withValues(alpha: 0.3),
      );
    case 'subtext':
      return base.copyWith(fontSize: size * 0.8, color: c.textDim);
    case 'code':
    case 'codeblock':
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

/// Hidden markers paint at near-zero size but keep caret offsets; [keepSpace] keeps an empty fence visible.
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

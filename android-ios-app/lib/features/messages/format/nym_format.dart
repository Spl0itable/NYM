// Pure content -> structured-node formatter, a Dart port of the PWA's
// `message-format.js` (`NymFormat.format` + `formatWithQuotes`).
//
// Instead of emitting HTML, [NymFormat.format] returns a list of block nodes,
// each carrying inline spans. The renderer (`message_content.dart`) turns these
// into Flutter widgets. Semantics mirror the JS formatter (docs/specs/03 §9):
// the same markdown subset, the same media/mention/emoji handling, and the same
// ordering so that e.g. code spans shield their contents from later passes.

import 'dart:convert';

import '../../../models/channel.dart' show isValidGeohash;

/// Any character that can trigger formatting. If absent, the fast path applies
/// (only newline -> paragraph splitting). Mirrors `RX_FORMAT_TRIGGERS`.
final RegExp _rxTriggers = RegExp(r'[^\x20-\x7E\n]|[*_~`#>@:;/\\&<>"]');

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// Formatting context, the Dart analogue of the JS `ctx` object.
class FormatContext {
  const FormatContext({
    this.currentChannel,
    this.currentGeohash,
    this.customEmojis = const {},
    this.proxyBase,
    this.knownChannels = const {},
  });

  /// Active named channel (lowercase); a `#ref` matching it renders active.
  final String? currentChannel;

  /// Active geohash channel (lowercase); a geohash `#ref` matching it is active.
  final String? currentGeohash;

  /// NIP-30 custom emoji: shortcode (without colons) -> image url.
  final Map<String, String> customEmojis;

  /// Optional media/emoji proxy base (`base?url=...` / `base?emoji=1&url=...`).
  final String? proxyBase;

  /// Channels known to the client; currently informational only.
  final Set<String> knownChannels;

  static const empty = FormatContext();
}

// ---------------------------------------------------------------------------
// Block nodes
// ---------------------------------------------------------------------------

/// Base type for block-level nodes.
sealed class FormatBlock {
  const FormatBlock();
}

/// A run of inline content (one logical line group). Newlines inside are kept.
class ParagraphBlock extends FormatBlock {
  const ParagraphBlock(this.inlines);
  final List<InlineNode> inlines;
}

/// A fenced or unterminated ``` code block.
class CodeBlock extends FormatBlock {
  const CodeBlock({required this.code, this.lang});
  final String code;
  final String? lang;
}

/// A `> quote` block. May nest [children] and carry a parsed `@author`.
class QuoteBlock extends FormatBlock {
  const QuoteBlock({required this.children, this.author});
  final List<FormatBlock> children;

  /// Author parsed from a `> @Author: msg` header (suffix included), else null.
  final String? author;
}

/// A heading line (`#`/`##`/`###` -> level 1/2/3).
class HeadingBlock extends FormatBlock {
  const HeadingBlock({required this.level, required this.inlines});
  final int level;
  final List<InlineNode> inlines;
}

/// One or more adjacent media items collapsed into a gallery.
class MediaBlock extends FormatBlock {
  const MediaBlock(this.items);
  final List<MediaItem> items;
}

/// A single image or video inside a [MediaBlock].
class MediaItem {
  const MediaItem({required this.url, required this.isVideo});

  /// The display URL (already proxied if a proxyBase was supplied).
  final String url;
  final bool isVideo;
}

// ---------------------------------------------------------------------------
// Inline nodes
// ---------------------------------------------------------------------------

/// Base type for inline (span-level) nodes.
sealed class InlineNode {
  const InlineNode();
}

/// Plain text. May contain newlines (rendered as line breaks).
class TextSpanNode extends InlineNode {
  const TextSpanNode(this.text);
  final String text;
}

/// `**bold**` / `__bold__`.
class BoldNode extends InlineNode {
  const BoldNode(this.children);
  final List<InlineNode> children;
}

/// `*italic*` / `_italic_`.
class ItalicNode extends InlineNode {
  const ItalicNode(this.children);
  final List<InlineNode> children;
}

/// `~~strike~~`.
class StrikeNode extends InlineNode {
  const StrikeNode(this.children);
  final List<InlineNode> children;
}

/// Inline `` `code` ``.
class InlineCodeNode extends InlineNode {
  const InlineCodeNode(this.code);
  final String code;
}

/// A bare `https?://` link (not media, channel-link, or invite).
class LinkNode extends InlineNode {
  const LinkNode(this.url);
  final String url;
}

/// `@name` or `@name#xxxx`. [suffix] is the 4-hex tag without `#`, or null.
class MentionNode extends InlineNode {
  const MentionNode({required this.base, this.suffix});

  /// The name portion including the leading `@`.
  final String base;
  final String? suffix;
}

/// A `#channel` reference.
class ChannelRefNode extends InlineNode {
  const ChannelRefNode({
    required this.name,
    required this.isGeohash,
    required this.isActive,
  });

  /// Channel name without the leading `#` (lowercased).
  final String name;
  final bool isGeohash;
  final bool isActive;
}

/// A standard (unicode) emoji from a `:shortcode:` or ASCII smiley, or a bare
/// unicode emoji in the source.
class EmojiNode extends InlineNode {
  const EmojiNode(this.unicode);
  final String unicode;
}

/// A NIP-30 custom emoji `:shortcode:` resolved against `ctx.customEmojis`.
class CustomEmojiNode extends InlineNode {
  const CustomEmojiNode({required this.shortcode, required this.url});
  final String shortcode;

  /// Image url (already proxied if a proxyBase was supplied).
  final String url;
}

/// `app.nym.bar/#<e|g|c>:<id>` channel-link chip.
class ChannelLinkChip extends InlineNode {
  const ChannelLinkChip({required this.ref, required this.label});

  /// `<prefix>:<id>` channel ref, e.g. `g:9q8y`.
  final String ref;

  /// The original matched URL text (display label).
  final String label;
}

/// `…#gjoin=<token>` group-invite chip.
class GroupInviteChip extends InlineNode {
  const GroupInviteChip({required this.name, required this.token});
  final String name;
  final String token;
}

// ---------------------------------------------------------------------------
// Built-in shortcode -> unicode emoji map (common subset, ~60 entries).
// ---------------------------------------------------------------------------

const Map<String, String> kBuiltinEmoji = {
  'smile': '😄',
  'smiley': '😃',
  'grin': '😁',
  'laughing': '😆',
  'joy': '😂',
  'rofl': '🤣',
  'sweat_smile': '😅',
  'blush': '😊',
  'slight_smile': '🙂',
  'wink': '😉',
  'heart_eyes': '😍',
  'kissing_heart': '😘',
  'yum': '😋',
  'stuck_out_tongue': '😛',
  'sunglasses': '😎',
  'thinking': '🤔',
  'neutral_face': '😐',
  'expressionless': '😑',
  'unamused': '😒',
  'roll_eyes': '🙄',
  'smirk': '😏',
  'pensive': '😔',
  'confused': '😕',
  'cry': '😢',
  'sob': '😭',
  'angry': '😠',
  'rage': '😡',
  'tired_face': '😫',
  'sleepy': '😪',
  'sleeping': '😴',
  'mask': '😷',
  'dizzy_face': '😵',
  'scream': '😱',
  'flushed': '😳',
  'fearful': '😨',
  'cold_sweat': '😰',
  'open_mouth': '😮',
  'astonished': '😲',
  'hushed': '😯',
  'sweat': '😓',
  'wave': '👋',
  'raised_hand': '✋',
  'ok_hand': '👌',
  'thumbsup': '👍',
  '+1': '👍',
  'thumbsdown': '👎',
  '-1': '👎',
  'punch': '👊',
  'fist': '✊',
  'v': '✌️',
  'clap': '👏',
  'pray': '🙏',
  'muscle': '💪',
  'point_up': '☝️',
  'point_down': '👇',
  'point_left': '👈',
  'point_right': '👉',
  'heart': '❤️',
  'broken_heart': '💔',
  'sparkling_heart': '💖',
  'fire': '🔥',
  'star': '⭐',
  'sparkles': '✨',
  'zap': '⚡',
  'boom': '💥',
  'tada': '🎉',
  'rocket': '🚀',
  'eyes': '👀',
  'skull': '💀',
  'poop': '💩',
  'ghost': '👻',
  'robot': '🤖',
  'wave2': '🌊',
  'sun': '☀️',
  'moon': '🌙',
  'check': '✅',
  'x': '❌',
  'warning': '⚠️',
  'question': '❓',
  'exclamation': '❗',
  '100': '💯',
  'ok': '🆗',
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

class NymFormat {
  const NymFormat._();

  /// Parses [content] into block nodes per the active [ctx].
  static List<FormatBlock> format(String content, [FormatContext? ctx]) {
    final c = ctx ?? FormatContext.empty;

    // Fast path: no trigger chars -> plain paragraphs split on blank lines,
    // keeping single newlines inside a paragraph.
    if (!_rxTriggers.hasMatch(content)) {
      return _plainParagraphs(content);
    }

    // Collapse `@name#xxxx#xxxx` -> `@name#xxxx` first (matches JS).
    final collapsed = content.replaceAllMapped(
      RegExp(r'@([^@#\s]+)#([0-9a-f]{4})#\2\b', caseSensitive: false),
      (m) => '@${m[1]}#${m[2]}',
    );

    return _formatWithQuotes(collapsed, c, 0);
  }

  static List<FormatBlock> _plainParagraphs(String content) {
    // PWA fast path (message-format.js:89-91): with no trigger chars the content
    // is returned verbatim, only converting `\n` -> `<br>`. That is a SINGLE
    // block preserving every newline (including runs of blank lines), not a
    // split into separate paragraphs. A TextSpan renders `\n` as a line break,
    // so one ParagraphBlock with the raw content reproduces it 1:1.
    return [
      ParagraphBlock([TextSpanNode(content)]),
    ];
  }

  static const int _maxQuoteDepth = 5;

  /// Splits leading `>` runs into [QuoteBlock]s and formats the rest as inline
  /// blocks. Mirrors `formatWithQuotes`.
  static List<FormatBlock> _formatWithQuotes(
    String content,
    FormatContext ctx,
    int depth,
  ) {
    final lines = content.split('\n');
    final out = <FormatBlock>[];
    var i = 0;

    while (i < lines.length) {
      if (lines[i].startsWith('>')) {
        final quoteLines = <String>[];
        while (i < lines.length && lines[i].startsWith('>')) {
          quoteLines.add(lines[i].substring(1).trim());
          i++;
        }
        if (depth >= _maxQuoteDepth) continue;

        final firstLine = quoteLines.isEmpty ? '' : quoteLines[0];
        final authorMatch =
            RegExp(r'^@([^:]+):\s*(.*)').firstMatch(firstLine);
        if (authorMatch != null) {
          final parts = <String>[];
          if ((authorMatch[2] ?? '').isNotEmpty) parts.add(authorMatch[2]!);
          for (var j = 1; j < quoteLines.length; j++) {
            parts.add(quoteLines[j]);
          }
          final quoted = parts.join('\n');
          final author = _cleanQuoteAuthor(authorMatch[1]!.trim());
          out.add(QuoteBlock(
            children: _formatWithQuotes(quoted, ctx, depth + 1),
            author: author,
          ));
        } else {
          out.add(QuoteBlock(
            children: _formatWithQuotes(quoteLines.join('\n'), ctx, depth + 1),
          ));
        }
      } else if (lines[i].trim().isEmpty) {
        i++;
      } else {
        final textLines = <String>[];
        while (i < lines.length && !lines[i].startsWith('>')) {
          textLines.add(lines[i]);
          i++;
        }
        final text = textLines
            .join('\n')
            .replaceFirst(RegExp(r'^\n+'), '')
            .replaceFirst(RegExp(r'\n+$'), '');
        if (text.isNotEmpty) out.addAll(_formatInlineBlocks(text, ctx));
      }
    }

    if (out.isEmpty) return _formatInlineBlocks(content, ctx);
    return out;
  }

  static String _cleanQuoteAuthor(String raw) {
    var a = raw.trim();
    // Collapse `name#xxxx#xxxx` -> `name#xxxx`.
    a = a.replaceFirstMapped(
      RegExp(r'^([^#]+)#([0-9a-f]{4})#\2$', caseSensitive: false),
      (m) => '${m[1]}#${m[2]}',
    );
    return a;
  }

  // -------------------------------------------------------------------------
  // Inline / block-within-quote formatting (the bulk of `format`).
  //
  // We work in passes, but instead of HTML placeholders we tokenize the string
  // into a flat list of "tokens" that are either raw text or already-resolved
  // nodes/blocks, so later passes never re-scan resolved content.
  // -------------------------------------------------------------------------

  static List<FormatBlock> _formatInlineBlocks(String text, FormatContext ctx) {
    // 1. Extract fenced + inline code first (shields contents).
    final codeBlocks = <CodeBlock>[];
    final inlineCode = <String>[];
    var s = text;

    // Fenced ```lang\ncode```
    s = s.replaceAllMapped(RegExp(r'```([\s\S]*?)```'), (m) {
      final idx = codeBlocks.length;
      codeBlocks.add(_makeCodeBlock(m[1] ?? ''));
      return 'F$idx';
    });
    // Unterminated ```code (to end).
    s = s.replaceAllMapped(RegExp(r'```([\s\S]+)$'), (m) {
      final idx = codeBlocks.length;
      codeBlocks.add(_makeCodeBlock(m[1] ?? ''));
      return 'F$idx';
    });
    // Inline `code`.
    s = s.replaceAllMapped(RegExp(r'`([^`]+?)`'), (m) {
      final idx = inlineCode.length;
      inlineCode.add(m[1] ?? '');
      return 'C$idx';
    });

    // Split into block lines: a line that is solely a fenced-code placeholder
    // becomes its own CodeBlock; `#`/`##`/`###` lines become headings; other
    // lines accumulate into paragraphs (preserving internal newlines).
    final blocks = <FormatBlock>[];
    final lines = s.split('\n');
    final paraBuf = <String>[];

    void flushPara() {
      if (paraBuf.isEmpty) return;
      final joined = paraBuf.join('\n');
      paraBuf.clear();
      blocks.addAll(_inlineToBlocks(joined, ctx, codeBlocks, inlineCode));
    }

    for (final line in lines) {
      final fenceOnly =
          RegExp(r'^F(\d+)$').firstMatch(line.trim());
      if (fenceOnly != null) {
        flushPara();
        blocks.add(codeBlocks[int.parse(fenceOnly[1]!)]);
        continue;
      }
      final heading = RegExp(r'^(#{1,3}) (.+)$').firstMatch(line);
      if (heading != null) {
        flushPara();
        final level = heading[1]!.length;
        blocks.add(HeadingBlock(
          level: level,
          inlines: _parseInline(heading[2]!, ctx, codeBlocks, inlineCode),
        ));
        continue;
      }
      paraBuf.add(line);
    }
    flushPara();

    if (blocks.isEmpty) {
      blocks.add(const ParagraphBlock([TextSpanNode('')]));
    }
    return blocks;
  }

  static CodeBlock _makeCodeBlock(String body) {
    String? lang;
    var b = body;
    final m =
        RegExp(r'^[ \t]*([A-Za-z0-9_+#.-]{1,20})[ \t]*\r?\n').firstMatch(b);
    if (m != null) {
      lang = m[1];
      b = b.substring(m[0]!.length);
    }
    final trimmed =
        b.replaceFirst(RegExp(r'^\s*\n'), '').replaceFirst(RegExp(r'\s+$'), '');
    return CodeBlock(code: trimmed, lang: lang);
  }

  /// Turns one paragraph's text (with code placeholders) into block nodes:
  /// media galleries split paragraphs, everything else is inline content.
  static List<FormatBlock> _inlineToBlocks(
    String text,
    FormatContext ctx,
    List<CodeBlock> codeBlocks,
    List<String> inlineCode,
  ) {
    final inlines = _parseInline(text, ctx, codeBlocks, inlineCode);

    // Pull contiguous runs of media into MediaBlocks (galleries). The PWA
    // collapses adjacent media (whitespace-only between) into one gallery; a
    // lone media item is rendered standalone (still a MediaBlock with one item).
    final blocks = <FormatBlock>[];
    var runInlines = <InlineNode>[];
    var mediaRun = <MediaItem>[];

    void flushInlines() {
      if (runInlines.isEmpty) return;
      // Drop trailing/leading empty text-only runs.
      final hasContent = runInlines.any((n) =>
          n is! TextSpanNode || (n).text.trim().isNotEmpty);
      if (hasContent) blocks.add(ParagraphBlock(List.of(runInlines)));
      runInlines = [];
    }

    void flushMedia() {
      if (mediaRun.isEmpty) return;
      blocks.add(MediaBlock(List.of(mediaRun)));
      mediaRun = [];
    }

    for (final node in inlines) {
      if (node is _MediaInline) {
        flushInlines();
        mediaRun.add(node.item);
      } else if (node is TextSpanNode && node.text.trim().isEmpty) {
        // Whitespace between media keeps the gallery contiguous; otherwise it
        // belongs to the surrounding paragraph.
        if (mediaRun.isNotEmpty) {
          // swallow whitespace between media
        } else {
          runInlines.add(node);
        }
      } else {
        flushMedia();
        runInlines.add(node);
      }
    }
    flushMedia();
    flushInlines();

    if (blocks.isEmpty) {
      blocks.add(ParagraphBlock(inlines));
    }
    return blocks;
  }

  // -------------------------------------------------------------------------
  // Inline span parser. Operates on text that may contain code placeholders.
  // -------------------------------------------------------------------------

  static List<InlineNode> _parseInline(
    String text,
    FormatContext ctx,
    List<CodeBlock> codeBlocks,
    List<String> inlineCode,
  ) {
    // Token list begins as a single raw-text token, progressively split.
    var tokens = <_Tok>[_RawTok(text)];

    // Code placeholders -> InlineCodeNode (fenced placeholders shouldn't reach
    // here since they're block-level, but handle inline ones).
    tokens = _splitByRegex(tokens, RegExp(r'C(\d+)'),
        (m) => _NodeTok(InlineCodeNode(inlineCode[int.parse(m[1]!)])));

    // Bold/italic/strike — recursive on inner content.
    tokens = _splitByRegex(tokens, RegExp(r'\*\*(.+?)\*\*'),
        (m) => _NodeTok(BoldNode(_parseInline(m[1]!, ctx, codeBlocks, inlineCode))));
    tokens = _splitByRegex(
        tokens,
        RegExp(r'(?<!\w)__(.+?)__(?!\w)'),
        (m) =>
            _NodeTok(BoldNode(_parseInline(m[1]!, ctx, codeBlocks, inlineCode))));
    tokens = _splitByRegex(
        tokens,
        RegExp(r'(?<![:/])\*([^*\s][^*]*)\*'),
        (m) => _NodeTok(
            ItalicNode(_parseInline(m[1]!, ctx, codeBlocks, inlineCode))));
    tokens = _splitByRegex(
        tokens,
        RegExp(r'(?<![:/\w])_([^_\s][^_]*)_(?!\w)'),
        (m) => _NodeTok(
            ItalicNode(_parseInline(m[1]!, ctx, codeBlocks, inlineCode))));
    tokens = _splitByRegex(
        tokens,
        RegExp(r'~~(.+?)~~'),
        (m) => _NodeTok(
            StrikeNode(_parseInline(m[1]!, ctx, codeBlocks, inlineCode))));

    // Media: video then image.
    tokens = _splitByRegex(
        tokens,
        RegExp(r'(https?://[^\s]+\.(mp4|webm|ogg|mov)(\?[^\s]*)?)',
            caseSensitive: false),
        (m) => _NodeTok(_MediaInline(
            MediaItem(url: _proxied(m[1]!, ctx.proxyBase), isVideo: true))));
    tokens = _splitByRegex(
        tokens,
        RegExp(r'(https?://[^\s]+\.(jpg|jpeg|png|gif|webp)(\?[^\s]*)?)',
            caseSensitive: false),
        (m) => _NodeTok(_MediaInline(
            MediaItem(url: _proxied(m[1]!, ctx.proxyBase), isVideo: false))));

    // Channel-link chip: app.nym.bar/#<e|g|c>:<id>
    tokens = _splitByRegex(
        tokens,
        RegExp(r'https?://app\.nym\.bar/#([egc]):([^\s<>"]+)',
            caseSensitive: false), (m) {
      return _NodeTok(ChannelLinkChip(ref: '${m[1]}:${m[2]}', label: m[0]!));
    });

    // Group-invite chip: …#gjoin=<token>
    tokens = _splitByRegex(
        tokens, RegExp(r'https?://[^\s<>"]*#gjoin=([A-Za-z0-9_-]+)'), (m) {
      final token = m[1]!;
      final invite = _parseGroupInvite(token);
      if (invite == null) return _RawTok(m[0]!);
      final name = _sanitizeGroupName(invite['n']?.toString() ?? '');
      return _NodeTok(GroupInviteChip(
          name: name.isEmpty ? 'group' : name, token: token));
    });

    // Bare links.
    tokens = _splitByRegex(tokens, RegExp(r'https?://[^\s]+'),
        (m) => _NodeTok(LinkNode(m[0]!)));

    // Mentions with suffix: @name#xxxx
    tokens = _splitByRegex(
        tokens,
        RegExp(r'@([^@#\s]+)#([0-9a-f]{4})\b', caseSensitive: false),
        (m) => _NodeTok(MentionNode(base: '@${m[1]}', suffix: m[2])));

    // Simple mentions: @name
    tokens = _splitByRegex(tokens, RegExp(r'@([^@\s][^@\s]*)'),
        (m) => _NodeTok(MentionNode(base: m[0]!)));

    // Channel refs: (start|space)#name
    tokens = _splitByRegex(
        tokens,
        RegExp(r'(^|\s)#([a-z0-9_-]+)(?=\s|$|[.,!?])', caseSensitive: false),
        (m) {
      final lead = m[1] ?? '';
      final name = m[2]!.toLowerCase();
      final isGeo = isValidGeohash(name);
      final isActive = isGeo
          ? ctx.currentGeohash == name
          : ctx.currentChannel == name;
      final ref = ChannelRefNode(
          name: name, isGeohash: isGeo, isActive: isActive);
      if (lead.isEmpty) return _NodeTok(ref);
      return _MultiTok([_RawTok(lead), _NodeTok(ref)]);
    });

    // `:shortcode:` -> custom emoji or standard emoji. The PWA formatter regex
    // is `/:([a-zA-Z0-9_]+):/` (message-format.js:251) — it does NOT include
    // `+`/`-`, so `:+1:` / `:-1:` are left as literal text by the renderer (they
    // are only reachable via the emoji autocomplete, which inserts the emoji
    // char directly). Keep the char class identical for 1:1 fidelity.
    tokens = _splitByRegex(tokens, RegExp(r':([a-zA-Z0-9_]+):'), (m) {
      final code = m[1]!;
      final lc = code.toLowerCase();
      // PWA order (message-format.js:251-257): standard emojiMap (lowercased
      // key) is tried FIRST; only then custom emoji, looked up with the EXACT
      // (case-sensitive) code — no lowercase fallback.
      final std = kBuiltinEmoji[lc];
      if (std != null) return _NodeTok(EmojiNode(std));
      final custom = ctx.customEmojis[code];
      if (custom != null) {
        return _NodeTok(CustomEmojiNode(
            shortcode: code, url: _proxiedEmoji(custom, ctx.proxyBase)));
      }
      return _RawTok(m[0]!); // leave untouched
    });

    // ASCII smileys (bounded by start/space on both sides).
    tokens = _applyAsciiSmileys(tokens);

    // Bare unicode emoji wrapping (extended pictographic). Alternation order
    // mirrors message-format.js:271: regional-indicator pairs, then keycap
    // sequences (`#`/`*`/digit + optional VS16 + U+20E3), then the base
    // pictographic + optional VS16 + skin-tone + ZWJ runs. (The PWA's rarer
    // subdivision-flag tag sequence — U+E0020..U+E007E + U+E007F — is not
    // matched here; a documented MINOR gap that only affects e.g. the England
    // flag emoji enlargement.)
    tokens = _splitByRegex(
        tokens,
        RegExp(
            r'(?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]️?⃣)|(?:[☀-➿\u{1F000}-\u{1FAFF}](?:️)?(?:[\u{1F3FB}-\u{1F3FF}])?(?:‍[☀-➿\u{1F000}-\u{1FAFF}](?:️)?)*)',
            unicode: true),
        (m) => _NodeTok(EmojiNode(m[0]!)));

    // Materialize raw tokens into TextSpanNodes; merge adjacency.
    final nodes = <InlineNode>[];
    void emit(_Tok t) {
      if (t is _RawTok) {
        if (t.text.isEmpty) return;
        if (nodes.isNotEmpty && nodes.last is TextSpanNode) {
          final prev = nodes.removeLast() as TextSpanNode;
          nodes.add(TextSpanNode(prev.text + t.text));
        } else {
          nodes.add(TextSpanNode(t.text));
        }
      } else if (t is _NodeTok) {
        nodes.add(t.node);
      } else if (t is _MultiTok) {
        for (final sub in t.parts) {
          emit(sub);
        }
      }
    }

    for (final t in tokens) {
      emit(t);
    }
    return nodes;
  }

  static List<_Tok> _applyAsciiSmileys(List<_Tok> tokens) {
    const map = <String, String>{
      ':)': '😊',
      ':-)': '😊',
      ':(': '😢',
      ':-(': '😢',
      ':D': '😃',
      ':P': '😛',
      ';)': '😉',
      ';-)': '😉',
      ':o': '😮',
      ':O': '😮',
      ':|': '😐',
      '<3': '❤️',
      r'/\': '⚠️',
    };
    // Match a smiley bounded by start/whitespace on each side.
    final re = RegExp(
        r'(^|\s)(:\)|:-\)|:\(|:-\(|:D|:P|;\)|;-\)|:o|:O|:\||<3|/\\)(?=$|\s)');
    return _splitByRegex(tokens, re, (m) {
      final lead = m[1] ?? '';
      final sym = m[2]!;
      final emoji = map[sym] ?? map[sym.toLowerCase()] ?? sym;
      final node = _NodeTok(EmojiNode(emoji));
      if (lead.isEmpty) return node;
      return _MultiTok([_RawTok(lead), node]);
    });
  }

  /// Splits each raw token by [re], replacing matches via [build].
  static List<_Tok> _splitByRegex(
    List<_Tok> tokens,
    RegExp re,
    _Tok Function(Match) build,
  ) {
    final out = <_Tok>[];
    for (final t in tokens) {
      if (t is! _RawTok) {
        out.add(t);
        continue;
      }
      final text = t.text;
      var last = 0;
      for (final m in re.allMatches(text)) {
        if (m.start > last) out.add(_RawTok(text.substring(last, m.start)));
        out.add(build(m));
        last = m.end;
      }
      if (last < text.length) out.add(_RawTok(text.substring(last)));
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Helpers shared with JS.
  // -------------------------------------------------------------------------

  static String _proxied(String url, String? base) {
    if (base == null || base.isEmpty) return url;
    return '$base?url=${Uri.encodeQueryComponent(url)}';
  }

  static String _proxiedEmoji(String url, String? base) {
    if (base == null || base.isEmpty) return url;
    return '$base?emoji=1&url=${Uri.encodeQueryComponent(url)}';
  }

  static String _sanitizeGroupName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }

  /// Validates + decodes a `#gjoin=` token (base64url JSON with v/g/a/e/n).
  static Map<String, dynamic>? _parseGroupInvite(String token) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) return null;
    try {
      var b64 = token.replaceAll('-', '+').replaceAll('_', '/');
      while (b64.length % 4 != 0) {
        b64 += '=';
      }
      final bytes = base64.decode(b64);
      final obj = jsonDecode(utf8.decode(bytes));
      if (obj is! Map) return null;
      if (obj['v'] != 1) return null;
      final g = (obj['g'] ?? '').toString();
      if (!RegExp(
              r'^([0-9a-f]{64}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$',
              caseSensitive: false)
          .hasMatch(g)) {
        return null;
      }
      final a = (obj['a'] ?? '').toString();
      if (!RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(a)) {
        return null;
      }
      return Map<String, dynamic>.from(obj);
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Internal token types used only during inline parsing.
// ---------------------------------------------------------------------------

sealed class _Tok {
  const _Tok();
}

class _RawTok extends _Tok {
  const _RawTok(this.text);
  final String text;
}

class _NodeTok extends _Tok {
  const _NodeTok(this.node);
  final InlineNode node;
}

class _MultiTok extends _Tok {
  const _MultiTok(this.parts);
  final List<_Tok> parts;
}

/// An inline node that carries a media item; flattened into MediaBlocks by
/// [_inlineToBlocks]. Never reaches the renderer as an inline span.
class _MediaInline extends InlineNode {
  const _MediaInline(this.item);
  final MediaItem item;
}

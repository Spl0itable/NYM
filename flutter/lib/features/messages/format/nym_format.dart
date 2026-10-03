// Pure content-to-node formatter mirroring the PWA's markdown, media, mention and emoji rules and pass order.

import 'dart:collection';
import 'dart:convert';

import '../../../models/channel.dart' show isValidGeohash;
import '../../group_tools/group_tools.dart' show GroupTools;
import '../../media_notes/media_notes.dart';
import '../../i18n/i18n.dart';
import 'discord_timestamp.dart';

/// Characters that can trigger formatting; without any, the fast path applies.
final RegExp _rxTriggers = RegExp(r'[^\x20-\x7E\n]|[*_~`#>@:;/\\&<>"|]');

final RegExp _rxBlockTrigger =
    RegExp(r'^[ \t]*(?:[-*]|\d{1,9}\.) \S', multiLine: true);

const String kSpoilerMask = '\u2592\u2592\u2592\u2592';

const String kSpoilerLabel = 'Spoiler, tap to reveal';

const int kMaxTimestampSeconds = 8640000000000;

final RegExp _rxSpoiler = RegExp(r'\|\|([^\s|](?:[^\n]*?[^\s|])??)\|\|');

final RegExp _rxTimestamp = RegExp(r'<t:(-?\d{1,17})(?::([tTdDfFR]))?>');
final RegExp _rxMediaNote = RegExp(
    r'((?:View-once (?:photo|video|voice message): )?)(https?://[^\s#<>"]+|nymlocal:[A-Za-z0-9]{1,40})#(nym:[A-Za-z0-9=;:./_+-]+)');

final RegExp _rxListLine = RegExp(r'^(\t| {2,})?([-*]|\d{1,9}\.) (\S.*)$');

final RegExp _rxSubtextLine = RegExp(r'^-# (\S.*)$');

final RegExp _rxCodeSpans = RegExp(r'```[\s\S]*?```|```[\s\S]*$|`[^`\n]+?`');

final RegExp _rxEmphasisSentinel = RegExp('[\uFDE0-\uFDEF]');

int? parseTimestampSeconds(String raw) {
  if (!RegExp(r'^-?\d{1,17}$').hasMatch(raw)) return null;
  final n = int.tryParse(raw);
  if (n == null || n.abs() > kMaxTimestampSeconds) return null;
  return n;
}

/// NIP-19 entities are alphanumeric and trip no trigger, so check them separately.
final RegExp _rxNostrTrigger = RegExp(
    r'(?:nevent|naddr|nprofile|note|npub)1[023456789acdefghjklmnpqrstuvwxyz]{20,}|[0-9a-f]{64}',
    caseSensitive: false);

/// Formatting context, the analogue of the JS `ctx`.
class FormatContext {
  const FormatContext({
    this.currentChannel,
    this.currentGeohash,
    this.customEmojis = const {},
    this.proxyBase,
    this.knownChannels = const {},
    this.commonMark = false,
  });

  /// Active named channel (lowercase); a matching `#ref` renders active.
  final String? currentChannel;

  /// Active geohash channel (lowercase); a matching `#ref` renders active.
  final String? currentGeohash;

  /// NIP-30 custom emoji: shortcode without colons -> image url.
  final Map<String, String> customEmojis;

  /// Optional media/emoji proxy base.
  final String? proxyBase;

  /// Currently informational only.
  final Set<String> knownChannels;

  final bool commonMark;

  static const empty = FormatContext();
}

/// Parse cache key; the collection fields compare by identity since providers replace rather than mutate them.
class _ParseCacheKey {
  _ParseCacheKey(this.content, FormatContext c)
      : currentChannel = c.currentChannel,
        currentGeohash = c.currentGeohash,
        proxyBase = c.proxyBase,
        customEmojis = c.customEmojis,
        knownChannels = c.knownChannels,
        commonMark = c.commonMark;

  final String content;
  final String? currentChannel;
  final String? currentGeohash;
  final String? proxyBase;
  final Map<String, String> customEmojis;
  final Set<String> knownChannels;
  final bool commonMark;

  @override
  bool operator ==(Object other) =>
      other is _ParseCacheKey &&
      other.content == content &&
      other.currentChannel == currentChannel &&
      other.currentGeohash == currentGeohash &&
      other.proxyBase == proxyBase &&
      identical(other.customEmojis, customEmojis) &&
      identical(other.knownChannels, knownChannels) &&
      other.commonMark == commonMark;

  @override
  int get hashCode => Object.hash(
        content,
        currentChannel,
        currentGeohash,
        proxyBase,
        identityHashCode(customEmojis),
        identityHashCode(knownChannels),
        commonMark,
      );
}

/// Base type for block-level nodes.
sealed class FormatBlock {
  const FormatBlock();
}

/// A run of inline content; internal newlines are kept.
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

/// A `> quote` block, possibly nested, with an optional parsed `@author`.
class QuoteBlock extends FormatBlock {
  const QuoteBlock({required this.children, this.author});
  final List<FormatBlock> children;

  /// Author from a `> @Author: msg` header, suffix included, else null.
  final String? author;
}

/// A heading line (`#`/`##`/`###` -> level 1/2/3).
class HeadingBlock extends FormatBlock {
  const HeadingBlock({required this.level, required this.inlines});
  final int level;
  final List<InlineNode> inlines;
}

class SubtextBlock extends FormatBlock {
  const SubtextBlock(this.inlines);
  final List<InlineNode> inlines;
}

class ListBlock extends FormatBlock {
  const ListBlock({
    required this.ordered,
    required this.start,
    required this.items,
  });
  final bool ordered;
  final int start;
  final List<ListItemNode> items;
}

class ListItemNode {
  const ListItemNode({required this.inlines, this.children = const []});
  final List<InlineNode> inlines;
  final List<ListBlock> children;
}

/// Adjacent media items collapsed into a gallery.
class MediaBlock extends FormatBlock {
  const MediaBlock(this.items);
  final List<MediaItem> items;
}

/// A playable audio link; never joins a gallery, where a seek bar can't be scrubbed.
class AudioBlock extends FormatBlock {
  const AudioBlock({required this.url, required this.fileName, this.note});

  final MediaNote? note;

  /// Playback/download URL, already proxied when a proxyBase was supplied.
  final String url;

  /// Download basename; empty when the URL has none.
  final String fileName;
}

/// A single image or video inside a [MediaBlock].
class MediaItem {
  const MediaItem({required this.url, required this.isVideo});

  /// Display URL, already proxied when a proxyBase was supplied.
  final String url;
  final bool isVideo;
}

/// Base type for inline nodes.
sealed class InlineNode {
  const InlineNode();
}

/// Plain text; newlines render as line breaks.
class TextSpanNode extends InlineNode {
  const TextSpanNode(this.text);
  final String text;
}

class BoldNode extends InlineNode {
  const BoldNode(this.children);
  final List<InlineNode> children;
}

class ItalicNode extends InlineNode {
  const ItalicNode(this.children);
  final List<InlineNode> children;
}

class StrikeNode extends InlineNode {
  const StrikeNode(this.children);
  final List<InlineNode> children;
}

class UnderlineNode extends InlineNode {
  const UnderlineNode(this.children);
  final List<InlineNode> children;
}

class SpoilerNode extends InlineNode {
  const SpoilerNode(this.children);
  final List<InlineNode> children;
}

class InlineGalleryNode extends InlineNode {
  const InlineGalleryNode(this.items);
  final List<MediaItem> items;
}

class TimestampNode extends InlineNode {
  const TimestampNode(
      {required this.seconds, required this.style, this.raw = ''});
  final int seconds;
  final String style;
  final String raw;
}

class InlineCodeNode extends InlineNode {
  const InlineCodeNode(this.code);
  final String code;
}

/// A bare `https?://` link that isn't media, a channel link or an invite.
class LinkNode extends InlineNode {
  const LinkNode(this.url);
  final String url;
}

/// `@name` or `@name#xxxx`; [suffix] is the 4-hex tag without `#`, or null.
class MentionNode extends InlineNode {
  const MentionNode({required this.base, this.suffix});

  /// Name portion including the leading `@`.
  final String base;
  final String? suffix;
}

class ChannelRefNode extends InlineNode {
  const ChannelRefNode({
    required this.name,
    required this.isGeohash,
    required this.isActive,
  });

  /// Channel name without `#`, lowercased.
  final String name;
  final bool isGeohash;
  final bool isActive;
}

/// A standard unicode emoji from a shortcode, ASCII smiley, or bare emoji.
class EmojiNode extends InlineNode {
  const EmojiNode(this.unicode);
  final String unicode;
}

/// A NIP-30 custom emoji resolved against `ctx.customEmojis`.
class CustomEmojiNode extends InlineNode {
  const CustomEmojiNode({required this.shortcode, required this.url});
  final String shortcode;

  /// Image url, already proxied when a proxyBase was supplied.
  final String url;
}

/// `app.nym.bar/#<e|g|c>:<id>` channel-link chip.
class ChannelLinkChip extends InlineNode {
  const ChannelLinkChip({required this.ref, required this.label});

  /// `<prefix>:<id>`, e.g. `g:9q8y`.
  final String ref;

  /// The original matched URL text.
  final String label;
}

/// A pasted NIP-19 entity or bare 64-hex event id, rendered as a chip and unfurled below.
class NostrRefNode extends InlineNode {
  const NostrRefNode({required this.token, required this.raw});

  /// The entity with its scheme stripped.
  final String token;

  /// Bare hex keeps its own text, since 64 hex chars aren't always an event id.
  final bool raw;
}

/// `…#gjoin=<token>` group-invite chip.
class GroupInviteChip extends InlineNode {
  const GroupInviteChip({required this.name, required this.token});
  final String name;
  final String token;
}

class CallLinkChip extends InlineNode {
  const CallLinkChip(
      {required this.name, required this.video, required this.token});
  final String name;
  final bool video;
  final String token;
}

// Built-in shortcode -> unicode emoji (common subset).

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

class NymFormat {
  const NymFormat._();

  /// Hidden `[gc:BASE64]` game token, including on `> ` quote lines; it rides the wire but must never show.
  static final RegExp _rxGameToken =
      RegExp(r'\n[ \t]*(?:>[ \t]*)*\[gc:[A-Za-z0-9+/=]+\]');

  /// Strips game tokens for display only; never on wire-bound content, since `?guess` routing reads them.
  static String stripGameTokens(String content) {
    if (!content.contains('[gc:')) return content;
    return content
        .replaceAll(_rxGameToken, '')
        .replaceAll(RegExp(r'^[ \t]*(?:>[ \t]*)*\[gc:[A-Za-z0-9+/=]+\]'), '');
  }

  static String _mapOutsideCode(String text, String Function(String) fn) {
    final out = StringBuffer();
    var last = 0;
    for (final m in _rxCodeSpans.allMatches(text)) {
      out
        ..write(fn(text.substring(last, m.start)))
        ..write(m[0]);
      last = m.end;
    }
    out.write(fn(text.substring(last)));
    return out.toString();
  }

  static String maskSpoilers(String text) {
    if (!text.contains('||')) return text;
    return _mapOutsideCode(
        text, (part) => part.replaceAll(_rxSpoiler, kSpoilerMask));
  }

  static String stripForPreview(String text, {String? locale, DateTime? now}) {
    if (text.isEmpty) return text;
    if (text.contains('#nym:')) text = previewText(text, tr);
    return _mapOutsideCode(
        text,
        (part) => part
                .replaceAll(_rxSpoiler, kSpoilerMask)
                .replaceAllMapped(_rxTimestamp, (m) {
              final seconds = parseTimestampSeconds(m[1]!);
              if (seconds == null) return m[0]!;
              return formatDiscordTimestamp(seconds, m[2] ?? 'f',
                  locale: locale, now: now);
            }).replaceAllMapped(
                    RegExp(r'(^|\n)-# (?=\S)'), (m) => m[1]!));
  }

  static ({int seconds, String style, String tag})? parseTimestampInput(
      String input) {
    final parts =
        input.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    var style = 'f';
    if (parts.length > 1 && RegExp(r'^[tTdDfFR]$').hasMatch(parts.last)) {
      style = parts.removeLast();
    }
    final raw = parts.join(' ');
    int? seconds;
    if (RegExp(r'^-?\d{1,17}$').hasMatch(raw)) {
      seconds = int.tryParse(raw);
    } else {
      final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2}))?$')
          .firstMatch(raw);
      if (m == null) return null;
      final y = int.parse(m[1]!);
      final mo = int.parse(m[2]!);
      final d = int.parse(m[3]!);
      final h = m[4] == null ? 0 : int.parse(m[4]!);
      final mi = m[5] == null ? 0 : int.parse(m[5]!);
      if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) {
        return null;
      }
      final date = DateTime(y, mo, d, h, mi);
      if (date.year != y || date.month != mo || date.day != d) return null;
      seconds = (date.millisecondsSinceEpoch / 1000).floor();
    }
    if (seconds == null || parseTimestampSeconds('$seconds') == null) {
      return null;
    }
    return (seconds: seconds, style: style, tag: '<t:$seconds:$style>');
  }

  /// Bounded LRU of parse results; parsing is pure and expensive, and rows re-format on every rebuild.
  static final LinkedHashMap<_ParseCacheKey, List<FormatBlock>> _parseCache =
      LinkedHashMap<_ParseCacheKey, List<FormatBlock>>();
  static const int _parseCacheCap = 800;

  /// Test hook: drop every memoized parse.
  static void clearParseCache() => _parseCache.clear();

  static List<FormatBlock> format(String content, [FormatContext? ctx]) {
    final c = ctx ?? FormatContext.empty;
    final key = _ParseCacheKey(content, c);
    // Remove and re-insert to mark most recently used.
    final hit = _parseCache.remove(key);
    if (hit != null) {
      _parseCache[key] = hit;
      return hit;
    }
    final result = _formatUncached(content, c);
    _parseCache[key] = result;
    if (_parseCache.length > _parseCacheCap) {
      _parseCache.remove(_parseCache.keys.first);
    }
    return result;
  }

  static List<FormatBlock> _formatUncached(String content, FormatContext c) {
    // Elide the hidden game token first, including on quoted lines.
    content = stripGameTokens(content);

    // Fast path when nothing can trigger formatting.
    if (!_rxTriggers.hasMatch(content) &&
        !_rxNostrTrigger.hasMatch(content) &&
        !_rxBlockTrigger.hasMatch(content)) {
      return _plainParagraphs(content);
    }

    // Collapse `@name#xxxx#xxxx` to `@name#xxxx` first.
    final collapsed = content.replaceAllMapped(
      RegExp(r'@([^@#\s]+)#([0-9a-f]{4})#\2\b', caseSensitive: false),
      (m) => '@${m[1]}#${m[2]}',
    );

    return _formatWithQuotes(collapsed, c, 0);
  }

  static List<FormatBlock> _plainParagraphs(String content) {
    // One block preserving every newline, like the PWA fast path.
    return [
      ParagraphBlock([TextSpanNode(content)]),
    ];
  }

  static const int _maxQuoteDepth = 5;

  /// Splits leading `>` runs into [QuoteBlock]s and formats the rest.
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
        final authorMatch = RegExp(r'^@([^:]+):\s*(.*)').firstMatch(firstLine);
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
        if (text.isNotEmpty) {
          out.addAll(_formatInlineBlocks(text, ctx, inQuote: depth > 0));
        }
      }
    }

    if (out.isEmpty) {
      return _formatInlineBlocks(content, ctx, inQuote: depth > 0);
    }
    return out;
  }

  static String _cleanQuoteAuthor(String raw) {
    var a = raw.trim();
    // Collapse `name#xxxx#xxxx` to `name#xxxx`.
    a = a.replaceFirstMapped(
      RegExp(r'^([^#]+)#([0-9a-f]{4})#\2$', caseSensitive: false),
      (m) => '${m[1]}#${m[2]}',
    );
    return a;
  }

  // Inline passes over a token list of raw text and resolved nodes, so later passes never re-scan resolved content.

  static List<FormatBlock> _formatInlineBlocks(String text, FormatContext ctx,
      {bool inQuote = false}) {
    // Extract code first so its contents are shielded.
    final codeBlocks = <CodeBlock>[];
    final inlineCode = <String>[];
    final stamps = <TimestampNode>[];
    final notes = <MediaNote>[];
    var s = text.replaceAll(_rxEmphasisSentinel, '\uFFFD');

    s = s.replaceAllMapped(RegExp(r'```([\s\S]*?)```'), (m) {
      final idx = codeBlocks.length;
      codeBlocks.add(_makeCodeBlock(m[1] ?? ''));
      return 'F$idx';
    });
    // Unterminated ``` runs to the end.
    s = s.replaceAllMapped(RegExp(r'```([\s\S]+)$'), (m) {
      final idx = codeBlocks.length;
      codeBlocks.add(_makeCodeBlock(m[1] ?? ''));
      return 'F$idx';
    });
    s = s.replaceAllMapped(RegExp(r'`([^`]+?)`'), (m) {
      final idx = inlineCode.length;
      inlineCode.add(m[1] ?? '');
      return 'C$idx';
    });
    if (s.contains('#nym:')) {
      s = s.replaceAllMapped(_rxMediaNote, (m) {
        final note = parseMediaUrl('${m[2]}#${m[3]}');
        if (note == null) return m[0]!;
        final idx = notes.length;
        notes.add(note);
        return '\x01M$idx\x01';
      });
    }
    s = s.replaceAllMapped(_rxTimestamp, (m) {
      final seconds = parseTimestampSeconds(m[1]!);
      if (seconds == null) return m[0]!;
      final idx = stamps.length;
      stamps.add(
          TimestampNode(seconds: seconds, style: m[2] ?? 'f', raw: m[0]!));
      return 'T$idx';
    });

    // Code placeholder lines become code blocks, `#` lines headings, the rest paragraphs.
    final blocks = <FormatBlock>[];
    final lines = s.split('\n');
    final paraBuf = <String>[];

    final listBuf = <_ListLine>[];

    List<InlineNode> inline(String t) =>
        _collapseMedia(_parseInline(t, ctx, codeBlocks, inlineCode, stamps, notes));

    void flushPara() {
      if (paraBuf.isEmpty) return;
      final joined = paraBuf.join('\n');
      paraBuf.clear();
      blocks.addAll(
          _inlineToBlocks(joined, ctx, codeBlocks, inlineCode, stamps, notes));
    }

    void flushList() {
      if (listBuf.isEmpty) return;
      blocks.addAll(_buildLists(listBuf, inline));
      listBuf.clear();
    }

    for (final line in lines) {
      final fenceOnly = RegExp(r'^F(\d+)$').firstMatch(line.trim());
      if (fenceOnly != null) {
        flushPara();
        flushList();
        blocks.add(codeBlocks[int.parse(fenceOnly[1]!)]);
        continue;
      }
      final heading = RegExp(r'^(#{1,3}) (.+)$').firstMatch(line);
      if (heading != null) {
        flushPara();
        flushList();
        final level = heading[1]!.length;
        blocks.add(HeadingBlock(
          level: level,
          inlines: inline(heading[2]!),
        ));
        continue;
      }
      final subtext = inQuote ? null : _rxSubtextLine.firstMatch(line);
      if (subtext != null) {
        flushPara();
        flushList();
        blocks.add(SubtextBlock(inline(subtext[1]!)));
        continue;
      }
      final item = _rxListLine.firstMatch(line);
      if (item != null) {
        flushPara();
        final marker = item[2]!;
        final ordered = marker != '-' && marker != '*';
        listBuf.add(_ListLine(
          level: listBuf.isEmpty || item[1] == null ? 0 : 1,
          ordered: ordered,
          number: ordered ? int.parse(marker.substring(0, marker.length - 1)) : 1,
          text: item[3]!,
        ));
        continue;
      }
      flushList();
      paraBuf.add(line);
    }
    flushPara();
    flushList();

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

  /// Media runs split paragraphs into galleries; everything else stays inline.
  static List<FormatBlock> _inlineToBlocks(
    String text,
    FormatContext ctx,
    List<CodeBlock> codeBlocks,
    List<String> inlineCode,
    List<TimestampNode> stamps,
    List<MediaNote> notes,
  ) {
    final inlines =
        _parseInline(text, ctx, codeBlocks, inlineCode, stamps, notes);

    // Adjacent media (whitespace between) collapse into one gallery.
    final blocks = <FormatBlock>[];
    var runInlines = <InlineNode>[];
    var mediaRun = <MediaItem>[];

    void flushInlines() {
      if (runInlines.isEmpty) return;
      // Drop empty text-only runs.
      final hasContent = runInlines
          .any((n) => n is! TextSpanNode || (n).text.trim().isNotEmpty);
      if (hasContent) blocks.add(ParagraphBlock(List.of(runInlines)));
      runInlines = [];
    }

    void flushMedia() {
      if (mediaRun.isEmpty) return;
      blocks.add(MediaBlock(List.of(mediaRun)));
      mediaRun = [];
    }

    for (final node in inlines) {
      if (node is AudioInlineNode) {
        // Its own block, never folded into a gallery.
        flushMedia();
        flushInlines();
        blocks.add(node.block);
      } else if (node is MediaInlineNode) {
        flushInlines();
        mediaRun.add(node.item);
      } else if (node is TextSpanNode && node.text.trim().isEmpty) {
        // Whitespace between media keeps the gallery contiguous.
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

  static List<ListBlock> _buildLists(
      List<_ListLine> lines, List<InlineNode> Function(String) inline) {
    final top = <_ListTree>[];
    for (final line in lines) {
      if (line.level == 1 && top.isNotEmpty) {
        top.last.children.add(_ListTree(line));
      } else {
        top.add(_ListTree(line));
      }
    }
    return _listSeq(top, inline);
  }

  static List<ListBlock> _listSeq(
      List<_ListTree> nodes, List<InlineNode> Function(String) inline) {
    final out = <ListBlock>[];
    var i = 0;
    while (i < nodes.length) {
      final head = nodes[i].line;
      final items = <ListItemNode>[];
      while (i < nodes.length && nodes[i].line.ordered == head.ordered) {
        final node = nodes[i++];
        items.add(ListItemNode(
          inlines: inline(node.line.text),
          children: node.children.isEmpty
              ? const <ListBlock>[]
              : _listSeq(node.children, inline),
        ));
      }
      out.add(ListBlock(
          ordered: head.ordered,
          start: head.ordered ? head.number : 1,
          items: items));
    }
    return out;
  }

  static const String _openSpoiler = '\uFDE0';
  static const String _openBold = '\uFDE1';
  static const String _openUnderline = '\uFDE2';
  static const String _openItalic = '\uFDE3';
  static const String _openStrike = '\uFDE4';
  static const int _closeOffset = 8;

  static bool _isOpenSentinel(int unit) => unit >= 0xFDE0 && unit <= 0xFDE4;
  static bool _isCloseSentinel(int unit) => unit >= 0xFDE8 && unit <= 0xFDEC;

  static String _closeOf(String open) =>
      String.fromCharCode(open.codeUnitAt(0) + _closeOffset);

  static bool _sentinelsBalanced(String inner) {
    final stack = <int>[];
    for (final unit in inner.codeUnits) {
      if (_isOpenSentinel(unit)) {
        stack.add(unit);
      } else if (_isCloseSentinel(unit)) {
        if (stack.isEmpty || stack.removeLast() + _closeOffset != unit) {
          return false;
        }
      }
    }
    return stack.isEmpty;
  }

  static String _wrapBalanced(String s, RegExp rx, String open) {
    final close = _closeOf(open);
    final out = StringBuffer();
    var last = 0;
    var pos = 0;
    while (pos <= s.length) {
      final it = rx.allMatches(s, pos).iterator;
      if (!it.moveNext()) break;
      final m = it.current;
      final inner = m[1]!;
      if (!_sentinelsBalanced(inner)) {
        pos = m.start + 1;
        continue;
      }
      out
        ..write(s.substring(last, m.start))
        ..write(open)
        ..write(inner)
        ..write(close);
      last = m.end;
      pos = m.end;
    }
    out.write(s.substring(last));
    return out.toString();
  }

  static String _markEmphasis(String text, bool commonMark) {
    var s = _wrapBalanced(text, _rxSpoiler, _openSpoiler);
    s = _wrapBalanced(s, RegExp(r'\*\*(.+?)\*\*'), _openBold);
    s = _wrapBalanced(s, RegExp(r'(?<!\w)__(.+?)__(?!\w)'),
        commonMark ? _openBold : _openUnderline);
    s = _wrapBalanced(s, RegExp(r'(?<![:/])\*([^*\s][^*]*)\*'), _openItalic);
    s = _wrapBalanced(
        s, RegExp(r'(?<![:/\w])_([^_\s][^_]*)_(?!\w)'), _openItalic);
    s = _wrapBalanced(s, RegExp(r'~~(.+?)~~'), _openStrike);
    return s;
  }

  static List<InlineNode> _parseInline(
    String text,
    FormatContext ctx,
    List<CodeBlock> codeBlocks,
    List<String> inlineCode,
    List<TimestampNode> stamps,
    List<MediaNote> notes,
  ) {
    final marked = _markEmphasis(text, ctx.commonMark);
    var i = 0;
    List<InlineNode> parse(int? closeUnit) {
      final out = <InlineNode>[];
      final buf = StringBuffer();
      var leafStart = i;
      void flush() {
        if (buf.isEmpty) return;
        final top = closeUnit == null;
        out.addAll(_parseLeaf(
            buf.toString(), ctx, codeBlocks, inlineCode, stamps, notes,
            blockStart: top && leafStart == 0,
            blockEnd: top && i >= marked.length));
        buf.clear();
      }

      while (i < marked.length) {
        final unit = marked.codeUnitAt(i);
        if (buf.isEmpty) leafStart = i;
        if (_isOpenSentinel(unit)) {
          flush();
          i++;
          final kids = _collapseMedia(parse(unit + _closeOffset));
          out.add(switch (String.fromCharCode(unit)) {
            _openSpoiler => SpoilerNode(kids),
            _openBold => BoldNode(kids),
            _openUnderline => UnderlineNode(kids),
            _openItalic => ItalicNode(kids),
            _ => StrikeNode(kids),
          });
          continue;
        }
        if (_isCloseSentinel(unit)) {
          i++;
          if (unit == closeUnit) {
            flush();
            return out;
          }
          continue;
        }
        buf.writeCharCode(unit);
        i++;
      }
      flush();
      return out;
    }

    return parse(null);
  }

  static List<InlineNode> _collapseMedia(List<InlineNode> nodes) {
    if (!nodes.any((n) => n is MediaInlineNode)) return nodes;
    final out = <InlineNode>[];
    var run = <MediaItem>[];
    var gap = <InlineNode>[];
    void flushRun() {
      if (run.isEmpty) return;
      out.add(InlineGalleryNode(List.of(run)));
      run = [];
    }

    for (final n in nodes) {
      if (n is MediaInlineNode) {
        if (run.isEmpty) out.addAll(gap);
        gap = [];
        run.add(n.item);
      } else if (run.isNotEmpty &&
          n is TextSpanNode &&
          RegExp(r'^[ \t\r\n]*$').hasMatch(n.text)) {
        gap.add(n);
      } else {
        flushRun();
        out.addAll(gap);
        gap = [];
        out.add(n);
      }
    }
    flushRun();
    out.addAll(gap);
    return out;
  }

  static List<_Tok> _mergeRaw(List<_Tok> tokens) {
    final flat = <_Tok>[];
    void add(_Tok t) {
      if (t is _MultiTok) {
        for (final p in t.parts) {
          add(p);
        }
        return;
      }
      if (t is _RawTok && flat.isNotEmpty && flat.last is _RawTok) {
        flat.add(_RawTok((flat.removeLast() as _RawTok).text + t.text));
        return;
      }
      flat.add(t);
    }

    for (final t in tokens) {
      add(t);
    }
    return flat;
  }

  static List<_Tok> _splitBounded(
    List<_Tok> tokens,
    RegExp re,
    _Tok Function(Match) build, {
    required bool blockStart,
    required bool blockEnd,
  }) {
    final merged = _mergeRaw(tokens);
    final out = <_Tok>[];
    for (var k = 0; k < merged.length; k++) {
      final t = merged[k];
      if (t is! _RawTok) {
        out.add(t);
        continue;
      }
      final pre = k == 0 && blockStart ? '' : '\u0002';
      final post = k == merged.length - 1 && blockEnd ? '' : '\u0002';
      final text = '$pre${t.text}$post';
      final limit = text.length - post.length;
      var last = pre.length;
      for (final m in re.allMatches(text)) {
        if (m.start > last) out.add(_RawTok(text.substring(last, m.start)));
        out.add(build(m));
        last = m.end;
      }
      if (last < limit) out.add(_RawTok(text.substring(last, limit)));
    }
    return out;
  }

  static List<InlineNode> _parseLeaf(
    String text,
    FormatContext ctx,
    List<CodeBlock> codeBlocks,
    List<String> inlineCode,
    List<TimestampNode> stamps,
    List<MediaNote> notes, {
    bool blockStart = true,
    bool blockEnd = true,
  }) {
    var tokens = <_Tok>[_RawTok(text)];

    // Fenced placeholders are block-level, but handle inline ones.
    tokens = _splitByRegex(tokens, RegExp(r'C(\d+)'),
        (m) => _NodeTok(InlineCodeNode(inlineCode[int.parse(m[1]!)])));

    tokens = _splitByRegex(tokens, RegExp(r'T(\d+)'),
        (m) => _NodeTok(stamps[int.parse(m[1]!)]));

    tokens = _splitByRegex(tokens, RegExp('\x01M(\\d+)\x01'), (m) {
      final note = notes[int.parse(m[1]!)];
      return _NodeTok(AudioInlineNode(AudioBlock(
        url: note.url,
        fileName: '',
        note: note,
      )));
    });

    // Audio first, since the video pass would claim .ogg/.webm.
    tokens = _splitByRegex(
        tokens,
        RegExp(r'(https?://[^\s]+\.(mp3|m4a|aac|wav|flac|opus|oga)(\?[^\s]*)?)',
            caseSensitive: false),
        (m) => _NodeTok(AudioInlineNode(AudioBlock(
              url: _proxied(m[1]!, ctx.proxyBase),
              fileName: _urlFileName(m[1]!),
            ))));

    tokens = _splitByRegex(
        tokens,
        RegExp(r'(https?://[^\s]+\.(mp4|webm|ogg|mov)(\?[^\s]*)?)',
            caseSensitive: false),
        (m) => _NodeTok(MediaInlineNode(
            MediaItem(url: _proxied(m[1]!, ctx.proxyBase), isVideo: true))));
    tokens = _splitByRegex(
        tokens,
        RegExp(r'(https?://[^\s]+\.(jpg|jpeg|png|gif|webp)(\?[^\s]*)?)',
            caseSensitive: false),
        (m) => _NodeTok(MediaInlineNode(
            MediaItem(url: _proxied(m[1]!, ctx.proxyBase), isVideo: false))));

    tokens = _splitByRegex(
        tokens,
        RegExp(r'https?://web\.nymchat\.app/#([egc]):([^\s<>"]+)',
            caseSensitive: false), (m) {
      return _NodeTok(ChannelLinkChip(ref: '${m[1]}:${m[2]}', label: m[0]!));
    });

    tokens = _splitByRegex(
        tokens, RegExp(r'https?://[^\s<>"]*#call=([A-Za-z0-9_-]+)'), (m) {
      final token = m[1]!;
      final link = GroupTools.parseCallLinkInput(token);
      if (link == null) return _RawTok(m[0]!);
      return _NodeTok(CallLinkChip(
          name: link.name.isEmpty ? 'call' : link.name,
          video: link.kind == 'video',
          token: token));
    });

    tokens = _splitByRegex(
        tokens, RegExp(r'https?://[^\s<>"]*#gjoin=([A-Za-z0-9_-]+)'), (m) {
      final token = m[1]!;
      final invite = _parseGroupInvite(token);
      if (invite == null) return _RawTok(m[0]!);
      final name = _sanitizeGroupName(invite['n']?.toString() ?? '');
      return _NodeTok(
          GroupInviteChip(name: name.isEmpty ? 'group' : name, token: token));
    });

    tokens = _splitByRegex(
        tokens, RegExp(r'https?://[^\s]+'), (m) => _NodeTok(LinkNode(m[0]!)));

    // After bare links so an entity inside a URL stays part of it; the lookbehind blocks mid-token matches.
    tokens = _splitByRegex(
        tokens,
        RegExp(
            r'''(?<![\w/:.#=&?"'-])(?:nostr:)?((?:nevent|naddr|nprofile|note|npub)1[023456789acdefghjklmnpqrstuvwxyz]{20,})(?![\w-])''',
            caseSensitive: false),
        (m) => _NodeTok(NostrRefNode(token: m[1]!, raw: false)));

    tokens = _splitByRegex(
        tokens,
        RegExp(r'''(?<![\w/:.#=&?"'-])([0-9a-f]{64})(?![\w-])''',
            caseSensitive: false),
        (m) => _NodeTok(NostrRefNode(token: m[1]!.toLowerCase(), raw: true)));

    // Suffixed mentions; the name may contain spaces, bounded by `#xxxx`, with no trailing space.
    tokens = _splitByRegex(
        tokens,
        RegExp(r'@([^@#\n]*?)(?<!\s)#([0-9a-f]{4})\b', caseSensitive: false),
        (m) => _NodeTok(MentionNode(base: '@${m[1]}', suffix: m[2])));

    tokens = _splitByRegex(tokens, RegExp(r'@([^@\s][^@\s]*)'),
        (m) => _NodeTok(MentionNode(base: m[0]!)));

    tokens = _splitBounded(tokens,
        RegExp(r'(^|\s)#([a-z0-9_-]+)(?=\s|$|[.,!?])', caseSensitive: false),
        blockStart: blockStart,
        blockEnd: blockEnd, (m) {
      final lead = m[1] ?? '';
      final name = m[2]!.toLowerCase();
      final isGeo = isValidGeohash(name);
      final isActive =
          isGeo ? ctx.currentGeohash == name : ctx.currentChannel == name;
      final ref =
          ChannelRefNode(name: name, isGeohash: isGeo, isActive: isActive);
      if (lead.isEmpty) return _NodeTok(ref);
      return _MultiTok([_RawTok(lead), _NodeTok(ref)]);
    });

    // Same char class as the PWA, so `:+1:` and `:-1:` stay literal.
    tokens = _splitByRegex(tokens, RegExp(r':([a-zA-Z0-9_]+):'), (m) {
      final code = m[1]!;
      final lc = code.toLowerCase();
      // Standard emoji (lowercased) first, then custom emoji by exact case-sensitive code.
      final std = kBuiltinEmoji[lc];
      if (std != null) return _NodeTok(EmojiNode(std));
      final custom = ctx.customEmojis[code];
      if (custom != null) {
        return _NodeTok(CustomEmojiNode(
            shortcode: code, url: _proxiedEmoji(custom, ctx.proxyBase)));
      }
      return _RawTok(m[0]!); // leave untouched
    });

    // ASCII smileys bounded by start or whitespace on both sides.
    tokens = _applyAsciiSmileys(tokens, blockStart, blockEnd);

    // Regional-indicator pairs, keycaps, then pictographic runs; subdivision-flag tag sequences aren't matched.
    tokens = _splitByRegex(
        tokens,
        RegExp(
            r'(?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]️?⃣)|(?:[☀-➿\u{1F000}-\u{1FAFF}](?:️)?(?:[\u{1F3FB}-\u{1F3FF}])?(?:‍[☀-➿\u{1F000}-\u{1FAFF}](?:️)?)*)',
            unicode: true),
        (m) => _NodeTok(EmojiNode(m[0]!)));

    // Materialize raw tokens into text nodes, merging neighbors.
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

  static List<_Tok> _applyAsciiSmileys(
      List<_Tok> tokens, bool blockStart, bool blockEnd) {
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
    final re = RegExp(
        r'(^|\s)(:\)|:-\)|:\(|:-\(|:D|:P|;\)|;-\)|:o|:O|:\||<3|/\\)(?=$|\s)');
    return _splitBounded(tokens, re,
        blockStart: blockStart, blockEnd: blockEnd, (m) {
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

  static String _proxied(String url, String? base) {
    if (base == null || base.isEmpty) return url;
    return '$base?url=${Uri.encodeQueryComponent(url)}';
  }

  /// URL path basename for the audio download label; empty when none.
  static String _urlFileName(String url) {
    try {
      final segs = Uri.parse(url).pathSegments;
      if (segs.isEmpty) return '';
      final last = Uri.decodeComponent(segs.last).trim();
      return last.length > 60 ? last.substring(0, 60) : last;
    } catch (_) {
      return '';
    }
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

  /// Validates and decodes a `#gjoin=` token (base64url JSON with v/g/a/e/n).
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

/// Carries a media item until [_inlineToBlocks] flattens it into a block.
class AudioInlineNode extends InlineNode {
  const AudioInlineNode(this.block);
  final AudioBlock block;
}

class _ListLine {
  const _ListLine({
    required this.level,
    required this.ordered,
    required this.number,
    required this.text,
  });
  final int level;
  final bool ordered;
  final int number;
  final String text;
}

class _ListTree {
  _ListTree(this.line);
  final _ListLine line;
  final List<_ListTree> children = [];
}

class MediaInlineNode extends InlineNode {
  const MediaInlineNode(this.item);
  final MediaItem item;
}

// composer_format.dart — the composer's WYSIWYG affordances: a formatting
// toolbar that writes the markdown for the user, and thumbnail previews of the
// images/videos attached to the draft (shown BEFORE send so the user can
// confirm what they picked).
//
// There is no preview panel: the field renders the formatting itself, with the
// markers hidden (composer_markdown.dart).
//
// Mirrors the PWA's `js/modules/rich-compose.js` one-for-one: the same toolbar
// set, the same markdown transforms, the same `nym_format_toolbar` preference
// key, and the same panel stack above the input (attachments → upload bar →
// toolbar → field).
//
// The draft on the wire stays plain markdown — the format every client parses
// via NymFormat — so nothing here changes what is sent, only how it is composed.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/i18n/i18n.dart';
import '../../features/messages/format/message_content.dart' show proxiedMedia;
import '../nym_icons.dart' show NymSvgIcon;

/// Persisted toolbar visibility. Same localStorage key as the PWA so a user who
/// turns the toolbar on there finds it on here once settings sync.
const String kFormatToolbarKey = 'nym_format_toolbar';

/// How a tool rewrites the draft.
enum FormatToolKind { wrap, linePrefix, codeBlock }

/// One button in the formatting toolbar.
class FormatTool {
  const FormatTool({
    required this.id,
    required this.kind,
    required this.token,
    required this.label,
    this.exclusive = const [],
    this.glyph,
    this.svg,
  });

  final String id;
  final FormatToolKind kind;

  /// The delimiter (`**`), line prefix (`> `) or fence (```` ``` ````).
  final String token;

  /// Tooltip text (translated at build time).
  final String label;

  /// Sibling prefixes stripped before this one is applied, so H1/H2/H3 replace
  /// one another rather than stacking.
  final List<String> exclusive;

  /// Text glyph for the typographic tools (B / I / S / H1…).
  final String? glyph;

  /// Inline SVG for the pictographic tools.
  final String? svg;
}

const List<String> _headingPrefixes = ['### ', '## ', '# '];

const List<FormatTool> kFormatTools = [
  FormatTool(
      id: 'bold',
      kind: FormatToolKind.wrap,
      token: '**',
      label: 'Bold',
      glyph: 'B'),
  FormatTool(
      id: 'italic',
      kind: FormatToolKind.wrap,
      token: '*',
      label: 'Italic',
      glyph: 'I'),
  FormatTool(
      id: 'strike',
      kind: FormatToolKind.wrap,
      token: '~~',
      label: 'Strikethrough',
      glyph: 'S'),
  FormatTool(
    id: 'code',
    kind: FormatToolKind.wrap,
    token: '`',
    label: 'Inline code',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" '
        'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
        '<polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>',
  ),
  FormatTool(
    id: 'codeblock',
    kind: FormatToolKind.codeBlock,
    token: '```',
    label: 'Code block',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" '
        'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
        '<rect x="3" y="4" width="18" height="16" rx="2"/>'
        '<polyline points="9 15 7 12 9 9"/><polyline points="15 9 17 12 15 15"/></svg>',
  ),
  FormatTool(
    id: 'quote',
    kind: FormatToolKind.linePrefix,
    token: '> ',
    label: 'Quote',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" '
        'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
        '<line x1="4" y1="5" x2="4" y2="19"/><line x1="9" y1="7" x2="20" y2="7"/>'
        '<line x1="9" y1="12" x2="20" y2="12"/><line x1="9" y1="17" x2="16" y2="17"/></svg>',
  ),
  FormatTool(
      id: 'h1',
      kind: FormatToolKind.linePrefix,
      token: '# ',
      exclusive: _headingPrefixes,
      label: 'Heading 1',
      glyph: 'H1'),
  FormatTool(
      id: 'h2',
      kind: FormatToolKind.linePrefix,
      token: '## ',
      exclusive: _headingPrefixes,
      label: 'Heading 2',
      glyph: 'H2'),
  FormatTool(
      id: 'h3',
      kind: FormatToolKind.linePrefix,
      token: '### ',
      exclusive: _headingPrefixes,
      label: 'Heading 3',
      glyph: 'H3'),
];

/// A draft plus a selection — what every transform below takes and returns.
class FormatEdit {
  const FormatEdit(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
}

bool _isSpace(String ch) => ch.trim().isEmpty;

/// The `[start, end)` of the word under [pos], or a zero-width range when the
/// caret sits on whitespace.
FormatEdit _wordRangeAt(String v, int pos) {
  var start = pos, end = pos;
  while (start > 0 && !_isSpace(v[start - 1])) {
    start--;
  }
  while (end < v.length && !_isSpace(v[end])) {
    end++;
  }
  return FormatEdit(v, start, end);
}

/// Toggle `token…token` around the selection (or the word under the caret).
/// Recognises an existing wrap both INSIDE the selection (`**bold**` selected)
/// and just outside it (`bold` selected between the asterisks), so a second
/// press always undoes the first.
FormatEdit applyWrap(FormatEdit input, String token) {
  final v = input.text;
  var s = input.start, e = input.end;
  if (s > e) {
    final t = s;
    s = e;
    e = t;
  }
  s = s.clamp(0, v.length);
  e = e.clamp(0, v.length);
  if (s == e) {
    final w = _wordRangeAt(v, s);
    s = w.start;
    e = w.end;
  }
  // Markdown delimiters must hug the text, so never swallow edge whitespace.
  while (e > s && _isSpace(v[e - 1])) {
    e--;
  }
  while (s < e && _isSpace(v[s])) {
    s++;
  }

  final sel = v.substring(s, e);
  final n = token.length;

  if (sel.length >= 2 * n && sel.startsWith(token) && sel.endsWith(token)) {
    final inner = sel.substring(n, sel.length - n);
    return FormatEdit(
        v.substring(0, s) + inner + v.substring(e), s, s + inner.length);
  }
  if (s >= n &&
      e + n <= v.length &&
      v.substring(s - n, s) == token &&
      v.substring(e, e + n) == token) {
    return FormatEdit(v.substring(0, s - n) + sel + v.substring(e + n), s - n,
        s - n + sel.length);
  }
  return FormatEdit(
    v.substring(0, s) + token + sel + token + v.substring(e),
    s + n,
    s + n + sel.length,
  );
}

/// The full-line span covering the selection, so the line-oriented tools operate
/// on whole lines the way markdown does.
List<int> _lineSpan(String v, int s, int e) {
  final start = v.lastIndexOf('\n', s - 1 < 0 ? 0 : s - 1) + 1;
  var end = v.indexOf('\n', e);
  if (end == -1) end = v.length;
  return [s == 0 ? 0 : start, end];
}

/// Add/remove [prefix] on every line the selection touches. When all touched
/// lines already carry it the press removes it.
FormatEdit applyLinePrefix(FormatEdit input, String prefix,
    {List<String> exclusive = const []}) {
  final v = input.text;
  var s = input.start, e = input.end;
  if (s > e) {
    final t = s;
    s = e;
    e = t;
  }
  s = s.clamp(0, v.length);
  e = e.clamp(0, v.length);
  final span = _lineSpan(v, s, e);
  final lines = v.substring(span[0], span[1]).split('\n');
  final allHave = lines.every((l) => l.startsWith(prefix));
  final out = lines.map((l) {
    if (allHave) return l.substring(prefix.length);
    var base = l;
    for (final p in exclusive) {
      if (base.startsWith(p)) {
        base = base.substring(p.length);
        break;
      }
    }
    return prefix + base;
  }).join('\n');
  return FormatEdit(v.substring(0, span[0]) + out + v.substring(span[1]),
      span[0], span[0] + out.length);
}

/// Fence/unfence the selected lines as a code block. Unfencing drops an opening
/// language tag (```` ```js ````) along with the fences.
FormatEdit applyCodeBlock(FormatEdit input, String fence) {
  final v = input.text;
  var s = input.start, e = input.end;
  if (s > e) {
    final t = s;
    s = e;
    e = t;
  }
  s = s.clamp(0, v.length);
  e = e.clamp(0, v.length);
  final span = _lineSpan(v, s, e);
  final block = v.substring(span[0], span[1]);
  final rx = RegExp('^$fence[^\\n]*\\n?([\\s\\S]*?)\\n?$fence\$');
  final m = rx.firstMatch(block.trim());
  if (m != null) {
    final inner = m.group(1) ?? '';
    return FormatEdit(v.substring(0, span[0]) + inner + v.substring(span[1]),
        span[0], span[0] + inner.length);
  }
  final wrapped = '$fence\n$block\n$fence';
  final innerStart = span[0] + fence.length + 1;
  return FormatEdit(v.substring(0, span[0]) + wrapped + v.substring(span[1]),
      innerStart, innerStart + block.length);
}

/// Run [tool] over [input].
FormatEdit applyFormatTool(FormatEdit input, FormatTool tool) {
  switch (tool.kind) {
    case FormatToolKind.wrap:
      return applyWrap(input, tool.token);
    case FormatToolKind.linePrefix:
      return applyLinePrefix(input, tool.token, exclusive: tool.exclusive);
    case FormatToolKind.codeBlock:
      return applyCodeBlock(input, tool.token);
  }
}

// ---- attachments -----------------------------------------------------------

/// One image/video URL found in the draft.
class ComposerMediaMatch {
  const ComposerMediaMatch(this.url, this.start, this.end, this.isVideo);
  final String url;
  final int start;
  final int end;
  final bool isVideo;
}

/// Kept in sync with the media regexes in `nym_format.dart` (and the PWA's
/// `message-format.js`) so the strip previews exactly the set of attachments
/// recipients will see rendered inline.
final RegExp _mediaRx = RegExp(
  r'(https?://[^\s]+\.(jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(\?[^\s]*)?)',
  caseSensitive: false,
);
const _videoExts = {'mp4', 'webm', 'ogg', 'mov'};

/// Media URLs in [value], for the composer's attachment strip.
///
/// [knownMedia] maps a URL we uploaded this session to whether it is a video.
/// It exists because the regex can only recognise media by file extension, and
/// Blossom is content-addressed: several servers hand back a bare
/// `https://host/<sha256>` with no extension at all. Those are unmistakably
/// media — we just uploaded them — so they are matched by identity instead of
/// by shape. Without this the attachment strip empties the moment an upload
/// completes and the user is left looking at a raw URL.
List<ComposerMediaMatch> composerMediaMatches(String value,
    {Map<String, bool>? knownMedia}) {
  if (value.isEmpty) return const [];
  final out = _mediaRx.allMatches(value).map((m) {
    final ext = (m.group(2) ?? '').toLowerCase();
    return ComposerMediaMatch(
        m.group(1)!, m.start, m.start + m.group(1)!.length, _videoExts.contains(ext));
  }).toList();
  if (knownMedia == null || knownMedia.isEmpty) return out;

  for (final entry in knownMedia.entries) {
    final url = entry.key;
    if (url.isEmpty) continue;
    var i = value.indexOf(url);
    while (i >= 0) {
      final end = i + url.length;
      // A bare URL can be a prefix of an extension-bearing one the regex
      // already claimed; never report the same span twice.
      final overlaps = out.any((m) => i < m.end && end > m.start);
      if (!overlaps) out.add(ComposerMediaMatch(url, i, end, entry.value));
      i = value.indexOf(url, end);
    }
  }
  // Strip order has to follow the draft, and [removeComposerMedia] indexes into
  // this list, so position order is load-bearing rather than cosmetic.
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// Remove the attachment at [index] from [value], swallowing one adjacent space
/// so a removal from the middle doesn't leave a double space behind. Returns the
/// new draft plus the caret offset.
FormatEdit removeComposerMedia(String value, int index,
    {Map<String, bool>? knownMedia}) {
  // Must see the same list the strip rendered, or the ✕ removes the wrong one.
  final matches = composerMediaMatches(value, knownMedia: knownMedia);
  if (index < 0 || index >= matches.length) {
    return FormatEdit(value, value.length, value.length);
  }
  var start = matches[index].start;
  var end = matches[index].end;
  if (end < value.length && value[end] == ' ') {
    end++;
  } else if (start > 0 && value[start - 1] == ' ') {
    start--;
  }
  final out = value.substring(0, start) + value.substring(end);
  return FormatEdit(out, start, start);
}

// ---- widgets ---------------------------------------------------------------

/// `#formatInputBtn` — the toggle that reveals the toolbar, sitting immediately
/// left of the translate button in the composer's inline action row.
class FormatInputButton extends StatefulWidget {
  const FormatInputButton({
    super.key,
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<FormatInputButton> createState() => _FormatInputButtonState();
}

class _FormatInputButtonState extends State<FormatInputButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final lit = widget.active || (_hover && widget.enabled);
    return Opacity(
      opacity: widget.enabled ? (lit ? 1.0 : 0.6) : 0.4,
      child: Tooltip(
        message: tr('Formatting'),
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.enabled ? widget.onTap : null,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: widget.active
                    ? c.primaryA(0.15)
                    : (_hover && widget.enabled
                        ? (c.isLight
                            ? Colors.black.withValues(alpha: 0.06)
                            : Colors.white.withValues(alpha: 0.08))
                        : null),
                borderRadius: BorderRadius.circular(4),
              ),
              // Feather "type" glyph — the same mark as the PWA's toggle.
              child: Icon(Icons.text_fields,
                  size: 17, color: lit ? c.primary : c.textDim),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.format-toolbar` — the row of markdown tools plus the preview toggle.
class FormatToolbar extends StatelessWidget {
  const FormatToolbar({super.key, required this.onTool, this.squareTop = false});

  final void Function(FormatTool tool) onTool;

  /// True while an anchored popup (command palette / autocomplete) is stacked
  /// directly above the toolbar: the touching top corners square off so the
  /// two surfaces read as one, and round back when the popup closes —
  /// animated both ways (PWA `.format-toolbar` border-radius transition).
  final bool squareTop;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Same shell as the autocomplete dropdown (autocomplete_dropdown.dart): it
    // sits in the same slot above the field and should read as the same
    // surface — opaque `--glass-bg` under solid-ui, bg-tertiary in glass mode,
    // rounded across the top only, `--shadow-lg`.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: squareTop ? 0 : 16),
      duration: NymMotion.transition,
      curve: NymMotion.curve,
      builder: (context, topRadius, child) {
        final radius = BorderRadius.vertical(top: Radius.circular(topRadius));
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: c.glassBg.a == 1.0 ? c.glassBg : c.bgTertiary,
            border: Border.all(color: c.glassBorder),
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: c.isLight
                    ? const Color(0x1F000000)
                    : const Color(0x80000000),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: child,
          ),
        );
      },
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final tool in kFormatTools)
              _FormatToolButton(tool: tool, onTap: () => onTool(tool)),
          ],
        ),
      ),
    );
  }
}

class _FormatToolButton extends StatefulWidget {
  const _FormatToolButton({required this.tool, required this.onTap});

  final FormatTool tool;
  final VoidCallback onTap;

  @override
  State<_FormatToolButton> createState() => _FormatToolButtonState();
}

class _FormatToolButtonState extends State<_FormatToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final tool = widget.tool;
    final lit = _hover;
    final color = lit ? c.primary : c.textDim;

    Widget child;
    if (tool.svg != null) {
      child = NymSvgIcon(tool.svg!, size: 15, color: color);
    } else {
      final g = tool.glyph!;
      // H1/H2/H3 render the digit as a subscript, like the PWA's `<sub>`.
      if (g.length == 2 && g.startsWith('H')) {
        child = RichText(
          text: TextSpan(
            style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1),
            children: [
              TextSpan(text: 'H'),
              TextSpan(
                text: g[1],
                style: const TextStyle(fontSize: 8, height: 1),
              ),
            ],
          ),
        );
      } else {
        child = Text(
          g,
          style: TextStyle(
            color: color,
            fontSize: 13,
            height: 1,
            fontWeight: tool.id == 'bold' ? FontWeight.w800 : FontWeight.w600,
            fontStyle:
                tool.id == 'italic' ? FontStyle.italic : FontStyle.normal,
            decoration: tool.id == 'strike'
                ? TextDecoration.lineThrough
                : TextDecoration.none,
            decorationColor: color,
          ),
        );
      }
    }

    return Tooltip(
      message: tr(tool.label),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 28,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover
                  ? (c.isLight
                      ? Colors.black.withValues(alpha: 0.06)
                      : Colors.white.withValues(alpha: 0.08))
                  : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// What an attachment is doing. The tile renders from this, so the wheel is
/// per file rather than one bar for the batch.
enum ComposerAttachmentStatus { uploading, done, failed }

/// One file the user attached, with its own lifecycle.
///
/// This — not the draft text — is what decides which media a message carries.
/// URLs used to be appended to the input as each upload landed and the strip
/// parsed them back out, which is what made a finished upload's preview vanish
/// and put a wall of links in front of the user mid-sentence.
class ComposerAttachment {
  ComposerAttachment({
    required this.id,
    required this.isVideo,
    required this.contentType,
    this.bytes,
    this.status = ComposerAttachmentStatus.uploading,
    this.url = '',
    this.error = '',
  });

  final int id;
  final bool isVideo;
  final String contentType;

  /// Read once and kept, so a failed upload can be retried without re-picking.
  Uint8List? bytes;
  ComposerAttachmentStatus status;
  String url;
  String error;

  bool get isDone => status == ComposerAttachmentStatus.done && url.isNotEmpty;
}

/// `.media-preview-strip` — a horizontal row of attachment thumbnails with a ✕
/// on each. An in-flight upload spins on its own tile; a failed one turns into
/// its own retry button.
class ComposerMediaStrip extends StatelessWidget {
  const ComposerMediaStrip({
    super.key,
    required this.matches,
    required this.attachments,
    required this.onRemove,
    required this.onOpen,
    this.onRemoveAttachment,
    this.onRetry,
    this.localPreviews = const {},
  });

  /// Attachments currently referenced by the draft (a pasted or typed URL).
  final List<ComposerMediaMatch> matches;

  /// Files attached through the picker, in the order they were added.
  final List<ComposerAttachment> attachments;

  final void Function(int index) onRemove;
  final void Function(ComposerMediaMatch match) onOpen;
  final void Function(ComposerAttachment a)? onRemoveAttachment;
  final void Function(ComposerAttachment a)? onRetry;

  /// Hosted URL → the bytes we uploaded, for media attached this session.
  /// Previewing from those bytes avoids re-downloading what we just sent up and
  /// shows a thumbnail even before the Blossom server serves the blob back.
  final Map<String, Uint8List> localPreviews;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        border: Border.all(color: c.glassBorder),
        borderRadius: NymRadius.rmd,
      ),
      child: SizedBox(
        height: 56,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (var i = 0; i < matches.length; i++)
              Padding(
                padding: EdgeInsets.only(
                    right: i == matches.length - 1 && attachments.isEmpty ? 0 : 6),
                child: _MediaThumb(
                  url: matches[i].url,
                  bytes: localPreviews[matches[i].url],
                  isVideo: matches[i].isVideo,
                  onRemove: () => onRemove(i),
                  onOpen: () => onOpen(matches[i]),
                ),
              ),
            for (var i = 0; i < attachments.length; i++)
              Padding(
                padding:
                    EdgeInsets.only(right: i == attachments.length - 1 ? 0 : 6),
                child: _MediaThumb(
                  url: attachments[i].url,
                  bytes: attachments[i].bytes,
                  isVideo: attachments[i].isVideo,
                  status: attachments[i].status,
                  error: attachments[i].error,
                  onRemove: onRemoveAttachment == null
                      ? null
                      : () => onRemoveAttachment!(attachments[i]),
                  onRetry: onRetry == null ? null : () => onRetry!(attachments[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MediaThumb extends StatelessWidget {
  const _MediaThumb({
    required this.url,
    required this.bytes,
    required this.isVideo,
    this.onRemove,
    this.onOpen,
    this.onRetry,
    this.status = ComposerAttachmentStatus.done,
    this.error = '',
  });

  final String url;
  final Uint8List? bytes;
  final bool isVideo;
  final VoidCallback? onRemove;
  final VoidCallback? onOpen;
  final VoidCallback? onRetry;
  final ComposerAttachmentStatus status;
  final String error;

  bool get _uploading => status == ComposerAttachmentStatus.uploading;
  bool get _failed => status == ComposerAttachmentStatus.failed;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final local = bytes;
    Widget media;
    if (isVideo) {
      // No frame to show for a video that hasn't been uploaded yet — the local
      // bytes aren't addressable by [VideoPlayerController] without writing them
      // to disk, which isn't worth it for a 56px tile.
      media = url.isEmpty
          ? Container(
              color: Colors.black.withValues(alpha: 0.45),
              alignment: Alignment.center,
              child: Icon(Icons.play_arrow_rounded,
                  size: 20, color: Colors.white.withValues(alpha: 0.9)),
            )
          : _VideoThumb(url: url);
    } else if (local != null && local.isNotEmpty) {
      media = Image.memory(
        local,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _broken(c),
      );
    } else {
      media = Image.network(
        proxiedMedia(url),
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _broken(c),
      );
    }

    final tile = GestureDetector(
      // A failed tile IS the retry control, so one file failing never costs the
      // user the rest of the batch.
      onTap: _uploading ? null : (_failed ? onRetry : onOpen),
      child: MouseRegion(
        cursor: _uploading ? MouseCursor.defer : SystemMouseCursors.click,
        child: SizedBox(
          width: 56,
          height: 56,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(color: Colors.black.withValues(alpha: 0.25)),
                Opacity(opacity: _uploading || _failed ? 0.4 : 1.0, child: media),
                if (_uploading)
                  const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (_failed)
                  Center(
                    child: Icon(Icons.refresh_rounded,
                        size: 20, color: c.danger),
                  ),
                if (_failed)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: c.danger, width: 1.5),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ),
                if (!_uploading && onRemove != null)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: onRemove,
                      child: Tooltip(
                        message: tr('Remove attachment'),
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close,
                              size: 11, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // The reason rides on the tile, not in a toast naming a file already off
    // screen.
    if (!_failed) return tile;
    return Tooltip(
      message: error.isEmpty
          ? tr('Tap to retry')
          : '$error — ${tr('Tap to retry')}',
      child: tile,
    );
  }

  Widget _broken(NymColors c) => Container(
        color: c.bgTertiary,
        alignment: Alignment.center,
        child: Icon(Icons.broken_image_outlined, size: 18, color: c.textDim),
      );
}

/// First-frame poster for a video attachment. [video_player] is already a
/// dependency (inline video messages), so the frame comes from the same engine
/// rather than pulling in a thumbnail plugin.
class _VideoThumb extends StatefulWidget {
  const _VideoThumb({required this.url});
  final String url;

  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _VideoThumb old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _controller?.dispose();
      _controller = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final controller =
          VideoPlayerController.networkUrl(Uri.parse(proxiedMedia(widget.url)));
      await controller.initialize();
      // Park on the first frame; never autoplay a composer thumbnail.
      await controller.seekTo(Duration.zero);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _controller != null && _controller!.value.isInitialized;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (ready)
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _controller!.value.size.width,
              height: _controller!.value.size.height,
              child: VideoPlayer(_controller!),
            ),
          )
        else
          Container(color: Colors.black.withValues(alpha: 0.45)),
        Center(
          child: Icon(
            _failed ? Icons.videocam_off_outlined : Icons.play_arrow_rounded,
            size: 20,
            color: Colors.white.withValues(alpha: 0.9),
          ),
        ),
      ],
    );
  }
}

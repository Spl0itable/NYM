// Composer formatting toolbar and attachment previews; the sent draft stays plain markdown.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/i18n/i18n.dart';
import '../../features/messages/format/message_content.dart' show proxiedMedia;
import '../../features/messages/inline_network_image.dart'
    show InlineNetworkImage;
import '../nym_icons.dart' show NymSvgIcon;

enum FormatToolKind { wrap, linePrefix, codeBlock, picker }

class FormatTool {
  const FormatTool({
    required this.id,
    required this.kind,
    required this.token,
    required this.label,
    this.exclusive = const [],
    this.glyph,
    this.svg,
    this.shortcut,
  });

  final String id;
  final FormatToolKind kind;

  final String token;

  final String label;

  /// Sibling prefixes stripped first, so H1/H2/H3 replace one another rather than stacking.
  final List<String> exclusive;

  final String? glyph;

  final String? svg;

  final String? shortcut;
}

const List<String> _headingPrefixes = ['### ', '## ', '# '];

const List<FormatTool> kFormatTools = [
  FormatTool(
      id: 'bold',
      kind: FormatToolKind.wrap,
      token: '**',
      label: 'Bold',
      glyph: 'B',
      shortcut: 'b'),
  FormatTool(
      id: 'italic',
      kind: FormatToolKind.wrap,
      token: '*',
      label: 'Italic',
      glyph: 'I',
      shortcut: 'i'),
  FormatTool(
      id: 'underline',
      kind: FormatToolKind.wrap,
      token: '__',
      label: 'Underline',
      glyph: 'U',
      shortcut: 'u'),
  FormatTool(
      id: 'strike',
      kind: FormatToolKind.wrap,
      token: '~~',
      label: 'Strikethrough',
      glyph: 'S'),
  FormatTool(
    id: 'spoiler',
    kind: FormatToolKind.wrap,
    token: '||',
    label: 'Spoiler',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" '
        'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
        '<path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/>'
        '<path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/>'
        '<path d="M14.12 14.12a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg>',
  ),
  FormatTool(
    id: 'code',
    kind: FormatToolKind.wrap,
    token: '`',
    label: 'Inline code',
    shortcut: 'e',
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
      id: 'subtext',
      kind: FormatToolKind.linePrefix,
      token: '-# ',
      label: 'Subtext',
      glyph: '-#'),
  FormatTool(
    id: 'timestamp',
    kind: FormatToolKind.picker,
    token: '',
    label: 'Timestamp',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" '
        'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
        '<circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 15 14"/></svg>',
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

class FormatEdit {
  const FormatEdit(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
}

bool _isSpace(String ch) => ch.trim().isEmpty;

/// Zero-width range when the caret sits on whitespace.
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

/// Toggles `token…token` around the selection or caret word, recognizing a wrap inside or just outside it.
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

List<int> _lineSpan(String v, int s, int e) {
  final start = v.lastIndexOf('\n', s - 1 < 0 ? 0 : s - 1) + 1;
  var end = v.indexOf('\n', e);
  if (end == -1) end = v.length;
  return [s == 0 ? 0 : start, end];
}

/// When every touched line already carries [prefix], the press removes it.
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

/// Unfencing also drops an opening language tag.
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

FormatEdit applyFormatTool(FormatEdit input, FormatTool tool) {
  switch (tool.kind) {
    case FormatToolKind.wrap:
      return applyWrap(input, tool.token);
    case FormatToolKind.linePrefix:
      return applyLinePrefix(input, tool.token, exclusive: tool.exclusive);
    case FormatToolKind.codeBlock:
      return applyCodeBlock(input, tool.token);
    case FormatToolKind.picker:
      return input;
  }
}

FormatTool? formatToolForShortcut(String key, {required bool shift}) {
  final k = key.toLowerCase();
  if (shift) {
    return k == 'x' ? kFormatTools.firstWhere((t) => t.id == 'strike') : null;
  }
  for (final tool in kFormatTools) {
    if (tool.shortcut == k) return tool;
  }
  return null;
}

FormatEdit insertTimestampTag(FormatEdit input, int seconds) {
  final v = input.text;
  var s = input.start, e = input.end;
  if (s < 0 || e < 0) {
    s = v.length;
    e = v.length;
  }
  if (s > e) {
    final t = s;
    s = e;
    e = t;
  }
  s = s.clamp(0, v.length);
  e = e.clamp(s, v.length);
  final tag = '<t:$seconds:f>';
  final caret = s + tag.length;
  return FormatEdit(v.substring(0, s) + tag + v.substring(e), caret, caret);
}

class ComposerMediaMatch {
  const ComposerMediaMatch(this.url, this.start, this.end, this.isVideo);
  final String url;
  final int start;
  final int end;
  final bool isVideo;
}

/// Kept in sync with the media regexes in `nym_format.dart` so previews match what recipients see.
final RegExp _mediaRx = RegExp(
  r'(https?://[^\s]+\.(jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(\?[^\s]*)?)',
  caseSensitive: false,
);
const _videoExts = {'mp4', 'webm', 'ogg', 'mov'};

/// [knownMedia] matches this session's uploads by identity, since Blossom URLs may lack a file extension.
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
      // A bare URL can prefix an extension-bearing one already claimed; never report a span twice.
      final overlaps = out.any((m) => i < m.end && end > m.start);
      if (!overlaps) out.add(ComposerMediaMatch(url, i, end, entry.value));
      i = value.indexOf(url, end);
    }
  }
  // [removeComposerMedia] indexes into this list, so position order is load-bearing.
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// Swallows one adjacent space so a mid-draft removal leaves no double space.
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

class FormatToolbarIconButton extends StatefulWidget {
  const FormatToolbarIconButton({
    super.key,
    required this.svg,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
    this.active = false,
  });

  final String svg;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;
  final bool active;

  @override
  State<FormatToolbarIconButton> createState() =>
      _FormatToolbarIconButtonState();
}

class _FormatToolbarIconButtonState extends State<FormatToolbarIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final lit = widget.enabled && (widget.active || _hover);
    final base = lit ? c.primary : c.textDim;
    final color = widget.enabled ? base : base.withValues(alpha: base.a * 0.4);
    return Tooltip(
      message: tr(widget.tooltip),
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        expanded: widget.active,
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
              width: 28,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hover && widget.enabled
                    ? (c.isLight
                        ? Colors.black.withValues(alpha: 0.06)
                        : Colors.white.withValues(alpha: 0.08))
                    : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: NymSvgIcon(widget.svg, size: 16, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class FormatToolbar extends StatelessWidget {
  const FormatToolbar({
    super.key,
    required this.onTool,
    this.squareTop = false,
    this.leading = const [],
  });

  final void Function(FormatTool tool) onTool;

  final List<Widget> leading;

  /// True while a popup is stacked directly above, squaring the touching top corners.
  final bool squareTop;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
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
            ...leading,
            if (leading.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Container(
                  key: const ValueKey('formatToolSep'),
                  width: 1,
                  height: 18,
                  color: c.glassBorder,
                ),
              ),
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
                : (tool.id == 'underline'
                    ? TextDecoration.underline
                    : TextDecoration.none),
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

enum ComposerAttachmentStatus { uploading, done, failed }

/// One attached file with its own lifecycle; this, not the draft text, decides which media a message carries.
class ComposerAttachment {
  ComposerAttachment({
    required this.id,
    required this.isVideo,
    required this.contentType,
    this.bytes,
    this.status = ComposerAttachmentStatus.uploading,
    this.url = '',
    this.error = '',
    this.label = '',
    this.hosted = false,
  });

  final int id;
  final String label;
  final bool hosted;
  final bool isVideo;
  final String contentType;

  /// Kept so a failed upload can be retried without re-picking.
  Uint8List? bytes;
  ComposerAttachmentStatus status;
  String url;
  String error;
  Uint8List? compressed;
  bool compressionTried = false;
  int? originalSize;
  int? compressedSize;
  ComposerUploadVariant? uploadedAs;

  bool get isDone => status == ComposerAttachmentStatus.done && url.isNotEmpty;
}

class ComposerUploadVariant {
  const ComposerUploadVariant({
    required this.hd,
    required this.once,
    this.onceId = '',
    this.key = '',
    this.nonce = '',
    this.mime = '',
    this.size = 0,
  });

  final bool hd;
  final bool once;
  final String onceId;
  final String key;
  final String nonce;
  final String mime;
  final int size;
}

/// Attachment thumbnails; an uploading tile spins and a failed tile is its own retry button.
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
    this.squareTop = false,
  });

  final List<ComposerMediaMatch> matches;

  final List<ComposerAttachment> attachments;

  final void Function(int index) onRemove;
  final void Function(ComposerMediaMatch match) onOpen;
  final void Function(ComposerAttachment a)? onRemoveAttachment;
  final void Function(ComposerAttachment a)? onRetry;

  /// Uploaded bytes by hosted URL, so previews show before the Blossom server serves the blob.
  final Map<String, Uint8List> localPreviews;

  final bool squareTop;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: squareTop ? 0 : 16),
      duration: NymMotion.transition,
      curve: NymMotion.curve,
      builder: (context, topRadius, child) => Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: c.bgTertiary,
          border: Border.all(color: c.glassBorder),
          borderRadius: BorderRadius.vertical(top: Radius.circular(topRadius)),
        ),
        child: child,
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
                  label: attachments[i].label,
                  gif: attachments[i].hosted &&
                      attachments[i].contentType == 'image/gif',
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
    this.label = '',
    this.gif = false,
  });

  final String label;
  final bool gif;
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
      // A not-yet-uploaded video's local bytes aren't addressable by [VideoPlayerController] without a temp file.
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
        // Decode a full-resolution pick at the chip size instead.
        cacheWidth:
            (56 * MediaQuery.devicePixelRatioOf(context) * 1.5).ceil(),
        errorBuilder: (_, _, _) => _broken(c),
      );
    } else {
      final proxied = proxiedMedia(url);
      media = Image.network(
        proxied,
        headers: InlineNetworkImage.imageHeadersFor(proxied),
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        cacheWidth:
            (56 * MediaQuery.devicePixelRatioOf(context) * 1.5).ceil(),
        errorBuilder: (_, _, _) => gif ? _gifPlaceholder(c) : _broken(c),
      );
    }

    if (label.isNotEmpty) {
      media = Semantics(label: label, image: true, child: media);
    }

    final tile = GestureDetector(
      // A failed tile is the retry control, so one failure never costs the rest of the batch.
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

  Widget _gifPlaceholder(NymColors c) => Container(
        color: c.bgTertiary,
        alignment: Alignment.center,
        child: Text(
          tr('GIF'),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: c.textDim,
          ),
        ),
      );
}

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

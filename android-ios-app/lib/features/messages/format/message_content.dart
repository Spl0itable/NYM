// Renders the structured output of [NymFormat.format] as Flutter widgets,
// mirroring the PWA's visual treatment (docs/specs/03 §9): markdown spans,
// code/quote/heading blocks, channel/mention chips, emoji, and media galleries.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../services/api/api_client.dart';
import '../../../state/app_state.dart';
import '../../../state/settings_provider.dart';
import 'link_preview.dart';
import 'nym_format.dart';

/// Shared stateless [ApiClient] for media/emoji proxy URL construction. The
/// builders are pure (no network), so a single instance is fine.
final _proxyApi = ApiClient();

/// Routes a remote media [url] through the backend media proxy
/// (`/api/proxy?url=…`, mirroring the PWA's `proxied`/`getProxiedMediaUrl`),
/// while passing through anything that must NOT be proxied:
///   - empty / relative (no scheme or non-http(s)) URLs,
///   - `data:` and `blob:` URLs,
///   - URLs that are already pointed at the proxy.
/// Set [emoji] for custom-emoji images (long edge-cache TTL, `&emoji=1`).
String proxiedMedia(String url, {bool emoji = false}) {
  if (url.isEmpty) return url;
  final lower = url.toLowerCase();
  if (lower.startsWith('data:') || lower.startsWith('blob:')) return url;
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) return url;
  // Already proxied (e.g. nym_format pre-proxied via proxyBase) — leave as-is.
  if (url.contains('/api/proxy?')) return url;
  return _proxyApi.mediaProxyUrl(url, emoji: emoji);
}

/// Renders a raw message [content] string using [NymFormat].
///
/// Reads `settingsProvider`, `currentViewProvider`, and `nymColorsProvider` to
/// build a [FormatContext] and to style spans with `context.nym` tokens and the
/// user's text size.
class MessageContent extends ConsumerWidget {
  const MessageContent({
    super.key,
    required this.content,
    this.baseColor,
    this.fontSize,
  });

  final String content;

  /// Body text color (defaults to `context.nym.text`).
  final Color? baseColor;

  /// Base font size (defaults to settings.textSize).
  final double? fontSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final view = ref.watch(currentViewProvider);
    final c = ref.watch(nymColorsProvider);

    final ctx = FormatContext(
      currentChannel:
          view.kind == ViewKind.channel ? view.id.toLowerCase() : null,
      currentGeohash:
          view.kind == ViewKind.channel ? view.id.toLowerCase() : null,
      customEmojis: const {},
    );

    final blocks = NymFormat.format(content, ctx);
    final size = fontSize ?? settings.textSize.toDouble();
    final color = baseColor ?? c.text;

    // Collect bare http(s) links to unfurl below the body (ui-context.js
    // `_attachLinkPreviews`), skipping inline-media URLs (already embedded).
    final previewUrls = _collectPreviewUrls(blocks);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          _block(context, c, blocks[i], color, size),
        ],
        for (final url in previewUrls) LinkPreviewCard(url: url),
      ],
    );
  }

  /// Walks the formatted [blocks] collecting bare http(s) [LinkNode] URLs for
  /// link-preview cards (de-duplicated, inline-media URLs skipped — those render
  /// as images/videos, mirroring ui-context.js:815).
  List<String> _collectPreviewUrls(List<FormatBlock> blocks) {
    final seen = <String>{};
    final out = <String>[];
    void visitInlines(List<InlineNode> inlines) {
      for (final n in inlines) {
        switch (n) {
          case LinkNode(:final url):
            if (isInlineMediaUrl(url)) break;
            if (seen.add(url)) out.add(url);
          case BoldNode(:final children):
            visitInlines(children);
          case ItalicNode(:final children):
            visitInlines(children);
          case StrikeNode(:final children):
            visitInlines(children);
          default:
            break;
        }
      }
    }

    void visitBlock(FormatBlock b) {
      switch (b) {
        case ParagraphBlock(:final inlines):
          visitInlines(inlines);
        case HeadingBlock(:final inlines):
          visitInlines(inlines);
        case QuoteBlock(:final children):
          for (final ch in children) {
            visitBlock(ch);
          }
        case CodeBlock():
        case MediaBlock():
          break;
      }
    }

    for (final b in blocks) {
      visitBlock(b);
    }
    return out;
  }

  Widget _block(
    BuildContext context,
    NymColors c,
    FormatBlock block,
    Color color,
    double size,
  ) {
    switch (block) {
      case ParagraphBlock(:final inlines):
        return _RichInline(inlines: inlines, color: color, size: size);
      case HeadingBlock(:final level, :final inlines):
        final scale = level == 1 ? 1.5 : (level == 2 ? 1.3 : 1.15);
        return _RichInline(
          inlines: inlines,
          color: c.textBright,
          size: size * scale,
          weight: FontWeight.w700,
        );
      case CodeBlock(:final code, :final lang):
        return _CodeBox(code: code, lang: lang, size: size);
      case QuoteBlock():
        return _QuoteBox(block: block, color: color, size: size);
      case MediaBlock(:final items):
        return _MediaGallery(items: items);
    }
  }
}

/// Renders a list of inline nodes as a single [Text.rich] (with [WidgetSpan]s
/// for chips, emoji images, and mentions).
class _RichInline extends StatelessWidget {
  const _RichInline({
    required this.inlines,
    required this.color,
    required this.size,
    this.weight,
  });

  final List<InlineNode> inlines;
  final Color color;
  final double size;
  final FontWeight? weight;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final base = TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      height: 1.4,
    );
    return Text.rich(
      TextSpan(
        children: [
          for (final n in inlines) _span(context, c, n, base),
        ],
      ),
    );
  }

  InlineSpan _span(
    BuildContext context,
    NymColors c,
    InlineNode node,
    TextStyle base,
  ) {
    switch (node) {
      case TextSpanNode(:final text):
        return TextSpan(text: text, style: base);
      case BoldNode(:final children):
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch, base.merge(const TextStyle(fontWeight: FontWeight.w700))),
        ]);
      case ItalicNode(:final children):
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch, base.merge(const TextStyle(fontStyle: FontStyle.italic))),
        ]);
      case StrikeNode(:final children):
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch,
                base.merge(const TextStyle(decoration: TextDecoration.lineThrough))),
        ]);
      case InlineCodeNode(:final code):
        return TextSpan(
          text: code,
          style: base.merge(TextStyle(
            fontFamily: 'monospace',
            color: c.textBright,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
          )),
        );
      case LinkNode(:final url):
        return TextSpan(
          text: url,
          style: base.merge(TextStyle(
            color: c.secondary,
            decoration: TextDecoration.underline,
          )),
          recognizer: _LinkTap(url),
        );
      case EmojiNode(:final unicode):
        return TextSpan(text: unicode, style: base.merge(TextStyle(fontSize: size * 1.25)));
      case MentionNode():
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _MentionChip(node: node, size: size),
        );
      case ChannelRefNode():
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _ChannelChip(node: node, size: size),
        );
      case CustomEmojiNode(:final url, :final shortcode):
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: CachedNetworkImage(
              imageUrl: proxiedMedia(url, emoji: true),
              width: 22,
              height: 22,
              fit: BoxFit.contain,
              errorWidget: (_, __, ___) =>
                  Text(':$shortcode:', style: base),
            ),
          ),
        );
      case ChannelLinkChip(:final ref, :final label):
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _LinkChip(label: label, ref: ref, size: size),
        );
      case GroupInviteChip(:final name):
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _InviteChip(name: name, size: size),
        );
      default:
        // _MediaInline is flattened to blocks and never reaches here.
        return const TextSpan(text: '');
    }
  }
}

/// A tap recognizer that opens a URL via url_launcher.
class _LinkTap extends TapGestureRecognizer {
  _LinkTap(String url) {
    onTap = () {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    };
  }
}

class _MentionChip extends StatelessWidget {
  const _MentionChip({required this.node, required this.size});
  final MentionNode node;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: node.base,
            style: TextStyle(
              color: c.primary,
              fontSize: size,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (node.suffix != null)
            TextSpan(
              text: '#${node.suffix}',
              style: TextStyle(
                color: c.primaryA(0.6),
                fontSize: size * 0.92,
              ),
            ),
        ],
      ),
    );
  }
}

class _ChannelChip extends StatelessWidget {
  const _ChannelChip({required this.node, required this.size});
  final ChannelRefNode node;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final fg = node.isGeohash ? c.warning : c.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: node.isActive ? fg.withValues(alpha: 0.18) : null,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
      ),
      child: Text(
        '#${node.name}',
        style: TextStyle(
          color: fg,
          fontSize: size,
          fontWeight: FontWeight.w500,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.label, required this.ref, required this.size});
  final String label;
  final String ref;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.secondaryA(0.12),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        border: Border.all(color: c.secondaryA(0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(color: c.secondary, fontSize: size * 0.92),
      ),
    );
  }
}

class _InviteChip extends StatelessWidget {
  const _InviteChip({required this.name, required this.size});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.secondaryA(0.12),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        border: Border.all(color: c.secondaryA(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.group, size: size, color: c.secondary),
          const SizedBox(width: 4),
          Text(
            'Join $name',
            style: TextStyle(color: c.secondary, fontSize: size * 0.92),
          ),
        ],
      ),
    );
  }
}

/// Monospace code box with an optional language label and a copy affordance.
class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.code, required this.lang, required this.size});
  final String code;
  final String? lang;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (lang != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 0, 0),
                  child: Text(
                    lang!,
                    style: TextStyle(color: c.textDim, fontSize: 11),
                  ),
                ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
                tooltip: 'Copy',
                color: c.textDim,
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: code)),
                icon: const Icon(Icons.copy),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                code,
                style: TextStyle(
                  color: c.textBright,
                  fontSize: size - 1,
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Left-bordered quote block, with an optional author header.
class _QuoteBox extends StatelessWidget {
  const _QuoteBox({required this.block, required this.color, required this.size});
  final QuoteBlock block;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: c.secondaryA(0.05),
        border: Border(left: BorderSide(color: c.secondaryA(0.6), width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (block.author != null)
            Text(
              '${block.author}:',
              style: TextStyle(
                color: c.secondary,
                fontSize: size - 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          for (final child in block.children)
            _quoteChild(context, c, child),
        ],
      ),
    );
  }

  Widget _quoteChild(BuildContext context, NymColors c, FormatBlock child) {
    final dim = c.textDim;
    switch (child) {
      case ParagraphBlock(:final inlines):
        return _RichInline(inlines: inlines, color: dim, size: size - 1);
      case HeadingBlock(:final inlines):
        return _RichInline(
            inlines: inlines, color: dim, size: size, weight: FontWeight.w700);
      case CodeBlock(:final code, :final lang):
        return _CodeBox(code: code, lang: lang, size: size - 1);
      case QuoteBlock():
        return _QuoteBox(block: child, color: dim, size: size);
      case MediaBlock(:final items):
        return _MediaGallery(items: items);
    }
  }
}

/// A 1/2/3/4-up media grid. Images are tappable (expand placeholder); videos
/// render as a play tile (no playback yet).
class _MediaGallery extends StatelessWidget {
  const _MediaGallery({required this.items});
  final List<MediaItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.length == 1) {
      return _MediaTile(item: items.first, maxSize: 300);
    }
    final cols = items.length == 2 ? 2 : (items.length == 3 ? 3 : 4);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: GridView.count(
        crossAxisCount: cols,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        children: [
          for (final item in items) _MediaTile(item: item, maxSize: 150),
        ],
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({required this.item, required this.maxSize});
  final MediaItem item;
  final double maxSize;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final radius = const BorderRadius.all(Radius.circular(8));

    if (item.isVideo) {
      return ClipRRect(
        borderRadius: radius,
        child: Container(
          constraints:
              BoxConstraints(maxWidth: maxSize, maxHeight: maxSize, minHeight: 80),
          color: Colors.black.withValues(alpha: 0.4),
          alignment: Alignment.center,
          child: Icon(Icons.play_circle_fill, size: 48, color: c.text),
        ),
      );
    }

    return GestureDetector(
      onTap: () {}, // expand placeholder
      child: ClipRRect(
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxSize, maxHeight: maxSize),
          child: CachedNetworkImage(
            imageUrl: proxiedMedia(item.url),
            fit: BoxFit.cover,
            placeholder: (_, __) => Container(
              width: maxSize,
              height: maxSize,
              color: Colors.white.withValues(alpha: 0.05),
            ),
            errorWidget: (_, __, ___) => Container(
              width: maxSize,
              height: 80,
              color: Colors.white.withValues(alpha: 0.05),
              alignment: Alignment.center,
              child: Icon(Icons.broken_image, color: c.textDim),
            ),
          ),
        ),
      ),
    );
  }
}

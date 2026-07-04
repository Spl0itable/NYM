// Renders the structured output of [NymFormat.format] as Flutter widgets,
// mirroring the PWA's visual treatment (docs/specs/03 §9): markdown spans,
// code/quote/heading blocks, channel/mention chips, emoji, and media galleries.

import 'dart:async' show Timer;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../core/theme/nym_metrics.dart';
import '../../../core/theme/nym_theme.dart'
    show kEmojiFontFallback, kSansFont, kMonoFont;
import '../../../core/utils/nym_utils.dart';
import '../../../models/message.dart';
import '../../../services/api/api_client.dart';
import '../../../services/platform/deep_links.dart';
import '../../../state/app_state.dart';
import '../../../state/nostr_controller.dart';
import '../../../state/settings_provider.dart';
import '../../../widgets/chat/messages_list.dart' show messageListScrollerProvider;
import '../../../widgets/common/app_dialog.dart';
import '../../../widgets/common/nym_avatar.dart';
import '../../../widgets/context_menu/context_menu_actions.dart';
import '../../../widgets/context_menu/context_menu_panel.dart';
import '../../commands/command_handler.dart' show resolveTarget;
import '../inline_network_image.dart';
import '../media_fallbacks.dart';
import 'link_preview.dart';
import 'nym_format.dart';
import 'video_message.dart';

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
    this.hostMessageId,
    this.baseColor,
    this.fontSize,
    this.blurImages = false,
    this.glyphShadows,
    this.monospace = false,
    this.enrichMentionAvatars = false,
  });

  final String content;

  /// The id of the message this content belongs to. Lets a tapped blockquote
  /// EXCLUDE its own host message when searching for the quoted source (mirrors
  /// the PWA `hostKey` guard in `_scrollToQuotedMessage`, messages.js:2690). Null
  /// for surfaces without a backing message (e.g. the `/me` action preview).
  final String? hostMessageId;

  /// Body text color (defaults to `context.nym.text`).
  final Color? baseColor;

  /// Base font size (defaults to settings.textSize).
  final double? fontSize;

  /// Blur inline/gallery images behind a tap-to-reveal (others' images privacy).
  final bool blurImages;

  /// Glyph [Shadow]s carried by the body text — the per-style `text-shadow`
  /// glow (neon/matrix/fire/…) or the glitch chromatic split. (`F11`/`F12`.)
  final List<Shadow>? glyphShadows;

  /// Render the body in a monospace family (the CRT style). (`F13`.)
  final bool monospace;

  /// Render a leading inline avatar on each `@mention` chip, resolved from
  /// `usersProvider`. Mirrors the PWA's `_enrichActionMentions`
  /// (messages.js:1369-1403), which decorates the mentions INSIDE a `/me`
  /// action with the mentioned user's avatar. Off everywhere else (a plain
  /// mention chip carries no avatar). (`F01-7`.)
  final bool enrichMentionAvatars;

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
      // Live NIP-30 custom emoji (kind-30030 packs + 10030 list + inbound
      // `emoji` tags) so `:shortcode:` renders as the custom image in messages,
      // not literal text. Mirrors the PWA's `customEmojis` map.
      customEmojis: ref.watch(liveCustomEmojiProvider).codeToUrl,
    );

    final blocks = NymFormat.format(content, ctx);
    final size = fontSize ?? settings.textSize.toDouble();
    final color = baseColor ?? c.text;

    // Emoji-only messages (1-6 emoji, no other text) render enlarged
    // (`.emoji-only .emoji { font-size: 2.5em }`, `messages.js:922-924`) — for
    // both unicode emoji and custom-emoji-only shortcode messages.
    final emojiOnly =
        isEmojiOnly(content) || isCustomEmojiOnly(content, ctx.customEmojis);

    // Collect bare http(s) links to unfurl below the body (ui-context.js
    // `_attachLinkPreviews`), skipping inline-media URLs (already embedded).
    final previewUrls = _collectPreviewUrls(blocks);

    // Tapping a `#ref` / `app.nym.bar/#…` link switches the active channel
    // (`channelLink` / `channelReference` data-actions).
    void onChannelRef(String name, bool isGeohash) {
      final controller = ref.read(nostrControllerProvider);
      if (isGeohash) {
        controller.switchChannel(name, geohash: name);
      } else {
        controller.switchChannel(name);
      }
    }

    // Tapping a `.nm-mention` chip opens the mentioned user's context menu
    // (styles-chat.css:1308 `.nm-mention { cursor:pointer }`; ui-context.js:859-
    // 870). The PWA resolves the mention to a pubkey (`_resolveMentionPubkey`)
    // then calls `showContextMenu(e, nym#suffix, pubkey, null, null, false)` —
    // the FULL menu with null content/messageId (NOT profile-only). We resolve
    // the chip's base nym + optional `#suffix` via [resolveTarget] (the same
    // matcher cmdSlap/cmdHug use) and build the matching [CtxTarget].
    void onMentionTap(MentionNode node) {
      final users = ref.read(usersProvider);
      // `node.base` already carries the leading `@`; re-attach the `#suffix` so
      // a suffixed mention disambiguates to the right pubkey.
      final raw = node.suffix != null ? '${node.base}#${node.suffix}' : node.base;
      final t = resolveTarget(raw, users);
      if (t == null) return; // unknown mention → inert (PWA: no pubkey → no-op)
      final app = ref.read(appStateProvider);
      ContextMenuPanel.show(
        context,
        // Mirrors `showContextMenu(e, nym#suffix, pubkey, null, null, false)`:
        // a full (non-profileOnly) target with no message content/id, so the
        // action list reduces to Mention/PM/Slap/Hug/AddToGroup/GiftCredits/
        // Friend/Report/Block (buildContextMenuActions with hasContent=false).
        target: CtxTarget(
          pubkey: t.pubkey,
          nym: stripPubkeySuffix(t.nym),
          isSelf: t.pubkey == app.selfPubkey,
        ),
      );
    }

    // Read-more height truncation (messages.js:1192-1265 + styles-chat.css:793-
    // 822). Long bodies collapse to a 300px `.truncated-inner` (200px on the
    // ≤768px breakpoint, styles-themes-responsive.css:42-46) with a "Read
    // more"/"Show less" toggle. The char threshold (400 mobile ≤768 / 600
    // desktop) only FLAGS a candidate; the collapse itself is height-based, so
    // `_Collapsible` drops the toggle when the rendered body already fits.
    // The PWA measures `replyText` = the content with `>`-prefixed quote lines
    // removed (blockquotes get their own separate truncation; primary path here
    // is the reply body).
    final replyText = content
        .split('\n')
        .where((line) => !line.startsWith('>'))
        .join('\n')
        .trim();
    final threshold = truncateThreshold(context);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The CSS `margin: 10px 0` renders even when the block is the FIRST/
        // LAST child of `.message-content` (no collapse through the padded
        // bubble), so a leading/trailing media/code/quote/heading block keeps
        // 10px of air against the content edges — e.g. an image-only message
        // has 10px above and below the image inside the bubble.
        if (blocks.isNotEmpty && _blockEdgeMargin(blocks.first) > 0)
          SizedBox(height: _blockEdgeMargin(blocks.first)),
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) SizedBox(height: _blockGap(blocks[i - 1], blocks[i])),
          _block(context, c, blocks[i], color, size,
              emojiOnly: emojiOnly,
              onChannelRef: onChannelRef,
              onMentionTap: onMentionTap),
        ],
        if (blocks.isNotEmpty && _blockEdgeMargin(blocks.last) > 0)
          SizedBox(height: _blockEdgeMargin(blocks.last)),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Link-preview cards (`_attachLinkPreviews`) are appended OUTSIDE the
        // `.truncated-inner` in the PWA, so they stay below the collapsible body.
        if (replyText.length > threshold) _Collapsible(child: body) else body,
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
    double size, {
    bool emojiOnly = false,
    void Function(String name, bool isGeohash)? onChannelRef,
    void Function(MentionNode node)? onMentionTap,
  }) {
    switch (block) {
      case ParagraphBlock(:final inlines):
        return _RichInline(
          inlines: inlines,
          color: color,
          size: size,
          emojiOnly: emojiOnly,
          shadows: glyphShadows,
          monospace: monospace,
          enrichMentionAvatars: enrichMentionAvatars,
          onChannelRef: onChannelRef,
          onMentionTap: onMentionTap,
        );
      case HeadingBlock(:final level, :final inlines):
        final scale = level == 1 ? 1.5 : (level == 2 ? 1.3 : 1.15);
        // `h1,h2,h3 { color: var(--primary) }` (styles-chat.css:1312-1317).
        return _RichInline(
          inlines: inlines,
          color: c.primary,
          size: size * scale,
          weight: FontWeight.w700,
          enrichMentionAvatars: enrichMentionAvatars,
          onChannelRef: onChannelRef,
          onMentionTap: onMentionTap,
        );
      case CodeBlock(:final code, :final lang):
        return _CodeBox(code: code, lang: lang, size: size);
      case QuoteBlock():
        // Top-level blockquote (PWA `:scope > blockquote`) — eligible for its
        // own read-more truncation, and tappable to jump to the quoted source.
        return _QuoteBox(
          block: block,
          color: color,
          size: size,
          topLevel: true,
          hostMessageId: hostMessageId,
        );
      case MediaBlock(:final items):
        return _MediaGallery(items: items, blur: blurImages);
    }
  }
}

/// The PWA vertical margin a block carries: media, code, quote and heading
/// blocks all have `margin: 10px 0` (`.message-content img` styles-chat.css:
/// 941-950, `.video-container` :980-985, `.message-gallery` :987-994, `pre`
/// :1094-1099, `blockquote` :1270-1279, `h1,h2,h3` :1312-1317); plain text
/// lines keep the 4px line gap.
double _blockMargin(FormatBlock block) => switch (block) {
      MediaBlock() || CodeBlock() || QuoteBlock() || HeadingBlock() => 10,
      ParagraphBlock() => 4,
    };

/// Vertical gap between two adjacent blocks. CSS sibling margins collapse to
/// the LARGER of the two, so any pair involving a media/code/quote block sits
/// 10px apart while text-text pairs keep the 4px line gap.
double _blockGap(FormatBlock a, FormatBlock b) {
  final ma = _blockMargin(a);
  final mb = _blockMargin(b);
  return ma > mb ? ma : mb;
}

/// The margin a block renders against the START/END edge of the message body.
/// Only blocks with a real CSS `margin: 10px 0` (media/code/quote/heading)
/// carry it; a paragraph's 4px is a line gap between siblings, not a margin,
/// so text sits flush at the edges exactly like the PWA.
double _blockEdgeMargin(FormatBlock block) => switch (block) {
      MediaBlock() || CodeBlock() || QuoteBlock() || HeadingBlock() => 10,
      ParagraphBlock() => 0,
    };

/// One emoji "unit" (the PWA's `_EMOJI_UNIT`, `messages.js:8`): a flag pair, a
/// keycap, or a presentation/pictographic glyph with optional VS / skin-tone /
/// ZWJ sequences and tags.
const String _emojiUnit =
    r'(?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]\u{FE0F}?\u{20E3})|'
    r'(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
    r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?'
    r'(?:\u{200D}(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
    r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?)*)'
    r'(?:[\u{E0020}-\u{E007E}]+\u{E007F})?';

final RegExp _rxEmojiOnly = RegExp('^(?:$_emojiUnit){1,6}\$', unicode: true);
final RegExp _rxWhitespace = RegExp(r'\s', unicode: true);

/// True when [content] is 1-6 emoji with optional whitespace and no other text
/// (port of `isEmojiOnly`, `messages.js:1424-1430`).
bool isEmojiOnly(String content) {
  if (content.isEmpty) return false;
  final stripped = content.replaceAll(_rxWhitespace, '');
  if (stripped.isEmpty) return false;
  return _rxEmojiOnly.hasMatch(stripped);
}

final RegExp _rxCustomEmojiToken = RegExp(r'^:([a-zA-Z0-9_]+):$');

/// True when [content] is 1-6 whitespace-separated custom-emoji shortcodes,
/// every one a known [customEmojis] code (port of `isCustomEmojiOnly`,
/// emoji.js:331). Drives the same `.emoji-only` 2.75em enlarge as a
/// unicode-emoji-only message.
bool isCustomEmojiOnly(String content, Map<String, String> customEmojis) {
  if (content.isEmpty || customEmojis.isEmpty) return false;
  final tokens = content.trim().split(RegExp(r'\s+'));
  if (tokens.isEmpty || tokens.length > 6) return false;
  for (final tok in tokens) {
    final m = _rxCustomEmojiToken.firstMatch(tok);
    if (m == null || !customEmojis.containsKey(m.group(1))) return false;
  }
  return true;
}

/// Renders a list of inline nodes as a single [Text.rich] (with [WidgetSpan]s
/// for chips, emoji images, and mentions).
class _RichInline extends StatelessWidget {
  const _RichInline({
    required this.inlines,
    required this.color,
    required this.size,
    this.weight,
    this.emojiOnly = false,
    this.shadows,
    this.monospace = false,
    this.enrichMentionAvatars = false,
    this.onChannelRef,
    this.onMentionTap,
  });

  final List<InlineNode> inlines;
  final Color color;
  final double size;
  final FontWeight? weight;

  /// Whole message is 1-6 emoji → enlarge emoji glyphs/images.
  final bool emojiOnly;

  /// Per-style glyph shadows (glow / glitch chromatic split).
  final List<Shadow>? shadows;

  /// Render glyphs in a monospace family (CRT).
  final bool monospace;

  /// Render a leading inline avatar on each mention chip (`/me` action
  /// enrichment, `_enrichActionMentions`). Off elsewhere. (`F01-7`.)
  final bool enrichMentionAvatars;

  /// Switches the active channel when a `#ref` / `app.nym.bar/#…` link is tapped.
  final void Function(String name, bool isGeohash)? onChannelRef;

  /// Opens the mentioned user's context menu when a `.nm-mention` chip is tapped.
  final void Function(MentionNode node)? onMentionTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final base = TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      height: 1.4,
      shadows: shadows,
      // Bundled [kSansFont] primary drives the (correct) line strut; the
      // emoji/symbol [kEmojiFontFallback] resolves emoji + enclosed letters in
      // body text per-glyph without touching Latin metrics. Mono bodies (CRT
      // style) keep the monospace family and skip the fallback.
      fontFamily: monospace ? kMonoFont : kSansFont,
      fontFamilyFallback: monospace ? null : kEmojiFontFallback,
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
        // `strong { color: var(--text-bright); font-weight:bold }`
        // (styles-chat.css:1074-1077).
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch,
                base.merge(TextStyle(fontWeight: FontWeight.w700, color: c.textBright))),
        ]);
      case ItalicNode(:final children):
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch, base.merge(const TextStyle(fontStyle: FontStyle.italic))),
        ]);
      case StrikeNode(:final children):
        // `del { text-decoration:line-through; color: var(--text-dim) }`
        // (styles-chat.css:1325-1328).
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch,
                base.merge(TextStyle(
                    decoration: TextDecoration.lineThrough, color: c.textDim))),
        ]);
      case InlineCodeNode(:final code):
        // `code { background: rgba(255,255,255,0.06); padding:2px 6px;
        //  border-radius:5px; font-family:mono; color: var(--secondary);
        //  font-size:0.9em }` (styles-chat.css:1084-1092) — a rounded inline
        //  pill, so a WidgetSpan carries the padding + radius the CSS needs.
        //  Light mode flips the fill to `rgba(0,0,0,0.06)` (`body.light-mode
        //  .message-content code`, styles-themes-responsive.css:632-634).
        //  The family is `--font-mono` (styles-core.css:81) — the app-wide
        //  [kMonoFont] stack, same as the CRT style and the fenced-code box.
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: c.isLight
                  ? Colors.black.withValues(alpha: 0.06)
                  : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              code,
              style: base.merge(TextStyle(
                fontFamily: kMonoFont,
                color: c.secondary,
                fontSize: size * 0.9,
                shadows: const [],
              )),
            ),
          ),
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
        // `.emoji` has no font-size (inherits 1em); only `.emoji-only .emoji` is
        // 2.5em (styles-chat.css:824-837). The emoji/symbol fallback already
        // rides on [base], so the glyph resolves to Noto Color Emoji here.
        return TextSpan(
          text: unicode,
          style: base.merge(TextStyle(fontSize: size * (emojiOnly ? 2.5 : 1.0))),
        );
      case MentionNode():
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _MentionChip(
            node: node,
            size: size,
            onTap: onMentionTap,
            withAvatar: enrichMentionAvatars,
          ),
        );
      case ChannelRefNode(:final name, :final isGeohash):
        // `.channel-reference`: underlined, inherits BODY text color (no tint),
        // no background/box, no active-state fill (styles-chat.css:933-939).
        // Hover→primary is desktop-only and omitted on touch.
        return TextSpan(
          text: '#$name',
          style: base.merge(const TextStyle(decoration: TextDecoration.underline)),
          recognizer: onChannelRef == null
              ? null
              : _ChannelRefTap(name, isGeohash, onChannelRef!),
        );
      case CustomEmojiNode(:final url, :final shortcode):
        // `.custom-emoji { width/height: 1.75em }`; emoji-only `2.75em`
        // (styles-chat.css:839-852). The HTML `width=30` attr is overridden by
        // the CSS, so inline is `1.75em` (≈26px at 15), not 22px.
        final side = emojiOnly ? size * 2.75 : size * 1.75;
        // Many NIP-30 custom emoji are SVG (and some hosts serve formats the
        // raster decoder can't handle); InlineNetworkImage renders SVG via
        // flutter_svg and otherwise falls back to the `:shortcode:` text so a
        // broken/undecodable emoji never throws. (BUG: custom emoji + decode.)
        final image = InlineNetworkImage(
          url: proxiedMedia(url, emoji: true),
          width: side,
          height: side,
          fit: BoxFit.contain,
          // Disk-cached (CachedNetworkImage): body emoji are sparse — only a
          // few per visible message — so they don't storm the cache DB, and
          // the disk cache lets them persist across restarts. (The high-volume
          // emoji PICKER grid uses memoryOnly to avoid the lock storm.)
          retryOnError: true,
          errorChild: Text(':$shortcode:', style: base),
        );
        // `.custom-emoji { vertical-align: -0.375em }` (styles-chat.css:843):
        // baseline-aligned with the image bottom 0.375em below the alphabetic
        // baseline. `.emoji-only .custom-emoji` overrides to `vertical-align:
        // middle` (:848-852).
        return WidgetSpan(
          alignment: emojiOnly
              ? PlaceholderAlignment.middle
              : PlaceholderAlignment.baseline,
          baseline: emojiOnly ? null : TextBaseline.alphabetic,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: emojiOnly
                ? image
                : EmojiBaselineDrop(drop: size * 0.375, child: image),
          ),
        );
      case ChannelLinkChip(:final ref, :final label):
        // `.channel-link`: plain underlined secondary text (full URL label),
        // no background/border/padding (styles-chat.css:895-903). Hover→primary
        // is desktop-only.
        return TextSpan(
          text: label,
          style: base.merge(TextStyle(
            color: c.secondary,
            decoration: TextDecoration.underline,
          )),
          recognizer:
              onChannelRef == null ? null : _ChannelLinkTap(ref, onChannelRef!),
        );
      case GroupInviteChip(:final name, :final token):
        // The chip renders to spec; tapping to JOIN needs the group-invite
        // decode that lives in NostrController (cross-file) — left inert here.
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _InviteChip(name: name, token: token, size: size),
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

class _MentionChip extends ConsumerWidget {
  const _MentionChip({
    required this.node,
    required this.size,
    this.onTap,
    this.withAvatar = false,
  });
  final MentionNode node;
  final double size;

  /// Tapping the chip opens the mentioned user's context menu
  /// (`.nm-mention { cursor:pointer }`, ui-context.js:859-870). Null → inert.
  final void Function(MentionNode node)? onTap;

  /// Prepend the mentioned user's inline avatar (the `.action-mention` form the
  /// PWA produces inside a `/me` action, `_enrichActionMentions`). When the
  /// mention can't be resolved to a known user the avatar is dropped and the
  /// chip renders plain — exactly like the PWA keeps the plain rendering.
  final bool withAvatar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    // `.nm-mention { color: var(--secondary) }` (no-inline.css:198) — the chip
    // inherits the body weight (NO bold), in both themes.
    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: node.base,
            style: TextStyle(
              color: c.secondary,
              fontSize: size,
            ),
          ),
          if (node.suffix != null)
            // `.nym-suffix`: opacity 0.7, 0.9em, weight 100 (styles-chat.css:
            // 706-710; inherits the mention's secondary).
            TextSpan(
              text: '#${node.suffix}',
              style: TextStyle(
                color: c.secondaryA(0.7),
                fontSize: size * 0.9,
                fontWeight: FontWeight.w100,
              ),
            ),
        ],
      ),
    );

    Widget chip = text;
    if (withAvatar) {
      // Resolve the mention to a known user (same matcher the tap path uses) and
      // pull its kind-0 avatar; NymAvatar falls back to the identicon when the
      // profile carries no picture. Mirrors `getAvatarUrl(pubkey)` in
      // `_enrichActionMentions` (messages.js:1395).
      final users = ref.watch(usersProvider);
      final raw =
          node.suffix != null ? '${node.base}#${node.suffix}' : node.base;
      final t = resolveTarget(raw, users);
      if (t != null) {
        final pic = users[t.pubkey]?.profile?.picture;
        chip = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // `.avatar-message` inline avatar — sized to the mention text.
            NymAvatar(seed: t.pubkey, size: size, imageUrl: pic),
            const SizedBox(width: 3),
            text,
          ],
        );
      }
    }

    if (onTap == null) return chip;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap!(node),
      child: chip,
    );
  }
}

/// Taps a `#channel` reference → switch to that channel (geohash or named).
class _ChannelRefTap extends TapGestureRecognizer {
  _ChannelRefTap(
      String name, bool isGeohash, void Function(String name, bool isGeohash) cb) {
    onTap = () => cb(name, isGeohash);
  }
}

/// Taps an `app.nym.bar/#…` channel link → switch to the referenced channel.
/// [ref] is `g:<geohash>` or `c:<name>` (the PWA `data-channel-ref`).
class _ChannelLinkTap extends TapGestureRecognizer {
  _ChannelLinkTap(String ref, void Function(String name, bool isGeohash) cb) {
    onTap = () {
      final colon = ref.indexOf(':');
      final prefix = colon > 0 ? ref.substring(0, colon) : '';
      final id = colon > 0 ? ref.substring(colon + 1) : ref;
      cb(id, prefix == 'g');
    };
  }
}

/// `.group-invite-chip` (`styles-chat.css:905-919`): a no-fill pill with a
/// solid 1px `--secondary` border, radius 12, padding `2px 8px`, a 1em stroked
/// group glyph, and secondary text at body size. Tapping confirms, then sends a
/// `group-join-request` to the link's sharer (groups.js `requestJoinGroupViaInvite`).
class _InviteChip extends ConsumerWidget {
  const _InviteChip(
      {required this.name, required this.token, required this.size});
  final String name;
  final String token;
  final double size;

  /// Decode the token, confirm, then hand off to the controller's joiner-side
  /// flow (mirrors the PWA's `Join "<name>"?` confirm before `_sendGiftWraps`).
  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final parsed = parseGroupInvite(token);
    if (parsed == null) return;
    final controller = ref.read(nostrControllerProvider);
    final ok = await showAppConfirm(
      context,
      'Join "$name"? A join request will be sent to a group member.',
      title: 'Join Group',
      okLabel: 'Join',
    );
    if (!ok) return;
    await controller.joinGroupViaInvite(parsed);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    return GestureDetector(
      onTap: () => _join(context, ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          // No background fill; solid full-opacity secondary 1px border, r12.
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          border: Border.all(color: c.secondary),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // `.inline-group-ico` ≈ 1em multi-person outline.
            SizedBox(
              width: size,
              height: size,
              child: CustomPaint(painter: _GroupIcoPainter(c.secondary)),
            ),
            SizedBox(width: size * 0.35),
            Text(
              'Join $name',
              style: TextStyle(color: c.secondary, fontSize: size),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small multi-person ("group") outline glyph, ≈ the PWA `inlineGroupSvg`.
class _GroupIcoPainter extends CustomPainter {
  _GroupIcoPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Authored in a 24×24 box; scale to [size].
    final s = size.width / 24.0;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    // Front person: head + shoulders.
    canvas.drawCircle(Offset(9 * s, 8 * s), 3.2 * s, stroke);
    final body = Path()
      ..moveTo(3.5 * s, 19 * s)
      ..cubicTo(3.5 * s, 14.5 * s, 6 * s, 13 * s, 9 * s, 13 * s)
      ..cubicTo(12 * s, 13 * s, 14.5 * s, 14.5 * s, 14.5 * s, 19 * s);
    canvas.drawPath(body, stroke);
    // Back person: partial head + shoulder behind/right.
    final back = Path()
      ..moveTo(15.5 * s, 5.2 * s)
      ..cubicTo(17.4 * s, 5.6 * s, 18.6 * s, 7.2 * s, 18.3 * s, 9.1 * s)
      ..cubicTo(18.1 * s, 10.3 * s, 17.3 * s, 11.2 * s, 16.3 * s, 11.7 * s);
    canvas.drawPath(back, stroke);
    final backBody = Path()
      ..moveTo(17 * s, 13.2 * s)
      ..cubicTo(19 * s, 13.6 * s, 20.5 * s, 15.3 * s, 20.5 * s, 19 * s);
    canvas.drawPath(backBody, stroke);
  }

  @override
  bool shouldRepaint(covariant _GroupIcoPainter old) => old.color != color;
}

// ===========================================================================
// Syntax highlighting — a 1:1 port of the PWA `NymHighlight`
// (js/modules/syntax-highlight.js): a tiny built-in tokenizer for fenced code
// blocks. Produces a flat list of `(text, class)` runs that `_CodeBox` paints
// with the VS-Code-ish token colors from styles-chat.css:1158-1170
// (`.hl-comment` #6a9955 italic, `.hl-string` #ce9178, `.hl-number` #b5cea8,
// `.hl-keyword` #569cd6 600, `.hl-builtin` #4ec9b0, `.hl-function` #dcdcaa,
// `.hl-key` #9cdcfe). When the language is unknown the highlighter returns a
// single `none` run, so the body is plain monospace exactly as before.
// ===========================================================================

/// Token classes emitted by [_highlightCode], mirroring the PWA's `hl-*` spans.
enum _HlClass { none, comment, string, number, keyword, builtin, function, key }

/// One highlighted run: a slice of source [text] with its token [cls].
class _HlTok {
  const _HlTok(this.text, this.cls);
  final String text;
  final _HlClass cls;
}

/// Per-language keyword sets (`syntax-highlight.js` `KW`). `ts` extends `js`;
/// `jsx`/`tsx` alias `js`/`ts`.
const Map<String, List<String>> _kHlKeywords = {
  'js': [
    'async','await','break','case','catch','class','const','continue','debugger','default','delete','do','else','export','extends','finally','for','from','function','if','import','in','instanceof','let','new','null','of','return','static','super','switch','this','throw','true','false','try','typeof','undefined','var','void','while','with','yield',
  ],
  'py': [
    'False','None','True','and','as','assert','async','await','break','class','continue','def','del','elif','else','except','finally','for','from','global','if','import','in','is','lambda','nonlocal','not','or','pass','raise','return','try','while','with','yield','match','case',
  ],
  'rs': [
    'as','async','await','break','const','continue','crate','dyn','else','enum','extern','false','fn','for','if','impl','in','let','loop','match','mod','move','mut','pub','ref','return','self','Self','static','struct','super','trait','true','type','unsafe','use','where','while','yield','box',
  ],
  'go': [
    'break','case','chan','const','continue','default','defer','else','fallthrough','for','func','go','goto','if','import','interface','map','package','range','return','select','struct','switch','type','var','true','false','nil','iota',
  ],
  'java': [
    'abstract','assert','boolean','break','byte','case','catch','char','class','const','continue','default','do','double','else','enum','extends','final','finally','float','for','goto','if','implements','import','instanceof','int','interface','long','native','new','null','package','private','protected','public','return','short','static','strictfp','super','switch','synchronized','this','throw','throws','transient','try','void','volatile','while','true','false',
  ],
  'c': [
    'auto','break','case','char','const','continue','default','do','double','else','enum','extern','float','for','goto','if','inline','int','long','register','restrict','return','short','signed','sizeof','static','struct','switch','typedef','union','unsigned','void','volatile','while','_Bool','_Complex','_Imaginary','bool','true','false','NULL','nullptr',
  ],
  'cpp': [
    'alignas','alignof','and','asm','auto','bool','break','case','catch','char','class','co_await','co_return','co_yield','const','constexpr','const_cast','continue','decltype','default','delete','do','double','dynamic_cast','else','enum','explicit','export','extern','false','final','float','for','friend','goto','if','inline','int','long','mutable','namespace','new','noexcept','not','nullptr','operator','or','override','private','protected','public','register','reinterpret_cast','return','short','signed','sizeof','static','static_cast','struct','switch','template','this','thread_local','throw','true','try','typedef','typeid','typename','union','unsigned','using','virtual','void','volatile','while','xor',
  ],
  'sh': [
    'if','then','else','elif','fi','for','in','do','done','while','until','case','esac','function','return','break','continue','exit','export','local','readonly','set','unset','source','alias','declare','typeset','true','false',
  ],
  'sql': [
    'SELECT','FROM','WHERE','INSERT','UPDATE','DELETE','CREATE','DROP','ALTER','TABLE','INDEX','VIEW','JOIN','LEFT','RIGHT','INNER','OUTER','FULL','ON','AS','AND','OR','NOT','NULL','IS','IN','LIKE','BETWEEN','GROUP','BY','ORDER','HAVING','LIMIT','OFFSET','UNION','ALL','DISTINCT','INTO','VALUES','SET','PRIMARY','KEY','FOREIGN','REFERENCES','DEFAULT','UNIQUE','CHECK','CASE','WHEN','THEN','ELSE','END','WITH','RETURNING','BEGIN','COMMIT','ROLLBACK','TRANSACTION','IF','EXISTS','TRUE','FALSE',
  ],
  'ts': [
    // KW.js ++ the TS-only additions (`syntax-highlight.js:16`).
    'async','await','break','case','catch','class','const','continue','debugger','default','delete','do','else','export','extends','finally','for','from','function','if','import','in','instanceof','let','new','null','of','return','static','super','switch','this','throw','true','false','try','typeof','undefined','var','void','while','with','yield',
    'any','as','boolean','declare','enum','interface','is','keyof','module','namespace','never','number','readonly','satisfies','string','symbol','type','unique','unknown','infer','public','private','protected','abstract','implements',
  ],
};

/// Per-language builtin/identifier sets (`syntax-highlight.js` `BUILTINS`).
const Map<String, List<String>> _kHlBuiltins = {
  'js': [
    'console','window','document','globalThis','Math','JSON','Object','Array','String','Number','Boolean','Date','Map','Set','Promise','RegExp','Symbol','BigInt','Error','fetch','setTimeout','setInterval','clearTimeout','clearInterval','queueMicrotask','structuredClone',
  ],
  'py': [
    'print','len','range','int','str','float','bool','list','dict','tuple','set','frozenset','bytes','bytearray','open','input','type','isinstance','enumerate','zip','map','filter','sorted','sum','min','max','abs','round','any','all','self','cls','__init__','__name__','super',
  ],
  'rs': [
    'Vec','String','Option','Result','Box','Rc','Arc','HashMap','HashSet','BTreeMap','Some','None','Ok','Err','println','print','format','vec','assert','assert_eq','assert_ne','panic','dbg','todo','unimplemented','unreachable','i8','i16','i32','i64','i128','u8','u16','u32','u64','u128','f32','f64','bool','char','str','isize','usize',
  ],
  'go': [
    'append','cap','close','copy','delete','len','make','new','panic','print','println','recover','complex','imag','real','string','int','int8','int16','int32','int64','uint','uint8','uint16','uint32','uint64','uintptr','byte','rune','float32','float64','bool','error',
  ],
  'ts': [
    'console','window','document','globalThis','Math','JSON','Object','Array','String','Number','Boolean','Date','Map','Set','Promise','RegExp','Symbol','BigInt','Error','fetch','Partial','Readonly','Record','Pick','Omit','Required','Exclude','Extract','ReturnType','Parameters',
  ],
  'sh': [
    'echo','cat','grep','sed','awk','cd','ls','rm','cp','mv','mkdir','rmdir','touch','chmod','chown','find','xargs','curl','wget','tar','gzip','gunzip','zip','unzip','ps','kill','top','df','du','wc','sort','uniq','head','tail','tr','tee','printf','read','test','sleep','date','env','which',
  ],
  'c': [
    'printf','scanf','fprintf','sprintf','snprintf','malloc','calloc','realloc','free','memcpy','memset','memcmp','strlen','strcpy','strncpy','strcmp','strncmp','strcat','strncat','strchr','strstr','fopen','fclose','fread','fwrite','fgets','fputs','exit','abort','assert','sizeof','NULL','stdin','stdout','stderr','std','cout','cin','cerr','endl','vector','string','map','unordered_map','set','unordered_set','pair','make_pair','shared_ptr','unique_ptr',
  ],
};

/// Language aliases (`syntax-highlight.js` `LANG_ALIAS`).
const Map<String, String> _kHlLangAlias = {
  'javascript': 'js', 'node': 'js', 'nodejs': 'js',
  'typescript': 'ts',
  'python': 'py', 'python3': 'py',
  'rust': 'rs',
  'golang': 'go',
  'bash': 'sh', 'shell': 'sh', 'zsh': 'sh', 'sh': 'sh',
  'c++': 'cpp', 'cxx': 'cpp',
  'objective-c': 'c', 'objc': 'c',
  'html': 'xml', 'svg': 'xml', 'xhtml': 'xml',
  'yml': 'yaml',
};

/// `normalizeLang` (`syntax-highlight.js:173-182`): resolve a fenced-code lang
/// hint to a canonical lexer key, or null when there's no highlighter for it.
String? _normalizeHlLang(String? lang) {
  if (lang == null) return null;
  final l = lang.toLowerCase().trim();
  if (_kHlLangAlias.containsKey(l)) return _kHlLangAlias[l];
  if (_kHlKeywords.containsKey(l) || _kHlBuiltins.containsKey(l)) return l;
  if (l == 'json' || l == 'jsonc') return 'json';
  if (l == 'xml' || l == 'html') return 'xml';
  if (l == 'css' || l == 'scss' || l == 'less') return 'css';
  return null;
}

/// `highlight` (`syntax-highlight.js:184-191`): tokenize [code] for [lang]. A
/// null/unknown lang yields a single `none` run (plain monospace).
List<_HlTok> _highlightCode(String code, String? lang) {
  final l = _normalizeHlLang(lang);
  if (l == null) return [_HlTok(code, _HlClass.none)];
  if (l == 'json') return _highlightJsonLike(code);
  if (l == 'xml') return _highlightXml(code);
  if (l == 'css') return _highlightCss(code);
  return _highlightGeneric(code, l);
}

final RegExp _rxHlNum = RegExp(r'^-?\d');

/// `highlightJsonLike` (`syntax-highlight.js:52-68`).
List<_HlTok> _highlightJsonLike(String src) {
  final out = <_HlTok>[];
  final re = RegExp(
      r'"(?:\\.|[^"\\])*"|true|false|null|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[{}\[\],:]|\s+|[^\s{}\[\],:"]+');
  for (final m in re.allMatches(src)) {
    final t = m[0]!;
    if (t.startsWith('"')) {
      // A string immediately followed by `:` is an object KEY (.hl-key).
      final after = src.substring(m.end);
      final isKey = RegExp(r'^\s*:').hasMatch(after);
      out.add(_HlTok(t, isKey ? _HlClass.key : _HlClass.string));
    } else if (t == 'true' || t == 'false' || t == 'null') {
      out.add(_HlTok(t, _HlClass.keyword));
    } else if (_rxHlNum.hasMatch(t)) {
      out.add(_HlTok(t, _HlClass.number));
    } else {
      out.add(_HlTok(t, _HlClass.none));
    }
  }
  return out;
}

/// `highlightXml` (`syntax-highlight.js:70-84`).
List<_HlTok> _highlightXml(String src) {
  final out = <_HlTok>[];
  final re = RegExp(
      '''<!--[\\s\\S]*?-->|</?[A-Za-z][\\w:-]*|/?>|"[^"]*"|'[^']*'|[A-Za-z_:][\\w:.-]*=|[^<"'>]+''');
  for (final m in re.allMatches(src)) {
    final t = m[0]!;
    if (t.startsWith('<!--')) {
      out.add(_HlTok(t, _HlClass.comment));
    } else if (RegExp(r'^<\/?[A-Za-z]').hasMatch(t)) {
      out.add(_HlTok(t, _HlClass.keyword));
    } else if (t == '>' || t == '/>') {
      out.add(_HlTok(t, _HlClass.keyword));
    } else if (t.startsWith('"') || t.startsWith("'")) {
      out.add(_HlTok(t, _HlClass.string));
    } else if (t.endsWith('=')) {
      out.add(_HlTok(t, _HlClass.builtin));
    } else {
      out.add(_HlTok(t, _HlClass.none));
    }
  }
  return out;
}

/// `highlightCss` (`syntax-highlight.js:86-101`).
List<_HlTok> _highlightCss(String src) {
  final out = <_HlTok>[];
  final re = RegExp(
      r'''/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|--[\w-]+|@[\w-]+|#[0-9a-fA-F]{3,8}\b|-?\d+(?:\.\d+)?(?:px|em|rem|vh|vw|%|s|ms|deg|fr)?|[\w-]+\s*(?=:)|[{}();:,]|[\w-]+|\s+|.''');
  for (final m in re.allMatches(src)) {
    final t = m[0]!;
    if (t.startsWith('/*')) {
      out.add(_HlTok(t, _HlClass.comment));
    } else if (t.startsWith('"') || t.startsWith("'")) {
      out.add(_HlTok(t, _HlClass.string));
    } else if (t.startsWith('@') || t.startsWith('--')) {
      out.add(_HlTok(t, _HlClass.keyword));
    } else if (RegExp(r'^#[0-9a-fA-F]{3,8}$').hasMatch(t)) {
      out.add(_HlTok(t, _HlClass.number));
    } else if (_rxHlNum.hasMatch(t)) {
      out.add(_HlTok(t, _HlClass.number));
    } else if (RegExp(r'\w').hasMatch(t) &&
        RegExp(r':\s*$')
            .hasMatch(src.substring(m.start, (m.start + t.length + 4).clamp(0, src.length)))) {
      // A property name (`name:`). The PWA trims the trailing run then re-emits
      // it; we keep the slice whole, tagging it builtin (a property token).
      out.add(_HlTok(t, _HlClass.builtin));
    } else {
      out.add(_HlTok(t, _HlClass.none));
    }
  }
  return out;
}

final RegExp _rxHlIdent = RegExp(r'[A-Za-z_$][\w$]*');
final RegExp _rxHlIdentStart = RegExp(r'[A-Za-z_$]');
final RegExp _rxHlNumber = RegExp(
    r'(?:0x[0-9a-fA-F_]+|0b[01_]+|0o[0-7_]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)[fFuUlLnN]*');
final RegExp _rxHlCall = RegExp(r'^\s*\(');

/// `highlightGeneric` (`syntax-highlight.js:103-171`): the main char-walk lexer
/// (comments, strings, numbers, identifiers → keyword/builtin/function).
List<_HlTok> _highlightGeneric(String src, String lang) {
  final kws = (_kHlKeywords[lang] ?? const <String>[]).toSet();
  final builtins = (_kHlBuiltins[lang] ?? const <String>[]).toSet();
  final isShell = lang == 'sh';
  final lineComment = (lang == 'py' || lang == 'sh' || lang == 'yaml' || lang == 'rb')
      ? RegExp(r'^#.*')
      : RegExp(r'^\/\/.*');
  final RegExp? blockComment = (lang == 'py') ? null : RegExp(r'^\/\*[\s\S]*?\*\/');
  final RegExp? pyDocstring =
      (lang == 'py') ? RegExp(r'''^("""[\s\S]*?"""|\x27\x27\x27[\s\S]*?\x27\x27\x27)''') : null;

  final out = <_HlTok>[];
  var i = 0;
  final n = src.length;

  while (i < n) {
    final rest = src.substring(i);

    if (pyDocstring != null) {
      final m = pyDocstring.matchAsPrefix(rest);
      if (m != null) {
        out.add(_HlTok(m[0]!, _HlClass.comment));
        i += m[0]!.length;
        continue;
      }
    }
    if (blockComment != null) {
      final m = blockComment.matchAsPrefix(rest);
      if (m != null) {
        out.add(_HlTok(m[0]!, _HlClass.comment));
        i += m[0]!.length;
        continue;
      }
    }
    final lc = lineComment.matchAsPrefix(rest);
    if (lc != null) {
      out.add(_HlTok(lc[0]!, _HlClass.comment));
      i += lc[0]!.length;
      continue;
    }

    final ch = src[i];
    if (ch == '"' || ch == "'" || ch == '`') {
      var j = i + 1;
      while (j < n) {
        if (src[j] == '\\') {
          j += 2;
          continue;
        }
        if (src[j] == ch) {
          j++;
          break;
        }
        if (src[j] == '\n' && ch != '`') break;
        j++;
      }
      out.add(_HlTok(src.substring(i, j.clamp(0, n)), _HlClass.string));
      i = j > n ? n : j;
      continue;
    }

    final numMatch = _rxHlNumber.matchAsPrefix(rest);
    if (numMatch != null && (i == 0 || !_rxHlIdentStart.hasMatch(src[i - 1]))) {
      out.add(_HlTok(numMatch[0]!, _HlClass.number));
      i += numMatch[0]!.length;
      continue;
    }

    final idMatch = _rxHlIdent.matchAsPrefix(rest);
    if (idMatch != null) {
      final id = idMatch[0]!;
      if (kws.contains(id)) {
        out.add(_HlTok(id, _HlClass.keyword));
      } else if (builtins.contains(id)) {
        out.add(_HlTok(id, _HlClass.builtin));
      } else {
        final after = _rxHlCall.matchAsPrefix(src.substring(i + id.length));
        if (after != null && !isShell) {
          out.add(_HlTok(id, _HlClass.function));
        } else if (isShell && i == 0) {
          out.add(_HlTok(id, _HlClass.function));
        } else {
          out.add(_HlTok(id, _HlClass.none));
        }
      }
      i += id.length;
      continue;
    }

    out.add(_HlTok(ch, _HlClass.none));
    i++;
  }
  return out;
}

/// Maps an [_HlClass] to its VS-Code-ish token color (styles-chat.css:1158-1170).
/// `none` falls back to the box's base bright text color.
Color _hlColor(_HlClass cls, Color base) {
  switch (cls) {
    case _HlClass.comment:
      return const Color(0xFF6A9955);
    case _HlClass.string:
      return const Color(0xFFCE9178);
    case _HlClass.number:
      return const Color(0xFFB5CEA8);
    case _HlClass.keyword:
      return const Color(0xFF569CD6);
    case _HlClass.builtin:
      return const Color(0xFF4EC9B0);
    case _HlClass.function:
      return const Color(0xFFDCDCAA);
    case _HlClass.key:
      return const Color(0xFF9CDCFE);
    case _HlClass.none:
      return base;
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
    // Tokenize for syntax coloring (NymHighlight). An unknown/absent language
    // yields a single `none` run, so the body is plain bright monospace exactly
    // as before — only recognized languages get the VS-Code token colors.
    // `pre code { font-size: inherit }` (styles-chat.css:1107-1112): code
    // glyphs render at the full base size, not 0.9em/size-1. The family is
    // `--font-mono` (styles-chat.css:1104 + styles-core.css:81) — the same
    // [kMonoFont] stack every other mono surface (CRT style) uses.
    final base = TextStyle(
      color: c.textBright,
      fontSize: size,
      fontFamily: kMonoFont,
      height: 1.4,
    );
    final tokens = _highlightCode(code, lang);
    final codeSpan = TextSpan(
      children: [
        for (final tok in tokens)
          TextSpan(
            text: tok.text,
            style: base.copyWith(
              color: _hlColor(tok.cls, c.textBright),
              // `.hl-comment { font-style: italic }`; `.hl-keyword { font-weight:600 }`.
              fontStyle:
                  tok.cls == _HlClass.comment ? FontStyle.italic : FontStyle.normal,
              fontWeight:
                  tok.cls == _HlClass.keyword ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
      ],
    );
    // `.code-block-wrapper { position:relative; padding-top:22px }`
    // (styles-chat.css:1141-1143) hosts the lang label / Copy pill in a 22px
    // strip ABOVE the `pre` box; the `pre` itself carries the fill
    // (white@0.04 dark / black@0.04 light, styles-chat.css:1094-1095 +
    // styles-themes-responsive.css:636-638), the 1px glass border, radius
    // `--radius-sm` (=12) and its own `padding: 12px` — so code text starts
    // 22+12px from the wrapper top and is inset 12px on the other sides.
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 22),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.insetFill,
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.glassBorder),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text.rich(codeSpan),
            ),
          ),
        ),
        // `.code-lang-label`: top:4 left:8, 0.7em, UPPERCASE, `text@0.55`,
        // letter-spacing 0.05em (styles-chat.css:1145-1156).
        if (lang != null && lang!.isNotEmpty)
          Positioned(
            top: 4,
            left: 8,
            child: Text(
              lang!.toUpperCase(),
              style: TextStyle(
                color: c.text.withValues(alpha: 0.55),
                fontSize: size * 0.7,
                letterSpacing: size * 0.7 * 0.05,
              ),
            ),
          ),
        // `.code-copy-btn`: top:6 right:6, primary@0.15 bg / primary@0.3
        // border / radius-xs(8), "Copy" text 0.75em in `--primary`.
        Positioned(
          top: 6,
          right: 6,
          child: _CodeCopyButton(code: code, size: size),
        ),
      ],
    );
  }
}

/// The `.code-copy-btn` pill. Tapping writes [code] to the clipboard and flips
/// the label to "Copied!" for 1500ms before reverting to "Copy"
/// (`codeBlockCopy`, inline-bindings.js:456-466).
class _CodeCopyButton extends StatefulWidget {
  const _CodeCopyButton({required this.code, required this.size});
  final String code;
  final double size;

  @override
  State<_CodeCopyButton> createState() => _CodeCopyButtonState();
}

class _CodeCopyButtonState extends State<_CodeCopyButton> {
  bool _copied = false;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    // The PWA stacks bare setTimeouts (no clearTimeout), so a re-tap's earlier
    // timer still reverts the label at ITS 1500ms mark — mirror that by not
    // cancelling; the `mounted` guard covers disposal.
    Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: _copy,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: c.primaryA(0.15),
          borderRadius: NymRadius.rxs,
          border: Border.all(color: c.primaryA(0.3)),
        ),
        child: Text(
          _copied ? 'Copied!' : 'Copy',
          style: TextStyle(color: c.primary, fontSize: widget.size * 0.75),
        ),
      ),
    );
  }
}

/// The read-more char-count threshold (`truncateThreshold`, messages.js:1193-
/// 1194): 400 on mobile (`innerWidth <= 768`), 600 on desktop. It only FLAGS a
/// truncation candidate; the collapse itself is height-based (see [_Collapsible]).
int truncateThreshold(BuildContext context) =>
    MediaQuery.of(context).size.width <= 768 ? 400 : 600;

/// The rendered text length of a [QuoteBlock], mirroring the PWA's
/// `bq.textContent.length` (messages.js:1214) — the author header plus all child
/// text, with custom-emoji images contributing nothing (they're `<img>`, no text)
/// the same way `textContent` skips them. Used to flag a lone long blockquote as
/// a read-more truncation candidate.
int _quoteTextLength(QuoteBlock block) {
  var n = block.author != null ? block.author!.length + 1 : 0; // header + ':'
  for (final child in block.children) {
    n += _blockTextLength(child);
  }
  return n;
}

int _blockTextLength(FormatBlock block) {
  switch (block) {
    case ParagraphBlock(:final inlines):
    case HeadingBlock(:final inlines):
      var n = 0;
      for (final node in inlines) {
        n += _inlineTextLength(node);
      }
      return n;
    case CodeBlock(:final code):
      return code.length;
    case QuoteBlock():
      return _quoteTextLength(block);
    case MediaBlock():
      return 0; // media renders as elements, no text content
  }
}

int _inlineTextLength(InlineNode node) {
  switch (node) {
    case TextSpanNode(:final text):
      return text.length;
    case BoldNode(:final children):
    case ItalicNode(:final children):
    case StrikeNode(:final children):
      var n = 0;
      for (final ch in children) {
        n += _inlineTextLength(ch);
      }
      return n;
    case InlineCodeNode(:final code):
      return code.length;
    case LinkNode(:final url):
      return url.length;
    case EmojiNode(:final unicode):
      return unicode.length;
    case MentionNode(:final base, :final suffix):
      return base.length + (suffix != null ? suffix.length + 1 : 0);
    case ChannelRefNode(:final name):
      return name.length + 1; // leading '#'
    case ChannelLinkChip(:final label):
      return label.length;
    case CustomEmojiNode():
    case GroupInviteChip():
      return 0; // rendered as an image / chip, no text content
    default:
      // `_MediaInline` is flattened to blocks before render and never reaches
      // here (it contributes no text content either way).
      return 0;
  }
}

// ===========================================================================
// Jump-to-quoted-message resolution — the content-based search behind a tapped
// blockquote, a 1:1 port of `_scrollToQuotedMessage`'s matcher
// (messages.js:2676-2762). Given a [QuoteBlock] and the loaded view messages it
// returns the best-matching SOURCE message (or null), so the caller can scroll
// to + flash it. Public for the unit tests in `message_render_test.dart`.
// ===========================================================================

final RegExp _rxQuoteSuffix = RegExp(r'#([0-9a-f]{4})$', caseSensitive: false);
final RegExp _rxWs = RegExp(r'\s+');

/// The `textContent` of a quote's children (the PWA clones the blockquote and
/// removes `.quote-author` before reading `textContent`), whitespace-collapsed.
/// Custom-emoji / media contribute nothing, exactly like an `<img>` in
/// `textContent`.
String _quoteBodyText(QuoteBlock block) {
  final buf = StringBuffer();
  for (final child in block.children) {
    _appendBlockText(buf, child);
  }
  return buf.toString().replaceAll(_rxWs, ' ').trim();
}

void _appendBlockText(StringBuffer buf, FormatBlock block) {
  switch (block) {
    case ParagraphBlock(:final inlines):
    case HeadingBlock(:final inlines):
      for (final node in inlines) {
        _appendInlineText(buf, node);
      }
      buf.write(' ');
    case CodeBlock(:final code):
      buf
        ..write(code)
        ..write(' ');
    case QuoteBlock():
      // Nested quote: its author span + body are part of the outer textContent.
      if (block.author != null) {
        buf
          ..write(block.author)
          ..write(': ');
      }
      for (final child in block.children) {
        _appendBlockText(buf, child);
      }
    case MediaBlock():
      break; // <img>/<video> — no text content
  }
}

void _appendInlineText(StringBuffer buf, InlineNode node) {
  switch (node) {
    case TextSpanNode(:final text):
      buf.write(text);
    case BoldNode(:final children):
    case ItalicNode(:final children):
    case StrikeNode(:final children):
      for (final ch in children) {
        _appendInlineText(buf, ch);
      }
    case InlineCodeNode(:final code):
      buf.write(code);
    case LinkNode(:final url):
      buf.write(url);
    case EmojiNode(:final unicode):
      buf.write(unicode);
    case MentionNode(:final base, :final suffix):
      buf.write(base);
      if (suffix != null) buf.write('#$suffix');
    case ChannelRefNode(:final name):
      buf.write('#$name');
    case ChannelLinkChip(:final label):
      buf.write(label);
    case CustomEmojiNode():
    case GroupInviteChip():
      break; // rendered as image / chip — no text content
    default:
      break;
  }
}

/// `stripQuoteLines` (messages.js:2711): the non-`>` lines of [raw], joined by a
/// space and whitespace-collapsed — the "reply only" text the match scores
/// against (so a reply whose body merely re-quotes doesn't shadow the original).
String _stripQuoteLines(String raw) => raw
    .split(RegExp(r'\r?\n'))
    .where((l) => !l.startsWith('>'))
    .join(' ')
    .replaceAll(_rxWs, ' ')
    .trim();

/// `scoreHaystack` (messages.js:2695-2701): exact 1000 / contains 500 / long-
/// prefix(80) 250 / else 0.
int _scoreHaystack(String haystack, String needle) {
  if (haystack.isEmpty) return 0;
  if (haystack == needle) return 1000;
  if (haystack.contains(needle)) return 500;
  if (needle.length > 20 &&
      haystack.contains(needle.substring(0, 80.clamp(0, needle.length)))) {
    return 250;
  }
  return 0;
}

/// Finds the message a tapped quote points at, mirroring the DOM scan in
/// `_scrollToQuotedMessage` (messages.js:2713-2728). Returns null when nothing
/// scores above 0 (PWA: "Original message is not available").
Message? resolveQuotedMessage(
  QuoteBlock block,
  List<Message> messages, {
  String? hostMessageId,
}) {
  // Author: strip a leading '@'/trailing ':' (already done in QuoteBlock.author)
  // then split a trailing `#xxxx` suffix from the base nym.
  final authorText = (block.author ?? '').trim();
  if (authorText.isEmpty && block.children.isEmpty) return null;
  final sfx = _rxQuoteSuffix.firstMatch(authorText);
  final quotedSuffix = sfx?.group(1)?.toLowerCase();
  final quotedName = authorText.replaceAll(_rxQuoteSuffix, '').trim();

  final quotedText = _quoteBodyText(block);
  if (quotedText.isEmpty) return null;
  final needle = quotedText.substring(0, quotedText.length.clamp(0, 200));

  bool matchesAuthor(Message m) {
    final suffix = m.pubkey.length >= 4
        ? m.pubkey.substring(m.pubkey.length - 4).toLowerCase()
        : m.pubkey.toLowerCase();
    if (quotedSuffix != null && suffix != quotedSuffix) return false;
    final trimmed = m.author.trim();
    final baseAuthor = stripPubkeySuffix(trimmed);
    if (quotedName.isNotEmpty &&
        baseAuthor != quotedName &&
        trimmed != quotedName) {
      return false;
    }
    return true;
  }

  Message? best;
  var bestScore = -1;
  for (final m in messages) {
    if (hostMessageId != null && m.id == hostMessageId) continue;
    if (!matchesAuthor(m)) continue;
    final raw = m.content.replaceAll(_rxWs, ' ').trim();
    if (raw.isEmpty) continue;
    final replyOnly = _stripQuoteLines(m.content);
    final score = _scoreHaystack(replyOnly.isNotEmpty ? replyOnly : raw, needle);
    if (score > bestScore) {
      bestScore = score;
      best = m;
    }
  }
  return bestScore > 0 ? best : null;
}

/// Left-bordered quote block, with an optional author header.
class _QuoteBox extends ConsumerWidget {
  const _QuoteBox({
    required this.block,
    required this.color,
    required this.size,
    this.topLevel = false,
    this.hostMessageId,
  });
  final QuoteBlock block;
  final Color color;
  final double size;

  /// True only for a direct child of `.message-content` (PWA `:scope >
  /// blockquote`); a nested quote is measured as part of its parent's
  /// `textContent` and is never independently truncated.
  final bool topLevel;

  /// The id of the host message (the one containing this quote), forwarded so a
  /// tap can exclude the host from the quoted-source search (PWA `hostKey`).
  final String? hostMessageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final inner = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (block.author != null) _quoteAuthor(c, block.author!),
        for (final child in block.children) _quoteChild(context, c, child),
      ],
    );
    // A lone long blockquote gets its OWN read-more truncation in the PWA
    // (messages.js:1213-1224): each top-level `> blockquote` whose
    // `textContent.length` exceeds the threshold is wrapped in a 300px
    // `.truncated-inner` + "Read more" toggle — independent of the reply-body
    // truncation in [MessageContent]. (The reply-body path measures only the
    // non-`>` lines, so a message that is purely one long quote is never caught
    // there; this is what clamps it.)
    final clamped =
        topLevel && _quoteTextLength(block) > truncateThreshold(context)
            ? _Collapsible(child: inner)
            : inner;
    // `blockquote`: border-left 3px primary@0.4, padding-left 12 ONLY (no
    // vertical/right padding), bg secondary@0.1, radius `0 8 8 0`, with
    // `transition: background var(--transition)` (styles-chat.css:1270-1279).
    //
    // solid-ui overrides (styles-themes-responsive.css:1808-1833): opaque
    // plates `#1c1c2c`/`#ececea` (ghost `#1f1f1f`+`#888` / `#d5d5d5`+`#555`)
    // with a FULL-alpha primary border, and — inside a SELF bubble in
    // chat-bubbles mode — a translucent black@0.25 / white@0.35 wash over the
    // primary-tinted bubble plate instead. No hover brightening in solid: the
    // override's specificity (0,2,2) beats `blockquote:hover` (0,2,1).
    final ghost = ref.watch(
        settingsProvider.select((s) => s.theme == NymThemeKey.ghost));
    final bubbles = ref.watch(
        settingsProvider.select((s) => s.chatLayout == 'bubbles'));
    bool hostIsSelf() {
      final id = hostMessageId;
      if (id == null || id.isEmpty) return false;
      final app = ref.read(appStateProvider);
      final msgs = app.messages[app.view.storageKey];
      if (msgs == null) return false;
      for (final m in msgs) {
        if (m.id == id) return m.isOwn;
      }
      return false;
    }

    BoxDecoration deco({bool hovered = false}) {
      final Color bg;
      final Color borderC;
      if (c.solidUi) {
        if (bubbles && hostIsSelf()) {
          // body.solid-ui.chat-bubbles .message.self … blockquote
          // (themes:1828-1833) — outranks the ghost background rule too.
          bg = c.isLight
              ? Colors.white.withValues(alpha: 0.35)
              : Colors.black.withValues(alpha: 0.25);
          borderC = ghost
              ? (c.isLight ? const Color(0xFF555555) : const Color(0xFF888888))
              : c.primary;
        } else if (ghost) {
          bg = c.isLight ? const Color(0xFFD5D5D5) : const Color(0xFF1F1F1F);
          borderC =
              c.isLight ? const Color(0xFF555555) : const Color(0xFF888888);
        } else {
          bg = c.isLight ? const Color(0xFFECECEA) : const Color(0xFF1C1C2C);
          borderC = c.primary;
        }
      } else {
        // `.message-content > blockquote:hover { background: secondary@0.18 }`
        // (styles-chat.css:1281-1283) — the desktop hover brightening that
        // signals the quote is clickable (glass mode only).
        bg = c.secondaryA(hovered ? 0.18 : 0.1);
        borderC = c.primaryA(0.4);
      }
      return BoxDecoration(
        color: bg,
        border: Border(left: BorderSide(color: borderC, width: 3)),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
      );
    }
    // `.message-content > blockquote { cursor: pointer }` (styles-chat.css:1276):
    // ONLY the top-level quote is tappable; tapping it jumps the list to the
    // quoted source message and flashes it (PWA `_scrollToQuotedMessage`, bound
    // to `.message-content > blockquote` in ui-context.js:873). Inner links /
    // mentions / code carry their own recognizers and win the hit-test, so the
    // translucent wrapper only fires on the quote's own (inert) surface — the
    // same effect as the PWA's `closest('a, .nm-mention, code, …')` exclusion.
    if (!topLevel) {
      return Container(
        padding: const EdgeInsets.only(left: 12),
        decoration: deco(),
        child: clamped,
      );
    }
    return _HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => _jumpToQuotedSource(ref),
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          padding: const EdgeInsets.only(left: 12),
          decoration: deco(hovered: hovered),
          child: clamped,
        ),
      ),
    );
  }

  /// Resolves the quoted SOURCE message in the current view and scrolls+flashes
  /// it, mirroring `_scrollToQuotedMessage` (messages.js:2676-2777): a
  /// content-based search keyed on the quote's author (base nym + optional 4-hex
  /// suffix) and its quoted text, excluding the host message. No-ops gracefully
  /// when the source isn't in the loaded set (the PWA bails the same way).
  void _jumpToQuotedSource(WidgetRef ref) {
    final messages = ref.read(messagesForCurrentViewProvider);
    final target = resolveQuotedMessage(
      block,
      messages,
      hostMessageId: hostMessageId,
    );
    if (target == null) return; // not in the loaded set → bail (PWA parity)
    final scroller = ref.read(messageListScrollerProvider);
    if (scroller.scrollToMessage(target.id)) {
      ref.read(flashedMessageProvider.notifier).flash(target.id);
    }
  }

  /// The `<span class="quote-author">author#suffix:</span>` header, splitting
  /// the base nym (secondary 600) from a dimmed `.nym-suffix` (`#xxxx`).
  Widget _quoteAuthor(NymColors c, String author) {
    final split = splitNymSuffix(author);
    final base = split.base;
    final suffix = split.suffix.isEmpty ? null : split.suffix;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: base,
            style: TextStyle(
              color: c.secondary,
              fontSize: size - 1,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (suffix != null)
            TextSpan(
              text: suffix,
              style: TextStyle(
                color: c.secondaryA(0.7),
                fontSize: (size - 1) * 0.9,
                fontWeight: FontWeight.w100,
              ),
            ),
          TextSpan(
            text: ':',
            style: TextStyle(
              color: c.secondary,
              fontSize: size - 1,
              fontWeight: FontWeight.w600,
            ),
          ),
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
        // Nested quote: NOT independently tappable (only `> blockquote` is); a
        // tap anywhere in the outer box already jumps using the outer quote.
        return _QuoteBox(
          block: child,
          color: dim,
          size: size,
          hostMessageId: hostMessageId,
        );
      case MediaBlock(:final items):
        return _MediaGallery(items: items);
    }
  }
}

/// A 1/2/3/4-up media grid. Images are tappable (expand placeholder); videos
/// render as an inline [VideoMessage] (tap-to-play, fullscreen expand).
class _MediaGallery extends StatelessWidget {
  const _MediaGallery({required this.items, this.blur = false});
  final List<MediaItem> items;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    // Single image/video: max 300×300, min-height 80 (`styles-chat.css:1029`).
    if (items.length == 1) {
      return _MediaTile(
          item: items.first, maxSize: 300, blur: blur, gallery: items);
    }
    // The grid is ALWAYS 2 columns, gap 4, max-width 420, radius sm
    // (`styles-chat.css:987-1023`). 3 items = a tall left hero + two stacked
    // right; 2 / 4+ = a 2-column wrap. Only the individual TILES cap at 220px
    // tall — the grid itself has no overall height cap, so a 5-6-image message
    // grows to fit every row (rows 3+ stay visible).
    const gap = 4.0;
    Widget tile(MediaItem m) => _MediaTile(
        item: m, maxSize: 220, blur: blur, inGallery: true, gallery: items);
    Widget body;
    if (items.length == 3) {
      // The hero spans both implicit rows (`gallery-3 > :first-child`), each
      // row capped at the 220px tile height → a fixed 2×220 + gap footprint.
      body = SizedBox(
        height: 2 * 220 + gap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: tile(items[0])),
            const SizedBox(width: gap),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: tile(items[1])),
                  const SizedBox(height: gap),
                  Expanded(child: tile(items[2])),
                ],
              ),
            ),
          ],
        ),
      );
    } else {
      body = GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: gap,
        crossAxisSpacing: gap,
        children: [for (final item in items) tile(item)],
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: body,
    );
  }
}

class _MediaTile extends ConsumerWidget {
  const _MediaTile({
    required this.item,
    required this.maxSize,
    this.blur = false,
    this.inGallery = false,
    this.gallery,
  });
  final MediaItem item;
  final double maxSize;

  /// The sibling media of this tile's message — lets a tap open the fullscreen
  /// viewer with prev/next paging across the message's images (`expandImage` /
  /// `_imageModalGallery`). Null/single → a one-image viewer.
  final List<MediaItem>? gallery;

  /// Opens [item] (and its image siblings) in the fullscreen viewer.
  void _openFullscreen(BuildContext context) {
    final urls = (gallery ?? [item])
        .where((m) => !m.isVideo)
        .map((m) => m.url)
        .toList();
    if (urls.isEmpty) return;
    final idx = urls.indexOf(item.url);
    _FullscreenImageViewer.open(context, urls, idx < 0 ? 0 : idx);
  }

  /// Apply the privacy blur (others' images), revealed on tap (`.blurred`).
  final bool blur;

  /// This tile sits inside a multi-up gallery grid — videos drop their border
  /// and corner radius (the grid clips), matching `.message-gallery video`.
  final bool inGallery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    // Single image: radius `--radius-sm` (=12); gallery cell: square (radius 0,
    // the grid clips). (styles-chat.css:941-950, 1012-1023.)
    final radius =
        inGallery ? BorderRadius.zero : NymRadius.rsm;

    // NIP-92 imeta Blossom mirrors recorded for this URL (`ingestImetaTags` /
    // the upload path), retried when the primary source fails — the PWA's
    // `data-media-fallbacks` attribute (message-format.js:146-151) consumed by
    // `_attachMediaFallbacks` (messages.js:1154-1187). Keyed by the RAW url;
    // each mirror is proxied at render time exactly like the primary.
    final mirrors = ref.watch(mediaFallbacksProvider).fallbacksFor(item.url);

    if (item.isVideo) {
      // Inline playable video (`F16`): single → bordered max-300 radius-sm;
      // gallery cell → borderless, square corners, filling the tile.
      return VideoMessage(
        url: item.url,
        fallbackUrls: mirrors,
        maxSize: maxSize,
        bordered: !inGallery,
        borderRadius: inGallery ? BorderRadius.zero : null,
      );
    }

    // SVG-aware + decode-safe: SVG images render via flutter_svg, and any
    // undecodable image (`ImageDecoder unimplemented`, broken URL) shows the
    // broken-image placeholder instead of throwing. (BUG: image decode failures.)
    final image = InlineNetworkImage(
      url: proxiedMedia(item.url),
      fallbackUrls: [for (final u in mirrors) proxiedMedia(u)],
      fit: BoxFit.cover,
      width: maxSize,
      // `.msg-img:not(.img-loaded)`: a 300px-wide 4:3 slot with a white@0.03
      // wash while the image decodes (styles-chat.css:952-958; no light-mode
      // override).
      placeholder: Container(
        width: maxSize,
        height: maxSize * 3 / 4,
        color: Colors.white.withValues(alpha: 0.03),
      ),
      errorChild: Container(
        width: maxSize,
        height: 80,
        color: Colors.white.withValues(alpha: 0.05),
        alignment: Alignment.center,
        child: Icon(Icons.broken_image, color: c.textDim),
      ),
    );

    // Tapping an image opens it fullscreen (after the privacy blur is first
    // revealed, when blurred) — `data-action="expandImageFromData"`.
    final tappableImage = blur
        ? _BlurReveal(
            onRevealedTap: () => _openFullscreen(context),
            child: image,
          )
        : GestureDetector(
            onTap: () => _openFullscreen(context),
            child: image,
          );
    // `.message-content img:hover { transform: scale(1.02); box-shadow:
    // var(--shadow-md); border-color: rgba(255,255,255,0.15) }` over
    // `transition: all var(--transition)` (styles-chat.css:941-964) — mouse
    // hover only ([MouseRegion] never fires on touch). `--shadow-md` is
    // 0 4px 16px black@0.4 dark / black@0.1 light (styles-core.css:92 +
    // styles-themes-responsive.css:536).
    if (inGallery) {
      // Gallery cell: no border; the scaled image is clipped by the cell
      // (the PWA's `.message-gallery { overflow: hidden }`).
      return _HoverBuilder(
        builder: (context, hovered) => ClipRRect(
          borderRadius: radius,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxSize, maxHeight: maxSize),
            child: AnimatedScale(
              scale: hovered ? 1.02 : 1.0,
              duration: NymMotion.transition,
              curve: NymMotion.curve,
              child: tappableImage,
            ),
          ),
        ),
      );
    }
    // A lone image carries a 1px glass border (`.message-content img`), which
    // brightens to white@0.15 on hover alongside the lift + shadow.
    return _HoverBuilder(
      builder: (context, hovered) => AnimatedScale(
        scale: hovered ? 1.02 : 1.0,
        duration: NymMotion.transition,
        curve: NymMotion.curve,
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: hovered
                  ? Colors.white.withValues(alpha: 0.15)
                  : c.glassBorder,
            ),
            boxShadow: hovered
                ? [
                    BoxShadow(
                      color: Colors.black
                          .withValues(alpha: c.isLight ? 0.1 : 0.4),
                      offset: const Offset(0, 4),
                      blurRadius: 16,
                    ),
                  ]
                : const [],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: maxSize, maxHeight: maxSize),
              child: tappableImage,
            ),
          ),
        ),
      ),
    );
  }
}

/// Rebuilds its subtree with the current mouse-hover state — the carrier for
/// the PWA's desktop-only `:hover` treatments. [MouseRegion] enter/exit only
/// fire for a hovering pointer (a mouse/trackpad), so touch platforms never
/// see the hover state; the cursor is `click`, matching the PWA's
/// `cursor: pointer` on these surfaces.
class _HoverBuilder extends StatefulWidget {
  const _HoverBuilder({required this.builder});
  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<_HoverBuilder> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(context, _hovered),
    );
  }
}

/// Fullscreen image viewer (`expandImage` + `_imageModalGallery`,
/// messages.js:1432-1483 + the touch-gesture module, app.js:2304-2480):
/// pinch-zoom (1–5×) with clamped pan, one-finger swipe-to-dismiss with a live
/// backdrop fade, >60px horizontal swipe gallery paging, 300ms double-tap
/// 2.5× zoom toggle, prev/next paging
/// across a message's images, tap the backdrop or the ✕ to close.
class _FullscreenImageViewer extends StatefulWidget {
  const _FullscreenImageViewer(
      {required this.urls, required this.initialIndex});
  final List<String> urls;
  final int initialIndex;

  static Future<void> open(
      BuildContext context, List<String> urls, int index) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        // The `.image-modal { background: rgba(0,0,0,0.85) }` backdrop is
        // painted INSIDE the page (not as a route barrier) because the swipe-
        // to-dismiss gesture live-fades it (`modal.style.background =
        // rgba(0,0,0, 0.4*(1-progress))`, app.js:2382-2383).
        pageBuilder: (_, __, ___) =>
            _FullscreenImageViewer(urls: urls, initialIndex: index),
      ),
    );
  }

  @override
  State<_FullscreenImageViewer> createState() => _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends State<_FullscreenImageViewer>
    with SingleTickerProviderStateMixin {
  static const double _minScale = 1; // MIN_SCALE (app.js:2305)
  static const double _maxScale = 5; // MAX_SCALE

  late int _index = widget.initialIndex;

  // The live `translate(tx, ty) scale(scale)` transform (app.js:2317-2320).
  double _scale = 1, _tx = 0, _ty = 0;

  // Gesture baselines captured at touch-down / pointer-count change.
  double _startScale = 1, _startTx = 0, _startTy = 0;
  Offset _startFocal = Offset.zero;

  /// 'pinch' | 'pan' (one finger, zoomed) | 'swipe' (one finger, unzoomed) —
  /// the PWA's `mode` (app.js:2341-2357). Null = no active gesture.
  String? _mode;

  /// The swipe-drag backdrop alpha override (`modal.style.background =
  /// rgba(0,0,0, 0.4 * (1 - progress))`, app.js:2382-2383); null = the resting
  /// `.image-modal` rgba(0,0,0,0.85).
  double? _swipeBgAlpha;

  /// Crossfade flag during gallery navigation (`opacity 0.12s linear`,
  /// app.js:2411-2420): fade out, swap src after 120ms, fade back in.
  bool _fadingOut = false;
  Timer? _navTimer;

  /// Measures the laid-out (unscaled) image box for `clampPan` (app.js:2331).
  final GlobalKey _imgKey = GlobalKey();

  /// Drives the animated transitions: the 0.25s ease `gesture-animating`
  /// spring-back/settle (styles-components.css:599-601) and the 0.18s ease
  /// transform reset while navigating the gallery.
  late final AnimationController _anim = AnimationController(vsync: this);

  @override
  void dispose() {
    _navTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  /// Animates the transform to the given target — the CSS
  /// `transition: transform [duration] ease` the PWA toggles via
  /// `gesture-animating`.
  void _animateTo(double scale, double tx, double ty, Duration duration) {
    _anim.stop();
    final s0 = _scale, x0 = _tx, y0 = _ty;
    final curve = CurvedAnimation(parent: _anim, curve: Curves.ease);
    void tick() {
      if (!mounted) return;
      setState(() {
        final t = curve.value;
        _scale = s0 + (scale - s0) * t;
        _tx = x0 + (tx - x0) * t;
        _ty = y0 + (ty - y0) * t;
      });
    }

    curve.addListener(tick);
    _anim.duration = duration;
    _anim.forward(from: 0).whenCompleteOrCancel(() {
      curve.removeListener(tick);
      curve.dispose();
    });
  }

  /// `reset(animate)` (app.js:2322-2328): zoom/pan back to identity and drop
  /// the swipe backdrop override (instantly, like `modal.style.background=''`).
  void _reset({required bool animate}) {
    setState(() => _swipeBgAlpha = null);
    if (animate) {
      _animateTo(1, 0, 0, const Duration(milliseconds: 250));
    } else {
      _anim.stop();
      setState(() {
        _scale = 1;
        _tx = 0;
        _ty = 0;
      });
    }
  }

  /// `clampPan()` (app.js:2331-2336): keeps the zoomed image's pan within the
  /// scaled overhang. Returns the clamped (tx, ty).
  (double, double) _clampedPan() {
    final box = _imgKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return (_tx, _ty);
    final maxX = math.max(0.0, (box.size.width * _scale - box.size.width) / 2);
    final maxY =
        math.max(0.0, (box.size.height * _scale - box.size.height) / 2);
    return (_tx.clamp(-maxX, maxX), _ty.clamp(-maxY, maxY));
  }

  void _onScaleStart(ScaleStartDetails d) {
    _anim.stop();
    _startScale = _scale;
    _startTx = _tx;
    _startTy = _ty;
    _startFocal = d.focalPoint;
    // 2 fingers → pinch; 1 finger → pan when zoomed, else swipe(-to-dismiss)
    // (`onStart`, app.js:2339-2357).
    _mode = d.pointerCount >= 2
        ? 'pinch'
        : (_scale > _minScale ? 'pan' : 'swipe');
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    // A finger added/lifted mid-gesture re-baselines like the PWA's fresh
    // `touchstart` (its handler re-runs `onStart` on every new touch).
    final wantPinch = d.pointerCount >= 2;
    if (_mode == null || wantPinch != (_mode == 'pinch')) {
      _startScale = _scale;
      _startTx = _tx;
      _startTy = _ty;
      _startFocal = d.focalPoint;
      _mode = wantPinch ? 'pinch' : (_scale > _minScale ? 'pan' : 'swipe');
    }
    final dFocal = d.focalPoint - _startFocal;
    setState(() {
      if (_mode == 'pinch') {
        // scale = clamp(startScale × spanRatio); the midpoint drag pans
        // (app.js:2361-2369).
        _scale = (_startScale * d.scale).clamp(_minScale, _maxScale);
        _tx = _startTx + dFocal.dx;
        _ty = _startTy + dFocal.dy;
      } else if (_mode == 'pan') {
        _tx = _startTx + dFocal.dx;
        _ty = _startTy + dFocal.dy;
      } else {
        // Swipe: the image follows the finger on BOTH axes and the backdrop
        // fades `rgba(0,0,0, 0.4 * (1 - min(1, hypot/300)))` (app.js:2374-2383).
        _tx = dFocal.dx;
        _ty = dFocal.dy;
        final progress =
            math.min(1.0, Offset(_tx, _ty).distance / 300);
        _swipeBgAlpha = 0.4 * (1 - progress);
      }
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final mode = _mode;
    if (d.pointerCount == 0) _mode = null;
    if (mode == 'swipe') {
      // `onEnd` (app.js:2426-2452): with a >1-image gallery a dominantly-
      // horizontal release past 60px pages prev/next; otherwise a release
      // whose travel exceeds 100px (vertical-only when a gallery exists)
      // dismisses; anything else springs back over 0.25s ease.
      final hasGallery = widget.urls.length > 1;
      final horizontal = _tx.abs() > _ty.abs();
      if (hasGallery && horizontal) {
        if (_tx.abs() > 60) {
          final delta = _tx < 0 ? 1 : -1;
          if (_navigate(delta)) return;
        }
        _reset(animate: true);
        return;
      }
      final closeDist =
          hasGallery ? _ty.abs() : Offset(_tx, _ty).distance;
      if (closeDist > 100) {
        Navigator.of(context).maybePop();
        return;
      }
      _reset(animate: true);
    } else if (mode == 'pinch' || mode == 'pan') {
      if (_scale <= _minScale) {
        _reset(animate: true);
      } else {
        // Settle the pan inside the scaled bounds (`clampPan(); apply(true)`).
        final (cx, cy) = _clampedPan();
        _animateTo(_scale, cx, cy, const Duration(milliseconds: 250));
      }
    }
  }

  /// Double-tap toggles zoom 1 ↔ 2.5 (`onDoubleTap`, app.js:2455-2463; the
  /// 300ms pairing window is the framework's double-tap timeout).
  void _onDoubleTap() {
    if (_scale > _minScale) {
      _reset(animate: true);
    } else {
      _animateTo(2.5, _tx, _ty, const Duration(milliseconds: 250));
    }
  }

  /// `navigateGallery(delta)` (app.js:2402-2423): CLAMPED at the gallery ends
  /// (no wraparound — returns false past either end), resets zoom/pan, and
  /// crossfades: opacity out over 0.12s (linear) with an 0.18s ease transform
  /// reset, src swap at 120ms, then fade back in.
  bool _navigate(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.urls.length) return false;
    setState(() {
      _fadingOut = true;
      _swipeBgAlpha = null;
    });
    _animateTo(1, 0, 0, const Duration(milliseconds: 180));
    _navTimer?.cancel();
    _navTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() {
        _index = next;
        _fadingOut = false;
      });
    });
    return true;
  }

  /// `downloadModalMedia` (app.js:2264-2302): the PWA blob-downloads the modal
  /// image, falling back to `window.open(src, '_blank')`. Natively we hand the
  /// image URL to the platform (browser/downloader) — the same
  /// open-externally path the video fullscreen uses.
  Future<void> _download() async {
    final uri = Uri.tryParse(widget.urls[_index]);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final screen = MediaQuery.of(context).size;
    final multi = widget.urls.length > 1;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // `.image-modal { background: rgba(0,0,0,0.85) }` (styles-components
          // .css:570-577), live-faded by the swipe drag; tap dismisses
          // (`data-action="closeImageModal"`).
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: _swipeBgAlpha ?? 0.85),
              ),
            ),
          ),
          Center(
            child: GestureDetector(
              // A click on the UNZOOMED image bubbles to the modal and closes
              // it; a zoomed/just-dragged image swallows the click (app.js:
              // 2474-2479).
              onTap: _scale > _minScale
                  ? null
                  : () => Navigator.of(context).maybePop(),
              onDoubleTap: _onDoubleTap,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: _onScaleEnd,
              child: Transform.translate(
                offset: Offset(_tx, _ty),
                child: Transform.scale(
                  scale: _scale,
                  // `transform-origin: center center` (styles-components.css:594).
                  alignment: Alignment.center,
                  child: AnimatedOpacity(
                    // The gallery crossfade (`opacity 0.12s linear`).
                    opacity: _fadingOut ? 0 : 1,
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.linear,
                    // `.image-modal img`: max 90% × 90%, 1px glass border,
                    // radius `--radius-md` (=16), `--shadow-lg` = 0 8px 32px
                    // rgba(0,0,0,0.5) (styles-components.css:587-596). Light
                    // mode softens it to 0 8px 40px rgba(0,0,0,0.2)
                    // (`body.light-mode .image-modal img`,
                    // styles-themes-responsive.css:677-679).
                    child: Container(
                      key: _imgKey,
                      constraints: BoxConstraints(
                        maxWidth: screen.width * 0.9,
                        maxHeight: screen.height * 0.9,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: c.glassBorder),
                        borderRadius: NymRadius.rmd,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black
                                .withValues(alpha: c.isLight ? 0.2 : 0.5),
                            offset: const Offset(0, 8),
                            blurRadius: c.isLight ? 40 : 32,
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.network(
                        proxiedMedia(widget.urls[_index]),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.broken_image,
                            color: Colors.white54,
                            size: 48),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (multi) ...[
            // `.image-modal-nav`: 44px glass circles at 20px insets, ‹ ›
            // glyphs at 32px with a 4px bottom pad, vertically centered
            // (styles-components.css:645-678). The prev arrow hides at index
            // 0 and next at the last image — NO wraparound
            // (`updateGalleryNavButtons`, app.js:2389-2399).
            if (_index > 0)
              Positioned(
                left: 20,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _chip('‹', 44, 32, () => _navigate(-1),
                      padding: const EdgeInsets.only(bottom: 4)),
                ),
              ),
            if (_index < widget.urls.length - 1)
              Positioned(
                right: 20,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _chip('›', 44, 32, () => _navigate(1),
                      padding: const EdgeInsets.only(bottom: 4)),
                ),
              ),
            Positioned(
              bottom: 28,
              left: 0,
              right: 0,
              child: Center(
                child: Text('${_index + 1} / ${widget.urls.length}',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13)),
              ),
            ),
          ],
          // `.image-modal-download`: a 40px glass circle at top:20 right:70
          // with a ⤓ glyph at 22px (styles-components.css:627-644).
          Positioned(
            top: 20,
            right: 70,
            child: SafeArea(child: _chip('⤓', 40, 22, _download)),
          ),
          // `.image-modal-close`: a 40px glass circle at top:20 right:20 with
          // a × glyph at 24px (styles-components.css:602-620).
          Positioned(
            top: 20,
            right: 20,
            child: SafeArea(
              child:
                  _chip('×', 40, 24, () => Navigator.of(context).maybePop()),
            ),
          ),
        ],
      ),
    );
  }

  /// A `.image-modal-close`/`-download`/`-nav` glass circle: rgba(20,20,35,0.8)
  /// fill, 1px glass border, `--text` glyph, centered.
  Widget _chip(String glyph, double side, double fontSize, VoidCallback onTap,
      {EdgeInsets padding = EdgeInsets.zero}) {
    final c = context.nym;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: side,
        height: side,
        padding: padding,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xCC141423),
          shape: BoxShape.circle,
          border: Border.all(color: c.glassBorder),
        ),
        child: Text(
          glyph,
          style: TextStyle(color: c.text, fontSize: fontSize, height: 1),
        ),
      ),
    );
  }
}

/// Wraps an image in a gaussian blur revealed on tap (`.blurred`,
/// `messages.js:1267-1274` — the PWA clears the blur class on tap).
class _BlurReveal extends StatefulWidget {
  const _BlurReveal({required this.child, this.onRevealedTap});
  final Widget child;

  /// Tapped once the blur is cleared (e.g. to open the fullscreen viewer).
  final VoidCallback? onRevealedTap;

  @override
  State<_BlurReveal> createState() => _BlurRevealState();
}

class _BlurRevealState extends State<_BlurReveal> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    if (_revealed) {
      return GestureDetector(
        onTap: widget.onRevealedTap,
        child: widget.child,
      );
    }
    // `img.blurred { filter: blur(20px) }` (styles-components.css:1628-1631);
    // the hover blur(10px) lightening is desktop-hover-only and omitted here.
    return GestureDetector(
      onTap: () => setState(() => _revealed = true),
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: widget.child,
      ),
    );
  }
}

/// Renders a short string inline while resolving NIP-30 custom emoji: any
/// `:shortcode:` known to [liveCustomEmojiProvider] becomes an inline image;
/// everything else is plain styled text.
///
/// This is the lightweight counterpart to [MessageContent] for surfaces that
/// show a reaction emoji or a short notification line — reaction badges, the
/// reactors sheet, the notifications panel — where a full formatted block is too
/// heavy and where, until now, `:shortcode:` reactions showed as literal text.
///
/// It mirrors the PWA's two short-text helpers (emoji.js):
///   - `renderCustomEmojiInEscapedText` (:560-568) — the default: every KNOWN
///     custom `:code:` in the string becomes an image; built-in unicode
///     shortcodes (e.g. `:tada:`) are NOT substituted (only message bodies do
///     that, message-format.js:251-257) and unknown codes stay literal.
///   - `renderReactionEmoji` (:342-351) — [wholeStringOnly]: ONLY a text that
///     is exactly `:code:` for a known custom code becomes an image; a token
///     embedded in longer content stays literal.
///
/// Text runs keep the caller's [style] verbatim (no colour-emoji fallback is
/// forced onto them, which would wreck Latin metrics/glyphs the same way the old
/// global theme fallback did); unicode emoji render via the platform font.
class InlineEmojiText extends ConsumerWidget {
  const InlineEmojiText({
    super.key,
    required this.text,
    required this.style,
    this.emojiSize,
    this.wholeStringOnly = false,
    this.emojiMargin = const EdgeInsets.symmetric(horizontal: 1),
    this.emojiAlignment,
    this.emojiBaselineDropEm,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle style;

  /// Exact side length for an inline custom-emoji image. Defaults to 1.75× the
  /// font size — the PWA's base `.custom-emoji { width/height: 1.75em }`
  /// (styles-chat.css:839-846). Surfaces with their own CSS size (reaction
  /// badges 1.45em, quick-react 30px, burst 45px, …) pass it explicitly.
  final double? emojiSize;

  /// `renderReactionEmoji` semantics (emoji.js:342-351): only an exact
  /// `^:code:$` text resolves to an image; embedded tokens stay literal.
  final bool wholeStringOnly;

  /// Margin around the emoji image. The base `.custom-emoji` rule is
  /// `margin: 0 1px`; reaction surfaces (`.custom-emoji-reaction`,
  /// `.quick-react-emoji .custom-emoji`) override it to 0.
  final EdgeInsets emojiMargin;

  /// Override for surfaces whose CSS is NOT the inline baseline-shift: pass
  /// [PlaceholderAlignment.middle] where the PWA says `vertical-align: middle`
  /// or centers the image as a flex item (`.reaction-badge`/
  /// `.reactors-modal-emoji` are `display:(inline-)flex; align-items:center`,
  /// `.quick-react-emoji .custom-emoji` is `vertical-align: middle`), or
  /// [PlaceholderAlignment.top] for the burst's `vertical-align: top`
  /// (styles-features.css:369-374). When null the image is baseline-aligned
  /// with its bottom [emojiBaselineDropEm] ems below the text baseline — the
  /// PWA's `vertical-align: -Nem`.
  final PlaceholderAlignment? emojiAlignment;

  /// Ems (of [style]'s font size, the img's inherited `em`) the image bottom
  /// sits below the alphabetic baseline. Defaults per the PWA class each mode
  /// maps to: `.custom-emoji { vertical-align: -0.375em }` for the default
  /// mode (styles-chat.css:843), `.custom-emoji-reaction { vertical-align:
  /// -0.25em }` for [wholeStringOnly] (:857). Ignored when [emojiAlignment]
  /// is set.
  final double? emojiBaselineDropEm;

  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  /// `:shortcode:` token (NIP-30 codes are `[a-zA-Z0-9_]+`, emoji.js).
  static final RegExp _rxToken = RegExp(r':([a-zA-Z0-9_]+):');

  /// Whole-string `:shortcode:` (emoji.js `renderReactionEmoji` `^:code:$`).
  static final RegExp _rxWholeToken = RegExp(r'^:([a-zA-Z0-9_]+):$');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final codeToUrl = ref.watch(liveCustomEmojiProvider).codeToUrl;
    final side = emojiSize ?? (style.fontSize ?? 14) * 1.75;

    Widget plainText() => Text(text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign);

    // `vertical-align: -Nem` per the mode's PWA class (see
    // [emojiBaselineDropEm]) unless the surface overrides [emojiAlignment].
    final dropPx = (style.fontSize ?? 14) *
        (emojiBaselineDropEm ?? (wholeStringOnly ? 0.25 : 0.375));

    InlineSpan emojiSpan(String code, String url) {
      final image = InlineNetworkImage(
        url: proxiedMedia(url, emoji: true),
        width: side,
        height: side,
        fit: BoxFit.contain,
        // Disk-cached (sparse: a reaction badge / a notification line
        // shows one emoji). Only the picker grid uses memoryOnly.
        retryOnError: true,
        errorChild: Text(':$code:', style: style),
      );
      final align = emojiAlignment;
      return WidgetSpan(
        alignment: align ?? PlaceholderAlignment.baseline,
        baseline: align == null ? TextBaseline.alphabetic : null,
        child: Padding(
          padding: emojiMargin,
          child: align == null
              ? EmojiBaselineDrop(drop: dropPx, child: image)
              : image,
        ),
      );
    }

    if (wholeStringOnly) {
      // `renderReactionEmoji`: an image ONLY when the whole text is a known
      // custom `:code:`; anything else (unicode, unknown code, embedded token)
      // is the literal escaped text.
      final code = _rxWholeToken.firstMatch(text)?.group(1);
      final url = code == null ? null : codeToUrl[code];
      if (url == null) return plainText();
      return Text.rich(
        emojiSpan(code!, url),
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }

    // Fast path: no `:shortcode:` token at all → a single styled Text (keeps
    // these surfaces find-by-text friendly and avoids a needless RichText).
    if (!_rxToken.hasMatch(text)) return plainText();

    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _rxToken.allMatches(text)) {
      final code = m.group(1)!;
      // `renderCustomEmojiInEscapedText` (emoji.js:560-568) replaces ONLY
      // known custom codes; built-in unicode shortcodes are never substituted
      // on these surfaces (`registerCustomEmoji` refuses codes shadowing the
      // built-in `emojiMap`, emoji.js:121, so `customEmojis` never has them)
      // and unknown codes stay literal text.
      final url = codeToUrl[code];
      if (url == null) {
        continue; // unknown code → leave the literal `:code:` in trailing text
      }
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start), style: style));
      }
      spans.add(emojiSpan(code, url));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: style));
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}

/// The maximum collapsed height of a `.truncated-inner` block: 300px
/// (`styles-chat.css:795`), reduced to 200px on the ≤768px breakpoint
/// (`@media (max-width:768px) .truncated-inner { max-height: 200px }`,
/// styles-themes-responsive.css:42-46).
double _truncateHeight(BuildContext context) =>
    MediaQuery.of(context).size.width <= 768 ? 200 : 300;

/// Collapsible body wrapper for the read-more truncation (messages.js:1192-1265,
/// `.truncated-inner` + `.read-more-btn`). Clamps [child] to [_truncateHeight]
/// with overflow hidden and a "Read more"/"Show less" toggle.
///
/// The char-count threshold (checked by the caller) only flags this body as a
/// candidate; the collapse itself is height-based, so the toggle is dropped once
/// the body is measured to already fit the collapsed height (PWA: `scrollHeight
/// <= clientHeight + 2` → remove the button + expand).
class _Collapsible extends ConsumerStatefulWidget {
  const _Collapsible({required this.child});
  final Widget child;

  @override
  ConsumerState<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends ConsumerState<_Collapsible> {
  bool _expanded = false;

  /// The body's natural (unclamped) height, learned after the first layout.
  /// Null until measured; `<= collapsed height + 2` means it fits and needs no
  /// toggle.
  double? _fullHeight;

  void _onMeasured(double height) {
    if (_fullHeight != null && (height - _fullHeight!).abs() < 0.5) return;
    // Defer the state update out of the layout phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _fullHeight = height);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `body.chat-bubbles` restyles the toggle (divider + tighter padding).
    final bubbles = ref.watch(settingsProvider).useBubbles;
    // 300px desktop / 200px on the ≤768px breakpoint (see [_truncateHeight]).
    final truncateHeight = _truncateHeight(context);
    // Content already fits the collapsed height → no clamp, no button (PWA
    // drops the toggle).
    final fits = _fullHeight != null && _fullHeight! <= truncateHeight + 2;
    final collapsed = !fits && !_expanded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRect(
          child: _MeasuredMaxHeight(
            maxHeight: collapsed ? truncateHeight : double.infinity,
            onMeasured: _onMeasured,
            child: widget.child,
          ),
        ),
        // `.read-more-btn`: a full-width <button> (label centered), `--primary`
        // 12px, `padding:4px 0; margin-top:2px` (styles-chat.css:804-816).
        // `body.chat-bubbles` adds explicit centering, `padding:6px 0 4px`,
        // `margin-top:0` and a 1px top divider — white@0.08 dark / black@0.06
        // light (styles-chat.css:817-822 + styles-themes-responsive.css:48-50).
        // Shown only while the body overflows the collapsed height.
        if (!fits)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              width: double.infinity,
              margin: bubbles ? null : const EdgeInsets.only(top: 2),
              padding: bubbles
                  ? const EdgeInsets.only(top: 6, bottom: 4)
                  : const EdgeInsets.symmetric(vertical: 4),
              decoration: bubbles
                  ? BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: c.isLight
                              ? Colors.black.withValues(alpha: 0.06)
                              : Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                    )
                  : null,
              child: Text(
                _expanded ? 'Show less' : 'Read more',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.primary, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }
}

/// Lays its [child] out at the incoming width with UNBOUNDED height to learn the
/// child's natural height (reported via [onMeasured]), then sizes itself to
/// `min(natural, maxHeight)` — clipping (via the enclosing [ClipRect]) anything
/// past [maxHeight]. This lets [_Collapsible] decide whether the read-more toggle
/// is needed without a flash: the child renders at full height and is clipped,
/// rather than being measured in a separate offstage pass.
class _MeasuredMaxHeight extends SingleChildRenderObjectWidget {
  const _MeasuredMaxHeight({
    required this.maxHeight,
    required this.onMeasured,
    required Widget super.child,
  });

  final double maxHeight;
  final ValueChanged<double> onMeasured;

  @override
  _RenderMeasuredMaxHeight createRenderObject(BuildContext context) {
    return _RenderMeasuredMaxHeight(
      maxHeight: maxHeight,
      onMeasured: onMeasured,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, _RenderMeasuredMaxHeight renderObject) {
    renderObject
      ..maxHeight = maxHeight
      ..onMeasured = onMeasured;
  }
}

class _RenderMeasuredMaxHeight extends RenderProxyBox {
  _RenderMeasuredMaxHeight({
    required double maxHeight,
    required ValueChanged<double> onMeasured,
  })  : _maxHeight = maxHeight,
        _onMeasured = onMeasured;

  double _maxHeight;
  double get maxHeight => _maxHeight;
  set maxHeight(double value) {
    if (_maxHeight == value) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  ValueChanged<double> _onMeasured;
  set onMeasured(ValueChanged<double> value) => _onMeasured = value;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // Lay the child out at our width with NO height bound to learn its natural
    // height, then report it and clamp our own height to maxHeight.
    child.layout(
      BoxConstraints(
        minWidth: constraints.minWidth,
        maxWidth: constraints.maxWidth,
        minHeight: 0,
        maxHeight: double.infinity,
      ),
      parentUsesSize: true,
    );
    final natural = child.size.height;
    _onMeasured(natural);
    final clamped = natural > _maxHeight ? _maxHeight : natural;
    size = constraints.constrain(Size(child.size.width, clamped));
  }
}

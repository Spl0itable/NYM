// Renders [NymFormat.format] output as widgets: markdown spans, code/quote/heading blocks, chips, emoji and media galleries.

import 'dart:async' show Timer;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../../../widgets/chat/messages_list.dart'
    show MessageListScroller, messageListScrollerProvider;
import '../../../widgets/chat/relative_time_ticker.dart';
import '../../../widgets/common/nym_avatar.dart';
import '../../../widgets/nym_icons.dart' show NymSvgIcon;
import '../../../widgets/context_menu/context_menu_actions.dart';
import '../../../widgets/context_menu/context_menu_panel.dart';
import '../../commands/command_handler.dart' show resolveTarget;
import '../../group_tools/group_tools_ui.dart' show GroupToolIcons, joinCallLinkFlow;
import '../../groups/group_invite_confirm.dart';
import '../../i18n/i18n.dart';
import '../../media_notes/media_note_view.dart' show audioOrMediaNote;
import '../../nymbot/nymbot_threads.dart' show threadChainFor;
import '../../shop/cosmetics.dart';
import '../../toasts/toast_center.dart';
import '../expanded_messages.dart';
import '../nostr_ref_card.dart';
import '../inline_network_image.dart';
import '../media_fallbacks.dart';
import 'link_preview.dart';
import 'nym_format.dart';
import 'discord_timestamp.dart';
import 'video_message.dart';
import '../../../core/utils/safe_url.dart';
import '../../../widgets/common/hollow_bullet.dart';
import '../../../widgets/common/nym_tooltip.dart';

/// Shared stateless [ApiClient] for proxy URL construction; its builders do no network.
final _proxyApi = ApiClient();

/// Routes [url] through the media proxy unless it is empty, relative, inline or already proxied.
String proxiedMedia(String url, {bool emoji = false}) {
  if (url.isEmpty) return url;
  final lower = url.toLowerCase();
  if (lower.startsWith('data:') || lower.startsWith('blob:')) return url;
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) return url;
  if (isOwnMediaUrl(url)) return url;
  return _proxyApi.mediaProxyUrl(url, emoji: emoji);
}

/// Renders raw message [content] via [NymFormat] with the user's settings and theme.
class MessageContent extends ConsumerWidget {
  const MessageContent({
    super.key,
    required this.content,
    this.hostMessageId,
    this.scrollKey,
    this.baseColor,
    this.fontSize,
    this.blurImages = false,
    this.glyphShadows,
    this.monospace = false,
    this.nostrRefCards = true,
    this.commonMark = false,
    this.spoilers,
  });

  final String content;

  final bool commonMark;

  final SpoilerRevealController? spoilers;

  /// Host message id, so a tapped quote excludes its own message when searching for the source; null without one.
  final String? hostMessageId;

  /// The list's `storageKey`, so a column's quote jumps its own list; null in the single view.
  final String? scrollKey;

  /// Body text color; defaults to `context.nym.text`.
  final Color? baseColor;

  /// Base font size; defaults to settings.textSize.
  final double? fontSize;

  /// Blur images behind tap-to-reveal (others' images privacy).
  final bool blurImages;

  /// Per-style glyph shadows (glow or glitch split).
  final List<Shadow>? glyphShadows;

  /// Monospace body (CRT style).
  final bool monospace;

  /// Unfurl NIP-19 references into cards; false inside a card's own body to avoid nesting.
  final bool nostrRefCards;

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
      // Live NIP-30 custom emoji so `:shortcode:` renders as images.
      customEmojis: ref.watch(liveCustomEmojiProvider).codeToUrl,
      commonMark: commonMark,
    );

    final blocks = NymFormat.format(content, ctx);
    final size = fontSize ?? settings.textSize.toDouble();
    final color = baseColor ?? c.text;

    // 1–6 emoji and nothing else render enlarged, unicode or custom.
    final emojiOnly =
        isEmojiOnly(content) || isCustomEmojiOnly(content, ctx.customEmojis);

    // Bare links to unfurl below the body, skipping inline media.
    final previewUrls = _collectPreviewUrls(blocks);
    final nostrRefs = nostrRefCards ? _collectNostrRefs(blocks) : const <String>[];

    // Tapping a channel reference or link switches channel.
    void onChannelRef(String name, bool isGeohash) {
      final controller = ref.read(nostrControllerProvider);
      if (isGeohash) {
        controller.switchChannel(name, geohash: name);
      } else {
        controller.switchChannel(name);
      }
    }

    // Tapping a mention opens the full context menu for the resolved user.
    void onMentionTap(MentionNode node) {
      final users = ref.read(usersProvider);
      // Re-attach the `#suffix` so suffixed mentions resolve to the right pubkey.
      final raw =
          node.suffix != null ? '${node.base}#${node.suffix}' : node.base;
      final t = resolveTarget(raw, users);
      if (t == null) return; // unknown mention → inert (PWA: no pubkey → no-op)
      final app = ref.read(appStateProvider);
      ContextMenuPanel.show(
        context,
        // Full target without message content, so only person-level actions show.
        target: CtxTarget(
          pubkey: t.pubkey,
          nym: stripPubkeySuffix(t.nym),
          isSelf: t.pubkey == app.selfPubkey,
        ),
      );
    }

    // Read-more: the char threshold only flags long bodies (quote lines excluded); the collapse is height-based.
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
        // Leading/trailing media, code, quote or heading blocks keep their 10px margin against the bubble edges.
        if (blocks.isNotEmpty && _blockEdgeMargin(blocks.first) > 0)
          SizedBox(height: _blockEdgeMargin(blocks.first)),
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) SizedBox(height: markdownBlockGap(blocks[i - 1], blocks[i])),
          _block(context, c, blocks[i], color, size,
              emojiOnly: emojiOnly,
              onChannelRef: onChannelRef,
              onMentionTap: onMentionTap),
        ],
        if (blocks.isNotEmpty && _blockEdgeMargin(blocks.last) > 0)
          SizedBox(height: _blockEdgeMargin(blocks.last)),
      ],
    );

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Link previews sit outside the collapsible body.
        if (replyText.length > threshold)
          _Collapsible(collapseKey: hostMessageId, child: body)
        else
          body,
        for (final url in previewUrls) LinkPreviewCard(url: url),
        // Reference cards also sit outside the collapsible body.
        for (final token in nostrRefs)
          NostrRefCard(
            token: token,
            blurImages: blurImages,
            onJump: (id) => _jumpToEvent(ref, id),
            onOpenProfile: (pubkey, nym) =>
                _openProfileCtx(context, ref, pubkey, nym),
          ),
      ],
    );
    final controller = spoilers;
    if (controller == null) return column;
    return SpoilerRevealScope(controller: controller, child: column);
  }

  /// Deduplicated bare http(s) links for previews, skipping inline-media URLs.
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
          case UnderlineNode(:final children):
            visitInlines(children);
          default:
            break;
        }
      }
    }

    void visitList(ListBlock list) {
      for (final item in list.items) {
        visitInlines(item.inlines);
        for (final child in item.children) {
          visitList(child);
        }
      }
    }

    void visitBlock(FormatBlock b) {
      switch (b) {
        case ParagraphBlock(:final inlines):
          visitInlines(inlines);
        case HeadingBlock(:final inlines):
          visitInlines(inlines);
        case SubtextBlock(:final inlines):
          visitInlines(inlines);
        case ListBlock():
          visitList(b);
        case QuoteBlock(:final children):
          for (final ch in children) {
            visitBlock(ch);
          }
        case CodeBlock():
        case MediaBlock():
        case AudioBlock():
          break;
      }
    }

    for (final b in blocks) {
      visitBlock(b);
    }
    return out;
  }

  /// Finds whichever conversation holds the referenced event, switches to it, and scrolls there.
  void _jumpToEvent(WidgetRef ref, String eventId) {
    final key = scrollKey ?? ref.read(appStateProvider).view.storageKey;
    final flash = ref.read(flashedMessageProvider.notifier);
    if (ref.read(messageListScrollerProvider(key)).scrollToMessage(eventId)) {
      flash.flash(eventId);
      return;
    }

    final app = ref.read(appStateProvider.notifier);
    void reportUnavailable() =>
        showToast(tr('Original message is not available'));

    final target = conversationHoldingEvent(ref.read(appStateProvider), eventId);
    if (target == null) {
      reportUnavailable();
      return;
    }

    // Leave the thread panel so the conversation's own list rebinds.
    if (ref.read(activeThreadProvider) != null) {
      ref.read(activeThreadProvider.notifier).state = null;
    }
    if (target != ref.read(appStateProvider).view) app.switchView(target);
    // Switching remounts the list, so the first frame can still miss.
    _jumpWhenBound(
      ref.read(messageListScrollerProvider(target.storageKey)),
      flash,
      eventId,
      onGiveUp: reportUnavailable,
    );
  }

  /// Opens the same context menu a tapped mention would.
  void _openProfileCtx(
      BuildContext context, WidgetRef ref, String pubkey, String nym) {
    if (pubkey.isEmpty) return;
    final app = ref.read(appStateProvider);
    ContextMenuPanel.show(
      context,
      target: CtxTarget(
        pubkey: pubkey,
        nym: pickDisplayNym(app.users[pubkey]?.nym, nym),
        isSelf: pubkey == app.selfPubkey,
      ),
    );
  }

  /// Distinct NIP-19 references, capped so a message can't open dozens of queries.
  List<String> _collectNostrRefs(List<FormatBlock> blocks) {
    final seen = <String>{};
    final out = <String>[];
    void visitInlines(List<InlineNode> inlines) {
      for (final n in inlines) {
        if (out.length >= 4) return;
        switch (n) {
          case NostrRefNode(:final token):
            if (seen.add(token)) out.add(token);
          case BoldNode(:final children):
            visitInlines(children);
          case ItalicNode(:final children):
            visitInlines(children);
          case StrikeNode(:final children):
            visitInlines(children);
          case UnderlineNode(:final children):
            visitInlines(children);
          default:
            break;
        }
      }
    }

    void visitList(ListBlock list) {
      for (final item in list.items) {
        visitInlines(item.inlines);
        for (final child in item.children) {
          visitList(child);
        }
      }
    }

    void visitBlock(FormatBlock b) {
      switch (b) {
        case ParagraphBlock(:final inlines):
          visitInlines(inlines);
        case HeadingBlock(:final inlines):
          visitInlines(inlines);
        case SubtextBlock(:final inlines):
          visitInlines(inlines);
        case ListBlock():
          visitList(b);
        case QuoteBlock(:final children):
          for (final ch in children) {
            visitBlock(ch);
          }
        case CodeBlock():
        case MediaBlock():
        case AudioBlock():
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
          blurMedia: blurImages,
          emojiOnly: emojiOnly,
          shadows: glyphShadows,
          monospace: monospace,
          onChannelRef: onChannelRef,
          onMentionTap: onMentionTap,
        );
      case HeadingBlock(:final level, :final inlines):
        final scale = level == 1 ? 1.5 : (level == 2 ? 1.3 : 1.15);
        return _RichInline(
          inlines: inlines,
          color: c.primary,
          size: size * scale,
          blurMedia: blurImages,
          weight: FontWeight.w700,
          onChannelRef: onChannelRef,
          onMentionTap: onMentionTap,
        );
      case SubtextBlock(:final inlines):
        return _RichInline(
          inlines: inlines,
          color: c.textDim,
          size: size * 0.8,
          blurMedia: blurImages,
          shadows: glyphShadows,
          monospace: monospace,
          onChannelRef: onChannelRef,
          onMentionTap: onMentionTap,
        );
      case ListBlock():
        return _ListView(
          block: block,
          color: color,
          size: size,
          blurMedia: blurImages,
          shadows: glyphShadows,
          monospace: monospace,
          onChannelRef: onChannelRef,
          onMentionTap: onMentionTap,
        );
      case CodeBlock(:final code, :final lang):
        return _CodeBox(code: code, lang: lang, size: size);
      case QuoteBlock():
        // Top-level blockquotes get their own read-more and jump to the quoted source on tap.
        return _QuoteBox(
          block: block,
          color: color,
          size: size,
          topLevel: true,
          hostMessageId: hostMessageId,
          scrollKey: scrollKey,
        );
      case MediaBlock(:final items):
        return _MediaGallery(items: items, blur: blurImages);
      case AudioBlock():
        return audioOrMediaNote(block);
    }
  }
}

/// Media, code, quote and heading blocks have a 10px margin; text lines keep a 4px gap.
double _blockMargin(FormatBlock block) => switch (block) {
      MediaBlock() ||
      AudioBlock() ||
      CodeBlock() ||
      QuoteBlock() ||
      ListBlock() ||
      HeadingBlock() =>
        10,
      ParagraphBlock() || SubtextBlock() => 4,
    };

/// Sibling margins collapse to the larger, so pairs involving a block sit 10px apart.
double markdownBlockGap(FormatBlock a, FormatBlock b) {
  bool textual(FormatBlock x) => x is ParagraphBlock || x is SubtextBlock;
  if ((a is SubtextBlock || b is SubtextBlock) && textual(a) && textual(b)) {
    return 0;
  }
  final ma = _blockMargin(a);
  final mb = _blockMargin(b);
  return ma > mb ? ma : mb;
}

/// Only real 10px-margin blocks keep space against the body edges; text sits flush.
double _blockEdgeMargin(FormatBlock block) => switch (block) {
      MediaBlock() ||
      AudioBlock() ||
      CodeBlock() ||
      QuoteBlock() ||
      ListBlock() ||
      HeadingBlock() =>
        10,
      ParagraphBlock() || SubtextBlock() => 0,
    };

/// One emoji unit: flag pair, keycap, or pictographic glyph with optional VS, skin tone, ZWJ and tags.
const String _emojiUnit =
    r'(?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]\u{FE0F}?\u{20E3})|'
    r'(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
    r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?'
    r'(?:\u{200D}(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
    r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?)*)'
    r'(?:[\u{E0020}-\u{E007E}]+\u{E007F})?';

final RegExp _rxEmojiOnly = RegExp('^(?:$_emojiUnit){1,6}\$', unicode: true);
final RegExp _rxWhitespace = RegExp(r'\s', unicode: true);

/// True for 1–6 emoji with optional whitespace and nothing else.
bool isEmojiOnly(String content) {
  if (content.isEmpty) return false;
  final stripped = content.replaceAll(_rxWhitespace, '');
  if (stripped.isEmpty) return false;
  return _rxEmojiOnly.hasMatch(stripped);
}

final RegExp _rxCustomEmojiToken = RegExp(r'^:([a-zA-Z0-9_]+):$');

/// True for 1–6 whitespace-separated known custom shortcodes.
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

/// Inline nodes as one [Text.rich], with [WidgetSpan]s for chips, emoji and mentions.
class _RichInline extends StatefulWidget {
  const _RichInline({
    required this.inlines,
    required this.color,
    required this.size,
    this.weight,
    this.emojiOnly = false,
    this.shadows,
    this.monospace = false,
    this.onChannelRef,
    this.onMentionTap,
    this.blurMedia = false,
  });

  final List<InlineNode> inlines;
  final Color color;
  final double size;
  final FontWeight? weight;

  final bool blurMedia;

  /// 1–6 emoji only: enlarge emoji.
  final bool emojiOnly;

  /// Per-style glyph shadows.
  final List<Shadow>? shadows;

  /// Monospace glyphs (CRT).
  final bool monospace;

  /// Switches channel when a reference or link is tapped.
  final void Function(String name, bool isGeohash)? onChannelRef;

  /// Opens the mentioned user's context menu.
  final void Function(MentionNode node)? onMentionTap;

  @override
  State<_RichInline> createState() => _RichInlineState();
}

class _RichInlineState extends State<_RichInline> {
  final SpoilerRevealController _local = SpoilerRevealController();
  SpoilerRevealController? _scope;
  int _spoilerSeq = 0;
  final List<Object> _hiddenKeys = [];
  bool _focused = false;
  Object? _hoverKey;

  double get size => widget.size;
  bool get emojiOnly => widget.emojiOnly;
  void Function(String name, bool isGeohash)? get onChannelRef =>
      widget.onChannelRef;
  void Function(MentionNode node)? get onMentionTap => widget.onMentionTap;

  SpoilerRevealController get _reveals => _scope ?? _local;

  void _onRevealsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _local.addListener(_onRevealsChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = SpoilerRevealScope.maybeOf(context);
    if (!identical(scope, _scope)) {
      _scope?.removeListener(_onRevealsChanged);
      _scope = scope;
      _scope?.addListener(_onRevealsChanged);
    }
  }

  @override
  void dispose() {
    _scope?.removeListener(_onRevealsChanged);
    _local.removeListener(_onRevealsChanged);
    _local.dispose();
    super.dispose();
  }

  Object _spoilerKey(int index) => (identityHashCode(widget.inlines), index);

  void _revealNext() {
    if (_hiddenKeys.isEmpty) return;
    _reveals.reveal(_hiddenKeys.first);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final base = TextStyle(
      color: widget.color,
      fontSize: widget.size,
      fontWeight: widget.weight,
      height: 1.4,
      shadows: widget.shadows,
      // Sans primary sets the line strut; the emoji fallback resolves emoji per glyph. Mono bodies skip it.
      fontFamily: widget.monospace ? kMonoFont : kSansFont,
      fontFamilyFallback: widget.monospace ? null : kEmojiFontFallback,
    );
    _spoilerSeq = 0;
    _hiddenKeys.clear();
    final text = Text.rich(
      TextSpan(
        children: [
          for (final n in widget.inlines) _span(context, c, n, base),
        ],
      ),
    );
    if (_hiddenKeys.isEmpty) return text;
    return FocusableActionDetector(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          _revealNext();
          return null;
        }),
      },
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: _focused ? Border.all(color: c.primary, width: 2) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: text,
      ),
    );
  }

  InlineSpan _hiddenSpoiler(NymColors c, List<InlineNode> children,
      TextStyle base, Object key, VoidCallback onReveal) {
    final hovered = _hoverKey == key;
    final fill = c.isLight
        ? (hovered ? const Color(0xFF8A8A8A) : const Color(0xFF9A9A9A))
        : (hovered ? c.textDim.withValues(alpha: 0.85) : c.textDim);
    final hidden = base.copyWith(
      color: const Color(0x00000000),
      backgroundColor: fill,
      decorationColor: const Color(0x00000000),
      shadows: const <Shadow>[],
    );
    final spans = <InlineSpan>[];
    var labeled = false;
    void addText(String text) {
      if (text.isEmpty) return;
      spans.add(TextSpan(
        text: text.replaceAll(_rxHiddenGlyph, '\u2003'),
        style: hidden,
        recognizer: _SpoilerTap(onReveal),
        mouseCursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hoverKey = key),
        onExit: (_) {
          if (_hoverKey == key) setState(() => _hoverKey = null);
        },
        semanticsLabel: labeled ? '' : tr('Spoiler, tap to reveal'),
      ));
      labeled = true;
    }

    Widget blurred(Widget child) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onReveal,
          child: ExcludeSemantics(
            child: IgnorePointer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: child,
                ),
              ),
            ),
          ),
        );

    void walk(List<InlineNode> nodes) {
      final buf = StringBuffer();
      void flushText() {
        addText(buf.toString());
        buf.clear();
      }

      for (final n in nodes) {
        switch (n) {
          case InlineGalleryNode(:final items):
            flushText();
            spans.add(WidgetSpan(
                child: blurred(_MediaGallery(items: items))));
          case AudioInlineNode(:final block):
            flushText();
            spans.add(WidgetSpan(
                child: blurred(
                    audioOrMediaNote(block))));
          case BoldNode(:final children):
          case ItalicNode(:final children):
          case UnderlineNode(:final children):
          case StrikeNode(:final children):
          case SpoilerNode(:final children):
            flushText();
            walk(children);
          case TimestampNode(:final seconds, :final style):
            buf.write(formatDiscordTimestamp(seconds, style));
          default:
            _appendInlineText(buf, n);
        }
      }
      flushText();
    }

    walk(children);
    if (spans.isEmpty) addText(' ');
    return TextSpan(children: spans);
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
            _span(
                context,
                c,
                ch,
                base.merge(TextStyle(
                    fontWeight: FontWeight.w700, color: c.textBright))),
        ]);
      case ItalicNode(:final children):
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch,
                base.merge(const TextStyle(fontStyle: FontStyle.italic))),
        ]);
      case StrikeNode(:final children):
        return TextSpan(children: [
          for (final ch in children)
            _span(
                context,
                c,
                ch,
                base.merge(TextStyle(
                    decoration: TextDecoration.lineThrough, color: c.textDim))),
        ]);
      case UnderlineNode(:final children):
        final underlined = base.merge(TextStyle(
            decoration: TextDecoration.combine([
          if (base.decoration != null) base.decoration!,
          TextDecoration.underline,
        ])));
        return TextSpan(children: [
          for (final ch in children) _span(context, c, ch, underlined),
        ]);
      case SpoilerNode(:final children):
        final key = _spoilerKey(_spoilerSeq++);
        if (_reveals.isRevealed(key)) {
          final shown = base.merge(TextStyle(
              backgroundColor: c.isLight
                  ? Colors.black.withValues(alpha: 0.06)
                  : c.text.withValues(alpha: 0.08)));
          return TextSpan(children: [
            for (final ch in children) _span(context, c, ch, shown),
          ]);
        }
        _hiddenKeys.add(key);
        return _hiddenSpoiler(
            c, children, base, key, () => _reveals.reveal(key));
      case InlineGalleryNode(:final items):
        return WidgetSpan(
          child: _MediaGallery(items: items, blur: widget.blurMedia),
        );
      case AudioInlineNode(:final block):
        return WidgetSpan(
          child: audioOrMediaNote(block),
        );
      case TimestampNode(:final seconds, :final style):
        return WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: TimestampChip(seconds: seconds, style: style, textStyle: base),
        );
      case InlineCodeNode(:final code):
        // Inline code as a padded rounded pill in [kMonoFont]; light mode flips the fill.
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
        // Emoji inherit 1em; only emoji-only messages enlarge them.
        return TextSpan(
          text: unicode,
          style:
              base.merge(TextStyle(fontSize: size * (emojiOnly ? 2.5 : 1.0))),
        );
      case MentionNode():
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _MentionChip(
            node: node,
            size: size,
            onTap: onMentionTap,
          ),
        );
      case ChannelRefNode(:final name, :final isGeohash):
        // Underlined in the body color, with no fill.
        return TextSpan(
          text: '#$name',
          style:
              base.merge(const TextStyle(decoration: TextDecoration.underline)),
          recognizer: onChannelRef == null
              ? null
              : _ChannelRefTap(name, isGeohash, onChannelRef!),
        );
      case CustomEmojiNode(:final url, :final shortcode):
        // 1.75em inline, 2.75em when emoji-only.
        final side = emojiOnly ? size * 2.75 : size * 1.75;
        // SVG-aware; an undecodable emoji falls back to its `:shortcode:` text.
        final image = InlineNetworkImage(
          url: proxiedMedia(url, emoji: true),
          width: side,
          height: side,
          fit: BoxFit.contain,
          // Disk-cached: body emoji are sparse, unlike the picker grid.
          retryOnError: true,
          errorChild: Text(':$shortcode:', style: base),
        );
        // Bottom 0.375em below the baseline; emoji-only centers instead.
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
        // Plain underlined secondary text with the full URL label.
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
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _InviteChip(name: name, token: token, size: size),
        );
      case CallLinkChip(:final name, :final video, :final token):
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _CallLinkChipView(
              name: name, video: video, token: token, size: size),
        );
      case NostrRefNode(:final token, :final raw):
        // Bare hex keeps its own text; 64 hex chars aren't always an event id.
        if (raw) return TextSpan(text: token, style: base);
        return TextSpan(
          text: token.length > 20
              ? '${token.substring(0, 12)}…${token.substring(token.length - 6)}'
              : token,
          style: base.merge(TextStyle(
            color: c.primary,
            fontFamily: 'monospace',
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dotted,
          )),
        );
      default:
        // Flattened to blocks before this point.
        return const TextSpan(text: '');
    }
  }
}

final RegExp _rxHiddenGlyph = RegExp(
    r'[\u{1F000}-\u{1FAFF}\u{2190}-\u{21FF}\u{2300}-\u{23FF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}\u{20E3}]',
    unicode: true);

class _SpoilerTap extends TapGestureRecognizer {
  _SpoilerTap(VoidCallback onReveal) {
    onTap = onReveal;
  }
}

class SpoilerRevealController extends ChangeNotifier {
  final Set<Object> _revealed = <Object>{};

  bool isRevealed(Object key) => _revealed.contains(key);

  void reveal(Object key) {
    if (_revealed.add(key)) notifyListeners();
  }
}

class SpoilerRevealScope extends InheritedWidget {
  const SpoilerRevealScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final SpoilerRevealController controller;

  static SpoilerRevealController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SpoilerRevealScope>()
      ?.controller;

  @override
  bool updateShouldNotify(SpoilerRevealScope oldWidget) =>
      !identical(oldWidget.controller, controller);
}

class TimestampChip extends StatefulWidget {
  const TimestampChip({
    super.key,
    required this.seconds,
    required this.style,
    required this.textStyle,
  });

  final int seconds;
  final String style;
  final TextStyle textStyle;

  @override
  State<TimestampChip> createState() => _TimestampChipState();
}

class _TimestampChipState extends State<TimestampChip> {
  final GlobalKey<NymTooltipState> _tooltip = GlobalKey<NymTooltipState>();
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    Widget chip() => Container(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: c.isLight
                ? Colors.black.withValues(alpha: 0.06)
                : c.text.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(4),
            border: _focused ? Border.all(color: c.primary, width: 2) : null,
          ),
          child: Text(
            formatDiscordTimestamp(widget.seconds, widget.style),
            style: widget.textStyle,
            softWrap: false,
          ),
        );
    return FocusableActionDetector(
      onShowFocusHighlight: (v) {
        setState(() => _focused = v);
        if (v) _tooltip.currentState?.ensureTooltipVisible();
      },
      child: NymTooltip(
        key: _tooltip,
        message: formatDiscordTimestamp(widget.seconds, 'F'),
        child: widget.style == 'R'
            ? ListenableBuilder(
                listenable: RelativeTimeTicker.instance,
                builder: (context, _) => chip(),
              )
            : chip(),
      ),
    );
  }
}

class _ListView extends StatelessWidget {
  const _ListView({
    required this.block,
    required this.color,
    required this.size,
    this.nested = false,
    this.shadows,
    this.monospace = false,
    this.onChannelRef,
    this.onMentionTap,
    this.blurMedia = false,
  });

  final ListBlock block;
  final bool blurMedia;
  final Color color;
  final double size;
  final bool nested;
  final List<Shadow>? shadows;
  final bool monospace;
  final void Function(String name, bool isGeohash)? onChannelRef;
  final void Function(MentionNode node)? onMentionTap;

  @override
  Widget build(BuildContext context) {
    final markerStyle = TextStyle(
      color: color,
      fontSize: size,
      height: 1.4,
      shadows: shadows,
      fontFamily: monospace ? kMonoFont : kSansFont,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < block.items.length; i++)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 20),
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: !block.ordered && nested
                      ? HollowBullet(
                          key: const ValueKey('md-nested-bullet'),
                          color: markerStyle.color ?? const Color(0xFF888888),
                          fontSize: markerStyle.fontSize ?? 14,
                          lineHeight: markerStyle.height ?? 1.0,
                        )
                      : Text(
                          block.ordered ? '${block.start + i}.' : '\u2022',
                          textAlign: TextAlign.right,
                          style: markerStyle,
                        ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RichInline(
                      inlines: block.items[i].inlines,
                      color: color,
                      size: size,
                      shadows: shadows,
                      monospace: monospace,
                      onChannelRef: onChannelRef,
                      onMentionTap: onMentionTap,
                      blurMedia: blurMedia,
                    ),
                    for (final child in block.items[i].children)
                      _ListView(
                        block: child,
                        color: color,
                        size: size,
                        nested: true,
                        blurMedia: blurMedia,
                        shadows: shadows,
                        monospace: monospace,
                        onChannelRef: onChannelRef,
                        onMentionTap: onMentionTap,
                      ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// Opens a URL via url_launcher.
class _LinkTap extends TapGestureRecognizer {
  _LinkTap(String url) {
    onTap = () => launchSafeUrl(url);
  }
}

class _MentionChip extends ConsumerWidget {
  const _MentionChip({
    required this.node,
    required this.size,
    this.onTap,
  });
  final MentionNode node;
  final double size;

  /// Opens the mentioned user's context menu; null is inert.
  final void Function(MentionNode node)? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    // Secondary color at body weight.
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

    // Resolve the mention to decorate it with avatar and flair; unresolved mentions render plain.
    final users = ref.watch(usersProvider);
    final raw = node.suffix != null ? '${node.base}#${node.suffix}' : node.base;
    final t = resolveTarget(raw, users);
    Widget chip = text;
    if (t != null) {
      chip = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          NymAvatar(
              seed: t.pubkey,
              size: size,
              imageUrl: users[t.pubkey]?.profile?.picture),
          const SizedBox(width: 3),
          text,
          // Flair and supporter badge, hidden when the user has none.
          CosmeticNymBadges(
            cosmetics: ref.watch(userCosmeticsProvider(t.pubkey)),
            flairSize: size,
            supporterHeight: size,
          ),
        ],
      );
    }

    if (onTap == null) return chip;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap!(node),
      child: chip,
    );
  }
}

/// Switches to the tapped `#channel` (geohash or named).
class _ChannelRefTap extends TapGestureRecognizer {
  _ChannelRefTap(String name, bool isGeohash,
      void Function(String name, bool isGeohash) cb) {
    onTap = () => cb(name, isGeohash);
  }
}

/// Switches to the channel in an `app.nym.bar/#…` link (`g:<geohash>` or `c:<name>`).
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

/// Group invite chip; tapping confirms, then sends a join request to the link's sharer.
class _InviteChip extends ConsumerWidget {
  const _InviteChip(
      {required this.name, required this.token, required this.size});
  final String name;
  final String token;
  final double size;

  /// Decode the token, confirm, then hand off to the controller's join flow.
  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final parsed = parseGroupInvite(token);
    if (parsed == null) return;
    final controller = ref.read(nostrControllerProvider);
    final ok = await confirmGroupInviteJoin(context, parsed);
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
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          border: Border.all(color: c.secondary),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: size,
              height: size,
              child: CustomPaint(painter: _GroupIcoPainter(c.secondary)),
            ),
            SizedBox(width: size * 0.35),
            Flexible(
              child: Text(
                tr('Join {name}', {'name': name}),
                softWrap: true,
                style: TextStyle(color: c.secondary, fontSize: size),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallLinkChipView extends StatelessWidget {
  const _CallLinkChipView(
      {required this.name,
      required this.video,
      required this.token,
      required this.size});
  final String name;
  final bool video;
  final String token;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      key: const ValueKey('gtCallLinkChip'),
      onTap: () => joinCallLinkFlow(context, token),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          border: Border.all(color: c.secondary),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NymSvgIcon(GroupToolIcons.callLink, size: size, color: c.secondary),
            SizedBox(width: size * 0.35),
            Flexible(
              child: Text(
                '${video ? tr('Join video call') : tr('Join voice call')}: $name',
                softWrap: true,
                style: TextStyle(color: c.secondary, fontSize: size),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small multi-person outline glyph.
class _GroupIcoPainter extends CustomPainter {
  _GroupIcoPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Authored in a 24x24 box; scale to [size].
    final s = size.width / 24.0;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    canvas.drawCircle(Offset(9 * s, 8 * s), 3.2 * s, stroke);
    final body = Path()
      ..moveTo(3.5 * s, 19 * s)
      ..cubicTo(3.5 * s, 14.5 * s, 6 * s, 13 * s, 9 * s, 13 * s)
      ..cubicTo(12 * s, 13 * s, 14.5 * s, 14.5 * s, 14.5 * s, 19 * s);
    canvas.drawPath(body, stroke);
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

// Syntax highlighting for fenced code, a port of the PWA's tokenizer; unknown languages render plain.

/// Token classes, mirroring the PWA's `hl-*` spans.
enum _HlClass { none, comment, string, number, keyword, builtin, function, key }

/// One highlighted run of source [text] with its class.
class _HlTok {
  const _HlTok(this.text, this.cls);
  final String text;
  final _HlClass cls;
}

/// Per-language keyword sets; `ts` extends `js`, and `jsx`/`tsx` alias them.
const Map<String, List<String>> _kHlKeywords = {
  'js': [
    'async',
    'await',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'debugger',
    'default',
    'delete',
    'do',
    'else',
    'export',
    'extends',
    'finally',
    'for',
    'from',
    'function',
    'if',
    'import',
    'in',
    'instanceof',
    'let',
    'new',
    'null',
    'of',
    'return',
    'static',
    'super',
    'switch',
    'this',
    'throw',
    'true',
    'false',
    'try',
    'typeof',
    'undefined',
    'var',
    'void',
    'while',
    'with',
    'yield',
  ],
  'py': [
    'False',
    'None',
    'True',
    'and',
    'as',
    'assert',
    'async',
    'await',
    'break',
    'class',
    'continue',
    'def',
    'del',
    'elif',
    'else',
    'except',
    'finally',
    'for',
    'from',
    'global',
    'if',
    'import',
    'in',
    'is',
    'lambda',
    'nonlocal',
    'not',
    'or',
    'pass',
    'raise',
    'return',
    'try',
    'while',
    'with',
    'yield',
    'match',
    'case',
  ],
  'rs': [
    'as',
    'async',
    'await',
    'break',
    'const',
    'continue',
    'crate',
    'dyn',
    'else',
    'enum',
    'extern',
    'false',
    'fn',
    'for',
    'if',
    'impl',
    'in',
    'let',
    'loop',
    'match',
    'mod',
    'move',
    'mut',
    'pub',
    'ref',
    'return',
    'self',
    'Self',
    'static',
    'struct',
    'super',
    'trait',
    'true',
    'type',
    'unsafe',
    'use',
    'where',
    'while',
    'yield',
    'box',
  ],
  'go': [
    'break',
    'case',
    'chan',
    'const',
    'continue',
    'default',
    'defer',
    'else',
    'fallthrough',
    'for',
    'func',
    'go',
    'goto',
    'if',
    'import',
    'interface',
    'map',
    'package',
    'range',
    'return',
    'select',
    'struct',
    'switch',
    'type',
    'var',
    'true',
    'false',
    'nil',
    'iota',
  ],
  'java': [
    'abstract',
    'assert',
    'boolean',
    'break',
    'byte',
    'case',
    'catch',
    'char',
    'class',
    'const',
    'continue',
    'default',
    'do',
    'double',
    'else',
    'enum',
    'extends',
    'final',
    'finally',
    'float',
    'for',
    'goto',
    'if',
    'implements',
    'import',
    'instanceof',
    'int',
    'interface',
    'long',
    'native',
    'new',
    'null',
    'package',
    'private',
    'protected',
    'public',
    'return',
    'short',
    'static',
    'strictfp',
    'super',
    'switch',
    'synchronized',
    'this',
    'throw',
    'throws',
    'transient',
    'try',
    'void',
    'volatile',
    'while',
    'true',
    'false',
  ],
  'c': [
    'auto',
    'break',
    'case',
    'char',
    'const',
    'continue',
    'default',
    'do',
    'double',
    'else',
    'enum',
    'extern',
    'float',
    'for',
    'goto',
    'if',
    'inline',
    'int',
    'long',
    'register',
    'restrict',
    'return',
    'short',
    'signed',
    'sizeof',
    'static',
    'struct',
    'switch',
    'typedef',
    'union',
    'unsigned',
    'void',
    'volatile',
    'while',
    '_Bool',
    '_Complex',
    '_Imaginary',
    'bool',
    'true',
    'false',
    'NULL',
    'nullptr',
  ],
  'cpp': [
    'alignas',
    'alignof',
    'and',
    'asm',
    'auto',
    'bool',
    'break',
    'case',
    'catch',
    'char',
    'class',
    'co_await',
    'co_return',
    'co_yield',
    'const',
    'constexpr',
    'const_cast',
    'continue',
    'decltype',
    'default',
    'delete',
    'do',
    'double',
    'dynamic_cast',
    'else',
    'enum',
    'explicit',
    'export',
    'extern',
    'false',
    'final',
    'float',
    'for',
    'friend',
    'goto',
    'if',
    'inline',
    'int',
    'long',
    'mutable',
    'namespace',
    'new',
    'noexcept',
    'not',
    'nullptr',
    'operator',
    'or',
    'override',
    'private',
    'protected',
    'public',
    'register',
    'reinterpret_cast',
    'return',
    'short',
    'signed',
    'sizeof',
    'static',
    'static_cast',
    'struct',
    'switch',
    'template',
    'this',
    'thread_local',
    'throw',
    'true',
    'try',
    'typedef',
    'typeid',
    'typename',
    'union',
    'unsigned',
    'using',
    'virtual',
    'void',
    'volatile',
    'while',
    'xor',
  ],
  'sh': [
    'if',
    'then',
    'else',
    'elif',
    'fi',
    'for',
    'in',
    'do',
    'done',
    'while',
    'until',
    'case',
    'esac',
    'function',
    'return',
    'break',
    'continue',
    'exit',
    'export',
    'local',
    'readonly',
    'set',
    'unset',
    'source',
    'alias',
    'declare',
    'typeset',
    'true',
    'false',
  ],
  'sql': [
    'SELECT',
    'FROM',
    'WHERE',
    'INSERT',
    'UPDATE',
    'DELETE',
    'CREATE',
    'DROP',
    'ALTER',
    'TABLE',
    'INDEX',
    'VIEW',
    'JOIN',
    'LEFT',
    'RIGHT',
    'INNER',
    'OUTER',
    'FULL',
    'ON',
    'AS',
    'AND',
    'OR',
    'NOT',
    'NULL',
    'IS',
    'IN',
    'LIKE',
    'BETWEEN',
    'GROUP',
    'BY',
    'ORDER',
    'HAVING',
    'LIMIT',
    'OFFSET',
    'UNION',
    'ALL',
    'DISTINCT',
    'INTO',
    'VALUES',
    'SET',
    'PRIMARY',
    'KEY',
    'FOREIGN',
    'REFERENCES',
    'DEFAULT',
    'UNIQUE',
    'CHECK',
    'CASE',
    'WHEN',
    'THEN',
    'ELSE',
    'END',
    'WITH',
    'RETURNING',
    'BEGIN',
    'COMMIT',
    'ROLLBACK',
    'TRANSACTION',
    'IF',
    'EXISTS',
    'TRUE',
    'FALSE',
  ],
  'ts': [
    // JS keywords plus the TS-only additions.
    'async',
    'await',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'debugger',
    'default',
    'delete',
    'do',
    'else',
    'export',
    'extends',
    'finally',
    'for',
    'from',
    'function',
    'if',
    'import',
    'in',
    'instanceof',
    'let',
    'new',
    'null',
    'of',
    'return',
    'static',
    'super',
    'switch',
    'this',
    'throw',
    'true',
    'false',
    'try',
    'typeof',
    'undefined',
    'var',
    'void',
    'while',
    'with',
    'yield',
    'any',
    'as',
    'boolean',
    'declare',
    'enum',
    'interface',
    'is',
    'keyof',
    'module',
    'namespace',
    'never',
    'number',
    'readonly',
    'satisfies',
    'string',
    'symbol',
    'type',
    'unique',
    'unknown',
    'infer',
    'public',
    'private',
    'protected',
    'abstract',
    'implements',
  ],
};

/// Per-language builtin identifier sets.
const Map<String, List<String>> _kHlBuiltins = {
  'js': [
    'console',
    'window',
    'document',
    'globalThis',
    'Math',
    'JSON',
    'Object',
    'Array',
    'String',
    'Number',
    'Boolean',
    'Date',
    'Map',
    'Set',
    'Promise',
    'RegExp',
    'Symbol',
    'BigInt',
    'Error',
    'fetch',
    'setTimeout',
    'setInterval',
    'clearTimeout',
    'clearInterval',
    'queueMicrotask',
    'structuredClone',
  ],
  'py': [
    'print',
    'len',
    'range',
    'int',
    'str',
    'float',
    'bool',
    'list',
    'dict',
    'tuple',
    'set',
    'frozenset',
    'bytes',
    'bytearray',
    'open',
    'input',
    'type',
    'isinstance',
    'enumerate',
    'zip',
    'map',
    'filter',
    'sorted',
    'sum',
    'min',
    'max',
    'abs',
    'round',
    'any',
    'all',
    'self',
    'cls',
    '__init__',
    '__name__',
    'super',
  ],
  'rs': [
    'Vec',
    'String',
    'Option',
    'Result',
    'Box',
    'Rc',
    'Arc',
    'HashMap',
    'HashSet',
    'BTreeMap',
    'Some',
    'None',
    'Ok',
    'Err',
    'println',
    'print',
    'format',
    'vec',
    'assert',
    'assert_eq',
    'assert_ne',
    'panic',
    'dbg',
    'todo',
    'unimplemented',
    'unreachable',
    'i8',
    'i16',
    'i32',
    'i64',
    'i128',
    'u8',
    'u16',
    'u32',
    'u64',
    'u128',
    'f32',
    'f64',
    'bool',
    'char',
    'str',
    'isize',
    'usize',
  ],
  'go': [
    'append',
    'cap',
    'close',
    'copy',
    'delete',
    'len',
    'make',
    'new',
    'panic',
    'print',
    'println',
    'recover',
    'complex',
    'imag',
    'real',
    'string',
    'int',
    'int8',
    'int16',
    'int32',
    'int64',
    'uint',
    'uint8',
    'uint16',
    'uint32',
    'uint64',
    'uintptr',
    'byte',
    'rune',
    'float32',
    'float64',
    'bool',
    'error',
  ],
  'ts': [
    'console',
    'window',
    'document',
    'globalThis',
    'Math',
    'JSON',
    'Object',
    'Array',
    'String',
    'Number',
    'Boolean',
    'Date',
    'Map',
    'Set',
    'Promise',
    'RegExp',
    'Symbol',
    'BigInt',
    'Error',
    'fetch',
    'Partial',
    'Readonly',
    'Record',
    'Pick',
    'Omit',
    'Required',
    'Exclude',
    'Extract',
    'ReturnType',
    'Parameters',
  ],
  'sh': [
    'echo',
    'cat',
    'grep',
    'sed',
    'awk',
    'cd',
    'ls',
    'rm',
    'cp',
    'mv',
    'mkdir',
    'rmdir',
    'touch',
    'chmod',
    'chown',
    'find',
    'xargs',
    'curl',
    'wget',
    'tar',
    'gzip',
    'gunzip',
    'zip',
    'unzip',
    'ps',
    'kill',
    'top',
    'df',
    'du',
    'wc',
    'sort',
    'uniq',
    'head',
    'tail',
    'tr',
    'tee',
    'printf',
    'read',
    'test',
    'sleep',
    'date',
    'env',
    'which',
  ],
  'c': [
    'printf',
    'scanf',
    'fprintf',
    'sprintf',
    'snprintf',
    'malloc',
    'calloc',
    'realloc',
    'free',
    'memcpy',
    'memset',
    'memcmp',
    'strlen',
    'strcpy',
    'strncpy',
    'strcmp',
    'strncmp',
    'strcat',
    'strncat',
    'strchr',
    'strstr',
    'fopen',
    'fclose',
    'fread',
    'fwrite',
    'fgets',
    'fputs',
    'exit',
    'abort',
    'assert',
    'sizeof',
    'NULL',
    'stdin',
    'stdout',
    'stderr',
    'std',
    'cout',
    'cin',
    'cerr',
    'endl',
    'vector',
    'string',
    'map',
    'unordered_map',
    'set',
    'unordered_set',
    'pair',
    'make_pair',
    'shared_ptr',
    'unique_ptr',
  ],
};

/// Language aliases.
const Map<String, String> _kHlLangAlias = {
  'javascript': 'js',
  'node': 'js',
  'nodejs': 'js',
  'typescript': 'ts',
  'python': 'py',
  'python3': 'py',
  'rust': 'rs',
  'golang': 'go',
  'bash': 'sh',
  'shell': 'sh',
  'zsh': 'sh',
  'sh': 'sh',
  'c++': 'cpp',
  'cxx': 'cpp',
  'objective-c': 'c',
  'objc': 'c',
  'html': 'xml',
  'svg': 'xml',
  'xhtml': 'xml',
  'yml': 'yaml',
};

/// Canonical lexer key for a fenced-code language hint, or null without a highlighter.
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

/// Tokenizes [code] for [lang]; unknown languages yield a single plain run.
List<_HlTok> _highlightCode(String code, String? lang) {
  final l = _normalizeHlLang(lang);
  if (l == null) return [_HlTok(code, _HlClass.none)];
  if (l == 'json') return _highlightJsonLike(code);
  if (l == 'xml') return _highlightXml(code);
  if (l == 'css') return _highlightCss(code);
  return _highlightGeneric(code, l);
}

final RegExp _rxHlNum = RegExp(r'^-?\d');

List<_HlTok> _highlightJsonLike(String src) {
  final out = <_HlTok>[];
  final re = RegExp(
      r'"(?:\\.|[^"\\])*"|true|false|null|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[{}\[\],:]|\s+|[^\s{}\[\],:"]+');
  for (final m in re.allMatches(src)) {
    final t = m[0]!;
    if (t.startsWith('"')) {
      // A string followed by `:` is an object key.
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
        RegExp(r':\s*$').hasMatch(src.substring(
            m.start, (m.start + t.length + 4).clamp(0, src.length)))) {
      // A property name, tagged builtin.
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

/// Main char-walk lexer: comments, strings, numbers, identifiers.
List<_HlTok> _highlightGeneric(String src, String lang) {
  final kws = (_kHlKeywords[lang] ?? const <String>[]).toSet();
  final builtins = (_kHlBuiltins[lang] ?? const <String>[]).toSet();
  final isShell = lang == 'sh';
  final lineComment =
      (lang == 'py' || lang == 'sh' || lang == 'yaml' || lang == 'rb')
          ? RegExp(r'^#.*')
          : RegExp(r'^\/\/.*');
  final RegExp? blockComment =
      (lang == 'py') ? null : RegExp(r'^\/\*[\s\S]*?\*\/');
  final RegExp? pyDocstring = (lang == 'py')
      ? RegExp(r'''^("""[\s\S]*?"""|\x27\x27\x27[\s\S]*?\x27\x27\x27)''')
      : null;

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

/// Token colors; `none` uses the base text color.
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

/// Monospace code box with optional language label and copy button.
class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.code, required this.lang, required this.size});
  final String code;
  final String? lang;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Unknown languages render as a single plain run at full base size in [kMonoFont].
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
              fontStyle: tok.cls == _HlClass.comment
                  ? FontStyle.italic
                  : FontStyle.normal,
              fontWeight: tok.cls == _HlClass.keyword
                  ? FontWeight.w600
                  : FontWeight.normal,
            ),
          ),
      ],
    );
    // A 22px strip above the box hosts the language label and Copy; the box has its own 12px padding.
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
        Positioned(
          top: 6,
          right: 6,
          child: _CodeCopyButton(code: code, size: size),
        ),
      ],
    );
  }
}

/// Copies [code] and shows "Copied!" for 1500ms.
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
    // Not cancelled on re-tap, matching the PWA's stacked timeouts; `mounted` guards disposal.
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
          _copied ? tr('Copied!') : tr('Copy'),
          style: TextStyle(color: c.primary, fontSize: widget.size * 0.75),
        ),
      ),
    );
  }
}

/// Read-more threshold: 400 chars at ≤768px, else 600; only flags a candidate.
int truncateThreshold(BuildContext context) =>
    MediaQuery.of(context).size.width <= 768 ? 400 : 600;

/// Rendered text length of a quote (author plus text; images count zero), to flag long quotes.
int _quoteTextLength(QuoteBlock block) {
  var n = block.author != null ? block.author!.length + 1 : 0; // header + ':'
  for (final child in block.children) {
    n += _blockTextLength(child);
  }
  return n;
}

Iterable<List<InlineNode>> _listInlines(ListBlock list) sync* {
  for (final item in list.items) {
    yield item.inlines;
    for (final child in item.children) {
      yield* _listInlines(child);
    }
  }
}

int _blockTextLength(FormatBlock block) {
  switch (block) {
    case ParagraphBlock(:final inlines):
    case HeadingBlock(:final inlines):
    case SubtextBlock(:final inlines):
      var n = 0;
      for (final node in inlines) {
        n += _inlineTextLength(node);
      }
      return n;
    case ListBlock():
      var n = 0;
      for (final inlines in _listInlines(block)) {
        for (final node in inlines) {
          n += _inlineTextLength(node);
        }
      }
      return n;
    case CodeBlock(:final code):
      return code.length;
    case QuoteBlock():
      return _quoteTextLength(block);
    case MediaBlock():
    case AudioBlock():
      return 0;
  }
}

int _inlineTextLength(InlineNode node) {
  switch (node) {
    case TextSpanNode(:final text):
      return text.length;
    case BoldNode(:final children):
    case ItalicNode(:final children):
    case StrikeNode(:final children):
    case UnderlineNode(:final children):
    case SpoilerNode(:final children):
      var n = 0;
      for (final ch in children) {
        n += _inlineTextLength(ch);
      }
      return n;
    case TimestampNode(:final seconds, :final style):
      return formatDiscordTimestamp(seconds, style).length;
    case InlineCodeNode(:final code):
      return code.length;
    case LinkNode(:final url):
      return url.length;
    case EmojiNode(:final unicode):
      return unicode.length;
    case MentionNode(:final base, :final suffix):
      return base.length + (suffix != null ? suffix.length + 1 : 0);
    case ChannelRefNode(:final name):
      return name.length + 1;
    case ChannelLinkChip(:final label):
      return label.length;
    case NostrRefNode(:final token):
      return token.length;
    case CustomEmojiNode():
    case GroupInviteChip():
      return 0;
    default:
      // Flattened before render; no text either way.
      return 0;
  }
}

// Quote-source matcher: finds the best-matching loaded message for a tapped quote.

final RegExp _rxQuoteSuffix = RegExp(r'#([0-9a-f]{4})$', caseSensitive: false);
final RegExp _rxWs = RegExp(r'\s+');

/// Whitespace-collapsed text of a quote's children, excluding the author and images.
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
    case SubtextBlock(:final inlines):
      for (final node in inlines) {
        _appendInlineText(buf, node);
      }
      buf.write(' ');
    case ListBlock():
      for (final inlines in _listInlines(block)) {
        for (final node in inlines) {
          _appendInlineText(buf, node);
        }
        buf.write(' ');
      }
    case CodeBlock(:final code):
      buf
        ..write(code)
        ..write(' ');
    case QuoteBlock():
      // A nested quote's author and body count toward the outer text.
      if (block.author != null) {
        buf
          ..write(block.author)
          ..write(': ');
      }
      for (final child in block.children) {
        _appendBlockText(buf, child);
      }
    case MediaBlock():
    case AudioBlock():
      break;
  }
}

void _appendInlineText(StringBuffer buf, InlineNode node) {
  switch (node) {
    case TextSpanNode(:final text):
      buf.write(text);
    case BoldNode(:final children):
    case ItalicNode(:final children):
    case StrikeNode(:final children):
    case UnderlineNode(:final children):
    case SpoilerNode(:final children):
      for (final ch in children) {
        _appendInlineText(buf, ch);
      }
    case TimestampNode(:final seconds, :final style, :final raw):
      buf.write(raw.isNotEmpty ? raw : '<t:$seconds:$style>');
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
    case NostrRefNode(:final token):
      buf.write(token);
    case CustomEmojiNode():
    case GroupInviteChip():
      break;
    default:
      break;
  }
}

/// Non-`>` lines joined and collapsed, so re-quoting replies don't shadow the original.
String _stripQuoteLines(String raw) => raw
    .split(RegExp(r'\r?\n'))
    .where((l) => !l.startsWith('>'))
    .join(' ')
    .replaceAll(_rxWs, ' ')
    .trim();

/// Letters and digits only, unicode-aware, so rendered and raw text normalize the same.
final RegExp _rxLooseStrip = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
String _loose(String s) => s.toLowerCase().replaceAll(_rxLooseStrip, '');

/// Scores exact/contains/prefix on literal text, then lower tiers on normalized text, since the rendered quote drops markup.
int _scoreHaystack(String haystack, String needle) {
  if (haystack.isEmpty) return 0;
  if (haystack == needle) return 1000;
  if (haystack.contains(needle)) return 500;
  if (needle.length > 20 &&
      haystack.contains(needle.substring(0, 80.clamp(0, needle.length)))) {
    return 250;
  }
  final looseNeedle = _loose(needle);
  final looseHay = _loose(haystack);
  if (looseNeedle.isEmpty || looseHay.isEmpty) return 0;
  if (looseHay == looseNeedle) return 900;
  if (looseNeedle.length >= 8 && looseHay.contains(looseNeedle)) return 400;
  if (looseNeedle.length >= 20 &&
      looseHay.contains(looseNeedle.substring(0, 60.clamp(0, looseNeedle.length)))) {
    return 200;
  }
  return 0;
}

/// Finds the message a quote points at, or null when nothing scores above 0.
Message? resolveQuotedMessage(
  QuoteBlock block,
  List<Message> messages, {
  String? hostMessageId,
}) {
  // Split a trailing `#xxxx` suffix from the author's base nym.
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
    // A recorded suffix is the identity; the nym spelling needn't match.
    if (quotedSuffix != null) return suffix == quotedSuffix;
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
    final score =
        _scoreHaystack(replyOnly.isNotEmpty ? replyOnly : raw, needle);
    if (score > bestScore) {
      bestScore = score;
      best = m;
    }
  }
  return bestScore > 0 ? best : null;
}

/// Conversation holding [eventId], or null when this client has no copy.
ChatView? conversationHoldingEvent(AppState app, String eventId) {
  if (eventId.isEmpty) return null;
  for (final entry in app.messages.entries) {
    final holds =
        entry.value.any((m) => m.id == eventId || m.nymMessageId == eventId);
    if (!holds) continue;
    final key = entry.key;
    if (key.startsWith('pm-')) return ChatView.pm(key.substring(3));
    if (key.startsWith('group-')) return ChatView.group(key.substring(6));
    if (key.startsWith('#')) return ChatView.channel(key.substring(1));
    return ChatView.channel(key);
  }
  return null;
}

/// Retries a jump for a few frames while a remounted list rebinds; [onGiveUp] fires when spent.
void _jumpWhenBound(
  MessageListScroller scroller,
  FlashedMessageNotifier flash,
  String id, {
  required VoidCallback onGiveUp,
  int attempts = 8,
}) {
  WidgetsBinding.instance
    ..addPostFrameCallback((_) {
      if (scroller.scrollToMessage(id)) {
        flash.flash(id);
      } else if (attempts > 1) {
        _jumpWhenBound(scroller, flash, id,
            onGiveUp: onGiveUp, attempts: attempts - 1);
      } else {
        onGiveUp();
      }
    })
    // Post-frame callbacks need a scheduled frame, or retries stall when idle.
    ..scheduleFrame();
}

/// Left-bordered quote block with an optional author header.
class _QuoteBox extends ConsumerWidget {
  const _QuoteBox({
    required this.block,
    required this.color,
    required this.size,
    this.topLevel = false,
    this.hostMessageId,
    this.scrollKey,
  });
  final QuoteBlock block;
  final Color color;
  final double size;

  /// Only direct children of the body are independently truncated.
  final bool topLevel;

  /// Host message id, excluded from the quoted-source search.
  final String? hostMessageId;

  /// The list's `storageKey` so a column resolves its own messages; null in the single view.
  final String? scrollKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final inner = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (block.author != null) _quoteAuthor(c, ref, block.author!),
        for (final child in block.children) _quoteChild(context, c, child),
      ],
    );
    // A lone long top-level quote gets its own read-more, since the body path ignores quote lines.
    final clamped =
        topLevel && _quoteTextLength(block) > truncateThreshold(context)
            ? _Collapsible(
                collapseKey:
                    hostMessageId == null ? null : '$hostMessageId#quote',
                child: inner)
            : inner;
    // Solid-ui uses opaque plates with a full-alpha border (a wash inside self bubbles) and no hover lift.
    final ghost =
        ref.watch(settingsProvider.select((s) => s.theme == NymThemeKey.ghost));
    final bubbles =
        ref.watch(settingsProvider.select((s) => s.chatLayout == 'bubbles'));
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
        // Hover brightening shows the quote is clickable (glass mode only).
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

    // Only top-level quotes are tappable; inner links and mentions win their own taps.
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

  /// Scrolls to and flashes the quoted source in this view; no-op if it isn't loaded.
  void _jumpToQuotedSource(WidgetRef ref) {
    // In a column, resolve against that column's conversation.
    final key = scrollKey ?? ref.read(appStateProvider).view.storageKey;
    // Resolve against the same filtered set the list renders, so hits are scrollable.
    final messages = scrollKey != null
        ? visibleMessagesFor(ref.read(appStateProvider), scrollKey!)
        : ref.read(messagesForCurrentViewProvider);
    final target = resolveQuotedMessage(
      block,
      messages,
      hostMessageId: hostMessageId,
    );
    void reportUnavailable() =>
        showToast(tr('Original message is not available'));
    if (target == null) {
      reportUnavailable();
      return;
    }
    final scroller = ref.read(messageListScrollerProvider(key));
    final flash = ref.read(flashedMessageProvider.notifier);
    // Try the open thread first; leave it only when the message is elsewhere.
    final open = ref.read(activeThreadProvider);
    final inThread = open != null && open.view.storageKey == key;
    if (inThread &&
        threadChainFor(ref.read(appStateProvider), key, open.rootId)
            .any((m) => m.id == target.id)) {
      if (scroller.scrollToMessage(target.id)) {
        flash.flash(target.id);
        return;
      }
    }
    if (inThread) {
      ref.read(activeThreadProvider.notifier).state = null;
      _jumpWhenBound(scroller, flash, target.id, onGiveUp: reportUnavailable);
      return;
    }
    if (scroller.scrollToMessage(target.id)) {
      flash.flash(target.id);
    } else {
      reportUnavailable();
    }
  }


  /// Quote author header with a dim `#suffix`.
  Widget _quoteAuthor(NymColors c, WidgetRef ref, String author) {
    final split = splitNymSuffix(author);
    final base = split.base;
    final suffix = split.suffix.isEmpty ? null : split.suffix;
    // Resolve the author for a leading avatar and trailing flair; unknown authors render plain.
    final users = ref.watch(usersProvider);
    final t = resolveTarget(author, users);
    final authorSize = size - 1;
    return Text.rich(
      TextSpan(
        children: [
          if (t != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 3),
                child: NymAvatar(
                  seed: t.pubkey,
                  size: authorSize,
                  imageUrl: users[t.pubkey]?.profile?.picture,
                ),
              ),
            ),
          TextSpan(
            text: base,
            style: TextStyle(
              color: c.secondary,
              fontSize: authorSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (suffix != null)
            TextSpan(
              text: suffix,
              style: TextStyle(
                color: c.secondaryA(0.7),
                fontSize: authorSize * 0.9,
                fontWeight: FontWeight.w100,
              ),
            ),
          // Flair goes after the suffix and before ':'.
          if (t != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: CosmeticNymBadges(
                cosmetics: ref.watch(userCosmeticsProvider(t.pubkey)),
                flairSize: authorSize,
                supporterHeight: authorSize,
              ),
            ),
          TextSpan(
            text: ':',
            style: TextStyle(
              color: c.secondary,
              fontSize: authorSize,
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
      case SubtextBlock(:final inlines):
        return _RichInline(inlines: inlines, color: dim, size: (size - 1) * 0.8);
      case ListBlock():
        return _ListView(block: child, color: dim, size: size - 1);
      case CodeBlock(:final code, :final lang):
        return _CodeBox(code: code, lang: lang, size: size - 1);
      case QuoteBlock():
        // Nested quotes aren't independently tappable.
        return _QuoteBox(
          block: child,
          color: dim,
          size: size,
          hostMessageId: hostMessageId,
        );
      case MediaBlock(:final items):
        return _MediaGallery(items: items);
      case AudioBlock():
        return audioOrMediaNote(child);
    }
  }
}

/// 1–4-up media grid; images open fullscreen, videos play inline.
class _MediaGallery extends StatelessWidget {
  const _MediaGallery({required this.items, this.blur = false});
  final List<MediaItem> items;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    // Single item: max 300x300, min height 80.
    if (items.length == 1) {
      return _MediaTile(
          item: items.first, maxSize: 300, blur: blur, gallery: items);
    }
    // Always 2 columns; 3 items use a tall left hero; tiles cap at 220px tall but the grid grows to fit.
    const gap = 4.0;
    Widget tile(MediaItem m) => _MediaTile(
        item: m, maxSize: 220, blur: blur, inGallery: true, gallery: items);
    Widget body;
    if (items.length == 3) {
      // The hero spans both rows at 2x220 plus the gap.
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

  /// Sibling media for prev/next paging in the fullscreen viewer.
  final List<MediaItem>? gallery;

  /// Opens [item] and its image siblings fullscreen.
  void _openFullscreen(BuildContext context) {
    final urls =
        (gallery ?? [item]).where((m) => !m.isVideo).map((m) => m.url).toList();
    if (urls.isEmpty) return;
    final idx = urls.indexOf(item.url);
    _FullscreenImageViewer.open(context, urls, idx < 0 ? 0 : idx);
  }

  /// Privacy blur, revealed on tap.
  final bool blur;

  /// Gallery tiles drop the video border and radius; the grid clips.
  final bool inGallery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final radius = inGallery ? BorderRadius.zero : NymRadius.rsm;

    // Recorded mirrors for the raw URL, retried when the primary fails.
    final mirrors = ref.watch(mediaFallbacksProvider).fallbacksFor(item.url);

    if (item.isVideo) {
      return VideoMessage(
        url: item.url,
        fallbackUrls: mirrors,
        maxSize: maxSize,
        bordered: !inGallery,
        borderRadius: inGallery ? BorderRadius.zero : null,
      );
    }

    // SVG-aware; undecodable images show a placeholder instead of throwing.
    final image = InlineNetworkImage(
      url: proxiedMedia(item.url),
      fallbackUrls: [for (final u in mirrors) proxiedMedia(u)],
      fit: BoxFit.cover,
      width: maxSize,
      // 300px-wide 4:3 slot while the image decodes.
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

    // Tap opens fullscreen, after revealing any blur.
    final tappableImage = blur
        ? _BlurReveal(
            onRevealedTap: () => _openFullscreen(context),
            child: image,
          )
        : GestureDetector(
            onTap: () => _openFullscreen(context),
            child: image,
          );
    // Desktop hover lift, shadow and border brighten; never on touch.
    if (inGallery) {
      // Gallery cells have no border and are clipped by the cell.
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
    // Lone images have a glass border that brightens on hover.
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
                      color:
                          Colors.black.withValues(alpha: c.isLight ? 0.1 : 0.4),
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

/// Rebuilds with mouse-hover state; never fires on touch.
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

/// Fullscreen image viewer with pinch-zoom, swipe-to-dismiss, paging and double-tap zoom; public for other surfaces.
Future<void> openFullscreenMedia(
        BuildContext context, List<String> urls, int index) =>
    _FullscreenImageViewer.open(context, urls, index);

class ViewerItem {
  const ViewerItem({
    required this.url,
    this.isVideo = false,
    this.spoiler = false,
    this.revealed = false,
    this.image,
    this.id = 0,
  });

  final String url;
  final bool isVideo;
  final bool spoiler;
  final bool revealed;
  final ImageProvider? image;
  final int id;
}

Future<void> openMediaViewer(
  BuildContext context,
  List<ViewerItem> items,
  int index, {
  ValueChanged<ViewerItem>? onReveal,
}) =>
    _FullscreenImageViewer.openItems(context, items, index, onReveal: onReveal);

class _FullscreenImageViewer extends StatefulWidget {
  const _FullscreenImageViewer(
      {required this.items, required this.initialIndex, this.onReveal});
  final List<ViewerItem> items;
  final int initialIndex;
  final ValueChanged<ViewerItem>? onReveal;

  static Future<void> open(BuildContext context, List<String> urls, int index) =>
      openItems(context, [for (final u in urls) ViewerItem(url: u)], index);

  static Future<void> openItems(
      BuildContext context, List<ViewerItem> items, int index,
      {ValueChanged<ViewerItem>? onReveal}) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, _, _) => _FullscreenImageViewer(
            items: items, initialIndex: index, onReveal: onReveal),
      ),
    );
  }

  @override
  State<_FullscreenImageViewer> createState() => _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends State<_FullscreenImageViewer>
    with SingleTickerProviderStateMixin {
  static const double _minScale = 1;
  static const double _maxScale = 5;

  late int _index = widget.initialIndex.clamp(0, widget.items.length - 1);

  late final Set<int> _revealed = {
    for (var i = 0; i < widget.items.length; i++)
      if (!widget.items[i].spoiler || widget.items[i].revealed) i,
  };

  ViewerItem get _item => widget.items[_index];

  bool get _hidden => !_revealed.contains(_index);

  bool get _zoomable => !_item.isVideo && !_hidden;

  // Live translate and scale transform.
  double _scale = 1, _tx = 0, _ty = 0;

  // Gesture baselines captured at touch-down or pointer-count change.
  double _startScale = 1, _startTx = 0, _startTy = 0;
  Offset _startFocal = Offset.zero;

  /// 'pinch', 'pan' (zoomed) or 'swipe' (unzoomed); null when idle.
  String? _mode;

  /// Backdrop alpha during a swipe drag; null for the resting 0.85.
  double? _swipeBgAlpha;

  /// Crossfade flag during gallery navigation.
  bool _fadingOut = false;
  Timer? _navTimer;
  int? _navTarget;

  /// Measures the unscaled image box for pan clamping.
  final GlobalKey _imgKey = GlobalKey();

  /// Drives spring-back and navigation reset animations.
  late final AnimationController _anim = AnimationController(vsync: this);

  @override
  void dispose() {
    _navTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _preloadNeighbors();
  }

  ImageProvider _providerFor(ViewerItem it) {
    final own = it.image;
    if (own != null) return own;
    final url = proxiedMedia(it.url);
    return CachedNetworkImageProvider(url,
        headers: InlineNetworkImage.imageHeadersFor(url));
  }

  void _preloadNeighbors() {
    for (final i in [_index + 1, _index - 1]) {
      if (i < 0 || i >= widget.items.length) continue;
      final it = widget.items[i];
      if (it.isVideo || !_revealed.contains(i)) continue;
      precacheImage(_providerFor(it), context, onError: (_, _) {});
    }
  }

  void _reveal() {
    setState(() => _revealed.add(_index));
    widget.onReveal?.call(_item);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      _navigate(1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _navigate(-1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Animates the transform to the target.
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

  /// Resets zoom and pan and drops the swipe backdrop override.
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

  /// Keeps the zoomed pan within the scaled overhang.
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
    // Two fingers pinch; one pans when zoomed, else swipes to dismiss.
    _mode = d.pointerCount >= 2 && _zoomable
        ? 'pinch'
        : (_scale > _minScale ? 'pan' : 'swipe');
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    // Adding or lifting a finger re-baselines the gesture.
    final wantPinch = d.pointerCount >= 2 && _zoomable;
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
        // Scale clamped from the pinch ratio; the midpoint drag pans.
        _scale = (_startScale * d.scale).clamp(_minScale, _maxScale);
        _tx = _startTx + dFocal.dx;
        _ty = _startTy + dFocal.dy;
      } else if (_mode == 'pan') {
        _tx = _startTx + dFocal.dx;
        _ty = _startTy + dFocal.dy;
      } else {
        // The image follows the finger and the backdrop fades with distance.
        _tx = dFocal.dx;
        _ty = dFocal.dy;
        final progress = math.min(1.0, Offset(_tx, _ty).distance / 300);
        _swipeBgAlpha = 0.4 * (1 - progress);
      }
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final mode = _mode;
    if (d.pointerCount == 0) _mode = null;
    if (mode == 'swipe') {
      // Galleries page on a mostly horizontal release past 60px; releases past 100px dismiss; else spring back.
      final hasGallery = widget.items.length > 1;
      final horizontal = _tx.abs() > _ty.abs();
      if (hasGallery && horizontal) {
        if (_tx.abs() > 60) {
          final delta = _tx < 0 ? 1 : -1;
          if (_navigate(delta)) return;
        }
        _reset(animate: true);
        return;
      }
      final closeDist = hasGallery ? _ty.abs() : Offset(_tx, _ty).distance;
      if (closeDist > 100) {
        Navigator.of(context).maybePop();
        return;
      }
      _reset(animate: true);
    } else if (mode == 'pinch' || mode == 'pan') {
      if (_scale <= _minScale) {
        _reset(animate: true);
      } else {
        // Settle the pan inside the scaled bounds.
        final (cx, cy) = _clampedPan();
        _animateTo(_scale, cx, cy, const Duration(milliseconds: 250));
      }
    }
  }

  /// Toggles zoom 1 <-> 2.5.
  void _onDoubleTap() {
    if (!_zoomable) return;
    if (_scale > _minScale) {
      _reset(animate: true);
    } else {
      _animateTo(2.5, _tx, _ty, const Duration(milliseconds: 250));
    }
  }

  /// Clamped at the ends (no wraparound); resets zoom and crossfades.
  bool _navigate(int delta) {
    final next = (_navTarget ?? _index) + delta;
    if (next < 0 || next >= widget.items.length) return false;
    _navTarget = next;
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
        _navTarget = null;
        _fadingOut = false;
      });
      _preloadNeighbors();
    });
    return true;
  }

  /// Hands the image URL to the platform to download or open.
  Future<void> _download() async {
    await launchSafeUrl(_item.url);
  }

  Widget _content(NymColors c, Size screen) {
    if (_hidden) {
      return Semantics(
        button: true,
        label: tr('Spoiler, tap to reveal'),
        child: GestureDetector(
          key: const ValueKey('viewerSpoiler'),
          onTap: _reveal,
          child: Container(
            width: math.min(320, screen.width - 32),
            height: 200,
            alignment: Alignment.center,
            color: const Color(0xEB141423),
            child: Text(tr('Spoiler, tap to reveal'),
                style: TextStyle(color: c.text, fontSize: 15)),
          ),
        ),
      );
    }
    if (_item.isVideo) {
      return KeyedSubtree(
        key: const ValueKey('viewerVideo'),
        child: VideoMessage(
          key: ValueKey('viewerVideo-$_index'),
          url: _item.url,
          maxSize: math.min(screen.width, screen.height) * 0.9,
          bordered: false,
        ),
      );
    }
    final own = _item.image;
    if (own != null) {
      return Image(
          image: own,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image,
              color: Colors.white54, size: 48));
    }
    return CachedNetworkImage(
      imageUrl: proxiedMedia(_item.url),
      httpHeaders: InlineNetworkImage.imageHeadersFor(proxiedMedia(_item.url)),
      fit: BoxFit.contain,
      errorWidget: (_, _, _) =>
          const Icon(Icons.broken_image, color: Colors.white54, size: 48),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final screen = MediaQuery.of(context).size;
    final multi = widget.items.length > 1;
    final gutter = screen.width < 600 ? 16.0 : 20.0;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
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
                onTap: _scale > _minScale
                    ? null
                    : () => Navigator.of(context).maybePop(),
                onDoubleTap: _zoomable ? _onDoubleTap : null,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                child: Transform.translate(
                  offset: Offset(_tx, _ty),
                  child: Transform.scale(
                    scale: _scale,
                    alignment: Alignment.center,
                    child: AnimatedOpacity(
                      opacity: _fadingOut ? 0 : 1,
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.linear,
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
                        child: _content(c, screen),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (multi) ...[
              if (_index > 0)
                Positioned(
                  left: gutter,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _chip('‹', 44, 32, () => _navigate(-1),
                        key: const ValueKey('viewerPrev'),
                        label: tr('Previous'),
                        padding: const EdgeInsets.only(bottom: 4)),
                  ),
                ),
              if (_index < widget.items.length - 1)
                Positioned(
                  right: gutter,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _chip('›', 44, 32, () => _navigate(1),
                        key: const ValueKey('viewerNext'),
                        label: tr('Next'),
                        padding: const EdgeInsets.only(bottom: 4)),
                  ),
                ),
              Positioned(
                bottom: 28,
                left: 0,
                right: 0,
                child: Center(
                  child: Semantics(
                    liveRegion: true,
                    child: Text('${_index + 1} / ${widget.items.length}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                  ),
                ),
              ),
            ],
            Positioned(
              top: 20,
              right: gutter + 50,
              child: SafeArea(
                  child: _chip('⤓', 40, 22, _download, label: tr('Download'))),
            ),
            Positioned(
              top: 20,
              right: gutter,
              child: SafeArea(
                child: _chip('×', 40, 24, () => Navigator.of(context).maybePop(),
                    label: tr('Close')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Glass circle for close, download and nav buttons.
  Widget _chip(String glyph, double side, double fontSize, VoidCallback onTap,
      {EdgeInsets padding = EdgeInsets.zero, Key? key, String? label}) {
    final c = context.nym;
    return Semantics(
      key: key,
      button: true,
      label: label,
      excludeSemantics: label != null,
      child: GestureDetector(
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
      ),
    );
  }
}

/// Image blurred until tapped.
class _BlurReveal extends StatefulWidget {
  const _BlurReveal({required this.child, this.onRevealedTap});
  final Widget child;

  /// Tapped once revealed, e.g. to open fullscreen.
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
    // blur(20px); the desktop hover lightening is omitted.
    return GestureDetector(
      onTap: () => setState(() => _revealed = true),
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: widget.child,
      ),
    );
  }
}

/// Short text with known custom `:shortcode:`s as inline images; [wholeStringOnly] only matches an exact `:code:`.
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

  /// Custom emoji side length; defaults to 1.75x the font size.
  final double? emojiSize;

  /// Only an exact `^:code:$` resolves to an image.
  final bool wholeStringOnly;

  /// Margin around the emoji image.
  final EdgeInsets emojiMargin;

  /// Alignment override; when null the image drops [emojiBaselineDropEm] below the baseline.
  final PlaceholderAlignment? emojiAlignment;

  /// Ems below the baseline: 0.375 by default, 0.25 for [wholeStringOnly]; ignored with [emojiAlignment].
  final double? emojiBaselineDropEm;

  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  /// `:shortcode:` token.
  static final RegExp _rxToken = RegExp(r':([a-zA-Z0-9_]+):');

  /// Whole-string `:shortcode:`.
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

    // Baseline drop per mode unless [emojiAlignment] overrides it.
    final dropPx = (style.fontSize ?? 14) *
        (emojiBaselineDropEm ?? (wholeStringOnly ? 0.25 : 0.375));

    InlineSpan emojiSpan(String code, String url) {
      final image = InlineNetworkImage(
        url: proxiedMedia(url, emoji: true),
        width: side,
        height: side,
        fit: BoxFit.contain,
        // Disk-cached; these surfaces show few emoji.
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
      // An image only when the whole text is a known custom code.
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

    // No token: a single plain Text.
    if (!_rxToken.hasMatch(text)) return plainText();

    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _rxToken.allMatches(text)) {
      final code = m.group(1)!;
      // Only known custom codes are replaced; built-in and unknown codes stay literal.
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

/// Max collapsed height: 300px, or 200px at ≤768px.
double _truncateHeight(BuildContext context) =>
    MediaQuery.of(context).size.width <= 768 ? 200 : 300;

/// Read-more wrapper clamping [child]; the toggle drops once the body fits.
class _Collapsible extends ConsumerStatefulWidget {
  const _Collapsible({required this.child, this.collapseKey});
  final Widget child;

  /// Identity across rebuilds for [expandedMessagesProvider]; null uses local state.
  final String? collapseKey;

  @override
  ConsumerState<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends ConsumerState<_Collapsible> {
  bool _localExpanded = false;

  /// Natural height after first layout; null until measured.
  double? _fullHeight;

  bool get _expanded {
    final key = widget.collapseKey;
    if (key == null || key.isEmpty) return _localExpanded;
    return ref.watch(expandedMessagesProvider).contains(key);
  }

  void _setExpanded(bool value) {
    final key = widget.collapseKey;
    if (key == null || key.isEmpty) {
      setState(() => _localExpanded = value);
      return;
    }
    ref.read(expandedMessagesProvider.notifier).toggle(key, expanded: value);
  }

  void _onMeasured(double height) {
    if (_fullHeight != null && (height - _fullHeight!).abs() < 0.5) return;
    // Defer the state update out of layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _fullHeight = height);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final bubbles = ref.watch(settingsProvider).useBubbles;
    final truncateHeight = _truncateHeight(context);
    // Fits already: no clamp and no toggle.
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
        // Full-width primary toggle; bubbles add a top divider. Shown only while overflowing.
        if (!fits)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _setExpanded(!_expanded),
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
                _expanded ? tr('Show less') : tr('Read more'),
                textAlign: TextAlign.center,
                style: TextStyle(color: c.primary, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }
}

/// Measures the child's natural height and sizes to min(natural, max), avoiding an offstage pass.
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
    required this._maxHeight,
    required this._onMeasured,
  });

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
    // Lay out without a height bound to learn the natural height.
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

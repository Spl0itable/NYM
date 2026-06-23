import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/messages/format/message_content.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/reactions/quick_react_popup.dart';
import '../../features/reactions/reaction_burst.dart';
import '../../features/reactions/reactors_modal.dart';
import '../../features/translate/message_translation.dart';
import '../../models/message.dart';
import '../../models/settings.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/nym_avatar.dart';
import '../context_menu/context_menu_actions.dart';
import '../context_menu/context_menu_panel.dart';
import '../context_menu/interaction_hooks.dart';

/// Formats a [DateTime] per the user's time-format setting (docs/specs/02 §4).
String formatTime(DateTime t, String timeFormat) {
  final h24 = t.hour;
  final m = t.minute.toString().padLeft(2, '0');
  if (timeFormat == '24hr') {
    return '${h24.toString().padLeft(2, '0')}:$m';
  }
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final ampm = h24 < 12 ? 'AM' : 'PM';
  return '$h12:$m $ampm';
}

/// Renders a single message in either IRC or bubble layout.
///
/// IRC (`!useBubbles`): a wrapping row of [author 120w] [time 50w] [content],
/// with self/mentioned tints + left accent bars. Bubble (`useBubbles`): a
/// name-above-bubble stack, the content boxed with a tail corner, right-aligned
/// for self, with an in-bubble time. (docs/specs/02 §6, docs/specs/03 §2.7)
///
/// Interactions (docs/specs/02 §5.8): reaction badges toggle via
/// [NostrController.toggleReaction] (kind inferred from the message), an
/// "add reaction" affordance opens the picker, long-pressing a badge shows the
/// reactor list, and long-pressing the message (or tapping the author/avatar)
/// opens the quick-react popup / context menu.
class MessageRow extends ConsumerStatefulWidget {
  const MessageRow({
    super.key,
    required this.message,
    required this.settings,
    required this.reactions,
    this.mentioned = false,
    this.grouped = false,
    this.showAvatar = true,
    this.showName = true,
    this.onReactionPicker,
  });

  final Message message;
  final Settings settings;
  final List<MessageReaction> reactions;
  final bool mentioned;

  /// Bubble layout: this message is part of a consecutive same-author group.
  final bool grouped;

  /// Bubble layout: render the 32px sticky avatar (others only).
  final bool showAvatar;

  /// Bubble layout: render the name above the bubble.
  final bool showName;

  /// Opens the full emoji reaction picker for this message (host supplies it).
  /// When null the add-reaction / "more" affordances are no-ops.
  final ValueChanged<Message>? onReactionPicker;

  @override
  ConsumerState<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends ConsumerState<MessageRow> {
  bool _showTranslation = false;
  String? _translateLangOverride;

  Message get message => widget.message;
  Settings get settings => widget.settings;
  List<MessageReaction> get reactions => widget.reactions;

  /// The author's active flair-shop cosmetics (style / flair / supporter),
  /// resolved from the shop controller (self) or presence (`usersProvider`).
  UserCosmetics get _cosmetics =>
      ref.watch(userCosmeticsProvider(message.pubkey));

  /// The author's active message-style decoration. The supporter badge also
  /// adds a gold "supporter-style" treatment to the message body
  /// (`.message.supporter-style`); an explicit style takes precedence.
  MessageStyleDecoration? get _styleDecoration {
    final cos = _cosmetics;
    final styled = messageStyleDecoration(cos.styleId);
    if (styled != null) return styled;
    if (cos.supporter) return supporterStyleDecoration;
    return null;
  }

  /// The flair + supporter badges that follow the author nym.
  Widget _nymBadges(BuildContext context, {double flairSize = 16}) {
    return CosmeticNymBadges(
      cosmetics: _cosmetics,
      flairSize: flairSize,
      supporterHeight: flairSize,
    );
  }

  @override
  Widget build(BuildContext context) {
    return settings.useBubbles ? _buildBubble(context) : _buildIrc(context);
  }

  // ---- IRC layout ----
  Widget _buildIrc(BuildContext context) {
    final c = context.nym;
    final fontSize = settings.textSize.toDouble();
    final self = message.isOwn;

    final deco = _styleDecoration;

    Color? bg;
    Color? barColor;
    if (self) {
      bg = c.secondaryA(0.05);
      barColor = Colors.white.withValues(alpha: 0.30);
    } else if (widget.mentioned) {
      bg = c.secondaryA(0.06);
      barColor = c.secondary;
    }
    // IRC layout paints the message-style accents on the row itself
    // (`body:not(.chat-bubbles) .message.supporter-style { background; border-left }`).
    if (deco?.borderAccent != null) {
      barColor = deco!.borderAccent;
      bg = deco.contentBackground ?? bg;
    }

    final content = Container(
      decoration: BoxDecoration(
        color: bg,
        border: barColor != null
            ? Border(left: BorderSide(color: barColor, width: 3))
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.start,
        spacing: 10,
        runSpacing: 4,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 120, maxWidth: 200),
            child: GestureDetector(
              onTap: () => _openContextMenu(context),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      message.author,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: self ? c.primary : c.secondary,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _nymBadges(context),
                ],
              ),
            ),
          ),
          if (settings.showTimestamps)
            SizedBox(
              width: 50,
              child: Text(
                formatTime(message.dateTime, settings.timeFormat),
                style: TextStyle(color: c.textDim, fontSize: 12),
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width - 220,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _content(context, c.text, fontSize, deco: deco),
                if (_showTranslation)
                  MessageTranslation(
                    content: message.content,
                    targetLang: _translateLangOverride,
                  ),
                if (reactions.isNotEmpty || widget.onReactionPicker != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: _reactionsRow(context),
                  ),
                if (self && message.isPM) _deliveryTicks(context),
              ],
            ),
          ),
        ],
      ),
    );
    return GestureDetector(
      onLongPress: () => _onMessageLongPress(context),
      child: content,
    );
  }

  // ---- Bubble layout ----
  Widget _buildBubble(BuildContext context) {
    final c = context.nym;
    final fontSize = settings.textSize.toDouble();
    final self = message.isOwn;
    final align = self ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final deco = _styleDecoration;

    // In bubble mode the CSS applies the message style to `.message-content`
    // (the bubble): a translucent style background plus a soft glow halo.
    final bubbleColor = deco?.contentBackground ??
        (self ? c.primaryA(0.25) : Colors.white.withValues(alpha: 0.14));
    final glow = deco?.glow;

    final bubble = GestureDetector(
      onLongPress: () => _onMessageLongPress(context),
      child: Container(
        constraints: BoxConstraints(
          minWidth: 0,
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: _bubbleRadius(self),
          boxShadow: glow != null
              ? [BoxShadow(color: glow, blurRadius: 18, spreadRadius: -2)]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _content(context, c.text, fontSize, deco: deco),
            if (_showTranslation)
              MessageTranslation(
                content: message.content,
                targetLang: _translateLangOverride,
              ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (message.isEdited)
                  Text(
                    'edited ',
                    style: TextStyle(color: c.textDim, fontSize: 10),
                  ),
                Text(
                  formatTime(message.dateTime, settings.timeFormat),
                  style: TextStyle(color: c.textDim, fontSize: 10),
                ),
                if (self && message.isPM) ...[
                  const SizedBox(width: 4),
                  _ticksGlyph(context),
                ],
              ],
            ),
          ],
        ),
      ),
    );

    final stack = Column(
      crossAxisAlignment: align,
      children: [
        if (widget.showName && !widget.grouped)
          Padding(
            padding: const EdgeInsets.only(bottom: 2, left: 2, right: 2),
            child: GestureDetector(
              onTap: () => _openContextMenu(context),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      message.author,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: self ? c.primary : c.secondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _nymBadges(context, flairSize: 14),
                ],
              ),
            ),
          ),
        bubble,
        if (reactions.isNotEmpty || widget.onReactionPicker != null)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: _reactionsRow(context),
          ),
      ],
    );

    // `.message-group`: align-end row with a 32px sticky avatar for others.
    final row = Row(
      mainAxisAlignment:
          self ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!self) ...[
          SizedBox(
            width: 32,
            child: widget.showAvatar && !widget.grouped
                ? GestureDetector(
                    onTap: () => _openContextMenu(context),
                    child: NymAvatar(seed: message.author, size: 32),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 6),
        ],
        Flexible(child: stack),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(14, widget.grouped ? 1 : 4, 14, 1),
      child: row,
    );
  }

  // ---- reactions row ----
  Widget _reactionsRow(BuildContext context) {
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final r in reactions)
          _ReactionBadge(
            reaction: r,
            onTap: (rect) => _toggleReaction(context, r),
            onLongPress: (rect) => _showReactors(context, r, rect),
          ),
        // `.add-reaction-btn` affordance (always present so users can react).
        if (widget.onReactionPicker != null)
          _AddReactionBtn(onTap: () => widget.onReactionPicker!(message)),
      ],
    );
  }

  Future<void> _toggleReaction(BuildContext context, MessageReaction r) async {
    final controller = ref.read(nostrControllerProvider);
    final view = ref.read(currentViewProvider);
    final kind = inferOriginalKind(message, view: view);
    final wasReacted = r.userReacted;
    final ok = await controller.toggleReaction(
      message.id,
      r.emoji,
      target: reactionTargetFor(message),
      kind: kind,
    );
    // Burst on add (not on removal), mirroring `_burstOnBadge` after sendReaction.
    if (ok && !wasReacted && context.mounted) {
      final center = _globalCenterOfContext(context);
      if (center != null) ReactionBurst.play(context, center, r.emoji);
    }
  }

  void _showReactors(BuildContext context, MessageReaction r, Rect rect) {
    // The engine exposes only aggregate tallies publicly (count + userReacted),
    // so we render the self row when applicable plus an anonymous count.
    // TODO(verify): show real reactor nyms once AppState exposes the reactor
    // pubkey/nym map (`_reactors`) publicly.
    final self = ref.read(appStateProvider);
    final reactors = <ReactorEntry>[
      if (r.userReacted)
        ReactorEntry(
          pubkey: self.selfPubkey,
          nym: _baseNym(self.selfNym),
          suffix: getPubkeySuffix(self.selfPubkey),
          isYou: true,
        ),
    ];
    showReactorsModal(
      context,
      anchorRect: rect,
      emoji: r.emoji,
      reactors: reactors,
    );
  }

  void _onMessageLongPress(BuildContext context) {
    final rect = _globalRectOfContext(context);
    // Quick-react recents are sourced from the engine when exposed; until then
    // the popup pads with the six defaults (calls.js `_messageQuickReactDefaults`).
    showQuickReactPopup(
      context,
      anchorRect: rect ?? Rect.zero,
      emojis: quickReactEmojis(const []),
      onReact: (emoji) => _quickReact(context, emoji),
      onMore: () => widget.onReactionPicker?.call(message),
      onMenu: message.isOwn ? null : () => _openContextMenu(context),
    );
  }

  Future<void> _quickReact(BuildContext context, String emoji) async {
    final controller = ref.read(nostrControllerProvider);
    final view = ref.read(currentViewProvider);
    final already = reactions.any((r) => r.emoji == emoji && r.userReacted);
    final ok = await controller.toggleReaction(
      message.id,
      emoji,
      target: reactionTargetFor(message),
      kind: inferOriginalKind(message, view: view),
    );
    if (ok && !already && context.mounted) {
      final center = _globalCenterOfContext(context);
      if (center != null) ReactionBurst.play(context, center, emoji);
    }
  }

  void _openContextMenu(BuildContext context) {
    final app = ref.read(appStateProvider);
    final target = ctxTargetForMessage(message, selfPubkey: app.selfPubkey);
    ContextMenuPanel.show(
      context,
      target: target,
      message: message,
      onReact: () => widget.onReactionPicker?.call(message),
      onTranslateInline: (lang) => setState(() {
        _translateLangOverride = lang;
        _showTranslation = true;
      }),
    );
  }

  // ---- helpers ----
  Rect? _globalRectOfContext(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    return origin & box.size;
  }

  Offset? _globalCenterOfContext(BuildContext context) {
    final r = _globalRectOfContext(context);
    return r?.center;
  }

  String _baseNym(String nym) {
    final hash = nym.indexOf('#');
    return hash > 0 ? nym.substring(0, hash) : nym;
  }

  BorderRadius _bubbleRadius(bool self) {
    const r = Radius.circular(16);
    const tail = Radius.circular(4);
    if (widget.grouped) return const BorderRadius.all(r);
    if (self) {
      return const BorderRadius.only(
        topLeft: r,
        topRight: tail,
        bottomLeft: r,
        bottomRight: r,
      );
    }
    return const BorderRadius.only(
      topLeft: tail,
      topRight: r,
      bottomLeft: r,
      bottomRight: r,
    );
  }

  /// Renders the message body through the rich formatter pipeline, tinted by the
  /// author's active message style ([deco]) when present.
  ///
  /// The style's glyph colour is threaded via [MessageContent.baseColor]; a
  /// gradient style (aurora) clips the text with a `ShaderMask`. The per-glyph
  /// `text-shadow` glow can't be pushed through `MessageContent`, so the glow is
  /// rendered as the bubble/row halo instead (see TODO(verify) in the report).
  Widget _content(
    BuildContext context,
    Color color,
    double fontSize, {
    MessageStyleDecoration? deco,
  }) {
    final body = MessageContent(
      content: message.content,
      baseColor: deco?.textColor ?? color,
      fontSize: fontSize,
    );
    final gradient = deco?.gradient;
    if (gradient != null && gradient.length >= 2) {
      // `.message.style-aurora .message-content` clips a gradient to the text.
      return ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: gradient,
        ).createShader(rect),
        child: MessageContent(
          content: message.content,
          baseColor: Colors.white,
          fontSize: fontSize,
        ),
      );
    }
    return body;
  }

  Widget _deliveryTicks(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: _ticksGlyph(context),
      ),
    );
  }

  Widget _ticksGlyph(BuildContext context) {
    final c = context.nym;
    // Glyphs + colors are a 1:1 port of messages.js:837-844 and the
    // `.delivery-status` rules in styles-chat.css:673-686 (those colors are
    // hard-coded hex, not theme vars):
    //   read      → "✓✓" #2196F3 (blue)
    //   delivered → "✓"  #4CAF50 (green)   ← single tick, not double
    //   sent      → "✓"  --text-dim
    //   failed    → "!"  #f44336 (danger)
    // The PWA renders nothing for any other status (e.g. a pending "sending"),
    // so we emit an empty widget rather than an ellipsis.
    String glyph;
    Color color;
    switch (message.deliveryStatus) {
      case DeliveryStatus.read:
        glyph = '✓✓';
        color = const Color(0xFF2196F3);
        break;
      case DeliveryStatus.delivered:
        glyph = '✓';
        color = const Color(0xFF4CAF50);
        break;
      case DeliveryStatus.sent:
        glyph = '✓';
        color = c.textDim;
        break;
      case DeliveryStatus.failed:
        glyph = '!';
        color = c.danger;
        break;
      case DeliveryStatus.sending:
        return const SizedBox.shrink();
    }
    return Text(
      glyph,
      style: TextStyle(color: color, fontSize: 11, height: 1),
    );
  }
}

/// A single `.reaction-badge` pill. Tappable (toggle) with a long-press to show
/// the reactor list; reports its global bounds to the callbacks for anchoring.
class _ReactionBadge extends StatelessWidget {
  const _ReactionBadge({
    required this.reaction,
    required this.onTap,
    required this.onLongPress,
  });
  final MessageReaction reaction;
  final void Function(Rect) onTap;
  final void Function(Rect) onLongPress;

  Rect _rect(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Rect.zero;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final r = reaction;
    return GestureDetector(
      onTap: () => onTap(_rect(context)),
      onLongPress: () => onLongPress(_rect(context)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: r.userReacted
              ? c.primaryA(0.12)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          border: Border.all(
            color: r.userReacted ? c.primaryA(0.35) : c.glassBorder,
          ),
        ),
        child: Text(
          '${r.emoji} ${r.count}',
          style: TextStyle(
            color: r.userReacted ? c.primary : c.text,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

/// The `.add-reaction-btn` affordance (a dim "+ smiley" pill that opens the
/// emoji picker).
class _AddReactionBtn extends StatelessWidget {
  const _AddReactionBtn({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: 0.6,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            border: Border.all(color: c.glassBorder),
          ),
          child: Icon(Icons.add_reaction_outlined, size: 14, color: c.textDim),
        ),
      ),
    );
  }
}

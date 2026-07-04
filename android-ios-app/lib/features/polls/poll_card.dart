import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../models/poll.dart';
import '../../models/settings.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/bitchat_user_color.dart';
import '../../widgets/chat/message_row.dart'
    show formatTime, formatFullTimestamp;
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/context_menu/context_menu_panel.dart';
import '../../widgets/context_menu/profile_badges.dart';
import '../../widgets/nym_icons.dart';
import '../reactions/reaction_picker.dart';
import '../shop/cosmetics.dart';
import '../shop/shop_widgets.dart';
import '../translate/translate_languages.dart';
import '../translate/translate_service.dart';

/// An inline poll message (`displayPollMessage`, `polls.js:187-371`). The PWA
/// renders a poll as a FULL `.message` row: `.message-time` (clickable full
/// timestamp), a `.message-author` with `<nym#suffix>` brackets + flair +
/// verified ✓ + supporter badges, then the `.message-content` holding the
/// `.poll-container` (📊 Poll header + question + option rows with animated
/// vote bars, `NN%`, voted highlight, voter-avatar stacks, and an "N votes"
/// footer). The row carries the sender's shop classes — `style-*`,
/// `supporter-style` and `cosmetic-aura-gold` ONLY (polls.js:190-198) — and
/// desktop adds the `.msg-hover-buttons` react/translate pair.
///
/// Tapping an option casts a vote ([NostrController.votePoll]); tapping the
/// footer opens the `.poll-voters-modal` (no-op with zero votes).
///
/// CSS source of truth: `styles-features.css:3992-4157`,
/// `styles-themes-responsive.css:1510-1525`.
class PollCard extends ConsumerStatefulWidget {
  const PollCard({super.key, required this.poll, required this.settings});

  final Poll poll;
  final Settings settings;

  @override
  ConsumerState<PollCard> createState() => _PollCardState();
}

class _PollCardState extends ConsumerState<PollCard> {
  // Inline-translation state (mirrors `MessageRow._showTranslation` /
  // `_translateLangOverride`, message_row.dart:179-180): rendered below the
  // `.poll-container` once the user picks Translate from the author context
  // menu (polls.js author click → showContextMenu Translate → `translatePoll`)
  // or hits the hover translate button (`translateHoverMessage` routes a
  // `.poll-message` to `translatePoll`, translate.js:408-416).
  bool _showTranslation = false;
  String? _translateLangOverride;

  /// Desktop row hover (`@media(hover:hover) .message:hover`) — drives the row
  /// hover tint and the `.msg-hover-buttons` opacity, like a regular message.
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final poll = widget.poll;
    final settings = widget.settings;
    final c = context.nym;
    final controller = ref.read(nostrControllerProvider);
    // Watch app state so a new vote re-tallies the bars live.
    final appState = ref.watch(appStateProvider);

    final selfPubkey = appState.selfPubkey;
    final isOwn = poll.pubkey == selfPubkey;
    final hasVoted = poll.votes.containsKey(selfPubkey);
    final votedIndex = hasVoted ? poll.votes[selfPubkey] : null;
    final total = poll.totalVotes;
    final fontSize = settings.textSize.toDouble();

    final users = ref.watch(usersProvider);
    final authorPic = users[poll.pubkey]?.profile?.picture;
    final baseNym = stripPubkeySuffix(poll.nym.isEmpty ? 'nym' : poll.nym);
    final suffix = getPubkeySuffix(poll.pubkey);

    // Clamp the timestamp to now so polls never appear in the future
    // (polls.js:211-213).
    var dt = DateTime.fromMillisecondsSinceEpoch(poll.createdAt * 1000);
    final now = DateTime.now();
    if (dt.isAfter(now)) dt = now;
    final timeStr = poll.createdAt > 0 ? formatTime(dt, settings.timeFormat) : '';
    // polls.js:270-278 hardcodes en-US "Mon D, YYYY, hh:mm:ss" (it ignores the
    // dateFormat setting) — the '' dateFormat selects [formatFullTimestamp]'s
    // short-month default branch.
    final fullTimestamp = formatFullTimestamp(dt, settings.timeFormat, '');

    // The sender's shop chrome (polls.js:190-198): the poll `.message` carries
    // the style-* class, `supporter-style`, and `cosmetic-aura-gold` — ONLY
    // gold; the other special cosmetics are never applied to poll messages.
    final cosmetics = ref.watch(userCosmeticsProvider(poll.pubkey));
    final styleDeco =
        messageStyleDecoration(cosmetics.styleId, isLight: c.isLight);
    final supporterDeco = cosmetics.supporter
        ? (c.isLight ? supporterStyleDecorationLight : supporterStyleDecoration)
        : null;
    final goldAura = cosmetics.cosmetics.contains('cosmetic-aura-gold')
        ? cosmeticAuraFor('cosmetic-aura-gold', isLight: c.isLight)
        : null;

    // Row paint, mirroring the IRC `.message` rules (message_row._buildIrc):
    // `.message.self` tints the row + paints the white/black accent bar; the
    // desktop hover tint REPLACES the flat fill; the supporter/gold gradients
    // (styles-features.css, loaded later) win over both.
    Color? bg;
    Color? barColor;
    if (isOwn) {
      bg = c.secondaryA(0.05);
      // `.message.self::before`: white@0.3 dark; light-mode black@0.25.
      barColor = c.isLight
          ? const Color(0x40000000) // black @ 0.25
          : const Color(0x4DFFFFFF); // white @ 0.30
    }
    if (_hovered) {
      // `.message:hover { background: rgba(255,255,255,0.03) }`; light mode
      // flips to black@0.03 (styles-themes-responsive.css:555-559).
      bg = c.isLight
          ? Colors.black.withValues(alpha: 0.03)
          : Colors.white.withValues(alpha: 0.03);
    }
    List<Color>? bgGradient;
    if (supporterDeco != null) {
      // `body:not(.chat-bubbles) .message.supporter-style`: gold 135deg wash +
      // gold left bar.
      barColor = supporterDeco.borderAccent ?? barColor;
      bgGradient = supporterDeco.backgroundGradient ?? bgGradient;
    }
    if (goldAura != null) {
      // `.message.cosmetic-aura-gold` (IRC): gold left bar, gold wash, an
      // inset 1px ring + an 18px (12px light) outer glow.
      barColor = goldAura.borderAccent ?? barColor;
      bgGradient = goldAura.gradient ?? bgGradient;
    }
    final rowRing = goldAura?.insetColor;
    final glowBlur = goldAura?.glowBlurFor(bubble: false) ?? 0;

    // The author nym colour: self → primary (`.message-author.self`), bitchat
    // theme → the deterministic per-user hue (`getUserColorClass`, users.js:
    // 11-18), else secondary. Genesis flair bolds the nym
    // (`.has-genesis-flair`).
    final bitchat = (!isOwn && settings.theme == NymThemeKey.bitchat)
        ? bitchatUserColor(poll.pubkey, isLight: c.isLight)
        : null;
    final authorColor = isOwn ? c.primary : (bitchat ?? c.secondary);
    final authorStyle = TextStyle(
      color: authorColor,
      fontSize: fontSize,
      fontWeight:
          hasGenesisFlair(cosmetics) ? FontWeight.w700 : FontWeight.w600,
      // `.message-author { letter-spacing: 0.2px }`.
      letterSpacing: 0.2,
    );
    final isVerified = controller.isVerifiedDeveloper(poll.pubkey) ||
        controller.isVerifiedBot(poll.pubkey);
    // `body.chat-bubbles .nym-bracket { display: none }`.
    final brackets = !settings.useBubbles;

    // `.author-clickable` (polls.js:314-324): avatar + `<` + nym#suffix +
    // flair + verified ✓ + supporter — that exact order (polls.js:281,301) —
    // then the closing `>` bracket.
    final authorLine = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openAuthorMenu(context, selfPubkey),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          NymAvatar(seed: poll.pubkey, size: 18, imageUrl: authorPic),
          const SizedBox(width: 4),
          if (brackets)
            Text('<', style: TextStyle(color: authorColor, fontSize: fontSize)),
          Flexible(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: baseNym, style: authorStyle),
                if (suffix.isNotEmpty)
                  TextSpan(
                    text: '#$suffix',
                    // `.nym-suffix`: opacity 0.7, 0.9em, weight 100.
                    style: authorStyle.copyWith(
                      color: authorColor.withValues(alpha: 0.7),
                      fontSize: fontSize * 0.9,
                      fontWeight: FontWeight.w100,
                    ),
                  ),
              ]),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // `getFlairForUser` flair badge(s) — in-chat `.flair-badge` is 20px.
          if (cosmetics.flairId != null && cosmetics.flairId!.isNotEmpty)
            FlairBadge(
              flairId: cosmetics.flairId!,
              edition: cosmetics.flairId == 'flair-genesis'
                  ? cosmetics.genesisEdition
                  : null,
              size: 20,
            ),
          // Blue ✓ for the verified developer / Nymbot (polls.js:230-234).
          if (isVerified) ...[
            const SizedBox(width: 4),
            const VerifiedBadge(size: 20),
          ],
          // Gold "Supporter" pill (polls.js:228-229).
          if (cosmetics.supporter) const SupporterBadge(height: 20),
          if (brackets)
            Text('>', style: TextStyle(color: authorColor, fontSize: fontSize)),
        ],
      ),
    );

    // `.poll-container` (max-width 400, `margin: 8px 0` inside the content).
    final pollContainer = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        // `body.light-mode .poll-container { background: rgba(0,0,0,0.03) }`
        // (styles-themes-responsive.css:1510-1513); dark white@0.04.
        color: c.isLight
            ? const Color(0x08000000) // black @ 0.03
            : Colors.white.withValues(alpha: 0.04),
        border: Border.all(color: c.glassBorder),
        borderRadius: NymRadius.rmd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // `.poll-header`.
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '📊 POLL',
              style: TextStyle(
                color: c.textDim,
                fontSize: 11,
                letterSpacing: 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // `.poll-question`.
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              poll.question,
              style: TextStyle(
                color: c.textBright,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ),
          // `.poll-options` (flex column, gap 8).
          for (var i = 0; i < poll.options.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _PollOption(
              poll: poll,
              option: poll.options[i],
              total: total,
              selected: votedIndex == poll.options[i].index,
              avatarFor: (pk) => users[pk]?.profile?.picture,
              onTap: hasVoted
                  ? null
                  : () => controller.votePoll(poll.id, poll.options[i].index),
            ),
          ],
          // `.poll-footer` ("N vote(s)", margin-top 12) → voters modal.
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _PollFooter(
              total: total,
              onTap: (rect) => _showVoters(context, rect),
            ),
          ),
        ],
      ),
    );

    // `.message-content`: the poll box (its 8px vertical margin lives OUTSIDE
    // any style tint), tinted by `.message.style-X .message-content
    // { background }` when the sender has a message style active.
    final styleBg = styleDeco?.contentBackgroundFor(bubble: false);
    Widget content = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: styleBg != null
          ? DecoratedBox(
              decoration: BoxDecoration(color: styleBg),
              child: pollContainer,
            )
          : pollContainer,
    );
    content = Padding(
      // `.poll-container { margin: 8px 0 }`.
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: content,
    );

    // The `.message` flex-wrap row, in PWA DOM order (polls.js:299-311):
    // `.message-time` FIRST, then `.message-author`, then `.message-content`.
    final messageRow = Wrap(
      crossAxisAlignment: WrapCrossAlignment.start,
      spacing: 10, // `.message { gap: 10px }`
      runSpacing: 4,
      children: [
        // `.message-time { font-size:12px; min-width:50px }` — the clickable
        // timestamp opening the styled full-timestamp popup.
        if (settings.showTimestamps && timeStr.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 50),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PollTimestampText(
                  label: timeStr,
                  fullTimestamp: fullTimestamp,
                  fontSize: 12,
                ),
              ],
            ),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 120, maxWidth: 320),
          child: authorLine,
        ),
        content,
      ],
    );

    final rowChildren = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        messageRow,
        // Inline poll translation (`translatePoll`, translate.js:361-406): a
        // `.message-translation` block appended AFTER `.message-content`
        // (`contentEl.after`), so it spans the full message width.
        if (_showTranslation)
          _PollTranslation(
            key: ValueKey(_translateLangOverride ?? ''),
            poll: poll,
            targetLang: _translateLangOverride,
          ),
      ],
    );

    // `--style-pattern` watermark behind the content (satoshi ₿ tile, matrix
    // code, …), like the IRC message row.
    final watermark = styleDeco?.watermark;
    final body = Padding(
      // `.message { padding: 10px 14px }`.
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: watermark != null
          ? Stack(
              children: [
                Positioned.fill(
                    child: StyleWatermarkLayer(watermark: watermark)),
                rowChildren,
              ],
            )
          : rowChildren,
    );

    final hasBg = bg != null || bgGradient != null;
    Widget row = Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bgGradient == null ? bg : null,
        // The 135deg supporter/gold gradient on the row.
        gradient: bgGradient != null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: bgGradient,
              )
            : null,
        borderRadius: (hasBg || rowRing != null) ? NymRadius.rsm : null,
        // Gold aura inset ring, approximated as a 1px border (like the IRC
        // message row).
        border: rowRing != null ? Border.all(color: rowRing, width: 1) : null,
        boxShadow: (goldAura?.glowColor != null && glowBlur > 0)
            ? [BoxShadow(color: goldAura!.glowColor!, blurRadius: glowBlur)]
            : null,
      ),
      clipBehavior: hasBg ? Clip.antiAlias : Clip.none,
      child: barColor != null
          ? Stack(
              children: [
                body,
                // The 3px × ~60%-height rounded accent bar, vertically
                // centered (`.message.self::before` / supporter / gold).
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: FractionallySizedBox(
                      heightFactor: 0.6,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: barColor,
                          borderRadius: const BorderRadius.only(
                            topRight: Radius.circular(3),
                            bottomRight: Radius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : body,
    );

    // Hover-capable (non-touch) devices: track `.message:hover` for the row
    // tint and overlay the `.msg-hover-buttons` pair — quick-react + translate
    // — at the row's top-right (`right:10; top:5`, styles-chat.css:357-364).
    // Polls render the pair whenever `!isMobile` (innerWidth > 768,
    // polls.js:283-297 — no event-id validity gate like regular messages).
    final p = Theme.of(context).platform;
    final touchPlatform =
        p == TargetPlatform.android || p == TargetPlatform.iOS;
    if (!touchPlatform) {
      final withButtons =
          MediaQuery.of(context).size.width > NymDimens.mobileBreakpoint;
      Widget hoverChild = row;
      if (withButtons) {
        hoverChild = Stack(
          clipBehavior: Clip.none,
          children: [
            row,
            Positioned(
              top: 5,
              right: 10,
              child: IgnorePointer(
                ignoring: !_hovered,
                child: AnimatedOpacity(
                  opacity: _hovered ? 1 : 0,
                  duration: NymMotion.transition,
                  curve: NymMotion.curve,
                  child: _PollHoverButtons(
                    onReact: () => _openReactionPicker(context),
                    onTranslate: () =>
                        setState(() => _showTranslation = true),
                  ),
                ),
              ),
            ),
          ],
        );
      }
      row = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: hoverChild,
      );
    }
    return row;
  }

  /// `.author-clickable` click → the user context menu, mirroring a normal
  /// message author (polls.js `displayPollMessage`: `showContextMenu(e,
  /// displayAuthor, pubkey, '[Poll] '+question, pollId)`). The panel re-derives
  /// friend/block/group-role flags itself (context_menu_panel.dart:113), so we
  /// only supply identity + the poll body/id. The menu's Translate action then
  /// renders the inline poll translation via [onTranslateInline].
  void _openAuthorMenu(BuildContext context, String selfPubkey) {
    final poll = widget.poll;
    final isBot = ref.read(nostrControllerProvider).isVerifiedBot(poll.pubkey);
    ContextMenuPanel.show(
      context,
      target: CtxTarget(
        pubkey: poll.pubkey,
        nym: stripPubkeySuffix(poll.nym.isEmpty ? 'nym' : poll.nym),
        isSelf: poll.pubkey == selfPubkey,
        content: '[Poll] ${poll.question}',
        messageId: poll.id,
        isBot: isBot,
      ),
      onTranslateInline: (lang) => setState(() {
        _translateLangOverride = lang;
        _showTranslation = true;
      }),
    );
  }

  /// The hover `.reaction-btn` (`reactionShowPicker` with the poll id,
  /// polls.js:286): opens the enhanced reaction picker targeting the poll
  /// event. The synthetic [Message] carries only identity fields — reaction
  /// kind inference falls back to the active view, exactly like the PWA's
  /// `sendReaction` (reactions.js:982-988).
  void _openReactionPicker(BuildContext context) {
    final poll = widget.poll;
    final selfPubkey = ref.read(appStateProvider).selfPubkey;
    showReactionPicker(
      context,
      ref,
      Message(
        id: poll.id,
        author: poll.nym.isEmpty ? 'nym' : poll.nym,
        pubkey: poll.pubkey,
        content: poll.question,
        createdAt: poll.createdAt,
        isOwn: poll.pubkey == selfPubkey,
      ),
    );
  }

  void _showVoters(BuildContext context, Rect anchorRect) {
    final poll = widget.poll;
    // `showPollVotersModal` no-ops when there are no votes (polls.js:459).
    if (poll.votes.isEmpty) return;
    final selfPubkey = ref.read(appStateProvider).selfPubkey;
    final controller = ref.read(nostrControllerProvider);
    showPollVotersModal(
      context,
      anchorRect: anchorRect,
      poll: poll,
      selfPubkey: selfPubkey,
      // Tapping a voter opens a PM with them (polls.js:513-524); self rows
      // just close.
      onOpenPM: (pk) => controller.startPM(pk),
    );
  }
}

/// `.msg-hover-buttons` on a poll (polls.js:283-297): the reaction-picker and
/// translate buttons shown at the row's top-right while hovered, 4px apart.
class _PollHoverButtons extends StatelessWidget {
  const _PollHoverButtons({required this.onReact, required this.onTranslate});

  final VoidCallback onReact;
  final VoidCallback onTranslate;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // `.reaction-btn` — the 20×20 smiley-plus glyph.
        _PollHoverActionButton(svg: NymIcons.addReaction, onTap: onReact),
        const SizedBox(width: 4), // `.msg-hover-buttons { gap: 4px }`
        // `.translate-msg-btn` (`title="Translate"`).
        _PollHoverActionButton(
          svg: NymIcons.translate,
          onTap: onTranslate,
          tooltip: 'Translate',
        ),
      ],
    );
  }
}

/// One `.reaction-btn` / `.translate-msg-btn` (styles-chat.css:366-402): bg
/// rgba(20,20,35,0.8), 1px `--glass-border`, radius-xs, padding 4px 8px,
/// 16px glyph filled `--text`; hover → bg white@0.08 + border primary@0.3.
/// Light mode flips the rest fill to white@0.85 with a black@0.08 border
/// (styles-themes-responsive.css:1184-1187).
class _PollHoverActionButton extends StatefulWidget {
  const _PollHoverActionButton({
    required this.svg,
    required this.onTap,
    this.tooltip,
  });
  final String svg;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  State<_PollHoverActionButton> createState() => _PollHoverActionButtonState();
}

class _PollHoverActionButtonState extends State<_PollHoverActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final restFill = c.isLight
        ? const Color(0xD9FFFFFF) // rgba(255,255,255,0.85)
        : const Color(0xCC141423); // rgba(20,20,35,0.8)
    final restBorder = c.isLight
        ? Colors.black.withValues(alpha: 0.08)
        : c.glassBorder;
    final btn = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _hover ? Colors.white.withValues(alpha: 0.08) : restFill,
            borderRadius: NymRadius.rxs,
            border:
                Border.all(color: _hover ? c.primaryA(0.3) : restBorder),
          ),
          child: NymSvgIcon(widget.svg, size: 16, color: c.text),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: btn)
        : btn;
  }
}

/// The poll's tappable `.message-time.clickable-timestamp` (polls.js:300).
/// Hover tints it `--primary` over 120ms (`.clickable-timestamp:hover`) and
/// shows the glass full-timestamp tooltip (`.message-time:hover::after`);
/// tapping opens the anchored `.timestamp-popup` (`showTimestampPopup`,
/// messages.js:3367-3390) — right-aligned to the timestamp, flipped above/
/// below by head-room, dismissed on the next tap.
class _PollTimestampText extends StatefulWidget {
  const _PollTimestampText({
    required this.label,
    required this.fullTimestamp,
    required this.fontSize,
  });

  final String label;
  final String fullTimestamp;
  final double fontSize;

  @override
  State<_PollTimestampText> createState() => _PollTimestampTextState();
}

class _PollTimestampTextState extends State<_PollTimestampText> {
  bool _hover = false;
  OverlayEntry? _popup;

  @override
  void dispose() {
    _popup?.remove();
    _popup = null;
    super.dispose();
  }

  void _closePopup() {
    _popup?.remove();
    _popup = null;
  }

  /// `showTimestampPopup` placement (messages.js:3377-3384): right-aligned to
  /// the timestamp, 6px above it when there is head-room, else 6px below.
  void _openPopup() {
    _closePopup();
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final overlay = Overlay.of(context);
    final screen = MediaQuery.of(context).size;
    final right = (screen.width - rect.right).clamp(4.0, double.infinity);
    final above = rect.top > 110;
    final entry = OverlayEntry(
      builder: (ctx) {
        final c = ctx.nym;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closePopup,
                onPanStart: (_) => _closePopup(),
              ),
            ),
            Positioned(
              right: right,
              top: above ? null : rect.bottom + 6,
              bottom: above ? screen.height - rect.top + 6 : null,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  // `.reactors-modal { min-width:160; max-width:240 }`.
                  constraints:
                      const BoxConstraints(minWidth: 160, maxWidth: 240),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: c.bgSecondary,
                    borderRadius: NymRadius.rmd,
                    border: Border.all(
                      color: c.isLight
                          ? Colors.black.withValues(alpha: 0.08)
                          : c.glassBorder,
                    ),
                    // dark: shadow-lg + shadow-glow + a 1px white@0.05 ring;
                    // light: `0 8px 32px rgba(0,0,0,0.12)`.
                    boxShadow: c.isLight
                        ? const [
                            BoxShadow(
                                color: Color(0x1F000000),
                                offset: Offset(0, 8),
                                blurRadius: 32),
                          ]
                        : [
                            const BoxShadow(
                                color: Color(0x80000000),
                                offset: Offset(0, 8),
                                blurRadius: 32),
                            BoxShadow(color: c.primaryA(0.1), blurRadius: 20),
                            const BoxShadow(
                                color: Color(0x0DFFFFFF), spreadRadius: 1),
                          ],
                  ),
                  // `.timestamp-popup-body`: 13px --text, nowrap.
                  child: Text(
                    widget.fullTimestamp,
                    softWrap: false,
                    style: TextStyle(color: c.text, fontSize: 13),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    _popup = entry;
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openPopup,
        child: Tooltip(
          message: widget.fullTimestamp,
          triggerMode: TooltipTriggerMode.manual,
          waitDuration: Duration.zero,
          preferBelow: false,
          verticalOffset: 14,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: c.isLight
                ? const Color(0xEBFFFFFF) // rgba(255,255,255,0.92)
                : const Color(0xE6141423), // rgba(20,20,35,0.9)
            borderRadius: NymRadius.rxs,
            border: Border.all(
              color: c.isLight
                  ? Colors.black.withValues(alpha: 0.08)
                  : c.glassBorder,
            ),
            // `--shadow-sm: 0 2px 8px rgba(0,0,0,0.3)`.
            boxShadow: const [
              BoxShadow(
                  color: Color(0x4D000000),
                  offset: Offset(0, 2),
                  blurRadius: 8),
            ],
          ),
          textStyle:
              TextStyle(fontSize: 11, color: c.isLight ? c.text : c.textDim),
          child: AnimatedDefaultTextStyle(
            // `.clickable-timestamp { transition: color 120ms ease }`.
            duration: const Duration(milliseconds: 120),
            curve: Curves.ease,
            style: TextStyle(
              color: _hover ? c.primary : c.textDim,
              fontSize: widget.fontSize,
            ),
            child: Text(widget.label),
          ),
        ),
      ),
    );
  }
}

/// One `.poll-option` row: an absolutely-positioned gradient bar animating its
/// width to `pct%` over 400ms, the option text + right-aligned `NN%`, and a
/// voter-avatar stack (up to 8 + "+N"). Selected rows tint the border/bg
/// primary; pointer hover tints the border primary + a subtle fill
/// (`.poll-option:hover`, styles-features.css:4034-4037 / light
/// styles-themes-responsive.css:1515-1517 — its specificity beats the
/// selected fill).
class _PollOption extends StatefulWidget {
  const _PollOption({
    required this.poll,
    required this.option,
    required this.total,
    required this.selected,
    required this.avatarFor,
    required this.onTap,
  });

  final Poll poll;
  final PollOption option;
  final int total;
  final bool selected;
  final String? Function(String pubkey) avatarFor;
  final VoidCallback? onTap;

  @override
  State<_PollOption> createState() => _PollOptionState();
}

class _PollOptionState extends State<_PollOption> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final poll = widget.poll;
    final option = widget.option;
    final selected = widget.selected;
    final count = poll.votesFor(option.index);
    final pct = widget.total > 0 ? ((count / widget.total) * 100).round() : 0;
    final voters =
        poll.votes.entries.where((e) => e.value == option.index).toList();

    return MouseRegion(
      // `.poll-option { cursor: pointer }` (unconditional).
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          // `transition: all var(--transition)`.
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          decoration: BoxDecoration(
            // Hover: white@0.03 dark / black@0.04 light — its specificity
            // beats the selected white@0.06 fill.
            color: _hover
                ? (c.isLight
                    ? const Color(0x0A000000) // black @ 0.04
                    : Colors.white.withValues(alpha: 0.03))
                : (selected
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.transparent),
            border: Border.all(
                color: (_hover || selected) ? c.primary : c.glassBorder),
            borderRadius: NymRadius.rsm,
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // `.poll-option-bar`: full-height gradient fill whose WIDTH
              // animates to `pct%` over 400ms (`transition: width 0.4s ease`).
              Positioned.fill(
                child: AnimatedFractionallySizedBox(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.ease,
                  alignment: Alignment.centerLeft,
                  widthFactor: (pct / 100.0).clamp(0.0, 1.0),
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: NymRadius.rsm,
                      // `body.light-mode .poll-option-bar` flips to black@.06→.02
                      // and the selected bar to a blue rgb(0,100,200) tint
                      // (styles-themes-responsive.css:1519-1525). Dark base is
                      // white@.06→.02 / primary@.15→.05 (styles-features.css:4044).
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: selected
                            ? (c.isLight
                                ? const [Color(0x1F0064C8), Color(0x0A0064C8)]
                                : [c.primaryA(0.15), c.primaryA(0.05)])
                            : (c.isLight
                                ? const [Color(0x0F000000), Color(0x05000000)]
                                : [
                                    Colors.white.withValues(alpha: 0.06),
                                    Colors.white.withValues(alpha: 0.02),
                                  ]),
                      ),
                    ),
                  ),
                ),
              ),
              // `.poll-option-content` + `.poll-voters`.
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            option.text,
                            style: TextStyle(color: c.text, fontSize: 13),
                          ),
                        ),
                        if (widget.total > 0)
                          ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 35),
                            child: Text(
                              '$pct%',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                color: c.textDim,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    // `.poll-voters` is always emitted (polls.js:266), so every
                    // option reserves the 20px min-height strip 6px below the
                    // text even when nobody voted.
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 20),
                        alignment: Alignment.centerLeft,
                        child: _VoterStack(
                          voters: voters.map((e) => e.key).toList(),
                          avatarFor: widget.avatarFor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.poll-voters`: up to 8 × 20px round avatars (1px glass border) + "+N".
class _VoterStack extends StatelessWidget {
  const _VoterStack({required this.voters, required this.avatarFor});
  final List<String> voters;
  final String? Function(String pubkey) avatarFor;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final visible = voters.take(8).toList();
    final extra = voters.length - visible.length;
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final pk in visible)
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.glassBorder),
            ),
            child: NymAvatar(seed: pk, size: 20, imageUrl: avatarFor(pk)),
          ),
        if (extra > 0)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              '+$extra',
              style: TextStyle(color: c.textDim, fontSize: 10),
            ),
          ),
      ],
    );
  }
}

/// `.poll-footer` (styles-features.css:4105-4120): the raw "N vote(s)" count
/// (polls.js:307 — NO abbreviation), text-dim 11px, padding 2px 6px with
/// `margin-left: -6px` (so the text stays flush with the container), radius-xs.
/// Hover turns it into a pill — bg white@0.06 + `--text` — over 150ms in BOTH
/// themes (no light override). Tapping opens the voters modal anchored to it.
class _PollFooter extends StatefulWidget {
  const _PollFooter({required this.total, required this.onTap});
  final int total;
  final ValueChanged<Rect> onTap;

  @override
  State<_PollFooter> createState() => _PollFooterState();
}

class _PollFooterState extends State<_PollFooter> {
  bool _hover = false;

  void _handleTap() {
    final box = context.findRenderObject() as RenderBox?;
    final rect = (box != null && box.hasSize)
        ? box.localToGlobal(Offset.zero) & box.size
        : Rect.zero;
    widget.onTap(rect);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `${totalVotes} vote${totalVotes !== 1 ? 's' : ''}` — the raw integer.
    final label = '${widget.total} vote${widget.total == 1 ? '' : 's'}';
    return Transform.translate(
      // `.poll-footer { margin-left: -6px }`.
      offset: const Offset(-6, 0),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: _handleTap,
          child: AnimatedContainer(
            // `transition: background 0.15s, color 0.15s`.
            duration: const Duration(milliseconds: 150),
            curve: Curves.ease,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _hover
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.transparent,
              borderRadius: NymRadius.rxs,
            ),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 150),
              curve: Curves.ease,
              style: TextStyle(
                color: _hover ? c.text : c.textDim,
                fontSize: 11,
              ),
              child: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}

/// Maximum voter rows before the "+N more" overflow line
/// (`MAX_ROWS`, polls.js:464).
const int _kPollVotersMaxRows = 100;

/// Shows the `.poll-voters-modal` (`showPollVotersModal`, polls.js:456-533):
/// a `.reactors-modal`-chromed popup anchored to the tapped `.poll-footer` —
/// left-aligned to it (clamped 10px from the viewport edges), 6px above when
/// it fits, else 6px below — dismissed on outside tap.
void showPollVotersModal(
  BuildContext context, {
  required Rect anchorRect,
  required Poll poll,
  required String selfPubkey,
  required void Function(String pubkey) onOpenPM,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final screen = MediaQuery.of(context).size;
  const modalW = 240.0;
  late OverlayEntry entry;

  void close() {
    if (entry.mounted) entry.remove();
  }

  // Horizontal: `left = rect.left`, clamped to [10, innerWidth - width - 10]
  // (polls.js:498-505).
  double left = anchorRect.left;
  if (left + modalW > screen.width - 10) left = screen.width - modalW - 10;
  if (left < 10) left = 10;

  // Vertical: the PWA measures the rendered modal and opens above when
  // `spaceAbove > height + 10` (polls.js:506-511); estimate the height from
  // the row count (header ~43px + ~30px rows, list capped at 320px).
  final shownRows = poll.votes.length > _kPollVotersMaxRows
      ? _kPollVotersMaxRows
      : poll.votes.length;
  final overflowRows = poll.votes.length > _kPollVotersMaxRows ? 1 : 0;
  final estHeight =
      43 + (8 + shownRows * 30 + overflowRows * 33).clamp(0, 320).toDouble();
  final openAbove = anchorRect.top > estHeight + 10;

  entry = OverlayEntry(
    builder: (ctx) => Stack(
      children: [
        // Outside-tap scrim (the PWA's document-level click closer).
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: close,
          ),
        ),
        Positioned(
          left: left,
          top: openAbove ? null : anchorRect.bottom + 6,
          bottom: openAbove ? screen.height - anchorRect.top + 6 : null,
          child: _PollVotersModal(
            poll: poll,
            selfPubkey: selfPubkey,
            onTapRow: (pk) {
              close();
              // `if (pk && pk !== this.pubkey) openUserPM(…)` (polls.js:517).
              if (pk != selfPubkey) onOpenPM(pk);
            },
          ),
        ),
      ],
    ),
  );
  overlay.insert(entry);
}

/// The `.poll-voters-modal` body: a "📊 Voters" header with a 12px dim count
/// badge (polls.js:488), then one `.poll-voters-row` per voter — 18px avatar,
/// nym + `#suffix`, a "you" chip on the self row, and the chosen option in a
/// right-aligned pill (`.poll-voters-choice`) — capped at 100 rows with a
/// "+N more" overflow line. Nyms/avatars resolve live from `usersProvider`
/// (the PWA's `ensureListProfiles`).
class _PollVotersModal extends ConsumerWidget {
  const _PollVotersModal({
    required this.poll,
    required this.selfPubkey,
    required this.onTapRow,
  });

  final Poll poll;
  final String selfPubkey;
  final void Function(String pubkey) onTapRow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final users = ref.watch(usersProvider);
    final optionLabel = {for (final o in poll.options) o.index: o.text};
    final entries = poll.votes.entries.toList();
    final shown = entries.take(_kPollVotersMaxRows).toList();
    final overflow = entries.length - shown.length;
    final borderColor =
        c.isLight ? Colors.black.withValues(alpha: 0.08) : c.glassBorder;

    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: const BoxConstraints(minWidth: 160, maxWidth: 240),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          border: Border.all(color: borderColor),
          borderRadius: NymRadius.rmd,
          // dark (styles-chat.css:495): shadow-lg + shadow-glow + a 1px
          // white@0.05 ring; light (styles-themes-responsive.css:1196-1199):
          // `0 8px 32px rgba(0,0,0,0.12)` only.
          boxShadow: c.isLight
              ? const [
                  BoxShadow(
                      color: Color(0x1F000000),
                      offset: Offset(0, 8),
                      blurRadius: 32),
                ]
              : [
                  const BoxShadow(
                      color: Color(0x80000000),
                      offset: Offset(0, 8),
                      blurRadius: 32),
                  BoxShadow(color: c.primaryA(0.1), blurRadius: 20),
                  const BoxShadow(color: Color(0x0DFFFFFF), spreadRadius: 1),
                ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // `.reactors-modal-header` — "📊 Voters" + the count badge
            // (`.reactors-modal-count`: 12px text-dim), gap 6.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: borderColor)),
              ),
              child: Row(
                children: [
                  Text(
                    '📊 Voters',
                    style: TextStyle(fontSize: 16, color: c.text),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${poll.votes.length}',
                    style: TextStyle(fontSize: 12, color: c.textDim),
                  ),
                ],
              ),
            ),
            // `.poll-voters-modal .reactors-modal-list { max-height: 320px }`.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  children: [
                    for (final e in shown)
                      _row(
                        context,
                        users,
                        e.key,
                        optionLabel[e.value] ?? 'Option ${e.value + 1}',
                      ),
                    // `.reactors-modal-more` — "+N more" (polls.js:482-483).
                    if (overflow > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        child: Text(
                          '+$overflow more',
                          style: TextStyle(
                            fontSize: 12,
                            color: c.textDim,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One `.poll-voters-row` (styles-features.css:4126-4157): gap 6, padding
  /// 6px 8px, 18px avatar, ellipsized nym (suffix at opacity 0.5 / 0.9em), an
  /// optional 10px primary@0.7 "you" chip, and the `.poll-voters-choice` pill
  /// (0.85em text-dim on white@0.06, radius-xs, padding 2px 6px, max 140px).
  Widget _row(
    BuildContext context,
    Map<String, User> users,
    String pk,
    String choice,
  ) {
    final c = context.nym;
    final isYou = pk == selfPubkey;
    final nym = stripPubkeySuffix(users[pk]?.nym ?? getNymFromPubkey('nym', pk));
    final suffix = getPubkeySuffix(pk);
    return InkWell(
      onTap: () => onTapRow(pk),
      // `.reactors-modal-user:hover` — white@0.06 dark / black@0.05 light.
      hoverColor: c.isLight
          ? Colors.black.withValues(alpha: 0.05)
          : Colors.white.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            NymAvatar(seed: pk, size: 18, imageUrl: users[pk]?.profile?.picture),
            const SizedBox(width: 6),
            Expanded(
              child: RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: TextStyle(fontSize: 13, color: c.text),
                  children: [
                    TextSpan(text: nym),
                    if (suffix.isNotEmpty)
                      TextSpan(
                        text: '#$suffix',
                        style: TextStyle(
                          color: c.text.withValues(alpha: 0.5),
                          fontSize: 13 * 0.9,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (isYou) ...[
              const SizedBox(width: 6),
              Text(
                'you',
                style: TextStyle(
                  fontSize: 10,
                  color: c.primary.withValues(alpha: 0.7),
                ),
              ),
            ],
            const SizedBox(width: 6),
            Container(
              constraints: const BoxConstraints(maxWidth: 140),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: NymRadius.rxs,
              ),
              child: Text(
                choice,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13 * 0.85, color: c.textDim),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The inline `.message-translation` block for a poll (`translatePoll`,
/// translate.js:361-406). Translates the segment list `[question, …options]`
/// (each via [TranslateService.translate], mirroring `_translatePreservingMentions`)
/// and renders the translated question (`.poll-translation-question`, bold) over
/// `• option` lines (`.poll-translation-option`, 0.95em opacity 0.9) plus the
/// `source → target` label. Container styling matches [MessageTranslation]
/// (`.message-translation`, styles-features.css:4310-4320).
class _PollTranslation extends ConsumerStatefulWidget {
  const _PollTranslation({super.key, required this.poll, this.targetLang});

  final Poll poll;

  /// Override target language; defaults to `settings.translateLanguage`.
  final String? targetLang;

  @override
  ConsumerState<_PollTranslation> createState() => _PollTranslationState();
}

class _PollTranslationState extends ConsumerState<_PollTranslation> {
  final TranslateService _service = TranslateService();
  late final List<String> _segments;
  late final Future<List<TranslationResult>> _future;

  String get _target =>
      widget.targetLang ?? ref.read(settingsProvider).translateLanguage;

  @override
  void initState() {
    super.initState();
    // `[poll.question, ...poll.options.map(o => o.text)]` (translate.js:380).
    _segments = [
      widget.poll.question,
      for (final o in widget.poll.options) o.text,
    ];
    final target = _target.isEmpty ? 'en' : _target;
    _future = Future.wait(
      _segments.map((s) => _service.translate(s, target)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        // `.message-translation` — bg white@0.04, left primary rule, right-only
        // radius (styles-features.css:4310-4320).
        color: Colors.white.withValues(alpha: 0.04),
        border: Border(left: BorderSide(color: c.primary, width: 3)),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(NymRadius.xs),
          bottomRight: Radius.circular(NymRadius.xs),
        ),
      ),
      child: FutureBuilder<List<TranslationResult>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            // `.translation-loading`: static italic dim@0.6 (no pulse, matching
            // the inline message translation, styles-features.css:4333).
            return Text(
              'Translating...',
              style: TextStyle(
                color: c.textDim.withValues(alpha: 0.6),
                fontStyle: FontStyle.italic,
                fontSize: 13,
              ),
            );
          }
          if (snap.hasError) {
            return Text(
              'Translation failed',
              style: TextStyle(color: c.danger, fontSize: 12),
            );
          }
          final results = snap.data!;
          final translated = [
            for (final r in results) r.translatedText,
          ];
          // `allNoop`: every segment came back blank or unchanged
          // (translate.js:387).
          final allNoop = () {
            for (var i = 0; i < _segments.length; i++) {
              final t = (i < translated.length ? translated[i] : '').trim();
              if (t.isNotEmpty && t != _segments[i].trim()) return false;
            }
            return true;
          }();
          if (allNoop) {
            return Text.rich(
              TextSpan(children: [
                const TextSpan(text: '🌐 '),
                TextSpan(
                  text:
                      'Already in ${languageName(_target)} (nothing to translate)',
                  style: TextStyle(color: c.danger, fontSize: 13 * 0.85),
                ),
              ]),
            );
          }
          // First non-`auto` detected language wins (translate.js:385).
          var detected = 'auto';
          for (final r in results) {
            if (r.detectedLanguage.isNotEmpty &&
                r.detectedLanguage != 'auto') {
              detected = r.detectedLanguage;
              break;
            }
          }
          final showLang = detected != 'auto' && detected != _target;
          final question = translated.isNotEmpty && translated[0].isNotEmpty
              ? translated[0]
              : widget.poll.question;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // `🌐` + `.poll-translation-question` (bold, margin-bottom 4).
              Text.rich(
                TextSpan(
                  style:
                      TextStyle(color: c.textDim, fontSize: 13, height: 1.4),
                  children: [
                    const TextSpan(text: '🌐 '),
                    TextSpan(
                      text: question,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // `.poll-translation-option` — "• {translated}" per option.
              for (var i = 0; i < widget.poll.options.length; i++)
                Text(
                  '• ${(i + 1 < translated.length && translated[i + 1].isNotEmpty) ? translated[i + 1] : widget.poll.options[i].text}',
                  style: TextStyle(
                    color: c.textDim.withValues(alpha: 0.9),
                    fontSize: 13 * 0.95,
                    height: 1.4,
                  ),
                ),
              if (showLang)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${languageName(detected)} → ${languageName(_target)}',
                    style: TextStyle(
                      color: c.textDim.withValues(alpha: 0.7),
                      fontSize: 13 * 0.8,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

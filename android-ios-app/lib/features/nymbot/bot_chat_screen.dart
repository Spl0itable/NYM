import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/composer.dart'
    show ComposerDrafts, EmojiSentinelController;
import '../../widgets/chat/message_row.dart' show MessageGroup, MessageGroupEntry;
import '../../widgets/chat/typing_indicator.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/context_menu/context_menu_panel.dart';
import '../../widgets/context_menu/interaction_hooks.dart';
import '../../widgets/context_menu/profile_badges.dart' show VerifiedBadge;
import '../../widgets/nym_icons.dart';
import '../emoji/emoji_data.dart';
import '../emoji/emoji_picker.dart';
import '../emoji/gif_picker.dart';
import '../reactions/reaction_picker.dart';
import '../translate/translate_languages.dart';
import '../translate/translate_service.dart';
import 'bot_credits_modal.dart';
import 'nymbot_models.dart';
import 'nymbot_providers.dart';

/// The private 1:1 Nymbot chat screen.
///
/// The conversation itself is the CANONICAL PM thread
/// (`AppState.messages['pm-<botPubkey>']`, fed by [BotChatController]), rendered
/// through the same [MessageGroup]/`MessageRow` pipeline as every other PM —
/// IRC/bubble layout setting, 5-minute grouping, sticky group avatar, author
/// headers (incl. self), delivery ticks, crypto locks, reactions, context menu,
/// swipe/double-tap quote-reply, the shared typing-indicator strip and the
/// scroll-to-bottom button. Exactly how the PWA routes the bot PM through
/// `displayMessage()` (pms.js:1291-1339).
///
/// Premium features kept on top of the canonical chat (intentional additions):
///   * the Standard / Pro tier switch + `?model` picker sheet,
///   * `?balance` / `?buy` (shared credits modal),
///   * the `?git` connect modal (typed `?git …` subcommands run in-chat).
class BotChatScreen extends ConsumerStatefulWidget {
  const BotChatScreen({super.key, this.onOpenSidebar});

  /// Mobile/tablet: opens the off-canvas sidebar drawer (the chat-header
  /// hamburger). Null on wide layouts, where the sidebar is always visible.
  final VoidCallback? onOpenSidebar;

  @override
  ConsumerState<BotChatScreen> createState() => _BotChatScreenState();
}

class _BotChatScreenState extends ConsumerState<BotChatScreen> {
  final _scroll = ScrollController();

  /// Whether the floating scroll-to-bottom chevron shows (the PWA's
  /// `distanceFromBottom > 150` gate, app.js:7120-7124). In the reversed list
  /// `offset` IS the distance from the bottom.
  bool _showScrollButton = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Bind the paid surface to the live identity, make the bot PM the active
      // view (receipts / read-marking / typing all key off it, like openPM),
      // then render the empty-thread intro + refresh credits.
      final nostr = ref.read(nostrControllerProvider);
      nostr.bindBotChat();
      ref
          .read(appStateProvider.notifier)
          .switchView(const ChatView.pm(kNymbotPubkey));
      final engine = ref.read(botChatControllerProvider.notifier);
      // Paid-auth signs through the ACTIVE signer (local or NIP-46 remote) —
      // the PWA's `_signBotAuth` generic dispatch (pms.js:1649-1679).
      engine.attachSigner(nostr.signer);
      engine.ensureIntro();
      engine.refreshBalance();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScrolled() {
    final show = _scroll.hasClients && _scroll.offset > 150;
    if (show != _showScrollButton) {
      setState(() => _showScrollButton = show);
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0,
        duration: NymMotion.transition, curve: NymMotion.curve);
  }

  NymColors _colors(BuildContext context) =>
      Theme.of(context).extension<NymColors>() ?? _fallbackColors;

  @override
  Widget build(BuildContext context) {
    final c = _colors(context);
    final state = ref.watch(botChatControllerProvider);

    // NOTE: `?buy` / out-of-credits (`botBuyRequestProvider`) AND gift requests
    // (`?gift` / context-menu "Gift Nymbot Credits") are handled by the
    // always-mounted listeners in home_shell.dart — no second listener here,
    // or the modal would open twice.

    return Scaffold(
      backgroundColor: c.bg,
      appBar: _header(context, c, state),
      body: Column(
        children: [
          _TierSwitch(
            isPro: state.isPro,
            proLabel: state.proModel?.label,
            colors: c,
            onTapStandard: () => ref
                .read(botChatControllerProvider.notifier)
                .setModelDirect(null),
            onTapPro: () => _showModelPicker(context),
          ),
          Expanded(
            // Tap on the messages region drops focus (dismisses the keyboard)
            // when no interactive child consumes it — same wiring as the
            // canonical ChatPane; the browser gives the PWA this for free.
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusScope.of(context).unfocus(),
              child: _buildMessagesArea(c),
            ),
          ),
          // The shared `.typing-indicator` strip pinned above the composer —
          // "Nymbot is thinking" with the 18px avatar + bouncing dots
          // (pms.js `_setBotTyping` → `_renderTypingInto`).
          const TypingIndicatorRow(
              storageKey: 'pm-$kNymbotPubkey'),
          _BotComposer(
            colors: c,
            onSubmit: (content) {
              ref
                  .read(botChatControllerProvider.notifier)
                  .sendUserBotPM(content);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _scrollToBottom();
              });
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header (`_renderPMHeader`, pms.js:2905-2941)
  // ---------------------------------------------------------------------------

  PreferredSizeWidget _header(
      BuildContext context, NymColors c, BotChatState state) {
    final botUser = ref.watch(usersProvider)[kNymbotPubkey];
    return AppBar(
      backgroundColor: c.bgSecondary,
      foregroundColor: c.textBright,
      titleSpacing: 0,
      toolbarHeight: 68,
      automaticallyImplyLeading: false,
      // Compact layouts keep the hamburger so the off-canvas sidebar stays
      // reachable from the bot PM (the shared `.mobile-menu-toggle`).
      leading: widget.onOpenSidebar == null
          ? null
          : IconButton(
              tooltip: 'Menu',
              icon: NymSvgIcon(NymIcons.menu, size: 20, color: c.primary),
              onPressed: widget.onOpenSidebar,
            ),
      title: Row(
        children: [
          // `.pm-header-avatar`: 26px avatar with a 7px status dot — the bot is
          // always online (pms.js `getEffectiveUserStatus` bot override).
          SizedBox(
            width: 30,
            height: 30,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                NymAvatar(
                  seed: kNymbotPubkey,
                  size: 26,
                  imageUrl: botUser?.profile?.picture,
                ),
                Positioned(
                  // `.pm-header-avatar .user-status-dot`: 7px, bottom/right -2.
                  right: 2,
                  bottom: 2,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      // `.status-online` #22c55e ringed by 2px --bg.
                      color: const Color(0xFF22C55E),
                      shape: BoxShape.circle,
                      border: Border.all(color: c.bg, width: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // `.pm-header-row` is `header-clickable`: tapping the name opens
                // the bot's profile context menu (pms.js:2929-2932).
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openHeaderMenu(context),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text.rich(
                          TextSpan(children: [
                            const TextSpan(text: 'Nymbot'),
                            TextSpan(
                              text: '#${getPubkeySuffix(kNymbotPubkey)}',
                              // `.nym-suffix`: opacity 0.7 / 0.9em / weight 100.
                              style: TextStyle(
                                color: c.textBright.withValues(alpha: 0.7),
                                fontSize: 16 * 0.9,
                                fontWeight: FontWeight.w100,
                              ),
                            ),
                          ]),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: c.textBright,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const VerifiedBadge(size: 16),
                    ],
                  ),
                ),
                // `.pm-last-seen` presence line — the bot's is the fixed
                // 'Always at your service' (pms.js:37).
                Text(
                  'Always at your service',
                  style: TextStyle(color: c.textDim, fontSize: 12, height: 1.2),
                  overflow: TextOverflow.ellipsis,
                ),
                // `#channelMeta` for the bot PM: 12px lock +
                // 'E2E encrypted · <botCreditMeta>' (pms.js:2934-2938).
                Row(
                  children: [
                    NymSvgIcon(NymIcons.lock, size: 12, color: c.textDim),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'E2E encrypted · ${_botCreditMeta(state)}',
                        style: TextStyle(
                            color: c.textDim, fontSize: 11, height: 1.2),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Balance',
          icon: Icon(Icons.account_balance_wallet_outlined, color: c.text),
          onPressed: () => _showBalance(context),
        ),
        IconButton(
          tooltip: 'Connect git repo',
          icon: Icon(Icons.source_outlined,
              color: (state.git?.hasRepo ?? false) ? c.primary : c.text),
          onPressed: () => _showGitConnect(context),
        ),
      ],
    );
  }

  /// The `#botCreditMeta` text (`_renderBotCreditMeta`, pms.js:2361-2380):
  /// Pro pinned → `'<n> Pro credit(s) · <model> [· <repoName>]'`; otherwise the
  /// standard count (`'<n> credit(s) left'`, or both pools when Pro credits
  /// exist). 'checking credits…' until the first balance lands.
  String _botCreditMeta(BotChatState state) {
    final proModel = state.proModel;
    if (proModel != null) {
      final pro = state.balance.proBalance;
      final proText = state.balanceKnown ? '$pro' : '…';
      var meta = '$proText Pro credit${pro == 1 ? '' : 's'} · ${proModel.label}';
      final git = state.git;
      if (git != null && git.hasRepo) {
        meta += ' · ${git.repo.split('/').last}';
      }
      return meta;
    }
    if (!state.balanceKnown) {
      // A failed check with no cached count settles on 'credits unavailable'
      // (`_refreshBotCreditMeta`, pms.js:2382-2389).
      return state.balanceUnavailable ? 'credits unavailable' : 'checking credits…';
    }
    final std = state.balance.balance;
    final pro = state.balance.proBalance;
    return pro > 0
        ? '$std standard · $pro Pro credits left'
        : '$std credit${std == 1 ? '' : 's'} left';
  }

  /// Header name tap → the bot's profile context menu (the PWA's
  /// `showContextMenu(e, nym, pubkey, null, null, true)` — profile mode).
  void _openHeaderMenu(BuildContext context) {
    ContextMenuPanel.show(
      context,
      target: const CtxTarget(
        pubkey: kNymbotPubkey,
        nym: 'Nymbot',
        isSelf: false,
        isBot: true,
        profileOnly: true,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Message list — the canonical `.messages-container` pipeline
  // ---------------------------------------------------------------------------

  static const int _groupWindowSec = 300; // 5 min (messages.js:1557)

  Widget _buildMessagesArea(NymColors c) {
    final app = ref.watch(appStateProvider);
    final settings = ref.watch(settingsProvider);
    final reactions = ref.watch(reactionsProvider);
    // The canonical thread merged with the LOCAL-ONLY info bubbles (welcome,
    // `?help` guide, command outputs — never in the shared store, never
    // persisted; PWA `_displayBotInfoMessage`, pms.js:1773-1776).
    final msgs = mergeBotThreadWithInfo(
      app.messages[BotChatController.conversationKey] ?? const <Message>[],
      ref.watch(botChatControllerProvider).infoMessages,
    );

    // `.messages-container` bg: black@0.15 dark / white@0.3 light.
    final containerColor = c.isLight
        ? const Color(0x4DFFFFFF) // white @ 0.3
        : const Color(0x26000000); // black @ 0.15

    final mentionToken = '@${stripPubkeySuffix(app.selfNym)}';

    // Fold consecutive same-author bubble messages into render groups (the
    // PWA's `.message-group`, 5-minute window) so the group's single avatar can
    // glide over the run — identical fold to `messages_list.dart`.
    final units = <List<MessageGroupEntry>>[];
    for (final m in msgs) {
      final entry = MessageGroupEntry(
        message: m,
        reactions: reactions[m.id] ?? const [],
        mentioned: !m.isOwn && m.content.contains(mentionToken),
      );
      if (settings.useBubbles &&
          units.isNotEmpty &&
          _groupsWith(units.last.last.message, m)) {
        units.last.add(entry);
      } else {
        units.add([entry]);
      }
    }

    return ColoredBox(
      color: containerColor,
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView.builder(
              controller: _scroll,
              reverse: true,
              // Drag on the list dismisses the keyboard, like the canonical
              // MessagesList's on-drag unfocus.
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              // Scroller padding (`styles-shell.css:941`).
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              itemCount: units.length,
              itemBuilder: (context, revIndex) {
                final unit = units[units.length - 1 - revIndex];
                // A reasoning-bearing bot reply renders its collapsed
                // "💭 Reasoning" section INSIDE the bubble content — the
                // canonical MessageRow prepends it (messages.js:796-797).
                return MessageGroup(
                  entries: unit,
                  settings: settings,
                  onReactionPicker: (msg) =>
                      showReactionPicker(context, ref, msg),
                );
              },
            ),
          ),
          // `.scroll-to-bottom-btn` — shown >150px from the bottom.
          if (_showScrollButton)
            Positioned(
              right: 24,
              bottom: 16,
              child: _ScrollToBottomButton(onTap: _scrollToBottom),
            ),
        ],
      ),
    );
  }

  /// Whether [cur] bubble-groups onto [prev]: same author within the 5-minute
  /// window, neither a system pill nor a `/me` action (messages.js:1679-1706).
  /// A thinking reply groups NORMALLY — its `.bot-think` section renders inside
  /// the bubble (messages.js:1552-1568 has no thinking exclusion).
  bool _groupsWith(Message prev, Message cur) =>
      !prev.isSystemRow &&
      !cur.isSystemRow &&
      !prev.isMeAction &&
      !cur.isMeAction &&
      prev.pubkey == cur.pubkey &&
      (cur.createdAt - prev.createdAt).abs() <= _groupWindowSec;

  // ---------------------------------------------------------------------------
  // Modals (premium surfaces kept on top of the canonical chat)
  // ---------------------------------------------------------------------------

  void _showBalance(BuildContext context) {
    final c = _colors(context);
    final b = ref.read(botChatControllerProvider).balance;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bgSecondary,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Credit balance',
                style: TextStyle(
                    color: c.textBright,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            _balanceRow('Standard', b.balance, '10 sats each', c),
            const SizedBox(height: 8),
            _balanceRow('Pro', b.proBalance, '100 sats each', c,
                accent: c.primary),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  _showBuy(context);
                },
                child: const Text('Buy credits'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _balanceRow(String label, int value, String hint, NymColors c,
      {Color? accent}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: accent ?? c.blue, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: c.textBright, fontWeight: FontWeight.w600)),
                Text(hint, style: TextStyle(color: c.textDim, fontSize: 11)),
              ],
            ),
          ),
          Text('$value',
              style: TextStyle(
                  color: c.textBright,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          Text('cr', style: TextStyle(color: c.textDim, fontSize: 11)),
        ],
      ),
    );
  }

  void _showBuy(BuildContext context) {
    // Buy mode of the shared credits modal (PWA: same modal as gift, no
    // recipient). Pro tier preselected when a Pro model is pinned.
    final state = ref.read(botChatControllerProvider);
    BotCreditsModal.show(
      context,
      colors: _colors(context),
      initialTier: state.isPro ? CreditTier.pro : CreditTier.standard,
    );
  }

  void _showModelPicker(BuildContext context) {
    final c = _colors(context);
    final current = ref.read(botChatControllerProvider).proModel;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bgSecondary,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Text('Pro model',
                      style: TextStyle(
                          color: c.textBright,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('100 sats / credit',
                      style: TextStyle(color: c.textDim, fontSize: 11)),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.auto_awesome, color: c.blue),
              title: Text('Standard (auto-routed)',
                  style: TextStyle(color: c.text)),
              subtitle: Text('Best model per task · 10 sats each',
                  style: TextStyle(color: c.textDim, fontSize: 11)),
              trailing: current == null
                  ? Icon(Icons.check, color: c.primary)
                  : null,
              onTap: () {
                ref.read(botChatControllerProvider.notifier).setModelDirect(null);
                Navigator.pop(context);
              },
            ),
            Divider(height: 1, color: c.border),
            for (final m in kProModels)
              ListTile(
                leading: Icon(Icons.bolt, color: c.primary),
                title: Text(m.label, style: TextStyle(color: c.text)),
                // PWA `?model` list: the human price-range phrase, not the id.
                subtitle: Text(
                    m.priceLabel,
                    style: TextStyle(color: c.textDim, fontSize: 11)),
                trailing: current?.key == m.key
                    ? Icon(Icons.check, color: c.primary)
                    : null,
                onTap: () {
                  ref
                      .read(botChatControllerProvider.notifier)
                      .setModelDirect(m);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showGitConnect(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _colors(context).bgSecondary,
      builder: (_) => _GitConnectModal(
        colors: _colors(context),
        existing: ref.read(botChatControllerProvider).git,
        onConnect: (cfg) =>
            ref.read(botChatControllerProvider.notifier).connectGit(cfg),
        onDisconnect: () =>
            ref.read(botChatControllerProvider.notifier).disconnectGit(),
      ),
    );
  }
}

// =============================================================================
// `.scroll-to-bottom-btn` (styles-chat.css:9-43): 40×40 round glass FAB with a
// primary down-chevron, hover glow + scale 1.1; light mode flips the rest fill
// to white@0.85 / border primary@0.2 (styles-themes-responsive.css:607-615).
// =============================================================================

class _ScrollToBottomButton extends StatefulWidget {
  const _ScrollToBottomButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ScrollToBottomButton> createState() => _ScrollToBottomButtonState();
}

class _ScrollToBottomButtonState extends State<_ScrollToBottomButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final light = c.isLight;
    final fill = _hover
        ? c.primaryA(0.15)
        : (light ? const Color(0xD9FFFFFF) /* white @ 0.85 */ : c.glassBg);
    final border = _hover
        ? c.primaryA(0.30)
        : (light ? c.primaryA(0.20) : c.glassBorder);
    final shadow = light
        ? const BoxShadow(
            color: Color(0x26000000), // black @ 0.15
            offset: Offset(0, 2),
            blurRadius: 12,
          )
        : const BoxShadow(
            color: Color(0x66000000), // black @ 0.4
            offset: Offset(0, 4),
            blurRadius: 16,
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.1 : 1.0,
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              border: Border.all(color: border),
              boxShadow: [shadow],
            ),
            child: NymSvgIcon(NymIcons.chevronDown, size: 20, color: c.primary),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Tier switch (Standard / Pro) — intentional premium addition
// =============================================================================

class _TierSwitch extends StatelessWidget {
  const _TierSwitch({
    required this.isPro,
    required this.proLabel,
    required this.colors,
    required this.onTapStandard,
    required this.onTapPro,
  });

  final bool isPro;
  final String? proLabel;
  final NymColors colors;
  final VoidCallback onTapStandard;
  final VoidCallback onTapPro;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          // PWA `.bot-credit-tier-btn.active`: both segments use the lightning
          // accent (orange) — fill @0.12, border @0.5, text --lightning bold.
          _segment('Standard', !isPro, onTapStandard, c),
          _segment(
            isPro && proLabel != null ? 'Pro · $proLabel' : 'Pro',
            isPro,
            onTapPro,
            c,
          ),
        ],
      ),
    );
  }

  Widget _segment(String label, bool active, VoidCallback onTap, NymColors c) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? c.lightning.withValues(alpha: 0.12)
                // Inactive fill: white@0.04 dark / black@0.04 light. `insetFill`
                // is mode-aware so the pill stays visible in light mode.
                : c.insetFill,
            // `.bot-credit-tier-btn`: radius --radius-sm (12).
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? c.lightning.withValues(alpha: 0.5) : c.border,
              width: 1,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: active ? c.lightning : c.textDim,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Composer — the PWA `.input-container` chrome (styles-chat.css:1384-1965)
// =============================================================================

class _BotComposer extends ConsumerStatefulWidget {
  const _BotComposer({
    required this.colors,
    required this.onSubmit,
  });

  final NymColors colors;

  /// Receives the composed outgoing content (quote prefix already applied).
  final ValueChanged<String> onSubmit;

  @override
  ConsumerState<_BotComposer> createState() => _BotComposerState();
}

class _BotComposerState extends ConsumerState<_BotComposer> {
  /// The shared rich composer controller: known `:code:` collapse to sentinel
  /// chars painted as 1.4em inline emoji images while composing, and
  /// [EmojiSentinelController.expand] restores the literal shortcodes at send —
  /// the PWA's single rich `#messageInput` (`_maybeRenderTypedEmoji`,
  /// ui-context.js:1968), which bot PMs share.
  final _controller = EmojiSentinelController();
  final _focus = FocusNode();

  /// The currently-filtered `?…` suggestions (empty → palette hidden).
  List<BotPMCommand> _suggestions = const [];

  /// Highlighted palette row — reset to the first row on every input change,
  /// like `showBotCommandPalette` (`commandPaletteIndex = 0`, commands.js:464).
  int _paletteIndex = 0;

  /// Escape hides the palette until the input text changes again
  /// (`hideCommandPalette`; the next input event re-shows it,
  /// ui-context.js:1003-1005).
  bool _suppressPalette = false;

  /// Last seen input text, so selection-only controller notifications don't
  /// count as input events (the PWA palette reacts to `input` only).
  String _lastText = '';

  /// Deferred quote-reply chip (`setQuoteReply`): author + stripped text; the
  /// quote is prepended to the outgoing content only at send.
  ({String author, String text})? _pendingQuote;

  // Emoji / GIF picker popovers, anchored above their toolbar buttons like the
  // PWA's inline `bottom:100%` popups.
  final _emojiPortal = OverlayPortalController();
  final _gifPortal = OverlayPortalController();
  final _emojiAnchor = LayerLink();
  final _gifAnchor = LayerLink();
  SharedPreferences? _prefs;
  List<String> _recents = const [];

  // --- Attachments (`selectImage` / `selectP2PFile`, index.html:759-775) ----
  // The bot PM shares the canonical `.input-buttons` in the PWA, so the
  // Image/Video upload and P2P-file buttons are present here too.

  /// `#uploadProgress` state (0..1, null = hidden) — the progress panel shown
  /// during `uploadImage` (users.js:971+).
  double? _uploadProgress;
  String? _uploadMime;
  bool _uploadCancelled = false;

  /// 1-based index + total of the current multi-file upload ("Uploading i of
  /// N…" when N>1, users.js:1006-1008). 0/0 = single-file.
  int _uploadIndex = 0;
  int _uploadTotal = 0;

  // --- In-composer translate (`#translateInputBtn` + its 230px dropdown, ----
  // translate.js:563-600) — the bot PM shares the same `.message-input-row`.
  final _translatePortal = OverlayPortalController();
  final _translateAnchor = LayerLink();
  final _translateSearchController = TextEditingController();
  String _translateQuery = '';
  bool _translating = false;

  /// Translate-dropdown favorites (`nym_translate_favorites`), pinned to the
  /// top of the language list (translate.js:93-108).
  List<String> _translateFavorites = const [];

  /// Favorites-pinned order snapshotted when the dropdown opens ("the next
  /// time the dropdown opens", translate.js:563-571) — toggling a star
  /// mid-open doesn't reshuffle.
  List<MapEntry<String, String>> _translateLangOrder = const [];

  /// The bot conversation's draft key in the shared session store — the PWA's
  /// one persistent `#messageInput` keeps bot-PM drafts in the same
  /// `_inputDrafts` map as every other conversation (`_getInputContextKey`
  /// `'p:'+pm`, channels.js:1075-1105).
  static final String _draftKey =
      ComposerDrafts.keyFor(const ChatView.pm(kNymbotPubkey));

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focus.addListener(() => setState(() {}));
    // Restore any unsent input previously typed for the bot conversation
    // (`_restoreDraftForContext` on open, pms.js:3023-3024). Post-frame so the
    // change listener's setState never fires mid-mount.
    final draft = ComposerDrafts.restore(_draftKey);
    if (draft.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _controller.text = draft;
        _controller.selection = TextSelection.collapsed(offset: draft.length);
      });
    }
  }

  @override
  void dispose() {
    // Stash the unsent input before this composer unmounts (switching away
    // from the bot chat) — `_saveCurrentDraft` on every conversation switch
    // (channels.js:1082-1089); a blank draft deletes the entry.
    ComposerDrafts.save(_draftKey, _controller.expand(_controller.text));
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focus.dispose();
    _translateSearchController.dispose();
    super.dispose();
  }

  Future<SharedPreferences> _ensurePrefs() async =>
      _prefs ??= await SharedPreferences.getInstance();

  void _onTextChanged() {
    // Collapse any just-completed known `:code:` into its inline-image
    // sentinel (mirrors `_maybeRenderTypedEmoji` firing on input). A rewrite
    // re-notifies; the second pass is a no-op.
    _controller.resolveInput();
    final text = _controller.text;
    final textChanged = text != _lastText;
    _lastText = text;
    final next = text.startsWith('?')
        ? filterBotPMCommands(text)
        : const <BotPMCommand>[];
    if (textChanged) {
      // Every input event re-shows the palette (after an Escape) and
      // re-highlights the first row (showBotCommandPalette).
      _suppressPalette = false;
      _paletteIndex = 0;
    }
    if (!_sameCommands(next, _suggestions)) {
      setState(() => _suggestions = next);
    } else {
      // Rebuild for the SEND-affordance / translate-style hooks keyed on text.
      setState(() {});
    }
  }

  /// Cheap equality on the (small) suggestion lists, by command name+order.
  bool _sameCommands(List<BotPMCommand> a, List<BotPMCommand> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].name != b[i].name) return false;
    }
    return true;
  }

  void _pick(BotPMCommand cmd) {
    final text = '${cmd.name} ';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    // Re-filter so a multi-step command (e.g. `?git `) immediately surfaces its
    // subcommands; a leaf command just hides the palette.
    _onTextChanged();
    _focus.requestFocus();
  }

  // --- Quote-reply chip (mention/quote mailbox from swipe / menu / dbl-tap) ---

  void _applyComposerAction(ComposerAction action) {
    switch (action) {
      case MentionAction(:final fullNym):
        final existing = _controller.text;
        final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
        _controller.text = '$existing${needsSpace ? ' ' : ''}@$fullNym ';
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
      case QuoteAction(:final fullNym, :final content):
        _pendingQuote = (author: fullNym, text: _strippedQuoteText(content));
    }
    _focus.requestFocus();
    setState(() {});
  }

  /// Strips nested `>` quote lines (keep only the top level), collapses blank
  /// runs, and trims — the `setQuoteReply` pre-processing (messages.js:1817).
  static String _strippedQuoteText(String text) {
    final kept = <String>[];
    for (final line in text.split('\n')) {
      if (!line.startsWith('>')) kept.add(line);
    }
    return kept
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// The chip's cleaned preview text: strip HTML/markdown punctuation, cap 120
  /// (`cleanText` in setQuoteReply, messages.js:1845-1846).
  static String _quotePreviewText(String text) {
    final clean = text
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'[*_~`>#]'), '');
    return clean.length > 120 ? '${clean.substring(0, 120)}...' : clean;
  }

  void _clearQuote() {
    if (_pendingQuote == null) return;
    setState(() => _pendingQuote = null);
  }

  /// Prepends the pending quote to [typed] ONLY at send (messages.js:2354-2361).
  String _composeOutgoing(String typed) {
    var content = typed;
    final quote = _pendingQuote;
    if (quote != null) {
      final lines = quote.text.split('\n');
      final quoteRest = lines.length > 1
          ? '\n${lines.skip(1).map((l) => '> $l').join('\n')}'
          : '';
      final quoteLine = '> @${quote.author}: ${lines.first}$quoteRest';
      content = content.isNotEmpty ? '$quoteLine\n\n$content' : quoteLine;
      _pendingQuote = null;
    }
    return content;
  }

  void _send() {
    // Expand sentinel chars back to literal `:code:` before anything leaves
    // the composer (wire safety — the sentinel is render-only).
    final typed = _controller.expand(_controller.text).trim();
    // The PWA allows sending a bare quote: `if (!content && !pendingQuote)`.
    if (typed.isEmpty && _pendingQuote == null) return;
    final content = _composeOutgoing(typed);
    widget.onSubmit(content);
    _controller.clear();
    setState(() {});
    _focus.requestFocus();
  }

  /// With the `?` palette open: ↑/↓ move the highlight (wrapping), Enter/Tab
  /// pick the highlighted command, Escape hides the palette until the input
  /// changes (ui-context.js:992-1005 → navigateCommandPalette/selectCommand).
  /// Otherwise hardware Enter sends; Shift+Enter inserts a newline
  /// (ui-context.js:1007-14). Esc cancels a pending quote chip.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (_suggestions.isNotEmpty && !_suppressPalette) {
      final n = _suggestions.length;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() => _paletteIndex = (_paletteIndex + 1) % n);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() => _paletteIndex = (_paletteIndex - 1 + n) % n);
        return KeyEventResult.handled;
      }
      if (isEnter || event.logicalKey == LogicalKeyboardKey.tab) {
        _pick(_suggestions[_paletteIndex.clamp(0, n - 1)]);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() => _suppressPalette = true);
        return KeyEventResult.handled;
      }
    }
    if (isEnter && !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        _pendingQuote != null) {
      _clearQuote();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _insertAtCaret(String insert) {
    final text = _controller.text;
    final sel = _controller.selection;
    final at = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(at, end, insert);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
  }

  Future<void> _onEmojiSelected(String emoji) async {
    _insertAtCaret(emoji);
    _emojiPortal.hide();
    final prefs = await _ensurePrefs();
    final next = await EmojiRecentsStore(prefs).add(emoji);
    if (!mounted) return;
    setState(() => _recents = next);
  }

  void _onGifSelected(String url) {
    // PWA appends the GIF URL; the formatter renders it as media.
    _insertAtCaret(url);
    _gifPortal.hide();
  }

  Future<void> _toggleEmojiPicker() async {
    if (_emojiPortal.isShowing) {
      _emojiPortal.hide();
      return;
    }
    _gifPortal.hide();
    final prefs = await _ensurePrefs();
    if (!mounted) return;
    _recents = EmojiRecentsStore(prefs).load();
    _emojiPortal.show();
  }

  Future<void> _toggleGifPicker() async {
    if (_gifPortal.isShowing) {
      _gifPortal.hide();
      return;
    }
    _emojiPortal.hide();
    await _ensurePrefs();
    if (!mounted) return;
    _gifPortal.show();
  }

  // --- Attachments: image upload (Blossom) + P2P file share -----------------

  /// A system line in the bot conversation (the failure/notice surface the
  /// canonical composer's `_onSystemMessage` uses for upload errors).
  void _systemLine(String text) => ref
      .read(appStateProvider.notifier)
      .addSystemMessage(text, storageKey: BotChatController.conversationKey);

  void _cancelUpload() {
    setState(() {
      _uploadCancelled = true;
      _uploadProgress = null;
      _uploadMime = null;
      _uploadIndex = 0;
      _uploadTotal = 0;
    });
  }

  /// Image/Video button (`selectImage` → fileInput `multiple`, accepts image +
  /// video): pick one OR MANY media, upload each to a Blossom server, then
  /// append ALL resulting URLs (space-joined) to the input — the formatter
  /// renders them as media (users.js:971-1028).
  Future<void> _pickAndUploadImage() async {
    List<XFile> picked;
    try {
      picked = await ImagePicker().pickMultipleMedia();
    } catch (_) {
      return; // picker unavailable (tests/desktop)
    }
    if (picked.isEmpty) return;
    const maxUpload = 50 * 1024 * 1024; // 50 MB cap (users.js:977)

    if (!mounted) return;
    setState(() {
      _uploadCancelled = false;
      _uploadTotal = picked.length;
    });

    final controller = ref.read(nostrControllerProvider);
    final urls = <String>[];
    for (var i = 0; i < picked.length; i++) {
      if (!mounted || _uploadCancelled) break;
      final file = picked[i];
      final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (_) {
        continue;
      }
      if (bytes.length > maxUpload) {
        _systemLine('Files must be under 50MB.');
        continue;
      }
      final contentType = file.mimeType ?? _guessMime(file.name);
      if (!mounted) return;
      setState(() {
        _uploadProgress = 0.1;
        _uploadMime = contentType;
        _uploadIndex = i + 1;
      });
      final url = await controller.uploadImage(
        bytes,
        contentType: contentType,
        onProgress: (p) {
          if (mounted && !_uploadCancelled) setState(() => _uploadProgress = p);
        },
      );
      if (!mounted) return;
      if (_uploadCancelled) break;
      if (url == null) {
        _systemLine('Failed to upload media.');
        continue;
      }
      urls.add(url);
    }

    if (!mounted) return;
    final wasCancelled = _uploadCancelled;
    setState(() {
      _uploadProgress = null;
      _uploadMime = null;
      _uploadCancelled = false;
      _uploadIndex = 0;
      _uploadTotal = 0;
    });
    // Drop the results entirely if the user pressed ✕ mid-batch.
    if (wasCancelled || urls.isEmpty) return;
    // Append all URLs space-joined (then a trailing space), like the PWA.
    final existing = _controller.text;
    final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
    _controller.text = '$existing${needsSpace ? ' ' : ''}${urls.join(' ')} ';
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    _focus.requestFocus();
  }

  /// File button (`selectP2PFile` → p2pFileInput): pick any file and offer it
  /// as a P2P transfer (`shareP2PFile`, p2p.js:86).
  Future<void> _pickAndShareFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(withData: true);
    } catch (_) {
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _systemLine('Could not read the selected file.');
      return;
    }
    await ref.read(nostrControllerProvider).shareP2PFile(
          bytes: bytes,
          name: file.name,
          type: _guessMime(file.name),
        );
    if (mounted) _systemLine('File offered for P2P download.');
  }

  static String _guessMime(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }

  /// `.upload-progress` — a panel (12px padding, 8px bottom gap, top corners
  /// radius-sm) floating above the input with a label + cancel ✕ + a thin
  /// primary→secondary gradient bar (users.js:988-1008). Single: "Uploading
  /// image/video..."; multi: "Uploading i of N...".
  Widget _uploadBar(BuildContext context) {
    final c = widget.colors;
    final isVideo = (_uploadMime ?? '').startsWith('video/');
    final kind = isVideo ? 'video' : 'image';
    final label = _uploadTotal > 1
        ? 'Uploading $_uploadIndex of $_uploadTotal...'
        : 'Uploading $kind...';
    final fraction = (_uploadProgress ?? 0.1).clamp(0.0, 1.0);
    final solidUi = ref.watch(settingsProvider.select((s) => s.solidUi));
    return Container(
      // `.upload-progress`: bg rgba(20,20,35,0.9) dark / white@0.92 light
      // (solid-ui repaints with --glass-bg), 1px glass border, radius-sm top
      // corners (styles-components.css:1142-1153).
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: solidUi
            ? c.glassBg
            : (c.isLight
                ? Colors.white.withValues(alpha: 0.92)
                : const Color(0xE6141423)),
        border: Border.all(color: c.glassBorder),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(NymRadius.sm)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(color: c.textDim, fontSize: 12)),
              ),
              // `.upload-progress-close` (22×22 ✕, radius-sm), cancels the
              // in-flight upload.
              Material(
                type: MaterialType.transparency,
                borderRadius: NymRadius.rsm,
                child: InkWell(
                  onTap: _cancelUpload,
                  borderRadius: NymRadius.rsm,
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: Center(
                      child: NymSvgIcon(NymIcons.close,
                          size: 14, color: c.textDim),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // `.progress-bar`: height 6, white@0.05, radius 10; `.progress-fill`
          // linear-gradient(90deg, primary, secondary).
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: 6,
              color: Colors.white.withValues(alpha: 0.05),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: fraction,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      gradient: LinearGradient(
                        colors: [c.primary, c.secondary],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- In-composer translate (`#translateInputBtn` + dropdown) --------------

  /// `#translateInputBtn` (+ its dropdown). Exists only while the field has
  /// text; pulses while translating. Anchors the 230px language dropdown.
  Widget _translateButton(BuildContext context) {
    final hasText = _controller.text.trim().isNotEmpty;
    return CompositedTransformTarget(
      link: _translateAnchor,
      child: OverlayPortal(
        controller: _translatePortal,
        overlayChildBuilder: _translateDropdown,
        child: _BotTranslateButton(
          enabled: hasText && !_translating,
          translating: _translating,
          onTap: _toggleTranslateDropdown,
        ),
      ),
    );
  }

  Future<void> _toggleTranslateDropdown() async {
    if (_translatePortal.isShowing) {
      _translatePortal.hide();
      return;
    }
    if (_controller.text.trim().isEmpty || _translating) return;
    _emojiPortal.hide();
    _gifPortal.hide();
    final prefs = await _ensurePrefs();
    if (!mounted) return;
    setState(() {
      _translateFavorites = _loadTranslateFavorites(prefs);
      _translateQuery = '';
      // Snapshot the favorites-pinned order at open (re-pins only on reopen).
      _translateLangOrder =
          sortedTranslateLanguagesWithFavorites(_translateFavorites);
    });
    _translateSearchController.clear();
    _translatePortal.show();
  }

  /// Read the persisted translate favorites (`nym_translate_favorites`).
  static List<String> _loadTranslateFavorites(SharedPreferences prefs) {
    final raw = prefs.getString(kTranslateFavoritesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return const [];
  }

  /// Toggle [code] in the favorites list and persist (translate.js:102-108):
  /// append when absent, remove when present.
  void _toggleTranslateFavorite(String code) {
    final next = [..._translateFavorites];
    if (!next.remove(code)) next.add(code);
    setState(() => _translateFavorites = next);
    _prefs?.setString(kTranslateFavoritesKey, jsonEncode(next));
  }

  /// `.translate-input-dropdown`: a 230px search + language list anchored
  /// above the translate button. Choosing a language translates the draft in
  /// place (identical chrome to the canonical composer's dropdown).
  Widget _translateDropdown(BuildContext context) {
    final c = widget.colors;
    final q = _translateQuery.trim().toLowerCase();
    // Star FILL reads the live favorites set; row ORDER uses the open-time
    // snapshot so toggling a star doesn't reshuffle mid-open (PWA parity).
    final favSet = _translateFavorites.toSet();
    final order = _translateLangOrder.isEmpty
        ? sortedTranslateLanguagesWithFavorites(_translateFavorites)
        : _translateLangOrder;
    final langs = order
        .where((e) => q.isEmpty || e.value.toLowerCase().contains(q))
        .toList();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _translatePortal.hide,
          ),
        ),
        CompositedTransformFollower(
          link: _translateAnchor,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -4),
          showWhenUnlinked: false,
          child: Align(
            alignment: Alignment.bottomRight,
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                width: 230,
                constraints: const BoxConstraints(maxHeight: 320),
                decoration: BoxDecoration(
                  // `.translate-input-dropdown` bg --bg-secondary / glass
                  // border / shadow black@0.4; light flips to white@0.98 /
                  // black@0.12 (styles-themes-responsive.css:1278-1282).
                  color: c.isLight
                      ? Colors.white.withValues(alpha: 0.98)
                      : c.bgSecondary,
                  border: Border.all(
                      color: c.isLight
                          ? Colors.black.withValues(alpha: 0.12)
                          : c.glassBorder),
                  borderRadius: NymRadius.rmd,
                  boxShadow: [
                    BoxShadow(
                        color: c.isLight
                            ? Colors.black.withValues(alpha: 0.12)
                            : const Color(0x66000000),
                        blurRadius: 24,
                        offset: const Offset(0, 8)),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // `.translate-dropdown-search`: 8px padding + a bottom
                    // hairline under the search region.
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border:
                            Border(bottom: BorderSide(color: c.glassBorder)),
                      ),
                      child: TextField(
                        controller: _translateSearchController,
                        autofocus: true,
                        onChanged: (v) => setState(() => _translateQuery = v),
                        style: TextStyle(color: c.text, fontSize: 13),
                        cursorColor: c.isLight ? Colors.black : Colors.white,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search languages...',
                          hintStyle: TextStyle(color: c.textDim, fontSize: 13),
                          filled: true,
                          fillColor: c.isLight
                              ? Colors.black.withValues(alpha: 0.04)
                              : Colors.white.withValues(alpha: 0.05),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 7),
                          border: OutlineInputBorder(
                            borderRadius: NymRadius.rsm,
                            borderSide: BorderSide(color: c.glassBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: NymRadius.rsm,
                            borderSide: BorderSide(color: c.glassBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: NymRadius.rsm,
                            borderSide: BorderSide(color: c.primary),
                          ),
                        ),
                      ),
                    ),
                    Flexible(
                      // `.translate-dropdown-list`: padding 4px 0.
                      child: langs.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(14),
                              child: Text('No languages found',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: c.textDim, fontSize: 13)),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              itemCount: langs.length,
                              itemBuilder: (_, i) {
                                final e = langs[i];
                                return _BotTranslateLangRow(
                                  name: e.value,
                                  favorited: favSet.contains(e.key),
                                  onTap: () => _translateDraft(e.key),
                                  onToggleFavorite: () =>
                                      _toggleTranslateFavorite(e.key),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Translates the typed draft into [targetLang] and replaces the input text
  /// (the PWA's in-input translate flow). Sentinel emoji expand to their
  /// literal `:code:` before the external round-trip.
  Future<void> _translateDraft(String targetLang) async {
    _translatePortal.hide();
    final text = _controller.expand(_controller.text).trim();
    if (text.isEmpty) return;
    setState(() => _translating = true);
    try {
      final res = await TranslateService().translate(text, targetLang);
      if (!mounted) return;
      final out = res.translatedText.trim();
      if (out.isNotEmpty) {
        _controller.text = out;
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
      }
    } catch (_) {
      if (mounted) _systemLine('Translation failed.');
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    // `#sendBtn` is gated on CONNECTION, not input content (relays.js:1040+);
    // the empty-input guard lives inside `_send`. It is NOT disabled while a
    // reply is pending — the PWA lets you keep sending.
    final sendEnabled = ref.watch(
          appStateProvider.select((s) => s.connectedRelays > 0),
        ) ||
        ref.read(nostrControllerProvider).isLive;

    // Feed the live NIP-30 shortcode→url map into the controller so typed and
    // picked custom emoji render inline while composing (composer parity).
    _controller.codeToUrl = ref.watch(liveCustomEmojiProvider).codeToUrl;

    // Apply mention/quote requests published by the context menu / swipe /
    // double-tap (one-shot mailbox).
    ref.listen(pendingComposerActionProvider, (_, action) {
      if (action == null) return;
      _applyComposerAction(action);
      ref.read(pendingComposerActionProvider.notifier).consume();
    });

    final phone =
        MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint;
    final compact =
        MediaQuery.of(context).size.width <= NymDimens.tabletBreakpoint;

    final input = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // `.quote-preview` chip stacked above the input, sliding in.
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.bottomLeft,
          child: _pendingQuote == null
              ? const SizedBox(height: 0)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _QuotePreviewChip(
                    author: _pendingQuote!.author,
                    text: _quotePreviewText(_pendingQuote!.text),
                    onClose: _clearQuote,
                  ),
                ),
        ),
        Focus(onKeyEvent: _onKey, child: _textField(context, phone)),
      ],
    );

    final toolbar = _toolbar(context, sendEnabled, compact, phone);

    return Container(
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      // `.input-container { padding: 12px 16px }`; phones collapse to 10px.
      padding: phone
          ? const EdgeInsets.all(10)
          : const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // `#uploadProgress` floats above the input while a Blossom upload
            // runs (users.js:988-1008).
            if (_uploadProgress != null) _uploadBar(context),
            // `#commandPalette` for the bot-PM `?` commands, above the input
            // (hidden by Escape until the input changes again).
            if (_suggestions.isNotEmpty && !_suppressPalette) _palette(c),
            compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      input,
                      const SizedBox(height: 10),
                      toolbar,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(child: input),
                      const SizedBox(width: 10),
                      toolbar,
                    ],
                  ),
          ],
        ),
      ),
    );
  }

  /// `.message-input`: white@0.05 fill (black@0.04 light), glass border, ONLY
  /// the bottom corners rounded (radius-md), 10px/16px padding, pure
  /// white/black text at the user size; focus lifts the fill, tints the border
  /// primary@0.3 and paints the 3px primary@0.06 ring (styles-chat.css:1662+).
  Widget _textField(BuildContext context, bool phone) {
    final c = widget.colors;
    final focused = _focus.hasFocus;
    final hasText = _controller.text.trim().isNotEmpty;
    final flatFill = c.isLight
        ? Colors.black.withValues(alpha: focused ? 0.02 : 0.04)
        : Colors.white.withValues(alpha: focused ? 0.07 : 0.05);
    const radius = BorderRadius.vertical(bottom: Radius.circular(NymRadius.md));
    final border = OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: c.glassBorder),
    );
    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      maxLines: 5,
      minLines: 1,
      textInputAction: TextInputAction.newline,
      style: TextStyle(
        color: c.isLight ? Colors.black : Colors.white,
        fontSize: phone ? 16 : 15,
      ),
      cursorColor: c.isLight ? Colors.black : Colors.white,
      decoration: InputDecoration(
        isDense: true,
        // The shared input placeholder (index.html `data-placeholder`).
        hintText: 'Message, / for commands, ? for Nymbot...',
        hintStyle: TextStyle(
            color:
                (c.isLight ? Colors.black : Colors.white).withValues(alpha: 0.4),
            fontSize: phone ? 16 : 15),
        filled: true,
        fillColor: flatFill,
        // The translate button only exists when there's text, so only then
        // does the input reserve right padding for it (`paddingRight 38px`).
        contentPadding: EdgeInsets.fromLTRB(16, 10, hasText ? 38 : 16, 10),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: c.primaryA(0.30)),
        ),
      ),
    );
    final stack = Stack(
      children: [
        field,
        // `#translateInputBtn` starts `.nm-hidden` and `display:flex` ONLY
        // when the field has text (translate.js:588-600).
        if (hasText)
          Positioned(
            right: 8,
            bottom: 10,
            child: _translateButton(context),
          ),
      ],
    );
    // `.message-input:focus`: a 3px primary@0.06 ring (spread, no blur).
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: focused
            ? [
                BoxShadow(
                  color: c.primaryA(0.06),
                  spreadRadius: 3,
                  blurRadius: 0,
                ),
              ]
            : const [],
      ),
      child: stack,
    );
  }

  /// `.input-buttons` (index.html:758-790): EXACTLY five children — Image,
  /// File (P2P), Emoji, GIF and the SEND pill — shared by the bot PM.
  Widget _toolbar(
      BuildContext context, bool sendEnabled, bool compact, bool phone) {
    final buttons = <Widget>[
      _BotIconBtn(
        svg: NymIcons.composerImage,
        tooltip: 'Upload Image/Video',
        expand: compact,
        // Inert until relays connect (same `sendEnabled` as SEND), then the
        // in-upload guard takes over.
        enabled: sendEnabled,
        onTap: _uploadProgress != null ? null : _pickAndUploadImage,
      ),
      _BotIconBtn(
        svg: NymIcons.composerFile,
        tooltip: 'Share File (P2P)',
        expand: compact,
        enabled: sendEnabled,
        onTap: _pickAndShareFile,
      ),
      _emojiButton(context, sendEnabled, compact),
      _gifButton(context, sendEnabled, compact),
      _BotSendButton(
        enabled: sendEnabled,
        onTap: _send,
        expand: compact,
        phone: phone,
      ),
    ];
    if (compact) {
      return Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            Expanded(flex: i == buttons.length - 1 ? 2 : 1, child: buttons[i]),
            if (i != buttons.length - 1) const SizedBox(width: 10),
          ],
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          buttons[i],
          if (i != buttons.length - 1) const SizedBox(width: 5),
        ],
      ],
    );
  }

  Widget _emojiButton(BuildContext context, bool enabled, bool expand) {
    return CompositedTransformTarget(
      link: _emojiAnchor,
      child: OverlayPortal(
        controller: _emojiPortal,
        overlayChildBuilder: (context) => _popover(
          link: _emojiAnchor,
          onDismiss: _emojiPortal.hide,
          child: EmojiPicker(
            recents: _recents,
            onSelect: _onEmojiSelected,
            onClose: _emojiPortal.hide,
          ),
        ),
        child: _BotIconBtn(
          svg: NymIcons.composerEmoji,
          tooltip: 'Emoji',
          expand: expand,
          enabled: enabled,
          onTap: _toggleEmojiPicker,
        ),
      ),
    );
  }

  Widget _gifButton(BuildContext context, bool enabled, bool expand) {
    return CompositedTransformTarget(
      link: _gifAnchor,
      child: OverlayPortal(
        controller: _gifPortal,
        overlayChildBuilder: (context) {
          final prefs = _prefs;
          if (prefs == null) return const SizedBox.shrink();
          return _popover(
            link: _gifAnchor,
            onDismiss: _gifPortal.hide,
            child: GifPicker(
              favoritesStore: FavoriteGifsStore(prefs),
              onSelect: _onGifSelected,
              onClose: _gifPortal.hide,
            ),
          );
        },
        child: _BotIconBtn(
          label: 'GIF',
          tooltip: 'GIF',
          expand: expand,
          enabled: enabled,
          onTap: _toggleGifPicker,
        ),
      ),
    );
  }

  /// Positions a picker above its anchor button (the PWA's `bottom: 100%`
  /// popups) with a barrier to dismiss on tap-out; phones center it above the
  /// input bar instead.
  Widget _popover({
    required LayerLink link,
    required VoidCallback onDismiss,
    required Widget child,
  }) {
    final media = MediaQuery.of(context);
    final isPhone = media.size.width <= NymDimens.mobileBreakpoint;
    final picker = Material(type: MaterialType.transparency, child: child);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        if (isPhone)
          Positioned(
            left: 8,
            right: 8,
            bottom: 60 + media.viewInsets.bottom,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: picker,
              ),
            ),
          )
        else
          CompositedTransformFollower(
            link: link,
            targetAnchor: Alignment.topRight,
            followerAnchor: Alignment.bottomRight,
            offset: const Offset(0, -8),
            showWhenUnlinked: false,
            child: Align(
              alignment: Alignment.bottomRight,
              child: picker,
            ),
          ),
      ],
    );
  }

  /// The `#commandPalette` dropdown: `.command-item` rows (name w600 + desc);
  /// `.command-item.selected` highlights [_paletteIndex] (first row on open,
  /// then ↑/↓-navigable), bgTertiary surface.
  Widget _palette(NymColors c) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      // `.command-palette`: bg rgba(20,20,35,0.9), radius 16/16/0/0, padding 6,
      // max-height 200, shadow-lg.
      constraints: const BoxConstraints(maxHeight: 200),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        // `body.light-mode .command-palette { background: rgba(255,255,255,0.92);
        // box-shadow: 0 8px 32px rgba(0,0,0,0.12); border-color: rgba(0,0,0,0.08) }`
        // (styles-themes-responsive.css:1155-1158) vs dark rgba(20,20,35,0.9).
        color: c.isLight ? const Color(0xEBFFFFFF) : const Color(0xE6141423),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        border: Border.all(
            color: c.isLight ? const Color(0x14000000) : c.glassBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: c.isLight ? 0.12 : 0.5),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _suggestions.length,
        itemBuilder: (_, i) {
          final cmd = _suggestions[i];
          final selected = i == _paletteIndex;
          return InkWell(
            onTap: () => _pick(cmd),
            child: Container(
              decoration: BoxDecoration(
                // `.command-item.selected`: background white@0.08 dark, flipped to
                // black@0.06 in light mode — `hoverOverlay` is mode-aware. Radius
                // xs (8).
                color: selected ? c.hoverOverlay : null,
                borderRadius: BorderRadius.circular(8),
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // `.command-name`: --primary, bold (not monospace).
                  Flexible(
                    child: Text(cmd.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: c.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 10),
                  // `.command-desc`: 12px; brightens to --text when selected.
                  Flexible(
                    child: Text(
                      cmd.desc,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          color: selected ? c.text : c.textDim, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// `.quote-preview`: bgTertiary panel with a 3px primary bar, the author
/// (primary 12/w600 with a muted `#suffix`) over the truncated quoted text
/// (dim 12, ellipsis) and a close ✕.
class _QuotePreviewChip extends StatelessWidget {
  const _QuotePreviewChip({
    required this.author,
    required this.text,
    required this.onClose,
  });

  final String author;
  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hashIdx = author.indexOf('#');
    final base = hashIdx >= 0 ? author.substring(0, hashIdx) : author;
    final suffix = hashIdx >= 0 ? author.substring(hashIdx) : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        border: Border.all(color: c.glassBorder),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(NymRadius.md)),
        // `--shadow-lg`: 0 8px 32px rgba(0,0,0,0.5).
        boxShadow: const [
          BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // `.quote-preview-bar`: 3px wide, ≥28 tall, radius 2.
          Container(
            width: 3,
            constraints: const BoxConstraints(minHeight: 28),
            decoration: BoxDecoration(
              color: c.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: TextStyle(
                        color: c.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                    children: [
                      TextSpan(text: base),
                      if (suffix.isNotEmpty)
                        TextSpan(
                          text: suffix,
                          // `.nym-suffix`: opacity 0.7, 0.9em, weight 100.
                          style: TextStyle(
                            color: c.primary.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w100,
                            fontSize: 12 * 0.9,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textDim, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // `.quote-preview-close`: 16×16 ✕.
          InkWell(
            onTap: onClose,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: NymSvgIcon(NymIcons.close, size: 14, color: c.textDim),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.icon-btn.input-btn` (styles-chat.css:1946-1965): 42px tall, 0 12px
/// padding, radius-sm, 18×18 glyph stroked text → primary on hover; disabled
/// dims to 0.35.
class _BotIconBtn extends StatefulWidget {
  const _BotIconBtn({
    this.svg,
    this.label,
    required this.tooltip,
    this.expand = false,
    this.enabled = true,
    this.onTap,
  }) : assert(svg != null || label != null, 'provide an svg or a label');

  final String? svg;
  final String? label;
  final String tooltip;
  final bool expand;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  State<_BotIconBtn> createState() => _BotIconBtnState();
}

class _BotIconBtnState extends State<_BotIconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final enabled = widget.enabled;
    final hovered = enabled && _hover;
    final glyphColor = hovered ? c.primary : c.text;
    final child = widget.svg != null
        ? NymSvgIcon(widget.svg!, size: 18, color: glyphColor)
        : Text(
            widget.label!,
            style: TextStyle(
              color: glyphColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          );
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: enabled ? widget.onTap : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.35,
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hovered ? c.hoverOverlay : c.glassBg,
                border: Border.all(color: c.glassBorder),
                borderRadius: NymRadius.rsm,
              ),
              child: widget.expand
                  ? Center(child: child)
                  : child,
            ),
          ),
        ),
      ),
    );
  }
}

/// `.send-btn` (styles-chat.css:1920-1944): primary@0.1 fill, primary@0.3 1px
/// border, radius-sm, 10px/22px padding at 42px height, 'SEND' 12px/600 with
/// 1.5px letter-spacing, uppercase; hover deepens the fill (0.18) + glow;
/// disabled dims to 0.35. Phones shrink to `padding:10px; font-size:11px`.
class _BotSendButton extends StatefulWidget {
  const _BotSendButton({
    required this.enabled,
    required this.onTap,
    this.expand = false,
    this.phone = false,
  });

  final bool enabled;
  final VoidCallback onTap;
  final bool expand;
  final bool phone;

  @override
  State<_BotSendButton> createState() => _BotSendButtonState();
}

class _BotSendButtonState extends State<_BotSendButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final enabled = widget.enabled;
    final hovered = enabled && _hover;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.35,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 42,
            padding: widget.phone
                ? const EdgeInsets.all(10)
                : const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.primaryA(hovered ? 0.18 : 0.10),
              border: Border.all(color: c.primaryA(0.30)),
              borderRadius: NymRadius.rsm,
              boxShadow: hovered
                  ? [BoxShadow(color: c.primaryA(0.10), blurRadius: 15)]
                  : null,
            ),
            child: Text(
              'SEND',
              style: TextStyle(
                color: c.primary,
                fontSize: widget.phone ? 11 : 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `#translateInputBtn`: the 26×26 translate glyph overlaid bottom-right of
/// the input (styles-chat.css `.translate-input-btn`); pulses (opacity
/// 0.4↔0.8) while a translation runs. Identical to the canonical composer's
/// button — the PWA bot PM shares the same `.message-input-row`.
class _BotTranslateButton extends StatefulWidget {
  const _BotTranslateButton({
    required this.enabled,
    required this.translating,
    required this.onTap,
  });

  final bool enabled;
  final bool translating;
  final VoidCallback onTap;

  @override
  State<_BotTranslateButton> createState() => _BotTranslateButtonState();
}

class _BotTranslateButtonState extends State<_BotTranslateButton>
    with SingleTickerProviderStateMixin {
  bool _hover = false;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
  }

  @override
  void didUpdateWidget(covariant _BotTranslateButton old) {
    super.didUpdateWidget(old);
    if (widget.translating && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.translating && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final color = _hover && widget.enabled ? c.primary : c.textDim;
    Widget glyph = NymSvgIcon(NymIcons.translate, size: 16, color: color);
    if (widget.translating) {
      // `.translating` pulse: opacity 0.4 ↔ 0.8.
      glyph = FadeTransition(
        opacity: Tween(begin: 0.4, end: 0.8).animate(_pulse),
        child: glyph,
      );
    }
    return Opacity(
      opacity: widget.enabled ? (_hover ? 1.0 : 0.6) : 0.4,
      child: Tooltip(
        message: 'Translate text',
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.enabled ? widget.onTap : null,
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // `.translate-input-btn:hover` white@0.08 dark / black@0.06
                // light (styles-themes-responsive.css:1274).
                color: _hover && widget.enabled
                    ? (c.isLight
                        ? Colors.black.withValues(alpha: 0.06)
                        : Colors.white.withValues(alpha: 0.08))
                    : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: glyph,
            ),
          ),
        ),
      ),
    );
  }
}

/// One `.translate-dropdown-item` row: the language name + a trailing favorite
/// star (`#f5c518` when favorited) — styles-chat.css:1850-1897.
class _BotTranslateLangRow extends StatefulWidget {
  const _BotTranslateLangRow({
    required this.name,
    required this.favorited,
    required this.onTap,
    required this.onToggleFavorite,
  });

  final String name;
  final bool favorited;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  @override
  State<_BotTranslateLangRow> createState() => _BotTranslateLangRowState();
}

class _BotTranslateLangRowState extends State<_BotTranslateLangRow> {
  bool _hover = false;
  bool _starHover = false;

  static const Color _favColor = Color(0xFFF5C518);

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          // `.translate-dropdown-item:hover` white@0.08 dark / black@0.05
          // light (styles-themes-responsive.css:1284).
          color: _hover
              ? (c.isLight
                  ? Colors.black.withValues(alpha: 0.05)
                  : Colors.white.withValues(alpha: 0.08))
              : null,
          // `.translate-dropdown-item`: padding 7px 8px 7px 14px; gap 8.
          padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _hover ? c.textBright : c.text,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // `.translate-dropdown-star`: 24×24, radius-sm.
              MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _starHover = true),
                onExit: (_) => setState(() => _starHover = false),
                child: GestureDetector(
                  onTap: widget.onToggleFavorite,
                  child: Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _starHover
                          ? (c.isLight
                              ? Colors.black.withValues(alpha: 0.06)
                              : Colors.white.withValues(alpha: 0.1))
                          : null,
                      borderRadius: NymRadius.rsm,
                    ),
                    child: NymSvgIcon(
                      widget.favorited
                          ? NymIcons.starFilled
                          : NymIcons.starOutline,
                      size: 14,
                      color: widget.favorited
                          ? _favColor
                          : (_starHover ? c.textBright : c.textDim),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Git connect modal (provider + PAT + repo/branch) — premium surface
// =============================================================================

class _GitConnectModal extends StatefulWidget {
  const _GitConnectModal({
    required this.colors,
    required this.existing,
    required this.onConnect,
    required this.onDisconnect,
  });

  final NymColors colors;
  final GitConfig? existing;
  final ValueChanged<GitConfig> onConnect;
  final VoidCallback onDisconnect;

  @override
  State<_GitConnectModal> createState() => _GitConnectModalState();
}

class _GitConnectModalState extends State<_GitConnectModal> {
  late GitProvider _provider;
  late final TextEditingController _host;
  late final TextEditingController _token;
  late final TextEditingController _repo;
  late final TextEditingController _branch;
  late bool _allowWrites;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _provider = e?.provider ?? GitProvider.github;
    _host = TextEditingController(text: e?.host ?? _provider.defaultHost);
    _token = TextEditingController(text: e?.token ?? '');
    _repo = TextEditingController(text: e?.repo ?? '');
    _branch = TextEditingController(text: e?.branch ?? '');
    _allowWrites = e?.allowWrites ?? false;
  }

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    _repo.dispose();
    _branch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connect a git repo',
                style: TextStyle(
                    color: c.textBright,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              'Pro replies can read your code and, with writes on, commit, '
              'branch, and open PRs. Your access token is stored only on this '
              'device (Panic Mode wipes it) and sent per request — never stored '
              'server-side.',
              style: TextStyle(color: c.textDim, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            // Provider selector.
            Wrap(
              spacing: 8,
              children: [
                for (final p in GitProvider.values)
                  ChoiceChip(
                    label: Text(p.label),
                    selected: _provider == p,
                    onSelected: (_) => setState(() {
                      _provider = p;
                      _host.text = p.defaultHost;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _field(_host, 'Host', 'github.com', c),
            const SizedBox(height: 10),
            _field(_token, 'Personal access token (PAT)', 'ghp_… / glpat-… ',
                c, obscure: true),
            const SizedBox(height: 10),
            _field(_repo, 'Repository', 'owner/repo', c),
            const SizedBox(height: 10),
            _field(_branch, 'Branch (optional)', 'main', c),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _allowWrites,
              thumbColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) return c.primary;
                return null;
              }),
              title: Text('Allow writes',
                  style: TextStyle(color: c.text, fontSize: 14)),
              subtitle: Text('commit, create branches, open pull/merge requests',
                  style: TextStyle(color: c.textDim, fontSize: 11)),
              onChanged: (v) => setState(() => _allowWrites = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (widget.existing != null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        widget.onDisconnect();
                        Navigator.pop(context);
                      },
                      child: const Text('Disconnect'),
                    ),
                  ),
                if (widget.existing != null) const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: _canConnect ? _connect : null,
                    child: const Text('Connect'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool get _canConnect =>
      _token.text.trim().isNotEmpty && _repo.text.trim().isNotEmpty;

  void _connect() {
    widget.onConnect(GitConfig(
      provider: _provider,
      host: _host.text.trim().isEmpty ? _provider.defaultHost : _host.text.trim(),
      token: _token.text.trim(),
      repo: _repo.text.trim(),
      branch: _branch.text.trim().isEmpty ? null : _branch.text.trim(),
      allowWrites: _allowWrites,
    ));
    Navigator.pop(context);
  }

  Widget _field(TextEditingController ctrl, String label, String hint,
      NymColors c,
      {bool obscure = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: c.textDim, fontSize: 12)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          style: TextStyle(color: c.text, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: c.textDim),
            isDense: true,
            filled: true,
            fillColor: c.bgTertiary,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: c.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: c.border),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Fallback theme colours (used only when NymColors isn't registered, e.g. in a
// bare widget test). The real app supplies NymColors via the theme extension.
// =============================================================================

const NymColors _fallbackColors = NymColors(
  primary: Color(0xFF7C5CFF),
  secondary: Color(0xFF4DA3FF),
  warning: Color(0xFFE0A800),
  danger: Color(0xFFE5484D),
  purple: Color(0xFF7C5CFF),
  blue: Color(0xFF4DA3FF),
  lightning: Color(0xFFF7931A),
  bg: Color(0xFF0E0E12),
  bgSecondary: Color(0xFF16161C),
  bgTertiary: Color(0xFF1E1E26),
  text: Color(0xFFE6E6EA),
  textDim: Color(0xFF9A9AA6),
  textBright: Color(0xFFFFFFFF),
  border: Color(0xFF2A2A33),
  glassBg: Color(0x22FFFFFF),
  glassBorder: Color(0x33FFFFFF),
  brightness: Brightness.dark,
);

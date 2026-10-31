import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../day_separators/day_separator.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/message_row.dart'
    show MessageGroup, MessageGroupEntry, hoverBarLitFill;
import '../../widgets/chat/message_selection.dart';
import '../../widgets/chat/typing_indicator.dart';
import '../../widgets/context_menu/interaction_hooks.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import '../reactions/reaction_picker.dart';
import '../settings/settings_widgets.dart' show SettingsToggleRow;
import '../threads/thread_view.dart' show ThreadView;
import 'bot_credits_modal.dart';
import 'bot_runs.dart' show kBotRunPollEvery;
import 'bot_runs_view.dart';
import '../shop/shop_purchase_policy.dart';
import 'bot_chip.dart';
import 'nymbot_models.dart';
import 'brand_tile.dart';
import 'nymbot_providers.dart';
import '../../widgets/chat/list_anchor.dart';
import '../../widgets/common/nym_field.dart';
import '../../widgets/common/nym_tooltip.dart';
import '../duo/duo_rail.dart';

/// Private Nymbot chat over the canonical bot PM thread, with tier/model switching and credit buying.
class BotChatScreen extends ConsumerStatefulWidget {
  const BotChatScreen({super.key, this.onOpenSidebar});

  /// Opens the drawer on compact layouts; null on wide ones.
  final VoidCallback? onOpenSidebar;

  @override
  ConsumerState<BotChatScreen> createState() => _BotChatScreenState();
}

class _BotChatScreenState extends ConsumerState<BotChatScreen> {
  final _scroll = ScrollController();

  /// Whether the scroll-to-bottom button shows (>150px up); in the reversed list `offset` is that distance.
  bool _showScrollButton = false;

  Timer? _runsTimer;
  final Map<String, GlobalKey> _runKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Bind the paid surface to the identity, make the bot PM the active view, then show the intro and refresh credits.
      final nostr = ref.read(nostrControllerProvider);
      nostr.bindBotChat();
      ref
          .read(appStateProvider.notifier)
          .switchView(const ChatView.pm(kNymbotPubkey));
      final engine = ref.read(botChatControllerProvider.notifier);
      // Sign paid actions through the active signer (local or NIP-46).
      engine.attachSigner(nostr.signer);
      engine.ensureIntro();
      engine.refreshBalance();
      engine.onChatOpen();
    });
    _runsTimer = Timer.periodic(kBotRunPollEvery, (_) {
      if (!mounted) return;
      final ctl = ref.read(botChatControllerProvider.notifier);
      if (ctl.runsPollWanted) ctl.pollRuns();
    });
  }

  @override
  void dispose() {
    _runsTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _openRun(String id) {
    final ctx = _runKeys[id.toLowerCase()]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: NymMotion.transition, alignment: 0.5);
    }
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

  /// The open thread when it belongs to this bot conversation, swapped in here since ChatPane renders this screen.
  ActiveThread? get _openThread {
    if (!appThreadsEnabled) return null;
    final at = ref.watch(activeThreadProvider);
    if (at == null || at.view != const ChatView.pm(kNymbotPubkey)) return null;
    return at;
  }

  @override
  Widget build(BuildContext context) {
    final c = _colors(context);
    final state = ref.watch(botChatControllerProvider);

    ref.listen<bool>(botAnonRequestProvider, (_, requested) {
      if (!requested) return;
      ref.read(botAnonRequestProvider.notifier).consume();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAnon(context);
      });
    });

    ref.listen<Message?>(
        appStateProvider.select((s) =>
            s.messages[BotChatController.conversationKey]?.lastOrNull),
        (prev, next) {
      if (next == null || !next.isOwn || next.id == prev?.id) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToBottom();
      });
    });

    // Buy and gift requests are handled by home_shell's listeners; a second one here would open the modal twice.

    // Below the shared chat header: control bar, thread, typing strip and composer; transparent so the wallpaper shows.
    return Column(
      children: [
        _BotControlBar(
          isPro: state.isPro,
          // Pinned Pro model label, else "Auto-routed".
          modelLabel: state.proModel?.label ?? tr('Auto-routed'),
          colors: c,
          onTapStandard: () =>
              ref.read(botChatControllerProvider.notifier).setModelDirect(null),
          // Both the Pro pill and the model chip open the picker.
          onTapModel: () => _showModelPicker(context),
          onTapBuy: () => _showBuy(context),
          balance: state.balanceKnown
              ? (state.isPro ? state.balance.proBalance : state.balance.balance)
              : null,
          free: ref.read(botChatControllerProvider.notifier).chipFree,
          anonOn: state.anonEnabled,
          onTapAnon: () => _showAnon(context),
          runsCount: ref
              .read(botChatControllerProvider.notifier)
              .runsEngine
              .rows()
              .length,
          onTapRuns: () =>
              showBotRunsSheet(context, ref, c, onOpen: _openRun),
          onStopAll: () {
            final runs = ref.read(botChatControllerProvider.notifier);
            runs.runsEngine.stopAll();
          },
        ),
        Expanded(
          // Tapping the messages region drops focus when nothing else consumes the tap.
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusScope.of(context).unfocus(),
            // An open thread replaces the message list; control bar and composer stay, and sends reply into it.
            child: _openThread != null
                ? ThreadView(key: ValueKey(_openThread), thread: _openThread!)
                : _buildMessagesArea(c),
          ),
        ),
        // "Nymbot is thinking" strip above the composer; the thread view renders its own.
        if (_openThread == null)
          const TypingIndicatorRow(storageKey: 'pm-$kNymbotPubkey'),
        if (state.priceRetry != null)
          BotPriceRetryBar(
            colors: c,
            busy: state.sending,
            onRetry: () => ref
                .read(botChatControllerProvider.notifier)
                .retryPriceUnavailable(),
            onDismiss: () => ref
                .read(botChatControllerProvider.notifier)
                .dismissPriceRetry(),
          ),
      ],
    );
  }

  static const int _groupWindowSec = 300; // 5 min (messages.js:1557)

  Widget _buildMessagesArea(NymColors c) {
    final app = ref.watch(appStateProvider);
    final settings = ref.watch(settingsProvider);
    final reactions = ref.watch(reactionsProvider);
    // The canonical thread merged with local-only, never-persisted info bubbles.
    var msgs = mergeBotThreadWithInfo(
      app.messages[BotChatController.conversationKey] ?? const <Message>[],
      ref.watch(botChatControllerProvider).infoMessages,
    );
    // Thread replies hide from the flat view when their root is present, like canonical conversations.
    if (appThreadsEnabled && msgs.any((m) => m.threadRoot != null)) {
      final rootIds = <String>{
        for (final m in msgs)
          if (m.threadRoot == null) threadKeyForMessage(m),
      }..remove('');
      msgs = [
        for (final m in msgs)
          if (m.threadRoot == null || !rootIds.contains(m.threadRoot)) m,
      ];
    }
    if (msgs.any((m) => m.threadRoot != null)) {
      final all = msgs;
      msgs = [
        for (final m in all)
          if (!botThreadForeign(m, all)) m,
      ];
    }

    final containerColor = c.isLight
        ? const Color(0x4DFFFFFF)
        : const Color(0x26000000);

    final mentionToken = '@${stripPubkeySuffix(app.selfNym)}';
    ref.watch(botChatControllerProvider.select((s) => s.runsVersion));
    final runs = ref.read(botChatControllerProvider.notifier).runsEngine;
    bool hasStatus(Message m) => m.isOwn
        ? botRunHasStatus(runs, m.nymMessageId)
        : botRunHasOffer(runs, m.replyTo);

    // Fold consecutive same-author messages into 5-minute groups, as messages_list.dart does.
    final units = <List<MessageGroupEntry>>[];
    for (final m in msgs) {
      final entry = MessageGroupEntry(
        message: m,
        reactions: reactions[m.id] ?? const [],
        // Mentions never apply to self or PM rows, and need a known self nym.
        mentioned: mentionToken.length > 1 &&
            !m.isOwn &&
            !m.isPM &&
            m.content.contains(mentionToken),
      );
      if (settings.useBubbles &&
          units.isNotEmpty &&
          !hasStatus(units.last.last.message) &&
          _groupsWith(units.last.last.message, m)) {
        units.last.add(entry);
      } else {
        units.add([entry]);
      }
    }

    final dayStarts = dayStartIndexes(
        units, (MessageGroupEntry e) => e.message.createdAt);

    return ColoredBox(
      color: containerColor,
      child: Stack(
        children: [
          Positioned.fill(
            child: MessageSelection(
            builder: (keepAlives) => ListView.builder(
              addAutomaticKeepAlives: keepAlives,
              controller: _scroll,
              reverse: true,
              physics: const KeepReadingPhysics(),
              // Dragging the list dismisses the keyboard.
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              itemCount: units.length,
              itemBuilder: (context, revIndex) {
                Widget unitAt() {
                final forward = units.length - 1 - revIndex;
                final unit = units[forward];
                final separator = dayStarts.contains(forward)
                    ? DaySeparator(
                        createdAt: unit.first.message.createdAt,
                        useBubbles: settings.useBubbles,
                      )
                    : null;
                // Keyed by the group's lead id so appended replies don't re-create visible rows and restart their snap-in.
                final group = MessageGroup(
                  key: ValueKey('botgroup_${unit.first.message.id}'),
                  entries: unit,
                  settings: settings,
                  onReactionPicker: (msg) =>
                      showReactionPicker(context, ref, msg),
                );
                final last = unit.last.message;
                if (!hasStatus(last)) {
                  if (separator == null) return group;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [separator, group],
                  );
                }
                if (!last.isOwn) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ?separator,
                      group,
                      BotRunOfferView(id: last.replyTo!.toLowerCase(), colors: c),
                    ],
                  );
                }
                final runId = last.nymMessageId!.toLowerCase();
                return Column(
                  key: _runKeys.putIfAbsent(runId, GlobalKey.new),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ?separator,
                    group,
                    BotRunStatusView(id: runId, colors: c),
                  ],
                );
              }

                final item = unitAt();
                final key = item.key;
                return MessageSelection.item(context, item,
                    key: key == null ? null : ValueKey<Key>(key));
              },
            )),
          ),
          // Shown >150px from the bottom.
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

  /// Groups onto [prev] for the same author within 5 minutes, excluding system pills and `/me`; thinking replies group normally.
  bool _groupsWith(Message prev, Message cur) =>
      !prev.isSystemRow &&
      !cur.isSystemRow &&
      !prev.isMeAction &&
      !cur.isMeAction &&
      prev.pubkey == cur.pubkey &&
      (cur.createdAt - prev.createdAt).abs() <= _groupWindowSec &&
      DayClock.instance.sameDay(prev.createdAt, cur.createdAt);

  void _showBuy(BuildContext context) {
    // Buy mode of the shared credits modal; Pro preselected when a Pro model is pinned.
    final state = ref.read(botChatControllerProvider);
    BotCreditsModal.show(
      context,
      colors: _colors(context),
      initialTier: state.isPro ? CreditTier.pro : CreditTier.standard,
    );
  }

  void _showAnon(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _colors(context).bgSecondary,
      builder: (_) => _AnonModal(colors: _colors(context)),
    );
  }

  void _showModelPicker(BuildContext context) {
    final c = _colors(context);
    final current = ref.read(botChatControllerProvider).proModel;
    // Refresh in the background; the sheet opens on the cached list.
    ref.read(proModelCatalogProvider.notifier).refresh();
    showProModelPicker(
      context,
      c,
      (_) => Consumer(
        builder: (_, sheetRef, _) => ProModelPickerSheet(
          colors: c,
          catalog: sheetRef.watch(proModelCatalogProvider),
          current: current,
          onSelected: (m) {
            ref.read(botChatControllerProvider.notifier).setModelDirect(m);
            Navigator.pop(context);
          },
          onGenerator: (text) {
            Navigator.pop(context);
            ref
                .read(pendingComposerActionProvider.notifier)
                .requestReplaceText(text);
          },
        ),
      ),
    );
  }
}

// 40x40 round glass scroll-to-bottom button with a primary chevron.

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
        ? hoverBarLitFill(c)
        : (light ? const Color(0xD9FFFFFF) : c.glassBg);
    final border =
        _hover ? c.primaryA(0.30) : (light ? c.primaryA(0.20) : c.glassBorder);
    final shadow = light
        ? const BoxShadow(
            color: Color(0x26000000),
            offset: Offset(0, 2),
            blurRadius: 12,
          )
        : const BoxShadow(
            color: Color(0x66000000),
            offset: Offset(0, 4),
            blurRadius: 16,
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover && !MediaQuery.disableAnimationsOf(context) ? 1.1 : 1.0,
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

// Glass control bar with the tier switch, model chip and buy chip.

/// Feather sparkle glyph for the model chip.
const String _kSvgSparkle =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
    'stroke-linecap="round" stroke-linejoin="round">'
    '<path d="m12 3-1.9 5.8a2 2 0 0 1-1.3 1.3L3 12l5.8 1.9a2 2 0 0 1 1.3 1.3L12 21'
    'l1.9-5.8a2 2 0 0 1 1.3-1.3L21 12l-5.8-1.9a2 2 0 0 1-1.3-1.3Z"/></svg>';

/// Feather lightning bolt for the buy chip.
const String _kSvgAnon =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
    'stroke-linecap="round" stroke-linejoin="round">'
    '<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/>'
    '<line x1="3" y1="21" x2="21" y2="3"/></svg>';

const String _kSvgStop =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
    'stroke-linecap="round" stroke-linejoin="round">'
    '<rect x="6" y="6" width="12" height="12" rx="2"/></svg>';

const String _kSvgBolt =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
    'stroke-linecap="round" stroke-linejoin="round">'
    '<polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>';

class _BotControlBar extends StatelessWidget {
  const _BotControlBar({
    required this.isPro,
    required this.modelLabel,
    required this.colors,
    required this.onTapStandard,
    required this.onTapModel,
    required this.onTapBuy,
    required this.anonOn,
    required this.onTapAnon,
    this.balance,
    this.free,
    this.runsCount = 0,
    this.onTapRuns,
    this.onStopAll,
  });

  final VoidCallback? onStopAll;
  final int runsCount;
  final VoidCallback? onTapRuns;
  final bool isPro;
  final String modelLabel;
  final NymColors colors;
  final VoidCallback onTapStandard;
  final VoidCallback onTapModel;
  final VoidCallback onTapBuy;
  final bool anonOn;
  final VoidCallback onTapAnon;
  final double? balance;
  final BotFreeAllowance? free;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    // ≤600px: tighter spacing and a shorter label clamp.
    final compact = MediaQuery.sizeOf(context).width <= 600;
    final gap = compact ? 6.0 : 8.0;
    final labelMax = compact ? 96.0 : 150.0;

    // The left cluster scrolls horizontally while Buy stays pinned at the trailing edge.
    final left = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _tierSwitch(c),
          SizedBox(width: gap),
          _CtrlButton(
            svg: _kSvgSparkle,
            label: modelLabel,
            tooltip: tr('Choose Pro model'),
            active: isPro,
            labelMaxWidth: labelMax,
            colors: c,
            compact: compact,
            onTap: onTapModel,
          ),
          SizedBox(width: gap),
          _CtrlButton(
            svg: _kSvgAnon,
            label: tr('Anon'),
            tooltip: anonOn
                ? tr('Anonymous: Nymbot sees a throwaway key, not your nym')
                : tr('Chat from a throwaway key Nymbot cannot link to your nym'),
            active: anonOn,
            labelMaxWidth: labelMax,
            colors: c,
            compact: compact,
            onTap: onTapAnon,
          ),
          if (runsCount > 0 && onStopAll != null) ...[
            SizedBox(width: gap),
            NymTooltip(
              message: tr('Stop every reply in this chat'),
              child: Semantics(
                button: true,
                label: tr('Stop every reply in this chat'),
                excludeSemantics: true,
                child: _CtrlButton(
                  svg: _kSvgStop,
                  label: tr('Stop'),
                  active: false,
                  labelMaxWidth: labelMax,
                  colors: c,
                  compact: compact,
                  onTap: onStopAll!,
                ),
              ),
            ),
          ],
          if (onTapRuns != null) ...[
            SizedBox(width: gap),
            _CtrlButton(
              svg: kSvgBotRuns,
              label: tr('Running now'),
              active: false,
              badge: runsCount > 0 ? runsCount : null,
              labelMaxWidth: labelMax,
              colors: c,
              compact: compact,
              onTap: onTapRuns!,
            ),
          ],
        ],
      ),
    );

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 16, vertical: compact ? 7 : 8),
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(child: left),
          SizedBox(width: gap),
          _BotChip(
            pro: isPro,
            balance: balance,
            free: free,
            labelMaxWidth: labelMax,
            colors: c,
            compact: compact,
            onTap: onTapBuy,
          ),
        ],
      ),
    );
  }

  /// Two-segment tier switch; Standard returns to auto-routing, Pro opens the model picker.
  Widget _tierSwitch(NymColors c) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _tierBtn(tr('Standard'), !isPro, onTapStandard, c),
          const SizedBox(width: 3),
          _tierBtn(tr('Pro'), isPro, onTapModel, c),
        ],
      ),
    );
  }

  Widget _tierBtn(String label, bool active, VoidCallback onTap, NymColors c) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color:
              active ? c.lightning.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active
                ? c.lightning.withValues(alpha: 0.4)
                : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? c.lightning : c.textDim,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _BotChip extends StatefulWidget {
  const _BotChip({
    required this.pro,
    required this.balance,
    required this.free,
    required this.labelMaxWidth,
    required this.colors,
    required this.compact,
    required this.onTap,
  });

  final bool pro;
  final double? balance;
  final BotFreeAllowance? free;
  final double labelMaxWidth;
  final NymColors colors;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_BotChip> createState() => _BotChipState();
}

class _BotChipState extends State<_BotChip> {
  Timer? _wake;

  @override
  void dispose() {
    _wake?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final free = widget.free;
    final view = botChipView(
      pro: widget.pro,
      balance: widget.balance,
      free: free,
      now: now,
      purchasesDisabled: botCreditPurchasesDisabled,
    );
    final text = botChipText(view, (at) => botResetTime(context, at));
    _wake?.cancel();
    _wake = null;
    final next = free?.limit == null ? null : free!.at(now).resetsAt;
    if (next != null) {
      _wake = Timer(Duration(milliseconds: next - now + 50), () {
        if (mounted) setState(() {});
      });
    }
    return _CtrlButton(
      svg: _kSvgBolt,
      label: text.label,
      tooltip: text.tip,
      active: false,
      buy: true,
      labelMaxWidth: widget.labelMaxWidth,
      colors: widget.colors,
      compact: widget.compact,
      onTap: widget.onTap,
    );
  }
}

/// Icon and label chip with a hover-lit border and a primary active state.
class _CtrlButton extends StatefulWidget {
  const _CtrlButton({
    required this.svg,
    required this.label,
    required this.active,
    required this.labelMaxWidth,
    required this.colors,
    required this.compact,
    required this.onTap,
    this.buy = false,
    this.badge,
    this.tooltip,
  });

  final String? tooltip;
  final int? badge;
  final String svg;
  final String label;
  final bool active;
  final bool buy;
  final double labelMaxWidth;
  final NymColors colors;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_CtrlButton> createState() => _CtrlButtonState();
}

class _CtrlButtonState extends State<_CtrlButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    // Buy chip (lightning), then active (primary), then the neutral chip.
    final Color fill;
    final Color border;
    final Color fg;
    if (widget.buy) {
      fill = c.lightning.withValues(alpha: _hover ? 0.16 : 0.1);
      border = c.lightning.withValues(alpha: _hover ? 0.6 : 0.4);
      fg = c.lightning;
    } else if (widget.active) {
      fill = c.primary.withValues(alpha: 0.1);
      border = c.primary.withValues(alpha: 0.5);
      fg = c.primary;
    } else {
      fill = c.insetFill;
      border = _hover ? c.primary.withValues(alpha: 0.4) : c.glassBorder;
      fg = _hover ? c.text : c.textDim;
    }

    final tip = widget.tooltip;
    final body = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 10 : 12, vertical: 6),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              NymSvgIcon(widget.svg, size: 15, color: fg),
              const SizedBox(width: 6),
              // Clamp with ellipsis so a long model name can't blow out the bar.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.labelMaxWidth),
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (widget.badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: c.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${widget.badge}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.bg,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (tip == null || tip.isEmpty) return body;
    return NymTooltip(message: tip, child: body);
  }
}

class BotPriceRetryBar extends StatelessWidget {
  const BotPriceRetryBar({
    super.key,
    required this.colors,
    required this.onRetry,
    required this.onDismiss,
    this.busy = false,
  });

  final NymColors colors;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: c.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.currency_bitcoin, size: 16, color: c.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                tr('Bitcoin price unavailable. Your message was not charged.'),
                style: TextStyle(color: c.text, fontSize: 12)),
          ),
          TextButton(
            onPressed: busy ? null : onRetry,
            style: TextButton.styleFrom(
              foregroundColor: c.primary,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(tr('Retry')),
          ),
          IconButton(
            tooltip: tr('Close'),
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            color: c.textDim,
            onPressed: onDismiss,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// Key for the scrolling model list, so tests target it rather than the search field's Scrollable.
const Key proModelListKey = ValueKey('proModelList');

const Key proPriceUnavailableKey = ValueKey('proPriceUnavailable');

Key generatorResKey(String generatorKey, String res) =>
    ValueKey('generatorRes:$generatorKey:$res');

Future<void> showProModelPicker(
    BuildContext context, NymColors c, WidgetBuilder builder) {
  return showNymSheet<void>(
    context,
    (ctx) => nymSheetOr(
      ctx,
      builder(ctx),
      (body) => Dialog(
        key: const ValueKey('proModelPickerDialog'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: c.bgSecondary,
              border: Border.all(color: c.glassBorder),
              borderRadius: NymRadius.rxl,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 32,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(color: c.primaryA(0.1), blurRadius: 20),
              ],
            ),
            child: Material(type: MaterialType.transparency, child: body),
          ),
        ),
      ),
    ),
  );
}

class ProModelPickerSheet extends StatefulWidget {
  const ProModelPickerSheet({
    super.key,
    required this.colors,
    required this.current,
    required this.onSelected,
    this.catalog,
    this.onGenerator,
  });

  final NymColors colors;

  final ValueChanged<String>? onGenerator;

  /// Live catalog; null or empty falls back to the built-in list.
  final ProModelCatalog? catalog;

  /// Pinned model, or null for auto-routing.
  final ProModel? current;

  /// Called with the chosen model, or null for auto-routing.
  final ValueChanged<ProModel?> onSelected;

  @override
  State<ProModelPickerSheet> createState() => _ProModelPickerSheetState();
}

class _ProModelPickerSheetState extends State<ProModelPickerSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  ProModelCatalog get _catalog {
    final c = widget.catalog;
    return (c == null || c.isEmpty) ? kProModelCatalogFallback : c;
  }

  bool _matches(ProModel m) {
    if (_query.isEmpty) return true;
    final q = _query;
    return m.key.toLowerCase().contains(q) ||
        m.label.toLowerCase().contains(q) ||
        m.author.toLowerCase().contains(q) ||
        m.description.toLowerCase().contains(q);
  }

  bool _matchesGenerator(ProGenerator g) {
    if (_query.isEmpty) return true;
    final q = _query;
    return g.key.toLowerCase().contains(q) ||
        g.label.toLowerCase().contains(q) ||
        g.author.toLowerCase().contains(q) ||
        g.kind.toLowerCase().contains(q) ||
        g.description.toLowerCase().contains(q);
  }

  String? _credits(num? n) {
    if (_catalog.priceUnavailable || n == null || n <= 0) return null;
    return creditFigure(n);
  }

  String _generatorPrice(ProGenerator g) {
    final n = _credits(g.credits);
    if (n == null) return tr('price unavailable');
    return n == '1'
        ? tr('{n} Pro credit', {'n': n})
        : tr('{n} Pro credits', {'n': n});
  }

  String _resolutionLabel(GeneratorResolution r) {
    final n = _credits(r.credits);
    if (n == null) return r.res;
    return n == '1'
        ? tr('{res} · {n} credit', {'res': r.res, 'n': n})
        : tr('{res} · {n} credits', {'res': r.res, 'n': n});
  }

  Widget _groupHeader(String label, NymColors c) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
        child: Text(label.toUpperCase(),
            style: TextStyle(
                color: c.textDim,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6)),
      );

  Widget _priceNotice(NymColors c) => Container(
        key: proPriceUnavailableKey,
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: c.warning.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.warning.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 16, color: c.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  tr("The Bitcoin price can't be checked right now, so credit "
                      'estimates are hidden. Paid messages will wait until '
                      "it's back."),
                  style: TextStyle(color: c.text, fontSize: 12)),
            ),
          ],
        ),
      );

  Widget _generatorTile(ProGenerator g, NymColors c, bool hasPro) {
    final insert = widget.onGenerator;
    final chips = g.isVideo && g.resolutions.length > 1;
    return ListTile(
      leading: g.authorSlug.isEmpty
          ? Icon(g.isVideo ? Icons.movie_outlined : Icons.image_outlined,
              color: c.primary)
          : BrandTile(slug: g.authorSlug, size: 24),
      title: Text(g.label, style: TextStyle(color: c.text)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (g.description.isNotEmpty)
            Text(g.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: c.text.withValues(alpha: 0.75), fontSize: 11)),
          Text(
              [
                g.isVideo ? tr('video') : tr('image'),
                _generatorPrice(g),
              ].join(' · '),
              style: TextStyle(color: c.lightning, fontSize: 11)),
          if (g.needsImage)
            Text(
                g.isVideo
                    ? tr('Animates a picture you send')
                    : tr('Edits a picture you send'),
                style: TextStyle(color: c.textDim, fontSize: 11)),
          if (!hasPro)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: c.warning.withValues(alpha: 0.5)),
                ),
                child: Text(tr('Needs a Pro model'),
                    style: TextStyle(color: c.warning, fontSize: 10)),
              ),
            ),
          if (chips)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in g.resolutions)
                    ChoiceChip(
                      key: generatorResKey(g.key, r.res),
                      label: Text(_resolutionLabel(r)),
                      labelStyle: TextStyle(
                          color: r.res == g.resolution ? c.primary : c.text,
                          fontSize: 11),
                      selected: r.res == g.resolution,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: c.bgTertiary,
                      selectedColor: c.primary.withValues(alpha: 0.16),
                      side: BorderSide(
                          color: r.res == g.resolution
                              ? c.primary.withValues(alpha: 0.6)
                              : c.border),
                      onSelected: insert == null
                          ? null
                          : (_) => insert(g.insertText(r.res)),
                    ),
                ],
              ),
            ),
        ],
      ),
      isThreeLine: true,
      onTap: insert == null ? null : () => insert(g.insertText()),
    );
  }

  /// Only the catalog's set flags; "cloudflare" means no gateway hop or upstream to reject the call.
  String _tagLine(ProModel m) {
    final tags = <String>[
      if (m.vision) tr('vision'),
      if (m.reasoning) tr('reasoning'),
      if (m.tools) tr('tools'),
      // A brand name, so not translated.
      if (m.cloudflareHosted) 'cloudflare',
    ];
    return tags.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final current = widget.current;
    final groups = _catalog.grouped();
    final rows = <Widget>[];

    if (_query.isEmpty) {
      rows.add(ListTile(
        leading: Icon(Icons.auto_awesome, color: c.blue),
        title:
            Text(tr('Standard (auto-routed)'), style: TextStyle(color: c.text)),
        subtitle: Text(tr('Best model per task · 10 sats each'),
            style: TextStyle(color: c.textDim, fontSize: 11)),
        trailing: current == null ? Icon(Icons.check, color: c.primary) : null,
        onTap: () => widget.onSelected(null),
      ));
      rows.add(Divider(height: 1, color: c.border));
    }

    if (_catalog.priceUnavailable) rows.insert(0, _priceNotice(c));

    var shown = 0;
    for (final g in groups) {
      final models = g.value.where(_matches).toList();
      if (models.isEmpty) continue;
      if (g.key.isNotEmpty) rows.add(_groupHeader(g.key, c));
      for (final m in models) {
        shown++;
        final tags = _tagLine(m);
        final rates = m.ratesLabel();
        rows.add(ListTile(
          leading: m.authorSlug.isEmpty
              ? Icon(Icons.bolt, color: c.primary)
              : BrandTile(slug: m.authorSlug, size: 24),
          title: Text(m.label, style: TextStyle(color: c.text)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.description.isNotEmpty)
                Text(m.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: c.text.withValues(alpha: 0.75), fontSize: 11)),
              if (!_catalog.priceUnavailable)
                Text(
                    m.turnLabel(
                        _catalog.usdPerCredit, _catalog.minChargeCredits),
                    style: TextStyle(color: c.lightning, fontSize: 11)),
              if (rates != null || tags.isNotEmpty)
                Text(
                    [?rates, if (tags.isNotEmpty) tags]
                        .join(' — '),
                    style: TextStyle(color: c.textDim, fontSize: 11)),
            ],
          ),
          isThreeLine: true,
          trailing:
              current?.key == m.key ? Icon(Icons.check, color: c.primary) : null,
          onTap: () => widget.onSelected(m),
        ));
      }
    }

    final generatorRows = <Widget>[];
    for (final g in _catalog.groupedGenerators()) {
      final gens = g.value.where(_matchesGenerator).toList();
      if (gens.isEmpty) continue;
      if (g.key.isNotEmpty) generatorRows.add(_groupHeader(g.key, c));
      for (final gen in gens) {
        shown++;
        generatorRows.add(_generatorTile(gen, c, current != null));
      }
    }
    if (generatorRows.isNotEmpty) {
      rows.add(Divider(height: 1, color: c.border));
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 2),
        child: Text(tr('Generators'),
            style: TextStyle(
                color: c.textBright,
                fontSize: 14,
                fontWeight: FontWeight.w600)),
      ));
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
        child: Text(
            tr('Images and videos. Picking one fills in the command; your '
                'chat model stays the same.'),
            style: TextStyle(color: c.textDim, fontSize: 11)),
      ));
      rows.addAll(generatorRows);
    }

    if (shown == 0) {
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        child: Text(tr('No model matches your search.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, fontSize: 13)),
      ));
    }

    return SafeArea(
      child: ConstrainedBox(
        // Keeps the sheet clear of the status bar.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              // Labels share the width and ellipsize to survive narrow screens and large text.
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(tr('Pro model'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: c.textBright,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(tr('100 sats / credit'),
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: TextStyle(color: c.textDim, fontSize: 11)),
                  ),
                  DuoRailSwap.close(
                    onTap: () => Navigator.of(context).maybePop(),
                    child: IconButton(
                      key: const ValueKey('proModelPickerClose'),
                      tooltip: tr('Close'),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.close, size: 20, color: c.textDim),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ],
              ),
            ),
            // The live catalog can run to dozens of models, so it needs a filter.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                controller: _search,
                onChanged: (v) =>
                    setState(() => _query = v.trim().toLowerCase()),
                style: TextStyle(color: c.text, fontSize: 13),
                decoration: NymField.decoration(c,
                  hint: tr('Search models…'),
                  fontSize: 13,
                  radius: BorderRadius.circular(8),
                  prefixIcon: Icon(Icons.search, size: 18, color: NymField.icon(c)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
              ),
            ),
            // Only the models scroll; header and search stay.
            Flexible(
              child: ListView(
                key: proModelListKey,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: rows,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnonModal extends ConsumerStatefulWidget {
  const _AnonModal({required this.colors});

  final NymColors colors;

  @override
  ConsumerState<_AnonModal> createState() => _AnonModalState();
}

class _AnonModalState extends ConsumerState<_AnonModal> {
  final TextEditingController _amount = TextEditingController();
  CreditTier _tier = CreditTier.standard;
  String _status = '';
  bool _busy = false;
  BotBalance? _accountBalance;

  @override
  void initState() {
    super.initState();
    _tier = ref.read(botChatControllerProvider).isPro
        ? CreditTier.pro
        : CreditTier.standard;
    _loadAccountBalance();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _loadAccountBalance() async {
    final b =
        await ref.read(botChatControllerProvider.notifier).accountBalance();
    if (mounted) setState(() => _accountBalance = b);
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    await ref.read(botChatControllerProvider.notifier).setAnonEnabled(on);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = on
          ? tr('Anonymous mode on — Nymbot sees only the key below.')
          : '';
    });
  }

  Future<void> _move() async {
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    if (amount <= 0) {
      setState(() => _status = tr('Enter how many credits to move.'));
      return;
    }
    setState(() {
      _busy = true;
      _status = tr('Moving credits…');
    });
    try {
      final moved = await ref
          .read(botChatControllerProvider.notifier)
          .anonMoveCredits(amount, _tier);
      if (!mounted) return;
      _amount.clear();
      setState(() => _status =
          '${tr('Moved')} $moved ${tr('credits to your throwaway key.')}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_loadAccountBalance());
    }
  }

  Future<void> _rotate() async {
    setState(() {
      _busy = true;
      _status = tr('Rotating…');
    });
    try {
      final moved = await ref
          .read(botChatControllerProvider.notifier)
          .anonRotate(sweep: true);
      if (!mounted) return;
      setState(() => _status = moved > 0
          ? tr('New throwaway key created. The old key\'s balance became '
              'anonymous vouchers the new key uses as needed.')
          : tr('New throwaway key created.'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final state = ref.watch(botChatControllerProvider);
    final anonPk = state.anonPubkey;
    final acct = _accountBalance;
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
            Text(tr('Anonymous Nymbot chat'),
                style: TextStyle(
                    color: c.textBright,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              tr('This chat is already end-to-end encrypted, but Nymbot still '
                  'sees which pubkey is talking to it. Turn this on and every '
                  'message and reply travels under a throwaway key generated on '
                  'this device — the same trick group chats use. Credits move '
                  'across as blind vouchers Nymbot signs without seeing, so its '
                  'records cannot link the two.'),
              style: TextStyle(color: c.textDim, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            SettingsToggleRow(
              key: const ValueKey('botAnonToggle'),
              sub: true,
              label: tr('Anonymous mode'),
              hint: tr('Send this chat from a throwaway key'),
              value: state.anonEnabled,
              onChanged: _busy ? null : (v) => _toggle(v),
            ),
            if (state.anonEnabled) ...[
              const SizedBox(height: 6),
              Text(
                anonPk == null || anonPk.isEmpty
                    ? tr('Throwaway key: not created yet')
                    : 'Throwaway key: ${anonPk.substring(0, 16)}…'
                        '${anonPk.substring(anonPk.length - 8)}',
                style: TextStyle(color: c.textDim, fontSize: 11),
              ),
              const SizedBox(height: 4),
              Text(
                'Anonymous: ${creditFigure(state.balance.balance)} standard · '
                '${creditFigure(state.balance.proBalance)} Pro'
                '${acct == null ? '' : ' · your nym: ${creditFigure(acct.balance)} standard · ${creditFigure(acct.proBalance)} Pro'}',
                style: TextStyle(color: c.textDim, fontSize: 11),
              ),
              const SizedBox(height: 14),
              Text(tr('Move credits across'),
                  style: TextStyle(color: c.textDim, fontSize: 12)),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _amount,
                      keyboardType: TextInputType.number,
                      style: TextStyle(color: c.inputText, fontSize: 14),
                      decoration: NymField.decoration(c,
                          hint: tr('credits'),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<CreditTier>(
                    value: _tier,
                    dropdownColor: c.bgSecondary,
                    style: TextStyle(color: c.text, fontSize: 13),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _tier = v ?? _tier),
                    items: [
                      DropdownMenuItem(
                          value: CreditTier.standard,
                          child: Text(tr('Standard'))),
                      DropdownMenuItem(
                          value: CreditTier.pro, child: Text(tr('Pro'))),
                    ],
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : _move,
                    child: Text(tr('Move')),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: _busy ? null : _rotate,
                child: Text(tr('New throwaway key')),
              ),
            ],
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_status,
                  style: TextStyle(color: c.textDim, fontSize: 12, height: 1.4)),
            ],
          ],
        ),
      ),
    );
  }
}

// Fallback colors for bare widget tests without the theme extension.

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

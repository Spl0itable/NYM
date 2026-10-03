import 'dart:async';
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
import '../../widgets/common/css_focus_ring.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/composer.dart'
    show ComposerDrafts, EmojiSentinelController;
import '../../widgets/chat/message_row.dart'
    show MessageGroup, MessageGroupEntry;
import '../../widgets/chat/typing_indicator.dart';
import '../../widgets/context_menu/interaction_hooks.dart';
import '../../widgets/nym_icons.dart';
import '../autocomplete/autocomplete_dropdown.dart';
import '../autocomplete/autocomplete_queries.dart' show queryEmoji, EmojiResult;
import '../autocomplete/autocomplete_triggers.dart';
import '../commands/command_i18n.dart';
import '../commands/command_palette.dart'
    show
        buildPaletteRows,
        commandItemRow,
        paletteCommands,
        CommandPalette,
        PaletteRow;
import '../commands/command_registry.dart' show CommandSpec;
import '../emoji/emoji_data.dart';
import '../emoji/emoji_picker.dart';
import '../emoji/gif_picker.dart';
import '../i18n/i18n.dart';
import '../messages/format/nym_format.dart' show NymFormat;
import '../reactions/reaction_picker.dart';
import '../threads/thread_view.dart' show ThreadView;
import '../translate/translate_languages.dart';
import '../translate/translate_service.dart';
import 'bot_credits_modal.dart';
import 'bot_runs.dart' show kBotRunPollEvery;
import 'bot_runs_view.dart';
import 'nymbot_models.dart';
import 'brand_tile.dart';
import 'nymbot_providers.dart';
import '../chat_lock/chat_lock_providers.dart';

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
  final _composerKey = GlobalKey<_BotComposerState>();

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
        _BotComposer(
          key: _composerKey,
          colors: c,
          onSubmit: (content) {
            ref.read(botChatControllerProvider.notifier).sendUserBotPM(content);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _scrollToBottom();
            });
          },
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

    return ColoredBox(
      color: containerColor,
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView.builder(
              controller: _scroll,
              reverse: true,
              // Dragging the list dismisses the keyboard.
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              itemCount: units.length,
              itemBuilder: (context, revIndex) {
                final unit = units[units.length - 1 - revIndex];
                // Keyed by the group's lead id so appended replies don't re-create visible rows and restart their snap-in.
                final group = MessageGroup(
                  key: ValueKey('botgroup_${unit.first.message.id}'),
                  entries: unit,
                  settings: settings,
                  onReactionPicker: (msg) =>
                      showReactionPicker(context, ref, msg),
                );
                final last = unit.last.message;
                if (!hasStatus(last)) return group;
                if (!last.isOwn) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
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
                    group,
                    BotRunStatusView(id: runId, colors: c),
                  ],
                );
              },
            ),
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
      (cur.createdAt - prev.createdAt).abs() <= _groupWindowSec;

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
    showModalBottomSheet<void>(
      context: context,
      // Otherwise the sheet is capped at 9/16 of the screen.
      isScrollControlled: true,
      backgroundColor: c.bgSecondary,
      builder: (_) => Consumer(
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
            _composerKey.currentState?.fillWith(text);
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
        ? c.primaryA(0.15)
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
            active: anonOn,
            labelMaxWidth: labelMax,
            colors: c,
            compact: compact,
            onTap: onTapAnon,
          ),
          if (runsCount > 0 && onStopAll != null) ...[
            SizedBox(width: gap),
            Tooltip(
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
          _CtrlButton(
            svg: _kSvgBolt,
            label: tr('Buy'),
            active: false,
            buy: true,
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
  });

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

    return MouseRegion(
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

class _BotComposer extends ConsumerStatefulWidget {
  const _BotComposer({
    super.key,
    required this.colors,
    required this.onSubmit,
  });

  final NymColors colors;

  /// Receives the outgoing content, quote prefix applied.
  final ValueChanged<String> onSubmit;

  @override
  ConsumerState<_BotComposer> createState() => _BotComposerState();
}

class _BotComposerState extends ConsumerState<_BotComposer> {
  /// Shared rich controller: known `:code:` renders inline while composing, expanded back at send.
  final _controller = EmojiSentinelController();
  final _focus = FocusNode();

  /// Filtered `?` suggestions; empty hides the palette.
  List<BotPMCommand> _suggestions = const [];

  /// Live trigger for `/`, `?` and `:` palettes via the shared [detectTrigger].
  TriggerMatch _trigger = const TriggerMatch.none();
  List<PaletteRow> _cmdRows = const [];
  AutocompleteView? _acView;

  /// True when any palette is live and not suppressed.
  bool get _paletteActive =>
      !_suppressPalette &&
      (_suggestions.isNotEmpty ||
          _cmdRows.isNotEmpty ||
          (_acView != null && !_acView!.isEmpty));

  /// Selectable rows in the active palette.
  int get _paletteLength {
    if (_cmdRows.isNotEmpty) return paletteCommands(_cmdRows).length;
    if (_acView != null && !_acView!.isEmpty) return _acView!.itemCount;
    return _suggestions.length;
  }

  /// Highlighted row, reset to the first on every input change.
  int _paletteIndex = 0;

  /// Escape hides the palette until the text changes.
  bool _suppressPalette = false;

  /// Anchors the palette overlay above the input so it floats over the conversation.
  final _acAnchor = LayerLink();
  final _acPortal = OverlayPortalController();

  /// Groups the field and palette so outside taps dismiss it.
  final Object _acGroupId = Object();
  final _inputKey = GlobalKey();

  /// Deferred post-frame because show()/hide() can't run mid-build.
  void _syncPalettePortal() {
    final want = _paletteActive;
    if (want == _acPortal.isShowing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final show = _paletteActive;
      if (show && !_acPortal.isShowing) _acPortal.show();
      if (!show && _acPortal.isShowing) _acPortal.hide();
    });
  }

  /// Palette overlay matching the input width, flush with its top.
  Widget _paletteOverlay(BuildContext context) {
    final box = _inputKey.currentContext?.findRenderObject() as RenderBox?;
    final width = (box != null && box.hasSize)
        ? box.size.width
        : MediaQuery.sizeOf(context).width;
    return CompositedTransformFollower(
      link: _acAnchor,
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      showWhenUnlinked: false,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Material(
          type: MaterialType.transparency,
          child: TapRegion(
            groupId: _acGroupId,
            child: SizedBox(width: width, child: _palette(widget.colors)),
          ),
        ),
      ),
    );
  }

  /// Last input text, so selection-only notifications aren't input events.
  String _lastText = '';

  /// Pending quote: author, nested-quote-stripped [text] sent at send time, and [fullText] shown in the chip.
  ({String author, String text, String fullText})? _pendingQuote;

  // Emoji and GIF pickers anchored above their toolbar buttons.
  final _emojiPortal = OverlayPortalController();
  final _gifPortal = OverlayPortalController();
  final _emojiAnchor = LayerLink();
  final _gifAnchor = LayerLink();
  SharedPreferences? _prefs;
  List<String> _recents = const [];

  // The bot PM has the same attachment buttons as other conversations.

  /// Upload progress 0..1, or null when hidden.
  double? _uploadProgress;
  String? _uploadMime;
  bool _uploadCancelled = false;

  /// 1-based index and total for multi-file uploads; 0/0 for single.
  int _uploadIndex = 0;
  int _uploadTotal = 0;

  // In-composer translate button and its dropdown.
  final _translatePortal = OverlayPortalController();
  final _translateAnchor = LayerLink();
  final _translateSearchController = TextEditingController();
  String _translateQuery = '';
  bool _translating = false;

  /// Translate favorites pinned to the top of the list.
  List<String> _translateFavorites = const [];

  /// Order snapshotted at open so toggling a star doesn't reshuffle.
  List<MapEntry<String, String>> _translateLangOrder = const [];

  /// Bot draft key in the shared draft store.
  static final String _draftKey =
      ComposerDrafts.keyFor(const ChatView.pm(kNymbotPubkey));

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focus.addListener(() => setState(() {}));
    // Restore any unsent draft, post-frame so setState never runs mid-mount.
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
    // Save the unsent input before unmounting; a blank draft deletes it.
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
    // Collapse a just-completed `:code:` into its inline sentinel; the re-notify is a no-op.
    _controller.resolveInput();
    final text = _controller.text;
    final textChanged = text != _lastText;
    _lastText = text;

    // Shared trigger detector; `botPM: true` keeps `?` alive past a space.
    final sel = _controller.selection;
    final caret = sel.isValid ? sel.start : text.length;
    _trigger = detectTrigger(text, caret: caret, botPM: true);

    var nextBot = const <BotPMCommand>[];
    var nextCmd = const <PaletteRow>[];
    AutocompleteView? nextAc;
    switch (_trigger.kind) {
      case TriggerKind.command:
        nextCmd = buildPaletteRows(_trigger.query);
        break;
      case TriggerKind.botCommand:
        nextBot = [
          for (final c in filterBotPMCommands(canonicalizeCommandInput(text)))
            BotPMCommand(name: localizeCommandTokensIn(c.name), desc: c.desc),
        ];
        break;
      case TriggerKind.emoji:
        final results = queryEmoji(
          search: _trigger.query,
          recents: _recents,
          custom: ref.read(liveCustomEmojiProvider),
        );
        if (results.isNotEmpty) nextAc = AutocompleteView.emoji(results);
        break;
      case TriggerKind.none:
      case TriggerKind.mention:
      case TriggerKind.channel:
      case TriggerKind.kaomoji:
        break;
    }

    if (textChanged) {
      // Every input event re-shows the palette and highlights the first row.
      _suppressPalette = false;
      _paletteIndex = 0;
    }
    setState(() {
      _suggestions = nextBot;
      _cmdRows = nextCmd;
      _acView = nextAc;
    });
  }

  void _pick(BotPMCommand cmd) {
    final text = '${cmd.name} ';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    // Re-filter so a multi-step command shows its subcommands.
    _onTextChanged();
    _focus.requestFocus();
  }

  void fillWith(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onTextChanged();
    _focus.requestFocus();
  }

  /// Completes a `/` command as `"<command> "`.
  void _completeCommand(CommandSpec spec) {
    final name = localizedCommandToken(spec.name);
    _controller.value = TextEditingValue(
      text: '$name ',
      selection: TextSelection.collapsed(offset: name.length + 1),
    );
    _onTextChanged();
    _focus.requestFocus();
  }

  /// Splices the emoji over the `:token`.
  void _completeEmoji(EmojiResult result) {
    final start = _trigger.triggerIndex;
    final text = _controller.text;
    final sel = _controller.selection;
    final caret = sel.isValid ? sel.start : text.length;
    if (start < 0 || start > caret) return;
    final next = text.replaceRange(start, caret, result.insertText);
    _controller.value = TextEditingValue(
      text: next,
      selection:
          TextSelection.collapsed(offset: start + result.insertText.length),
    );
    _onTextChanged();
    _focus.requestFocus();
  }

  /// Applies the selected row of the active palette.
  void _completeSelected() {
    final i = _paletteIndex.clamp(0, (_paletteLength - 1).clamp(0, 1 << 30));
    if (_cmdRows.isNotEmpty) {
      final cmds = paletteCommands(_cmdRows);
      if (i < cmds.length) _completeCommand(cmds[i]);
    } else if (_acView != null && !_acView!.isEmpty) {
      final emoji = _acView!.emoji;
      if (i < emoji.length) _completeEmoji(emoji[i]);
    } else if (i < _suggestions.length) {
      _pick(_suggestions[i]);
    }
  }

  void _applyComposerAction(ComposerAction action) {
    switch (action) {
      case MentionAction(:final fullNym):
        final existing = _controller.text;
        final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
        _controller.text = '$existing${needsSpace ? ' ' : ''}@$fullNym ';
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
      case QuoteAction(:final fullNym, :final content):
        _pendingQuote = (
          author: fullNym,
          text: _strippedQuoteText(content),
          fullText: content,
        );
      case InsertTextAction() || ShareFilesAction():
        // Share-sheet actions target real conversations, never the bot chat.
        return;
    }
    _focus.requestFocus();
    setState(() {});
  }

  /// Keeps only top-level quote lines, collapses blank runs and trims.
  static String _strippedQuoteText(String text) {
    final kept = <String>[];
    for (final line in text.split('\n')) {
      if (!line.startsWith('>')) kept.add(line);
    }
    return kept.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Chip preview: markup stripped, capped at 120.
  static String _quotePreviewText(String text) {
    final clean = NymFormat.stripForPreview(text)
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'[*_~`>#]'), '');
    return clean.length > 120 ? '${clean.substring(0, 120)}...' : clean;
  }

  void _clearQuote() {
    if (_pendingQuote == null) return;
    setState(() => _pendingQuote = null);
  }

  /// Prepends the pending quote only at send.
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
    // Expand sentinels to literal `:code:` before anything leaves the composer.
    final typed = _controller.expand(_controller.text).trim();
    // A bare quote can be sent.
    if (typed.isEmpty && _pendingQuote == null) return;
    final content = _composeOutgoing(typed);
    widget.onSubmit(content);
    _controller.clear();
    setState(() {});
    _focus.requestFocus();
  }

  /// With the palette open: arrows move, Enter/Tab pick, Escape hides; otherwise Enter sends and Shift+Enter adds a newline.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (_paletteActive) {
      final n = _paletteLength;
      if (n > 0 && event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() => _paletteIndex = (_paletteIndex + 1) % n);
        return KeyEventResult.handled;
      }
      if (n > 0 && event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() => _paletteIndex = (_paletteIndex - 1 + n) % n);
        return KeyEventResult.handled;
      }
      if (isEnter || event.logicalKey == LogicalKeyboardKey.tab) {
        _completeSelected();
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

  /// Inserts at the caret, keeping focus in the input.
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
    _focus.requestFocus();
  }

  /// Closes a picker without a selection; refocuses the input only above 768px so phone keyboards don't pop.
  void _hidePickerAndRefocus(OverlayPortalController portal) {
    portal.hide();
    if (!mounted) return;
    if (MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint) {
      return;
    }
    _focus.requestFocus();
  }

  void _hideEmojiPicker() => _hidePickerAndRefocus(_emojiPortal);

  void _hideGifPicker() => _hidePickerAndRefocus(_gifPortal);

  Future<void> _onEmojiSelected(String emoji) async {
    _insertAtCaret(emoji);
    _emojiPortal.hide();
    final prefs = await _ensurePrefs();
    final next = await EmojiRecentsStore(prefs).add(emoji);
    if (!mounted) return;
    setState(() => _recents = next);
  }

  void _onGifSelected(String url) {
    // The formatter renders the appended GIF URL as media.
    _insertAtCaret(url);
    _gifPortal.hide();
  }

  Future<void> _toggleEmojiPicker() async {
    if (_emojiPortal.isShowing) {
      _hideEmojiPicker();
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
      _hideGifPicker();
      return;
    }
    _emojiPortal.hide();
    await _ensurePrefs();
    if (!mounted) return;
    _gifPortal.show();
  }

  /// A system line in the bot conversation, for upload errors.
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

  /// Uploads picked media to Blossom and appends the URLs to the input.
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
        _systemLine(tr('Files must be under 50MB.'));
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
        _systemLine(tr('Failed to upload media.'));
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
    // Drop results if cancelled mid-batch.
    if (wasCancelled || urls.isEmpty) return;
    // Append URLs space-joined plus a trailing space.
    final existing = _controller.text;
    final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
    _controller.text = '$existing${needsSpace ? ' ' : ''}${urls.join(' ')} ';
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    _focus.requestFocus();
  }

  /// Offers a picked file as a P2P transfer.
  Future<void> _pickAndShareFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(withData: true);
    } catch (_) {
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _systemLine(tr('Could not read the selected file.'));
      return;
    }
    await ref.read(nostrControllerProvider).shareP2PFile(
          bytes: bytes,
          name: file.name,
          type: _guessMime(file.name),
        );
    if (mounted) _systemLine(tr('File offered for P2P download.'));
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

  /// Upload panel with label, cancel and gradient progress bar.
  Widget _uploadBar(BuildContext context) {
    final c = widget.colors;
    final isVideo = (_uploadMime ?? '').startsWith('video/');
    final label = _uploadTotal > 1
        ? tr('Uploading {i} of {n}...', {'i': _uploadIndex, 'n': _uploadTotal})
        : isVideo
            ? tr('Uploading video...')
            : tr('Uploading image...');
    final fraction = (_uploadProgress ?? 0.1).clamp(0.0, 1.0);
    final solidUi = ref.watch(settingsProvider.select((s) => s.solidUi));
    return Container(
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
              // Cancels the in-flight upload.
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

  /// Present only while there is text; anchors the language dropdown.
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
      // Snapshot the favorites order at open.
      _translateLangOrder =
          sortedTranslateLanguagesWithFavorites(_translateFavorites);
    });
    _translateSearchController.clear();
    _translatePortal.show();
  }

  /// Persisted translate favorites.
  static List<String> _loadTranslateFavorites(SharedPreferences prefs) {
    final raw = prefs.getString(kTranslateFavoritesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return const [];
  }

  /// Toggle [code] in favorites and persist.
  void _toggleTranslateFavorite(String code) {
    final next = [..._translateFavorites];
    if (!next.remove(code)) next.add(code);
    setState(() => _translateFavorites = next);
    _prefs?.setString(kTranslateFavoritesKey, jsonEncode(next));
  }

  /// Language dropdown that translates the draft in place.
  Widget _translateDropdown(BuildContext context) {
    final c = widget.colors;
    final q = _translateQuery.trim().toLowerCase();
    // Star fill reads live favorites; row order uses the open-time snapshot.
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
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border:
                            Border(bottom: BorderSide(color: c.glassBorder)),
                      ),
                      // Not autofocused, which would pull the IME away from the message input.
                      child: TextField(
                        controller: _translateSearchController,
                        onChanged: (v) => setState(() => _translateQuery = v),
                        style: TextStyle(color: c.inputText, fontSize: 13),
                        cursorColor: c.isLight ? Colors.black : Colors.white,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: tr('Search languages...'),
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
                      child: langs.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(14),
                              child: Text(tr('No languages found'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: c.textDim, fontSize: 13)),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 4),
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

  /// Translates the draft in place, expanding emoji sentinels first.
  Future<void> _translateDraft(String targetLang) async {
    _translatePortal.hide();
    final text = _controller.expand(_controller.text).trim();
    if (text.isEmpty) return;
    setState(() => _translating = true);
    try {
      final res = await TranslateService().translate(text, targetLang);
      if (!mounted) return;
      final out = res.translatedText;
      // Don't clobber the input on an empty or echoed result.
      if (out.trim().isEmpty || out.trim() == text) {
        _systemLine(tr(
            'Nothing to translate (text may already be in the target language).'));
        return;
      }
      _controller.text = out;
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    } catch (e) {
      // The exception message already carries the "Translation failed" prefix.
      if (mounted) {
        _systemLine(e is TranslateException
            ? e.message
            : tr('Translation failed: Unknown error'));
      }
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    // Send is gated on connection, not content, and stays enabled while a reply is pending.
    final sendEnabled = ref.watch(
          appStateProvider.select((s) => s.connectedRelays > 0),
        ) ||
        ref.read(nostrControllerProvider).isLive;

    // Live custom emoji map so emoji render inline while composing.
    _controller.codeToUrl = ref.watch(liveCustomEmojiProvider).codeToUrl;

    // Apply one-shot mention/quote requests.
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
                    // The chip shows the full original; only the sent quote is stripped.
                    text: _quotePreviewText(_pendingQuote!.fullText),
                    onClose: _clearQuote,
                  ),
                ),
        ),
        Focus(onKeyEvent: _onKey, child: _textField(context, phone)),
      ],
    );

    // The palette floats over the messages in an OverlayPortal rather than growing the input area.
    final inputWithPalette = CompositedTransformTarget(
      key: _inputKey,
      link: _acAnchor,
      child: OverlayPortal(
        controller: _acPortal,
        overlayChildBuilder: _paletteOverlay,
        child: input,
      ),
    );
    _syncPalettePortal();

    final toolbar = _toolbar(context, sendEnabled, compact, phone);

    return Container(
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      padding: phone
          ? const EdgeInsets.all(10)
          : const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Upload progress floats above the input.
            if (_uploadProgress != null) _uploadBar(context),
            compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      inputWithPalette,
                      const SizedBox(height: 10),
                      toolbar,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(child: inputWithPalette),
                      const SizedBox(width: 10),
                      toolbar,
                    ],
                  ),
          ],
        ),
      ),
    );
  }

  /// Message input with bottom-only rounding and a focus ring.
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
    final incog = ref.watch(incognitoFieldFlagsProvider);
    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      enableIMEPersonalizedLearning: incog.imeLearning,
      autocorrect: incog.autocorrect,
      enableSuggestions: incog.suggestions,
      groupId: _acGroupId,
      onTapOutside: (_) {
        if (_suggestions.isNotEmpty && !_suppressPalette) {
          setState(() => _suppressPalette = true);
        }
      },
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
        hintText: tr('Message, / for commands, ? for Nymbot...'),
        hintStyle: TextStyle(
            color: (c.isLight ? Colors.black : Colors.white)
                .withValues(alpha: 0.4),
            fontSize: phone ? 16 : 15),
        filled: true,
        fillColor: flatFill,
        // Reserve right padding only while the translate button exists.
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
        // The translate button only exists while there is text.
        if (hasText)
          Positioned(
            right: 8,
            bottom: 10,
            child: _translateButton(context),
          ),
      ],
    );
    // Focus ring painted outside the field only.
    return CssFocusRing(
      show: focused,
      color: c.primaryA(0.06),
      radius: radius,
      child: stack,
    );
  }

  /// Exactly five controls: Image, File, Emoji, GIF and Send.
  Widget _toolbar(
      BuildContext context, bool sendEnabled, bool compact, bool phone) {
    final buttons = <Widget>[
      _BotIconBtn(
        svg: NymIcons.composerImage,
        tooltip: tr('Upload Image/Video'),
        expand: compact,
        // Inert until relays connect, then the in-upload guard applies.
        enabled: sendEnabled,
        onTap: _uploadProgress != null ? null : _pickAndUploadImage,
      ),
      _BotIconBtn(
        svg: NymIcons.composerFile,
        tooltip: tr('Share File (P2P)'),
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
          onDismiss: _hideEmojiPicker,
          child: EmojiPicker(
            recents: _recents,
            onSelect: _onEmojiSelected,
            onClose: _hideEmojiPicker,
          ),
        ),
        child: _BotIconBtn(
          svg: NymIcons.composerEmoji,
          tooltip: tr('Emoji'),
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
            onDismiss: _hideGifPicker,
            child: GifPicker(
              favoritesStore: FavoriteGifsStore(prefs),
              onSelect: _onGifSelected,
              onClose: _hideGifPicker,
            ),
          );
        },
        child: _BotIconBtn(
          label: 'GIF',
          tooltip: tr('GIF'),
          expand: expand,
          enabled: enabled,
          onTap: _toggleGifPicker,
        ),
      ),
    );
  }

  /// Picker positioned above its button with a tap-out barrier; centered above the input on phones.
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

  /// Command palette rows with the selected one highlighted.
  Widget _palette(NymColors c) {
    // `/` and `:` palettes reuse the shared widgets; `?` keeps bespoke rows.
    if (_cmdRows.isNotEmpty) {
      return CommandPalette(
        rows: _cmdRows,
        selectedIndex:
            _paletteIndex.clamp(0, (_paletteLength - 1).clamp(0, 1 << 30)),
        onSelect: _completeCommand,
      );
    }
    final ac = _acView;
    if (ac != null && !ac.isEmpty) {
      return AutocompleteDropdown(
        view: ac,
        selectedIndex: _paletteIndex,
        custom: ref.watch(liveCustomEmojiProvider),
        onSelectMention: (_) {},
        onSelectChannel: (_) {},
        onSelectKaomoji: (_) {},
        onSelectEmoji: _completeEmoji,
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      constraints: const BoxConstraints(maxHeight: 200),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
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
          // Shared command row: sized name, wrapping localized description.
          return commandItemRow(
            c,
            name: cmd.name,
            desc: cmd.desc,
            selected: i == _paletteIndex,
            onTap: () => _pick(cmd),
          );
        },
      ),
    );
  }
}

/// Quote chip: accent bar, author with dim suffix, truncated text and close.
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
    final split = splitNymSuffix(author);
    final base = split.base;
    final suffix = split.suffix;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        border: Border.all(color: c.glassBorder),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(NymRadius.md)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
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

/// 42px input toolbar button; glyph turns primary on hover, disabled dims.
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
    // Same mode-aware fill/border/hover as the main composer's button.
    final Color fill;
    final Color borderColor;
    final Color labelColor;
    if (c.isLight) {
      fill = hovered
          ? Colors.black.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.03);
      borderColor = hovered ? c.primary : Colors.black.withValues(alpha: 0.1);
      labelColor = c.primary;
    } else {
      fill = hovered ? c.primaryA(0.12) : Colors.white.withValues(alpha: 0.05);
      borderColor = hovered ? c.primaryA(0.30) : c.glassBorder;
      labelColor = hovered ? c.primary : c.text;
    }
    final glyphColor = hovered ? c.primary : c.text;
    final child = widget.svg != null
        ? NymSvgIcon(widget.svg!, size: 18, color: glyphColor)
        : Text(
            widget.label!,
            style: TextStyle(
              color: labelColor,
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
            child: AnimatedContainer(
              duration: NymMotion.transition,
              curve: NymMotion.curve,
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                border: Border.all(color: borderColor),
                borderRadius: NymRadius.rsm,
                boxShadow: hovered
                    ? [BoxShadow(color: c.primaryA(0.10), blurRadius: 15)]
                    : null,
              ),
              child: widget.expand ? Center(child: child) : child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Send pill; hover deepens the fill, disabled dims, phones shrink it.
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
              tr('SEND'),
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

/// Translate glyph overlaid on the input, pulsing while translating.
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
      glyph = FadeTransition(
        opacity: Tween(begin: 0.4, end: 0.8).animate(_pulse),
        child: glyph,
      );
    }
    return Opacity(
      opacity: widget.enabled ? (_hover ? 1.0 : 0.6) : 0.4,
      child: Tooltip(
        message: tr('Translate text'),
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

/// Language row with a trailing favorite star.
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
          color: _hover
              ? (c.isLight
                  ? Colors.black.withValues(alpha: 0.05)
                  : Colors.white.withValues(alpha: 0.08))
              : null,
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

/// Key for the scrolling model list, so tests target it rather than the search field's Scrollable.
const Key proModelListKey = ValueKey('proModelList');

const Key proPriceUnavailableKey = ValueKey('proPriceUnavailable');

Key generatorResKey(String generatorKey, String res) =>
    ValueKey('generatorRes:$generatorKey:$res');

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
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr('Search models…'),
                  hintStyle: TextStyle(color: c.textDim, fontSize: 13),
                  prefixIcon: Icon(Icons.search, size: 18, color: c.textDim),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.primary),
                  ),
                ),
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
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: state.anonEnabled,
              thumbColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) return c.primary;
                return null;
              }),
              title: Text(tr('Anonymous mode'),
                  style: TextStyle(color: c.text, fontSize: 14)),
              subtitle: Text(tr('Send this chat from a throwaway key'),
                  style: TextStyle(color: c.textDim, fontSize: 11)),
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
                      decoration: InputDecoration(
                        hintText: tr('credits'),
                        hintStyle: TextStyle(color: c.textDim),
                        isDense: true,
                        filled: true,
                        fillColor: c.bgTertiary,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        border: const OutlineInputBorder(),
                      ),
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/polls/poll_card.dart';
import '../../features/reactions/reaction_picker.dart';
import '../../models/channel.dart';
import '../../models/message.dart';
import '../../models/poll.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../nym_icons.dart';
import 'message_row.dart';
import 'message_skeleton.dart';
import 'typing_indicator.dart';

/// Scroll-to-a-specific-message handle for the active [MessagesList], shared via
/// [messageListScrollerProvider] so the blockquote tap (in `message_content.dart`)
/// can jump the list to a quoted source message — the infrastructure behind the
/// PWA's `_scrollToQuotedMessage` (`target.scrollIntoView({block:'center'})`,
/// messages.js:2768-2774). The list reverses (newest at index 0), and items are
/// built lazily, so a plain `ListView` can't land on an off-screen message — this
/// wraps the package's [ItemScrollController] and a live message-id → render-index
/// map the list republishes on every build.
class MessageListScroller {
  ItemScrollController? _controller;

  /// message id → reversed render-unit index (the `ScrollablePositionedList`
  /// index), rebuilt by [MessagesList] each build for the current view.
  Map<String, int> _indexById = const {};

  /// Called by [MessagesList] every build to (re)bind its controller + the
  /// current id→index map.
  void bind(ItemScrollController controller, Map<String, int> indexById) {
    _controller = controller;
    _indexById = indexById;
  }

  /// Whether [messageId] is in the currently-rendered set (so a jump can land).
  bool canScrollTo(String messageId) =>
      _indexById.containsKey(messageId) && (_controller?.isAttached ?? false);

  /// Smooth-scrolls the list so [messageId] sits ~centered (PWA `block:'center'`).
  /// No-ops when the message isn't in the loaded set or the list isn't attached
  /// (the PWA likewise bails — "Original message is not available" — when the
  /// target can't be found). Returns true when a scroll was issued.
  bool scrollToMessage(String messageId) {
    final index = _indexById[messageId];
    final controller = _controller;
    if (index == null || controller == null || !controller.isAttached) {
      return false;
    }
    controller.scrollTo(
      index: index,
      // Leading-edge fraction of the viewport — ~0.4 lands the message a little
      // above center, the closest analogue to `scrollIntoView({block:'center'})`.
      alignment: 0.4,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    return true;
  }
}

/// The shared [MessageListScroller] for the mounted message list. A plain
/// `Provider` (single instance for the app's lifetime); [MessagesList] binds its
/// controller into it on build.
final messageListScrollerProvider =
    Provider<MessageListScroller>((ref) => MessageListScroller());

/// The scrolling message list (`.messages-container`, column-reverse). Renders
/// `messagesForCurrentViewProvider` newest-at-bottom via a reversed ListView,
/// supporting both IRC and bubble layouts. Bubble mode groups consecutive
/// same-author messages within 5 minutes (collapse name + tail). Inline poll
/// cards (`pollsForCurrentViewProvider`) are interleaved by `createdAt`.
/// (docs/specs/02 §6, docs/specs/03 §2.7)
class MessagesList extends ConsumerStatefulWidget {
  const MessagesList({super.key});

  @override
  ConsumerState<MessagesList> createState() => _MessagesListState();
}

class _MessagesListState extends ConsumerState<MessagesList> {
  static const int _groupWindowSec = 300; // 5 min

  /// Drives [ScrollablePositionedList.scrollTo] for the jump-to-quoted-message
  /// feature; bound into [messageListScrollerProvider] on every build.
  final ItemScrollController _itemScrollController = ItemScrollController();

  /// Reports the currently-visible render-index range so the scroll-to-bottom
  /// FAB can mirror the PWA's `distanceFromBottom > 150` gate (`app.js:7120`).
  /// In the `reverse:true` list, index 0 is the newest message at the bottom.
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();

  /// Whether the jump-to-latest FAB is currently shown (the user has scrolled
  /// up away from the newest message).
  bool _showScrollButton = false;

  /// The messages viewport height in px, captured at build — converts the
  /// normalized [ItemPosition] edges into the PWA's pixel scroll distance.
  double _viewportHeight = 0;

  @override
  void initState() {
    super.initState();
    _positionsListener.itemPositions.addListener(_onPositionsChanged);
  }

  @override
  void dispose() {
    _positionsListener.itemPositions.removeListener(_onPositionsChanged);
    super.dispose();
  }

  /// Recomputes [_showScrollButton] from the visible item positions — the
  /// PWA's fixed-pixel `distanceFromBottom > 150` gate (`app.js:7120-7124`).
  /// In the `reverse:true` list, scroll offset 0 rests index 0's leading
  /// (bottom) edge 16px inside the viewport (the list's bottom padding), so
  /// the pixel distance scrolled away from the bottom is
  /// `16 − itemLeadingEdge × viewportHeight`. When index 0 isn't laid out at
  /// all the user is far beyond 150px, so the FAB always shows.
  void _onPositionsChanged() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    ItemPosition? newest;
    for (final p in positions) {
      if (p.index == 0) {
        newest = p;
        break;
      }
    }
    final bool shouldShow;
    if (newest == null) {
      shouldShow = true;
    } else if (_viewportHeight <= 0) {
      shouldShow = false;
    } else {
      final distanceFromBottom = 16 - newest.itemLeadingEdge * _viewportHeight;
      shouldShow = distanceFromBottom > 150;
    }
    if (shouldShow != _showScrollButton) {
      setState(() => _showScrollButton = shouldShow);
    }
  }

  /// Smooth-scrolls the list back to the newest message (index 0 in the
  /// reversed list), mirroring the PWA `scrollToBottom()` (`app.js:2142`).
  void _scrollToBottom() {
    if (!_itemScrollController.isAttached) return;
    _itemScrollController.scrollTo(
      index: 0,
      alignment: 0,
      duration: NymMotion.transition,
      curve: NymMotion.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final messages = ref.watch(messagesForCurrentViewProvider);
    final reactions = ref.watch(reactionsProvider);
    final polls = ref.watch(pollsForCurrentViewProvider);
    // The history-edge notice is channel-only (the PWA's PM back-pager never
    // prepends one).
    final isChannel = app.view.kind == ViewKind.channel;

    // `.messages-container`: bg rgba(0,0,0,0.15) dark; light-mode flips it to
    // rgba(255,255,255,0.3) (a light wash over the page), so it must be
    // mode-aware or the message area looks dark-tinted in light mode.
    final containerColor = c.isLight
        ? const Color(0x4DFFFFFF) // white @ 0.3
        : const Color(0x26000000); // black @ 0.15

    if (messages.isEmpty && polls.isEmpty) {
      // PWA shows the shimmer skeleton FIRST while the conversation loads, then
      // settles an empty channel/PM into the "No recent messages" note after a
      // grace period (`messages.js:_showMessageSkeleton` → `_appendEmptyNote`,
      // `.msg-skeleton` / `.msg-empty-note`). An arriving message clears the
      // empty branch entirely (this widget no longer renders). The typing row
      // still animates in below for an empty PM/group where the peer is typing.
      return ColoredBox(
        color: containerColor,
        child: Column(
          children: [
            Expanded(
              // Keyed on the active view so re-entering a conversation re-runs
              // the shimmer-then-settle grace period.
              child: _EmptyOrLoading(
                key: ValueKey(app.view),
                useBubbles: settings.useBubbles,
                emptyNote: _emptyNoteText(app),
              ),
            ),
            const TypingIndicatorRow(),
          ],
        ),
      );
    }

    final mentionToken = '@${_baseNym(app.selfNym)}';

    // Merge messages + polls into one chronological list (oldest first), each
    // message carrying its resolved reactions + mention flag. The fast probe
    // mirrors the PWA gates: `.mentioned` never applies to self or PM/group
    // rows (else-if class chain, messages.js:686-692), and `isMentioned`
    // bails while the self nym is unknown (messages.js:400) — a bare '@'
    // token at boot must not flag every '@'-containing message.
    final merged = <_ListEntry>[
      for (final m in messages)
        _MsgEntry(MessageGroupEntry(
          message: m,
          reactions: reactions[m.id] ?? const [],
          mentioned: mentionToken.length > 1 &&
              !m.isOwn &&
              !m.isPM &&
              m.content.contains(mentionToken),
        )),
      for (final p in polls) _PollEntry(p),
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // Fold consecutive same-author bubble messages into render groups (the PWA's
    // `.message-group`), so the group's single avatar can span and glide over the
    // whole run. The fold runs over the MERGED order, so an interleaved poll — or
    // a system / `/me` row — correctly breaks a same-author run (PWA
    // `_rewrapBubbleGroups` resets the current group on any non-message or poll).
    // Polls render standalone; in IRC mode `_groupsWith` is gated off so every
    // message is its own (bare) group.
    final units = <_RenderUnit>[];
    for (final e in merged) {
      if (e is _PollEntry) {
        units.add(_PollUnit(e.poll));
        continue;
      }
      final entry = (e as _MsgEntry).entry;
      final last = units.isNotEmpty ? units.last : null;
      if (settings.useBubbles &&
          last is _GroupUnit &&
          _groupsWith(last.entries.last.message, entry.message)) {
        last.entries.add(entry);
      } else {
        units.add(_GroupUnit([entry]));
      }
    }

    // Publish a message-id → reversed-render-index map so the blockquote tap can
    // jump to a quoted source message (`ScrollablePositionedList.scrollTo`). The
    // reversed list uses index 0 = newest at the bottom, so a unit at forward
    // position `f` lives at reversed index `units.length - 1 - f`; every message
    // inside a group maps to that same unit index.
    final indexById = <String, int>{};
    for (var f = 0; f < units.length; f++) {
      final unit = units[f];
      if (unit is _GroupUnit) {
        final revIndex = units.length - 1 - f;
        for (final entry in unit.entries) {
          indexById[entry.message.id] = revIndex;
        }
      }
    }
    ref.read(messageListScrollerProvider).bind(_itemScrollController, indexById);

    // Reversed list: index 0 = newest at the bottom; the typing row is pinned
    // below the newest message, above the composer (`.typing-indicator`).
    // ScrollablePositionedList (vs a plain ListView) is what lets the quote tap
    // land on an OFF-SCREEN, lazily-built message via `scrollTo(index:…)`.
    // Swipe/drag-scroll the messages to dismiss the soft keyboard (01-B3): the
    // ScrollablePositionedList has no `keyboardDismissBehavior`, so unfocus on an
    // active user-drag while the keyboard is up (chat_pane handles tap-out).
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: _dismissKeyboardOnDrag,
      child: ColoredBox(
      color: containerColor,
      child: Column(
        children: [
          Expanded(
            // A Stack so the scroll-to-bottom FAB (`.scroll-to-bottom-btn`) can
            // float over the conversation, mirroring the PWA's always-present
            // single-view jump-to-latest control (`styles-chat.css:9-43`).
            // The LayoutBuilder captures the viewport height that
            // [_onPositionsChanged] needs to turn the normalized item edges
            // into the PWA's 150px distance-from-bottom gate.
            child: LayoutBuilder(builder: (context, constraints) {
              _viewportHeight = constraints.maxHeight;
              return Stack(
              children: [
                Positioned.fill(
                  child: ScrollablePositionedList.builder(
                    itemScrollController: _itemScrollController,
                    itemPositionsListener: _positionsListener,
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    // Channel views carry one extra unit ABOVE the oldest
                    // message: the `.channel-history-limit` pill ("You've
                    // reached the edge of this channel's history."), which the
                    // PWA prepends once back-paging reaches the start of stored
                    // history (`loadOlderChannelMessages`, messages.js:
                    // 3175-3180). Here the whole stored history is rendered, so
                    // the lazily-built top item IS that boundary — it only
                    // appears once the user scrolls back to it. PM/group views
                    // have no such notice (`loadOlderPMMessages` never adds
                    // one).
                    itemCount: units.length + (isChannel ? 1 : 0),
                    itemBuilder: (context, revIndex) {
                      if (revIndex == units.length) {
                        return _ChannelHistoryEdgeNotice(
                            textSize: settings.textSize.toDouble());
                      }
                      final forward = units.length - 1 - revIndex;
                      final unit = units[forward];
                      final Widget child;
                      if (unit is _PollUnit) {
                        child = PollCard(poll: unit.poll, settings: settings);
                      } else {
                        child = MessageGroup(
                          entries: (unit as _GroupUnit).entries,
                          settings: settings,
                          onReactionPicker: (msg) =>
                              showReactionPicker(context, ref, msg),
                        );
                      }
                      // `.messages-list { gap: 3px }` (styles-chat.css:1-7):
                      // a 3px flex gap between EVERY adjacent pair of list
                      // children (rows, group wrappers, pills, polls), on top
                      // of each row's own padding/margins. Driven from the top
                      // edge; the list's very first child (the oldest unit, or
                      // the history notice above it) opens no gap.
                      return Padding(
                        padding: EdgeInsets.only(
                            top: (forward > 0 || isChannel) ? 3 : 0),
                        child: child,
                      );
                    },
                  ),
                ),
                // `.scroll-to-bottom-btn`: 40×40 FAB, right:24, shown >150px from
                // the bottom (`app.js:7120`, `styles-chat.css:9-43`). The PWA's
                // `bottom:90` is measured from a container that spans BEHIND the
                // input, so it lands just above the composer. Here the button
                // lives in the messages Stack, which already ENDS at the composer
                // top, so it only needs a small inset to sit just above it (16,
                // same as the columns view) — `bottom:90` floated it ~90px too
                // high.
                if (_showScrollButton)
                  Positioned(
                    right: 24,
                    bottom: 16,
                    child: _ScrollToBottomButton(onTap: _scrollToBottom),
                  ),
              ],
              );
            }),
          ),
          const TypingIndicatorRow(),
        ],
      ),
      ),
    );
  }

  /// Swipe/drag-scroll the messages dismisses the soft keyboard (01-B3): unfocus
  /// on an active user drag while the keyboard is open (the PWA dismisses on
  /// scroll). Returns false so the scroll notification keeps bubbling.
  bool _dismissKeyboardOnDrag(ScrollUpdateNotification n) {
    if (n.dragDetails != null &&
        MediaQuery.of(context).viewInsets.bottom > 0) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    return false;
  }

  /// Whether [cur] bubble-groups onto [prev]: same author within the 5-minute
  /// window, neither a system pill nor a `/me` action. (Polls are filtered out
  /// before this is reached, so they never merge.)
  bool _groupsWith(Message prev, Message cur) =>
      !prev.isSystemRow &&
      !cur.isSystemRow &&
      !prev.isMeAction &&
      !cur.isMeAction &&
      prev.pubkey == cur.pubkey &&
      (cur.createdAt - prev.createdAt).abs() <= _groupWindowSec;

  String _baseNym(String nym) => splitNymSuffix(nym).base;

  /// The empty-state note text (`_appendEmptyNote`): "No recent messages in
  /// #channel" for a channel view (`messages.js:2840`), else the bare
  /// "No recent messages" (`messages.js:3069`). Mirrors `_titleFor`'s channel
  /// lookup (`chat_pane.dart:955-962`) and `columns_deck._emptyNoteText`.
  String _emptyNoteText(AppState app) {
    final view = app.view;
    if (view.kind == ViewKind.channel) {
      final ch = app.channels.firstWhere(
        (c) => c.key == view.id,
        orElse: () => ChannelEntry(channel: view.id),
      );
      return 'No recent messages in #${ch.isGeohash ? ch.geohash : ch.channel}';
    }
    return 'No recent messages';
  }
}

/// The empty-conversation surface: the shimmer [MessageSkeleton] while history
/// is plausibly still loading, settling into the centered "No recent messages"
/// note after a grace period — a 1:1 port of the PWA's `_showMessageSkeleton`
/// (shimmer) → `_appendEmptyNote` (note) flow with the same ~3s settle timer
/// (`messages.js:3030`, `this._msgSkeletonSettleMs || 3000`). Recreated (via a
/// view-keyed instance in [MessagesList]) each time an empty conversation is
/// opened, so the shimmer plays on every entry. Once a message arrives the
/// empty branch stops rendering, which removes this widget — matching the PWA
/// where an incoming message clears the skeleton/note immediately.
class _EmptyOrLoading extends StatefulWidget {
  const _EmptyOrLoading({
    super.key,
    required this.useBubbles,
    required this.emptyNote,
  });

  final bool useBubbles;

  /// The settled-state note text — "No recent messages in #channel" for a
  /// channel view, else the bare "No recent messages" (`_appendEmptyNote`).
  final String emptyNote;

  @override
  State<_EmptyOrLoading> createState() => _EmptyOrLoadingState();
}

class _EmptyOrLoadingState extends State<_EmptyOrLoading> {
  // `this._msgSkeletonSettleMs || 3000`.
  static const _settle = Duration(seconds: 3);

  Timer? _timer;
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_settle, () {
      if (mounted) setState(() => _settled = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_settled) {
      return MessageSkeleton(useBubbles: widget.useBubbles);
    }
    final c = context.nym;
    // `.msg-empty-note`: text-dim, 13px, centered, padding 24/16
    // (`styles-chat.css:2045-2051`).
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Text(
          widget.emptyNote,
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textDim, fontSize: 13),
        ),
      ),
    );
  }
}

/// The `.system-message.channel-history-limit` pill (`styles-chat.css:
/// 1349-1355` on the `.system-message` base at `:1334-1348`): a centered
/// fit-content pill marking the start of stored channel history — "You've
/// reached the edge of this channel's history." Softer chrome than a normal
/// system pill (border white@0.05, bg white@0.02 — same literals in both
/// themes; no light override exists), padding 12px 20px, radius 20, margin
/// 10px auto, italic `--text-dim` at `textSize − 3`, weight 450.
class _ChannelHistoryEdgeNotice extends StatelessWidget {
  const _ChannelHistoryEdgeNotice({required this.textSize});

  /// The user text-size setting (`--user-text-size`); the pill renders 3px
  /// smaller (`font-size: calc(var(--user-text-size) - 3px)`).
  final double textSize;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      // `.system-message { margin: 10px auto }`.
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          // `.channel-history-limit { padding: 12px 20px }` (overrides the
          // base pill's 8px 16px).
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.02),
            border:
                Border.all(color: Colors.white.withValues(alpha: 0.05)),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
          ),
          child: Text(
            "You've reached the edge of this channel's history.",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c.textDim,
              fontSize: textSize - 3,
              fontStyle: FontStyle.italic,
              // `.system-message { font-weight: 450 }` (w500 nearest).
              fontWeight: FontWeight.w500,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}

/// A merged conversation entry, used only to interleave messages + polls in
/// chronological order before folding into render units.
sealed class _ListEntry {
  int get createdAt;
}

class _MsgEntry extends _ListEntry {
  _MsgEntry(this.entry);
  final MessageGroupEntry entry;
  @override
  int get createdAt => entry.message.createdAt;
}

class _PollEntry extends _ListEntry {
  _PollEntry(this.poll);
  final Poll poll;
  @override
  int get createdAt => poll.createdAt;
}

/// A render unit in the reversed list: either a standalone poll card or a
/// same-author [MessageGroup] (one or more messages sharing a sticky avatar).
sealed class _RenderUnit {}

class _PollUnit extends _RenderUnit {
  _PollUnit(this.poll);
  final Poll poll;
}

class _GroupUnit extends _RenderUnit {
  _GroupUnit(this.entries);
  final List<MessageGroupEntry> entries;
}

/// `.scroll-to-bottom-btn` (`styles-chat.css:9-43`): a 40×40 round glass FAB
/// with a primary down-chevron, hover glow + scale 1.1 (`:34-39`). A single-view
/// analogue of the columns deck's `_ScrollBottomButton`, but 40px (vs 36) and —
/// unlike the columns copy — it carries the light-mode style
/// (`styles-themes-responsive.css:607-615`): rest fill white@0.85 / border
/// primary@0.2 / shadow `0 2px 12px black@0.15`. Dark hover: primary@0.15 fill,
/// primary@0.30 border, `0 0 15px primary@0.15` glow; light hover only lifts
/// the fill to primary@0.10 (the light rest rule outranks the dark `:hover`).
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
    // Rest fill/border flip in light mode (the columns copy omits this).
    // Light-mode CASCADE: `body.light-mode .scroll-to-bottom-btn` (0,2,1)
    // outranks the dark `.scroll-to-bottom-btn:hover` (0,2,0), so on light
    // hover ONLY the background changes — to primary@0.10 via the (0,3,1)
    // `body.light-mode .scroll-to-bottom-btn:hover` — while the border stays
    // primary@0.2 and the shadow stays `0 2px 12px black@0.15`
    // (styles-themes-responsive.css:607-615). Dark hover takes the full
    // `:hover` set: primary@0.15 fill, primary@0.3 border, and the shadow
    // swaps to a `0 0 15px primary@0.15` glow (styles-chat.css:34-39).
    //
    // solid-ui pins the FILL to the opaque `--glass-bg` in both themes AND
    // through hover: `body.solid-ui[.light-mode] .scroll-to-bottom-btn
    // { background: var(--glass-bg) }` (styles-themes-responsive.css:
    // 1582/1609) outranks the dark `:hover` (0,2,1 > 0,2,0) and, declared
    // later in the same sheet, the equal-specificity light rest/hover rules —
    // only the border/shadow/scale hover effects remain.
    final fill = c.solidUi
        ? c.glassBg
        : _hover
            ? (light ? c.primaryA(0.10) : c.primaryA(0.15))
            : (light ? const Color(0xD9FFFFFF) /* white @ 0.85 */ : c.glassBg);
    final border = light
        ? c.primaryA(0.20)
        : (_hover ? c.primaryA(0.30) : c.glassBorder);
    // shadow-md (dark rest) → hover glow (dark); light `0 2px 12px black@0.15`.
    final shadow = light
        ? const BoxShadow(
            color: Color(0x26000000), // black @ 0.15
            offset: Offset(0, 2),
            blurRadius: 12,
          )
        : _hover
            ? BoxShadow(color: c.primaryA(0.15), blurRadius: 15)
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

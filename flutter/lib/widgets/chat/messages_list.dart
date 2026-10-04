import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/chat_nav/chat_nav.dart';
import '../../features/chat_nav/chat_nav_ui.dart';
import '../../features/i18n/i18n.dart';
import '../../features/polls/poll_card.dart';
import '../../features/reactions/reaction_picker.dart';
import '../../models/channel.dart';
import '../../models/message.dart';
import '../../models/settings.dart';
import '../../models/poll.dart';
import '../../features/mesh/mesh_diagnostics.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../nym_icons.dart';
import 'list_anchor.dart';
import 'message_row.dart';
import 'message_skeleton.dart';
import 'typing_indicator.dart';

/// Jump-to-message handle for a message list, wrapping [ItemScrollController] and a live id-to-index map.
class MessageListScroller {
  ItemScrollController? _controller;

  Map<String, int> _indexById = const {};

  /// Held by message id, since indexes move as messages arrive, so leaving a thread restores the old position.
  ({String id, double alignment})? _anchor;

  void bind(ItemScrollController controller, Map<String, int> indexById) {
    _controller = controller;
    _indexById = indexById;
  }

  void rememberAnchor(String messageId, double alignment) {
    _anchor = (id: messageId, alignment: alignment);
  }

  /// Consumed as read: a restore happens once, on the remount the thread caused.
  ({int index, double alignment})? takeAnchor() {
    final anchor = _anchor;
    _anchor = null;
    if (anchor == null) return null;
    final index = _indexById[anchor.id];
    if (index == null) return null;
    return (index: index, alignment: anchor.alignment);
  }

  /// A view switch is not a thread round trip, so the remembered anchor is stale.
  void forgetAnchor() => _anchor = null;

  bool canScrollTo(String messageId) =>
      _indexById.containsKey(messageId) && (_controller?.isAttached ?? false);

  int _scrollCount = 0;
  int _inFlight = 0;

  int get scrollCount => _scrollCount;

  bool get animating => _inFlight > 0;

  Future<void> animateTo({
    required int index,
    double alignment = 0,
    Duration duration = NymMotion.transition,
    Curve curve = NymMotion.curve,
  }) {
    final controller = _controller;
    if (controller == null || !controller.isAttached) return Future.value();
    _scrollCount++;
    _inFlight++;
    return controller
        .scrollTo(
            index: index,
            alignment: alignment,
            duration: duration,
            curve: curve)
        .whenComplete(() => _inFlight--);
  }

  /// Scrolls [messageId] near center; returns false when it isn't loaded or the list isn't attached.
  bool scrollToMessage(String messageId) {
    final index = _indexById[messageId];
    final controller = _controller;
    if (index == null || controller == null || !controller.isAttached) {
      return false;
    }
    animateTo(
      index: index,
      // About 0.4 lands the message a little above center, like `scrollIntoView({block:'center'})`.
      alignment: 0.4,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    return true;
  }
}

/// Scroller per conversation `storageKey`, so a quote tap jumps the list (or deck column) it lives in.
final messageListScrollerProvider =
    Provider.family<MessageListScroller, String>(
        (ref, storageKey) => MessageListScroller());

/// The reversed, lazily built message list; bubble mode groups same-author messages within 5 minutes.
class MessagesList extends ConsumerStatefulWidget {
  const MessagesList({super.key});

  @override
  ConsumerState<MessagesList> createState() => _MessagesListState();
}

class _MessagesListState extends ConsumerState<MessagesList> {
  static const int _groupWindowSec = 300;

  final ItemScrollController _itemScrollController = ItemScrollController();

  /// Reports visible positions for the scroll-to-bottom FAB's 150px gate; index 0 is the newest message.
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();

  bool _showScrollButton = false;

  late final ChatNavListBinding _nav =
      ChatNavListBinding(ref, _positionsListener, inset: _bottomInset);
  String? _navBreak;

  /// Taken once from the scroller on the first build after a thread handed the list back.
  ({int index, double alignment})? _restore;
  bool _restoreDone = false;

  /// Converts normalized [ItemPosition] edges into pixel distances.
  double _viewportHeight = 0;

  /// Unit widgets reused verbatim when inputs are unchanged (by identity), so list rebuilds skip their subtrees.
  final Map<Key, _CachedUnitWidget> _unitWidgetCache = {};

  String? _unitCacheViewKey;

  final AnchoredUnits _anchors = AnchoredUnits();
  late final ListAnchorKeeper _keeper =
      ListAnchorKeeper(controller: _itemScrollController, units: _anchors);
  Map<int, String> _unitByIndex = const {};
  _UnitsBuild? _units;
  int _seenScrolls = 0;
  bool _listBuilt = false;

  bool _sameEntries(List<MessageGroupEntry> a, List<MessageGroupEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i].message, b[i].message) ||
          !identical(a[i].reactions, b[i].reactions) ||
          a[i].mentioned != b[i].mentioned) {
        return false;
      }
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    _positionsListener.itemPositions.addListener(_onPositionsChanged);
  }

  /// Ensures the id-to-index map used to save an anchor belongs to the anchor's view.
  String _viewKey = '';

  Map<int, String> _idByIndex = const {};

  @override
  void deactivate() {
    _saveAnchorIfThreadTookOver();
    super.deactivate();
  }

  @override
  void dispose() {
    _positionsListener.itemPositions.removeListener(_onPositionsChanged);
    _nav.dispose();
    super.dispose();
  }

  /// Only a thread replacing this list saves an anchor; other unmounts do not.
  void _saveAnchorIfThreadTookOver() {
    try {
      final thread = ref.read(activeThreadProvider);
      final scroller = ref.read(messageListScrollerProvider(_viewKey));
      if (thread == null || _viewKey.isEmpty) {
        scroller.forgetAnchor();
        return;
      }
      final positions = _positionsListener.itemPositions.value;
      if (positions.isEmpty) return;
      // The item nearest the viewport bottom (leading edge in a reversed list) is what gets restored.
      ItemPosition? nearest;
      for (final p in positions) {
        if (nearest == null || p.itemLeadingEdge < nearest.itemLeadingEdge) {
          nearest = p;
        }
      }
      final id = nearest == null ? null : _idByIndex[nearest.index];
      if (id == null) return;
      // Already at the newest message: nothing to restore, and pinning would fight the autoscroll.
      if (nearest!.index == 0 && nearest.itemLeadingEdge >= -0.01) return;
      final unit = _unitByIndex[nearest.index];
      var alignment = (unit == null ? null : _anchors.edgeOf(unit)) ??
          nearest.itemLeadingEdge;
      if (nearest.index == 0 && _viewportHeight > 0) {
        alignment -= _bottomInset / _viewportHeight;
      }
      scroller.rememberAnchor(id, alignment);
    } catch (_) {}
  }

  static const double _bottomInset = 16;

  void _keepAnchor() {
    if (!mounted ||
        !_listBuilt ||
        !_itemScrollController.isAttached ||
        _viewportHeight <= 0) {
      return;
    }
    final app = ref.read(appStateProvider);
    if (app.view.storageKey != _viewKey) return;
    final scroller = ref.read(messageListScrollerProvider(_viewKey));
    if (scroller.scrollCount != _seenScrolls) {
      _seenScrolls = scroller.scrollCount;
      _keeper.reset();
    }
    if (scroller.animating) return;
    final settings = ref.read(settingsProvider);
    final built = _unitsFor(
      ref.read(messagesForCurrentViewProvider),
      ref.read(pollsForCurrentViewProvider),
      ref.read(reactionsProvider),
      settings.useBubbles,
      '@${_baseNym(app.selfNym)}',
      _navBreak,
    );
    final positions = _positionsListener.itemPositions.value;
    ItemPosition? newest;
    for (final p in positions) {
      if (p.index == 0) {
        newest = p;
        break;
      }
    }
    final follow = newest != null &&
        _bottomInset - newest.itemLeadingEdge * _viewportHeight <= 150;
    final oldUnits = _unitByIndex;
    _keeper.keep(
      positions: positions,
      unitAt: (index) => oldUnits[index],
      indexOf: (unit) => built.indexByUnit[unit],
      viewportHeight: _viewportHeight,
      bottomInset: _bottomInset,
      follow: follow,
    );
  }

  _UnitsBuild _unitsFor(
    List<Message> messages,
    List<Poll> polls,
    Map<String, List<MessageReaction>> reactions,
    bool useBubbles,
    String mentionToken, [
    String? breakBefore,
  ]) {
    final cached = _units;
    if (cached != null &&
        identical(cached.messages, messages) &&
        identical(cached.polls, polls) &&
        identical(cached.reactions, reactions) &&
        cached.useBubbles == useBubbles &&
        cached.mentionToken == mentionToken &&
        cached.breakBefore == breakBefore) {
      return cached;
    }

    // Mention flags never apply to self or PM/group rows, nor while the self nym is still unknown.
    final raw = <_ListEntry>[
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
    ];
    final order = List<int>.generate(raw.length, (i) => i)
      ..sort((a, b) {
        final d = raw[a].createdAt.compareTo(raw[b].createdAt);
        return d != 0 ? d : a - b;
      });
    final merged = [for (final i in order) raw[i]];

    // Fold same-author bubble runs in merged order, so polls and system or `/me` rows break a run.
    final units = <_RenderUnit>[];
    for (final e in merged) {
      if (e is _PollEntry) {
        units.add(_PollUnit(e.poll));
        continue;
      }
      final entry = (e as _MsgEntry).entry;
      final last = units.isNotEmpty ? units.last : null;
      if (useBubbles &&
          last is _GroupUnit &&
          entry.message.id != breakBefore &&
          _groupsWith(last.entries.last.message, entry.message)) {
        last.entries.add(entry);
      } else {
        units.add(_GroupUnit([entry]));
      }
    }

    // A unit at forward position `f` has reversed index `units.length - 1 - f`; every message in a group maps to it.
    final indexById = <String, int>{};
    final indexByUnit = <String, int>{};
    final unitByIndex = <int, String>{};
    for (var f = 0; f < units.length; f++) {
      final unit = units[f];
      final revIndex = units.length - 1 - f;
      final String unitId;
      if (unit is _GroupUnit) {
        for (final entry in unit.entries) {
          indexById[entry.message.id] = revIndex;
        }
        unitId = 'group_${unit.entries.first.message.id}';
      } else {
        unitId = 'poll_${(unit as _PollUnit).poll.id}';
      }
      indexByUnit[unitId] = revIndex;
      unitByIndex[revIndex] = unitId;
    }
    return _units = _UnitsBuild(
      messages: messages,
      polls: polls,
      reactions: reactions,
      useBubbles: useBubbles,
      mentionToken: mentionToken,
      breakBefore: breakBefore,
      units: units,
      indexById: indexById,
      indexByUnit: indexByUnit,
      unitByIndex: unitByIndex,
    );
  }

  /// Shows the FAB beyond 150px from the bottom; offset 0 rests index 0's edge 16px inside the viewport.
  void _onPositionsChanged() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    _nav.update();
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

  void _scrollToBottom() {
    if (!_itemScrollController.isAttached) return;
    ref
        .read(messageListScrollerProvider(_viewKey))
        .animateTo(index: 0, alignment: 0);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    // Watch only the rendered slices, not the whole AppState, which emits on every ambient change.
    final view = ref.watch(appStateProvider.select((s) => s.view));
    final selfNym = ref.watch(appStateProvider.select((s) => s.selfNym));
    final messages = ref.watch(messagesForCurrentViewProvider);
    final reactions = ref.watch(reactionsProvider);
    final polls = ref.watch(pollsForCurrentViewProvider);
    ref.listen(messagesForCurrentViewProvider, (_, _) => _keepAnchor());
    ref.listen(pollsForCurrentViewProvider, (_, _) => _keepAnchor());

    // Different views share no keys, so keeping the cache across a switch would only leak.
    if (_unitCacheViewKey != view.storageKey) {
      _unitCacheViewKey = view.storageKey;
      _unitWidgetCache.clear();
    }

    // The history-edge notice is channel-only.
    final isChannel = view.kind == ViewKind.channel;

    final containerColor = c.isLight
        ? const Color(0x4DFFFFFF)
        : const Color(0x26000000);

    if (messages.isEmpty && polls.isEmpty) {
      _listBuilt = false;
      // Diagnostic: log what the widget sees for mesh-relevant empty views.
      final key = view.storageKey;
      if (key.startsWith('#') || key.startsWith('pm-')) {
        final rawCount = ref.read(appStateProvider).messages[key]?.length ?? 0;
        MeshDiagnostics.instance
            .log('RENDER empty view=$key widgetStore=$rawCount visible=0 '
                'rev=${ref.read(appStateProvider).displayRev}');
      }
      // Shimmer skeleton first, settling into the empty note after a grace period.
      return ColoredBox(
        color: containerColor,
        child: Column(
          children: [
            Expanded(
              // Keyed on the view so re-entering reruns the shimmer-then-settle grace period.
              child: _EmptyOrLoading(
                key: ValueKey(view),
                useBubbles: settings.useBubbles,
                // A read suffices: an arriving message bumps the display revision and re-renders this branch.
                emptyNote: _emptyNoteText(ref.read(appStateProvider)),
              ),
            ),
            const TypingIndicatorRow(),
          ],
        ),
      );
    }

    _navBreak = _nav.prepare(view.storageKey, messages);
    final built = _unitsFor(messages, polls, reactions, settings.useBubbles,
        '@${_baseNym(selfNym)}', _navBreak);
    final units = built.units;
    final indexById = built.indexById;
    _nav.bind(indexById, units.length - 1);
    _nav.observeLive(messages,
        away: _showScrollButton ||
            !ref.read(appStateProvider.notifier).appVisible);
    final scroller = ref.read(messageListScrollerProvider(view.storageKey));
    scroller.bind(_itemScrollController, indexById);
    _idByIndex = {for (final e in indexById.entries) e.value: e.key};
    _unitByIndex = built.unitByIndex;
    if (!_restoreDone) {
      // initialScrollIndex is read only on the first layout.
      _restore = scroller.takeAnchor();
      _restoreDone = true;
    } else if (_viewKey != view.storageKey) {
      // Switched conversation without remounting, so the remembered anchor is stale.
      scroller.forgetAnchor();
      _keeper.reset();
    }
    _viewKey = view.storageKey;
    final restore = _restore;
    if (!_listBuilt) {
      _listBuilt = true;
      _seenScrolls = scroller.scrollCount;
      _keeper.reset(
        target: restore?.index ?? 0,
        anchorUnit: restore == null ? null : built.unitByIndex[restore.index],
      );
    }
    _restore = null;
    _nav.afterBuild(scroller);

    // ScrollablePositionedList can reach off-screen lazy items; it lacks keyboardDismissBehavior, so unfocus on drag.
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ColoredBox(
        color: containerColor,
        child: Column(
          children: [
            Expanded(
              // LayoutBuilder captures the viewport height [_onPositionsChanged] needs.
              child: LayoutBuilder(builder: (context, constraints) {
                _viewportHeight = constraints.maxHeight;
                _nav.viewport = constraints.maxHeight;
                return Stack(
                  children: [
                    Positioned.fill(
                      child: ScrollablePositionedList.builder(
                        itemScrollController: _itemScrollController,
                        itemPositionsListener: _positionsListener,
                        reverse: true,
                        initialScrollIndex: restore?.index ?? 0,
                        initialAlignment: restore?.alignment ?? 0,
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                        // Channels get one extra top unit, the history-edge notice, shown once the user scrolls back to it.
                        itemCount: units.length + (isChannel ? 1 : 0),
                        itemBuilder: (context, revIndex) {
                          if (revIndex == units.length) {
                            return _ChannelHistoryEdgeNotice(
                                textSize: settings.textSize.toDouble());
                          }
                          final forward = units.length - 1 - revIndex;
                          final unit = units[forward];
                          final Widget child;
                          // Key by the group's lead message id so appends don't reparent rows and restart their snap-in animation.
                          final unitId = built.unitByIndex[revIndex]!;
                          final Key unitKey = ValueKey(unitId);
                          if (unit is _PollUnit) {
                            child =
                                PollCard(poll: unit.poll, settings: settings);
                          } else {
                            final group = unit as _GroupUnit;
                            // Reuse the cached widget when inputs are unchanged; the picker captures the State's stable context.
                            final cached = _unitWidgetCache[unitKey];
                            if (cached != null &&
                                identical(cached.settings, settings) &&
                                _sameEntries(cached.entries, group.entries)) {
                              child = cached.widget;
                            } else {
                              child = MessageGroup(
                                entries: group.entries,
                                settings: settings,
                                onReactionPicker: (msg) => showReactionPicker(
                                    this.context, ref, msg),
                              );
                              _unitWidgetCache[unitKey] = _CachedUnitWidget(
                                  group.entries, settings, child);
                            }
                          }
                          final Widget body = unit is _GroupUnit &&
                                  _navBreak != null &&
                                  unit.entries.first.message.id == _navBreak
                              ? Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [const ChatNavDivider(), child],
                                )
                              : child;
                          // 3px list gap from the top edge; RepaintBoundary keeps each row's repaints from re-rasterizing the whole list.
                          return RepaintBoundary(
                            key: unitKey,
                            child: Padding(
                              padding: EdgeInsets.only(
                                  top: (forward > 0 || isChannel) ? 3 : 0),
                              child: AnchoredUnit(
                                id: unitId,
                                units: _anchors,
                                child: body,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Positioned(
                      left: ChatFabs.rightPhone,
                      right: fabRight(MediaQuery.sizeOf(context).width, false),
                      bottom: 16,
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: ChatNavFabs(
                          binding: _nav,
                          slot: _fabSlot(context),
                          bottom: _showScrollButton
                              ? _ScrollToBottomButton(
                                  size: _fabSlot(context),
                                  onTap: _scrollToBottom)
                              : null,
                        ),
                      ),
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

  /// Returns false so the scroll notification keeps bubbling.
  bool _dismissKeyboardOnDrag(ScrollUpdateNotification n) {
    if (n.dragDetails != null && MediaQuery.of(context).viewInsets.bottom > 0) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    return false;
  }

  bool _onScroll(ScrollNotification n) {
    _keeper.observe(n);
    if ((n is ScrollUpdateNotification && n.dragDetails != null) ||
        n is UserScrollNotification) {
      _nav.userScrolled();
    }
    if (n is ScrollUpdateNotification) _dismissKeyboardOnDrag(n);
    if (n is ScrollEndNotification && _keeper.pending && !_keeper.retargeting) {
      _keeper.pending = false;
      _keepAnchor();
    }
    return false;
  }

  /// Polls are filtered out earlier, so they never merge.
  bool _groupsWith(Message prev, Message cur) =>
      !prev.isSystemRow &&
      !cur.isSystemRow &&
      !prev.isMeAction &&
      !cur.isMeAction &&
      prev.pubkey == cur.pubkey &&
      (cur.createdAt - prev.createdAt).abs() <= _groupWindowSec;

  String _baseNym(String nym) => splitNymSuffix(nym).base;

  String _emptyNoteText(AppState app) {
    final view = app.view;
    if (view.kind == ViewKind.channel) {
      final ch = app.channels.firstWhere(
        (c) => c.key == view.id,
        orElse: () => ChannelEntry(channel: view.id),
      );
      return tr('No recent messages in #{channel}',
          {'channel': ch.isGeohash ? ch.geohashKey : ch.channel});
    }
    return tr('No recent messages');
  }
}

/// Shimmer skeleton while history may still load, settling to the empty note after about 3s, like the PWA.
class _EmptyOrLoading extends StatefulWidget {
  const _EmptyOrLoading({
    super.key,
    required this.useBubbles,
    required this.emptyNote,
  });

  final bool useBubbles;

  final String emptyNote;

  @override
  State<_EmptyOrLoading> createState() => _EmptyOrLoadingState();
}

class _EmptyOrLoadingState extends State<_EmptyOrLoading> {
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

/// The pill marking the start of stored channel history.
class _ChannelHistoryEdgeNotice extends StatelessWidget {
  const _ChannelHistoryEdgeNotice({required this.textSize});

  final double textSize;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.02),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
          ),
          child: Text(
            tr("You've reached the edge of this channel's history."),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c.textDim,
              fontSize: textSize - 3,
              fontStyle: FontStyle.italic,
              // CSS weight 450; w500 is nearest.
              fontWeight: FontWeight.w500,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}

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

sealed class _RenderUnit {}

class _PollUnit extends _RenderUnit {
  _PollUnit(this.poll);
  final Poll poll;
}

class _GroupUnit extends _RenderUnit {
  _GroupUnit(this.entries);
  final List<MessageGroupEntry> entries;
}

class _CachedUnitWidget {
  _CachedUnitWidget(this.entries, this.settings, this.widget);
  final List<MessageGroupEntry> entries;
  final Settings settings;
  final Widget widget;
}

class _UnitsBuild {
  _UnitsBuild({
    required this.messages,
    required this.polls,
    required this.reactions,
    required this.useBubbles,
    required this.mentionToken,
    this.breakBefore,
    required this.units,
    required this.indexById,
    required this.indexByUnit,
    required this.unitByIndex,
  });

  final List<Message> messages;
  final List<Poll> polls;
  final Map<String, List<MessageReaction>> reactions;
  final bool useBubbles;
  final String mentionToken;
  final String? breakBefore;
  final List<_RenderUnit> units;
  final Map<String, int> indexById;
  final Map<String, int> indexByUnit;
  final Map<int, String> unitByIndex;
}

double _fabSlot(BuildContext context) =>
    MediaQuery.sizeOf(context).width <= ChatFabs.phoneMax ? 36 : 40;

/// 40x40 scroll-to-bottom FAB; unlike the columns copy, it carries the light-mode style.
class _ScrollToBottomButton extends StatefulWidget {
  const _ScrollToBottomButton({required this.onTap, this.size = 40});
  final VoidCallback onTap;
  final double size;

  @override
  State<_ScrollToBottomButton> createState() => _ScrollToBottomButtonState();
}

class _ScrollToBottomButtonState extends State<_ScrollToBottomButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final light = c.isLight;
    // Light hover changes only the fill (CSS specificity); solid-ui pins the fill to `--glass-bg` through hover.
    final fill = c.solidUi
        ? c.glassBg
        : _hover
            ? (light ? c.primaryA(0.10) : c.primaryA(0.15))
            : (light ? const Color(0xD9FFFFFF) : c.glassBg);
    final border =
        light ? c.primaryA(0.20) : (_hover ? c.primaryA(0.30) : c.glassBorder);
    final shadow = light
        ? const BoxShadow(
            color: Color(0x26000000),
            offset: Offset(0, 2),
            blurRadius: 12,
          )
        : _hover
            ? BoxShadow(color: c.primaryA(0.15), blurRadius: 15)
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
            key: const ValueKey('chat-nav-bottom'),
            width: widget.size,
            height: widget.size,
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

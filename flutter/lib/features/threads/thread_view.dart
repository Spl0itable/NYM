import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../day_separators/day_separator.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../chat_tools/chat_tools_ui.dart' show ChatToolsReader;
import '../../widgets/chat/message_row.dart';
import '../../widgets/chat/message_selection.dart';
import '../../widgets/chat/typing_indicator.dart';
import '../../widgets/common/nym_label.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import '../nymbot/bot_runs_view.dart' show botRunTrailing;
import '../reactions/reaction_picker.dart';
import '../toasts/toast_center.dart';
import '../../widgets/chat/list_anchor.dart';
import '../../widgets/chat/messages_list.dart' show ScrollToBottomFab, chatFabSlot;
import '../../widgets/columns/columns_deck.dart' show ColumnScrollBottomFab;
import '../chat_nav/chat_nav.dart';
import '../chat_nav/chat_nav_providers.dart';
import '../chat_nav/chat_nav_ui.dart' show ChatFloatInset, ChatNavDivider, ChatNavFabRow;
import 'thread_nav.dart';

/// Focuses the conversation first so the shared composer targets it, then swaps the message area to [m]'s thread.
void openMessageThread(WidgetRef ref, Message m,
        {String? storageKey, bool silent = false}) =>
    openThreadFor(ref.read, m, storageKey: storageKey, silent: silent);

void openThreadFor(ChatToolsReader read, Message m,
    {String? storageKey, bool silent = false}) {
  if (!appThreadsEnabled) return;
  final app = read(appStateProvider);
  final key = storageKey ?? app.view.storageKey;
  var root = m;
  final rootRef = m.threadRoot;
  if (rootRef != null) {
    root = threadRootMessage(app, key, rootRef) ?? m;
  }
  if (!threadEligibleRoot(root)) {
    if (!silent) {
      showToast(tr(
          'This message cannot start a thread yet — try again once it has '
          'finished sending.'));
    }
    return;
  }
  final view = _viewForStorageKey(key) ?? app.view;
  if (view != app.view) {
    read(appStateProvider.notifier).switchView(view);
  }
  // Post-frame so it wins over listeners that clear the thread; use the captured notifier since this ref may be disposed.
  final target = ActiveThread(view: view, rootId: threadKeyForMessage(root));
  final activeThread = read(activeThreadProvider.notifier);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    activeThread.state = target;
  });
  activeThread.state = target;
}

ChatView? _viewForStorageKey(String key) {
  if (key.startsWith('#')) return ChatView.channel(key.substring(1));
  if (key.startsWith('pm-')) return ChatView.pm(key.substring(3));
  if (key.startsWith('group-')) return ChatView.group(key.substring(6));
  return null;
}

/// In-place thread view that replaces the message list while a thread is open, above the shared composer.
class ThreadView extends ConsumerStatefulWidget {
  const ThreadView({
    super.key,
    required this.thread,
    this.showTyping = true,
    this.columnsMode = false,
    this.onScreen,
    this.screenChanges,
  });
  final ActiveThread thread;

  /// False inside a columns deck, where the column hosts its own typing row.
  final bool showTyping;

  final bool columnsMode;

  final bool Function()? onScreen;

  final Listenable? screenChanges;

  @override
  ConsumerState<ThreadView> createState() => _ThreadViewState();
}

class _ThreadScroll extends ScrollController {
  bool pinned = false;

  void pinEnd() {
    pinned = true;
    if (hasClients) jumpTo(position.maxScrollExtent);
  }

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics,
          ScrollContext context, ScrollPosition? oldPosition) =>
      _ThreadPosition(
        owner: this,
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
        debugLabel: debugLabel,
      );
}

class _ThreadPosition extends ScrollPositionWithSingleContext {
  _ThreadPosition({
    required this.owner,
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final _ThreadScroll owner;
  int _pinPasses = 0;

  void _moved(double to) {
    if (owner.pinned &&
        hasContentDimensions &&
        (to - maxScrollExtent).abs() > 0.5) {
      owner.pinned = false;
    }
  }

  @override
  double setPixels(double newPixels) {
    final overscroll = super.setPixels(newPixels);
    _moved(pixels);
    return overscroll;
  }

  @override
  void forcePixels(double value) {
    _moved(value);
    super.forcePixels(value);
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    if (owner.pinned &&
        hasPixels &&
        _pinPasses < 6 &&
        (pixels - maxScrollExtent).abs() > 0.01) {
      _pinPasses++;
      correctPixels(maxScrollExtent);
      return false;
    }
    _pinPasses = 0;
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }

  @override
  bool correctForNewDimensions(
      ScrollMetrics oldPosition, ScrollMetrics newPosition) {
    final end = newPosition.maxScrollExtent;
    if (oldPosition.viewportDimension != newPosition.viewportDimension &&
        oldPosition.extentAfter < 1 &&
        (pixels - end).abs() > 0.01) {
      correctPixels(end);
      return false;
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
  }
}

class _ThreadViewState extends ConsumerState<ThreadView> {
  final _ThreadScroll _scroll = _ThreadScroll();
  final ReaderAway _reader = ReaderAway();
  int _lastReplyCount = -1;
  final ValueNotifier<int> _fabs = ValueNotifier(0);
  final ValueNotifier<bool> _showBottom = ValueNotifier(false);
  final GlobalKey _viewKey = GlobalKey();
  final GlobalKey _dividerKey = GlobalKey();
  final Map<String, GlobalKey> _groupKeys = {};
  List<List<MessageGroupEntry>> _replyGroups = const [];
  List<ChatNavRow> _rows = const [];
  Map<String, int> _rowIndex = const {};
  Set<String> _seenIds = const {};
  ThreadNavEntry? _entry;
  List<String> _unseen = const [];
  bool _down = true;
  bool _landing = false;
  bool _queued = false;
  bool _hold = false;
  bool _jumping = false;
  String? _chatLastId;
  int _chatLastAt = 0;

  ThreadNavStore get _store => ref.read(threadNavProvider);

  bool get _shown => widget.onScreen?.call() ?? true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_queue);
    widget.screenChanges?.addListener(_queue);
  }

  @override
  void didUpdateWidget(covariant ThreadView old) {
    super.didUpdateWidget(old);
    if (old.screenChanges != widget.screenChanges) {
      old.screenChanges?.removeListener(_queue);
      widget.screenChanges?.addListener(_queue);
    }
  }

  @override
  void dispose() {
    widget.screenChanges?.removeListener(_queue);
    _scroll.removeListener(_queue);
    _scroll.dispose();
    _fabs.dispose();
    _showBottom.dispose();
    super.dispose();
  }

  void _queue() {
    if (_queued || !mounted) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted) _track();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  List<ChatNavRow> _rowsOf(List<Message> replies) {
    final nav = ref.read(chatNavProvider);
    final self = ref.read(appStateProvider).selfPubkey;
    return [
      for (final m in replies)
        ChatNavRow(
          id: m.id,
          at: nav.effAt(m),
          own: m.isOwn || (m.pubkey.isNotEmpty && m.pubkey == self),
          sys: m.pubkey.isEmpty || m.isSystemRow,
          mention: nav.hooks.isMention?.call(m) ?? false,
        ),
    ];
  }

  Rect? _rectOf(GlobalKey? key) {
    final box = key?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  static double _weight(Message m) => 1 + m.content.length / 40;

  (double, double)? _sliceOf(String id) {
    for (final g in _replyGroups) {
      if (!g.any((x) => x.message.id == id)) continue;
      final r = _rectOf(_groupKeys[g.first.message.id]);
      if (r == null) return null;
      var total = 0.0;
      for (final x in g) {
        total += _weight(x.message);
      }
      var top = r.top;
      for (final x in g) {
        final bottom = top + r.height * _weight(x.message) / total;
        if (x.message.id == id) return (top, bottom);
        top = bottom;
      }
    }
    return null;
  }

  int _groupIndexOf(String id) {
    for (var i = 0; i < _replyGroups.length; i++) {
      if (_replyGroups[i].any((x) => x.message.id == id)) return i;
    }
    return -1;
  }

  (int, int) _builtRange() {
    var lo = -1;
    var hi = -1;
    for (var i = 0; i < _replyGroups.length; i++) {
      if (_rectOf(_groupKeys[_replyGroups[i].first.message.id]) == null) {
        continue;
      }
      if (lo < 0) lo = i;
      hi = i;
    }
    return (lo, hi);
  }

  double get _gap {
    if (!_scroll.hasClients) return 0;
    final p = _scroll.position;
    return p.maxScrollExtent - p.pixels;
  }

  void _track() {
    final e = _entry;
    if (e == null || !_scroll.hasClients || _landing) return;
    if (!_hold && ref.read(appStateProvider.notifier).appVisible) {
      final shown = _shown;
      if (atBottom(_gap)) {
        _store.seeAll(e, _rows, shown: shown);
      } else {
        final view = _rectOf(_viewKey);
        if (view != null) {
          num at = -1;
          var idx = -1;
          for (final g in _replyGroups) {
            final r = _rectOf(_groupKeys[g.first.message.id]);
            if (r == null || r.bottom <= view.top + 0.5 || r.top >= view.bottom - 0.5) {
              continue;
            }
            String? id;
            if (r.bottom <= view.bottom + 0.5) {
              id = g.last.message.id;
            } else {
              for (final x in g) {
                final s = _sliceOf(x.message.id);
                if (s == null || s.$2 > view.bottom + 0.5) break;
                id = x.message.id;
              }
            }
            final i = id == null ? null : _rowIndex[id];
            if (i == null) continue;
            final a = _rows[i].at;
            if (a > at || (a == at && i > idx)) {
              at = a;
              idx = i;
            }
          }
          if (idx >= 0) {
            final ids = <String>[];
            for (var j = idx;
                j >= 0 && ids.length < ChatJump.markMax && _rows[j].at >= at;
                j--) {
              if (_rows[j].at == at) ids.add(_rows[j].id);
            }
            _store.advance(e, at, ids);
            if (shown) _store.sweep(e);
          }
        }
      }
    }
    _refresh();
  }

  String _dirFor(String id) {
    final s = _sliceOf(id);
    final view = _rectOf(_viewKey);
    if (s != null && view != null) {
      return jumpDir(top: s.$1, viewTop: view.top);
    }
    final gi = _groupIndexOf(id);
    final (_, hi) = _builtRange();
    return hi < 0 || gi > hi ? 'down' : 'up';
  }

  void _refresh() {
    final e = _entry;
    if (e == null) return;
    _unseen = _store.unseen(e, _rows);
    final down = _unseen.isEmpty || _dirFor(_unseen.first) == 'down';
    _down = down;
    _fabs.value++;
    if (_scroll.hasClients) _showBottom.value = bottomShown(_gap, _showBottom.value);
  }

  Future<bool> _bring(String id, double Function(Rect view) want,
      {bool divider = false, bool animate = false}) async {
    final limit = 40 + _replyGroups.length;
    for (var guard = 0;
        guard < limit && mounted && _scroll.hasClients;
        guard++) {
      final view = _rectOf(_viewKey);
      if (view == null) return false;
      final pos = _scroll.position;
      final s = divider ? _rectOf(_dividerKey) : null;
      final slice = divider
          ? (s == null ? null : (s.top, s.bottom))
          : _sliceOf(id);
      if (slice == null) {
        final gi = _groupIndexOf(id);
        if (gi < 0) return false;
        final next = (pos.pixels + _stepToward(gi, view))
            .clamp(pos.minScrollExtent, pos.maxScrollExtent);
        if ((next - pos.pixels).abs() < 1) return false;
        _scroll.jumpTo(next);
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }
      final dest = (pos.pixels + slice.$1 - want(view))
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if ((dest - pos.pixels).abs() < 1) return true;
      if (animate) {
        animate = false;
        await _scroll.animateTo(dest,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut);
      } else {
        _scroll.jumpTo(dest);
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    return false;
  }

  double _stepToward(int gi, Rect view) {
    final page = view.height * 0.8;
    final (lo, hi) = _builtRange();
    if (lo < 0) return page;
    final down = gi > hi;
    final step = down ? page : -page;
    if (hi <= lo) return step;
    final a = _rectOf(_groupKeys[_replyGroups[lo].first.message.id]);
    final b = _rectOf(_groupKeys[_replyGroups[hi].first.message.id]);
    if (a == null || b == null) return step;
    final per = (b.top - a.top) / (hi - lo);
    if (!(per > 0)) return step;
    final target = down ? b.top + (gi - hi) * per : a.top - (lo - gi) * per;
    final d = target - view.top - view.height * 0.3;
    if (down ? d < 1 : d > -1) return step;
    return d;
  }

  Future<void> _land(ThreadNavEntry e, String id) async {
    e.landed = true;
    _landing = true;
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final ok =
        await _bring(id, (v) => v.top + ChatJump.landPx, divider: true);
    if (!mounted) return;
    _landing = false;
    if (!atBottom(_gap)) _reader.away = true;
    if (!ok) _hold = true;
    _track();
  }

  Future<void> _jumpFirst() async {
    final e = _entry;
    if (e == null) return;
    e.landed = true;
    e.scrolled = true;
    _track();
    if (_unseen.isEmpty) return;
    final id = _unseen.first;
    _reader.away = true;
    final ok = await _bring(id, (v) => v.top + ChatJump.landPx, animate: true);
    if (!mounted) return;
    if (ok) _hold = false;
    _track();
  }

  Future<void> _jumpMention() async {
    final e = _entry;
    if (e == null || _jumping) return;
    for (var guard = 0; guard < 200; guard++) {
      final id = _store.nextMention(e, _seenIds);
      if (id == null) break;
      if (_groupIndexOf(id) < 0) {
        _store.dropMention(e, id);
        continue;
      }
      e.scrolled = true;
      _reader.away = true;
      ref.read(flashedMessageProvider.notifier).flash(id);
      _jumping = true;
      final bool ok;
      try {
        ok = await _bring(id, (v) => v.top + v.height * 0.4, animate: true);
      } finally {
        _jumping = false;
      }
      if (!mounted) return;
      if (ok) {
        _hold = false;
        _store.mentionSeenId(e, id);
      }
      _track();
      break;
    }
    _refresh();
  }

  void _noteChat(List<Message> list, String storageKey, AppState app) {
    if (list.isEmpty) return;
    final last = list.last;
    final prevId = _chatLastId;
    final prevAt = _chatLastAt;
    _chatLastId = last.id;
    _chatLastAt = last.createdAt;
    if (prevId == null || prevId == last.id) return;
    final nav = ref.read(chatNavProvider);
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (m.id == prevId || m.createdAt < prevAt) break;
      if (m.isHistorical || m.threadRoot != null || app.isMessageFiltered(m)) {
        continue;
      }
      nav.noteLive(storageKey, m, away: true);
    }
  }

  Future<void> _toBottom() async {
    if (!_scroll.hasClients) return;
    _hold = false;
    _reader.reset();
    await _scroll.animateTo(_scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    if (!mounted || !_scroll.hasClients) return;
    _scroll.pinEnd();
    _track();
  }

  Widget _fabRow(BuildContext context) {
    final slot = widget.columnsMode ? 36.0 : chatFabSlot(context);
    return ValueListenableBuilder<bool>(
      valueListenable: _showBottom,
      builder: (context, show, _) => ValueListenableBuilder<int>(
        valueListenable: _fabs,
        builder: (context, _, _) {
          final e = _entry;
          return ChatNavFabRow(
            mentions: e == null ? 0 : _store.mentionCountFor(e, _seenIds),
            jump: _unseen.isNotEmpty,
            jumpLabel: jumpText(_unseen.length, (s) => tr(s)),
            jumpDown: _down,
            onMention: () => unawaited(_jumpMention()),
            onJump: () => unawaited(_jumpFirst()),
            bottom: !show
                ? null
                : widget.columnsMode
                    ? ColumnScrollBottomFab(onTap: () => unawaited(_toBottom()))
                    : ScrollToBottomFab(
                        size: slot, onTap: () => unawaited(_toBottom())),
            slot: slot,
          );
        },
      ),
    );
  }

  void _close() {
    final t = widget.thread;
    if (!widget.columnsMode || ref.read(activeThreadProvider) == t) {
      ref.read(activeThreadProvider.notifier).state = null;
    }
    final parked = ref.read(columnThreadsProvider);
    if (parked[t.view.storageKey] == t) {
      ref.read(columnThreadsProvider.notifier).state = {...parked}
        ..remove(t.view.storageKey);
    }
  }

  String _contextLabel(AppState app) {
    final view = widget.thread.view;
    switch (view.kind) {
      case ViewKind.channel:
        return '#${view.id}';
      case ViewKind.group:
        final g = ref.read(appStateProvider.notifier).groupById(view.id);
        return g == null ? tr('Group chat') : app.groupLabel(g, tr('Group chat'));
      case ViewKind.pm:
        final root =
            threadRootMessage(app, view.storageKey, widget.thread.rootId);
        final peerNym = app.users[view.id]?.nym ?? '';
        if (!isPlaceholderNym(peerNym)) return '@$peerNym';
        return root != null ? '@${root.author}' : tr('Private message');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    ref.watch(appStateProvider.select((s) => s.displayRev));
    final app = ref.read(appStateProvider);
    final storageKey = widget.thread.view.storageKey;
    final rawRoot = threadRootMessage(app, storageKey, widget.thread.rootId);
    final root =
        rawRoot != null && app.isMessageFiltered(rawRoot) ? null : rawRoot;
    final replies = threadRepliesFor(app, storageKey, widget.thread.rootId);
    _noteChat(app.messages[storageKey] ?? const <Message>[], storageKey, app);
    final reactions = ref.watch(reactionsProvider);
    final rows = _rowsOf(replies);
    final before = _seenIds;
    _rows = rows;
    _rowIndex = {for (var i = 0; i < rows.length; i++) rows[i].id: i};
    _seenIds = {for (final r in rows) r.id};
    final store = _store;
    final entry = _entry ??= store.open(
      storageKey,
      widget.thread.rootId,
      threadReadSec: ref
          .read(notificationHistoryProvider.notifier)
          .threadReadAt(storageKey, widget.thread.rootId),
      convReadSec: ref.read(chatNavProvider).entry(storageKey)?.lastRead ??
          ref.read(appStateProvider.notifier).channelReadMark(storageKey),
      rows: rows,
    );

    if (replies.length != _lastReplyCount) {
      final first = _lastReplyCount < 0;
      if (!first &&
          replies.length > _lastReplyCount &&
          replies
              .skip(_lastReplyCount)
              .any((m) => m.isOwn && !m.isHistorical)) {
        _reader.reset();
      }
      if (!first) {
        final away = _reader.away ||
            !ref.read(appStateProvider.notifier).appVisible ||
            !_shown ||
            (_scroll.hasClients && !atBottom(_gap));
        for (var i = 0; i < replies.length; i++) {
          final m = replies[i];
          if (m.isHistorical || before.contains(m.id)) continue;
          store.noteLive(entry, rows[i], away: away);
        }
      }
      _lastReplyCount = replies.length;
      final land = first && store.shouldLand(entry);
      if (first && !land) _scroll.pinned = true;
      if (first || !_reader.away) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients || (!first && _reader.away)) {
            return;
          }
          if (land) {
            unawaited(_land(entry, entry.info!));
            return;
          }
          _scroll.pinEnd();
        });
      }
    }
    _queue();

    final useBubbles = settings.useBubbles;
    final mentionToken = '@${splitNymSuffix(app.selfNym).base}';
    final botThread = widget.thread.view == const ChatView.pm(kNymbotPubkey);

    Widget groupOf(List<MessageGroupEntry> entries) => MessageGroup(
          key: ValueKey('thread_${entries.first.message.id}'),
          entries: entries,
          settings: settings,
          columnsMode: widget.columnsMode,
          scrollKey: storageKey,
          onReactionPicker: (msg) => showReactionPicker(context, ref, msg),
          showThreadAffordances: false,
          trailingFor: botThread ? (m) => botRunTrailing(m, c) : null,
        );

    final divider = entry.info;

    List<List<MessageGroupEntry>> groupsOf(List<Message> list,
            {String? breakBefore}) =>
        splitGroupsByDay(
          buildMessageGroups(
            list,
            reactions: reactions,
            useBubbles: useBubbles,
            mentionToken: mentionToken,
            breakBefore: breakBefore,
          ),
          (MessageGroupEntry e) => e.message.createdAt,
        );

    final replyRows = <Widget>[];
    final replyGroups = groupsOf(replies, breakBefore: divider);
    _replyGroups = replyGroups;
    final liveKeys = <String>{};
    var prevAt = root?.createdAt ?? 0;
    for (final g in replyGroups) {
      final at = g.first.message.createdAt;
      if (!DayClock.instance.sameDay(prevAt, at)) {
        replyRows.add(DaySeparator(createdAt: at, useBubbles: useBubbles));
      }
      final lead = g.first.message.id;
      if (lead == divider) {
        replyRows.add(KeyedSubtree(
            key: _dividerKey, child: const ChatNavDivider()));
      }
      liveKeys.add(lead);
      replyRows.add(KeyedSubtree(
          key: _groupKeys.putIfAbsent(lead, GlobalKey.new),
          child: groupOf(g)));
      replyRows.add(const SizedBox(height: 3));
      prevAt = g.last.message.createdAt;
    }
    _groupKeys.removeWhere((k, _) => !liveKeys.contains(k));

    final containerColor = c.isLight
        ? const Color(0x4DFFFFFF)
        : const Color(0x26000000);

    return ColoredBox(
      color: containerColor,
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: c.primaryA(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.glassBorder),
            ),
            child: Row(
              children: [
                IconButton(
                  onPressed: _close,
                  tooltip: tr('Back'),
                  visualDensity: VisualDensity.compact,
                  icon: NymSvgIcon(NymIcons.chevronLeft,
                      size: 16, color: c.text),
                ),
                NymSvgIcon(NymIcons.thread, size: 14, color: c.primary),
                const SizedBox(width: 6),
                Text(
                  tr('Thread'),
                  style: TextStyle(
                    color: c.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: NymLabel(
                      _contextLabel(app),
                      style: TextStyle(color: c.textDim, fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
            children: [
            Positioned.fill(
            child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (n) {
              if (n.depth == 0) _queue();
              return false;
            },
            child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              _reader.observe(n);
              if (n.depth == 0 &&
                  (n is UserScrollNotification ||
                      (n is ScrollUpdateNotification && n.dragDetails != null))) {
                entry.scrolled = true;
                if (n is ScrollUpdateNotification ||
                    (n is UserScrollNotification &&
                        n.direction != ScrollDirection.idle)) {
                  _hold = false;
                }
              }
              return false;
            },
            child: MessageSelection(
            builder: (keepAlives) => ListView(
              key: _viewKey,
              addAutomaticKeepAlives: keepAlives,
              controller: _scroll,
              padding: EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: widget.columnsMode ||
                          MediaQuery.sizeOf(context).width <=
                              NymDimens.mobileBreakpoint
                      ? 10
                      : 4),
              children: [
                for (final w in <Widget>[
                if (root != null) ...[
                  DaySeparator(
                    createdAt: root.createdAt,
                    useBubbles: useBubbles,
                  ),
                  for (final g in groupsOf([root])) groupOf(g),
                ] else
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      tr('Original message unavailable'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.textDim, fontSize: 12),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                  child: Row(
                    children: [
                      NymSvgIcon(NymIcons.thread, size: 14, color: c.textDim),
                      const SizedBox(width: 6),
                      Text(
                        replies.isEmpty
                            ? tr('No replies yet')
                            : replies.length == 1
                                ? tr('1 reply')
                                : tr('{n} replies',
                                    {'n': abbreviateNumber(replies.length)}),
                        style: TextStyle(
                          color: c.textDim,
                          fontSize: 11,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Divider(color: c.glassBorder, height: 1)),
                    ],
                  ),
                ),
                ...replyRows,
              ])
                  MessageSelection.item(context, w),
              ],
            )))),
            ),
            Positioned(
              left: widget.columnsMode
                  ? ChatFabs.rightColumn
                  : ChatFabs.rightPhone,
              right: widget.columnsMode
                  ? fabRight(0, true)
                  : fabRight(MediaQuery.sizeOf(context).width, false),
              bottom: 0,
              child: ChatFloatInset(
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: _fabRow(context),
                ),
              ),
            ),
            ],
            ),
          ),
          if (widget.showTyping)
            TypingIndicatorRow(
                storageKey: widget.thread.view.storageKey,
                threadRoot: widget.thread.rootId),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../widgets/chat/messages_list.dart';
import '../../widgets/nym_icons.dart';
import '../../widgets/sidebar/pm_context_menu.dart';
import '../../widgets/sidebar/sidebar_row_gestures.dart';
import '../i18n/i18n.dart';
import '../day_separators/day_separator.dart';
import 'chat_nav.dart';
import 'chat_nav_providers.dart';
import 'chat_nav_service.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/common/nym_tooltip.dart';

class ChatNavIcons {
  const ChatNavIcons._();

  static const String _open =
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">';
  static const String up = '$_open<polyline points="4 10 8 6 12 10"/></svg>';
  static const String down = '$_open<polyline points="4 6 8 10 12 6"/></svg>';
  static const String clock =
      '$_open<circle cx="8" cy="8" r="6"/><polyline points="8 4.5 8 8 10.5 9.5"/></svg>';
  static const String arrowUp =
      '$_open<line x1="8" y1="13" x2="8" y2="3"/><polyline points="4 7 8 3 12 7"/></svg>';
  static const String arrowDown =
      '$_open<line x1="8" y1="3" x2="8" y2="13"/><polyline points="4 9 8 13 12 9"/></svg>';
  static const String _pillArrow =
      '<svg viewBox="3.25 2.25 9.5 11.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">';
  static const String pillArrowUp =
      '$_pillArrow<line x1="8" y1="13" x2="8" y2="3"/><polyline points="4 7 8 3 12 7"/></svg>';
  static const String pillArrowDown =
      '$_pillArrow<line x1="8" y1="3" x2="8" y2="13"/><polyline points="4 9 8 13 12 9"/></svg>';
  static const String pillAt =
      '<svg viewBox="0.625 0.625 22.75 22.75" fill="none" stroke="currentColor" stroke-width="2.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-4 8"/></svg>';
  static const double pillGap = 5;
  static const double pillPad = 12;
  static const String anon =
      '$_open<circle cx="8" cy="6" r="3"/><path d="M2.5 14c.8-2.6 2.9-4 5.5-4s4.7 1.4 5.5 4"/><line x1="2.5" y1="2.5" x2="13.5" y2="13.5"/></svg>';
}

class ChatNavDivider extends StatelessWidget {
  const ChatNavDivider({super.key, this.cover});

  final DayFloatCover? cover;

  static const double pad = 8;

  @override
  Widget build(BuildContext context) {
    cover?.track(context);
    final c = context.nym;
    final line = Expanded(
      child: Container(height: 1, color: c.danger.withValues(alpha: 0.6)),
    );
    return Padding(
      key: const ValueKey('chat-nav-divider'),
      padding: const EdgeInsets.symmetric(vertical: pad),
      child: Semantics(
        container: true,
        label: tr(ChatNavStrings.newMessages),
        child: Row(
          children: [
            line,
            const SizedBox(width: 10),
            Text(
              tr(ChatNavStrings.newMessages).toUpperCase(),
              style: TextStyle(
                color: c.danger,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.66,
              ),
            ),
            const SizedBox(width: 10),
            line,
          ],
        ),
      ),
    );
  }
}

class ChatNavListBinding with WidgetsBindingObserver {
  ChatNavListBinding(this.ref, this.positions, {this.inset = 0}) {
    WidgetsBinding.instance.addObserver(this);
  }

  final WidgetRef ref;
  final ItemPositionsListener positions;
  final double inset;
  double viewport = 0;
  final ValueNotifier<int> fabs = ValueNotifier(0);

  String _key = '';
  String? dividerId;
  int? dividerIndex;
  Map<String, int> _indexById = const {};
  Map<String, int>? _posById;
  bool _landing = false;
  bool _queued = false;
  bool _disposed = false;
  int _hold = 0;
  String? _lastId;
  int _lastAt = 0;
  List<Message> _messages = const [];
  List<String> _unseen = const [];
  int _shownCount = -1;
  int _shownMentions = -1;
  bool _down = true;
  Map<int, List<Message>>? _members;

  ChatNavService get nav => ref.read(chatNavProvider);

  String get storageKey => _key;

  bool get jumpDown => _down;

  int get unseenCount => _unseen.length;

  String get jumpLabel => jumpText(_unseen.length, (s) => tr(s));

  String? prepare(String key, List<Message> messages) {
    if (key != _key) {
      _key = key;
      _lastId = null;
      _lastAt = 0;
      _unseen = const [];
      _shownCount = -1;
    }
    if (!identical(messages, _messages)) _hold = 2;
    _messages = messages;
    _posById = null;
    if (key.isEmpty) return dividerId = null;
    final n = nav;
    if (!n.hasEntry(key)) n.capture(key);
    final info = n.infoFor(key, messages);
    return dividerId = info?.id;
  }

  void bind(Map<String, int> indexById, int maxIndex) {
    _indexById = indexById;
    _members = null;
    final id = dividerId;
    dividerIndex = id == null ? null : indexById[id];
  }

  void observeLive(List<Message> messages, {required bool away}) {
    if (messages.isEmpty || _key.isEmpty) return;
    final last = messages.last;
    final prevId = _lastId;
    final prevAt = _lastAt;
    _lastId = last.id;
    _lastAt = last.createdAt;
    if (prevId == null || prevId == last.id) return;
    final n = nav;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.id == prevId || m.createdAt < prevAt) break;
      if (m.isHistorical) continue;
      n.noteLive(_key, m, away: away);
    }
  }

  void afterBuild(MessageListScroller scroller) {
    _queue();
    final di = dividerIndex;
    final id = dividerId;
    if (di == null || id == null || !nav.shouldLand(_key)) return;
    nav.markLanded(_key);
    _landing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      unawaited(_landAt(scroller, di, id, animate: false)
          .whenComplete(() => _landing = false));
    });
  }

  void _queue() {
    if (_queued || _disposed) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (_hold > 0 && --_hold > 0) {
        _queue();
        WidgetsBinding.instance.scheduleFrame();
        return;
      }
      update();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (!_disposed) nav.flushMarks();
      return;
    }
    _queue();
    WidgetsBinding.instance.scheduleFrame();
  }

  ItemPosition? _at(int index) {
    for (final q in positions.itemPositions.value) {
      if (q.index == index) return q;
    }
    return null;
  }

  double _topOf(ItemPosition p, String id) {
    final group = _membersByIndex()[p.index];
    if (group == null || group.length < 2 || group.first.id == id) {
      return p.itemTrailingEdge;
    }
    for (final s in _slices(p, group)) {
      if (s.$1 == id) return s.$2;
    }
    return p.itemTrailingEdge;
  }

  double get _landLine =>
      1 - (viewport > 0 ? ChatJump.landPx / viewport : 0.01);

  Future<void> _landAt(MessageListScroller scroller, int index, String id,
      {required bool animate}) async {
    await scroller.animateTo(
      index: index,
      alignment: 0.45,
      duration: Duration(milliseconds: animate ? 300 : 1),
    );
    for (var i = 0; i < 2 && !_disposed; i++) {
      await WidgetsBinding.instance.endOfFrame;
      final p = _at(index);
      if (p == null) break;
      final shift = _landLine - _topOf(p, id);
      if (shift.abs() < 0.004) break;
      await scroller.animateTo(
          index: index,
          alignment: p.itemLeadingEdge + shift,
          duration: const Duration(milliseconds: 1));
    }
    _landing = false;
    update();
  }

  void update() {
    if (_key.isEmpty || _disposed) return;
    final pos = positions.itemPositions.value;
    final n = nav;
    if (pos.isNotEmpty &&
        _hold == 0 &&
        !_landing &&
        !n.shouldLand(_key) &&
        ref.read(appStateProvider.notifier).appVisible) {
      _track(pos);
    }
    _refresh(pos);
  }

  void _track(Iterable<ItemPosition> pos) {
    if (_messages.isEmpty) return;
    final n = nav;
    ItemPosition? newest;
    for (final q in pos) {
      if (q.index == 0) newest = q;
    }
    final bottom = newest != null &&
        (viewport > 0
            ? atBottom(inset - newest.itemLeadingEdge * viewport)
            : newest.itemLeadingEdge >= -0.01);
    if (bottom) {
      n.seeAll(_key, _messages);
      return;
    }
    final members = _membersByIndex();
    final vh = viewport > 0 ? viewport : 1000.0;
    bool inside(double edge) => edge * vh > 0.5 && edge * vh < vh - 0.5;
    final seen = <Message>[];
    for (final q in pos) {
      if (q.itemTrailingEdge <= 0 || q.itemLeadingEdge >= 1) continue;
      final group = members[q.index];
      if (group == null || group.isEmpty) continue;
      if (inside(q.itemLeadingEdge)) {
        seen.addAll(group);
        continue;
      }
      if (q.itemLeadingEdge > 0) continue;
      for (final s in _slices(q, group)) {
        if (!inside(s.$3)) continue;
        for (final m in group) {
          if (m.id == s.$1) seen.add(m);
        }
      }
    }
    if (seen.isEmpty) return;
    final byId = _posById ??= {
      for (var i = 0; i < _messages.length; i++) _messages[i].id: i,
    };
    var at = -1;
    var last = -1;
    for (final m in seen) {
      final e = n.effAt(m);
      final i = byId[m.id] ?? -1;
      if (e > at || (e == at && i > last)) {
        at = e;
        last = i;
      }
    }
    final ids = <String>[];
    for (var j = last;
        j >= 0 && ids.length < ChatJump.markMax && _messages[j].createdAt >= at;
        j--) {
      if (n.effAt(_messages[j]) == at) ids.add(_messages[j].id);
    }
    n.advance(_key, at, ids);
  }

  Map<int, List<Message>> _membersByIndex() {
    final cached = _members;
    if (cached != null) return cached;
    final out = <int, List<Message>>{};
    for (final m in _messages) {
      final i = _indexById[m.id];
      if (i != null) (out[i] ??= <Message>[]).add(m);
    }
    return _members = out;
  }

  static double _weight(Message m) => 1 + m.content.length / 40;

  String _dirFor(String id, Iterable<ItemPosition> pos) {
    final idx = _indexById[id];
    if (idx == null) return 'down';
    ItemPosition? hit;
    var minVis = 1 << 30;
    var maxVis = -1;
    for (final q in pos) {
      if (q.index == idx) hit = q;
      if (q.itemTrailingEdge <= 0 || q.itemLeadingEdge >= 1) continue;
      if (q.index < minVis) minVis = q.index;
      if (q.index > maxVis) maxVis = q.index;
    }
    if (hit != null) {
      final vh = viewport > 0 ? viewport : 1000.0;
      return jumpDir(top: (1 - _topOf(hit, id)) * vh, viewTop: 0);
    }
    if (maxVis < 0) return 'down';
    return idx > maxVis ? 'up' : 'down';
  }

  void _refresh(Iterable<ItemPosition> pos) {
    final n = nav;
    _unseen = n.unseenFor(_key, _messages);
    final count = _unseen.length;
    final mentions = n.mentionCountFor(_key);
    final down = count == 0 || _dirFor(_unseen.first, pos) == 'down';
    if (count != _shownCount || mentions != _shownMentions || down != _down) {
      _shownCount = count;
      _shownMentions = mentions;
      _down = down;
      fabs.value++;
    }
  }

  void userScrolled() {
    if (_key.isNotEmpty) nav.markScrolled(_key);
  }

  Future<void> _reveal(MessageListScroller scroller, String id) async {
    final idx = _indexById[id];
    if (idx == null) return;
    await scroller.animateTo(
      index: idx,
      alignment: 0.4,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    final group = _membersByIndex()[idx];
    if (group != null && group.length > 1) {
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      final shift = _sliceShift(idx, id, group);
      if (shift != null && shift.$2.abs() > 0.02) {
        await scroller.animateTo(
            index: idx,
            alignment: shift.$1 + shift.$2,
            duration: const Duration(milliseconds: 1));
      }
    }
    update();
  }

  (double, double)? _sliceShift(int idx, String id, List<Message> group) {
    final p = _at(idx);
    if (p == null) return null;
    for (final s in _slices(p, group)) {
      if (s.$1 == id) return (p.itemLeadingEdge, 0.5 - (s.$2 + s.$3) / 2);
    }
    return null;
  }

  static Iterable<(String, double, double)> _slices(
      ItemPosition p, List<Message> group) sync* {
    var total = 0.0;
    for (final m in group) {
      total += _weight(m);
    }
    final span = p.itemTrailingEdge - p.itemLeadingEdge;
    var top = p.itemTrailingEdge;
    for (final m in group) {
      final bottom = top - span * _weight(m) / total;
      yield (m.id, top, bottom);
      top = bottom;
    }
  }

  bool get jumpShown => _key.isNotEmpty && _unseen.isNotEmpty;

  Future<void> jumpFirst(MessageListScroller scroller) async {
    final n = nav;
    n.markScrolled(_key);
    n.markLanded(_key);
    _landing = false;
    update();
    final target = _unseen.isEmpty ? null : _unseen.first;
    final idx = target == null ? null : _indexById[target];
    if (target == null || idx == null) {
      fabs.value++;
      return;
    }
    _down = _dirFor(target, positions.itemPositions.value) == 'down';
    await _landAt(scroller, idx, target, animate: true);
    if (!_disposed) fabs.value++;
  }

  bool jumpMention(MessageListScroller scroller) {
    final n = nav;
    for (var guard = 0; guard < 200; guard++) {
      final id = n.nextMention(_key);
      if (id == null) {
        fabs.value++;
        return false;
      }
      if (!_indexById.containsKey(id)) {
        n.dropMention(_key, id);
        continue;
      }
      n.markScrolled(_key);
      unawaited(_reveal(scroller, id));
      ref.read(flashedMessageProvider.notifier).flash(id);
      n.markMentionsSeen(_key, [id]);
      fabs.value++;
      return true;
    }
    return false;
  }

  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    fabs.dispose();
  }
}

class ChatFloatInset extends ConsumerStatefulWidget {
  const ChatFloatInset({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ChatFloatInset> createState() => _ChatFloatInsetState();
}

class _ChatFloatInsetState extends ConsumerState<ChatFloatInset> {
  double _lift = 0;
  bool _queued = false;

  void _queue() {
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) return;
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      final next = floatLiftOver(ref.read(composerHintTopProvider), bottom);
      if ((next - _lift).abs() > 0.5) setState(() => _lift = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(composerHintTopProvider);
    _queue();
    return Padding(
      padding: EdgeInsets.only(bottom: ChatFabs.floatBottom + _lift),
      child: widget.child,
    );
  }
}

class ChatNavFabs extends ConsumerWidget {
  const ChatNavFabs({
    super.key,
    required this.binding,
    this.bottom,
    this.slot = 40,
  });

  final ChatNavListBinding binding;
  final Widget? bottom;
  final double slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(chatNavRevisionProvider);
    return ValueListenableBuilder<int>(
      valueListenable: binding.fabs,
      builder: (context, _, _) {
        final key = binding.storageKey;
        final nav = ref.read(chatNavProvider);
        final count = key.isEmpty ? 0 : nav.mentionCountFor(key);
        final jump = binding.jumpShown;
        final order =
            fabRow(bottom: bottom != null, jump: jump, mention: count > 0);
        if (order.isEmpty) return const SizedBox.shrink();
        final scroller = ref.read(messageListScrollerProvider(key));
        final children = <Widget>[];
        for (final k in order) {
          if (children.isNotEmpty) {
            children.add(const SizedBox(width: ChatFabs.gap));
          }
          switch (k) {
            case 'mention':
              children.add(_MentionFab(
                count: count,
                onTap: () => binding.jumpMention(scroller),
              ));
            case 'jump':
              children.add(Flexible(
                child: _JumpPill(
                  label: binding.jumpLabel,
                  down: binding.jumpDown,
                  onTap: () => unawaited(binding.jumpFirst(scroller)),
                ),
              ));
            case 'bottom':
              children.add(bottom!);
          }
        }
        return ConstrainedBox(
          key: const ValueKey('chat-nav-row'),
          constraints: BoxConstraints(minHeight: slot),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: children,
          ),
        );
      },
    );
  }
}

class _JumpPill extends StatelessWidget {
  const _JumpPill({required this.label, required this.down, required this.onTap});

  final String label;
  final bool down;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return NymTooltip(
      message: tr(ChatNavStrings.jumpFirst),
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: c.glassBg,
          shape: StadiumBorder(side: BorderSide(color: c.glassBorder)),
          elevation: 4,
          child: InkWell(
            key: const ValueKey('chat-nav-jump'),
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(
                  horizontal: ChatNavIcons.pillPad),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.string(
                    down ? ChatNavIcons.pillArrowDown : ChatNavIcons.pillArrowUp,
                    key: ValueKey(down ? 'chat-nav-jump-down' : 'chat-nav-jump-up'),
                    width: 8.26,
                    height: 10,
                    theme: SvgTheme(currentColor: c.primary),
                  ),
                  const SizedBox(width: ChatNavIcons.pillGap),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MentionFab extends StatelessWidget {
  const _MentionFab({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final label = '${tr(ChatNavStrings.mentions)} ($count)';
    return NymTooltip(
      message: tr(ChatNavStrings.mentions),
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: c.glassBg,
          shape: StadiumBorder(side: BorderSide(color: c.glassBorder)),
          elevation: 4,
          child: InkWell(
            key: const ValueKey('chat-nav-mention'),
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(
                  horizontal: ChatNavIcons.pillPad),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.string(
                    ChatNavIcons.pillAt,
                    key: const ValueKey('chat-nav-mention-icon'),
                    width: 10,
                    height: 10,
                    theme: SvgTheme(currentColor: c.primary),
                  ),
                  const SizedBox(width: ChatNavIcons.pillGap),
                  Text(
                    '$count',
                    key: const ValueKey('chat-nav-mention-count'),
                    style: TextStyle(
                      color: c.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ChatNavRowBadges extends ConsumerWidget {
  const ChatNavRowBadges({super.key, required this.storageKey});

  final String storageKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(chatNavRevisionProvider);
    final alias = chatNavAlias(storageKey);
    ref.watch(appStateProvider.select((s) =>
        (s.displayRev, s.unreadCounts[storageKey], s.unreadCounts[alias])));
    final nav = ref.read(chatNavProvider);
    final pinned = nav.pinIndexOfChat(storageKey) >= 0;
    final mention = nav.hasUnreadMention(storageKey, aliases: [alias]);
    if (!pinned && !mention) return const SizedBox.shrink();
    final c = context.nym;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pinned)
          Padding(
            padding: const EdgeInsets.only(left: 5),
            child: NymTooltip(
              message: tr(ChatNavStrings.favorited),
              child: NymSvgIcon(NymIcons.starFilled,
                  key: const ValueKey('chat-pin-icon'),
                  size: 14,
                  color: c.textDim),
            ),
          ),
        if (mention)
          NymTooltip(
            message: tr(ChatNavStrings.mentions),
            child: Container(
              key: const ValueKey('chat-mention-badge'),
              width: 18,
              height: 18,
              margin: const EdgeInsets.only(left: 5),
              decoration: BoxDecoration(color: c.primary, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text(
                '@',
                style: TextStyle(
                  color: c.bg,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

List<SidebarQuickMenuItem> chatNavSidebarItems(WidgetRef ref, String storageKey) {
  final nav = ref.read(chatNavProvider);
  final k = pinKeyForChat(storageKey);
  if (k.isEmpty || k == 'c:nymchat') return const [];
  final pinned = nav.isChatPinned(k);
  final channel = pinParse(k)?.kind == 'channel';
  return [
    SidebarQuickMenuItem(
      label: channel
          ? tr(pinned ? ChatNavStrings.unfavorite : ChatNavStrings.favorite)
          : tr(pinned
              ? ChatNavStrings.unfavoriteChat
              : ChatNavStrings.favoriteChat),
      svg: pinned ? NymIcons.starFilled : NymIcons.starOutline,
      onSelected: () => nav.togglePin(k),
    ),
    if (pinned && nav.canMovePin(k, -1))
      SidebarQuickMenuItem(
        label: tr(ChatNavStrings.moveUp),
        svg: ChatNavIcons.up,
        onSelected: () => nav.movePin(k, -1),
      ),
    if (pinned && nav.canMovePin(k, 1))
      SidebarQuickMenuItem(
        label: tr(ChatNavStrings.moveDown),
        svg: ChatNavIcons.down,
        onSelected: () => nav.movePin(k, 1),
      ),
  ];
}

List<String> chatNavPinSort(WidgetRef ref, List<String> keys) {
  ref.watch(chatNavRevisionProvider);
  return pinSort(keys, ref.read(chatNavProvider).pinState());
}

Future<void> showSendMenu(
  BuildContext context,
  Offset globalPosition, {
  required VoidCallback onSendLater,
  VoidCallback? onAnon,
}) {
  return showSidebarQuickMenu(context, globalPosition, [
    SidebarQuickMenuItem(
      label: tr(ChatNavStrings.sendLater),
      svg: ChatNavIcons.clock,
      onSelected: onSendLater,
    ),
    if (onAnon != null)
      SidebarQuickMenuItem(
        label: tr('Send anonymously'),
        svg: ChatNavIcons.anon,
        onSelected: onAnon,
      ),
  ]);
}

Future<void> _showPanel(BuildContext context, Widget child) {
  final isLight = context.nym.isLight;
  return showNymSheet<void>(
    context,
    (_) => child,
    barrierColor: isLight ? const Color(0x73000000) : const Color(0xBF000000),
  );
}

class _PanelShell extends StatelessWidget {
  const _PanelShell({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final size = MediaQuery.of(context).size;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title.toUpperCase(),
                style: TextStyle(
                  color: c.primary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            IconButton(
              tooltip: tr('Close'),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(Icons.close, size: 18, color: c.textDim),
            ),
          ],
        ),
        Divider(color: c.glassBorder, height: 16),
        Flexible(child: child),
      ],
    );
    return nymSheetOr(
      context,
      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), child: body),
      (body) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: size.width * 0.92,
            constraints:
                BoxConstraints(maxWidth: 520, maxHeight: size.height * 0.88),
            decoration: BoxDecoration(
              color: c.bgSecondary,
              borderRadius: NymRadius.rxl,
              border: Border.all(color: c.glassBorder),
            ),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: body,
          ),
        ),
      ),
    );
  }
}

class _HeldNote extends StatelessWidget {
  const _HeldNote({this.detail = false});

  final bool detail;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            NymSvgIcon(ChatNavIcons.clock, size: 14, color: c.textDim),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                tr(ChatNavStrings.held),
                style: TextStyle(color: c.textDim, fontSize: 12),
              ),
            ),
          ],
        ),
        if (detail) ...[
          const SizedBox(height: 4),
          Text(
            tr(ChatNavStrings.heldDetail),
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class SendLaterSheet extends ConsumerStatefulWidget {
  const SendLaterSheet({
    super.key,
    required this.storageKey,
    required this.draft,
    this.replaces,
    this.at,
    this.threadRoot,
    this.onScheduled,
  });

  final String storageKey;
  final String draft;
  final String? replaces;
  final int? at;
  final String? threadRoot;
  final VoidCallback? onScheduled;

  static Future<void> open(
    BuildContext context, {
    required String storageKey,
    required String draft,
    String? replaces,
    int? at,
    String? threadRoot,
    VoidCallback? onScheduled,
  }) {
    return _showPanel(
      context,
      SendLaterSheet(
        storageKey: storageKey,
        draft: draft,
        replaces: replaces,
        at: at,
        threadRoot: threadRoot,
        onScheduled: onScheduled,
      ),
    );
  }

  @override
  ConsumerState<SendLaterSheet> createState() => _SendLaterSheetState();
}

class _SendLaterSheetState extends ConsumerState<SendLaterSheet> {
  late DateTime _when;
  String? _error;
  bool _busy = false;

  int get _offsetMin => DateTime.now().timeZoneOffset.inMinutes;

  @override
  void initState() {
    super.initState();
    final presets =
        schedulePresets(DateTime.now().millisecondsSinceEpoch, _offsetMin);
    final at = widget.at ?? presets.first.at;
    _when = DateTime.fromMillisecondsSinceEpoch(at * 1000);
  }

  Future<void> _confirm(int at) async {
    if (_busy) return;
    final check =
        scheduleCheck(at, DateTime.now().millisecondsSinceEpoch ~/ 1000);
    if (check != null) {
      setState(() => _error = scheduleErrorText(check, tr));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final nav = ref.read(chatNavProvider);
    final res = widget.replaces != null
        ? await nav.reschedule(widget.replaces!, at)
        : await nav.schedule(widget.storageKey, widget.draft, at,
            threadRoot: widget.threadRoot);
    if (!mounted) return;
    if (res.ok) {
      widget.onScheduled?.call();
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _busy = false;
      _error = res.reason;
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _when.isBefore(now) ? now : _when,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 30)),
    );
    if (d == null || !mounted) return;
    setState(() => _when =
        DateTime(d.year, d.month, d.day, _when.hour, _when.minute));
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_when),
    );
    if (t == null || !mounted) return;
    setState(() => _when =
        DateTime(_when.year, _when.month, _when.day, t.hour, t.minute));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final nav = ref.read(chatNavProvider);
    final block = nav.blockReason(widget.storageKey);
    final preview = widget.draft.trim();
    final disabled = block != null || preview.isEmpty || _busy;
    final presets =
        schedulePresets(DateTime.now().millisecondsSinceEpoch, _offsetMin);
    final whenSec = _when.millisecondsSinceEpoch ~/ 1000;
    return _PanelShell(
      title: tr(ChatNavStrings.sendLater),
      child: SingleChildScrollView(
        child: Column(
          key: const ValueKey('send-later-sheet'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              constraints: const BoxConstraints(maxHeight: 120),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: c.bgTertiary,
                borderRadius: NymRadius.rsm,
              ),
              child: SingleChildScrollView(
                child: Text(
                  preview.isEmpty
                      ? tr('Write a message first.')
                      : (preview.length > 280
                          ? '${preview.substring(0, 280)}…'
                          : preview),
                  style: TextStyle(
                      color: preview.isEmpty ? c.textDim : c.text,
                      fontSize: preview.isEmpty ? 12 : 14),
                ),
              ),
            ),
            if (block != null) ...[
              const SizedBox(height: 12),
              Text(block,
                  key: const ValueKey('send-later-block'),
                  style: TextStyle(color: c.danger, fontSize: 13)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in presets)
                  OutlinedButton(
                    key: ValueKey('send-later-preset-${p.id}'),
                    onPressed: disabled ? null : () => _confirm(p.at),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.text,
                      side: BorderSide(color: c.glassBorder),
                    ),
                    child: Text(nav.presetLabel(p.id, p.at)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(tr('Pick a date and time'),
                style: TextStyle(color: c.textDim, fontSize: 12)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('send-later-date'),
                    onPressed: disabled ? null : _pickDate,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.text,
                      side: BorderSide(color: c.glassBorder),
                    ),
                    child: Text(scheduleInputValue(whenSec, _offsetMin)
                        .split('T')
                        .first),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('send-later-time'),
                    onPressed: disabled ? null : _pickTime,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.text,
                      side: BorderSide(color: c.glassBorder),
                    ),
                    child: Text(
                        scheduleInputValue(whenSec, _offsetMin).split('T').last),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  key: const ValueKey('send-later-error'),
                  style: TextStyle(color: c.danger, fontSize: 13)),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('send-later-confirm'),
                onPressed: disabled ? null : () => _confirm(whenSec),
                style: FilledButton.styleFrom(
                  backgroundColor: c.primaryA(0.15),
                  foregroundColor: c.primary,
                ),
                child: Text(tr('Schedule')),
              ),
            ),
            const SizedBox(height: 12),
            const _HeldNote(detail: true),
          ],
        ),
      ),
    );
  }
}

class ScheduledListPanel extends ConsumerWidget {
  const ScheduledListPanel({super.key, required this.storageKey});

  final String storageKey;

  static Future<void> open(BuildContext context, String storageKey) {
    final nav = ProviderScope.containerOf(context).read(chatNavProvider);
    unawaited(nav.refreshScheduled());
    return _showPanel(context, ScheduledListPanel(storageKey: storageKey));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(chatNavRevisionProvider);
    final c = context.nym;
    final nav = ref.read(chatNavProvider);
    final items = nav.scheduledFor(storageKey);
    return _PanelShell(
      title: tr(ChatNavStrings.scheduled),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(tr('Nothing scheduled in this chat.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.textDim)),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final it in items)
                        _ScheduledRow(item: it, storageKey: storageKey),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          const _HeldNote(),
        ],
      ),
    );
  }
}

class _ScheduledRow extends ConsumerWidget {
  const _ScheduledRow({required this.item, required this.storageKey});

  final ScheduledItem item;
  final String storageKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final nav = ref.read(chatNavProvider);
    final open = item.status == 'pending' || item.status == 'failed';
    final err = nav.scheduleFailText(item);
    ButtonStyle style({bool danger = false}) => OutlinedButton.styleFrom(
          foregroundColor: danger ? c.danger : c.text,
          side: BorderSide(color: c.glassBorder),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          textStyle: const TextStyle(fontSize: 13),
        );
    return Container(
      key: ValueKey('scheduled-${item.id}'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              NymSvgIcon(ChatNavIcons.clock,
                  key: const ValueKey('scheduled-clock'),
                  size: 14,
                  color: c.primary),
              const SizedBox(width: 8),
              Text(nav.formatScheduleTime(item.at),
                  style: TextStyle(color: c.textDim, fontSize: 12)),
              const Spacer(),
              Text(
                scheduleStatusText(item.status, tr),
                style: TextStyle(
                  color: item.status == 'failed' ? c.danger : c.textDim,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(item.text, style: TextStyle(color: c.text, fontSize: 14)),
          if (err.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(err, style: TextStyle(color: c.danger, fontSize: 13)),
          ],
          if (open) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  key: ValueKey('scheduled-edit-${item.id}'),
                  style: style(),
                  onPressed: () {
                    Navigator.of(context).maybePop();
                    unawaited(SendLaterSheet.open(
                      context,
                      storageKey: scheduleChatKey(item.chat),
                      draft: item.text,
                      replaces: item.id,
                      at: item.at,
                    ));
                  },
                  child: Text(tr(ChatNavStrings.editTime)),
                ),
                OutlinedButton(
                  key: ValueKey('scheduled-now-${item.id}'),
                  style: style(),
                  onPressed: () => unawaited(nav.sendScheduledNow(item.id)),
                  child: Text(tr(ChatNavStrings.sendNow)),
                ),
                OutlinedButton(
                  key: ValueKey('scheduled-cancel-${item.id}'),
                  style: style(danger: true),
                  onPressed: () => unawaited(nav.cancelScheduled(item.id)),
                  child: Text(tr(ChatNavStrings.cancel)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class ScheduledBar extends ConsumerWidget {
  const ScheduledBar({super.key, required this.storageKey});

  final String storageKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(chatNavRevisionProvider);
    if (storageKey.isEmpty) return const SizedBox.shrink();
    final n = ref.read(chatNavProvider).scheduledOpenCount(storageKey);
    if (n <= 0) return const SizedBox.shrink();
    final c = context.nym;
    final label = n == 1
        ? tr('1 scheduled message')
        : tr('{n} scheduled messages', {'n': n});
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: c.glassBg,
          shape: StadiumBorder(side: BorderSide(color: c.glassBorder)),
          child: InkWell(
            key: const ValueKey('scheduled-bar'),
            customBorder: const StadiumBorder(),
            onTap: () => ScheduledListPanel.open(context, storageKey),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NymSvgIcon(ChatNavIcons.clock, size: 14, color: c.primary),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(color: c.primary, fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

bool chatNavTouchDrag() =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

class PinnedReorder extends ConsumerStatefulWidget {
  const PinnedReorder({
    super.key,
    required this.storageKey,
    required this.child,
    this.onHoldMenu,
  });

  final String storageKey;
  final Widget child;
  final bool Function(Offset globalPosition)? onHoldMenu;

  @override
  ConsumerState<PinnedReorder> createState() => _PinnedReorderState();
}

class _PinnedReorderState extends ConsumerState<PinnedReorder> {
  Offset? _downAt;
  Offset? _lastAt;

  void _started() {
    SidebarRowGestures.suppressMenu = true;
  }

  void _ended() {
    SidebarRowGestures.suppressMenu = false;
    final down = _downAt;
    final last = _lastAt;
    _downAt = null;
    if (!chatNavTouchDrag() || down == null || last == null) return;
    if ((last - down).distance <= SidebarRowGestures.moveThreshold) {
      widget.onHoldMenu?.call(down);
    }
  }

  @override
  void dispose() {
    SidebarRowGestures.suppressMenu = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(chatNavRevisionProvider);
    final nav = ref.read(chatNavProvider);
    final key = pinKeyForChat(widget.storageKey);
    if (key.isEmpty || !nav.isChatPinned(key)) return widget.child;
    final c = context.nym;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 260.0;
      final feedback = Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.85,
          child: SizedBox(width: width, child: widget.child),
        ),
      );
      final dragging = Opacity(opacity: 0.5, child: widget.child);
      final Widget draggable = chatNavTouchDrag()
          ? LongPressDraggable<String>(
              key: ValueKey('pin-drag-$key'),
              data: key,
              delay: const Duration(milliseconds: 350),
              feedback: feedback,
              childWhenDragging: dragging,
              onDragStarted: _started,
              onDragEnd: (_) => _ended(),
              child: widget.child,
            )
          : Draggable<String>(
              key: ValueKey('pin-drag-$key'),
              data: key,
              feedback: feedback,
              childWhenDragging: dragging,
              onDragStarted: _started,
              onDragEnd: (_) => _ended(),
              child: widget.child,
            );
      return Listener(
        onPointerDown: (e) {
          _downAt = e.position;
          _lastAt = e.position;
        },
        onPointerMove: (e) => _lastAt = e.position,
        child: DragTarget<String>(
          onWillAcceptWithDetails: (d) => nav.canDropPin(d.data, key),
          onAcceptWithDetails: (d) => nav.dropPin(d.data, key),
          builder: (context, candidates, _) => Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: candidates.isNotEmpty ? c.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: draggable,
          ),
        ),
      );
    });
  }
}

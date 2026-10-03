import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/groups/group_logic.dart';
import '../../features/chat_nav/chat_nav_providers.dart';
import '../../features/chat_nav/chat_nav_service.dart';
import '../../features/chat_nav/chat_nav_ui.dart';
import '../../features/i18n/i18n.dart';
import '../../features/nymbot/nymbot_providers.dart'
    show BotChatController, botChatControllerProvider, mergeBotThreadWithInfo;
import '../../features/nymbot/bot_runs_view.dart' show botRunTrailing;
import '../../features/pms/pm_logic.dart';
import '../../features/reactions/reaction_picker.dart';
import '../../features/shop/cosmetics.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../models/pm_conversation.dart';
import '../../models/message.dart';
import '../../models/settings.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../chat/message_row.dart';
import '../../features/threads/thread_view.dart' show ThreadView;
import '../chat/list_anchor.dart';
import '../chat/messages_list.dart' show messageListScrollerProvider;
import '../chat/message_skeleton.dart';
import '../chat/typing_indicator.dart';
import '../common/app_dialog.dart';
import '../common/nym_avatar.dart';
import '../context_menu/profile_badges.dart';
import '../nym_icons.dart';
import '../../features/chat_lock/chat_lock_providers.dart';

class _CvDimens {
  static const double column = 360;
  static const double addColumn = 220;
  static const double gap = 12;
  static const double padding = 12;
  // The PWA's mobile snap carousel applies at `width <= 768`.
  static const double mobileBreakpoint = 768;
}

enum _ColumnKind { channel, pm, group }

/// A deck column descriptor resolving its own storage key, unread key, title and icon.
class _ColumnDesc {
  const _ColumnDesc.channel(this.channel, this.geohash)
      : kind = _ColumnKind.channel,
        pubkey = '',
        nym = '',
        groupId = '';
  const _ColumnDesc.pm(this.pubkey, {this.nym = ''})
      : kind = _ColumnKind.pm,
        channel = '',
        geohash = '',
        groupId = '';
  const _ColumnDesc.group(this.groupId)
      : kind = _ColumnKind.group,
        channel = '',
        geohash = '',
        pubkey = '',
        nym = '';

  final _ColumnKind kind;
  final String channel;
  final String geohash;
  final String pubkey;
  final String nym;
  final String groupId;

  /// Stable identity key, also used as the unread-counts key.
  String get key => switch (kind) {
        _ColumnKind.channel =>
          (geohash.isNotEmpty ? geohash : channel).toLowerCase(),
        _ColumnKind.pm => pubkey,
        _ColumnKind.group => groupId,
      };

  String get storageKey => switch (kind) {
        _ColumnKind.channel => '#${geohash.isNotEmpty ? geohash : channel}',
        _ColumnKind.pm => PmLogic.pmStorageKey(pubkey),
        _ColumnKind.group => GroupLogic.groupStorageKey(groupId),
      };

  /// Same JSON shape the PWA persists under `nym_columns_layout`.
  Map<String, dynamic> toJson() => switch (kind) {
        _ColumnKind.channel => {
            'type': 'channel',
            'channel': channel,
            'geohash': geohash,
          },
        _ColumnKind.pm => {
            'type': 'pm',
            'pubkey': pubkey,
            'nym': nym,
          },
        _ColumnKind.group => {
            'type': 'group',
            'groupId': groupId,
          },
      };

  /// Null for malformed entries so a bad value can't crash the deck.
  static _ColumnDesc? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    switch (type) {
      case 'channel':
        final channel = (raw['channel'] as String?) ?? '';
        final geohash = (raw['geohash'] as String?) ?? '';
        if (channel.isEmpty && geohash.isEmpty) return null;
        return _ColumnDesc.channel(channel, geohash);
      case 'pm':
        final pubkey = (raw['pubkey'] as String?) ?? '';
        if (pubkey.isEmpty) return null;
        return _ColumnDesc.pm(pubkey, nym: (raw['nym'] as String?) ?? '');
      case 'group':
        final groupId = (raw['groupId'] as String?) ?? '';
        if (groupId.isEmpty) return null;
        return _ColumnDesc.group(groupId);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _ColumnDesc && other.kind == kind && other.key == key;

  @override
  int get hashCode => Object.hash(kind, key);
}

typedef _PickerEntry = ({_ColumnDesc desc, String label, Widget icon});

/// The multi-column deck: a draggable strip on desktop, a snap carousel on mobile (<=768); layout persisted.
class ColumnsDeck extends ConsumerStatefulWidget {
  const ColumnsDeck({super.key});

  @override
  ConsumerState<ColumnsDeck> createState() => _ColumnsDeckState();
}

class _ColumnsDeckState extends ConsumerState<ColumnsDeck> {
  final List<_ColumnDesc> _columns = [];
  bool _seeded = false;

  /// One-shot: points the shared header/composer at the initial focused column.
  bool _syncedInitialView = false;

  /// Set while the deck drives `switchView`, so the view listener doesn't recurse into [_onExternalView].
  bool _syncingFromDeck = false;

  final PageController _pageController = PageController();

  final ScrollController _stripScroll = ScrollController();

  final GlobalKey _stripKey = GlobalKey();

  /// The PageView page on mobile; the last-focused column on desktop.
  int _focused = 0;

  /// Key of the primary channel column; sidebar channel taps repurpose it in place while it lives.
  String? _primaryKey;

  /// Desktop only; the add button hides while the picker is open.
  bool _pickerOpen = false;

  /// Current (live-reflowed) index of the dragged column.
  int? _dragIndex;

  /// True once the pointer moved past the 5px start threshold.
  bool _dragActive = false;
  Offset _dragStart = Offset.zero;

  /// The y component is clamped to 40 like the PWA.
  Offset _grabOffset = Offset.zero;

  Size _dragSize = Size.zero;
  BuildContext? _dragBoundary;
  ui.Image? _dragImage;
  OverlayEntry? _dragGhostEntry;
  Offset _ghostPos = Offset.zero;

  /// Per-column at-bottom flags by storage key; absent means at-bottom.
  final Map<String, bool> _atBottomByKey = <String, bool>{};

  /// Kept so [dispose] can unregister without touching `ref`.
  AppStateNotifier? _gateHost;

  @override
  void initState() {
    super.initState();
    // While set, unread bumps and read marks defer to focused + at-bottom + visible columns.
    final notifier = ref.read(appStateProvider.notifier);
    notifier.columnsReadGate = _columnsReadGate;
    // Distinguishes a reply the focused column shows (thread open) from one collapsed behind a reply count.
    notifier.openThreadGate =
        () => mounted ? ref.read(activeThreadProvider) : null;
    _gateHost = notifier;
  }

  @override
  void dispose() {
    // Guarded so another deck's gate is never clobbered.
    final host = _gateHost;
    if (host != null && host.columnsReadGate == _columnsReadGate) {
      host.columnsReadGate = null;
      host.openThreadGate = null;
    }
    _gateHost = null;
    _removeGhost();
    _pageController.dispose();
    _stripScroll.dispose();
    super.dispose();
  }

  /// Passes when [key] is the focused column's, it is at the bottom, and the app is visible; matches both key forms.
  bool _columnsReadGate(String key) {
    if (key.isEmpty || _columns.isEmpty) return false;
    if (_focused < 0 || _focused >= _columns.length) return false;
    final desc = _columns[_focused];
    if (!_descMatchesKey(desc, key)) return false;
    // Backgrounded apps never mark read; `inactive` still counts as visible, like an unfocused web tab.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      return false;
    }
    return _atBottomByKey[desc.storageKey] ?? true;
  }

  /// Accepts the storage key, the descriptor key, and a channel's bare lowercase name.
  bool _descMatchesKey(_ColumnDesc desc, String key) {
    if (key == desc.storageKey || key == desc.key) return true;
    if (desc.kind == _ColumnKind.channel) {
      final k = key.toLowerCase();
      return k == desc.key || k == '#${desc.key}';
    }
    return false;
  }

  /// On the scrolled-up to at-bottom transition, mark the column read (the gate is re-checked).
  void _onColumnAtBottom(_ColumnDesc desc, bool atBottom) {
    final was = _atBottomByKey[desc.storageKey] ?? true;
    _atBottomByKey[desc.storageKey] = atBottom;
    if (atBottom && !was) _markColumnRead(desc);
  }

  /// Clears the unread badge and stamps the read watermark when the gate passes.
  void _markColumnRead(_ColumnDesc desc) {
    if (!_columnsReadGate(desc.storageKey)) return;
    ref.read(appStateProvider.notifier).clearUnread(desc.storageKey);
  }

  /// Bound at build time so a scroll racing a reorder can't report under a stale index.
  ValueChanged<bool> _atBottomHandlerFor(_ColumnDesc desc) =>
      (atBottom) => _onColumnAtBottom(desc, atBottom);

  /// Live reset: drop in-memory columns so the next build re-seeds, or `_saveLayout` would undo the reset.
  void _onColumnsReset() {
    if (!mounted) return;
    setState(() {
      _columns.clear();
      _seeded = false;
      _pickerOpen = false;
      _focused = 0;
    });
    _primaryKey = null;
    _syncedInitialView = false;
    _atBottomByKey.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _columns.isNotEmpty) _scrollToIndex(0);
    });
  }

  void _saveLayout() {
    final kv = ref.read(keyValueStoreProvider);
    final data = _columns.map((c) => c.toJson()).toList();
    kv.setString(StorageKeys.columnsLayout, jsonEncode(data));
    // Every layout save also schedules the synced settings publish, which reads the layout from the KV store.
    ref.read(settingsProvider.notifier).notifySyncedChange();
  }

  /// Null when absent, empty or malformed.
  List<_ColumnDesc>? _loadLayout() {
    final kv = ref.read(keyValueStoreProvider);
    final raw = kv.getString(StorageKeys.columnsLayout);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final out = <_ColumnDesc>[];
      for (final entry in decoded) {
        final desc = _ColumnDesc.fromJson(entry);
        if (desc != null && !out.contains(desc)) out.add(desc);
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  void _seedIfNeeded(
    List<ChannelEntry> channels,
    List<PMConversation> pms,
    List<Group> groups,
    bool pmOnly,
  ) {
    if (_seeded) return;
    _seeded = true;

    final saved = _loadLayout();
    if (saved != null && saved.isNotEmpty) {
      // PM-only mode allows no channel columns.
      _columns.addAll(
          pmOnly ? saved.where((d) => d.kind != _ColumnKind.channel) : saved);
    }
    final lock = ref.read(chatLockProvider);
    _columns.removeWhere((d) => lock.blocks(d.storageKey));

    if (_columns.isEmpty) {
      if (!pmOnly) {
        final nymchat = channels.firstWhere(
          (ch) => ch.key == kDefaultChannel,
          orElse: () => channels.isNotEmpty
              ? channels.first
              : ChannelEntry(channel: kDefaultChannel),
        );
        _columns.add(_ColumnDesc.channel(nymchat.channel, nymchat.geohash));
      }
      final openPms =
          pms.where((p) => !lock.blocks('pm-${p.pubkey.toLowerCase()}')).toList();
      if (openPms.isNotEmpty) {
        // Already most-recent-first.
        _columns.add(_ColumnDesc.pm(openPms.first.pubkey, nym: openPms.first.nym));
      }
      final openGroups = groups.where((g) => !lock.blocks('group-${g.id}')).toList();
      if (openGroups.isNotEmpty) {
        final g = [...openGroups]
          ..sort((a, b) => b.lastMessageTime - a.lastMessageTime);
        _columns.add(_ColumnDesc.group(g.first.id));
      }
      // Post-frame since seeding runs inside the first build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _saveLayout();
      });
    }

    // The primary column is the first channel column at enable time.
    for (final d in _columns) {
      if (d.kind == _ColumnKind.channel) {
        _primaryKey = d.key;
        break;
      }
    }
    for (final d in _columns) {
      _subscribeChannel(d);
    }
  }

  /// Subscribes a channel column without switching the shared view; post-frame because seeding runs during build.
  void _subscribeChannel(_ColumnDesc desc) {
    if (desc.kind != _ColumnKind.channel) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(nostrControllerProvider)
          .subscribeChannelColumn(desc.channel, geohash: desc.geohash);
    });
  }

  /// Read via the KV store directly since the constants file belongs to another slice.
  static const String _skipRemoveConfirmKey = 'nym_columns_skip_delete_confirm';

  /// Confirms removal with a persistable "Don't ask again" unless already skipped.
  Future<void> _removeColumn(_ColumnDesc desc) async {
    final idx = _columns.indexOf(desc);
    if (idx < 0) return;
    final kv = ref.read(keyValueStoreProvider);
    if (kv.getBool(_skipRemoveConfirmKey)) {
      _doRemoveColumn(desc);
      return;
    }
    final title = _columnTitle(context, desc);
    final res = await showAppConfirmWithCheckbox(
      context,
      tr('Remove the "{title}" column? You can add it back anytime.',
          {'title': title}),
      title: tr('Remove column'),
      okLabel: tr('Remove'),
      danger: true,
      checkboxLabel: tr("Don't ask again"),
    );
    if (!res.confirmed || !mounted) return;
    if (res.checked) kv.setBool(_skipRemoveConfirmKey, true);
    _doRemoveColumn(desc);
  }

  /// Focus moves only when the removed column was the focused one.
  void _doRemoveColumn(_ColumnDesc desc) {
    final idx = _columns.indexOf(desc);
    if (idx < 0) return;
    final wasFocused = idx == _focused;
    final focusedDesc = (_focused >= 0 && _focused < _columns.length)
        ? _columns[_focused]
        : null;
    setState(() {
      _columns.removeAt(idx);
      if (_columns.isEmpty) {
        _focused = 0;
      } else if (wasFocused) {
        _focused = math.min(idx, _columns.length - 1);
      } else if (focusedDesc != null) {
        final f = _columns.indexOf(focusedDesc);
        if (f >= 0) _focused = f;
      }
    });
    if (desc.key == _primaryKey) _primaryKey = null;
    // Drop the at-bottom flag so a later re-add starts pinned.
    if (!_columns.any((d) => d.storageKey == desc.storageKey)) {
      _atBottomByKey.remove(desc.storageKey);
    }
    _saveLayout();
    _syncPageController();
    // Re-point the shared header/composer only if the focused column was removed.
    if (wasFocused) _syncFocusedView();
  }

  /// Keeps focus pinned to the same column by identity.
  void _commitTabsReorder(int from, int to) {
    if (from < 0 || from >= _columns.length) return;
    if (to < 0 || to >= _columns.length || from == to) return;
    final focusedDesc = (_focused >= 0 && _focused < _columns.length)
        ? _columns[_focused]
        : null;
    setState(() {
      final moved = _columns.removeAt(from);
      _columns.insert(to, moved);
      if (focusedDesc != null) {
        final f = _columns.indexOf(focusedDesc);
        if (f >= 0) _focused = f;
      }
    });
    _saveLayout();
  }

  /// Focuses a clicked column, re-points the shared header/composer, and scrolls it fully into view.
  void _focusColumn(int index) {
    if (index < 0 || index >= _columns.length) return;
    if (_focused == index) return;
    setState(() => _focused = index);
    _revealColumn(index);
    _syncFocusedView();
  }

  ChatView _viewForDesc(_ColumnDesc d) {
    switch (d.kind) {
      case _ColumnKind.channel:
        return ChatView.channel(d.key);
      case _ColumnKind.pm:
        return ChatView.pm(d.pubkey);
      case _ColumnKind.group:
        return ChatView.group(d.groupId);
    }
  }

  /// Points the shared header/composer at the focused column; post-frame so it never mutates during build.
  void _syncFocusedView() {
    if (_columns.isEmpty) return;
    final idx = _focused.clamp(0, _columns.length - 1);
    final desc = _columns[idx];
    final view = _viewForDesc(desc);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(appStateProvider).view == view) {
        // Mark the refocused column read even when the view already points at it.
        _markColumnRead(desc);
        return;
      }
      _syncingFromDeck = true;
      if (desc.kind == _ColumnKind.channel) {
        // Channels go through `switchChannel` so geo relays and the single typing sub follow focus.
        ref
            .read(nostrControllerProvider)
            .switchChannel(desc.channel, geohash: desc.geohash);
      } else {
        ref.read(appStateProvider.notifier).switchView(view);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncingFromDeck = false;
      });
    });
  }

  /// Falls back to a bare descriptor when the channel isn't registered yet.
  _ColumnDesc _descForView(ChatView v) {
    switch (v.kind) {
      case ViewKind.channel:
        final channels = ref.read(channelsProvider);
        for (final ch in channels) {
          if (ch.key == v.id.toLowerCase()) {
            return _ColumnDesc.channel(ch.channel, ch.geohashKey);
          }
        }
        return isValidGeohash(v.id)
            ? _ColumnDesc.channel('', v.id)
            : _ColumnDesc.channel(v.id, '');
      case ViewKind.pm:
        final nym = ref.read(appStateProvider).users[v.id]?.nym ?? '';
        return _ColumnDesc.pm(v.id, nym: nym);
      case ViewKind.group:
        return _ColumnDesc.group(v.id);
    }
  }

  /// Outside view changes drive the deck: focus an existing column, repurpose the primary channel column, or add one.
  void _onExternalView(ChatView v) {
    // Ignore deck-driven switches and anything before seeding.
    if (_syncingFromDeck || !_seeded) return;
    // Globe geohash opens set `forceNew`, so they never repurpose the primary column.
    final forceNew =
        ref.read(appStateProvider.notifier).consumeForceNewColumnHint();
    final desc = _descForView(v);

    final existing = _columns.indexWhere((d) => d == desc);
    if (existing >= 0) {
      _scrollToIndex(existing);
      return;
    }

    // Once the primary column is closed, channels add new columns instead.
    if (!forceNew && v.kind == ViewKind.channel && _primaryKey != null) {
      final primary = _columns.indexWhere(
          (d) => d.key == _primaryKey && d.kind == _ColumnKind.channel);
      if (primary >= 0) {
        final oldDesc = _columns[primary];
        setState(() {
          _columns[primary] = desc;
          _focused = primary;
        });
        _primaryKey = desc.key;
        // A repurposed column starts at the bottom, so drop the old key's flag or a stale `false` wedges the read gate.
        if (!_columns.any((d) => d.storageKey == oldDesc.storageKey)) {
          _atBottomByKey.remove(oldDesc.storageKey);
        }
        _atBottomByKey.remove(desc.storageKey);
        _subscribeChannel(desc);
        _saveLayout();
        _scrollToIndex(primary);
        return;
      }
    }

    // The single choke point refusing channel columns in PM-only mode.
    if (desc.kind == _ColumnKind.channel &&
        ref.read(settingsProvider).groupChatPMOnlyMode) {
      return;
    }
    setState(() {
      _columns.add(desc);
      _focused = _columns.length - 1;
    });
    _subscribeChannel(desc);
    _saveLayout();
    _scrollToIndex(_columns.length - 1);
  }

  /// Navigates the carousel; does not reorder.
  void _stepFocused(int dir) {
    final to = _focused + dir;
    if (to < 0 || to >= _columns.length) return;
    _scrollToIndex(to);
  }

  /// Mobile snaps instantly; desktop smooth-scrolls only if the column is partly off-screen.
  void _scrollToIndex(int idx) {
    if (idx < 0 || idx >= _columns.length) return;
    if (_isMobile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients && _columns.isNotEmpty) {
          _pageController.jumpToPage(idx.clamp(0, _columns.length - 1));
        }
      });
    } else {
      _revealColumn(idx);
    }
    if (_focused != idx) setState(() => _focused = idx);
    _syncFocusedView();
  }

  /// Never nudges a fully visible column; post-frame so a column added this build is in the extent.
  void _revealColumn(int idx) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_stripScroll.hasClients) return;
      if (idx < 0 || idx >= _columns.length) return;
      final pos = _stripScroll.position;
      final left = _CvDimens.padding + idx * (_CvDimens.column + _CvDimens.gap);
      final right = left + _CvDimens.column;
      double? target;
      if (left < pos.pixels) {
        target = left - 12;
      } else if (right > pos.pixels + pos.viewportDimension) {
        target =
            right - pos.viewportDimension + 12;
      }
      if (target == null) return;
      _stripScroll.animateTo(
        target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
        duration: NymMotion.transition,
        curve: NymMotion.curve,
      );
    });
  }

  void _scrollStripToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_stripScroll.hasClients) return;
      _stripScroll.animateTo(
        _stripScroll.position.maxScrollExtent,
        duration: NymMotion.transition,
        curve: NymMotion.curve,
      );
    });
  }

  void _syncPageController() {
    if (!_isMobile || !_pageController.hasClients) return;
    final page = _pageController.page?.round() ?? 0;
    if (page != _focused && _focused < _columns.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients && _columns.isNotEmpty) {
          _pageController.jumpToPage(_focused.clamp(0, _columns.length - 1));
        }
      });
    }
  }

  bool get _isMobile {
    final w = MediaQuery.of(context).size.width;
    return w <= _CvDimens.mobileBreakpoint;
  }

  /// The drag starts only after 5px of travel, so a plain click just focuses.
  void _onColumnHeaderDown(
      int index, PointerDownEvent e, BuildContext boundaryContext) {
    if (_isMobile) return;
    if (e.buttons != kPrimaryButton) return;
    final box = boundaryContext.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final topLeft = box.localToGlobal(Offset.zero);
    _dragIndex = index;
    _dragActive = false;
    _dragStart = e.position;
    _grabOffset = Offset(
      e.position.dx - topLeft.dx,
      math.min(e.position.dy - topLeft.dy, 40.0),
    );
    _dragSize = box.size;
    _dragBoundary = boundaryContext;
  }

  void _onColumnHeaderMove(PointerMoveEvent e) {
    final idx = _dragIndex;
    if (idx == null || _isMobile) return;
    if (!_dragActive) {
      final d = e.position - _dragStart;
      if (d.dx.abs() < 5 && d.dy.abs() < 5) return;
      _dragActive = true;
      _ghostPos = e.position - _grabOffset;
      _insertGhost();
      _captureDragImage();
      setState(() {});
    }
    _ghostPos = e.position - _grabOffset;
    _dragGhostEntry?.markNeedsBuild();
    _updateDragTarget(e.position.dx);
  }

  /// A reorder never changes focus.
  void _onColumnHeaderUp() {
    if (_dragIndex == null) return;
    final wasActive = _dragActive;
    _removeGhost();
    _dragIndex = null;
    _dragActive = false;
    _dragBoundary = null;
    if (wasActive && mounted) {
      setState(() {});
      _saveLayout();
    }
  }

  /// Live reflow: the source column moves as the ghost crosses a neighbor's midpoint.
  void _updateDragTarget(double pointerX) {
    final from = _dragIndex;
    if (from == null || from >= _columns.length) return;
    if (!_stripScroll.hasClients) return;
    final stripBox = _stripKey.currentContext?.findRenderObject() as RenderBox?;
    if (stripBox == null) return;
    final originX =
        stripBox.localToGlobal(Offset.zero).dx - _stripScroll.offset;
    const span = _CvDimens.column + _CvDimens.gap;
    var insertAt = _columns.length - 1;
    var pos = 0;
    var found = false;
    for (var i = 0; i < _columns.length; i++) {
      if (i == from) continue;
      final mid = originX + _CvDimens.padding + i * span + _CvDimens.column / 2;
      if (pointerX < mid) {
        insertAt = pos;
        found = true;
        break;
      }
      pos++;
    }
    if (!found) insertAt = _columns.length - 1;
    if (insertAt == from) return;
    final focusedDesc = (_focused >= 0 && _focused < _columns.length)
        ? _columns[_focused]
        : null;
    setState(() {
      final moved = _columns.removeAt(from);
      _columns.insert(insertAt, moved);
      _dragIndex = insertAt;
      // Reorders never move focus; re-derive the focused index by identity.
      if (focusedDesc != null) {
        final f = _columns.indexOf(focusedDesc);
        if (f >= 0) _focused = f;
      }
    });
  }

  /// Until the async snapshot lands, the ghost shows a live widget clone.
  void _captureDragImage() {
    final ctx = _dragBoundary;
    if (ctx == null || !ctx.mounted) return;
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary) return;
    final ratio = MediaQuery.of(context).devicePixelRatio;
    ro.toImage(pixelRatio: ratio).then((img) {
      if (_dragActive && _dragGhostEntry != null) {
        _dragImage = img;
        _dragGhostEntry?.markNeedsBuild();
      } else {
        img.dispose();
      }
    }).catchError((_) {});
  }

  void _insertGhost() {
    if (_dragGhostEntry != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(builder: (ctx) {
      final light = ctx.nym.isLight;
      return Positioned(
        left: _ghostPos.dx,
        top: _ghostPos.dy,
        width: _dragSize.width,
        height: _dragSize.height,
        child: IgnorePointer(
          child: Opacity(
            opacity: 0.92,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: NymRadius.rmd,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: light ? 0.12 : 0.5),
                    offset: const Offset(0, 8),
                    blurRadius: 32,
                  ),
                ],
              ),
              child: _dragImage != null
                  ? ClipRRect(
                      borderRadius: NymRadius.rmd,
                      child: RawImage(image: _dragImage, fit: BoxFit.fill),
                    )
                  : Material(
                      type: MaterialType.transparency,
                      child: _buildGhostClone(),
                    ),
            ),
          ),
        ),
      );
    });
    overlay.insert(entry);
    _dragGhostEntry = entry;
  }

  Widget _buildGhostClone() {
    final idx = _dragIndex;
    if (idx == null || idx < 0 || idx >= _columns.length || !mounted) {
      return const SizedBox.shrink();
    }
    final desc = _columns[idx];
    final style = TextStyle(
      color: context.nym.secondary,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    );
    return _DeckColumn(
      desc: desc,
      titleWidget: _columnTitleWidget(context, desc, style),
      icon: _columnIcon(context, desc),
      focused: idx == _focused,
      transparent: false,
      mobile: false,
      index: idx,
      total: _columns.length,
      onClose: () {},
    );
  }

  void _removeGhost() {
    _dragGhostEntry?.remove();
    _dragGhostEntry = null;
    _dragImage?.dispose();
    _dragImage = null;
  }

  /// Channels (unless PM-only), then PMs, then groups, minus already-open columns.
  List<_PickerEntry> _availableRows(
    BuildContext context,
    List<ChannelEntry> channels,
    List<PMConversation> pms,
    List<Group> groups,
    bool pmOnly,
  ) {
    final open = _columns.toSet();
    final out = <_PickerEntry>[];
    if (!pmOnly) {
      for (final ch in channels) {
        final d = _ColumnDesc.channel(ch.channel, ch.geohashKey);
        if (open.contains(d)) continue;
        out.add((
          desc: d,
          label: '#${ch.geohashKey.isNotEmpty ? ch.geohashKey : ch.channel}',
          icon: _pickerRowIcon(context, d),
        ));
      }
    }
    for (final pm in pms) {
      final d = _ColumnDesc.pm(pm.pubkey, nym: pm.nym);
      if (open.contains(d)) continue;
      out.add((
        desc: d,
        label: pm.nym.isNotEmpty ? pm.nym : tr('Direct message'),
        icon: _pickerRowIcon(context, d),
      ));
    }
    for (final g in groups) {
      final d = _ColumnDesc.group(g.id);
      if (open.contains(d)) continue;
      out.add((
        desc: d,
        label: g.name.isNotEmpty ? g.name : tr('Group chat'),
        icon: _pickerRowIcon(context, d),
      ));
    }
    return out;
  }

  Widget _pickerRowIcon(BuildContext context, _ColumnDesc d) {
    final c = context.nym;
    final app = ref.read(appStateProvider);
    switch (d.kind) {
      case _ColumnKind.channel:
        return Text('#',
            style: TextStyle(color: c.textDim, fontSize: 13, height: 1));
      case _ColumnKind.pm:
        return NymAvatar(
          seed: d.pubkey,
          size: 20,
          imageUrl: app.users[d.pubkey]?.profile?.picture,
        );
      case _ColumnKind.group:
        final g = app.groups.where((g) => g.id == d.groupId).toList();
        final avatar = g.isNotEmpty ? g.first.avatar : null;
        if (avatar != null && avatar.isNotEmpty) {
          return NymAvatar(
            seed: _columnTitle(context, d),
            size: 20,
            imageUrl: avatar,
          );
        }
        return Text('◧',
            style: TextStyle(color: c.textDim, fontSize: 13, height: 1));
    }
  }

  /// Opens the column-shaped picker; on mobile it is the carousel's trailing page.
  void _openAddColumn() {
    if (_pickerOpen) return;
    setState(() => _pickerOpen = true);
    if (_isMobile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        _pageController.animateToPage(
          _columns.length,
          duration: NymMotion.transition,
          curve: NymMotion.curve,
        );
      });
    } else {
      _scrollStripToEnd();
    }
  }

  void _addPickedColumn(_ColumnDesc desc) {
    final existing = _columns.indexOf(desc);
    setState(() {
      _pickerOpen = false;
      if (existing >= 0) {
        _focused = existing;
      } else {
        _columns.add(desc);
        _focused = _columns.length - 1;
      }
    });
    if (existing < 0) {
      // The focused picked column re-points the typing sub through `switchChannel`.
      _subscribeChannel(desc);
      _saveLayout();
    }
    _scrollToIndex(_focused);
  }

  /// Tabs sheet; reorders and removals commit immediately, so dismissing never discards anything.
  Future<void> _openTabsView() async {
    // The PWA overlay has no transition, so this pops in and out instantly.
    final result = await showGeneralDialog<_TabsResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: tr('Columns'),
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: Duration.zero,
      pageBuilder: (ctx, _, _) => Material(
        type: MaterialType.transparency,
        child: _TabsSheet(
          columns: List<_ColumnDesc>.from(_columns),
          activeDesc: (_focused >= 0 && _focused < _columns.length)
              ? _columns[_focused]
              : null,
          titleOf: (d) => _columnTitleWidget(
            ctx,
            d,
            TextStyle(
              color: ctx.nym.secondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          iconOf: (d) => _columnIcon(ctx, d, size: 24),
          onReorder: _commitTabsReorder,
          onRemove: (d) async {
            await _removeColumn(d);
            return !_columns.contains(d);
          },
        ),
      ),
    );
    if (result == null || !mounted) return;
    switch (result.action) {
      case _TabsAction.select:
        final i = _columns.indexOf(result.desc!);
        if (i >= 0) _scrollToIndex(i);
      case _TabsAction.add:
        _openAddColumn();
    }
  }

  String _columnTitle(BuildContext context, _ColumnDesc d) =>
      _titleFromState(ref.read(appStateProvider), d);

  /// Pure so the title widget can watch exactly this value; PM nyms and group names change after build.
  static String _titleFromState(AppState app, _ColumnDesc d) {
    switch (d.kind) {
      case _ColumnKind.channel:
        return '#${d.geohash.isNotEmpty ? d.geohash : d.channel}';
      case _ColumnKind.pm:
        final conv =
            app.pmConversations.where((c) => c.pubkey == d.pubkey).toList();
        final nym = conv.isNotEmpty ? conv.first.nym : null;
        return (nym != null && nym.isNotEmpty)
            ? nym
            : (d.nym.isNotEmpty
                ? d.nym
                : (app.users[d.pubkey]?.nym ?? tr('Direct message')));
      case _ColumnKind.group:
        final g = app.groups.where((g) => g.id == d.groupId).toList();
        return (g.isNotEmpty && g.first.name.isNotEmpty)
            ? g.first.name
            : tr('Group chat');
    }
  }

  /// Rich column title with the PM `#suffix` and badges; channels and groups render bare.
  Widget _columnTitleWidget(
      BuildContext context, _ColumnDesc d, TextStyle style) {
    // A Consumer so the title subscribes to what it renders; the State's `ref.watch` is invalid here.
    return Consumer(builder: (context, ref, _) {
      final title = ref.watch(appStateProvider.select((s) => _titleFromState(s, d)));
      return _columnTitleContent(context, ref, d, style, title);
    });
  }

  Widget _columnTitleContent(BuildContext context, WidgetRef ref, _ColumnDesc d,
      TextStyle style, String title) {
    if (d.kind != _ColumnKind.pm || d.pubkey.isEmpty) {
      return Text(title,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    final base = stripPubkeySuffix(title);
    final suffix = getPubkeySuffix(d.pubkey);
    final controller = ref.read(nostrControllerProvider);
    final isDev = controller.isVerifiedDeveloper(d.pubkey);
    final isBot = !isDev && controller.isVerifiedBot(d.pubkey);
    // Watched so befriending or flair arrival repaints the header.
    final isFriend = ref.watch(
        appStateProvider.select((s) => s.friends.contains(d.pubkey)));
    final cosmetics = ref.watch(userCosmeticsProvider(d.pubkey));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text.rich(
            TextSpan(
              style: style,
              children: [
                TextSpan(text: base),
                if (suffix.isNotEmpty)
                  TextSpan(
                    text: '#$suffix',
                    style: style.copyWith(
                      color: style.color?.withValues(alpha: 0.7),
                      fontSize: (style.fontSize ?? 14) * 0.9,
                      fontWeight: FontWeight.w100,
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        CosmeticNymBadges(
          cosmetics: cosmetics,
          flairSize: 20,
          supporterHeight: 20,
        ),
        if (isDev || isBot) ...[
          const SizedBox(width: 4),
          VerifiedBadge(
            size: 20,
            tooltip: isDev ? tr('Nymchat Developer') : tr('Nymchat Bot'),
          ),
        ],
        if (isFriend) ...[
          const SizedBox(width: 4),
          const FriendBadge(size: 20),
        ],
      ],
    );
  }

  Widget _columnIcon(BuildContext context, _ColumnDesc d, {double size = 20}) {
    final c = context.nym;
    final app = ref.read(appStateProvider);
    switch (d.kind) {
      case _ColumnKind.channel:
        return Text(
          '#',
          style: TextStyle(
            color: c.textDim,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        );
      case _ColumnKind.pm:
        final u = app.users[d.pubkey];
        return NymAvatar(
          seed: d.pubkey,
          size: size,
          imageUrl: u?.profile?.picture,
        );
      case _ColumnKind.group:
        final g = app.groups.where((g) => g.id == d.groupId).toList();
        final avatar = g.isNotEmpty ? g.first.avatar : null;
        if (avatar != null && avatar.isNotEmpty) {
          return NymAvatar(
            seed: _columnTitle(context, d),
            size: size,
            imageUrl: avatar,
          );
        }
        return SizedBox(
          width: 16,
          height: 16,
          child: CustomPaint(painter: _GroupGlyphPainter(color: c.textDim)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final channels = ref.watch(channelsProvider);
    final pms = ref.watch(pmListProvider);
    final groups = ref.watch(groupsProvider);
    final pmOnly =
        ref.watch(settingsProvider.select((s) => s.groupChatPMOnlyMode));
    final transparentColumns =
        ref.watch(settingsProvider.select((s) => s.columnsWallpaper));
    _seedIfNeeded(channels, pms, groups, pmOnly);
    ref.listen<int>(chatLockRevisionProvider, (_, _) {
      final lock = ref.read(chatLockProvider);
      for (final d in List.of(_columns)) {
        if (lock.blocks(d.storageKey)) _doRemoveColumn(d);
      }
    });

    // The deck is the navigation sink in columns mode.
    ref.listen<ChatView>(
      appStateProvider.select((s) => s.view),
      (prev, next) => _onExternalView(next),
    );

    // Reset while mounted re-seeds live, like the PWA.
    ref.listen<int>(
      settingsProvider.select((s) => s.columnsResetTick),
      (prev, next) {
        if (prev != next) _onColumnsReset();
      },
    );

    if (_focused >= _columns.length) {
      _focused = _columns.isEmpty ? 0 : _columns.length - 1;
    }

    if (!_syncedInitialView && _columns.isNotEmpty) {
      _syncedInitialView = true;
      _syncFocusedView();
    }

    return Container(
      key: const Key('columnsStrip'),
      color: Colors.transparent,
      child: _isMobile
          ? _buildMobile(c, channels, pms, groups, pmOnly, transparentColumns)
          : _buildDesktop(c, channels, pms, groups, pmOnly, transparentColumns),
    );
  }

  Widget _buildDesktop(
    NymColors c,
    List<ChannelEntry> channels,
    List<PMConversation> pms,
    List<Group> groups,
    bool pmOnly,
    bool transparentColumns,
  ) {
    final titleStyle = TextStyle(
      color: c.secondary,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_columns.length > 1)
          _Pager(
            count: _columns.length,
            active: _focused,
            onTap: _openTabsView,
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: _CvDimens.padding),
            // Light mode's scrollbar thumb rule is more specific, so the thumb flips to black.
            child: ScrollbarTheme(
              data: ScrollbarThemeData(
                thickness: const WidgetStatePropertyAll(6),
                radius: const Radius.circular(10),
                trackColor: const WidgetStatePropertyAll(Colors.transparent),
                trackBorderColor:
                    const WidgetStatePropertyAll(Colors.transparent),
                thumbColor: WidgetStateProperty.resolveWith(
                  (states) => (c.isLight ? Colors.black : Colors.white)
                      .withValues(
                          alpha: states.contains(WidgetState.hovered)
                              ? 0.2
                              : 0.12),
                ),
              ),
              child: Scrollbar(
                controller: _stripScroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  key: _stripKey,
                  controller: _stripScroll,
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: _CvDimens.padding),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < _columns.length; i++) ...[
                        _DesktopColumnSlot(
                          key: ValueKey('cvcol_${_columns[i].key}'),
                          index: i,
                          total: _columns.length,
                          desc: _columns[i],
                          titleWidget: _columnTitleWidget(
                              context, _columns[i], titleStyle),
                          icon: _columnIcon(context, _columns[i]),
                          focused: i == _focused,
                          transparent: transparentColumns,
                          dimmed: _dragActive && _dragIndex == i,
                          onClose: () => _removeColumn(_columns[i]),
                          onFocus: () => _focusColumn(i),
                          onDragDown: (e, boundaryCtx) =>
                              _onColumnHeaderDown(i, e, boundaryCtx),
                          onDragMove: _onColumnHeaderMove,
                          onDragEnd: _onColumnHeaderUp,
                          onAtBottomChanged: _atBottomHandlerFor(_columns[i]),
                        ),
                        const SizedBox(width: _CvDimens.gap),
                      ],
                      if (_pickerOpen)
                        _PickerColumn(
                          rows: _availableRows(
                              context, channels, pms, groups, pmOnly),
                          onPick: _addPickedColumn,
                          onClose: () => setState(() => _pickerOpen = false),
                        )
                      else
                        _AddColumnButton(
                          c: c,
                          width: _CvDimens.addColumn,
                          onTap: _openAddColumn,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMobile(
    NymColors c,
    List<ChannelEntry> channels,
    List<PMConversation> pms,
    List<Group> groups,
    bool pmOnly,
    bool transparentColumns,
  ) {
    final pageCount = _columns.length + 1;
    return PageView.builder(
      controller: _pageController,
      // No touch paging between columns (as in the PWA), freeing horizontal drags for row swipes.
      physics: const NeverScrollableScrollPhysics(),
      itemCount: pageCount,
      onPageChanged: (i) {
        if (i < _columns.length && i != _focused) {
          setState(() => _focused = i);
          _syncFocusedView();
        }
      },
      itemBuilder: (context, i) {
        if (i >= _columns.length) {
          // On mobile the picker is the trailing full snap page.
          if (_pickerOpen) {
            return _PickerColumn(
              mobile: true,
              rows: _availableRows(context, channels, pms, groups, pmOnly),
              onPick: _addPickedColumn,
              onClose: () => setState(() => _pickerOpen = false),
            );
          }
          return _AddColumnButton(
            c: c,
            width: double.infinity,
            onTap: _openAddColumn,
          );
        }
        final desc = _columns[i];
        return _MobileColumn(
          index: i,
          total: _columns.length,
          desc: desc,
          transparent: transparentColumns,
          onClose: () => _removeColumn(desc),
          onPrev: () => _stepFocused(-1),
          onNext: () => _stepFocused(1),
          onOpenTabs: _openTabsView,
          onAtBottomChanged: _atBottomHandlerFor(desc),
        );
      },
    );
  }
}

/// Desktop column slot: a [Listener] focuses on any click, bypassing the rows' gesture recognizers.
class _DesktopColumnSlot extends StatefulWidget {
  const _DesktopColumnSlot({
    super.key,
    required this.index,
    required this.total,
    required this.desc,
    required this.titleWidget,
    required this.icon,
    required this.focused,
    required this.transparent,
    required this.dimmed,
    required this.onClose,
    required this.onFocus,
    required this.onDragDown,
    required this.onDragMove,
    required this.onDragEnd,
    this.onAtBottomChanged,
  });

  final int index;
  final int total;
  final _ColumnDesc desc;
  final Widget titleWidget;
  final Widget icon;
  final bool focused;
  final bool transparent;

  final bool dimmed;
  final VoidCallback onClose;
  final VoidCallback onFocus;

  final void Function(PointerDownEvent event, BuildContext boundaryContext)
      onDragDown;
  final void Function(PointerMoveEvent event) onDragMove;
  final VoidCallback onDragEnd;

  final ValueChanged<bool>? onAtBottomChanged;

  @override
  State<_DesktopColumnSlot> createState() => _DesktopColumnSlotState();
}

class _DesktopColumnSlotState extends State<_DesktopColumnSlot> {
  final GlobalKey _boundaryKey = GlobalKey();

  /// True while a pointer-down started on the close button, so closing never focuses the column first.
  bool _closePressed = false;

  @override
  Widget build(BuildContext context) {
    final column = _DeckColumn(
      desc: widget.desc,
      titleWidget: widget.titleWidget,
      icon: widget.icon,
      focused: widget.focused,
      transparent: widget.transparent,
      mobile: false,
      index: widget.index,
      total: widget.total,
      onClose: widget.onClose,
      // The deepest Listener sees the pointer first, flagging it before the focus Listener.
      onCloseDown: () => _closePressed = true,
      onHeaderDown: (e) {
        final ctx = _boundaryKey.currentContext;
        if (ctx != null) widget.onDragDown(e, ctx);
      },
      onHeaderMove: widget.onDragMove,
      onHeaderUp: widget.onDragEnd,
      onAtBottomChanged: widget.onAtBottomChanged,
    );

    // Any click focuses the column, except on the close button.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (_closePressed) {
          _closePressed = false;
          return;
        }
        widget.onFocus();
      },
      child: AnimatedOpacity(
        duration: NymMotion.transition,
        curve: NymMotion.curve,
        opacity: widget.dimmed ? 0.4 : 1.0,
        child: RepaintBoundary(key: _boundaryKey, child: column),
      ),
    );
  }
}

class _MobileColumn extends StatelessWidget {
  const _MobileColumn({
    required this.index,
    required this.total,
    required this.desc,
    required this.transparent,
    required this.onClose,
    required this.onPrev,
    required this.onNext,
    required this.onOpenTabs,
    this.onAtBottomChanged,
  });

  final int index;
  final int total;
  final _ColumnDesc desc;
  final bool transparent;
  final VoidCallback onClose;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onOpenTabs;

  final ValueChanged<bool>? onAtBottomChanged;

  @override
  Widget build(BuildContext context) {
    return _DeckColumn(
      desc: desc,
      titleWidget: const SizedBox.shrink(),
      icon: const SizedBox.shrink(),
      focused: false,
      transparent: transparent,
      mobile: true,
      index: index,
      total: total,
      onClose: onClose,
      onPrev: onPrev,
      onNext: onNext,
      onOpenTabs: onOpenTabs,
      onAtBottomChanged: onAtBottomChanged,
    );
  }
}

class _DeckColumn extends ConsumerStatefulWidget {
  const _DeckColumn({
    required this.desc,
    required this.titleWidget,
    required this.icon,
    required this.focused,
    required this.transparent,
    required this.mobile,
    required this.index,
    required this.total,
    required this.onClose,
    this.onCloseDown,
    this.onPrev,
    this.onNext,
    this.onOpenTabs,
    this.onHeaderDown,
    this.onHeaderMove,
    this.onHeaderUp,
    this.onAtBottomChanged,
  });

  final _ColumnDesc desc;
  final Widget titleWidget;
  final Widget icon;

  final bool focused;
  final bool transparent;
  final bool mobile;
  final int index;
  final int total;
  final VoidCallback onClose;

  /// Fired before the slot's click-to-focus Listener sees the event.
  final VoidCallback? onCloseDown;

  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  final VoidCallback? onOpenTabs;

  /// Raw pointer plumbing over the header drag region, which excludes the close button.
  final void Function(PointerDownEvent event)? onHeaderDown;
  final void Function(PointerMoveEvent event)? onHeaderMove;
  final VoidCallback? onHeaderUp;

  /// Reports at-bottom transitions for the deck's read gate.
  final ValueChanged<bool>? onAtBottomChanged;

  @override
  ConsumerState<_DeckColumn> createState() => _DeckColumnState();
}

class _DeckColumnState extends ConsumerState<_DeckColumn> {
  /// Lets a quote tap jump this column to an off-screen message.
  final ItemScrollController _itemScroll = ItemScrollController();
  final ItemPositionsListener _positions = ItemPositionsListener.create();
  final AnchoredUnits _anchors = AnchoredUnits();
  late final ListAnchorKeeper _keeper =
      ListAnchorKeeper(controller: _itemScroll, units: _anchors);
  Map<int, String> _unitByIndex = const {};
  _ColumnGroups? _groups;
  int _seenScrolls = 0;
  bool _listBuilt = false;
  ({String unit, double alignment})? _restore;
  static const double _bottomInset = 10;

  double _viewportHeight = 0;
  bool _atBottom = true;
  bool _showScrollButton = false;

  /// Detects appended messages for autoscroll.
  int _lastMessageCount = 0;

  late final ChatNavListBinding _nav = ChatNavListBinding(ref, _positions);
  late final ChatNavService _navService;
  String? _navBreak;

  @override
  void initState() {
    super.initState();
    _positions.itemPositions.addListener(_onPositionsChanged);
    _navService = ref.read(chatNavProvider);
  }

  @override
  void didUpdateWidget(covariant _DeckColumn old) {
    super.didUpdateWidget(old);
    if (old.desc.storageKey != widget.desc.storageKey) {
      _navService.release(old.desc.storageKey);
      // A repurposed column re-renders pinned to the newest message.
      _lastMessageCount = 0;
      _atBottom = true;
      _showScrollButton = false;
      _restore = null;
      _groups = null;
      _keeper.reset();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_itemScroll.isAttached) {
          _itemScroll.jumpTo(index: 0);
          _keeper.reset(target: 0);
        }
        widget.onAtBottomChanged?.call(true);
      });
    }
  }

  @override
  void dispose() {
    _positions.itemPositions.removeListener(_onPositionsChanged);
    _navService.release(widget.desc.storageKey);
    _nav.dispose();
    super.dispose();
  }

  /// At-bottom at <120px and the scroll button at >150px; index 0's edge rests 10px inside the viewport.
  void _onPositionsChanged() {
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty) return;
    _nav.update();
    ItemPosition? newest;
    for (final p in positions) {
      if (p.index == 0) {
        newest = p;
        break;
      }
    }
    final double distanceFromBottom;
    if (newest == null) {
      distanceFromBottom = 100000;
    } else if (_viewportHeight <= 0) {
      distanceFromBottom = 0;
    } else {
      distanceFromBottom = 10 - newest.itemLeadingEdge * _viewportHeight;
    }
    final atBottom = distanceFromBottom < 120;
    final showButton = distanceFromBottom > 150;
    if (atBottom != _atBottom) widget.onAtBottomChanged?.call(atBottom);
    if (atBottom != _atBottom || showButton != _showScrollButton) {
      setState(() {
        _atBottom = atBottom;
        _showScrollButton = showButton;
      });
    }
  }

  void _scrollToBottom() {
    if (!_itemScroll.isAttached) return;
    ref
        .read(messageListScrollerProvider(widget.desc.storageKey))
        .animateTo(index: 0, alignment: 0);
  }

  List<Message> _messagesNow(AppState app) {
    var messages = visibleMessagesFor(app, widget.desc.storageKey);
    if (widget.desc.storageKey == BotChatController.conversationKey) {
      messages = mergeBotThreadWithInfo(
          messages, ref.read(botChatControllerProvider).infoMessages);
    }
    return messages;
  }

  _ColumnGroups _groupsFor(
      AppState app, Settings settings, List<Message> messages) {
    final mentionToken = '@${_baseNym(app.selfNym)}';
    final cached = _groups;
    if (cached != null &&
        cached.rev == app.displayRev &&
        cached.count == messages.length &&
        cached.mentionToken == mentionToken &&
        cached.useBubbles == settings.useBubbles &&
        cached.breakBefore == _navBreak) {
      return cached;
    }
    final groups = buildMessageGroups(
      messages,
      reactions: app.reactions,
      useBubbles: settings.useBubbles,
      mentionToken: mentionToken,
      breakBefore: _navBreak,
    );
    final indexById = <String, int>{};
    final indexByUnit = <String, int>{};
    final unitByIndex = <int, String>{};
    for (var f = 0; f < groups.length; f++) {
      final revIndex = groups.length - 1 - f;
      for (final e in groups[f]) {
        indexById[e.message.id] = revIndex;
      }
      final unit = 'cvgroup_${groups[f].first.message.id}';
      indexByUnit[unit] = revIndex;
      unitByIndex[revIndex] = unit;
    }
    return _groups = _ColumnGroups(
      rev: app.displayRev,
      count: messages.length,
      mentionToken: mentionToken,
      useBubbles: settings.useBubbles,
      breakBefore: _navBreak,
      groups: groups,
      indexById: indexById,
      indexByUnit: indexByUnit,
      unitByIndex: unitByIndex,
    );
  }

  void _keepAnchor() {
    if (!mounted ||
        !_listBuilt ||
        !_itemScroll.isAttached ||
        _viewportHeight <= 0) {
      return;
    }
    final scroller =
        ref.read(messageListScrollerProvider(widget.desc.storageKey));
    if (scroller.scrollCount != _seenScrolls) {
      _seenScrolls = scroller.scrollCount;
      _keeper.reset();
    }
    if (scroller.animating) return;
    final app = ref.read(appStateProvider);
    final built =
        _groupsFor(app, ref.read(settingsProvider), _messagesNow(app));
    final positions = _positions.itemPositions.value;
    ItemPosition? newest;
    for (final p in positions) {
      if (p.index == 0) {
        newest = p;
        break;
      }
    }
    final follow = newest != null &&
        _bottomInset - newest.itemLeadingEdge * _viewportHeight < 120;
    final old = _unitByIndex;
    _keeper.keep(
      positions: positions,
      unitAt: (index) => old[index],
      indexOf: (unit) => built.indexByUnit[unit],
      viewportHeight: _viewportHeight,
      bottomInset: _bottomInset,
      follow: follow,
    );
  }

  void _rememberForThread() {
    if (!_listBuilt || _viewportHeight <= 0) return;
    ItemPosition? nearest;
    for (final p in _positions.itemPositions.value) {
      if (nearest == null || p.itemLeadingEdge < nearest.itemLeadingEdge) {
        nearest = p;
      }
    }
    if (nearest == null) return;
    if (nearest.index == 0 && nearest.itemLeadingEdge >= -0.01) {
      _restore = null;
      return;
    }
    final unit = _unitByIndex[nearest.index];
    if (unit == null) return;
    var alignment = _anchors.edgeOf(unit) ?? nearest.itemLeadingEdge;
    if (nearest.index == 0) alignment -= _bottomInset / _viewportHeight;
    _restore = (unit: unit, alignment: alignment);
  }

  ({int index, double alignment})? _takeRestore(
      Map<String, int> indexByUnit) {
    final restore = _restore;
    _restore = null;
    if (restore == null) return null;
    final index = indexByUnit[restore.unit];
    if (index == null) return null;
    return (index: index, alignment: restore.alignment);
  }

  bool _onScroll(ScrollNotification n) {
    _keeper.observe(n);
    if ((n is ScrollUpdateNotification && n.dragDetails != null) ||
        n is UserScrollNotification) {
      _nav.userScrolled();
    }
    if (n is ScrollEndNotification &&
        _keeper.pending &&
        !_keeper.retargeting) {
      _keeper.pending = false;
      _keepAnchor();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final transparent = widget.transparent;
    final mobile = widget.mobile;
    final settings = ref.watch(settingsProvider);
    ref.listen(appStateProvider.select((s) => s.displayRev),
        (_, _) => _keepAnchor());
    ref.listen(activeThreadProvider, (prev, next) {
      final key = widget.desc.storageKey;
      if (next != null &&
          next.view.storageKey == key &&
          (prev == null || prev.view.storageKey != key)) {
        _rememberForThread();
      }
    });
    // Rebuild on display revision and self-nym only, not every ambient emit.
    ref.watch(appStateProvider.select((s) => (s.displayRev, s.selfNym)));
    final app = ref.read(appStateProvider);
    // Columns use the same filtered view as the single chat (blocked users, keywords, spam).
    var messages = visibleMessagesFor(app, widget.desc.storageKey);
    // Merge the bot engine's local-only info bubbles, which never enter the shared store.
    if (widget.desc.storageKey == BotChatController.conversationKey) {
      messages = mergeBotThreadWithInfo(
          messages, ref.watch(botChatControllerProvider).infoMessages);
    }

    // Autoscroll new messages while at bottom, unless `settings.autoscroll` is off.
    if (messages.length != _lastMessageCount) {
      final added = messages.length > _lastMessageCount;
      _lastMessageCount = messages.length;
      if (added && settings.autoscroll && _atBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _atBottom && _itemScroll.isAttached) {
            _itemScroll.jumpTo(index: 0);
            _keeper.reset(target: 0);
          }
        });
      }
    }

    // An open thread for this conversation swaps the list for the in-place ThreadView.
    final activeThread = ref.watch(activeThreadProvider);
    final threadOpen = activeThread != null &&
        appThreadsEnabled &&
        activeThread.view.storageKey == widget.desc.storageKey;

    final showFocus = widget.focused && !mobile;
    if (threadOpen || messages.isEmpty) _listBuilt = false;

    final body = AnimatedContainer(
      duration: NymMotion.transition,
      curve: NymMotion.curve,
      decoration: BoxDecoration(
        // The columns wallpaper clears only backgrounds; border, shadow and glass header remain.
        color: transparent ? Colors.transparent : c.bgSecondary,
        borderRadius: mobile ? null : NymRadius.rmd,
        border: mobile
            ? null
            : Border.all(color: showFocus ? c.primary : c.glassBorder),
        boxShadow: showFocus
            ? [BoxShadow(color: c.primaryA(0.1), blurRadius: 20)]
            : mobile
                ? null
                : [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: c.isLight ? 0.1 : 0.4),
                      offset: const Offset(0, 4),
                      blurRadius: 16,
                    ),
                  ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildHeader(c, mobile),
          Expanded(
            child: threadOpen
                ? ThreadView(
                    key: ValueKey(activeThread),
                    thread: activeThread,
                    showTyping: false)
                : ColoredBox(
              color: transparent
                  ? Colors.transparent
                  : (c.isLight
                      ? const Color(0x4DFFFFFF)
                      : const Color(0x26000000)),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: messages.isEmpty
                        // Shimmer then empty note, keyed on the storage key so re-pointing replays it.
                        ? _DeckEmptyOrLoading(
                            key: ValueKey('cvempty_${widget.desc.storageKey}'),
                            useBubbles: settings.useBubbles,
                            emptyNote: _emptyNoteText(),
                          )
                        : Builder(builder: (context) {
                            // Same MessageGroup path as the single view, so bubble columns get the gliding group avatar.
                            _navBreak = _nav.prepare(
                                widget.desc.storageKey, messages);
                            final built =
                                _groupsFor(app, settings, messages);
                            final groups = built.groups;
                            final scroller = ref.read(
                                messageListScrollerProvider(
                                    widget.desc.storageKey));
                            scroller.bind(_itemScroll, built.indexById);
                            _nav.bind(built.indexById, groups.length - 1);
                            _nav.observeLive(messages,
                                away: !_atBottom ||
                                    !ref
                                        .read(appStateProvider.notifier)
                                        .appVisible);
                            _nav.afterBuild(scroller);
                            _unitByIndex = built.unitByIndex;
                            final restore = _listBuilt
                                ? null
                                : _takeRestore(built.indexByUnit);
                            if (!_listBuilt) {
                              _listBuilt = true;
                              _seenScrolls = scroller.scrollCount;
                              _keeper.reset(
                                target: restore?.index ?? 0,
                                anchorUnit: restore == null
                                    ? null
                                    : built.unitByIndex[restore.index],
                              );
                            }
                            return LayoutBuilder(
                                builder: (context, constraints) {
                              _viewportHeight = constraints.maxHeight;
                              return NotificationListener<ScrollNotification>(
                                onNotification: _onScroll,
                                child: ScrollablePositionedList.builder(
                                itemScrollController: _itemScroll,
                                itemPositionsListener: _positions,
                                reverse: true,
                                initialScrollIndex: restore?.index ?? 0,
                                initialAlignment: restore?.alignment ?? 0,
                                padding: const EdgeInsets.all(10),
                                itemCount: groups.length,
                                itemBuilder: (context, revIndex) {
                                  final entries =
                                      groups[groups.length - 1 - revIndex];
                                  final unitId = built.unitByIndex[revIndex]!;
                                  // Per-row RepaintBoundary, keyed by the group's lead id so appends don't restart snap-in animations.
                                  final group = MessageGroup(
                                      entries: entries,
                                      settings: settings,
                                      columnsMode: true,
                                      // Jump within this column on a quote tap.
                                      scrollKey: widget.desc.storageKey,
                                      onReactionPicker: (msg) =>
                                          showReactionPicker(context, ref, msg),
                                      trailingFor: widget.desc.storageKey == BotChatController.conversationKey
                                          ? (m) => botRunTrailing(m, context.nym)
                                          : null,
                                    );
                                  return RepaintBoundary(
                                    key: ValueKey(unitId),
                                    child: AnchoredUnit(
                                      id: unitId,
                                      units: _anchors,
                                      child: _navBreak != null &&
                                              entries.first.message.id ==
                                                  _navBreak
                                          ? Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                const ChatNavDivider(),
                                                group,
                                              ],
                                            )
                                          : group,
                                    ),
                                  );
                                },
                              ),
                              );
                            });
                          }),
                  ),
                  if (_showScrollButton && messages.isNotEmpty)
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: _ScrollBottomButton(onTap: _scrollToBottom),
                    ),
                  if (messages.isNotEmpty)
                    Positioned(
                      right: 14,
                      bottom: _showScrollButton ? 62 : 16,
                      child: ChatNavFabs(binding: _nav),
                    ),
                ],
              ),
            ),
          ),
          TypingIndicatorRow(storageKey: widget.desc.storageKey),
        ],
      ),
    );

    return mobile ? body : SizedBox(width: _CvDimens.column, child: body);
  }

  /// Columns always use the generic empty note, not the single view's channel-specific one.
  String _emptyNoteText() => tr('No recent messages');

  String _baseNym(String nym) => splitNymSuffix(nym).base;

  /// Desktop: grip, icon, title (drag region) and close; mobile: dots, prev/next arrows and close.
  Widget _buildHeader(NymColors c, bool mobile) {
    final children = <Widget>[];

    if (mobile) {
      children.add(Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onOpenTabs,
          child: SizedBox(
            height: 20,
            child: _HeaderDots(count: widget.total, active: widget.index),
          ),
        ),
      ));
      children.add(const SizedBox(width: 8));
      children.add(_HeaderIconButton(
        svg: NymIcons.chevronLeft,
        tooltip: tr('Previous column'),
        enabled: widget.index > 0,
        onTap: widget.onPrev,
      ));
      children.add(const SizedBox(width: 8));
      children.add(_HeaderIconButton(
        svg: NymIcons.chevronRight,
        tooltip: tr('Next column'),
        enabled: widget.index < widget.total - 1,
        onTap: widget.onNext,
      ));
      children.add(const SizedBox(width: 8));
      children.add(_buildCloseButton(c));
      return _headerContainer(c, Row(children: children));
    }

    children.add(_DragHandle(color: c.textDim));
    children.add(const SizedBox(width: 8));
    children.add(widget.icon);
    children.add(const SizedBox(width: 8));
    children.add(Expanded(child: widget.titleWidget));

    Widget dragRegion = Row(children: children);
    if (widget.onHeaderDown != null) {
      // Raw listener (no gesture arena) so the deck can run its 5px-threshold drag.
      dragRegion = Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: widget.onHeaderDown,
        onPointerMove: widget.onHeaderMove,
        onPointerUp: (_) => widget.onHeaderUp?.call(),
        onPointerCancel: (_) => widget.onHeaderUp?.call(),
        child: dragRegion,
      );
    }
    dragRegion = MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: dragRegion,
    );

    return _headerContainer(
      c,
      Row(
        children: [
          Expanded(child: dragRegion),
          const SizedBox(width: 8),
          _buildCloseButton(c),
        ],
      ),
    );
  }

  Widget _buildCloseButton(NymColors c) {
    Widget btn = _HoverCloseButton(
      tooltip: tr('Remove column'),
      size: 16,
      hoverColor: c.danger,
      onTap: widget.onClose,
    );
    final down = widget.onCloseDown;
    if (down != null) {
      // Deeper Listeners see the pointer first, so this fires before the slot's focus Listener.
      btn = Listener(onPointerDown: (_) => down(), child: btn);
    }
    return btn;
  }

  /// Stays glass under the columns wallpaper.
  Widget _headerContainer(NymColors c, Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: child,
    );
  }
}

/// Empty-column shimmer settling into the empty note after about 3s; same flow as the single view.
class _DeckEmptyOrLoading extends StatefulWidget {
  const _DeckEmptyOrLoading({
    super.key,
    required this.useBubbles,
    required this.emptyNote,
  });

  final bool useBubbles;

  final String emptyNote;

  @override
  State<_DeckEmptyOrLoading> createState() => _DeckEmptyOrLoadingState();
}

class _DeckEmptyOrLoadingState extends State<_DeckEmptyOrLoading> {
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

class _DragHandle extends StatefulWidget {
  const _DragHandle({required this.color});
  final Color color;

  @override
  State<_DragHandle> createState() => _DragHandleState();
}

class _DragHandleState extends State<_DragHandle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SizedBox(
        width: 14,
        height: 14,
        child: CustomPaint(
          painter: _SixDotPainter(
            color: _hover ? c.textBright : widget.color,
          ),
        ),
      ),
    );
  }
}

class _SixDotPainter extends CustomPainter {
  _SixDotPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final sx = size.width / 24, sy = size.height / 24;
    const r = 1.4;
    for (final cx in [9.0, 15.0]) {
      for (final cy in [6.0, 12.0, 18.0]) {
        canvas.drawCircle(Offset(cx * sx, cy * sy), r * sx, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_SixDotPainter old) => old.color != color;
}

class _GroupGlyphPainter extends CustomPainter {
  _GroupGlyphPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset p(double x, double y) => Offset(x * s, y * s);

    canvas.drawCircle(p(12, 7), 2.75 * s, paint);
    final centre = Path()
      ..moveTo(5 * s, 21 * s)
      ..relativeLineTo(0, -1.5 * s)
      ..arcToPoint(p(19, 19.5), radius: Radius.circular(7 * s), clockwise: true)
      ..lineTo(19 * s, 21 * s);
    canvas.drawPath(centre, paint);

    canvas.drawCircle(p(4.5, 9.5), 2 * s, paint);
    final left = Path()
      ..moveTo(1 * s, 20 * s)
      ..relativeLineTo(0, -1 * s)
      ..relativeArcToPoint(p(5.5, -4.35),
          radius: Radius.circular(4.5 * s), clockwise: true);
    canvas.drawPath(left, paint);

    canvas.drawCircle(p(19.5, 9.5), 2 * s, paint);
    final right = Path()
      ..moveTo(23 * s, 20 * s)
      ..relativeLineTo(0, -1 * s)
      ..relativeArcToPoint(p(-5.5, -4.35),
          radius: Radius.circular(4.5 * s), clockwise: false);
    canvas.drawPath(right, paint);
  }

  @override
  bool shouldRepaint(_GroupGlyphPainter old) => old.color != color;
}

class _HeaderDots extends StatelessWidget {
  const _HeaderDots({required this.count, required this.active});
  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    i == active ? c.primary : c.textDim.withValues(alpha: 0.4),
              ),
            ),
        ],
      ),
    );
  }
}

/// Mobile prev/next arrow; never dimmed at the ends, where taps silently no-op.
class _HeaderIconButton extends StatefulWidget {
  const _HeaderIconButton({
    required this.svg,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final String svg;
  final String tooltip;

  /// Gates the tap only; the visual state never changes.
  final bool enabled;
  final VoidCallback? onTap;

  @override
  State<_HeaderIconButton> createState() => _HeaderIconButtonState();
}

class _HeaderIconButtonState extends State<_HeaderIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final color = _hover ? c.textBright : c.textDim;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: NymSvgIcon(widget.svg, size: 16, color: color),
          ),
        ),
      ),
    );
  }
}

/// Desktop pager dots above the strip; opens the tabs view; shown only for more than one column.
class _Pager extends StatefulWidget {
  const _Pager(
      {required this.count, required this.active, required this.onTap});
  final int count;
  final int active;
  final VoidCallback onTap;

  @override
  State<_Pager> createState() => _PagerState();
}

class _PagerState extends State<_Pager> {
  bool _hover = false;

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
        child: Tooltip(
          message: tr('Switch columns'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // On pager hover every dot, including the active one, dims to 0.7 (CSS specificity).
                for (var i = 0; i < widget.count; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.ease,
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (i == widget.active ? c.primary : c.textDim)
                          .withValues(
                              alpha: _hover
                                  ? 0.7
                                  : (i == widget.active ? 1.0 : 0.4)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HoverCloseButton extends StatefulWidget {
  const _HoverCloseButton({
    required this.onTap,
    required this.hoverColor,
    this.size = 16,
    this.padding = const EdgeInsets.all(2),
    this.tooltip,
  });

  final VoidCallback onTap;
  final Color hoverColor;
  final double size;
  final EdgeInsets padding;
  final String? tooltip;

  @override
  State<_HoverCloseButton> createState() => _HoverCloseButtonState();
}

class _HoverCloseButtonState extends State<_HoverCloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final target = _hover ? widget.hoverColor : c.textDim;
    Widget button = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: widget.padding,
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: target),
            duration: NymMotion.transition,
            curve: NymMotion.curve,
            builder: (context, color, _) => NymSvgIcon(
              NymIcons.close,
              size: widget.size,
              color: color ?? target,
            ),
          ),
        ),
      ),
    );
    final t = widget.tooltip;
    if (t != null && t.isNotEmpty) {
      button = Tooltip(message: t, child: button);
    }
    return button;
  }
}

/// In-strip add-column panel; with [mobile] it is a full carousel page.
class _PickerColumn extends StatelessWidget {
  const _PickerColumn({
    required this.rows,
    required this.onPick,
    required this.onClose,
    this.mobile = false,
  });

  final List<_PickerEntry> rows;
  final ValueChanged<_ColumnDesc> onPick;
  final VoidCallback onClose;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: mobile ? null : _CvDimens.column,
      clipBehavior: Clip.antiAlias,
      decoration: mobile
          ? BoxDecoration(color: c.bgSecondary)
          : BoxDecoration(
              color: c.bgSecondary,
              borderRadius: NymRadius.rmd,
              border: Border.all(color: c.glassBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: c.isLight ? 0.1 : 0.4),
                  offset: const Offset(0, 4),
                  blurRadius: 16,
                ),
              ],
            ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: c.glassBg,
              border: Border(bottom: BorderSide(color: c.glassBorder)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Add a column'),
                    style: TextStyle(
                      color: c.secondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _HoverCloseButton(
                  tooltip: tr('Cancel'),
                  size: 16,
                  hoverColor: c.danger,
                  onTap: onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: _PickerBody(rows: rows, onPick: onPick),
          ),
        ],
      ),
    );
  }
}

/// The input grabs focus 30ms after opening.
class _PickerBody extends StatefulWidget {
  const _PickerBody({
    required this.rows,
    required this.onPick,
  });

  final List<_PickerEntry> rows;
  final ValueChanged<_ColumnDesc> onPick;

  @override
  State<_PickerBody> createState() => _PickerBodyState();
}

class _PickerBodyState extends State<_PickerBody> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _focusTimer;
  String _term = '';

  @override
  void initState() {
    super.initState();
    _focusTimer = Timer(const Duration(milliseconds: 30), () {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusTimer?.cancel();
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final f = _term.trim().toLowerCase();
    final shown = f.isEmpty
        ? widget.rows
        : widget.rows.where((r) => r.label.toLowerCase().contains(f)).toList();

    final search = Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: TextField(
        controller: _ctrl,
        focusNode: _focusNode,
        style: TextStyle(color: c.inputText, fontSize: 14),
        cursorColor: c.isLight ? Colors.black : Colors.white,
        onChanged: (v) => setState(() => _term = v),
        decoration: InputDecoration(
          isDense: true,
          hintText: tr('Search conversations…'),
          hintStyle: TextStyle(color: c.textDim, fontSize: 14),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          filled: true,
          fillColor: c.insetFill,
          border: OutlineInputBorder(
            borderRadius: NymRadius.rxs,
            borderSide: BorderSide(color: c.glassBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: NymRadius.rxs,
            borderSide: BorderSide(color: c.glassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: NymRadius.rxs,
            borderSide: BorderSide(color: c.primaryA(0.30)),
          ),
        ),
      ),
    );

    final Widget list = shown.isEmpty
        ? Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                tr('No conversations'),
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textDim, fontSize: 12),
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(6),
            children: [
              for (final r in shown)
                _PickerRow(
                  icon: r.icon,
                  label: r.label,
                  onTap: () => widget.onPick(r.desc),
                ),
            ],
          );

    return Column(children: [search, Expanded(child: list)]);
  }
}

class _PickerRow extends StatefulWidget {
  const _PickerRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Widget icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_PickerRow> createState() => _PickerRowState();
}

class _PickerRowState extends State<_PickerRow> {
  bool _hover = false;

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
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: NymRadius.rxs,
            color: _hover
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.transparent,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Center(child: widget.icon),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.text, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reorders and removals commit live, so only select/add round-trip.
enum _TabsAction { select, add }

class _TabsResult {
  const _TabsResult.select(this.desc) : action = _TabsAction.select;
  const _TabsResult.add()
      : action = _TabsAction.add,
        desc = null;

  final _TabsAction action;
  final _ColumnDesc? desc;
}

class _TabsSheet extends StatefulWidget {
  const _TabsSheet({
    required this.columns,
    required this.activeDesc,
    required this.titleOf,
    required this.iconOf,
    required this.onReorder,
    required this.onRemove,
  });

  final List<_ColumnDesc> columns;
  final _ColumnDesc? activeDesc;
  final Widget Function(_ColumnDesc) titleOf;
  final Widget Function(_ColumnDesc) iconOf;

  final void Function(int from, int to) onReorder;

  /// Resolves true when removed; the sheet stays open.
  final Future<bool> Function(_ColumnDesc) onRemove;

  @override
  State<_TabsSheet> createState() => _TabsSheetState();
}

class _TabsSheetState extends State<_TabsSheet> {
  late List<_ColumnDesc> _local;

  @override
  void initState() {
    super.initState();
    _local = List<_ColumnDesc>.from(widget.columns);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final size = MediaQuery.of(context).size;
    // Desktop centers the sheet with a 70vh cap; below 769px it is a 75vh bottom sheet.
    final desktop = size.width >= 769;
    final maxHeight = size.height * (desktop ? 0.70 : 0.75);
    return SafeArea(
      top: false,
      child: Align(
        alignment: desktop ? Alignment.center : Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520, maxHeight: maxHeight),
          child: Container(
            decoration: BoxDecoration(
              color: c.bgSecondary,
              border: Border.all(color: c.glassBorder),
              borderRadius: desktop
                  ? NymRadius.rlg
                  : const BorderRadius.vertical(
                      top: Radius.circular(NymRadius.lg),
                    ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: c.isLight ? 0.12 : 0.5),
                  blurRadius: 32,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.glassBorder)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr('Columns'),
                          style: TextStyle(
                            color: c.primary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      _HoverCloseButton(
                        tooltip: tr('Close'),
                        size: 18,
                        padding: const EdgeInsets.all(4),
                        hoverColor: c.textBright,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ReorderableListView.builder(
                    shrinkWrap: true,
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.all(8),
                    itemCount: _local.length,
                    proxyDecorator: (child, index, animation) {
                      final d = _local[index];
                      return Material(
                        type: MaterialType.transparency,
                        child: _TabRow(
                          index: index,
                          active: widget.activeDesc == d,
                          dragging: true,
                          icon: widget.iconOf(d),
                          title: widget.titleOf(d),
                          onTap: () {},
                          onClose: () {},
                        ),
                      );
                    },
                    onReorderItem: (oldIndex, newIndex) {
                      setState(() {
                        final moved = _local.removeAt(oldIndex);
                        _local.insert(newIndex, moved);
                      });
                      widget.onReorder(oldIndex, newIndex);
                    },
                    itemBuilder: (context, i) {
                      final desc = _local[i];
                      return _TabRow(
                        key: ValueKey('cvtab_${desc.key}'),
                        index: i,
                        active: widget.activeDesc == desc,
                        icon: widget.iconOf(desc),
                        title: widget.titleOf(desc),
                        onTap: () =>
                            Navigator.of(context).pop(_TabsResult.select(desc)),
                        onClose: () async {
                          final removed = await widget.onRemove(desc);
                          if (removed && mounted) {
                            setState(() => _local.remove(desc));
                          }
                        },
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: _AddColumnButton(
                    c: c,
                    width: double.infinity,
                    height: 44,
                    hoverFill: false,
                    onTap: () =>
                        Navigator.of(context).pop(const _TabsResult.add()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// With [dragging], renders the dashed reorder drag proxy.
class _TabRow extends StatelessWidget {
  const _TabRow({
    super.key,
    required this.index,
    required this.active,
    required this.icon,
    required this.title,
    required this.onTap,
    required this.onClose,
    this.dragging = false,
  });

  final int index;
  final bool active;
  final Widget icon;
  final Widget title;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final bool dragging;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final borderColor = active ? c.primary : c.glassBorder;
    final inner = Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: SizedBox(
                width: 16,
                height: 16,
                child: CustomPaint(
                  painter: _SixDotPainter(color: c.textDim),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(width: 24, height: 24, child: Center(child: icon)),
          const SizedBox(width: 10),
          Expanded(child: title),
          _HoverCloseButton(
            tooltip: tr('Remove column'),
            size: 16,
            padding: const EdgeInsets.all(4),
            hoverColor: c.danger,
            onTap: onClose,
          ),
        ],
      ),
    );

    if (dragging) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Opacity(
          opacity: 0.6,
          child: CustomPaint(
            painter: _DashedBorderPainter(
              color: borderColor,
              radius: NymRadius.sm,
              strokeWidth: 1,
              fill: Colors.white.withValues(alpha: 0.03),
            ),
            child: inner,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      // No hover state in the PWA, so no ink.
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: NymRadius.rsm,
              border: Border.all(color: borderColor),
            ),
            child: inner,
          ),
        ),
      ),
    );
  }
}

/// Column scroll-to-bottom button; unlike the single-view one it has no light-mode override.
class _ScrollBottomButton extends StatefulWidget {
  const _ScrollBottomButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ScrollBottomButton> createState() => _ScrollBottomButtonState();
}

class _ScrollBottomButtonState extends State<_ScrollBottomButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final fill = _hover ? c.primaryA(0.15) : c.glassBg;
    final border = _hover ? c.primaryA(0.30) : c.glassBorder;
    final shadow = BoxShadow(
      color: Colors.black.withValues(alpha: c.isLight ? 0.1 : 0.4),
      offset: const Offset(0, 4),
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
            width: 36,
            height: 36,
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

/// Dashed "+ Add column" tile; only the strip tile fills on hover, via [hoverFill].
class _AddColumnButton extends StatefulWidget {
  const _AddColumnButton({
    required this.c,
    required this.onTap,
    this.width = _CvDimens.addColumn,
    this.height,
    this.hoverFill = true,
  });

  final NymColors c;
  final VoidCallback onTap;
  final double width;
  final double? height;
  final bool hoverFill;

  @override
  State<_AddColumnButton> createState() => _AddColumnButtonState();
}

class _AddColumnButtonState extends State<_AddColumnButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final borderColor = _hover ? c.primary : c.glassBorder;
    final labelColor = _hover ? c.textBright : c.textDim;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          key: const Key('cvAddColumn'),
          onTap: widget.onTap,
          borderRadius: NymRadius.rmd,
          child: DottedBorderBox(
            color: borderColor,
            radius: NymRadius.md,
            fill: (_hover && widget.hoverFill) ? c.primaryA(0.04) : null,
            child: Center(
              child: Text(
                tr('+ Add column'),
                style: TextStyle(
                  color: labelColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({
    super.key,
    required this.child,
    required this.color,
    required this.radius,
    this.fill,
  });

  final Widget child;
  final Color color;
  final double radius;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(color: color, radius: radius, fill: fill),
      child: child,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({
    required this.color,
    required this.radius,
    this.fill,
    this.strokeWidth = 2,
  });

  final Color color;
  final double radius;
  final Color? fill;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
          inset, inset, size.width - strokeWidth, size.height - strokeWidth),
      Radius.circular(radius),
    );
    if (fill != null) {
      canvas.drawRRect(rrect, Paint()..color = fill!);
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    final path = Path()..addRRect(rrect);
    const dash = 6.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      double dist = 0;
      while (dist < metric.length) {
        canvas.drawPath(
          metric.extractPath(dist, dist + dash),
          paint,
        );
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.fill != fill ||
      old.strokeWidth != strokeWidth;
}

class _ColumnGroups {
  _ColumnGroups({
    required this.rev,
    required this.count,
    required this.mentionToken,
    required this.useBubbles,
    this.breakBefore,
    required this.groups,
    required this.indexById,
    required this.indexByUnit,
    required this.unitByIndex,
  });

  final int rev;
  final int count;
  final String mentionToken;
  final bool useBubbles;
  final String? breakBefore;
  final List<List<MessageGroupEntry>> groups;
  final Map<String, int> indexById;
  final Map<String, int> indexByUnit;
  final Map<int, String> unitByIndex;
}

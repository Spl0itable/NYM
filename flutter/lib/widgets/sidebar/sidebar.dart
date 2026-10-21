import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat_tools/chat_tools_ui.dart';
import '../../features/composer/composer_model.dart';
import '../../features/notifications/notifications_panel.dart';
import '../../features/shortcuts/shortcuts.dart';
import '../../features/group_tools/group_tools_ui.dart';
import '../../features/calls/call_history_providers.dart';
import '../../features/calls/call_history_ui.dart';
import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/globe/geohash_explorer.dart';
import '../../features/mesh/mesh_controller.dart';
import '../../features/i18n/localization_service.dart';
import '../../features/i18n/i18n.dart';
import '../../features/accounts/account_host.dart';
import '../../features/accounts/account_switcher.dart';
import '../../features/identity/nick_edit_modal.dart';
import '../../features/identity/panic_overlay.dart';
import '../../features/onboarding/tutorial_overlay.dart';
import '../../features/pms/new_pm_modal.dart';
import '../../features/relays/relay_stats_modal.dart';
import '../../features/settings/about_screen.dart';
import '../../features/settings/settings_helpers.dart'
    show geohashLocationLabel;
import '../../features/settings/settings_screen.dart';
import '../../features/shop/shop_modal.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../features/layout/layout_model.dart' show kPhoneMax;
import '../../state/settings_provider.dart';
import '../common/hit_slop.dart';
import '../common/app_dialog.dart';
import '../common/nym_avatar.dart';
import '../common/nym_label.dart';
import '../../features/chat_nav/chat_nav_providers.dart';
import '../../features/chat_nav/chat_nav_ui.dart';
import '../../features/chat_lock/chat_lock.dart' show ChatLockStrings;
import '../../features/chat_lock/chat_lock_providers.dart';
import '../../features/chat_lock/chat_lock_ui.dart';
import '../../features/search/unified_search_panel.dart';
import '../nym_icons.dart';
import 'sidebar_chrome.dart';
import 'channel_list_item.dart';
import 'conversation_avatar.dart';
import 'pm_context_menu.dart';
import 'pm_list_item.dart';
import 'row_preview.dart';
import 'sidebar_row_gestures.dart';
import 'sidebar_row_menu_button.dart';
import 'sidebar_rows.dart';
import 'sidebar_skeleton.dart';
import '../common/list_empty_note.dart';
import 'user_list_item.dart';
import '../common/panic_hold_detector.dart';
import '../common/nym_focusable.dart';
import 'unread_pill.dart';
import '../common/nym_field.dart';
import '../common/nym_tooltip.dart';
import '../../core/theme/nym_a11y.dart';

enum _SectionId { channels, pms, nyms }

extension _SectionIdName on _SectionId {
  /// Matches the PWA `data-section` values.
  String get id => switch (this) {
        _SectionId.channels => 'channels',
        _SectionId.pms => 'pms',
        _SectionId.nyms => 'nyms',
      };

  static _SectionId? fromId(String id) {
    for (final s in _SectionId.values) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// The left sidebar: identity header plus three collapsible sections, all in one scroll container.
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar(
      {super.key,
      this.onItemSelected,
      this.compact = false,
      this.onClose,
      this.closeShown = true,
      this.hidden = false});

  final bool hidden;

  /// Called after a row is tapped, so the mobile drawer can close.
  final VoidCallback? onItemSelected;

  final VoidCallback? onClose;

  final bool closeShown;

  /// Compact (<=1024) layout shows the `.sidebar-actions` row; wide layouts put those actions in the header.
  final bool compact;

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  Timer? _rowClock;

  final Set<_SectionId> _collapsed = {};

  late List<_SectionId> _order;

  List<ChatView> _navOrder = const [];

  void _publishNavOrder(List<ChatView> next) {
    if (listEquals(next, _navOrder)) return;
    _navOrder = next;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(sidebarNavOrderProvider.notifier).state = _navOrder;
    });
  }

  // Toggled by a 500ms long-press on a section title.
  bool _reorderMode = false;

  bool _channelSearch = false;
  bool _pmSearch = false;
  bool _nymSearch = false;

  String _channelTerm = '';
  String _pmTerm = '';
  String _nymTerm = '';

  // Collapsed lists cap at 20 rows; channels and PMs expand fully.
  bool _channelExpanded = false;
  bool _pmExpanded = false;

  // Nyms expand in 500-row steps; null means collapsed.
  int? _nymExpandedCap;

  static const int _collapsedCap = 20;

  static const int _expandedStep = 500;

  bool _loaded = false;

  bool _nymHover = false;

  final ScrollController _scroll = ScrollController();

  final Map<Key, (Object, Widget)> _channelMemo = {};
  final Map<Key, (Object, Widget)> _pmMemo = {};
  final Map<Key, (Object, Widget)> _nymMemo = {};

  @visibleForTesting
  Map<String, int> get debugRowMemoCounts => {
        'channel': _channelMemo.length,
        'pm': _pmMemo.length,
        'nym': _nymMemo.length,
      };

  // Skeleton rows are dropped after an 8s safety timeout even if no content arrives.
  bool _skelTimedOut = false;
  Timer? _skelTimer;

  @override
  void initState() {
    super.initState();
    _order = List.of(_SectionId.values);
    _skelTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _skelTimedOut = true);
    });
    _rowClock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) ref.read(rowClockProvider.notifier).state++;
    });
    // Persisted collapse and order are restored in didChangeDependencies, where ref.read is valid.
  }

  @override
  void dispose() {
    _skelTimer?.cancel();
    _rowClock?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final kv = ref.read(keyValueStoreProvider);

    final collapsedRaw = kv.getString(StorageKeys.sidebarSectionCollapsed);
    for (final id in _decodeIds(collapsedRaw)) {
      final s = _SectionIdName.fromId(id);
      if (s != null) _collapsed.add(s);
    }

    // Missing sections are appended in their default order.
    final orderRaw = kv.getString(StorageKeys.sidebarSectionOrder);
    final stored = _decodeIds(orderRaw)
        .map(_SectionIdName.fromId)
        .whereType<_SectionId>()
        .toList();
    if (stored.isNotEmpty) {
      final next = <_SectionId>[];
      for (final s in stored) {
        if (!next.contains(s)) next.add(s);
      }
      for (final s in _SectionId.values) {
        if (!next.contains(s)) next.add(s);
      }
      _order = next;
    }
  }

  List<String> _decodeIds(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      return raw
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return const [];
  }

  void _persistCollapsed() {
    ref.read(keyValueStoreProvider).setString(
          StorageKeys.sidebarSectionCollapsed,
          jsonEncode(_collapsed.map((s) => s.id).toList()),
        );
  }

  void _persistOrder() {
    ref.read(keyValueStoreProvider).setString(
          StorageKeys.sidebarSectionOrder,
          jsonEncode(_order.map((s) => s.id).toList()),
        );
  }

  void _toggleCollapse(_SectionId s) {
    setState(() {
      if (!_collapsed.remove(s)) _collapsed.add(s);
    });
    _persistCollapsed();
  }

  // No haptic: the PWA's section-title hold is silent.
  void _toggleReorderMode() {
    setState(() => _reorderMode = !_reorderMode);
  }

  void _moveSection(_SectionId s, int delta) {
    final i = _order.indexOf(s);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= _order.length) return;
    setState(() {
      _order
        ..removeAt(i)
        ..insert(j, s);
    });
    _persistOrder();
  }

  Widget? _frozen;

  @override
  Widget build(BuildContext context) {
    final frozen = _frozen;
    if (widget.hidden && frozen != null) {
      return TickerMode(
          enabled: false, child: _SidebarHidden(hidden: true, child: frozen));
    }
    return TickerMode(
        enabled: true,
        child: _SidebarHidden(hidden: false, child: _frozen = _buildLive(context)));
  }

  void _trimMemo(Map<Key, (Object, Widget)> memo, List<Key> shown) {
    final keep = shown.toSet();
    memo.removeWhere((k, _) => !keep.contains(k));
  }

  Widget _memoRow(Map<Key, (Object, Widget)> memo, Key key, Object sig,
      Widget Function() make) {
    final hit = memo[key];
    if (hit != null && hit.$1 == sig) return hit.$2;
    final w = AutomaticKeepAlive(
      key: ValueKey<Key>(key),
      child: RepaintBoundary(child: _KeptRow(child: make())),
    );
    memo[key] = (sig, w);
    return w;
  }

  Widget _channelRow(SidebarRow<ChannelEntry> row, double textSize, int i18n,
      void Function(ChatView) select) {
    final ch = row.item;
    final s = row.sig as SidebarChannelSig;
    final key = ValueKey('sidebar-channel-${ch.key}');
    return _memoRow(
      _channelMemo,
      key,
      (s, textSize, i18n),
      () => ChannelListItem(
        key: key,
        entry: ch,
        active: s.active,
        pinned: s.pinned,
        unread: s.unread,
        textSize: textSize,
        onTap: () => select(ChatView.channel(ch.key)),
      ),
    );
  }

  Widget _pmRow(SidebarRow<SidebarPmEntry> row, double textSize, int i18n,
      String selfPubkey, void Function(ChatView) select) {
    final e = row.item;
    final g = e.group;
    if (g != null) {
      final key = ValueKey('sidebar-group-${g.id}');
      return _memoRow(
        _pmMemo,
        key,
        (row.sig, textSize, i18n),
        () => _GroupListItem(
          key: key,
          group: g,
          active: e.active,
          unread: e.unread,
          textSize: textSize,
          selfPubkey: selfPubkey,
          users: ref.read(usersProvider),
          onTap: () => select(ChatView.group(g.id)),
        ),
      );
    }
    final pm = e.pm!;
    final key = ValueKey('sidebar-pm-${pm.pubkey}');
    return _memoRow(
      _pmMemo,
      key,
      (row.sig, textSize, i18n),
      () => PMListItem(
        key: key,
        nym: pm.nym,
        pubkey: pm.pubkey,
        active: e.active,
        unread: e.unread,
        textSize: textSize,
        mesh: e.mesh,
        onTap: () => select(ChatView.pm(pm.pubkey)),
      ),
    );
  }

  Key _pmKey(SidebarPmEntry e) => e.group != null
      ? ValueKey('sidebar-group-${e.group!.id}')
      : ValueKey('sidebar-pm-${e.pm!.pubkey}');

  Widget _nymRow(SidebarRow<User> row, double textSize, int i18n) {
    final u = row.item;
    final key = ValueKey('sidebar-nym-${u.pubkey}');
    return _memoRow(
      _nymMemo,
      key,
      (row.sig, textSize, i18n),
      () => UserListItem(
        key: key,
        user: u,
        textSize: textSize,
        onTap: () => showUserContextMenu(context, ref, u, Offset.zero),
      ),
    );
  }

  Widget _rowsSliver({
    List<Widget> leading = const [],
    required List<Key> keys,
    required Widget Function(int) rowAt,
    List<Widget> trailing = const [],
  }) {
    final lead = leading.length;
    final count = keys.length;
    final index = <Key, int>{
      for (var i = 0; i < count; i++) ValueKey<Key>(keys[i]): lead + i,
    };
    return SliverList.builder(
      itemCount: lead + count + trailing.length,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: false,
      addSemanticIndexes: false,
      findChildIndexCallback: (key) => index[key],
      itemBuilder: (context, i) {
        if (i < lead) return leading[i];
        if (i < lead + count) return rowAt(i - lead);
        return trailing[i - lead - count];
      },
    );
  }

  void _syncNav() {
    final pmOnly = ref.read(settingsProvider).groupChatPMOnlyMode;
    final channels = ref.read(sidebarChannelRowsProvider).rows;
    final pms = ref.read(sidebarPmRowsProvider).rows;
    _publishNavOrder([
      for (final sec in _order)
        if (sec == _SectionId.channels && !pmOnly)
          for (final r in channels) ChatView.channel(r.item.key)
        else if (sec == _SectionId.pms)
          for (final r in pms)
            r.item.group != null
                ? ChatView.group(r.item.group!.id)
                : ChatView.pm(r.item.pm!.pubkey),
    ]);
  }

  void _ensurePmProfiles() {
    ref
        .read(nostrControllerProvider)
        .ensureProfiles([for (final p in ref.read(pmListProvider)) p.pubkey]);
  }

  Widget _buildLive(BuildContext context) {
    final c = context.nym;
    final i18n = ref.watch(i18nVersionProvider);
    final settings = ref.watch(settingsProvider);
    final textSize = settings.textSize.toDouble();
    final selfNym = ref.watch(appStateProvider.select((s) => s.selfNym));
    final selfPubkey = ref.watch(appStateProvider.select((s) => s.selfPubkey));
    ref.watch(chatLockRevisionProvider);
    final chatLock = ref.read(chatLockProvider);
    final lockShown =
        ref.watch(chatLockBadgesProvider.select((b) => b.shown));
    ref.listen(sidebarChannelRowsProvider, (_, _) => _syncNav());
    ref.listen(sidebarPmRowsProvider, (_, _) {
      _ensurePmProfiles();
      _syncNav();
    });
    _ensurePmProfiles();
    _syncNav();

    bool secretOpened(String v) {
      if (!chatLock.matchesSecret(v)) return false;
      setState(() {
        _pmSearch = false;
        _pmTerm = '';
        _channelSearch = false;
        _channelTerm = '';
      });
      unawaited(openLockedChats(context, ref));
      return true;
    }

    void select(ChatView v) {
      if (ref.read(meshScreenOpenProvider)) {
        ref.read(meshScreenOpenProvider.notifier).state = false;
      }
      ref.read(appStateProvider.notifier).switchView(v);
      widget.onItemSelected?.call();
    }

    final controller = ref.read(nostrControllerProvider);

    ({List<T> rows, int more}) capped<T>(
      List<T> all,
      String term,
      bool Function(T) matches,
      bool expanded,
    ) {
      final filtered =
          term.isEmpty ? all : all.where(matches).toList(growable: false);
      if (term.isNotEmpty || expanded || filtered.length <= _collapsedCap) {
        return (rows: filtered, more: 0);
      }
      return (
        rows: filtered.sublist(0, _collapsedCap),
        more: filtered.length - _collapsedCap,
      );
    }

    Widget channelRows(BuildContext context, WidgetRef ref) {
      final data = ref.watch(sidebarChannelRowsProvider);
      final all = data.rows;
      final term = _channelTerm.toLowerCase();
      final r = capped<SidebarRow<ChannelEntry>>(
        all,
        term,
        (row) => (row.item.isGeohash ? row.item.geohashKey : row.item.channel)
            .toLowerCase()
            .contains(term),
        _channelExpanded,
      );
      final showChannelSkel = !_skelTimedOut && !data.flag;
      final keys = <Key>[
        for (final row in r.rows) ValueKey('sidebar-channel-${row.item.key}'),
      ];
      _trimMemo(_channelMemo, keys);
      return _rowsSliver(
        keys: keys,
        rowAt: (i) => _channelRow(r.rows[i], textSize, i18n, select),
        trailing: [
          if (showChannelSkel)
            for (final f in const [0.70, 0.42, 0.50, 0.58])
              SidebarSkeletonRow.channel(barWidthFactor: f),
          if (r.more > 0)
            _ViewMoreButton(
              more: r.more,
              onTap: () => setState(() => _channelExpanded = true),
            )
          else if (term.isEmpty &&
              _channelExpanded &&
              all.length > _collapsedCap)
            _ViewMoreButton(
              more: 0,
              onTap: () => setState(() => _channelExpanded = false),
            ),
          if (term.trim().isNotEmpty &&
              !all.any((row) => row.item.key == term.trim()))
            _SearchCreatePrompt(
              term: term.trim(),
              onTap: () {
                final t = term.trim();
                final geo = isValidGeohash(t) ? t : '';
                controller.switchChannel(t, geohash: geo);
                setState(() {
                  _channelTerm = '';
                  _channelSearch = false;
                });
                widget.onItemSelected?.call();
              },
            ),
        ],
      );
    }

    Widget pmRows(BuildContext context, WidgetRef ref) {
      final all = ref.watch(sidebarPmRowsProvider).rows;
      final term = _pmTerm.toLowerCase();
      final users = term.isEmpty ? null : ref.watch(usersProvider);
      final app = term.isEmpty ? null : ref.watch(appStateProvider);
      final r = capped<SidebarRow<SidebarPmEntry>>(
        all,
        term,
        (row) {
          final e = row.item;
          final String rendered;
          if (e.group != null) {
            final g = e.group!;
            final name = app!.groupLabel(g);
            rendered = '$name · ${_abbreviateNumber(g.members.length)}';
          } else {
            rendered =
                '${pickDisplayNym(users![e.pm!.pubkey]?.nym, e.pm!.nym)}'
                '#${getPubkeySuffix(e.pm!.pubkey)}';
          }
          return rendered.toLowerCase().contains(term);
        },
        _pmExpanded,
      );
      final showPmSkel = !_skelTimedOut && all.isEmpty;
      final keys = [for (final row in r.rows) _pmKey(row.item)];
      _trimMemo(_pmMemo, keys);
      return _rowsSliver(
        leading: [
          if (showPmSkel)
            for (final f in const [0.58, 0.70, 0.42])
              SidebarSkeletonRow.pm(barWidthFactor: f)
          else if (r.rows.isEmpty)
            ListEmptyNote(
              key: const ValueKey('pm-empty'),
              text: all.isEmpty
                  ? tr('No private messages yet')
                  : tr('No matches'),
              actionLabel: all.isEmpty ? tr('Start one') : null,
              onAction: all.isEmpty
                  ? () {
                      widget.onItemSelected?.call();
                      NewPmModal.open(context);
                    }
                  : null,
            ),
        ],
        keys: keys,
        rowAt: (i) => _pmRow(r.rows[i], textSize, i18n, selfPubkey, select),
        trailing: [
          if (r.more > 0)
            _ViewMoreButton(
              more: r.more,
              onTap: () => setState(() => _pmExpanded = true),
            )
          else if (term.isEmpty && _pmExpanded && all.length > _collapsedCap)
            _ViewMoreButton(
              more: 0,
              onTap: () => setState(() => _pmExpanded = false),
            ),
        ],
      );
    }

    Widget nymRows(BuildContext context, WidgetRef ref) {
      final onlineUsers = ref.watch(sidebarNymRowsProvider).rows;
      final term = _nymTerm.toLowerCase();
      final filtered = term.isEmpty
          ? onlineUsers
          : onlineUsers
              .where((r) =>
                  stripPubkeySuffix(r.item.nym).toLowerCase().contains(term))
              .toList(growable: false);
      final total = filtered.length;
      final int renderCap;
      if (term.isNotEmpty) {
        renderCap = total;
      } else if (_nymExpandedCap != null) {
        renderCap = total < _nymExpandedCap! ? total : _nymExpandedCap!;
      } else {
        renderCap = total < _collapsedCap ? total : _collapsedCap;
      }
      final nymRows =
          renderCap < total ? filtered.sublist(0, renderCap) : filtered;
      final remaining = total - renderCap;
      final keys = <Key>[
        for (final row in nymRows) ValueKey('sidebar-nym-${row.item.pubkey}'),
      ];
      _trimMemo(_nymMemo, keys);
      return _rowsSliver(
        leading: [
          if (!_skelTimedOut && onlineUsers.isEmpty)
            for (final f in const [0.70, 0.42, 0.50, 0.58, 0.70])
              SidebarSkeletonRow.nym(barWidthFactor: f)
          else if (nymRows.isEmpty)
            ListEmptyNote(
              key: const ValueKey('nym-empty'),
              text: onlineUsers.isEmpty
                  ? tr('No one else is here right now')
                  : tr('No matches'),
            ),
        ],
        keys: keys,
        rowAt: (i) => _nymRow(nymRows[i], textSize, i18n),
        trailing: [
          if (term.isEmpty && total > _collapsedCap)
            if (_nymExpandedCap == null)
              _ViewMoreButton(
                more: total - _collapsedCap,
                onTap: () => setState(() => _nymExpandedCap = _expandedStep),
              )
            else if (remaining > 0)
              _ViewMoreButton(
                more: remaining < _expandedStep ? remaining : _expandedStep,
                stepMore: true,
                onTap: () => setState(
                    () => _nymExpandedCap = _nymExpandedCap! + _expandedStep),
              )
            else
              _ViewMoreButton(
                more: 0,
                onTap: () => setState(() => _nymExpandedCap = null),
              ),
        ],
      );
    }

    Widget sectionFor(_SectionId s) {
      switch (s) {
        case _SectionId.channels:
          return _NavSection(
            id: const ValueKey('section-channels'),
            sectionKey: TutorialTargets.keyFor(TutorialTarget.channelList),
            title: tr('Public Channels'),
            open: !_collapsed.contains(s),
            searching: _channelSearch,
            reorderMode: _reorderMode,
            canMoveUp: _order.indexOf(s) > 0,
            canMoveDown: _order.indexOf(s) < _order.length - 1,
            onMoveUp: () => _moveSection(s, -1),
            onMoveDown: () => _moveSection(s, 1),
            onToggleOpen: () => _toggleCollapse(s),
            onToggleSearch: () => setState(() {
              _channelSearch = !_channelSearch;
              if (!_channelSearch) _channelTerm = '';
            }),
            onSearchChanged: (v) {
              if (secretOpened(v)) return;
              setState(() => _channelTerm = v);
            },
            onLongPressTitle: _toggleReorderMode,
            leadingIcon: _MiniIcon(
              key: TutorialTargets.keyFor(TutorialTarget.discoverIcon),
              svg: NymIcons.globe,
              tooltip: tr('Explore geohash channels globally'),
              onTap: _openDiscover,
            ),
            searchHint: tr('Search channels...'),
            searchTooltip: tr('Search channels'),
            body: _SidebarLive(builder: channelRows),
          );
        case _SectionId.pms:
          return _NavSection(
            id: const ValueKey('section-pms'),
            sectionKey: TutorialTargets.keyFor(TutorialTarget.pmList),
            title: tr('Private Messages'),
            open: !_collapsed.contains(s),
            searching: _pmSearch,
            reorderMode: _reorderMode,
            canMoveUp: _order.indexOf(s) > 0,
            canMoveDown: _order.indexOf(s) < _order.length - 1,
            onMoveUp: () => _moveSection(s, -1),
            onMoveDown: () => _moveSection(s, 1),
            onToggleOpen: () => _toggleCollapse(s),
            onToggleSearch: () => setState(() {
              _pmSearch = !_pmSearch;
              if (!_pmSearch) _pmTerm = '';
            }),
            onSearchChanged: (v) {
              if (secretOpened(v)) return;
              setState(() => _pmTerm = v);
            },
            onLongPressTitle: _toggleReorderMode,
            leadingIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (chatLock.entryShown) ...[
                  _LockedChatsEntry(
                    count: lockShown,
                    onTap: () => unawaited(openLockedChats(context, ref)),
                  ),
                  const SizedBox(width: 10),
                ],
                _MiniIcon(
                  svg: NymIcons.plus,
                  tooltip: tr('New message'),
                  onTap: () {
                    widget.onItemSelected?.call();
                    NewPmModal.open(context);
                  },
                ),
              ],
            ),
            searchHint: tr('Search PMs...'),
            searchTooltip: tr('Search PMs'),
            body: _SidebarLive(builder: pmRows),
          );
        case _SectionId.nyms:
          return _NavSection(
            id: const ValueKey('section-nyms'),
            sectionKey: TutorialTargets.keyFor(TutorialTarget.userList),
            title: '',
            titleText: _SidebarLive(
              builder: (context, ref) => _NavTitleText(
                tr('Nyms ({count} online)', {
                  'count': _abbreviateNumber(ref.watch(
                      sidebarNymRowsProvider.select((d) => d.count))),
                }),
              ),
            ),
            open: !_collapsed.contains(s),
            searching: _nymSearch,
            reorderMode: _reorderMode,
            isUserList: true,
            canMoveUp: _order.indexOf(s) > 0,
            canMoveDown: _order.indexOf(s) < _order.length - 1,
            onMoveUp: () => _moveSection(s, -1),
            onMoveDown: () => _moveSection(s, 1),
            onToggleOpen: () => _toggleCollapse(s),
            onToggleSearch: () => setState(() {
              _nymSearch = !_nymSearch;
              if (!_nymSearch) _nymTerm = '';
            }),
            onSearchChanged: (v) => setState(() => _nymTerm = v),
            onLongPressTitle: _toggleReorderMode,
            searchHint: tr('Search nyms...'),
            searchTooltip: tr('Search nyms'),
            body: _SidebarLive(builder: nymRows),
          );
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: c.bgSecondary,
        border: Border(right: BorderSide(color: c.glassBorder)),
      ),
      child: SafeArea(
        right: false,
        top: false,
        bottom: false,
        child: Column(
          children: [
            _header(context, selfNym),
            Expanded(
              child: ScrollbarTheme(
          data: ScrollbarThemeData(
            thickness: const WidgetStatePropertyAll(6),
            radius: const Radius.circular(10),
            trackColor: const WidgetStatePropertyAll(Colors.transparent),
            trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
            thumbColor: WidgetStateProperty.resolveWith(
              (states) {
                final base = c.isLight ? Colors.black : Colors.white;
                return base.withValues(
                    alpha: states.contains(WidgetState.hovered) ? 0.2 : 0.12);
              },
            ),
          ),
          child: Scrollbar(
            controller: _scroll,
            child: CustomScrollView(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverToBoxAdapter(
                  child: UnifiedSearchButton(onTap: () {
                    widget.onItemSelected?.call();
                    UnifiedSearchPanel.open(context);
                  }),
                ),
                if (widget.compact)
                  SliverToBoxAdapter(
                    child:
                        _SidebarActions(onItemSelected: widget.onItemSelected),
                  ),
                for (final s in _order)
                  if (!(settings.groupChatPMOnlyMode &&
                      s == _SectionId.channels))
                    sectionFor(s),
                const SliverToBoxAdapter(
                    child: SizedBox(height: NymSpace.s3)),
              ],
            ),
          ),
        ),
            ),
            _footer(context),
          ],
        ),
      ),
    );
  }


  Widget _footer(BuildContext context) {
    final c = context.nym;
    final connectedRelays = ref.watch(
      appStateProvider.select((s) => s.connectedRelays),
    );
    final proxyMode = ref.watch(
      appStateProvider.select((s) => s.proxyMode),
    );
    final bottom = MediaQuery.paddingOf(context).bottom;
    final phone =
        MediaQuery.sizeOf(context).width <= NymDimens.mobileBreakpoint;
    final extent =
        ref.watch(composerRestExtentProvider) ?? (phone ? 65 : 69) + bottom;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: tr('Connection status and sidebar tools'),
      child: Container(
      key: const ValueKey('sidebarFooter'),
      constraints: BoxConstraints(minHeight: extent),
      padding: EdgeInsets.fromLTRB(NymSpace.s2, 0, NymSpace.s2, bottom),
      decoration: BoxDecoration(
        color: c.isLight
            ? Colors.white.withValues(alpha: 0.3)
            : Colors.black.withValues(alpha: 0.15),
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: context.largeTouchTargets
                ? Row(
                    children: [
                      Flexible(
                        child: _ConnectionStatusIndicator(
                          connectedCount: connectedRelays,
                          proxyMode: proxyMode,
                        ),
                      ),
                      const SizedBox(width: NymSpace.s1),
                      Flexible(
                        child: _MeshStatusIndicator(
                            onItemSelected: widget.onItemSelected),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ConnectionStatusIndicator(
                        connectedCount: connectedRelays,
                        proxyMode: proxyMode,
                      ),
                      _MeshStatusIndicator(onItemSelected: widget.onItemSelected),
                    ],
                  ),
          ),
          const SizedBox(width: NymSpace.s2),
          _editButton(context),
        ],
      ),
      ),
    );
  }

  Widget _editButton(BuildContext context) {
    final c = context.nym;
    final on = _reorderMode;
    final label = on ? tr('Done') : tr('Edit sidebar');
    final button = Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: on ? c.primary.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: NymRadius.rsm,
        child: InkWell(
          key: const ValueKey('sidebarEditBtn'),
          borderRadius: NymRadius.rsm,
          hoverColor: c.primary.withValues(alpha: 0.1),
          onTap: _toggleReorderMode,
          child: Container(
            height: 40,
            constraints: const BoxConstraints(minWidth: 40),
            padding: on
                ? const EdgeInsets.symmetric(horizontal: NymSpace.s3)
                : EdgeInsets.zero,
            alignment: Alignment.center,
            child: on
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      NymSvgIcon(kSidebarCheckSvg, size: 16, color: c.primary),
                      const SizedBox(width: 6),
                      Text(label,
                          style: TextStyle(
                              color: c.primary,
                              fontSize: NymType.sm,
                              fontWeight: FontWeight.w600)),
                    ],
                  )
                : NymSvgIcon(kSidebarPencilSvg, size: 18, color: c.textDim),
          ),
        ),
      ),
    );
    return HitSlop(
        child: NymTooltip(
            message: label, excludeFromSemantics: true, child: button));
  }

  Future<void> _openDiscover() async {
    widget.onItemSelected?.call();
    final gh = await Navigator.of(context).push<String>(
      GeohashExplorer.route(),
    );
    if (gh == null || gh.isEmpty || !mounted) return;
    ref.read(nostrControllerProvider).switchChannel(gh, geohash: gh);
  }

  /// Identity header: a tap opens the nick editor, a 2s hold triggers the panic wipe.
  Widget _header(BuildContext context, String nym) {
    final c = context.nym;
    final self = ref.read(appStateProvider).selfPubkey;
    final top = MediaQuery.paddingOf(context).top;
    final extent = ref.watch(chatHeaderExtentProvider) ??
        (MediaQuery.sizeOf(context).width <= NymDimens.mobileBreakpoint
                ? 92
                : 101) +
            top;
    return Container(
      key: const ValueKey('sidebarHeader'),
      constraints: BoxConstraints(minHeight: extent),
      padding: EdgeInsets.only(top: top),
      decoration: BoxDecoration(
        color: c.isLight
            ? Colors.white.withValues(alpha: 0.3)
            : Colors.black.withValues(alpha: 0.15),
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            key: const ValueKey('sidebarIdentityRow'),
            children: [
              const SizedBox(width: NymSpace.s3),
              Expanded(
                child: PanicHoldDetector(
                  onTap: () => NickEditModal.open(context),
                  onHold: () => _triggerPanic(context),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => setState(() => _nymHover = true),
                    onExit: (_) => setState(() => _nymHover = false),
                    child: Semantics(
                      button: true,
                      label: tr('Your Nym (click to edit)'),
                      child: NymTooltip(
                        message: tr('Edit your profile'),
                        triggerMode: TooltipTriggerMode.manual,
                        child: Container(
                          key: TutorialTargets.keyFor(TutorialTarget.nymDisplay),
                          padding: const EdgeInsets.symmetric(
                              horizontal: NymSpace.s2, vertical: 6),
                          decoration: BoxDecoration(
                            color: _nymHover
                                ? (c.isLight
                                    ? Colors.black.withValues(alpha: 0.05)
                                    : Colors.white.withValues(alpha: 0.07))
                                : Colors.transparent,
                            borderRadius: NymRadius.rsm,
                          ),
                          child: Row(
                            children: [
                              NymAvatar(
                                seed: self,
                                size: 36,
                                imageUrl: ref
                                    .read(appStateProvider)
                                    .users[self]
                                    ?.profile
                                    ?.picture,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _NymValueText(nym: nym, pubkey: self),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (ref.watch(accountsProvider) != null) ...[
                const SizedBox(width: NymSpace.s2),
                const AccountSwitchButton(),
              ],
              if (widget.compact &&
                  MediaQuery.sizeOf(context).width <= kPhoneMax) ...[
                const SizedBox(width: NymSpace.s2),
                const _IdentityBell(),
                if (widget.onClose != null) ...[
                  const SizedBox(width: NymSpace.s2),
                  ExcludeSemantics(
                    excluding: !widget.closeShown,
                    child: IgnorePointer(
                      ignoring: !widget.closeShown,
                      child: _IdentityClose(onTap: widget.onClose!),
                    ),
                  ),
                ],
              ],
              const SizedBox(width: NymSpace.s3),
            ],
          ),
        ],
      ),
    );
  }

  // PanicWipe clears disk stores; resetAfterPanic's boot-epoch bump remounts the first-run gate.
  void _triggerPanic(BuildContext context) => startPanicWipe(context, ref);
}

final RegExp _hex64Re = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

final RegExp _nymSuffix4Re = RegExp(r'#([0-9a-f]{4})$', caseSensitive: false);

/// Header nym with a dimmed `#suffix` taken from the pubkey, then the nym's own suffix, then `????`.
class _NymValueText extends StatelessWidget {
  const _NymValueText({required this.nym, required this.pubkey});

  final String nym;
  final String pubkey;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final String base;
    final String suffix;
    if (_hex64Re.hasMatch(pubkey)) {
      base = stripPubkeySuffix(nym);
      suffix = getPubkeySuffix(pubkey);
    } else {
      final m = _nymSuffix4Re.firstMatch(nym);
      if (m != null) {
        base = nym.substring(0, nym.length - 5);
        suffix = m.group(1)!;
      } else {
        base = nym;
        suffix =
            pubkey.length >= 4 ? pubkey.substring(pubkey.length - 4) : '????';
      }
    }
    return NymLabel(
      base,
      suffix: suffix,
      style: TextStyle(
        color: c.secondary,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// Connection-status row below the nym box; tapping opens Network Stats.
class _ConnectionStatusIndicator extends StatelessWidget {
  const _ConnectionStatusIndicator({
    required this.connectedCount,
    required this.proxyMode,
  });

  final int connectedCount;
  final bool proxyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final connected = connectedCount > 0;
    final label = connected
        ? (proxyMode
            ? tr('Proxy Connected ({count} relays)', {'count': connectedCount})
            : tr('Direct Connected ({count} relays)',
                {'count': connectedCount}))
        : tr('Connecting...');
    final dotColor = connected ? c.primary : c.warning;
    return _StatusRow(
      key: TutorialTargets.keyFor(TutorialTarget.statusIndicator),
      rowKey: const ValueKey('sidebarNetRow'),
      onTap: () => RelayStatsModal.open(context),
      tooltip: tr('View network stats'),
      leading: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: dotColor,
          shape: BoxShape.circle,
        ),
      ),
      label: label,
      trailing: const _TranslatingIndicator(),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    super.key,
    required this.rowKey,
    required this.onTap,
    required this.leading,
    required this.label,
    required this.tooltip,
    this.trailing,
    this.trailingText,
    this.selected = false,
  });

  final bool selected;
  final Key rowKey;
  final VoidCallback onTap;
  final Widget leading;
  final String label;
  final String tooltip;
  final Widget? trailing;
  final String? trailingText;

  static const double _fixed = NymSpace.s2 * 2 + 12 + 5;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final style = TextStyle(
        color: selected ? c.primary : c.textDim, fontSize: NymType.xs);
    final scaler = MediaQuery.textScalerOf(context);
    final row = LayoutBuilder(builder: (context, box) {
      final tail = trailingText == null
          ? 0.0
          : 6 +
              (TextPainter(
                text: TextSpan(
                    text: trailingText,
                    style: const TextStyle(fontSize: 10)),
                textScaler: scaler,
                textDirection: TextDirection.ltr,
                maxLines: 1,
              )..layout())
                  .width;
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: math.max(0, box.maxWidth - _fixed - tail));
      final full =
          trailingText == null ? label : '$label · $trailingText';
      return Align(
        alignment: Alignment.centerLeft,
        child: NymTooltip(
          message: painter.didExceedMaxLines ? full : tooltip,
          excludeFromSemantics: true,
          child: Material(
            color: selected ? c.primaryA(0.12) : Colors.transparent,
            borderRadius: NymRadius.rxs,
            child: InkWell(
              key: rowKey,
              borderRadius: NymRadius.rxs,
              hoverColor: c.primary.withValues(alpha: 0.08),
              onTap: onTap,
              child: Container(
                constraints: BoxConstraints(
                    minHeight: context.largeTouchTargets ? 44 : 28),
                padding: const EdgeInsets.symmetric(
                    horizontal: NymSpace.s2, vertical: NymSpace.s1),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 12, child: Center(child: leading)),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 6),
                      trailing!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
    return Semantics(selected: selected, child: row);
  }
}

class _TranslatingIndicator extends ConsumerWidget {
  const _TranslatingIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(i18nVersionProvider);
    if (!LocalizationService.instance.isTranslating) {
      return const SizedBox.shrink();
    }
    final c = context.nym;
    return NymTooltip(
      message: tr('Translating...'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(c.primary),
              backgroundColor: c.textDim.withValues(alpha: 0.25),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mesh status line with peer/link count; renders nothing without mesh support.
class _MeshStatusIndicator extends ConsumerWidget {
  const _MeshStatusIndicator({this.onItemSelected});

  /// Closes the mobile drawer before the mesh screen opens, or it reappears when the screen pops.
  final VoidCallback? onItemSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final mesh = ref.watch(meshControllerProvider);
    if (!MeshController.isSupportedPlatform) return const SizedBox.shrink();

    final active = mesh.running;
    final peerCount = mesh.peers.length;
    final label = !active
        ? tr('Mesh off')
        : (peerCount == 0
            ? tr('Mesh · no peers')
            : (peerCount == 1
                ? tr('Mesh · 1 peer')
                : tr('Mesh · {count} peers', {'count': peerCount})));
    final links = active && mesh.linkCount > 0
        ? (mesh.linkCount == 1
            ? tr('1 link')
            : tr('{count} links', {'count': mesh.linkCount}))
        : null;
    final color = active ? c.primary : c.textDim;
    return _StatusRow(
      selected: ref.watch(meshScreenOpenProvider),
      rowKey: const ValueKey('sidebarMeshRow'),
      onTap: () {
        // Idempotent; an already-open overlay stays open.
        ref.read(meshScreenOpenProvider.notifier).state = true;
        onItemSelected?.call();
      },
      leading: NymSvgIcon(NymIcons.bluetooth, size: 12, color: color),
      label: label,
      tooltip: tr('Bluetooth mesh'),
      trailingText: links,
      trailing: links == null
          ? null
          : Text(links,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                  color: c.textDim.withValues(alpha: 0.7), fontSize: 10)),
    );
  }
}

class _SidebarActions extends ConsumerWidget {
  const _SidebarActions({this.onItemSelected});

  final VoidCallback? onItemSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final unread =
        ref.watch(notificationHistoryProvider.select((s) => s.unread));
    final notifEnabled =
        ref.watch(settingsProvider.select((s) => s.notificationsEnabled));
    final missedCalls = ref.watch(callHistoryMissedProvider);
    void go(void Function() open) {
      onItemSelected?.call();
      open();
    }

    Widget tile(String id) => switch (id) {
          'notifications' => _ActionButton(
              key: const ValueKey('menu-notifications'),
              svg: NymIcons.bell,
              label: tr('Notifications'),
              badge: notifEnabled ? unread : 0,
              onTap: () => go(() => showNotificationsPanel(context)),
            ),
          'saved' => _ActionButton(
              key: const ValueKey('menu-saved'),
              svg: ChatToolIcons.saved,
              label: tr('Saved'),
              onTap: () => go(() => SavedMessagesPanel.open(context)),
            ),
          'calls' => _ActionButton(
              key: const ValueKey('gtCallsButton'),
              svg: GroupToolIcons.callLink,
              label: tr('Calls'),
              badge: missedCalls,
              onTap: () => go(() => showCallsScreen(context)),
            ),
          'shop' => _ActionButton(
              key: const ValueKey('menu-shop'),
              svg: NymIcons.store,
              label: tr('Shop'),
              onTap: () => go(() => ShopModal.open(context)),
            ),
          'settings' => _ActionButton(
              key: const ValueKey('menu-settings'),
              svg: NymIcons.settings,
              label: tr('Settings'),
              onTap: () => go(() => SettingsScreen.open(context)),
            ),
          _ => _ActionButton(
              key: const ValueKey('menu-about'),
              svg: NymIcons.info,
              label: tr('About'),
              onTap: () => go(() => AboutScreen.open(context)),
            ),
        };

    final phone = MediaQuery.sizeOf(context).width <= kPhoneMax;
    final rows = [
      for (final r in mainMenuRows('mobile').grid)
        [
          for (final id in r)
            if (!(phone && id == 'notifications')) id,
        ],
    ];
    return Semantics(
      label: tr('Main menu'),
      container: true,
      child: Container(
        key: TutorialTargets.keyFor(TutorialTarget.mainMenu),
        padding: const EdgeInsets.fromLTRB(
            NymSpace.s2, NymSpace.s1, NymSpace.s2, 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.glassBorder)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              Row(
                key: ValueKey('menu-row-$i'),
                children: [
                  for (var j = 0; j < rows[i].length; j++) ...[
                    if (j > 0) const SizedBox(width: 2),
                    tile(rows[i][j]),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  const _ActionButton({
    super.key,
    required this.svg,
    required this.label,
    required this.onTap,
    this.badge = 0,
  });

  final String svg;
  final String label;
  final VoidCallback onTap;
  final int badge;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final fill = _hover
        ? (c.isLight
            ? Colors.black.withValues(alpha: 0.05)
            : c.primaryA(0.1))
        : Colors.transparent;
    final fg = c.isLight || _hover ? c.primary : c.text;
    return Expanded(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: NymRadius.rxs,
          child: Container(
            padding: const EdgeInsets.fromLTRB(2, NymSpace.s2, 2, 6),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: NymRadius.rxs,
            ),
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    NymSvgIcon(widget.svg, size: 16, color: fg),
                    if (widget.badge > 0)
                      Positioned(
                        top: -6,
                        left: 10,
                        child: Container(
                          key: const ValueKey('menu-notifications-badge'),
                          constraints:
                              const BoxConstraints(minWidth: 16, minHeight: 16),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: badgeFill(context, c.danger),
                            borderRadius:
                                const BorderRadius.all(Radius.circular(8)),
                          ),
                          child: Text(
                            widget.badge > 99 ? '99+' : '${widget.badge}',
                            style: const TextStyle(
                              color: Color(0xFFFFFFFF),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.highContrast
                        ? legibleOn(fg, flattenOver(fill, sidebarRowBg(c)))
                        : fg,
                    fontSize: NymType.xs,
                    fontWeight: FontWeight.w500,
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

/// Collapsible nav section; a 500ms title hold toggles reorder mode and only the chevron collapses.
class _KeptRow extends StatefulWidget {
  const _KeptRow({required this.child});

  final Widget child;

  @override
  State<_KeptRow> createState() => _KeptRowState();
}

class _KeptRowState extends State<_KeptRow>
    with AutomaticKeepAliveClientMixin {
  bool _keep = false;

  @override
  bool get wantKeepAlive => _keep;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = mounted ? context.findRenderObject() : null;
      if (box is RenderBox && box.hasSize) {
        _keep = true;
        updateKeepAlive();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _SidebarHidden extends InheritedWidget {
  const _SidebarHidden({required this.hidden, required super.child});

  final bool hidden;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SidebarHidden>()?.hidden ??
      false;

  @override
  bool updateShouldNotify(_SidebarHidden oldWidget) =>
      oldWidget.hidden != hidden;
}

class _SidebarLive extends ConsumerStatefulWidget {
  const _SidebarLive({required this.builder});

  final Widget Function(BuildContext context, WidgetRef ref) builder;

  @override
  ConsumerState<_SidebarLive> createState() => _SidebarLiveState();
}

class _SidebarLiveState extends ConsumerState<_SidebarLive> {
  Widget? _last;

  @override
  Widget build(BuildContext context) {
    final last = _last;
    if (_SidebarHidden.of(context) && last != null) return last;
    return _last = widget.builder(context, ref);
  }
}

enum _TargetSlot { sliver, box }

class _SliverTarget
    extends SlottedMultiChildRenderObjectWidget<_TargetSlot, RenderObject> {
  const _SliverTarget({required this.targetKey, required this.sliver});

  final Key targetKey;
  final Widget sliver;

  @override
  Iterable<_TargetSlot> get slots => _TargetSlot.values;

  @override
  Widget? childForSlot(_TargetSlot slot) => switch (slot) {
        _TargetSlot.sliver => sliver,
        _TargetSlot.box =>
          KeyedSubtree(key: targetKey, child: const SizedBox.expand()),
      };

  @override
  _RenderSliverTarget createRenderObject(BuildContext context) =>
      _RenderSliverTarget();
}

class _RenderSliverTarget extends RenderSliver
    with
        SlottedContainerRenderObjectMixin<_TargetSlot, RenderObject>,
        RenderSliverHelpers {
  RenderSliver? get _sliver => childForSlot(_TargetSlot.sliver) as RenderSliver?;
  RenderBox? get _box => childForSlot(_TargetSlot.box) as RenderBox?;

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! SliverPhysicalParentData) {
      child.parentData = SliverPhysicalParentData();
    }
  }

  @override
  void performLayout() {
    final sliver = _sliver!;
    sliver.layout(constraints, parentUsesSize: true);
    final g = sliver.geometry!;
    geometry = g;
    _box?.layout(BoxConstraints.tightFor(
        width: constraints.crossAxisExtent, height: g.scrollExtent));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final sliver = _sliver;
    if (sliver != null && sliver.geometry!.visible) {
      context.paintChild(sliver, offset);
    }
  }

  @override
  bool hitTestChildren(SliverHitTestResult result,
          {required double mainAxisPosition,
          required double crossAxisPosition}) =>
      _sliver?.hitTest(result,
          mainAxisPosition: mainAxisPosition,
          crossAxisPosition: crossAxisPosition) ??
      false;

  @override
  double childMainAxisPosition(covariant RenderObject child) =>
      child == _box ? -constraints.scrollOffset : 0;

  @override
  double childCrossAxisPosition(covariant RenderObject child) => 0;

  @override
  double? childScrollOffset(covariant RenderObject child) => 0;

  @override
  void applyPaintTransform(covariant RenderObject child, Matrix4 transform) {
    final box = _box;
    if (child == box && box != null) {
      applyPaintTransformForBoxChild(box, transform);
    }
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final sliver = _sliver;
    if (sliver != null) visitor(sliver);
  }
}

class _NavTitleText extends StatelessWidget {
  const _NavTitleText(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: context.nym.textDim,
        fontSize: 10,
        letterSpacing: 2,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _NavSection extends StatelessWidget {
  const _NavSection({
    required this.id,
    required this.sectionKey,
    required this.title,
    required this.open,
    required this.searching,
    required this.onToggleOpen,
    required this.onToggleSearch,
    required this.onSearchChanged,
    required this.onLongPressTitle,
    required this.searchHint,
    required this.searchTooltip,
    required this.body,
    required this.reorderMode,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    this.leadingIcon,
    this.titleText,
    this.isUserList = false,
  });

  final Key id;
  final Key sectionKey;
  final String title;
  final Widget? titleText;
  final bool open;
  final bool searching;
  final VoidCallback onToggleOpen;
  final VoidCallback onToggleSearch;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onLongPressTitle;
  final String searchHint;
  final String searchTooltip;
  final Widget body;
  final bool reorderMode;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final Widget? leadingIcon;
  final bool isUserList;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final pad = isUserList
        ? const EdgeInsets.fromLTRB(12, 10, 12, 10)
        : const EdgeInsets.fromLTRB(12, 16, 12, 12);
    final border =
        isUserList ? null : Border(bottom: BorderSide(color: c.glassBorder));
    final header = Padding(
      key: id,
      padding: pad.copyWith(bottom: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _NavTitleHold(
            onHold: onLongPressTitle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 0, 10),
              child: Row(
                children: [
                  if (reorderMode) ...[
                    _ReorderArrows(
                      canUp: canMoveUp,
                      canDown: canMoveDown,
                      onUp: onMoveUp,
                      onDown: onMoveDown,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(child: titleText ?? _NavTitleText(title)),
                  const SizedBox(width: 10),
                  if (leadingIcon != null) ...[
                    leadingIcon!,
                    SizedBox(width: context.largeTouchTargets ? 12 : 10),
                  ],
                  _MiniIcon(
                    svg: NymIcons.search,
                    tooltip: searchTooltip,
                    onTap: onToggleSearch,
                  ),
                  SizedBox(width: context.largeTouchTargets ? 12 : 10),
                  _MiniIcon(
                    svg: open ? NymIcons.chevronDown : NymIcons.chevronRight,
                    tooltip:
                        open ? tr('Collapse section') : tr('Expand section'),
                    onTap: onToggleOpen,
                  ),
                ],
              ),
            ),
          ),
          if (open && searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
              child: _SearchField(
                hint: searchHint,
                onChanged: onSearchChanged,
              ),
            ),
        ],
      ),
    );
    final group = SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: header),
        SliverPadding(
          padding: pad.copyWith(
              top: 0, bottom: pad.bottom + (border?.bottom.width ?? 0)),
          sliver: _SliverTarget(
            targetKey: sectionKey,
            sliver: open
                ? body
                : const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),
        ),
      ],
    );
    if (border == null) return group;
    return DecoratedSliver(
      decoration: BoxDecoration(border: border),
      sliver: group,
    );
  }
}

/// Silent 500ms title hold with a 10px cancel; a [Listener] stays out of the arena so drags still scroll.
class _NavTitleHold extends StatefulWidget {
  const _NavTitleHold({required this.onHold, required this.child});

  final VoidCallback onHold;
  final Widget child;

  static const Duration holdDuration = Duration(milliseconds: 500);

  static const double moveThreshold = 10;

  @override
  State<_NavTitleHold> createState() => _NavTitleHoldState();
}

class _NavTitleHoldState extends State<_NavTitleHold> {
  Timer? _pressTimer;
  Offset _start = Offset.zero;

  void _onPointerDown(PointerDownEvent e) {
    // Mouse presses count only for the primary button.
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) {
      return;
    }
    _start = e.position;
    _cancel();
    _pressTimer = Timer(_NavTitleHold.holdDuration, () {
      _pressTimer = null;
      if (!mounted) return;
      widget.onHold();
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_pressTimer == null) return;
    if ((e.position.dx - _start.dx).abs() > _NavTitleHold.moveThreshold ||
        (e.position.dy - _start.dy).abs() > _NavTitleHold.moveThreshold) {
      _cancel();
    }
  }

  void _cancel([PointerEvent? _]) {
    _pressTimer?.cancel();
    _pressTimer = null;
  }

  @override
  void dispose() {
    _pressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _cancel,
      onPointerCancel: _cancel,
      child: widget.child,
    );
  }
}

class _ReorderArrows extends StatelessWidget {
  const _ReorderArrows({
    required this.canUp,
    required this.canDown,
    required this.onUp,
    required this.onDown,
  });
  final bool canUp;
  final bool canDown;
  final VoidCallback onUp;
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ReorderBtn(svg: NymIcons.reorderUp, enabled: canUp, onTap: onUp),
        const SizedBox(width: 3),
        _ReorderBtn(
          svg: NymIcons.reorderDown,
          enabled: canDown,
          onTap: onDown,
        ),
      ],
    );
  }
}

class _ReorderBtn extends StatefulWidget {
  const _ReorderBtn({
    required this.svg,
    required this.enabled,
    required this.onTap,
  });
  final String svg;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_ReorderBtn> createState() => _ReorderBtnState();
}

class _ReorderBtnState extends State<_ReorderBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hovered = _hover && widget.enabled;
    return Opacity(
      opacity: widget.enabled ? 1 : 0.25,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.enabled ? widget.onTap : null,
          borderRadius: NymRadius.rxs,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // Fixed white fill in both modes; the CSS has no light override.
              color: hovered ? c.primary : Colors.white.withValues(alpha: 0.08),
              borderRadius: NymRadius.rxs,
            ),
            child: NymSvgIcon(
              widget.svg,
              size: 14,
              color: hovered ? Colors.white : c.text,
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniIcon extends StatefulWidget {
  const _MiniIcon({
    super.key,
    required this.svg,
    this.tooltip,
    required this.onTap,
  });
  final String svg;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  State<_MiniIcon> createState() => _MiniIconState();
}

class _MiniIconState extends State<_MiniIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final target = _hover ? c.primary : c.textDim;
    final btn = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.onTap,
        canRequestFocus: false,
        excludeFromSemantics: true,
        borderRadius: NymRadius.rxs,
        child: SizedBox(
          key: const ValueKey('sectionIconBox'),
          width: 32,
          height: 32,
          child: Center(
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: target),
            duration: const Duration(milliseconds: 200),
            curve: Curves.ease,
            builder: (context, color, _) => NymSvgIcon(
              widget.svg,
              size: 14,
              color: color ?? target,
            ),
          ),
          ),
        ),
      ),
    );
    return HitSlop(
      child: NymFocusable(
        onActivate: widget.onTap,
        tooltip: widget.tooltip,
        radius: const BorderRadius.all(Radius.circular(4)),
        child: btn,
      ),
    );
  }
}

class _LockedChatsEntry extends StatelessWidget {
  const _LockedChatsEntry({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Stack(
      key: const ValueKey('locked-chats-entry'),
      clipBehavior: Clip.none,
      children: [
        _MiniIcon(
          svg: ChatLockIcons.lock,
          tooltip: tr(ChatLockStrings.lockedChats),
          onTap: onTap,
        ),
        if (count > 0)
          Positioned(
            top: -6,
            right: -8,
            child: IgnorePointer(
              child: Container(
                key: const ValueKey('locked-chats-badge'),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: c.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  count > 99 ? '99+' : '$count',
                  style: TextStyle(
                    color: c.bg,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Group row in the PM list; a hold opens the one-item "Leave conversation" menu.
class _GroupListItem extends ConsumerWidget {
  const _GroupListItem({
    super.key,
    required this.group,
    required this.active,
    required this.unread,
    required this.textSize,
    required this.selfPubkey,
    required this.users,
    required this.onTap,
  });

  final Group group;
  final bool active;
  final int unread;
  final double textSize;
  final String selfPubkey;
  final Map<String, User> users;
  final VoidCallback onTap;

  void _leaveMenu(BuildContext context, WidgetRef ref, Offset at) {
    showSidebarQuickMenu(context, at, groupId: group.id, [
      ...chatNavSidebarItems(ref, 'group-${group.id}'),
      ...chatLockSidebarItems(ref, 'group-${group.id}'),
      ...chatToolSidebarItems(context, 'group-${group.id}'),
      SidebarQuickMenuItem(
        label: tr('Leave conversation'),
        svg: NymIcons.logout,
        danger: true,
        // Danger confirm before leaving.
        onSelected: () async {
          if (!context.mounted) return;
          final ok = await showAppConfirm(
            context,
            tr('Leave and delete this group conversation?'),
            danger: true,
            okLabel: tr('Leave'),
          );
          if (!ok || !context.mounted) return;
          await ref.read(nostrControllerProvider).leaveGroup(group.id);
        },
      ),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    ref.watch(appStateProvider.select((a) => a.contentFilterSignature));
    final name = ref.read(appStateProvider).groupLabel(group);
    ref.watch(chatNavRevisionProvider);
    final pinned = !active &&
        ref.read(chatNavProvider).pinIndexOfChat('group-${group.id}') >= 0;
    final preview = sidebarRowPreview(ref, 'group-${group.id}', 'group');

    final Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: SidebarRowGestures(
        onTap: onTap,
        onShowMenu: (pos) {
          _leaveMenu(context, ref, pos);
          return true;
        },
        builder: (context, hovered) => Stack(
          children: [
            Container(
              key: const ValueKey('sidebarRowBox'),
              constraints: const BoxConstraints(minHeight: kSidebarRowMinH),
              padding: EdgeInsets.fromLTRB(hovered ? 14 : 12, 6, 12, 6),
              decoration: BoxDecoration(
                color: active
                    ? (c.isLight
                        ? Colors.black.withValues(alpha: 0.06)
                        : c.primaryA(0.10))
                    : hovered
                        ? (c.isLight
                            ? Colors.black.withValues(alpha: 0.04)
                            : Colors.white.withValues(alpha: 0.06))
                        : pinned
                            ? const Color(0x1A9696A0)
                            : Colors.transparent,
                borderRadius: NymRadius.rxs,
                border: Border.all(
                  color: active
                      ? c.primaryA(0.20)
                      : pinned
                          ? const Color(0x339696A0)
                          : Colors.transparent,
                  width: 1,
                ),
                boxShadow: active && !c.isLight
                    ? [BoxShadow(color: c.primaryA(0.05), blurRadius: 12)]
                    : null,
              ),
              child: Row(
                children: [
                  KeyedSubtree(
                    key: const ValueKey('sidebarLead'),
                    child: GroupSidebarAvatar(
                        group: group,
                        selfPubkey: selfPubkey,
                        users: users,
                        size: kSidebarIcon),
                  ),
                  const SizedBox(width: kSidebarGap),
                  Expanded(
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    Text.rich(
                      key: const ValueKey('sidebarName'),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      TextSpan(
                        style: TextStyle(
                          color: c.textDim,
                          fontSize: textSize,
                          fontWeight: FontWeight.w400,
                          height: 1.3,
                        ),
                        children: [
                          TextSpan(text: name),
                          TextSpan(
                            text:
                                ' · ${_abbreviateNumber(group.members.length)}',
                            style: TextStyle(
                              color: context.highContrast
                                  ? legibleOn(c.textDim, sidebarRowBg(c))
                                  : c.textDim.withValues(alpha: 0.55),
                              fontSize: textSize * 0.8,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (preview.text.isNotEmpty)
                      rowPreviewLine(context, preview.text, 'group',
                          preview.dim, preview.sender, preview.bodyAt),
                    ],
                    ),
                  ),
                  rowTimeLabel(context, preview.time),
                  ChatNavRowBadges(storageKey: 'group-${group.id}'),
                  if (unread > 0) ...[
                    const SizedBox(width: 5),
                    SidebarUnreadPill(count: unread),
                  ],
                  const SizedBox(width: kSidebarMenuReserve),
                ],
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: SidebarRowMenuButton(
                semanticLabel: 'Group menu',
                onShowMenu: (pos) {
                  _leaveMenu(context, ref, pos);
                  return true;
                },
              ),
            ),
            if (active)
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
                        color: c.primary,
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(3),
                          bottomRight: Radius.circular(3),
                        ),
                        boxShadow: [
                          BoxShadow(color: c.primaryA(0.4), blurRadius: 8),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return PinnedReorder(
      storageKey: 'group-${group.id}',
      onHoldMenu: (pos) {
        _leaveMenu(context, ref, pos);
        return true;
      },
      child: row,
    );
  }
}

/// Full-width collapse toggle: "View N more..." first, "Show N more..." per step, "Show less" when expanded.
class _ViewMoreButton extends StatefulWidget {
  const _ViewMoreButton({
    required this.more,
    required this.onTap,
    this.stepMore = false,
  });
  final int more;
  final VoidCallback onTap;

  final bool stepMore;

  @override
  State<_ViewMoreButton> createState() => _ViewMoreButtonState();
}

class _ViewMoreButtonState extends State<_ViewMoreButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Three ASCII periods, not U+2026, as the PWA writes it.
    final label = widget.more > 0
        ? (widget.stepMore
            ? tr('SHOW {count} MORE...',
                {'count': _abbreviateNumber(widget.more)})
            : tr('VIEW {count} MORE...',
                {'count': _abbreviateNumber(widget.more)}))
        : tr('SHOW LESS');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: NymRadius.rxs,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: NymRadius.rxs,
              color: _hover ? c.primaryA(0.08) : null,
              border:
                  Border.all(color: _hover ? c.primaryA(0.3) : c.glassBorder),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _hover ? c.text : c.textDim,
                fontSize: 11,
                letterSpacing: 1,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Discover-by-typing join row shown when the channel search matches nothing.
class _SearchCreatePrompt extends StatefulWidget {
  const _SearchCreatePrompt({required this.term, required this.onTap});
  final String term;
  final VoidCallback onTap;

  @override
  State<_SearchCreatePrompt> createState() => _SearchCreatePromptState();
}

class _SearchCreatePromptState extends State<_SearchCreatePrompt> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final isGeo = isValidGeohash(widget.term);
    final label = isGeo
        ? tr('Join geohash channel "{term}"', {'term': widget.term})
        : tr('Join channel "{term}"', {'term': widget.term});
    final loc = isGeo ? geohashLocationLabel(widget.term) : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 0),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: NymRadius.rxs,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: NymRadius.rxs,
              color: _hover ? c.primaryA(0.1) : c.bgTertiary,
              border: Border.all(color: _hover ? c.primary : c.border),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textBright, fontSize: 12),
                  ),
                ),
                if (loc.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    loc,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.textDim, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _abbreviateNumber(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
  }
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

/// Section search input; clearing it resets the filter via [onChanged].
class _SearchField extends StatefulWidget {
  const _SearchField({required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hasValue = _controller.text.isNotEmpty;
    final focused = _focusNode.hasFocus;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NymRadius.rxs,
        boxShadow: NymField.ring(c, focused),
      ),
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        // The global `input` rule forces pure white text in dark mode.
        style:
            TextStyle(color: c.isLight ? c.text : Colors.white, fontSize: 12),
        cursorColor: c.isLight ? Colors.black : Colors.white,
        onChanged: (v) {
          widget.onChanged(v);
          setState(() {});
        },
        decoration: NymField.decoration(c,
          hint: widget.hint,
          fontSize: 12,
          radius: NymRadius.rxs,
          contentPadding: const EdgeInsets.fromLTRB(12, 8, 28, 8),
          suffixIcon: hasValue
              ? _SearchClear(onTap: () {
                  _controller.clear();
                  widget.onChanged('');
                  setState(() {});
                })
              : null,
          suffixIconConstraints:
              const BoxConstraints(minWidth: 28, minHeight: 0)),
      ),
    );
  }
}

class _SearchClear extends StatefulWidget {
  const _SearchClear({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_SearchClear> createState() => _SearchClearState();
}

class _SearchClearState extends State<_SearchClear> {
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
        child: Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Icon(
            Icons.close,
            size: 14,
            color: _hover ? c.danger : c.textDim,
          ),
        ),
      ),
    );
  }
}


class _IdentityBell extends ConsumerStatefulWidget {
  const _IdentityBell();

  @override
  ConsumerState<_IdentityBell> createState() => _IdentityBellState();
}

class _IdentityBellState extends ConsumerState<_IdentityBell> {
  bool _hover = false;
  bool _focus = false;

  void _open() => showNotificationsPanel(context);

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final unread =
        ref.watch(notificationHistoryProvider.select((s) => s.unread));
    final enabled =
        ref.watch(settingsProvider.select((s) => s.notificationsEnabled));
    final count = enabled ? unread : 0;
    final lit = _hover || _focus;
    final label = tr('Notifications');
    final button = InkWell(
      borderRadius: NymRadius.rsm,
      onTap: _open,
      onHover: (v) => setState(() => _hover = v),
      onFocusChange: (v) => setState(() => _focus = v),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: lit
              ? (c.isLight
                  ? Colors.black.withValues(alpha: 0.05)
                  : c.primaryA(0.1))
              : Colors.transparent,
          borderRadius: NymRadius.rsm,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            NymSvgIcon(NymIcons.bell, size: 18, color: lit ? c.primary : c.textDim),
            if (count > 0)
              Positioned(
                top: -13,
                right: -15,
                child: Container(
                  key: const ValueKey('identityNotifBadge'),
                  constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: badgeFill(context, c.danger),
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    style: const TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return HitSlop(
      child: Semantics(
        key: const ValueKey('identityNotifBtn'),
        container: true,
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: _open,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: NymTooltip(message: label, child: button),
        ),
      ),
    );
  }
}

class _IdentityClose extends StatefulWidget {
  const _IdentityClose({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_IdentityClose> createState() => _IdentityCloseState();
}

class _IdentityCloseState extends State<_IdentityClose> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final lit = _hover || _focus;
    final label = tr('Close');
    final button = InkWell(
      borderRadius: NymRadius.rsm,
      onTap: widget.onTap,
      onHover: (v) => setState(() => _hover = v),
      onFocusChange: (v) => setState(() => _focus = v),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: lit
              ? (c.isLight
                  ? Colors.black.withValues(alpha: 0.05)
                  : c.primaryA(0.1))
              : Colors.transparent,
          borderRadius: NymRadius.rsm,
        ),
        child: NymSvgIcon(NymIcons.close,
            size: 18, color: lit ? c.primary : c.textDim),
      ),
    );
    return HitSlop(
      child: Semantics(
        key: const ValueKey('identityCloseBtn'),
        container: true,
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: widget.onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: NymTooltip(message: label, child: button),
        ),
      ),
    );
  }
}

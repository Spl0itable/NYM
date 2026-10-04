import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../features/chat_tools/chat_tools_ui.dart';
import '../../features/composer/composer_model.dart';
import '../../features/notifications/notifications_panel.dart';
import '../../features/group_tools/group_tools_ui.dart';
import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/channels/channel_manager.dart';
import '../../features/globe/geohash_explorer.dart';
import '../../features/mesh/mesh_controller.dart';
import '../../features/groups/group_logic.dart';
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
import '../../models/pm_conversation.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/app_dialog.dart';
import '../common/nym_avatar.dart';
import '../../features/chat_nav/chat_nav_providers.dart';
import '../../features/chat_nav/chat_nav_ui.dart';
import '../../features/chat_lock/chat_lock.dart' show ChatLockStrings;
import '../../features/chat_lock/chat_lock_providers.dart';
import '../../features/chat_lock/chat_lock_ui.dart';
import '../nym_icons.dart';
import 'channel_list_item.dart';
import 'pm_context_menu.dart';
import 'pm_list_item.dart';
import 'sidebar_row_gestures.dart';
import 'sidebar_row_menu_button.dart';
import 'sidebar_skeleton.dart';
import 'user_list_item.dart';
import '../common/panic_hold_detector.dart';

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
  const Sidebar({super.key, this.onItemSelected, this.compact = false});

  /// Called after a row is tapped, so the mobile drawer can close.
  final VoidCallback? onItemSelected;

  /// Compact (<=1024) layout shows the `.sidebar-actions` row; wide layouts put those actions in the header.
  final bool compact;

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  final Set<_SectionId> _collapsed = {};

  late List<_SectionId> _order;

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
    // Persisted collapse and order are restored in didChangeDependencies, where ref.read is valid.
  }

  @override
  void dispose() {
    _skelTimer?.cancel();
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

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final textSize = settings.textSize.toDouble();

    final app = ref.watch(appStateProvider);
    final view = ref.watch(currentViewProvider);
    // While the mesh overlay is open nothing is active, so re-tapping the previous channel dismisses it.
    final meshOpen = ref.watch(meshScreenOpenProvider);
    // `#nymchat` and the active row are never hidden, keeping "Unhide channel" reachable.
    final sortByProximity = ref
        .watch(settingsProvider.select((settings) => settings.sortByProximity));
    final hideNonPinned = ref
        .watch(settingsProvider.select((settings) => settings.hideNonPinned));
    final location = ref.watch(userLocationProvider);
    final activeChannelKey = (!meshOpen && view.kind == ViewKind.channel)
        ? view.id.toLowerCase()
        : '';
    final visibleChannels = app.channels
        .where((ch) => !app.blockedChannels.contains(ch.key))
        .where((ch) =>
            ch.key == kDefaultChannel ||
            ch.key == activeChannelKey ||
            (!app.hiddenChannels.contains(ch.key) &&
                !(hideNonPinned && !app.pinnedChannels.contains(ch.key))))
        .toList();
    var channels = ChannelManager.sortChannels(
      visibleChannels,
      ChannelSortContext(
        activeKey: activeChannelKey,
        pinned: app.pinnedChannels,
        lastActivity: app.channelLastActivity,
        unreadCounts: app.unreadCounts,
        sortByProximity: sortByProximity,
        userLocation: location,
      ),
    );
    int orderBand(ChannelEntry ch) {
      if (ch.key == kDefaultChannel) return -4;
      if (app.pinnedChannels.contains(ch.key)) return -3;
      if (ch.key == activeChannelKey) return -2;
      if ((app.unreadCounts[ch.storageKey] ?? 0) > 0) return -1;
      return 0;
    }

    ref.watch(chatLockRevisionProvider);
    final chatLock = ref.read(chatLockProvider);
    channels = [
      for (var band = -4; band <= 0; band++)
        ...channels.where((ch) =>
            orderBand(ch) == band &&
            !chatLock.isConversationLocked(ch.storageKey)),
    ];
    final pinned = app.pinnedChannels;
    final pms = ref.watch(pmListProvider);
    // Backfill PM peers' profiles so older conversations show real avatars; debounced, so cheap per build.
    ref
        .read(nostrControllerProvider)
        .ensureProfiles([for (final p in pms) p.pubkey]);
    final groups = ref.watch(groupsProvider);
    final users = ref.watch(usersProvider);
    final unread = ref.watch(unreadCountsProvider);

    // Mesh-only DM peers get a Bluetooth glyph; channels are dual-transport and carry none.
    final meshPmPubkeys =
        ref.watch(meshControllerProvider.select((s) => s.meshPmPubkeys));

    // Groups and PMs share one list, newest-first by last-message time.
    final byTime = <_PmEntry>[
      for (final pm in pms) _PmEntry.pm(pm),
      for (final g in groups) _PmEntry.group(g),
    ]..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    final entryByKey = <String, _PmEntry>{
      for (final e in byTime)
        e.group != null
            ? 'group-${e.group!.id}'
            : 'pm-${e.pm!.pubkey.toLowerCase()}': e,
    };
    final pmEntries = [
      for (final k in chatNavPinSort(ref, entryByKey.keys.toList()))
        if (!chatLock.isConversationLocked(k)) entryByKey[k]!,
    ];
    final lockBadges = ref.watch(chatLockBadgesProvider);

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

    final notifier = ref.read(appStateProvider.notifier);

    // Channel skeletons follow the static `#nymchat` row, so they clear on the first non-default channel.
    final showChannelSkel =
        !_skelTimedOut && !app.channels.any((ch) => ch.key != kDefaultChannel);
    final showPmSkel = !_skelTimedOut && pmEntries.isEmpty;

    void select(ChatView v) {
      // Dismiss the mesh overlay on any tap, even on the current view, since switchView is then a no-op.
      if (ref.read(meshScreenOpenProvider)) {
        ref.read(meshScreenOpenProvider.notifier).state = false;
      }
      notifier.switchView(v);
      widget.onItemSelected?.call();
    }

    // PM/group-only mode restricts the nyms list to PM peers and group members.
    final Set<String>? pmOnlyPubkeys = settings.groupChatPMOnlyMode
        ? {
            for (final pm in pms) pm.pubkey,
            for (final g in groups) ...g.members,
          }
        : null;
    // No self exclusion: the PWA lists and counts your own nym.
    final onlineUsers = users.values
        .where((u) => pmOnlyPubkeys == null || pmOnlyPubkeys.contains(u.pubkey))
        .toList()
      ..sort((a, b) {
        int rank(User u) {
          // Verified bots rank as online.
          switch (u.effectiveStatus(
              isVerifiedBot: kVerifiedBotPubkeys.contains(u.pubkey))) {
            case UserStatus.online:
              return 0;
            case UserStatus.away:
              return 1;
            default:
              return 2;
          }
        }

        final r = rank(a) - rank(b);
        if (r != 0) return r;
        // Status ties break on the suffix-stripped, lowercased base nym.
        return stripPubkeySuffix(a.nym)
            .toLowerCase()
            .compareTo(stripPubkeySuffix(b.nym).toLowerCase());
      });

    // Online count: non-hidden recent nyms, plus verified bots regardless of recency.
    final controller = ref.read(nostrControllerProvider);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nymActiveCount = onlineUsers.where((u) {
      final isBot = kVerifiedBotPubkeys.contains(u.pubkey);
      final st = u.effectiveStatus(isVerifiedBot: isBot);
      if (st == UserStatus.hidden || st == UserStatus.offline) return false;
      return nowMs - u.lastSeen < kActiveThresholdMs || isBot;
    }).length;

    // Applies the search term and 20-row cap; searching disables the cap.
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

    Widget sectionFor(_SectionId s) {
      switch (s) {
        case _SectionId.channels:
          final term = _channelTerm.toLowerCase();
          final r = capped<ChannelEntry>(
            channels,
            term,
            (ch) => (ch.isGeohash ? ch.geohashKey : ch.channel)
                .toLowerCase()
                .contains(term),
            _channelExpanded,
          );
          return _NavSection(
            key: const ValueKey('section-channels'),
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
              tooltip: tr('Explore geohash channels'),
              onTap: _openDiscover,
            ),
            searchHint: tr('Search channels...'),
            children: [
              for (final ch in r.rows)
                ChannelListItem(
                  entry: ch,
                  active: !meshOpen &&
                      view.kind == ViewKind.channel &&
                      view.id == ch.key,
                  pinned: pinned.contains(ch.key),
                  // `unreadCounts` is keyed by storageKey, not the bare registry key.
                  unread: unread[ch.storageKey] ?? 0,
                  textSize: textSize,
                  onTap: () => select(ChatView.channel(ch.key)),
                ),
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
                  channels.length > _collapsedCap)
                _ViewMoreButton(
                  more: 0,
                  onTap: () => setState(() => _channelExpanded = false),
                ),
              // When the search matches no channel, offer a row to join it by name or geohash.
              if (term.trim().isNotEmpty &&
                  !channels.any((ch) => ch.key == term.trim()))
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
        case _SectionId.pms:
          final term = _pmTerm.toLowerCase();
          // Matches the whole rendered name (including `#suffix` or member count), like the PWA.
          final r = capped<_PmEntry>(
            pmEntries,
            term,
            (e) {
              final String rendered;
              if (e.group != null) {
                final g = e.group!;
                final name = g.name.isEmpty ? 'Group' : g.name;
                rendered = '$name · ${_abbreviateNumber(g.members.length)}';
              } else {
                rendered =
                    '${pickDisplayNym(users[e.pm!.pubkey]?.nym, e.pm!.nym)}'
                    '#${getPubkeySuffix(e.pm!.pubkey)}';
              }
              return rendered.toLowerCase().contains(term);
            },
            _pmExpanded,
          );
          return _NavSection(
            key: const ValueKey('section-pms'),
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
                    count: lockBadges.shown,
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
            children: [
              // No fixed Nymbot row: the bot appears here only once a real PM thread with it exists.
              if (showPmSkel)
                for (final f in const [0.58, 0.70, 0.42])
                  SidebarSkeletonRow.pm(barWidthFactor: f),
              for (final e in r.rows)
                if (e.group != null)
                  _GroupListItem(
                    group: e.group!,
                    active: !meshOpen &&
                        view.kind == ViewKind.group &&
                        view.id == e.group!.id,
                    unread:
                        unread[GroupLogic.groupStorageKey(e.group!.id)] ?? 0,
                    textSize: textSize,
                    selfPubkey: app.selfPubkey,
                    users: users,
                    onTap: () => select(ChatView.group(e.group!.id)),
                  )
                else
                  PMListItem(
                    nym: e.pm!.nym,
                    pubkey: e.pm!.pubkey,
                    active: !meshOpen &&
                        view.kind == ViewKind.pm &&
                        view.id == e.pm!.pubkey,
                    unread: unread[e.pm!.pubkey] ?? 0,
                    textSize: textSize,
                    mesh: meshPmPubkeys.contains(e.pm!.pubkey.toLowerCase()),
                    onTap: () => select(ChatView.pm(e.pm!.pubkey)),
                  ),
              if (r.more > 0)
                _ViewMoreButton(
                  more: r.more,
                  onTap: () => setState(() => _pmExpanded = true),
                )
              else if (term.isEmpty &&
                  _pmExpanded &&
                  pmEntries.length > _collapsedCap)
                _ViewMoreButton(
                  more: 0,
                  onTap: () => setState(() => _pmExpanded = false),
                ),
            ],
          );
        case _SectionId.nyms:
          final term = _nymTerm.toLowerCase();
          // Searching shows all matches; the search matches the suffix-stripped lowercase base nym.
          final filtered = term.isEmpty
              ? onlineUsers
              : onlineUsers
                  .where((u) =>
                      stripPubkeySuffix(u.nym).toLowerCase().contains(term))
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
          return _NavSection(
            key: const ValueKey('section-nyms'),
            sectionKey: TutorialTargets.keyFor(TutorialTarget.userList),
            title: tr('Nyms ({count} online)',
                {'count': _abbreviateNumber(nymActiveCount)}),
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
            children: [
              if (!_skelTimedOut && onlineUsers.isEmpty)
                for (final f in const [0.70, 0.42, 0.50, 0.58, 0.70])
                  SidebarSkeletonRow.nym(barWidthFactor: f),
              for (final u in nymRows)
                UserListItem(
                  user: u,
                  textSize: textSize,
                  // A tap opens the profile menu (not a PM); the panel ignores the anchor.
                  onTap: () =>
                      showUserContextMenu(context, ref, u, Offset.zero),
                ),
              // The view-more control exists only for an unsearched list over 20.
              if (term.isEmpty && total > _collapsedCap)
                if (_nymExpandedCap == null)
                  _ViewMoreButton(
                    more: total - _collapsedCap,
                    onTap: () =>
                        setState(() => _nymExpandedCap = _expandedStep),
                  )
                else if (remaining > 0)
                  _ViewMoreButton(
                    more: remaining < _expandedStep ? remaining : _expandedStep,
                    stepMore: true,
                    onTap: () => setState(() =>
                        _nymExpandedCap = _nymExpandedCap! + _expandedStep),
                  )
                else
                  _ViewMoreButton(
                    more: 0,
                    onTap: () => setState(() => _nymExpandedCap = null),
                  ),
            ],
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
        // Scrollbar thumb is transparent at rest and fades in while scrolling or hovering.
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
            child: ListView(
              controller: _scroll,
              padding: EdgeInsets.zero,
              children: [
                _header(context, app.selfNym),
                if (widget.compact)
                  _SidebarActions(onItemSelected: widget.onItemSelected),
                // PM/group-only mode hides the whole channels section.
                for (final s in _order)
                  if (!(settings.groupChatPMOnlyMode &&
                      s == _SectionId.channels))
                    sectionFor(s),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
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
    final connectedRelays = ref.watch(
      appStateProvider.select((s) => s.connectedRelays),
    );
    final proxyMode = ref.watch(
      appStateProvider.select((s) => s.proxyMode),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: c.isLight
            ? Colors.white.withValues(alpha: 0.3)
            : Colors.black.withValues(alpha: 0.15),
        border: widget.compact
            ? null
            : Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 15),
          // Bind only the nym box, not the status row: the raw Listener bypasses the gesture arena.
          PanicHoldDetector(
            onTap: () => NickEditModal.open(context),
            onHold: () => _triggerPanic(context),
            child: MouseRegion(
              onEnter: (_) => setState(() => _nymHover = true),
              onExit: (_) => setState(() => _nymHover = false),
              child: Container(
                key: TutorialTargets.keyFor(TutorialTarget.nymDisplay),
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: _nymHover
                      ? (c.isLight
                          ? Colors.black.withValues(alpha: 0.07)
                          : Colors.white.withValues(alpha: 0.07))
                      : c.insetFill,
                  border: Border.all(
                    color: _nymHover && !c.isLight
                        ? c.primaryA(0.3)
                        : c.glassBorder,
                  ),
                  borderRadius: NymRadius.rsm,
                  boxShadow: _nymHover
                      ? [BoxShadow(color: c.primaryA(0.08), blurRadius: 15)]
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tr('YOUR NYM (CLICK TO EDIT)'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.textDim,
                        fontSize: 10,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        NymAvatar(
                          seed: ref.read(appStateProvider).selfPubkey,
                          size: 32,
                          imageUrl: ref
                              .read(appStateProvider)
                              .users[ref.read(appStateProvider).selfPubkey]
                              ?.profile
                              ?.picture,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _NymValueText(
                            nym: nym,
                            pubkey: ref.read(appStateProvider).selfPubkey,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (ref.watch(accountsProvider) != null) ...[
            const SizedBox(height: 6),
            const AccountSwitchButton(),
          ],
          const SizedBox(height: 10),
          _ConnectionStatusIndicator(
            connectedCount: connectedRelays,
            proxyMode: proxyMode,
          ),
          _MeshStatusIndicator(onItemSelected: widget.onItemSelected),
          const _TranslatingIndicator(),
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
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: base),
          // The base `.nym-suffix` rule still applies, so the suffix dims and thins.
          TextSpan(
            text: '#$suffix',
            style: TextStyle(
              color: c.textDim.withValues(alpha: 0.7),
              fontSize: 15 * 0.9,
              fontWeight: FontWeight.w100,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
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
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => RelayStatsModal.open(context),
        child: Row(
          key: TutorialTargets.keyFor(TutorialTarget.statusIndicator),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
          ],
        ),
      ),
    );
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
    return Padding(
      padding: const EdgeInsets.only(top: 8),
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
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              tr('Translating...'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.textDim, fontSize: 12),
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
            : tr('Mesh · {count} peer(s)', {'count': peerCount}));
    final color = active ? c.primary : c.textDim;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            // Idempotent; an already-open overlay stays open.
            ref.read(meshScreenOpenProvider.notifier).state = true;
            onItemSelected?.call();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                NymSvgIcon(NymIcons.bluetooth, size: 12, color: color),
                const SizedBox(width: 5),
                Text(label, style: TextStyle(color: c.textDim, fontSize: 11)),
                if (active && mesh.linkCount > 0) ...[
                  const SizedBox(width: 6),
                  Text('${mesh.linkCount} link(s)',
                      style: TextStyle(
                          color: c.textDim.withValues(alpha: 0.7),
                          fontSize: 10)),
                ],
              ],
            ),
          ),
        ),
      ),
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
    void go(void Function() open) {
      onItemSelected?.call();
      open();
    }

    Widget tile(String id) => switch (id) {
          'notifications' => _ActionButton(
              key: const ValueKey('menu-notifications'),
              svg: NymIcons.bell,
              label: tr('Notifications'),
              primary: true,
              badge: notifEnabled ? unread : 0,
              onTap: () => go(() => showNotificationsPanel(context)),
            ),
          'saved' => _ActionButton(
              key: const ValueKey('menu-saved'),
              svg: ChatToolIcons.saved,
              label: tr('Saved'),
              primary: true,
              onTap: () => go(() => SavedMessagesPanel.open(context)),
            ),
          'calls' => _ActionButton(
              key: const ValueKey('gtCallsButton'),
              svg: GroupToolIcons.calls,
              label: tr('Calls'),
              primary: true,
              onTap: () => go(() => showGtCallLinks(context)),
            ),
          'flair' => _ActionButton(
              key: const ValueKey('menu-flair'),
              svg: NymIcons.starFlair,
              label: tr('Flair'),
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

    final rows = mainMenuRows('mobile').grid;
    return Semantics(
      label: tr('Main menu'),
      container: true,
      child: Container(
        key: TutorialTargets.keyFor(TutorialTarget.mainMenu),
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.glassBorder)),
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
                    if (j > 0) const SizedBox(width: 6),
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
    this.primary = false,
    this.badge = 0,
  });

  final String svg;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final int badge;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final Color fill;
    final Color borderColor;
    final Color fg;
    if (c.isLight) {
      fill = Colors.black.withValues(alpha: _hover ? 0.06 : 0.03);
      borderColor = _hover ? c.primary : Colors.black.withValues(alpha: 0.1);
      fg = c.primary;
    } else {
      fill = _hover ? c.primaryA(0.12) : Colors.white.withValues(alpha: 0.05);
      borderColor = _hover ? c.primaryA(0.3) : c.glassBorder;
      fg = _hover ? c.primary : c.text;
    }
    return Expanded(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: NymRadius.rxs,
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(
                  color: widget.primary && !_hover
                      ? c.primaryA(0.25)
                      : borderColor),
              borderRadius: NymRadius.rxs,
              // The hover glow applies in both modes, as the CSS cascade does.
              boxShadow: _hover
                  ? [BoxShadow(color: c.primaryA(0.1), blurRadius: 15)]
                  : null,
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
                            color: c.danger,
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
                  widget.label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 9 * 0.02,
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
class _NavSection extends StatelessWidget {
  const _NavSection({
    super.key,
    required this.sectionKey,
    required this.title,
    required this.open,
    required this.searching,
    required this.onToggleOpen,
    required this.onToggleSearch,
    required this.onSearchChanged,
    required this.onLongPressTitle,
    required this.searchHint,
    required this.children,
    required this.reorderMode,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    this.leadingIcon,
    this.isUserList = false,
  });

  final Key sectionKey;
  final String title;
  final bool open;
  final bool searching;
  final VoidCallback onToggleOpen;
  final VoidCallback onToggleSearch;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onLongPressTitle;
  final String searchHint;
  final List<Widget> children;
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
        ? const EdgeInsets.all(10)
        : const EdgeInsets.fromLTRB(12, 16, 12, 12);
    return Container(
      padding: pad,
      decoration: isUserList
          ? null
          : BoxDecoration(
              border: Border(bottom: BorderSide(color: c.glassBorder)),
            ),
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
                  Expanded(
                    child: Text(
                      title.toUpperCase(),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textDim,
                        fontSize: 10,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (leadingIcon != null) ...[
                    leadingIcon!,
                    const SizedBox(width: 10),
                  ],
                  _MiniIcon(
                    svg: NymIcons.search,
                    tooltip: tr('Search'),
                    onTap: onToggleSearch,
                  ),
                  const SizedBox(width: 10),
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
          // Collapsing hides everything but the title row, including an open search input.
          if (open && searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
              child: _SearchField(
                hint: searchHint,
                onChanged: onSearchChanged,
              ),
            ),
          KeyedSubtree(
            key: sectionKey,
            child: open
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
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
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // Fixed white fill in both modes; the CSS has no light override.
              color: hovered ? c.primary : Colors.white.withValues(alpha: 0.08),
              borderRadius: NymRadius.rxs,
            ),
            child: NymSvgIcon(
              widget.svg,
              size: 12,
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
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
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
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: btn)
        : btn;
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

class _PmEntry {
  _PmEntry.pm(PMConversation this.pm)
      : group = null,
        lastMessageTime = pm.lastMessageTime;
  _PmEntry.group(Group g)
      : pm = null,
        group = g,
        lastMessageTime = g.lastMessageTime;

  final PMConversation? pm;
  final Group? group;
  final int lastMessageTime;
}

/// `{C}` is substituted with the resolved primary hex at render time.
const String _groupGlyphSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
    'stroke="{C}" stroke-width="1.75" stroke-linecap="round" '
    'stroke-linejoin="round">'
    '<circle cx="12" cy="7" r="2.75"/>'
    '<path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/>'
    '<circle cx="4.5" cy="9.5" r="2"/>'
    '<path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/>'
    '<circle cx="19.5" cy="9.5" r="2"/>'
    '<path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>';

String _hex(Color c) {
  int ch(double v) => (v * 255).round() & 0xff;
  return '#${ch(c.r).toRadixString(16).padLeft(2, '0')}'
      '${ch(c.g).toRadixString(16).padLeft(2, '0')}'
      '${ch(c.b).toRadixString(16).padLeft(2, '0')}';
}

/// Group row in the PM list; a hold opens the one-item "Leave conversation" menu.
class _GroupListItem extends ConsumerWidget {
  const _GroupListItem({
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
    showSidebarQuickMenu(context, at, [
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
    final avatarUrl = proxiedAvatarUrl(group.avatar);
    final name = group.name.isEmpty ? tr('Group') : group.name;
    final otherMembers =
        group.members.where((pk) => pk != selfPubkey).toList(growable: false);
    ref.watch(chatNavRevisionProvider);
    final pinned = !active &&
        ref.read(chatNavProvider).pinIndexOfChat('group-${group.id}') >= 0;

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
              constraints: const BoxConstraints(minHeight: 36),
              padding: EdgeInsets.fromLTRB(hovered ? 14 : 12, 9, 12, 9),
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
                  if (avatarUrl != null && avatarUrl.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ClipOval(
                        child: NymAvatar(
                          seed: group.id,
                          size: 26,
                          imageUrl: group.avatar,
                        ),
                      ),
                    )
                  else if (otherMembers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _GroupAvatarStack(
                        members: otherMembers.take(3).toList(),
                        users: users,
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _GroupIconWrap(c: c),
                    ),
                  Expanded(
                    // Long names wrap rather than ellipsize; flex:1 pushes the unread pill flush right.
                    child: RichText(
                      text: TextSpan(
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
                              color: c.textDim.withValues(alpha: 0.55),
                              fontSize: textSize * 0.8,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ChatNavRowBadges(storageKey: 'group-${group.id}'),
                  if (unread > 0) ...[
                    const SizedBox(width: 5),
                    _GroupUnreadPill(count: unread),
                  ],
                  const SizedBox(width: 2),
                  SidebarRowMenuButton(
                    semanticLabel: 'Group menu',
                    onShowMenu: (pos) {
                      _leaveMenu(context, ref, pos);
                      return true;
                    },
                  ),
                ],
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

/// Up to 3 overlapping member avatars plus a corner group-glyph badge.
class _GroupAvatarStack extends StatelessWidget {
  const _GroupAvatarStack({required this.members, required this.users});

  final List<String> members;
  final Map<String, User> users;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return SizedBox(
      width: 34,
      height: 22,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < members.length && i < 3; i++)
            Positioned(
              left: i * 9.0,
              top: 0,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: c.bg, width: 1),
                ),
                child: ClipOval(
                  child: NymAvatar(
                    seed: members[i],
                    size: 18,
                    imageUrl: users[members[i]]?.profile?.picture,
                  ),
                ),
              ),
            ),
          Positioned(
            right: -4,
            bottom: -3,
            child: Container(
              width: 13,
              height: 13,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.bgSecondary,
                shape: BoxShape.circle,
                border: Border.all(color: c.primaryA(0.3), width: 1),
              ),
              child: SvgPicture.string(
                _groupGlyphSvg.replaceAll('{C}', _hex(c.primary)),
                width: 8,
                height: 8,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fallback icon used only when the group has no other members.
class _GroupIconWrap extends StatelessWidget {
  const _GroupIconWrap({required this.c});
  final NymColors c;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.primaryA(0.10),
        border: Border.all(color: c.primaryA(0.25), width: 1),
      ),
      child: SvgPicture.string(
        _groupGlyphSvg.replaceAll('{C}', _hex(c.primary)),
        width: 14,
        height: 14,
      ),
    );
  }
}

class _GroupUnreadPill extends StatelessWidget {
  const _GroupUnreadPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      constraints: const BoxConstraints(minWidth: 30),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.primary,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: c.bg,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
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
    // Light mode pins the fill with `!important`, even when focused.
    final Color fill = c.isLight
        ? Colors.black.withValues(alpha: 0.04)
        : Colors.white.withValues(alpha: focused ? 0.08 : 0.05);
    final Color restBorder =
        c.isLight ? Colors.black.withValues(alpha: 0.1) : c.glassBorder;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NymRadius.rxs,
        boxShadow: focused
            ? [
                BoxShadow(
                  color: c.primaryA(c.isLight ? 0.1 : 0.06),
                  spreadRadius: 3,
                ),
              ]
            : null,
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
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hint,
          hintStyle: TextStyle(color: c.textDim, fontSize: 12),
          contentPadding: const EdgeInsets.fromLTRB(12, 8, 28, 8),
          filled: true,
          fillColor: fill,
          suffixIcon: hasValue
              ? _SearchClear(onTap: () {
                  _controller.clear();
                  widget.onChanged('');
                  setState(() {});
                })
              : null,
          suffixIconConstraints:
              const BoxConstraints(minWidth: 28, minHeight: 0),
          border: OutlineInputBorder(
            borderRadius: NymRadius.rxs,
            borderSide: BorderSide(color: restBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: NymRadius.rxs,
            borderSide: BorderSide(color: restBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: NymRadius.rxs,
            borderSide: BorderSide(color: c.primaryA(0.30)),
          ),
        ),
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
          child: Text(
            '✕',
            style: TextStyle(
              color: _hover ? c.danger : c.textDim,
              fontSize: 14,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/channels/channel_manager.dart';
import '../../features/globe/geohash_explorer.dart';
import '../../features/groups/group_logic.dart';
import '../../features/identity/nick_edit_modal.dart';
import '../../features/identity/panic_overlay.dart';
import '../../features/identity/panic_wipe.dart';
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
import '../nym_icons.dart';
import 'channel_list_item.dart';
import 'pm_context_menu.dart';
import 'pm_list_item.dart';
import 'sidebar_row_gestures.dart';
import 'sidebar_skeleton.dart';
import 'user_list_item.dart';

/// The three reorderable sidebar sections (`data-section` ids in the PWA).
enum _SectionId { channels, pms, nyms }

extension _SectionIdName on _SectionId {
  /// The persisted id, matching the PWA `data-section` values
  /// (`channels` / `pms` / `nyms`).
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

/// The left sidebar: identity header + three collapsible nav sections
/// (PUBLIC CHANNELS, PRIVATE MESSAGES, ONLINE NYMS). Width 290 desktop / 300 in
/// the mobile drawer (caller sizes it). bg `--bg-secondary`, right hairline
/// border. (docs/specs/02 §1.1, §5.3)
///
/// The whole column is a single scroll container (`.sidebar { overflow-y:auto }`,
/// gap F7) — the identity header + action row scroll away with the lists.
/// `.sidebar-actions` only mounts on compact (<=1024) layouts (gap F3); on the
/// fixed desktop sidebar those actions live in the header instead.
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key, this.onItemSelected, this.compact = false});

  /// Called after a channel/PM is tapped (so the mobile drawer can close).
  final VoidCallback? onItemSelected;

  /// Compact (mobile/tablet, <=1024) layout: shows the `.sidebar-actions` row
  /// (Flair/Settings/About/Logout). On wide layouts those live in the header.
  final bool compact;

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  // Collapse state (persisted to `nym_sidebar_section_collapsed`, gap F11).
  final Set<_SectionId> _collapsed = {};

  // Section order (persisted to `nym_sidebar_section_order`, gap F12).
  late List<_SectionId> _order;

  // Reorder mode (500ms long-press on a title toggles it, gap F12).
  bool _reorderMode = false;

  bool _channelSearch = false;
  bool _pmSearch = false;
  bool _nymSearch = false;

  // Live search terms per section (PWA `channelSearchTerm` / `pmSearchTerm` /
  // `userSearchTerm`), lower-cased at filter time.
  String _channelTerm = '';
  String _pmTerm = '';
  String _nymTerm = '';

  // View-more expansion per section: collapsed lists cap at 20 rows
  // (`COLLAPSED_CAP`). Channels/PMs expand fully (a simple bool).
  bool _channelExpanded = false;
  bool _pmExpanded = false;

  // The Nyms list grows in 500-row steps (`EXPANDED_STEP`) rather than fully:
  // null = collapsed (cap 20); otherwise the live expanded cap, stepped up by
  // 500 per "Show N more…" click (users.js:1411-1422, 1705-1728).
  int? _nymExpandedCap;

  /// Collapsed row cap (`COLLAPSED_CAP` / `.list-collapsed :nth-child(n+21)`).
  static const int _collapsedCap = 20;

  /// Per-click growth of the expanded Nyms list (`EXPANDED_STEP`, users.js:1412).
  static const int _expandedStep = 500;

  bool _loaded = false;

  // `.nym-display:hover` (styles-shell.css:69-73) — mouse hover over the
  // identity box.
  bool _nymHover = false;

  // Drives the `.sidebar` scrollbar (thumb fades in while scrolling/hovering).
  final ScrollController _scroll = ScrollController();

  // `.sidebar-skeleton` safety clear: the PWA drops any shimmer rows that
  // never got cleared by real content after 8s (`_sidebarSkelTimer`,
  // init.js:105). Until then, each empty list shows its skeleton rows.
  bool _skelTimedOut = false;
  Timer? _skelTimer;

  @override
  void initState() {
    super.initState();
    _order = List.of(_SectionId.values);
    _skelTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _skelTimedOut = true);
    });
    // Restore persisted collapse + order on first build (the KV store is a
    // provider, so defer to didChangeDependencies where ref.read is valid).
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

    // Collapse list.
    final collapsedRaw = kv.getString(StorageKeys.sidebarSectionCollapsed);
    for (final id in _decodeIds(collapsedRaw)) {
      final s = _SectionIdName.fromId(id);
      if (s != null) _collapsed.add(s);
    }

    // Order list — keep any missing sections appended in their default order.
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
      // Fall back to a bare comma list (defensive).
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

  // NO haptic: the PWA's section-title hold toggles `sidebar-reorder-mode`
  // silently — it is the one long-press WITHOUT a `nymHapticTap`
  // (sidebar-sections.js:335-338).
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
    // Visible channels + PWA sort. `applyHiddenChannels` (channels.js:820-833)
    // NEVER hides `#nymchat` or the ACTIVE row — neither via the per-channel
    // hidden set nor via hide-non-pinned — which is exactly what keeps the
    // "Unhide channel" menu label reachable on the channel you're in.
    final sortByProximity = ref
        .watch(settingsProvider.select((settings) => settings.sortByProximity));
    final hideNonPinned = ref
        .watch(settingsProvider.select((settings) => settings.hideNonPinned));
    final location = ref.watch(userLocationProvider);
    final activeChannelKey =
        view.kind == ViewKind.channel ? view.id.toLowerCase() : '';
    final visibleChannels = app.channels
        .where((ch) => !app.blockedChannels.contains(ch.key))
        .where((ch) =>
            ch.key == kDefaultChannel ||
            ch.key == activeChannelKey ||
            (!app.hiddenChannels.contains(ch.key) &&
                !(hideNonPinned && !app.pinnedChannels.contains(ch.key))))
        .toList();
    // `sortChannelsByActivity` (nymchat → active → pinned → proximity →
    // activity/unread) sets the DOM order …
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
    // … and CSS `order` bands re-sort it stably on top (styles-shell.css:
    // 344-390): nymchat (-4) > active (-3) > pinned (-2) > has-unread (-1,
    // toggled by `_renderUnreadBadge` when count > 0) > rest (0). The band
    // partition below preserves comparator order within each band, exactly
    // like flex `order` ties breaking on DOM order.
    int orderBand(ChannelEntry ch) {
      if (ch.key == kDefaultChannel) return -4;
      if (ch.key == activeChannelKey) return -3;
      if (app.pinnedChannels.contains(ch.key)) return -2;
      if ((app.unreadCounts[ch.storageKey] ?? 0) > 0) return -1;
      return 0;
    }

    channels = [
      for (var band = -4; band <= 0; band++)
        ...channels.where((ch) => orderBand(ch) == band),
    ];
    final pinned = app.pinnedChannels;
    final pms = ref.watch(pmListProvider);
    // Resolve D1 kind-0 profiles for every PM peer shown in the list so a
    // conversation whose only events predate this session still shows the peer's
    // real avatar + nym instead of an identicon (the PWA fetches PM-list
    // profiles). Debounced + self/picture-guarded inside `_maybeBackfillProfiles`,
    // so calling it each build is cheap.
    ref
        .read(nostrControllerProvider)
        .ensureProfiles([for (final p in pms) p.pubkey]);
    final groups = ref.watch(groupsProvider);
    final users = ref.watch(usersProvider);
    final unread = ref.watch(unreadCountsProvider);

    // Groups + 1:1 PMs share the PRIVATE MESSAGES list, ordered newest-first by
    // last-message time (PWA `insertPMInOrder` keys both off `lastMessageTime`).
    final pmEntries = <_PmEntry>[
      for (final pm in pms) _PmEntry.pm(pm),
      for (final g in groups) _PmEntry.group(g),
    ]..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));

    final notifier = ref.read(appStateProvider.notifier);

    // `.sidebar-skeleton` rows: each list shimmers until its first real item
    // is inserted (`_clearSidebarSkel`) — bounded by the 8s safety clear.
    // The channel list's skeletons sit AFTER the static `#nymchat` row
    // (index.html:498-506), so they clear on the first non-default channel.
    final showChannelSkel =
        !_skelTimedOut && !app.channels.any((ch) => ch.key != kDefaultChannel);
    final showPmSkel = !_skelTimedOut && pmEntries.isEmpty;

    void select(ChatView v) {
      notifier.switchView(v);
      widget.onItemSelected?.call();
    }

    // PM/group-only mode restricts the Nyms list to PM-conversation peers +
    // group members (`pmOnlyPubkeys`, users.js:1353-1360); everyone else is
    // skipped at :1374.
    final Set<String>? pmOnlyPubkeys = settings.groupChatPMOnlyMode
        ? {
            for (final pm in pms) pm.pubkey,
            for (final g in groups) ...g.members,
          }
        : null;
    // NO self exclusion: `_doUpdateUserList` iterates `this.users` with no
    // self check (self is seeded into the map, nostr-core.js:2813), so your
    // own nym renders as a normal row and counts toward `activeCount`.
    final onlineUsers = users.values
        .where((u) => pmOnlyPubkeys == null || pmOnlyPubkeys.contains(u.pubkey))
        .toList()
      ..sort((a, b) {
        int rank(User u) {
          // CC-2: verified bots rank as online (always-online override,
          // users.js:1112) so they sort to the top of the nyms list.
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
        // Status ties break on the suffix-stripped, lowercased base nym
        // (`sortKey = parseNymFromDisplay(user.nym).toLowerCase()`,
        // users.js:1391,1395-1400).
        return stripPubkeySuffix(a.nym)
            .toLowerCase()
            .compareTo(stripPubkeySuffix(b.nym).toLowerCase());
      });

    // Dynamic "Nyms (N online)" title (`activeCount`, users.js:1383): non-hidden
    // nyms that are online/away (recent), plus verified bots regardless of
    // recency.
    final controller = ref.read(nostrControllerProvider);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nymActiveCount = onlineUsers.where((u) {
      // CC-2: verified bots count as online regardless of recency
      // (`getEffectiveUserStatus`, users.js:1112) — fold the override into the
      // status read so the count matches the PWA's `activeCount`.
      final isBot = kVerifiedBotPubkeys.contains(u.pubkey);
      final st = u.effectiveStatus(isVerifiedBot: isBot);
      if (st == UserStatus.hidden || st == UserStatus.offline) return false;
      // `(isRecent || verifiedBotSet.has(pubkey))` (users.js:1383): a stale
      // away user doesn't count as active.
      return nowMs - u.lastSeen < kActiveThresholdMs || isBot;
    }).length;

    // Apply the live search term + the collapse-to-20 cap, returning the capped
    // rows plus the hidden remainder count (0 when nothing is hidden). Searching
    // disables the cap (the PWA renders all matches).
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

    // Build the three sections, then emit them in the persisted order.
    Widget sectionFor(_SectionId s) {
      switch (s) {
        case _SectionId.channels:
          final term = _channelTerm.toLowerCase();
          final r = capped<ChannelEntry>(
            channels,
            term,
            (ch) => (ch.isGeohash ? ch.geohash : ch.channel)
                .toLowerCase()
                .contains(term),
            _channelExpanded,
          );
          return _NavSection(
            key: const ValueKey('section-channels'),
            sectionKey: TutorialTargets.keyFor(TutorialTarget.channelList),
            title: 'Public Channels',
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
            onSearchChanged: (v) => setState(() => _channelTerm = v),
            onLongPressTitle: _toggleReorderMode,
            // `.discover-icon` (globe) → geohash explorer (gap F15).
            leadingIcon: _MiniIcon(
              key: TutorialTargets.keyFor(TutorialTarget.discoverIcon),
              svg: NymIcons.globe,
              tooltip: 'Explore geohash channels',
              onTap: _openDiscover,
            ),
            searchHint: 'Search channels...',
            children: [
              for (final ch in r.rows)
                ChannelListItem(
                  entry: ch,
                  active: view.kind == ViewKind.channel && view.id == ch.key,
                  pinned: pinned.contains(ch.key),
                  // `unreadCounts` is keyed by the `#<geohash|name>` storageKey
                  // (app_state `_ingestChannelMessage` / `channelKeyOf`), NOT
                  // the bare lowercase registry `key` — read with storageKey so
                  // public-channel unread pills actually surface.
                  unread: unread[ch.storageKey] ?? 0,
                  textSize: textSize,
                  onTap: () => select(ChatView.channel(ch.key)),
                ),
              // `.ssk-channel` ×4 (index.html:503-506; widths w3/w1/w4/w2).
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
              // `.search-create-prompt` (channels.js:463-518): while a non-empty
              // search term matches no existing channel, offer a tappable "Join
              // channel / Join geohash" row to discover-by-typing. Tap joins via
              // `switchChannel` (adds to the registry + persists, like the PWA's
              // `addChannel → switchChannel → saveUserChannels`) and clears the
              // box. (07-F07-2 / F05-1.)
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
          // `filterPMs` (pms.js:3129-3134) matches the WHOLE `.pm-name`
          // textContent — for a PM row that's `{base}#{suffix}` (pms.js:2759),
          // for a group row `{name} · {memberCount}` (groups.js:2551) — so a
          // pubkey-suffix search like `#a3f2` (or member-count digits) hits.
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
                rendered = '${stripPubkeySuffix(e.pm!.nym)}'
                    '#${getPubkeySuffix(e.pm!.pubkey)}';
              }
              return rendered.toLowerCase().contains(term);
            },
            _pmExpanded,
          );
          return _NavSection(
            key: const ValueKey('section-pms'),
            sectionKey: TutorialTargets.keyFor(TutorialTarget.pmList),
            title: 'Private Messages',
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
            onSearchChanged: (v) => setState(() => _pmTerm = v),
            onLongPressTitle: _toggleReorderMode,
            // `.new-pm-btn` (plus) → new PM / group (gap F15).
            leadingIcon: _MiniIcon(
              svg: NymIcons.plus,
              tooltip: 'New message',
              onTap: () {
                widget.onItemSelected?.call();
                NewPmModal.open(context);
              },
            ),
            searchHint: 'Search PMs...',
            children: [
              // NO fixed Nymbot row: the PWA's `#pmList` only ever contains
              // real conversations inserted by `addPMConversation`
              // (pms.js:2714). The bot is a seeded USER (app.js:1102-1111) —
              // it surfaces under Online Nyms and appears here only once an
              // actual PM thread with it exists.
              // `.ssk-pm` ×3 (index.html:543-546; widths w2/w3/w1).
              if (showPmSkel)
                for (final f in const [0.58, 0.70, 0.42])
                  SidebarSkeletonRow.pm(barWidthFactor: f),
              for (final e in r.rows)
                if (e.group != null)
                  _GroupListItem(
                    group: e.group!,
                    active:
                        view.kind == ViewKind.group && view.id == e.group!.id,
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
                    active: view.kind == ViewKind.pm && view.id == e.pm!.pubkey,
                    unread: unread[e.pm!.pubkey] ?? 0,
                    textSize: textSize,
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
          // Nyms list capping (users.js:1411-1424): searching shows every match;
          // collapsed caps at 20; expanded renders `min(total, cap)` where the
          // cap grows by `EXPANDED_STEP` (500) per "Show N more…" click.
          // The search matches the `sortKey` — the suffix-stripped, lowercased
          // base nym (users.js:1405-1409) — NOT the raw `base#suffix` string.
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
          // `.user-list` (gap F17): 10px padding, NO bottom divider.
          return _NavSection(
            key: const ValueKey('section-nyms'),
            sectionKey: TutorialTargets.keyFor(TutorialTarget.userList),
            // Dynamic "Nyms (N online)" (`abbreviateNumber(activeCount)`).
            title: 'Nyms (${_abbreviateNumber(nymActiveCount)} online)',
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
            searchHint: 'Search nyms...',
            children: [
              // `.ssk-nym` ×5 (index.html:577-582; widths w3/w1/w4/w2/w3).
              if (!_skelTimedOut && onlineUsers.isEmpty)
                for (final f in const [0.70, 0.42, 0.50, 0.58, 0.70])
                  SidebarSkeletonRow.nym(barWidthFactor: f),
              for (final u in nymRows)
                UserListItem(
                  user: u,
                  textSize: textSize,
                  // A plain tap on a nyms-list row opens the profile context
                  // menu (`showContextMenu(..., profileOnly=true)`,
                  // users.js:1502-1517) — it does NOT start a PM directly; the
                  // PM is reachable from inside the profile panel's "Message"
                  // action. (07-F07-1.) The panel slides in from the right and
                  // ignores the anchor, so any offset works.
                  onTap: () =>
                      showUserContextMenu(context, ref, u, Offset.zero),
                ),
              // The view-more control only exists for an unsearched list of >20
              // (`_updateUserListViewMoreButton`, users.js:1683).
              if (term.isEmpty && total > _collapsedCap)
                if (_nymExpandedCap == null)
                  // Collapsed → "View {total-20} more…" expands to the first step.
                  _ViewMoreButton(
                    more: total - _collapsedCap,
                    onTap: () =>
                        setState(() => _nymExpandedCap = _expandedStep),
                  )
                else if (remaining > 0)
                  // Expanded with more rows → "Show {min(remaining,500)} more…",
                  // each click adds another 500-row step.
                  _ViewMoreButton(
                    more: remaining < _expandedStep ? remaining : _expandedStep,
                    stepMore: true,
                    onTap: () => setState(() =>
                        _nymExpandedCap = _nymExpandedCap! + _expandedStep),
                  )
                else
                  // Fully expanded → "Show less" collapses back to 20.
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
        // `.sidebar { overflow-y:auto }`: the whole column is one scroll
        // container, header + actions + sections (gap F7). The PWA draws a
        // 6px scrollbar whose thumb is transparent at rest and fades in while
        // scrolling/hovering: white@0.12 → 0.2 on hover (light: black@0.12 →
        // 0.2), radius 10, transparent track (styles-components.css:2190-2221;
        // styles-themes-responsive.css:1095-1106).
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
                // PM/group-only mode hides the whole PUBLIC CHANNELS section
                // (`applyGroupChatPMOnlyMode` sets `display:none` on the
                // `#channelList` `.nav-section`, pms.js:3862-3866).
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

  /// `.sidebar-header` with `.nym-display` (avatar 32 + nym + status/connection).
  ///
  /// Panic gesture (`bindNymPanicGesture`, docs/specs/04 §10.1): a normal tap
  /// opens the nick editor; a 2000 ms press-and-hold triggers the emergency
  /// wipe. The post-hold tap is swallowed so the editor doesn't open over the
  /// scramble overlay.
  Widget _header(BuildContext context, String nym) {
    final c = context.nym;
    // Live connected-relay count (PWA `poolConnectedRelays.length`, used by
    // `updateConnectionStatus`). Read-only here — drives the status-indicator
    // label + dot colour below the nym box.
    final connectedRelays = ref.watch(
      appStateProvider.select((s) => s.connectedRelays),
    );
    // `.sidebar-header`: padding 20/16, bottom hairline. bg is black@0.15
    // (dark) and `body.light-mode .sidebar-header` → white@0.3
    // (styles-themes-responsive.css:1226) so it reads as a light wash, not a
    // dark scrim, in light mode. On compact (<=1024) layouts the PWA zeroes
    // the bottom border (`.sidebar-header { border-bottom: 0px }`,
    // styles-themes-responsive.css:194-196, 457-459).
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
          // `.nym-display { margin-top:15px }` — the top gap above the box
          // (cosmetic in app mode where the ASCII logo above is hidden).
          const SizedBox(height: 15),
          // Click-to-edit AND the 2s panic hold bind to `.nym-display` only
          // (panic.js:14, app.js nick-edit click) — NOT to the status
          // indicator below it. The detector is a raw Listener (bypasses the
          // gesture arena), so wrapping the whole header made a status-row
          // tap open the nick editor behind the Network Stats modal.
          _PanicHoldDetector(
            onTap: () => NickEditModal.open(context),
            onHold: () => _triggerPanic(context),
            // `.nym-display`: padding 10/14, bg white@0.04 (light-mode →
            // black@0.04), glass border, radius-sm. `:hover` → bg white@0.07,
            // border primary@0.3, glow 0 0 15px primary@0.08 (styles-shell
            // .css:69-73); light mode overrides only the bg to black@0.07 —
            // its higher-specificity rest rule keeps the black@0.08 border
            // (styles-themes-responsive.css:1242-1249) while the glow applies.
            child: MouseRegion(
              onEnter: (_) => setState(() => _nymHover = true),
              onExit: (_) => setState(() => _nymHover = false),
              child: Container(
                key: TutorialTargets.keyFor(TutorialTarget.nymDisplay),
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
                    // `.nym-label` (block, `.sidebar-header { text-align:center }`):
                    // 10px uppercase ls 1.5 textDim weight 500, centered. Copy is
                    // "Your Nym (click to edit)" in the PWA (gap F16).
                    Text(
                      'YOUR NYM (CLICK TO EDIT)',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.textDim,
                        fontSize: 10,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // `.nym-identity` (flex) stays LEFT-aligned inside the box:
                    // avatar 32 (`.avatar.nm-h-14`) + nym, gap 10.
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
          // `.status-indicator` (index.html:434-437) is a SIBLING of
          // `.nym-display` inside `.sidebar-header`, NOT nested in it. Its
          // `margin-top:10px` is the gap below the nym box.
          const SizedBox(height: 10),
          _ConnectionStatusIndicator(connectedCount: connectedRelays),
        ],
      ),
    );
  }

  void _triggerPanic(BuildContext context) {
    PanicOverlay.show(
      context,
      wipe: PanicWipe.production(),
      onComplete: () {
        // The disk stores are wiped (PanicWipe). Now reset the RUNNING session:
        // drop the in-memory identity/keys/vault, reset AppState to the empty
        // logged-out shell, and drive the app back to first-run setup — the
        // in-memory half of the PWA's `panicWipe` (panic.js nulls
        // privkey/pubkey/_vaultMem then reloads to a pristine first run). The
        // boot-epoch bump inside `resetAfterPanic` remounts the BootGate (now
        // setup-needed) and its `popUntil(first)` also tears down this overlay,
        // so no manual pop is required.
        unawaited(ref.read(nostrControllerProvider).resetAfterPanic());
      },
    );
  }
}

/// Wraps the identity header to implement the panic gesture: a tap fires
/// [onTap], while a press held for [holdMs] fires [onHold] (and suppresses the
/// following tap). Bound for pointer down/move/up/cancel, matching the PWA's
/// mouse/touch handlers (`bindNymPanicGesture`) — which also cancel the hold
/// on `touchmove`/`mouseleave` (panic.js:27-33), so a finger that drags off or
/// wiggles never detonates the wipe.
class _PanicHoldDetector extends StatefulWidget {
  const _PanicHoldDetector({
    required this.child,
    required this.onTap,
    required this.onHold,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onHold;

  /// Press-and-hold threshold (`_PANIC_HOLD_MS`).
  static const int holdMs = 2000;

  @override
  State<_PanicHoldDetector> createState() => _PanicHoldDetectorState();
}

class _PanicHoldDetectorState extends State<_PanicHoldDetector> {
  /// Movement past this cancels the hold. The PWA cancels on ANY `touchmove`
  /// (panic.js:32) — which mobile browsers only emit once the touch leaves
  /// their internal slop, ~10px — so a drift beyond 10px is the equivalent
  /// "the finger moved" signal (the PWA's other 500ms holds use the same
  /// 10px MOVE_THRESHOLD, e.g. sidebar-sections.js:240).
  static const double _moveTolerance = 10;

  Timer? _timer;
  bool _fired = false;
  Offset _downAt = Offset.zero;

  void _start(PointerDownEvent e) {
    _fired = false;
    _downAt = e.position;
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: _PanicHoldDetector.holdMs),
      () {
        _fired = true;
        // The PWA fires exactly ONE 30ms `nymHapticTap` as the 2s timer
        // elapses (`if (window.nymHapticTap) window.nymHapticTap();
        // this.panicWipe()`, panic.js:20-25). `onHold` shows [PanicOverlay]
        // synchronously, whose `initState` fires that single mediumImpact —
        // buzzing here too would double-buzz, which the PWA never does.
        widget.onHold();
      },
    );
  }

  void _cancel([PointerEvent? _]) {
    _timer?.cancel();
    _timer = null;
  }

  /// `touchmove`/`mouseleave` → cancel (panic.js:27-33): a wiggling or
  /// dragging finger must never trigger the 2s emergency wipe.
  void _move(PointerMoveEvent e) {
    if (_timer == null) return;
    if ((e.position - _downAt).distance > _moveTolerance) _cancel();
  }

  void _up(PointerUpEvent _) {
    final held = _timer != null;
    _cancel();
    // A movement-cancelled press must not fall through to the tap action
    // either (the PWA's click handler only fires when the pointer stayed put).
    if (!_fired && held) widget.onTap();
    _fired = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _start,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      child: widget.child,
    );
  }
}

/// `^[0-9a-f]{64}$` pubkey check (`formatNymWithPubkey`, users.js:263).
final RegExp _hex64Re = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

/// Trailing `#xxxx` capture (`formatNymWithPubkey`, users.js:268).
final RegExp _nymSuffix4Re = RegExp(r'#([0-9a-f]{4})$', caseSensitive: false);

/// `.nym-value` (styles-shell.css:91-103): the header nym, 15px `--secondary`
/// weight 600 — with the `#suffix` split into a `.nym-suffix` span colored
/// `--text-dim` (`formatNymWithPubkey`, users.js:263-273: base = nym minus any
/// trailing `#xxxx`; suffix = the pubkey's last 4 hex chars, falling back to
/// the nym's own `#xxxx`, then to `pubkey.slice(-4)` / `????`).
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
          // `.nym-value .nym-suffix` overrides only `color: var(--text-dim)`;
          // the base `.nym-suffix` still applies (opacity 0.7, 0.9em, weight
          // 100 — styles-chat.css:706-710). So the suffix dims AND thins, it is
          // NOT bold like the base nym.
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

/// `.status-indicator` (index.html:434-437, styles-shell.css:105-119): the
/// connection-status row that sits in `.sidebar-header` directly below
/// `.nym-display` (a sibling of it, NOT nested inside). inline-flex, gap 5,
/// 11px `--text-dim`, centred by the header's `text-align:center`; tapping
/// opens the Network Stats modal (`data-action="openRelayStats"`).
///
/// `.status-dot` is a plain 8px circle whose colour `updateConnectionStatus`
/// (relays.js:3886) sets inline from the live pool count:
/// `--primary` Connected / `--warning` Connecting / `--danger` Disconnected.
/// In the default proxy/pool mode the label is `Connected (N relays)` when any
/// relay is connected, else `Connecting...` (relays.js:3905-3914).
/// [connectedCount] mirrors the PWA's `poolConnectedRelays.length`.
class _ConnectionStatusIndicator extends StatelessWidget {
  const _ConnectionStatusIndicator({required this.connectedCount});

  final int connectedCount;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final connected = connectedCount > 0;
    // PWA pool branch (relays.js:3905-3914): in the default proxy/pool mode
    // (`useRelayProxy = !!apiHost`, app.js:487) an open pool with connected
    // relays shows `Connected (N relays)` (primary dot); otherwise
    // `Connecting...` with the `--warning` dot. The `Disconnected`/`--danger`
    // state only exists in the non-proxy branch, which never runs by default.
    final label =
        connected ? 'Connected ($connectedCount relays)' : 'Connecting...';
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
            // `.status-dot`: plain 8px circle, colour set per connection state.
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

/// `.sidebar-actions`: the Flair / Settings / About / Logout button row that
/// sits under the identity header (index.html:440). Each is an `.icon-btn` with
/// an icon over a small label. Mounted only on compact layouts (gap F3); the
/// row carries the [TutorialTarget.mainMenu] key for the tour.
class _SidebarActions extends ConsumerWidget {
  const _SidebarActions({this.onItemSelected});

  final VoidCallback? onItemSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    // `.sidebar-actions`: padding 16/12, gap 6, top hairline border.
    return Container(
      key: TutorialTargets.keyFor(TutorialTarget.mainMenu),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _ActionButton(
            // `.sidebar-actions` Flair → the feather star polygon (index.html:442).
            svg: NymIcons.starFlair,
            label: 'Flair',
            onTap: () {
              onItemSelected?.call();
              ShopModal.open(context);
            },
          ),
          // `.sidebar-actions { gap: 6px }`.
          const SizedBox(width: 6),
          _ActionButton(
            svg: NymIcons.settings,
            label: 'Settings',
            onTap: () {
              onItemSelected?.call();
              SettingsScreen.open(context);
            },
          ),
          const SizedBox(width: 6),
          _ActionButton(
            svg: NymIcons.info,
            label: 'About',
            onTap: () {
              onItemSelected?.call();
              AboutScreen.open(context);
            },
          ),
          const SizedBox(width: 6),
          _ActionButton(
            svg: NymIcons.logout,
            label: 'Logout',
            // `.icon-btn` Logout → `signOut()` (app.js `signOut`, 6740-6741):
            // close the drawer (inline-bindings `signOutAndCloseSidebar`), then
            // confirm and disconnect. `signOut()` clears the identity + persisted
            // login keys and bumps the boot generation so the app remounts the
            // first-run gate.
            onTap: () async {
              final controller = ref.read(nostrControllerProvider);
              onItemSelected?.call();
              final ok = await showAppConfirm(
                context,
                'Sign out and disconnect from Nymchat?',
                okLabel: 'Sign out',
                danger: true,
              );
              if (!ok) return;
              await controller.signOut();
            },
          ),
        ],
      ),
    );
  }
}

/// A `.sidebar-actions` `.icon-btn` (styles-shell.css:912-935 + 501-535):
/// bg white@0.05, 1px `--glass-border` border, radius-xs, `--text` icon+label,
/// uppercase 9px label (letter-spacing 0.02em). Hover → primary@0.12 fill,
/// `--primary` text, primary@0.3 border, 0 0 15px primary@0.1 glow. Light mode
/// (styles-themes-responsive.css:595-605): bg black@0.03, border black@0.1,
/// `--primary` text; hover → bg black@0.06, border `--primary`.
class _ActionButton extends StatefulWidget {
  const _ActionButton({
    required this.svg,
    required this.label,
    required this.onTap,
  });

  final String svg;
  final String label;
  final VoidCallback onTap;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Resting: `.icon-btn` white@0.05 / glass border / --text; light-mode
    // overrides to black@0.03 / black@0.1 / --primary.
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
          // `.sidebar-actions .icon-btn`: padding 6/4, gap 3, 9px label.
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: borderColor),
              borderRadius: NymRadius.rxs,
              // `.icon-btn:hover` glow (dark only; the light-mode override
              // sets no shadow of its own but the base hover rule still
              // applies — keep it in both modes like the cascade does).
              boxShadow: _hover
                  ? [BoxShadow(color: c.primaryA(0.1), blurRadius: 15)]
                  : null,
            ),
            child: Column(
              children: [
                NymSvgIcon(widget.svg, size: 16, color: fg),
                const SizedBox(height: 3),
                Text(
                  // `.icon-btn { text-transform: uppercase }` → FLAIR/SETTINGS/…
                  widget.label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    // `.btn-label { letter-spacing: 0.02em }` (of 9px).
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

/// A collapsible nav section: 10px uppercase title (letter-spacing 2,
/// textDim), an optional leading action icon (globe/plus), a search-toggle +
/// collapse chevron, optional reorder arrows, an optional search field, then
/// the list body. (docs/specs/02 §1.1, §4 nav-title)
///
/// `.nav-section` gets a bottom hairline divider (gap F21); the Online Nyms
/// section ([isUserList]) uses `.user-list` metrics: 10px padding, no divider
/// (gap F17). A 500ms long-press on the title toggles section reorder mode
/// (gap F12); the chevron alone toggles collapse (the title row no longer
/// toggles collapse, matching the PWA, gap F11).
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

  /// Key attached to the section body (list area) for the tutorial spotlight.
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
    // `.nav-section` padding 16/12/12 + bottom divider; `.user-list` is 10px
    // padding with no divider.
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
          // `.nav-title`: a 500ms press-and-hold toggles reorder mode; the
          // title text does NOT toggle collapse (the chevron does).
          _NavTitleHold(
            onHold: onLongPressTitle,
            child: Padding(
              // `.nav-title` padding-left 8, margin-bottom 10.
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
                  // `.nav-title` lays its children on a 10px flex gap
                  // (styles-shell.css:127-138) — the gap is between the 20px
                  // icon hit boxes, padding included (and holds between the
                  // flex:1 title text and the first icon when it truncates).
                  const SizedBox(width: 10),
                  if (leadingIcon != null) ...[
                    leadingIcon!,
                    const SizedBox(width: 10),
                  ],
                  // `.search-icon svg` stays `--text-dim` even while the
                  // input is open — `--primary` only on :hover
                  // (styles-shell.css:189-214; no active-state rule).
                  _MiniIcon(
                    svg: NymIcons.search,
                    tooltip: 'Search',
                    onTap: onToggleSearch,
                  ),
                  const SizedBox(width: 10),
                  // `.collapse-icon` chevron — ▾ open (chevronDown) / ▸ collapsed
                  // (the PWA rotates the same glyph -90° → chevronRight).
                  _MiniIcon(
                    svg: open ? NymIcons.chevronDown : NymIcons.chevronRight,
                    tooltip: open ? 'Collapse section' : 'Expand section',
                    onTap: onToggleOpen,
                  ),
                ],
              ),
            ),
          ),
          // `.section-collapsed > *:not(.nav-title) { display:none !important }`
          // (styles-shell.css:221-224): collapsing hides EVERYTHING but the
          // title row — including an open search input.
          // `.search-input-wrapper { margin-bottom: 10px }`
          // (styles-shell.css:230-234).
          if (open && searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
              child: _SearchField(
                hint: searchHint,
                onChanged: onSearchChanged,
              ),
            ),
          // The list body carries the tutorial key (`#channelList` etc.).
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

/// The section-title reorder-mode hold (`sidebar-sections.js:320-366`): a
/// 500ms press — primary mouse button or touch — with the PWA's explicit
/// `MOVE_THRESHOLD = 10` cancel (drift past 10px on EITHER axis kills the
/// pending timer), NOT the framework long-press recognizer's ~18px kTouchSlop.
/// The hold is SILENT — the PWA's section hold fires no `nymHapticTap`.
/// A [Listener] doesn't enter the gesture arena, so a scroll-drag that starts
/// on the title still scrolls the sidebar (and the >10px drift cancels the
/// hold), matching the PWA's passive touch handlers.
class _NavTitleHold extends StatefulWidget {
  const _NavTitleHold({required this.onHold, required this.child});

  final VoidCallback onHold;
  final Widget child;

  /// The `pressTimer` delay (sidebar-sections.js:335).
  static const Duration holdDuration = Duration(milliseconds: 500);

  /// `MOVE_THRESHOLD` (sidebar-sections.js:322).
  static const double moveThreshold = 10;

  @override
  State<_NavTitleHold> createState() => _NavTitleHoldState();
}

class _NavTitleHoldState extends State<_NavTitleHold> {
  Timer? _pressTimer;
  Offset _start = Offset.zero;

  void _onPointerDown(PointerDownEvent e) {
    // Mouse presses count only for the primary button
    // (`if (e.button !== 0) return`, sidebar-sections.js:341).
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

/// `.section-reorder-arrows`: up/down `.section-reorder-btn` (18×18, white@0.08
/// bg, primary hover, 0.25 disabled). Shown only in reorder mode (gap F12).
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
    // `:hover:not(:disabled)` (styles-shell.css:180-183): bg `--primary`,
    // glyph #fff.
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
              // `.section-reorder-btn` bg is a fixed rgba(255,255,255,0.08)
              // in BOTH color modes (styles-shell.css:164-176 — the CSS has
              // no light-theme override for it).
              color: hovered ? c.primary : Colors.white.withValues(alpha: 0.08),
              borderRadius: NymRadius.rxs,
            ),
            // 12px stroke-width-3 chevron (index.html:466-472).
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
    // `.search-icon:hover svg` etc. tint the glyph `--text-dim` → `--primary`
    // over `transition: stroke 0.2s` (styles-shell.css:199-214).
    final target = _hover ? c.primary : c.textDim;
    final btn = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: Padding(
          // `.search-icon/.discover-icon/.collapse-icon`: 20×20 hit (`padding:
          // 2px 5px`), 14 glyph.
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

/// A unified PRIVATE MESSAGES list entry: either a 1:1 PM thread or a group.
/// Carries the `lastMessageTime` both kinds sort by.
class _PmEntry {
  _PmEntry.pm(PMConversation pm)
      : pm = pm,
        group = null,
        lastMessageTime = pm.lastMessageTime;
  _PmEntry.group(Group g)
      : pm = null,
        group = g,
        lastMessageTime = g.lastMessageTime;

  final PMConversation? pm;
  final Group? group;
  final int lastMessageTime;
}

/// The PWA's stroked multi-person group glyph (`groupSvg`, groups.js:2539):
/// a 3-person icon, `stroke-width:1.75`, `currentColor` → `--primary`. `{C}` is
/// substituted with the resolved primary hex at render time.
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

/// A group conversation row in the PRIVATE MESSAGES list (`.pm-item.group-item`,
/// groups.js `_buildGroupItemHTML`). Same box metrics as [PMListItem]. The icon
/// is either a custom avatar, a 34×22 stack of up to 3 member avatars + a
/// corner group-glyph badge (the common case), or a 26px `.group-icon-wrap`
/// fallback (no other members). A tap opens the group; a 500ms press-and-hold
/// opens the one-item "Leave conversation" `.quick-context-menu` at the press
/// point (the rich `#groupContextMenu` panel is opened from the chat header
/// instead).
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
      SidebarQuickMenuItem(
        label: 'Leave conversation',
        // PWA `leaveSvg` is the feather log-out (== NymIcons.logout).
        svg: NymIcons.logout,
        danger: true,
        // `deleteGroup` (groups.js:1851-1854): danger confirm first, then
        // `leaveGroup`.
        onSelected: () async {
          if (!context.mounted) return;
          final ok = await showAppConfirm(
            context,
            'Leave and delete this group conversation?',
            danger: true,
            okLabel: 'Leave',
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
    final name = group.name.isEmpty ? 'Group' : group.name;
    final otherMembers =
        group.members.where((pk) => pk != selfPubkey).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      // The PWA's 500ms press-and-hold (mouse button 0 / touch, 10px move
      // cancel) opens the quick menu at the press point and swallows the
      // following tap; right-click deliberately does nothing
      // (sidebar-sections.js:239-303).
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
              // `:hover { padding-left: 14px }` (rest 12px).
              padding: EdgeInsets.fromLTRB(hovered ? 14 : 12, 9, 12, 9),
              decoration: BoxDecoration(
                // `.pm-item.active` (shared by group rows): primary@0.10 fill
                // + primary@0.05 glow (dark); `body.light-mode` neutralises to
                // black@0.06 with `box-shadow:none` (styles-themes-responsive
                // .css:1139), border + accent bar stay primary. Hover (loses
                // to active): white@0.06 dark / black@0.04 light.
                color: active
                    ? (c.isLight
                        ? Colors.black.withValues(alpha: 0.06)
                        : c.primaryA(0.10))
                    : hovered
                        ? (c.isLight
                            ? Colors.black.withValues(alpha: 0.04)
                            : Colors.white.withValues(alpha: 0.06))
                        : Colors.transparent,
                borderRadius: NymRadius.rxs,
                border: Border.all(
                  color: active ? c.primaryA(0.20) : Colors.transparent,
                  width: 1,
                ),
                boxShadow: active && !c.isLight
                    ? [BoxShadow(color: c.primaryA(0.05), blurRadius: 12)]
                    : null,
              ),
              child: Row(
                children: [
                  // Custom avatar (`.group-avatar-wrap`, margin-right 4px,
                  // styles-features.css:5348) → 34×22 member stack → 26px
                  // icon-wrap fallback (both margin-right 6px).
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
                    // `.pm-name { flex: 1 }` (shared by group rows):
                    // white-space:normal + word-break:break-word
                    // (styles-shell.css:418-429) — long names WRAP, no
                    // ellipsis; flex:1 pushes the unread pill flush right
                    // so badges align in a column across rows.
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
                          // `.group-member-count`: 0.8em, opacity .55,
                          // weight 300, abbreviated total member count.
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
                  // `.channel-badges { margin-left: 5px }`.
                  if (unread > 0) ...[
                    const SizedBox(width: 5),
                    _GroupUnreadPill(count: unread),
                  ],
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
  }
}

/// `.group-avatar-stack`: a 34×22 cluster of up to 3 overlapping 18px member
/// avatars (left 0/9/18, each with a 1px `--bg-primary` border) + a 13×13
/// `.group-icon-badge` corner badge holding the 8px group glyph
/// (styles-features.css:2400-2448).
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
              left: i * 9.0, // left 0 / 9 / 18
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
          // `.group-icon-badge`: 13×13 at bottom -3 / right -4, bg-secondary
          // fill, 1px primary@30 border, 8px glyph.
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

/// `.group-icon-wrap` (styles-features.css:2450-2466): a 26px circle, primary@10
/// fill + 1px primary@25 border, holding the 14px group glyph (tinted primary).
/// Used only when the group has no other members.
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

/// `.unread-badge` for a group row (mirrors [PMListItem]'s pill).
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

/// `.view-more-btn` (styles-shell.css:284-304): a full-width pill that toggles
/// the collapse. [more] > 0 → "VIEW {more} MORE…" (or "SHOW {more} MORE…" for a
/// subsequent expand step when [stepMore]); 0 → "SHOW LESS". The PWA labels the
/// first expand "View N more…" and each further 500-row step "Show N more…"
/// (users.js:1707/1715/1722).
class _ViewMoreButton extends StatefulWidget {
  const _ViewMoreButton({
    required this.more,
    required this.onTap,
    this.stepMore = false,
  });
  final int more;
  final VoidCallback onTap;

  /// A subsequent expand step (uses the "Show …" verb instead of "View …").
  final bool stepMore;

  @override
  State<_ViewMoreButton> createState() => _ViewMoreButtonState();
}

class _ViewMoreButtonState extends State<_ViewMoreButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // PWA labels use three ASCII periods, not U+2026 ('View N more...' /
    // 'Show N more...', users.js:1707/1715).
    final label = widget.more > 0
        ? '${widget.stepMore ? 'SHOW' : 'VIEW'} '
            '${_abbreviateNumber(widget.more)} MORE...'
        : 'SHOW LESS';
    return Padding(
      // `margin: 6px 10px`.
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: NymRadius.rxs,
          child: Container(
            width: double.infinity,
            // `padding: 8px 12px`.
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: NymRadius.rxs,
              // `:hover` (styles-shell.css:300-304): border primary@0.3,
              // bg primary@0.08, text `--text`.
              color: _hover ? c.primaryA(0.08) : null,
              border:
                  Border.all(color: _hover ? c.primaryA(0.3) : c.glassBorder),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              // 11px, uppercase, letter-spacing 1, weight 500, --text-dim.
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

/// `.search-create-prompt` (channels.js:463-518, styles-components.css:551-568):
/// the "Join channel / Join geohash" discover-by-typing row shown under the
/// channel search when the term matches no existing channel. flex space-between,
/// radius xs, padding 10, bg `--bg-tertiary`, 1px `--border`, 12px
/// `--text-bright`; hover → bg `primary@0.1` + `--primary` border. (07-F07-2.)
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
    // geohash → `Join geohash channel "term" (location)`; else `Join channel
    // "term"`. The location suffix mirrors the PWA's resolved geohash label.
    final label = isGeo
        ? 'Join geohash channel "${widget.term}"'
        : 'Join channel "${widget.term}"';
    final loc = isGeo ? geohashLocationLabel(widget.term) : '';
    return Padding(
      // `margin-top: 5` + the section's 10px horizontal gutter.
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 0),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: NymRadius.rxs,
          child: Container(
            width: double.infinity,
            // `padding: 10`.
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: NymRadius.rxs,
              // hover: bg primary@0.1; rest: --bg-tertiary.
              color: _hover ? c.primaryA(0.1) : c.bgTertiary,
              border: Border.all(color: _hover ? c.primary : c.border),
            ),
            child: Row(
              // `justify-content: space-between`.
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 12px, --text-bright.
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

/// `abbreviateNumber` (users.js:2069): `<1000` raw, `<1M` → `N.Nk` (1 decimal
/// under 10k, else 0), else `N.NM`.
String _abbreviateNumber(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
  }
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

/// `.search-input`: radius rxs, padding 8px 28px 8px 12px, 12px, bg white@5, no
/// leading icon. Shows a trailing ✕ `.search-clear` (right 6px, danger on hover)
/// once it has a value; clearing it resets the section's filter (gap: wired via
/// [onChanged]).
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
    // Repaint the fill + focus ring on focus changes.
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
    // `.search-input` rests on white@0.05 and brightens to white@0.08 on
    // `:focus` (styles-shell.css:240-253, 278-282). In light mode the global
    // `body.light-mode input { background: rgba(0,0,0,0.04) !important }`
    // (styles-themes-responsive.css:571-579) pins the fill — even focused.
    final Color fill = c.isLight
        ? Colors.black.withValues(alpha: 0.04)
        : Colors.white.withValues(alpha: focused ? 0.08 : 0.05);
    // Resting border: `--glass-border` (dark) / the light-mode input override
    // `border-color: rgba(0,0,0,0.1) !important`.
    final Color restBorder =
        c.isLight ? Colors.black.withValues(alpha: 0.1) : c.glassBorder;
    // `:focus` also draws a 3px outer ring: `box-shadow: 0 0 0 3px
    // primary@0.06` (light-mode focus ring is primary@0.1,
    // styles-themes-responsive.css:1085-1093).
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
        // The global `input { color: #ffffff !important }` rule forces pure
        // white in dark mode; `body.light-mode .search-input` resolves to
        // `var(--text)` (styles-themes-responsive.css:571-593, 1063-1068).
        style:
            TextStyle(color: c.isLight ? c.text : Colors.white, fontSize: 12),
        cursorColor: c.isLight ? Colors.black : Colors.white,
        onChanged: (v) {
          widget.onChanged(v);
          setState(() {}); // toggle the clear ✕ visibility
        },
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hint,
          hintStyle: TextStyle(color: c.textDim, fontSize: 12),
          // `padding: 8px 28px 8px 12px` (right room for the ✕).
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

/// `.search-clear` ✕ (styles-shell.css:255-276): 14px, `--text-dim`, danger on
/// hover, right 6px.
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

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/groups/group_logic.dart';
import '../../features/nymbot/nymbot_providers.dart'
    show BotChatController, botChatControllerProvider, mergeBotThreadWithInfo;
import '../../features/pms/pm_logic.dart';
import '../../features/reactions/reaction_picker.dart';
import '../../features/shop/cosmetics.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../models/pm_conversation.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../chat/message_row.dart';
import '../chat/message_skeleton.dart';
import '../chat/typing_indicator.dart';
import '../common/app_dialog.dart';
import '../common/nym_avatar.dart';
import '../context_menu/profile_badges.dart';
import '../nym_icons.dart';

/// Fixed dimensions from `css/styles-columns.css`.
class _CvDimens {
  static const double column = 360; // .cv-column flex-basis/width
  static const double addColumn = 220; // .cv-add-column width
  static const double gap = 12; // .cv-strip gap
  static const double padding = 12; // .cv-strip padding
  // The PWA's mobile snap carousel is gated on `width <= 768`
  // (`styles-columns.css:496`, `_cvScrollToIndex`/`_cvAttachDnd` on
  // `innerWidth <= 768`).
  static const double mobileBreakpoint = 768;
}

/// The kind of conversation a deck column shows (`desc.type` in columns.js).
enum _ColumnKind { channel, pm, group }

/// A deck column descriptor (`_cvColumns` entry), mirroring `_cvDescForSave`.
/// Resolves its own storage key (into [AppState.messages]), unread key, title
/// and header icon so the deck can host channel / PM / group columns (gap F1).
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

  /// Stable identity key (`_cvColKey`): `#geo|channel`, the pm pubkey, or the
  /// group id. Also the unread-counts key for channels/PMs/groups.
  String get key => switch (kind) {
        _ColumnKind.channel =>
          (geohash.isNotEmpty ? geohash : channel).toLowerCase(),
        _ColumnKind.pm => pubkey,
        _ColumnKind.group => groupId,
      };

  /// Key into [AppState.messages].
  String get storageKey => switch (kind) {
        _ColumnKind.channel => '#${geohash.isNotEmpty ? geohash : channel}',
        _ColumnKind.pm => PmLogic.pmStorageKey(pubkey),
        _ColumnKind.group => GroupLogic.groupStorageKey(groupId),
      };

  /// Serializes to the same JSON shape the PWA persists (`_cvDescForSave`),
  /// stored under `nym_columns_layout` (`_cvSaveLayout`).
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

  /// Rebuilds a descriptor from persisted JSON (`_cvLoadLayout`). Returns null
  /// for unrecognised / malformed entries so a bad key can't crash the deck.
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

/// A row in the add-column picker (`_cvAvailableConversations` entry).
typedef _PickerEntry = ({_ColumnDesc desc, String label, Widget icon});

/// The deck / multi-column view (`#columnsStrip .cv-strip`), shown when
/// `settings.chatViewMode == 'columns'`.
///
/// Desktop (width > 768): a horizontally-scrollable strip of 360px-wide columns
/// — channel, PM, or group (gap F1) — each draggable by its header to reorder
/// (`_cvAttachDnd`/`cv-drag-ghost`, with the PWA's 5px start threshold and live
/// midpoint reflow) and clickable to focus (`.cv-column.focused` primary border
/// + glow), with a centered pager (`.cv-pager`/`.cv-pdot`) above the strip.
/// Ends in a 220px dashed "+ Add column" which opens an in-strip column-shaped
/// picker panel (`.cv-picker`).
///
/// Mobile (width <= 768): a full-width [PageView] snap carousel (one column per
/// screen, `scroll-snap-type:x mandatory` / `flex:0 0 100%`), each header
/// showing a position-dot indicator (`.cv-hdot`) instead of the title/icon plus
/// prev/next move arrows (`.cv-col-move` → `_cvStepFocused`). Tapping the dots
/// opens a "Columns" bottom-sheet tab switcher (`_cvOpenTabsView`) with
/// drag-to-reorder rows (`.cv-tab`, gap F5).
///
/// Seeded from the persisted `nym_columns_layout` (`_cvSeedIfNeeded`) or, when
/// none is saved, `#nymchat` + the most-recent PM + the most-recent group
/// (`_cvSeedDefaults`); the order/layout is persisted on every mutation
/// (`_cvSaveLayout`). When `settings.columnsWallpaper` is on, the per-column
/// body/scroller backgrounds go transparent so the wallpaper drawn by the shell
/// behind the deck shows through (`.columns-wallpaper` — the glass header bar
/// and the column border/shadow are kept, styles-columns.css:72-78).
class ColumnsDeck extends ConsumerStatefulWidget {
  const ColumnsDeck({super.key});

  @override
  ConsumerState<ColumnsDeck> createState() => _ColumnsDeckState();
}

class _ColumnsDeckState extends ConsumerState<ColumnsDeck> {
  /// The columns currently shown. Seeded on first build (`_cvSeedDefaults`).
  final List<_ColumnDesc> _columns = [];
  bool _seeded = false;

  /// Whether the shared header/composer has been pointed at the initially
  /// focused column yet (`_cvEnable` focuses the first column on entry,
  /// columns.js:77-78). One-shot so later rebuilds don't re-fire it.
  bool _syncedInitialView = false;

  /// Re-entrancy guard for the external-view nav-sink (`_onExternalView`). Set
  /// while the deck itself is driving `switchView` (via `_syncFocusedView`) so
  /// the `ref.listen(view)` it triggers doesn't recurse back into the sink and
  /// add/duplicate a column. Mirrors the PWA `_cvOpenConversation` guard against
  /// `_cvFocusColumn` re-entry (columns.js:274-296 / 550-559).
  bool _syncingFromDeck = false;

  /// Mobile carousel page controller (`_cvScrollToIndex` on `innerWidth<=768`).
  final PageController _pageController = PageController();

  /// Desktop strip scroll controller (`_cvScrollToIndex`/`_cvScrollToEnd`).
  final ScrollController _stripScroll = ScrollController();

  /// The scrollable strip's element, for drag geometry (`_cvStrip` rects).
  final GlobalKey _stripKey = GlobalKey();

  /// The focused / visible column index. On mobile this is the PageView page;
  /// on desktop it tracks the last-focused column for the pager highlight.
  int _focused = 0;

  /// `_cvPrimaryId`: the key of the primary channel column — the FIRST channel
  /// column at enable (columns.js:75-76). Nulled when that column is removed
  /// (columns.js:261) and never reassigned; only while it's alive (and still a
  /// channel) do sidebar channel taps repurpose it in place (columns.js:282-287).
  /// Repurposing keeps the same column, so the tracked key follows it.
  String? _primaryKey;

  /// Whether the in-strip add-column picker panel is open (`.cv-picker`,
  /// `_cvOpenAddColumn`). Desktop only; the add button hides while it's open.
  bool _pickerOpen = false;

  // --- Desktop column drag state (`_cvStartColumnDrag`, columns.js:673-728) ---

  /// Current index of the column being dragged (live-reflowed), else null.
  int? _dragIndex;

  /// True once the pointer moved past the 5px start threshold (columns.js:682).
  bool _dragActive = false;
  Offset _dragStart = Offset.zero;

  /// Pointer offset inside the column at grab time; the y component is clamped
  /// to 40 like the PWA (`grabY = Math.min(startY - rect.top, 40)`).
  Offset _grabOffset = Offset.zero;

  /// The dragged column's exact on-screen size (the ghost matches it 1:1).
  Size _dragSize = Size.zero;
  BuildContext? _dragBoundary;
  ui.Image? _dragImage;
  OverlayEntry? _dragGhostEntry;
  Offset _ghostPos = Offset.zero;

  /// Per-column `col._atBottom` flags keyed by storage key, reported by each
  /// mounted [_DeckColumn] (`_cvAttachColumnScroll`, columns.js:633-636).
  /// Absent means at-bottom — columns start pinned to the newest message
  /// (`col._atBottom = true`, columns.js:433).
  final Map<String, bool> _atBottomByKey = <String, bool>{};

  /// The [AppStateNotifier] the deck registered its [columnsReadGate] on, kept
  /// so [dispose] can unregister without touching `ref` after teardown.
  AppStateNotifier? _gateHost;

  @override
  void initState() {
    super.initState();
    // Register the columns-mode read gate for the deck's lifetime (the PWA's
    // `_cvMarkColumnRead`, columns.js:26-42): while it is set, the unread bump
    // (app_state ingest), the `switchView` clear, channel read receipts
    // (`isConversationSeen`) and `markVisibleColumnsRead` (fired on resume,
    // relays.js:532/584) all defer to focused + at-bottom + visible.
    final notifier = ref.read(appStateProvider.notifier);
    notifier.columnsReadGate = _columnsReadGate;
    _gateHost = notifier;
  }

  @override
  void dispose() {
    // Unregister the read gate (single view has none — the active conversation
    // is simply the seen one). Guarded so a hypothetical second deck's gate is
    // never clobbered.
    final host = _gateHost;
    if (host != null && host.columnsReadGate == _columnsReadGate) {
      host.columnsReadGate = null;
    }
    _gateHost = null;
    _removeGhost();
    _pageController.dispose();
    _stripScroll.dispose();
    super.dispose();
  }

  // --- Columns read gate (`_cvMarkColumnRead`, columns.js:26-47) --------------

  /// `_cvMarkColumnRead`'s pass condition (columns.js:26-42): [key] belongs to
  /// the FOCUSED column, that column is pinned to the bottom
  /// (`col._atBottom !== false`), and the app is visible (`!document.hidden`).
  /// Unread keys arrive as either the storage key or the bare id (peer pubkey /
  /// group id / channel name) depending on the ingest path, so both forms match.
  bool _columnsReadGate(String key) {
    if (key.isEmpty || _columns.isEmpty) return false;
    if (_focused < 0 || _focused >= _columns.length) return false;
    final desc = _columns[_focused];
    if (!_descMatchesKey(desc, key)) return false;
    // `document.hidden`: a backgrounded app never marks columns read; unread
    // accrued while hidden is cleared on resume via `markVisibleColumnsRead`.
    // `inactive` (visible but unfocused) still counts as visible — on the web
    // an unfocused-but-visible tab has `document.hidden === false`.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      return false;
    }
    return _atBottomByKey[desc.storageKey] ?? true;
  }

  /// Whether an unread-counts [key] refers to [desc]'s conversation — accepts
  /// the storage key (`#chan` / `pm-<pk>` / `group-<id>`), the descriptor key,
  /// and (for channels) the bare lowercase name/geohash badge bucket.
  bool _descMatchesKey(_ColumnDesc desc, String key) {
    if (key == desc.storageKey || key == desc.key) return true;
    if (desc.kind == _ColumnKind.channel) {
      final k = key.toLowerCase();
      return k == desc.key || k == '#${desc.key}';
    }
    return false;
  }

  /// `_cvAttachColumnScroll`'s at-bottom bookkeeping (columns.js:633-636):
  /// track the per-column flag and, on the scrolled-up → at-bottom transition,
  /// mark the column read — only the focused + visible column's badge actually
  /// clears (`_cvMarkColumnRead` re-checks the gate).
  void _onColumnAtBottom(_ColumnDesc desc, bool atBottom) {
    final was = _atBottomByKey[desc.storageKey] ?? true;
    _atBottomByKey[desc.storageKey] = atBottom;
    if (atBottom && !was) _markColumnRead(desc);
  }

  /// `_cvMarkColumnRead` (columns.js:26-42): when the gate passes, clear the
  /// column's unread badge AND stamp its read watermark ([clearUnread] folds
  /// the PWA's `clearUnreadCount` + `_markChannelRead` branches together).
  void _markColumnRead(_ColumnDesc desc) {
    if (!_columnsReadGate(desc.storageKey)) return;
    ref.read(appStateProvider.notifier).clearUnread(desc.storageKey);
  }

  /// Binds [_onColumnAtBottom] to [desc] at BUILD time, so a scroll event that
  /// races a live reorder can't report under a stale index's column.
  ValueChanged<bool> _atBottomHandlerFor(_ColumnDesc desc) =>
      (atBottom) => _onColumnAtBottom(desc, atBottom);

  /// `cvResetColumns` while columns are LIVE (columns.js:363-381): tear down
  /// the in-memory columns and let the next build re-seed the defaults
  /// (`_cvSeedDefaults` — storage was already cleared by
  /// [SettingsController.resetColumns] before the tick bump), re-derive the
  /// primary column, re-focus the first column and snap the strip/carousel to
  /// it. Without this a mounted deck would keep its stale `_columns` and the
  /// next `_saveLayout` would re-persist them, permanently undoing the reset.
  void _onColumnsReset() {
    if (!mounted) return;
    setState(() {
      _columns.clear();
      _seeded = false; // build → `_seedIfNeeded` → seed defaults + save
      _pickerOpen = false;
      _focused = 0;
    });
    _primaryKey = null; // re-derived by the re-seed (columns.js:376-377)
    _syncedInitialView = false; // re-fire `_cvFocusColumn(first.id)` (:378-379)
    _atBottomByKey.clear();
    // Snap the carousel/strip back to the first (focused) column once the
    // re-seeded columns have built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _columns.isNotEmpty) _scrollToIndex(0);
    });
  }

  // --- Persistence (`_cvSaveLayout` / `_cvLoadLayout`) -----------------------

  /// Persist the current column order/layout to `nym_columns_layout`, mirroring
  /// the PWA `_cvSaveLayout` (a JSON array of `_cvDescForSave` descriptors).
  /// Written directly through the [KeyValueStore] the deck already reaches via
  /// [settingsProvider] / [keyValueStoreProvider] — no other file is touched.
  void _saveLayout() {
    final kv = ref.read(keyValueStoreProvider);
    final data = _columns.map((c) => c.toJson()).toList();
    kv.setString(StorageKeys.columnsLayout, jsonEncode(data));
  }

  /// Load a saved layout (`_cvLoadLayout`); null when absent/empty/malformed.
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

    // PWA `_cvSeedIfNeeded`: restore the saved layout first if one exists.
    final saved = _loadLayout();
    if (saved != null && saved.isNotEmpty) {
      // In PM-only mode channel columns are not allowed (`cvAddColumn` guard).
      _columns.addAll(pmOnly
          ? saved.where((d) => d.kind != _ColumnKind.channel)
          : saved);
    }

    if (_columns.isEmpty) {
      // `_cvSeedDefaults`: #nymchat (unless PM-only) + most-recent PM + group.
      if (!pmOnly) {
        final nymchat = channels.firstWhere(
          (ch) => ch.key == kDefaultChannel,
          orElse: () => channels.isNotEmpty
              ? channels.first
              : ChannelEntry(channel: kDefaultChannel),
        );
        _columns.add(_ColumnDesc.channel(nymchat.channel, nymchat.geohash));
      }
      if (pms.isNotEmpty) {
        // pmListProvider is already most-recent-first.
        _columns.add(_ColumnDesc.pm(pms.first.pubkey, nym: pms.first.nym));
      }
      if (groups.isNotEmpty) {
        final g = [...groups]
          ..sort((a, b) => b.lastMessageTime - a.lastMessageTime);
        _columns.add(_ColumnDesc.group(g.first.id));
      }
      // Mirror `_cvSeedDefaults`, which persists the freshly seeded layout.
      // Deferred to post-frame since seeding runs inside the first build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _saveLayout();
      });
    }

    // `_cvEnable` (columns.js:75-76): the primary column is the first channel
    // column present at enable time.
    for (final d in _columns) {
      if (d.kind == _ColumnKind.channel) {
        _primaryKey = d.key;
        break;
      }
    }
    // `cvAddColumn` → `_cvSubscribeChannel` for every seeded channel column
    // (columns.js:188/200 seed with `cvAddColumn`, which subscribes at :224).
    for (final d in _columns) {
      _subscribeChannel(d);
    }
  }

  /// `_cvSubscribeChannel` (columns.js:520-540), fired for every channel column
  /// the deck seeds/adds/repurposes. Routes through the controller's
  /// `subscribeChannelColumn`, which bundles the PWA's side effects WITHOUT
  /// switching the shared view: register + persist the channel (`addChannel` +
  /// `userJoinedChannels`, columns.js:523-526), the D1 archive restore
  /// (`channelRestoreFromD1`, columns.js:527), geo-relay connect for a geohash
  /// channel (`connectToGeoRelays`, columns.js:529 — the native relay pool owns
  /// reconnection, so `startGeoRelayKeepAlive`/`ensureDefaultRelaysConnected`
  /// need no counterpart, and the always-on shared channel subscription does
  /// `loadChannelFromRelays`'s job), and the channel typing sub when this
  /// column IS the active conversation (`_ensureChannelTypingSub`,
  /// columns.js:536-538 — the native sub is single/latest-wins, so a
  /// background column must not steal the focused column's feed; focus-driven
  /// switches re-point it via [_syncFocusedView] → `switchChannel`). Runs
  /// post-frame because seeding happens during build.
  void _subscribeChannel(_ColumnDesc desc) {
    if (desc.kind != _ColumnKind.channel) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(nostrControllerProvider)
          .subscribeChannelColumn(desc.channel, geohash: desc.geohash);
    });
  }

  /// Storage flag for the "Don't ask again" remove-column confirm
  /// (`nym_columns_skip_delete_confirm`, columns.js:236/247). Reached through the
  /// KV store directly (like [_saveLayout]) since the constants file is owned by
  /// another slice.
  static const String _skipRemoveConfirmKey = 'nym_columns_skip_delete_confirm';

  /// `cvRequestRemoveColumn` (columns.js:233-251): confirm removal with a
  /// persistable "Don't ask again", unless the skip flag is already set. The
  /// column close buttons + the tabs-sheet close both route through here.
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
      'Remove the "$title" column? You can add it back anytime.',
      title: 'Remove column',
      okLabel: 'Remove',
      danger: true,
      checkboxLabel: "Don't ask again",
    );
    if (!res.confirmed || !mounted) return;
    if (res.checked) kv.setBool(_skipRemoveConfirmKey, true);
    _doRemoveColumn(desc);
  }

  /// The actual removal (`cvRemoveColumn`, columns.js:253-268). Focus is
  /// identity-based: it only moves (to `min(idx, len-1)`) when the REMOVED
  /// column was the focused one; removing any other column leaves the focused
  /// column — and the shared header/composer — untouched.
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
    // `cvRemoveColumn`: `if (this._cvPrimaryId === id) this._cvPrimaryId = null`.
    if (desc.key == _primaryKey) _primaryKey = null;
    // No column shows this conversation anymore — drop its at-bottom flag so a
    // later re-add starts pinned (`col._atBottom = true`, columns.js:433).
    if (!_columns.any((d) => d.storageKey == desc.storageKey)) {
      _atBottomByKey.remove(desc.storageKey);
    }
    _saveLayout();
    _syncPageController();
    // Re-point the shared header/composer only when the focused column itself
    // was removed (`_cvFocusColumn(next.id)` runs only in that branch).
    if (wasFocused) _syncFocusedView();
  }

  /// Commit a tabs-sheet row reorder ([from] → [to], final-index terms), keeping
  /// focus pinned to the same column by identity — the PWA drag `end()`
  /// (columns.js:928-937) re-sorts `_cvColumns` + saves without ever touching
  /// `_cvFocusedId`.
  void _commitTabsReorder(int from, int to) {
    if (from < 0 || from >= _columns.length) return;
    if (to < 0 || to >= _columns.length || from == to) return;
    final focusedDesc =
        (_focused >= 0 && _focused < _columns.length) ? _columns[_focused] : null;
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

  /// Desktop "click a column to focus it" (`columns.js:175-179` →
  /// `_cvOpenConversation`/`_cvFocusColumn` + `_cvScrollToCol`): clicking a
  /// non-focused column marks it focused so its header shows the primary border
  /// + `--shadow-glow`, re-points the shared chat header + composer at it, and
  /// reveals it — the strip scrolls a partly off-screen column fully into view
  /// (`_cvScrollToIndex`, columns.js:969-977). Clicks on the already-focused
  /// column do nothing (the strip delegate gates on `colId !== _cvFocusedId`).
  void _focusColumn(int index) {
    if (index < 0 || index >= _columns.length) return;
    if (_focused == index) return;
    setState(() => _focused = index);
    _revealColumn(index);
    _syncFocusedView();
  }

  /// Maps a column descriptor to the shared [ChatView] it represents.
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

  /// Point the shared chat header + composer at the focused column's
  /// conversation, mirroring `_cvFocusColumn` (columns.js:550-559), which sets
  /// `currentChannel`/`currentPM`/`currentGroup` so the single shared composer
  /// (kept mounted in columns mode) targets the focused column. Deferred to
  /// post-frame so it never mutates the provider during a build/seed pass.
  void _syncFocusedView() {
    if (_columns.isEmpty) return;
    final idx = _focused.clamp(0, _columns.length - 1);
    final desc = _columns[idx];
    final view = _viewForDesc(desc);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(appStateProvider).view == view) {
        // `_cvFocusColumn` still marks the (re)focused column read
        // (columns.js:565) even when the shared view already points at it;
        // the gated `switchView` clear below covers the switching path.
        _markColumnRead(desc);
        return;
      }
      // Flag the deck-driven switch so the `ref.listen(view)` nav-sink
      // (`_onExternalView`) doesn't treat it as outside navigation and recurse.
      _syncingFromDeck = true;
      if (desc.kind == _ColumnKind.channel) {
        // Channel focus routes through the controller's `switchChannel` (not
        // bare `switchView`) so the focused geohash channel's geo relays
        // (`connectGeoRelaysForGeohash`) and typing sub follow focus — the
        // controller keeps ONE active channel typing sub, unlike the PWA's
        // accumulating per-channel `_ensureChannelTypingSub`.
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

  /// Inverse of [_viewForDesc]: turn the shared [ChatView] into the matching
  /// column descriptor so the nav-sink can find/repurpose/add a column. For a
  /// channel it recovers the registered [ChannelEntry] (so a fresh column shows
  /// the right name/geohash); falling back to a bare descriptor keyed off
  /// `view.id` (geohash vs named) when the channel isn't in the registry yet.
  _ColumnDesc _descForView(ChatView v) {
    switch (v.kind) {
      case ViewKind.channel:
        final channels = ref.read(channelsProvider);
        for (final ch in channels) {
          if (ch.key == v.id.toLowerCase()) {
            return _ColumnDesc.channel(ch.channel, ch.geohash);
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

  /// The columns-mode navigation sink (`_cvOpenConversation`, columns.js:274-296,
  /// reached because `switchChannel`/`openPM`/`openGroup` short-circuit on
  /// `_cvActive`). When the shared view changes from OUTSIDE the deck (sidebar
  /// tap, notification, deep-link, back/forward), drive the deck instead of
  /// leaving the header/composer pointed at a conversation with no visible
  /// column:
  ///   1. an existing column for [v] → focus + scroll it into view;
  ///   2. a channel [v] while the tracked PRIMARY column is alive and still a
  ///      channel → repurpose that column in place (`_cvNavigateColumn`);
  ///   3. otherwise → append a new column, focus + scroll to it (`cvAddColumn`).
  void _onExternalView(ChatView v) {
    // Ignore our own `_syncFocusedView`-driven switches, and anything before the
    // deck has seeded its initial columns.
    if (_syncingFromDeck || !_seeded) return;
    // `opts.forceNew` (columns.js:282): the globe's geohash opens pass
    // `{forceNew: true}` (geohash-globe.js:1200) so they NEVER repurpose the
    // primary column — an existing column still wins, but otherwise a NEW
    // column is added. One-shot hint set by `switchView(forceNewColumn:)`.
    final forceNew =
        ref.read(appStateProvider.notifier).consumeForceNewColumnHint();
    final desc = _descForView(v);

    // (1) Existing column → focus + scroll (handles the back/forward + re-tap
    // cases). `_scrollToIndex` records focus, moves the carousel/strip and
    // re-points the shared view (a no-op here since it already equals [v]).
    final existing = _columns.indexWhere((d) => d == desc);
    if (existing >= 0) {
      _scrollToIndex(existing);
      return;
    }

    // (2) Channel view + the tracked primary column is alive and still a
    // channel → navigate it in place (`_cvNavigateColumn`). Once the primary is
    // closed (`_cvPrimaryId = null`), channels ADD new columns instead. Skipped
    // entirely when the open carried `forceNew` (globe geohash opens).
    if (!forceNew && v.kind == ViewKind.channel && _primaryKey != null) {
      final primary = _columns.indexWhere(
          (d) => d.key == _primaryKey && d.kind == _ColumnKind.channel);
      if (primary >= 0) {
        setState(() {
          _columns[primary] = desc;
          _focused = primary;
        });
        // The repurposed column stays the primary under its new key.
        _primaryKey = desc.key;
        // `_cvNavigateColumn` → `_cvSubscribeChannel` (geo relays + typing sub
        // + D1 restore; the view already points here, so no re-switch needed).
        _subscribeChannel(desc);
        _saveLayout();
        _scrollToIndex(primary);
        return;
      }
    }

    // (3) Otherwise add a new column, focus + scroll to it (`cvAddColumn`).
    setState(() {
      _columns.add(desc);
      _focused = _columns.length - 1;
    });
    // `cvAddColumn` → `_cvSubscribeChannel` (relay-side work included).
    _subscribeChannel(desc);
    _saveLayout();
    _scrollToIndex(_columns.length - 1);
  }

  /// Step the visible column one slot left/right (`_cvStepFocused`, mobile
  /// arrows — navigates the carousel, it does not reorder).
  void _stepFocused(int dir) {
    final to = _focused + dir;
    if (to < 0 || to >= _columns.length) return;
    _scrollToIndex(to);
  }

  /// `_cvScrollToIndex` + focus: on mobile snap the carousel INSTANTLY (the PWA
  /// assigns `scrollLeft` directly, columns.js:965-967 — no smooth behavior);
  /// on desktop smooth-scroll the strip only if the target column is partly
  /// off-screen (columns.js:969-977).
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

  /// Desktop `_cvScrollToIndex` (columns.js:969-977): smooth-scroll the strip so
  /// column [idx] is fully visible with the strip's 12px edge padding — but
  /// never nudge a column that's already fully in view. Post-frame so a column
  /// added this build participates in the extent.
  void _revealColumn(int idx) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_stripScroll.hasClients) return;
      if (idx < 0 || idx >= _columns.length) return;
      final pos = _stripScroll.position;
      final left = _CvDimens.padding + idx * (_CvDimens.column + _CvDimens.gap);
      final right = left + _CvDimens.column;
      double? target;
      if (left < pos.pixels) {
        target = left - 12; // `cr.left - sr.left - 12`
      } else if (right > pos.pixels + pos.viewportDimension) {
        target = right - pos.viewportDimension + 12; // `cr.right - sr.right + 12`
      }
      if (target == null) return;
      _stripScroll.animateTo(
        target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
        duration: NymMotion.transition,
        curve: NymMotion.curve,
      );
    });
  }

  /// `_cvScrollToEnd` (columns.js:979-981): smooth-scroll the strip to its end
  /// (used when the add-column picker opens).
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

  /// Keep the PageView page valid after a removal/reorder changes the count.
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

  // --- Desktop column drag (`_cvStartColumnDrag`, columns.js:673-728) --------

  /// Header mouse-down (`_cvAttachDnd`): arm a potential drag. The drag itself
  /// starts only after 5px of pointer travel, so a plain click just focuses.
  void _onColumnHeaderDown(
      int index, PointerDownEvent e, BuildContext boundaryContext) {
    if (_isMobile) return;
    if (e.buttons != kPrimaryButton) return; // `e.button !== 0`
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
      // 5px start threshold (columns.js:682).
      final d = e.position - _dragStart;
      if (d.dx.abs() < 5 && d.dy.abs() < 5) return;
      _dragActive = true;
      _ghostPos = e.position - _grabOffset;
      _insertGhost();
      _captureDragImage();
      setState(() {}); // dim the source (`.cv-column.cv-dragging`, 0.4)
    }
    _ghostPos = e.position - _grabOffset;
    _dragGhostEntry?.markNeedsBuild();
    _updateDragTarget(e.position.dx);
  }

  /// Mouse-up / cancel: drop the ghost; when a drag actually ran, persist the
  /// (already live-reflowed) order. Focus is never changed by a reorder.
  void _onColumnHeaderUp() {
    if (_dragIndex == null) return;
    final wasActive = _dragActive;
    _removeGhost();
    _dragIndex = null;
    _dragActive = false;
    _dragBoundary = null;
    if (wasActive && mounted) {
      setState(() {}); // un-dim the source
      _saveLayout();
    }
  }

  /// Live reflow (columns.js:706-713): as the ghost crosses a neighbour's
  /// midpoint the strip reorders immediately — the dimmed source column moves to
  /// the insertion point, exactly like the PWA's `insertBefore` loop.
  void _updateDragTarget(double pointerX) {
    final from = _dragIndex;
    if (from == null || from >= _columns.length) return;
    if (!_stripScroll.hasClients) return;
    final stripBox = _stripKey.currentContext?.findRenderObject() as RenderBox?;
    if (stripBox == null) return;
    final originX =
        stripBox.localToGlobal(Offset.zero).dx - _stripScroll.offset;
    const span = _CvDimens.column + _CvDimens.gap;
    // Find the first non-dragged column whose midpoint is right of the pointer;
    // the dragged column inserts before it (else it goes to the end).
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
    final focusedDesc =
        (_focused >= 0 && _focused < _columns.length) ? _columns[_focused] : null;
    setState(() {
      final moved = _columns.removeAt(from);
      _columns.insert(insertAt, moved);
      _dragIndex = insertAt;
      // Reorders never move focus (`_cvMoveColumn`/drag `end()` don't touch
      // `_cvFocusedId`); re-derive the focused index by identity.
      if (focusedDesc != null) {
        final f = _columns.indexOf(focusedDesc);
        if (f >= 0) _focused = f;
      }
    });
  }

  /// Snapshot the dragged column's pixels so the ghost is an exact clone of what
  /// the user sees (the PWA clones the DOM node trimmed to visible messages).
  /// Until the async capture lands, the ghost shows a live widget clone.
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

  /// The floating drag clone (`.cv-drag-ghost`: fixed, exact column size,
  /// opacity 0.92, `--shadow-lg`, pointer-events none).
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
                // `--shadow-lg`: 0 8px 32px black@0.5 (dark) / @0.12 (light,
                // styles-themes-responsive.css:537).
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

  // --- Add-column picker (`_cvOpenAddColumn` / `_cvAvailableConversations`) ---

  /// `_cvAvailableConversations` (columns.js:774-803): channels (unless
  /// PM-only), then PMs, then groups — minus already-open columns. Row icons
  /// follow the picker markup: `#`, a 20px avatar, or the `◧` group fallback
  /// character (columns.js:798).
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
        final d = _ColumnDesc.channel(ch.channel, ch.geohash);
        if (open.contains(d)) continue;
        out.add((
          desc: d,
          label: '#${ch.geohash.isNotEmpty ? ch.geohash : ch.channel}',
          icon: _pickerRowIcon(context, d),
        ));
      }
    }
    for (final pm in pms) {
      final d = _ColumnDesc.pm(pm.pubkey, nym: pm.nym);
      if (open.contains(d)) continue;
      out.add((
        desc: d,
        label: pm.nym.isNotEmpty ? pm.nym : 'Direct message',
        icon: _pickerRowIcon(context, d),
      ));
    }
    for (final g in groups) {
      final d = _ColumnDesc.group(g.id);
      if (open.contains(d)) continue;
      out.add((
        desc: d,
        label: g.name.isNotEmpty ? g.name : 'Group chat',
        icon: _pickerRowIcon(context, d),
      ));
    }
    return out;
  }

  /// Picker-row icons (`.cv-picker-row-icon`, 13px row font): `#` for channels,
  /// a 20px round avatar for PMs / avatar groups, the literal `◧` otherwise.
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
        // `_cvAvailableConversations` group fallback is the '◧' character.
        return Text('◧',
            style: TextStyle(color: c.textDim, fontSize: 13, height: 1));
    }
  }

  /// `_cvOpenAddColumn` (columns.js:731-772): the picker is a column-shaped
  /// `.cv-picker` panel inserted into the strip before the (hidden) add button.
  /// Desktop: the strip smooth-scrolls to the end so the panel is in view.
  /// Mobile: every `.cv-column` — the picker included — is a full snap page
  /// (`flex:0 0 100%`, styles-columns.css:508-517), so the picker occupies the
  /// carousel's trailing page and the strip scrolls to it (`_cvScrollToEnd`).
  void _openAddColumn() {
    if (_pickerOpen) return; // `if (strip.querySelector('.cv-picker')) return`
    setState(() => _pickerOpen = true);
    if (_isMobile) {
      // `_cvScrollToEnd()`: the picker page replaces the (hidden) add-column
      // page at the end of the carousel.
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

  /// A picker row was chosen: `cvAddColumn(desc, { focus:true })` + close +
  /// `_cvScrollToIndex(len-1)` (columns.js:760-764).
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
      // `cvAddColumn` → `_cvSubscribeChannel` (geo relays, D1 restore); the
      // picked column gets focus via `_scrollToIndex` → `_syncFocusedView`,
      // which re-points the typing sub through `switchChannel`.
      _subscribeChannel(desc);
      _saveLayout();
    }
    _scrollToIndex(_focused);
  }

  /// The "Columns" bottom-sheet tab switcher (`_cvOpenTabsView` /
  /// `_cvBuildTabsView`): a list of `.cv-tab` rows with drag-to-reorder, a
  /// per-row close, the active column highlighted, and a "+ Add column" footer
  /// (gap F5). Reorders and removals commit IMMEDIATELY (the PWA saves on every
  /// drag `end()` and keeps the sheet open across removals), so dismissing the
  /// sheet never discards anything. Metrics from `styles-columns.css:623-772`.
  Future<void> _openTabsView() async {
    // The PWA overlay is a plain `display: none` → `display: flex` toggle
    // (`.cv-tabs-overlay.open`, styles-columns.css:623-635) with no
    // transition/animation, so the sheet POPS in/out instantly on both
    // breakpoints — a general dialog with a zero-length transition, not a
    // slide-up modal bottom sheet.
    final result = await showGeneralDialog<_TabsResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Columns',
      // `.cv-tabs-overlay` background rgba(0,0,0,0.5).
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: Duration.zero,
      pageBuilder: (ctx, _, __) => Material(
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
        // `_cvSwitchToColumn(row.dataset.colId)`: focus + reveal by identity.
        final i = _columns.indexOf(result.desc!);
        if (i >= 0) _scrollToIndex(i);
      case _TabsAction.add:
        _openAddColumn();
    }
  }

  /// Resolves a column's title (`_cvColTitle`).
  String _columnTitle(BuildContext context, _ColumnDesc d) {
    final app = ref.read(appStateProvider);
    switch (d.kind) {
      case _ColumnKind.channel:
        return '#${d.geohash.isNotEmpty ? d.geohash : d.channel}';
      case _ColumnKind.pm:
        final conv = app.pmConversations
            .where((c) => c.pubkey == d.pubkey)
            .toList();
        final nym = conv.isNotEmpty ? conv.first.nym : null;
        return (nym != null && nym.isNotEmpty)
            ? nym
            : (d.nym.isNotEmpty
                ? d.nym
                : (app.users[d.pubkey]?.nym ?? 'Direct message'));
      case _ColumnKind.group:
        final g = app.groups.where((g) => g.id == d.groupId).toList();
        return (g.isNotEmpty && g.first.name.isNotEmpty)
            ? g.first.name
            : 'Group chat';
    }
  }

  /// The rich column title (`_cvColTitleHtml`, columns.js:492-505): for PM
  /// columns the title carries the dimmed `#suffix` (`.nym-suffix`: 0.9em, w100,
  /// opacity 0.7), the user's flair/supporter badge, the verified-developer/bot
  /// ✓ badge, and the friend badge. Channels/groups render the bare title. Used
  /// by the column header (columns.js:394), and the tabs-sheet rows (:903-904).
  Widget _columnTitleWidget(
      BuildContext context, _ColumnDesc d, TextStyle style) {
    final title = _columnTitle(context, d);
    if (d.kind != _ColumnKind.pm || d.pubkey.isEmpty) {
      return Text(title,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    final base = stripPubkeySuffix(title);
    final suffix = getPubkeySuffix(d.pubkey);
    final controller = ref.read(nostrControllerProvider);
    final isDev = controller.isVerifiedDeveloper(d.pubkey);
    final isBot = !isDev && controller.isVerifiedBot(d.pubkey);
    final isFriend = ref.read(appStateProvider).friends.contains(d.pubkey);
    final cosmetics = ref.read(userCosmeticsProvider(d.pubkey));
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
                    // `.nym-suffix`: opacity 0.7, 0.9em, weight 100.
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
        // `getFlairForUser` markup (flair + supporter, both 20px like the PWA).
        CosmeticNymBadges(
          cosmetics: cosmetics,
          flairSize: 20,
          supporterHeight: 20,
        ),
        // `.verified-badge` (20×20 circle, ✓) for the developer/bot pubkeys.
        if (isDev || isBot) ...[
          const SizedBox(width: 4),
          VerifiedBadge(
            size: 20,
            tooltip: isDev ? 'Nymchat Developer' : 'Nymchat Bot',
          ),
        ],
        // `getFriendBadgeHtml`.
        if (isFriend) ...[
          const SizedBox(width: 4),
          const FriendBadge(size: 20),
        ],
      ],
    );
  }

  /// Resolves a column's header icon (`_cvColIcon`): a `#` text glyph for
  /// channels, a multi-person SVG for groups without an avatar (both in
  /// `--text-dim`), and a 20px round avatar for PMs / avatar-bearing groups.
  Widget _columnIcon(BuildContext context, _ColumnDesc d, {double size = 20}) {
    final c = context.nym;
    final app = ref.read(appStateProvider);
    switch (d.kind) {
      case _ColumnKind.channel:
        // `_cvColIcon` returns the literal text '#'; `.cv-col-icon` is text-dim.
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
        // Group fallback: the 16×16 multi-person SVG, stroked in text-dim.
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

    // Make the deck the navigation sink in columns mode: when the shared view
    // changes from outside (sidebar/notification/deep-link/back-forward), focus,
    // repurpose, or add the matching column (`_cvOpenConversation`, 08-B1).
    ref.listen<ChatView>(
      appStateProvider.select((s) => s.view),
      (prev, next) => _onExternalView(next),
    );

    // "Reset columns to defaults" pressed while the deck is mounted — the PWA
    // resets LIVE (`cvResetColumns` tears down + re-seeds + re-focuses,
    // columns.js:363-381); the tick is bumped by `SettingsController.
    // resetColumns` after clearing the persisted layout.
    ref.listen<int>(
      settingsProvider.select((s) => s.columnsResetTick),
      (prev, next) {
        if (prev != next) _onColumnsReset();
      },
    );

    if (_focused >= _columns.length) {
      _focused = _columns.isEmpty ? 0 : _columns.length - 1;
    }

    // On first mount, point the shared header/composer at the focused column
    // (mirrors `_cvEnable` → `_cvFocusColumn(first.id)`, columns.js:77-78).
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

  // --- Desktop (>768): horizontal strip + drag-reorder + pager ---------------

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
        // `.cv-pager` (centered, ≥769 only, hidden for a single column).
        if (_columns.length > 1)
          _Pager(
            count: _columns.length,
            active: _focused,
            onTap: _openTabsView,
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: _CvDimens.padding),
            // `.cv-strip::-webkit-scrollbar`: 6px, transparent track, radius 10.
            // Thumb rgba(255,255,255,0.12) → 0.2 on hover (styles-columns.css:
            // 110-117) — but `body.light-mode ::-webkit-scrollbar-thumb`
            // (styles-themes-responsive.css:1095-1106) is MORE SPECIFIC
            // (0-1-2 vs 0-1-1), so in light mode the strip thumb is
            // rgba(0,0,0,0.12) → 0.2 on hover.
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
                  padding: const EdgeInsets.symmetric(
                      horizontal: _CvDimens.padding),
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
                      // `.cv-picker` replaces the (hidden) add button while
                      // open (`_cvOpenAddColumn` sets `display:none` on it).
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

  // --- Mobile (<=768): full-width PageView snap carousel ---------------------

  Widget _buildMobile(
    NymColors c,
    List<ChannelEntry> channels,
    List<PMConversation> pms,
    List<Group> groups,
    bool pmOnly,
    bool transparentColumns,
  ) {
    // The "+ Add column" tile is the trailing page (PWA: it stays in the snap
    // strip at `flex:0 0 100%`).
    final pageCount = _columns.length + 1;
    return PageView.builder(
      controller: _pageController,
      // PWA parity: the mobile column strip is `overflow-x:hidden` with columns
      // `touch-action:pan-y` (styles-columns.css:496-517), so there is NO
      // column-to-column touch paging — columns are switched only via the
      // arrows/dots. Disabling touch paging here frees the horizontal-drag
      // budget for each message row's swipe-to-act (G3). Arrow/dot navigation
      // still works because it drives `jumpToPage` programmatically, which
      // ignores scroll physics.
      physics: const NeverScrollableScrollPhysics(),
      itemCount: pageCount,
      onPageChanged: (i) {
        if (i < _columns.length && i != _focused) {
          setState(() => _focused = i);
          // Re-point the shared header/composer at the now-visible column.
          _syncFocusedView();
        }
      },
      itemBuilder: (context, i) {
        if (i >= _columns.length) {
          // `_cvOpenAddColumn` inserts the `.cv-picker` — itself a `.cv-column`
          // — before the (display:none) add button, so on mobile the picker IS
          // the trailing full snap page (`flex:0 0 100%`, with the column
          // border/radius/shadow dropped — styles-columns.css:508-517).
          if (_pickerOpen) {
            return _PickerColumn(
              mobile: true,
              rows: _availableRows(context, channels, pms, groups, pmOnly),
              onPick: _addPickedColumn,
              onClose: () => setState(() => _pickerOpen = false),
            );
          }
          // Full-bleed dashed add-column page: the mobile strip has NO padding
          // (`.cv-strip { padding:0; gap:0 }`, styles-columns.css:501-506) and
          // the tile spans the whole screen (`.cv-add-column flex:0 0 100%`).
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

/// A desktop column slot: hosts the column, the "any click focuses" listener
/// (`columns.js:175-179` — delegated on the strip, so clicks on message rows
/// focus too; a [Listener] bypasses the gesture arena the rows' own recognizers
/// would otherwise win), the `cv-dragging` dim, and the [RepaintBoundary] the
/// custom header drag snapshots for its pixel-exact ghost.
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

  /// `.cv-column.cv-dragging { opacity: 0.4 }` while this column is dragged.
  final bool dimmed;
  final VoidCallback onClose;
  final VoidCallback onFocus;

  /// Header pointer plumbing for the deck-level drag (`_cvStartColumnDrag`).
  final void Function(PointerDownEvent event, BuildContext boundaryContext)
      onDragDown;
  final void Function(PointerMoveEvent event) onDragMove;
  final VoidCallback onDragEnd;

  /// At-bottom transitions, forwarded to the deck's read-gate bookkeeping.
  final ValueChanged<bool>? onAtBottomChanged;

  @override
  State<_DesktopColumnSlot> createState() => _DesktopColumnSlotState();
}

class _DesktopColumnSlotState extends State<_DesktopColumnSlot> {
  /// Marks the snapshot boundary for the drag ghost (and the drag geometry —
  /// grab offset + exact column size).
  final GlobalKey _boundaryKey = GlobalKey();

  /// True while the current pointer-down started on the close button. The PWA
  /// close click `e.stopPropagation()`s before the strip's click-to-focus
  /// delegate runs (columns.js:168-171), so closing an UNFOCUSED column never
  /// focuses it first (which would re-point the shared header/composer and
  /// clear its unread).
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
      // The close button's pointer-down lands here (deepest Listener) BEFORE
      // the slot's focus Listener below, flagging the event as "consumed".
      onCloseDown: () => _closePressed = true,
      onHeaderDown: (e) {
        final ctx = _boundaryKey.currentContext;
        if (ctx != null) widget.onDragDown(e, ctx);
      },
      onHeaderMove: widget.onDragMove,
      onHeaderUp: widget.onDragEnd,
      onAtBottomChanged: widget.onAtBottomChanged,
    );

    // Any click inside the column focuses it (`columns.js:175-179`) — EXCEPT
    // one on the close button, whose handler stops propagation in the PWA.
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
        // `.cv-column { transition: ... opacity var(--transition) }` — the
        // cv-dragging dim fades over 250ms cubic-bezier(0.4,0,0.2,1).
        duration: NymMotion.transition,
        curve: NymMotion.curve,
        opacity: widget.dimmed ? 0.4 : 1.0,
        child: RepaintBoundary(key: _boundaryKey, child: column),
      ),
    );
  }
}

/// A mobile carousel page: a full-width column whose header shows a position-dot
/// indicator + prev/next move arrows instead of the title/icon (gap F5).
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

  /// At-bottom transitions, forwarded to the deck's read-gate bookkeeping.
  final ValueChanged<bool>? onAtBottomChanged;

  @override
  Widget build(BuildContext context) {
    return _DeckColumn(
      desc: desc,
      // Title/icon are hidden on mobile; the dots take the title's slot.
      titleWidget: const SizedBox.shrink(),
      icon: const SizedBox.shrink(),
      // Mobile columns reset `.cv-column.focused` border/shadow to none.
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

/// A single deck column (`.cv-column`): 360px wide on desktop / full-width on
/// mobile, header + compact message list for one channel / PM / group.
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

  /// Desktop only: the focused column shows a primary border + `--shadow-glow`
  /// (`.cv-column.focused`). Always false on mobile (the PWA resets it to none).
  final bool focused;
  final bool transparent;
  final bool mobile;
  final int index;
  final int total;
  final VoidCallback onClose;

  /// Desktop: pointer-down on the close button, fired before the slot's
  /// click-to-focus Listener sees the event (the PWA close handler
  /// `stopPropagation()`s, columns.js:168-171).
  final VoidCallback? onCloseDown;

  /// Mobile prev/next carousel step (`_cvStepFocused`).
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// Mobile: tapping the dot indicator opens the "Columns" tabs sheet.
  final VoidCallback? onOpenTabs;

  /// Desktop: raw pointer plumbing over the header drag region so the deck can
  /// run the PWA's custom column drag (`_cvAttachDnd` mousedown on the header,
  /// excluding the close button — which sits outside this region).
  final void Function(PointerDownEvent event)? onHeaderDown;
  final void Function(PointerMoveEvent event)? onHeaderMove;
  final VoidCallback? onHeaderUp;

  /// Reports `col._atBottom` transitions up to the deck
  /// (`_cvAttachColumnScroll`, columns.js:633-636) so the columns read gate
  /// and the at-bottom mark-read can see this column's scroll state.
  final ValueChanged<bool>? onAtBottomChanged;

  @override
  ConsumerState<_DeckColumn> createState() => _DeckColumnState();
}

class _DeckColumnState extends ConsumerState<_DeckColumn> {
  final ScrollController _scroll = ScrollController();
  bool _atBottom = true;
  bool _showScrollButton = false;

  /// Message count last seen by [build] — detects appended messages, standing
  /// in for `_cvAttachAutoScroll`'s childList MutationObserver.
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant _DeckColumn old) {
    super.didUpdateWidget(old);
    if (old.desc.storageKey != widget.desc.storageKey) {
      // Repurposed column (`_cvNavigateColumn` → `_cvRenderColumn`): the PWA
      // re-renders the new conversation pinned to the newest message
      // (`scrollerEl.scrollTop = 0; col._atBottom = true`, columns.js:511-512).
      _lastMessageCount = 0;
      _atBottom = true;
      _showScrollButton = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scroll.hasClients && _scroll.offset != 0) _scroll.jumpTo(0);
        widget.onAtBottomChanged?.call(true);
      });
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Reversed list: offset 0 == newest at the bottom, so offset is the distance
    // from the bottom. The PWA decouples the two thresholds
    // (`_cvAttachColumnScroll`): at-bottom (autoscroll/mark-read) at <120, and
    // the scroll-to-bottom button shows at >150.
    final distanceFromBottom = _scroll.offset;
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
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: NymMotion.transition,
      curve: NymMotion.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final transparent = widget.transparent;
    final mobile = widget.mobile;
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final reactions = ref.watch(reactionsProvider);
    // Columns render the same FILTERED view as the single chat: the PWA's
    // columns draw via `renderMessagesWithVirtualScroll` → `getFilteredMessages`
    // / `getFilteredPMMessages` (columns.js:510 → messages.js:2934-2949), so
    // blocked users, blocked-keyword hits and heuristic spam are dropped here
    // exactly like `messagesForCurrentViewProvider` does for the single view.
    var messages = visibleMessagesFor(app, widget.desc.storageKey);
    // The Nymbot PM column additionally merges the bot engine's LOCAL-ONLY
    // info bubbles (welcome intro, `?help` guide, command outputs — PWA
    // `_displayBotInfoMessage`) exactly like the single-view `BotChatScreen`:
    // they never enter the shared store, so the store-only filter above would
    // silently drop them. The "thinking" strip needs no merge — it rides the
    // shared typing indicator ([TypingIndicatorRow] below).
    if (widget.desc.storageKey == BotChatController.conversationKey) {
      messages = mergeBotThreadWithInfo(
          messages, ref.watch(botChatControllerProvider).infoMessages);
    }

    // `_cvAttachAutoScroll` (columns.js:442-456): when new messages arrive
    // while the user is at the bottom (<120px, `_atBottom`), pin the column
    // back to the newest message (`scrollerEl.scrollTop = 0` in a rAF) —
    // UNLESS `settings.autoscroll === false`, in which case the observer bails
    // and the user's small scroll drift is preserved. (At offset exactly 0 the
    // reversed list tracks the newest edge inherently, like the PWA's
    // column-reverse scroller does at scrollTop 0 in both modes.)
    if (messages.length != _lastMessageCount) {
      final added = messages.length > _lastMessageCount;
      _lastMessageCount = messages.length;
      if (added && settings.autoscroll && _atBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients && _atBottom && _scroll.offset != 0) {
            _scroll.jumpTo(0);
          }
        });
      }
    }

    // `.cv-column.focused` (desktop): primary border + `--shadow-glow`
    // (`0 0 20px primary@0.1`). Mobile resets focused styling to none.
    final showFocus = widget.focused && !mobile;

    // `.cv-column` chrome. AnimatedContainer because the CSS cross-fades
    // border-color/box-shadow over `var(--transition)` (0.25s cubic-bezier)
    // when focus moves between columns (styles-columns.css:133).
    final body = AnimatedContainer(
      duration: NymMotion.transition,
      curve: NymMotion.curve,
      decoration: BoxDecoration(
        // `.columns-wallpaper` clears ONLY the column/scroller backgrounds
        // (styles-columns.css:72-78) — border + shadow + glass header remain.
        color: transparent ? Colors.transparent : c.bgSecondary,
        // Mobile columns drop the border/radius/shadow (`flex:0 0 100%`,
        // `border:none; border-radius:0; box-shadow:none`).
        borderRadius: mobile ? null : NymRadius.rmd,
        border: mobile
            ? null
            : Border.all(color: showFocus ? c.primary : c.glassBorder),
        // .cv-column box-shadow: focused → --shadow-glow (0 0 20px primary@0.1,
        // desktop only); else --shadow-md (0 4px 16px black@0.4 dark / @0.1
        // light, styles-themes-responsive.css:536), dropped on mobile only.
        boxShadow: showFocus
            ? [BoxShadow(color: c.primaryA(0.1), blurRadius: 20)]
            : mobile
                ? null
                : [
                    BoxShadow(
                      color: Colors.black
                          .withValues(alpha: c.isLight ? 0.1 : 0.4),
                      offset: const Offset(0, 4),
                      blurRadius: 16,
                    ),
                  ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildHeader(c, mobile),
          // .cv-column-scroller / .cv-list (padding 10) + scroll-to-bottom.
          // .messages-container background rgba(0,0,0,0.15) dark; light-mode
          // flips it to rgba(255,255,255,0.3) (themes-responsive.css:1230-1232),
          // so it must be mode-aware or the column body looks dark-tinted in
          // light mode. Transparent only under the columns wallpaper.
          Expanded(
            child: ColoredBox(
              color: transparent
                  ? Colors.transparent
                  : (c.isLight
                      ? const Color(0x4DFFFFFF) // white @ 0.3
                      : const Color(0x26000000)), // black @ 0.15
              child: Stack(
                children: [
                  Positioned.fill(
                    child: messages.isEmpty
                        // PWA renders empty columns through
                        // `_showMessageSkeleton(... () => _appendEmptyNote(...))`
                        // (messages.js:3066-3070): a shimmer for up to 3s, then
                        // the generic note if still empty (08-H1). Keyed on the
                        // storage key so re-pointing the column replays it.
                        ? _DeckEmptyOrLoading(
                            key: ValueKey(
                                'cvempty_${widget.desc.storageKey}'),
                            useBubbles: settings.useBubbles,
                            emptyNote: _emptyNoteText(),
                          )
                        : Builder(builder: (context) {
                            // Group consecutive same-author messages into the
                            // PWA `.message-group` runs and render each via
                            // MessageGroup — the SAME path the single-chat view
                            // uses — so columns get the gliding group avatar in
                            // bubble layout (previously a flat row list passed
                            // showAvatar:false, so columns had NO avatars). IRC
                            // layout still renders bare, avatar-less rows.
                            final groups = buildMessageGroups(
                              messages,
                              reactions: reactions,
                              useBubbles: settings.useBubbles,
                              mentionToken: '@${_baseNym(app.selfNym)}',
                            );
                            return ListView.builder(
                              controller: _scroll,
                              reverse: true,
                              padding: const EdgeInsets.all(10),
                              itemCount: groups.length,
                              itemBuilder: (context, revIndex) {
                                final entries =
                                    groups[groups.length - 1 - revIndex];
                                return MessageGroup(
                                  entries: entries,
                                  settings: settings,
                                  // `body.columns-mode` message-layout variants
                                  // (styles-columns.css:27-82): IRC rows stack
                                  // vertically, hover buttons stack, media caps
                                  // at 100%, and desktop self bubble groups
                                  // drop the 14px right padding.
                                  columnsMode: true,
                                  onReactionPicker: (msg) =>
                                      showReactionPicker(context, ref, msg),
                                );
                              },
                            );
                          }),
                  ),
                  // .cv-scroll-bottom: 36×36 circle, bottom/right 16, shown when
                  // scrolled >150px from the bottom (gap F10).
                  if (_showScrollButton && messages.isNotEmpty)
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: _ScrollBottomButton(onTap: _scrollToBottom),
                    ),
                ],
              ),
            ),
          ),
          // `.cv-typing` per-column typing indicator. Reuses the canonical
          // single-view widget (bouncing dots, bot "is thinking", 1.5px avatar
          // ring, light-mode bg flip) keyed off this column's storage key
          // (08-H2), rather than a degraded re-implementation.
          TypingIndicatorRow(storageKey: widget.desc.storageKey),
        ],
      ),
    );

    return mobile ? body : SizedBox(width: _CvDimens.column, child: body);
  }

  /// The empty-state text (`_appendEmptyNote`). Columns render through
  /// `renderMessagesWithVirtualScroll` (columns.js:507-514) whose empty path is
  /// `_showMessageSkeleton(container, () => _appendEmptyNote(container, 'No
  /// recent messages'))` (messages.js:3066-3070) — i.e. the GENERIC bare string
  /// in BOTH modes. The channel-specific "No recent messages in #&lt;name&gt;" is a
  /// single-view-only string (the `loadChannelFromRelays` path, messages.js:2840)
  /// and is NOT used by columns (08-H1).
  String _emptyNoteText() => 'No recent messages';

  /// Strips the `#suffix` off a nym for the `@name` mention token (mirrors
  /// messages_list `_baseNym`).
  String _baseNym(String nym) {
    final hash = nym.indexOf('#');
    return hash > 0 ? nym.substring(0, hash) : nym;
  }

  /// The `.cv-column-header` (padding 10/12, bottom border, gap 8). On desktop:
  /// 6-dot grip + icon + title (all draggable to reorder, `cursor:grab`) + a
  /// close button. On mobile: prev arrow + position dots (in the title's slot) +
  /// next arrow + close. The `.cv-col-unread` pill and the desktop move arrows
  /// are intentionally omitted (dead/desktop-hidden in the PWA).
  Widget _buildHeader(NymColors c, bool mobile) {
    final children = <Widget>[];

    if (mobile) {
      // PWA mobile header order (columns.js:391-399 + styles-columns.css:562-587):
      // `[ dots — LEFT-aligned, fills the title slot ][ ◀ prev ][ ▶ next ][ ✕ ]`.
      // The dots take the title's slot on the LEFT (left-aligned, flex:1) and
      // BOTH move arrows sit together on the RIGHT, then the close button.
      //
      // `.cv-col-dots`: the position-dot indicator, fills the title slot, taps
      // to open the tabs sheet.
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
      // `.cv-column-header { gap: 8px }` separates every visible control:
      // dots | prev | next | close (styles-columns.css:184-194).
      children.add(const SizedBox(width: 8));
      // `.cv-col-move` prev arrow (columns.js:397 — feather chevron-left).
      children.add(_HeaderIconButton(
        svg: NymIcons.chevronLeft,
        tooltip: 'Previous column',
        enabled: widget.index > 0,
        onTap: widget.onPrev,
      ));
      children.add(const SizedBox(width: 8));
      // `.cv-col-move` next arrow (columns.js:398 — feather chevron-right).
      children.add(_HeaderIconButton(
        svg: NymIcons.chevronRight,
        tooltip: 'Next column',
        enabled: widget.index < widget.total - 1,
        onTap: widget.onNext,
      ));
      // `.cv-col-close`.
      children.add(const SizedBox(width: 8));
      children.add(_buildCloseButton(c));
      return _headerContainer(c, Row(children: children));
    }

    // Desktop: the whole header is the drag source (`_cvAttachDnd` mousedown on
    // the header, excluding the close button). The grip + icon + title form the
    // draggable region; `.cv-col-move` arrows are desktop-hidden (reorder is
    // drag-only) and the unread pill is never shown (`.cv-col-unread:empty`).
    children.add(_DragHandle(color: c.textDim));
    children.add(const SizedBox(width: 8));
    children.add(widget.icon);
    children.add(const SizedBox(width: 8));
    children.add(Expanded(child: widget.titleWidget));

    Widget dragRegion = Row(children: children);
    if (widget.onHeaderDown != null) {
      // Raw pointer listener (no gesture arena) so the deck can run the PWA's
      // 5px-threshold custom drag; move/up events keep routing here after the
      // down hit-tested this region.
      dragRegion = Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: widget.onHeaderDown,
        onPointerMove: widget.onHeaderMove,
        onPointerUp: (_) => widget.onHeaderUp?.call(),
        onPointerCancel: (_) => widget.onHeaderUp?.call(),
        child: dragRegion,
      );
    }
    // `.cv-column-header { cursor: grab }` over the draggable region.
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

  /// The `.cv-col-close` button — the X glyph itself recolors text-dim → danger
  /// on hover over `var(--transition)` (styles-columns.css:268-270); no hover
  /// circle/fill in the PWA.
  Widget _buildCloseButton(NymColors c) {
    Widget btn = _HoverCloseButton(
      tooltip: 'Remove column',
      size: 16,
      hoverColor: c.danger,
      onTap: widget.onClose,
    );
    final down = widget.onCloseDown;
    if (down != null) {
      // Deeper Listeners see the pointer first, so this fires before the
      // desktop slot's click-to-focus Listener (`stopPropagation()` analogue).
      btn = Listener(onPointerDown: (_) => down(), child: btn);
    }
    return btn;
  }

  /// The `.cv-column-header` chrome (padding 10/12, glass bg, bottom border).
  /// Kept glass under the columns wallpaper — only `.cv-column`/`.cv-scroller`
  /// go transparent (styles-columns.css:72-78); the header keeps var(--glass-bg).
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

/// The empty-column surface: a shimmer [MessageSkeleton] while history is
/// plausibly still loading, settling into the centered "No recent messages"
/// note after a ~3s grace period — a 1:1 port of the PWA's
/// `_showMessageSkeleton` (shimmer) → `_appendEmptyNote` (note) flow for columns
/// (`renderMessagesWithVirtualScroll`'s empty path, messages.js:3066-3070, with
/// `this._msgSkeletonSettleMs || 3000`). The same widget the single view uses
/// (`messages_list.dart`'s `_EmptyOrLoading`), recreated per column via a
/// storage-key-keyed instance so the shimmer plays on every (re)entry. Once a
/// message arrives `messages.isEmpty` is false and this widget stops rendering,
/// matching the PWA where an incoming message clears the skeleton/note.
class _DeckEmptyOrLoading extends StatefulWidget {
  const _DeckEmptyOrLoading({
    super.key,
    required this.useBubbles,
    required this.emptyNote,
  });

  /// Bubble vs IRC skeleton layout (`body.chat-bubbles`).
  final bool useBubbles;

  /// The settled-state note text (`_appendEmptyNote`); the generic "No recent
  /// messages" for columns.
  final String emptyNote;

  @override
  State<_DeckEmptyOrLoading> createState() => _DeckEmptyOrLoadingState();
}

class _DeckEmptyOrLoadingState extends State<_DeckEmptyOrLoading> {
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

/// The `.cv-drag-handle` 6-dot grip (14×14 svg, two columns of three dots,
/// text-dim → text-bright on hover). Desktop only.
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

/// Paints the two-column, three-row dot grip from the PWA SVG
/// (`circle cx=9/15 cy=6/12/18 r=1.4` in a 24×24 box).
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

/// The group-header fallback glyph (`_cvColIcon` multi-person SVG): three heads
/// + shoulders, stroked (no fill), `stroke-width 1.75` in a 24×24 viewBox.
class _GroupGlyphPainter extends CustomPainter {
  _GroupGlyphPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24; // uniform scale (16×16 box).
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset p(double x, double y) => Offset(x * s, y * s);

    // Center head + shoulders: circle cx12 cy7 r2.75; M5 21v-1.5 a7 7 0 0 1 14 0 V21.
    canvas.drawCircle(p(12, 7), 2.75 * s, paint);
    final centre = Path()
      ..moveTo(5 * s, 21 * s)
      ..relativeLineTo(0, -1.5 * s)
      ..arcToPoint(p(19, 19.5), radius: Radius.circular(7 * s), clockwise: true)
      ..lineTo(19 * s, 21 * s);
    canvas.drawPath(centre, paint);

    // Left figure: circle cx4.5 cy9.5 r2; M1 20v-1 a4.5 4.5 0 0 1 5.5-4.35.
    canvas.drawCircle(p(4.5, 9.5), 2 * s, paint);
    final left = Path()
      ..moveTo(1 * s, 20 * s)
      ..relativeLineTo(0, -1 * s)
      ..relativeArcToPoint(p(5.5, -4.35),
          radius: Radius.circular(4.5 * s), clockwise: true);
    canvas.drawPath(left, paint);

    // Right figure: circle cx19.5 cy9.5 r2; M23 20v-1 a4.5 4.5 0 0 0-5.5-4.35.
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

/// The mobile per-column position dots (`.cv-hdot`): 6px circles, 2px h-margin,
/// the active one primary/opaque (`styles-columns.css:573-587`).
class _HeaderDots extends StatelessWidget {
  const _HeaderDots({required this.count, required this.active});
  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // PWA `.cv-col-dots` has no `justify-content`, so dots default to flex-start
    // (LEFT-aligned) within their flex:1 slot (styles-columns.css:562-570).
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
                color: i == active
                    ? c.primary
                    : c.textDim.withValues(alpha: 0.4),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small header control button used for the mobile `.cv-col-move` prev/next
/// carousel arrows (`_cvStepFocused`). text-dim → text-bright on hover; the PWA
/// never dims the arrows at the ends (`_cvStepFocused` silently no-ops,
/// columns.js:321-327, and `.cv-col-move` keeps `--text-dim`). (Desktop move
/// arrows don't exist — reorder is drag-only.)
class _HeaderIconButton extends StatefulWidget {
  const _HeaderIconButton({
    required this.svg,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final String svg;
  final String tooltip;

  /// Gates the tap only (a tap past the first/last column is a silent no-op);
  /// the visual state never changes.
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

/// The desktop `.cv-pager`: centered row of `.cv-pdot` (7px) dots above the
/// strip, the active column's dot primary/opaque; the whole cluster opens the
/// tabs view. Shown only for >1 column (gap F5).
class _Pager extends StatefulWidget {
  const _Pager({required this.count, required this.active, required this.onTap});
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
          message: 'Switch columns',
          child: Padding(
            // `.cv-pager` padding: 12px 8px 0.
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // `.cv-pdot`: text-dim @ 0.4, active primary @ 1 — but
                // `.cv-pager:hover .cv-pdot { opacity: 0.7 }` outweighs
                // `.cv-pdot.active` (specificity 0,3,0 vs 0,2,0), so on hover
                // EVERY dot — the active one included — dims to 0.7. Both the
                // opacity and background cross-fade over 0.15s (ease).
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

/// A close/X glyph button whose ICON recolors on hover (no hover fill), with
/// the CSS `transition: color var(--transition)` (250ms) — `.cv-col-close` /
/// `.cv-tab-close` hover → `--danger`, `.cv-tabs-close` hover → text-bright.
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

// --- Add-column picker (`.cv-picker`) ----------------------------------------

/// The in-strip add-column panel (`_cvOpenAddColumn`, columns.js:731-772
/// + styles-columns.css:322-390): a column-shaped `.cv-column.cv-picker` frame
/// inserted before the (hidden) add button, with an "Add a column" header
/// (`.cv-col-title`: 14/600/--secondary) + cancel X, a search input, and the
/// filtered conversation rows. With [mobile] the panel is a full carousel page
/// and the mobile `.cv-column` rules drop the border/radius/shadow
/// (styles-columns.css:508-517).
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
      // `.cv-column` chrome (the picker reuses the column frame); mobile keeps
      // only the bg-secondary fill.
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
          // `.cv-column-header` with only the title + `.cv-picker-close`.
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
                    'Add a column',
                    style: TextStyle(
                      color: c.secondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _HoverCloseButton(
                  tooltip: 'Cancel',
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

/// The picker's search field + filtered rows (`.cv-picker-search` /
/// `.cv-picker-list`, the latter `flex:1`), shared by the desktop in-strip
/// panel and the mobile full-page picker. The input grabs focus 30ms after
/// opening (`setTimeout(() => input.focus(), 30)`).
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
        : widget.rows
            .where((r) => r.label.toLowerCase().contains(f))
            .toList();

    // `.cv-picker-search` (padding 10, bottom border) → `.cv-picker-input`.
    final search = Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: TextField(
        controller: _ctrl,
        focusNode: _focusNode,
        style: TextStyle(color: c.textBright, fontSize: 14),
        cursorColor: c.isLight ? Colors.black : Colors.white,
        onChanged: (v) => setState(() => _term = v),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search conversations…',
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

    // `.cv-picker-empty`: padding 16, centered, text-dim, 12px.
    final Widget list = shown.isEmpty
        ? Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No conversations',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textDim, fontSize: 12),
              ),
            ),
          )
        : ListView(
            // `.cv-picker-list { padding: 6px }`.
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

/// A `.cv-picker-row`: padding 8/10, gap 10, 13px text, radius-xs, hover
/// rgba(255,255,255,0.05) (styles-columns.css:343-361).
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
              // `.cv-picker-row-icon` (20px imgs, text-dim glyphs).
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

// --- "Columns" tabs sheet (`.cv-tabs-overlay` / `.cv-tabs-sheet`) ------------

/// What the tabs sheet was dismissed with; reorders/removals are committed live
/// through callbacks (the PWA saves on every drag `end()` and keeps the sheet
/// open across removals), so only select/add need to round-trip.
enum _TabsAction { select, add }

class _TabsResult {
  const _TabsResult.select(this.desc) : action = _TabsAction.select;
  const _TabsResult.add()
      : action = _TabsAction.add,
        desc = null;

  final _TabsAction action;
  final _ColumnDesc? desc;
}

/// The "Columns" bottom-sheet (`.cv-tabs-overlay`/`.cv-tabs-sheet`): a
/// reorderable list of `.cv-tab` rows (drag handle + icon + title + close), the
/// active column highlighted, plus a "+ Add column" footer (gap F5). Metrics
/// from `styles-columns.css:623-772`.
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

  /// Commits a reorder immediately ([from] → final index [to]), like the PWA
  /// drag `end()` (columns.js:928-937).
  final void Function(int from, int to) onReorder;

  /// Requests a (confirmed) removal; resolves true when the column is gone.
  /// The sheet stays open and just drops the row (columns.js:862-866).
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
    // `@media(min-width:769px)`: the overlay centers the sheet, which gets an
    // all-corner `--radius-lg` and a 70vh cap. Below that it's a bottom sheet
    // with top-only radius and a 75vh cap.
    final desktop = size.width >= 769;
    final maxHeight = size.height * (desktop ? 0.70 : 0.75);
    return SafeArea(
      top: false,
      child: Align(
        alignment: desktop ? Alignment.center : Alignment.bottomCenter,
        child: ConstrainedBox(
          // `.cv-tabs-sheet`: max-width 520.
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
              // `--shadow-lg`: 0 8px 32px black@0.5 (dark) / @0.12 (light,
              // styles-themes-responsive.css:537).
              boxShadow: [
                BoxShadow(
                  color: Colors.black
                      .withValues(alpha: c.isLight ? 0.12 : 0.5),
                  blurRadius: 32,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // `.cv-tabs-head`: padding 14/16, bottom border, primary title
                // (font-weight 600, inherited 14px size).
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: c.glassBorder)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Columns',
                          style: TextStyle(
                            color: c.primary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      // `.cv-tabs-close` (columns.js:851): X glyph, text-dim →
                      // text-bright on hover.
                      _HoverCloseButton(
                        tooltip: 'Close',
                        size: 18,
                        padding: const EdgeInsets.all(4),
                        hoverColor: c.textBright,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                // `.cv-tabs-list`: the reorderable `.cv-tab` rows.
                Flexible(
                  child: ReorderableListView.builder(
                    shrinkWrap: true,
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.all(8),
                    itemCount: _local.length,
                    // `.cv-tab.cv-dragging { opacity:0.6; border-style:dashed }`
                    // — the drag proxy is the row at 60% with a dashed border,
                    // not Material's default elevated card.
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
                    // `onReorder` over `onReorderItem`: the latter doesn't exist
                    // on the build toolchain's Flutter; this works on both
                    // (deprecated-only on newer SDKs).
                    // ignore: deprecated_member_use
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex -= 1;
                      setState(() {
                        final moved = _local.removeAt(oldIndex);
                        _local.insert(newIndex, moved);
                      });
                      // Commit instantly (`end()` re-sorts `_cvColumns`, moves
                      // the strip DOM and saves — the sheet stays open).
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
                        onTap: () => Navigator.of(context)
                            .pop(_TabsResult.select(desc)),
                        onClose: () async {
                          // Remove by identity and keep the sheet open,
                          // rebuilding the rows (columns.js:862-866).
                          final removed = await widget.onRemove(desc);
                          if (removed && mounted) {
                            setState(() => _local.remove(desc));
                          }
                        },
                      );
                    },
                  ),
                ),
                // `.cv-tabs-add`: dashed "+ Add column" footer (hover: primary
                // border + bright text, NO bg fill — styles-columns.css:757-772).
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

/// A single `.cv-tab` row in the tabs sheet: drag handle + icon + title + close,
/// active rows get a primary border (`styles-columns.css:690-755`). With
/// [dragging] the row renders the PWA `.cv-dragging` style (opacity 0.6, dashed
/// border) — used as the reorder drag proxy.
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
      // `.cv-tab` padding 10, gap 10.
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          // `.cv-tab-handle` (6-dot grip).
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
          // `.cv-tab-close` (columns.js:899): the X glyph itself recolors
          // text-dim → danger on hover (styles-columns.css:753-755).
          _HoverCloseButton(
            tooltip: 'Remove column',
            size: 16,
            padding: const EdgeInsets.all(4),
            hoverColor: c.danger,
            onTap: onClose,
          ),
        ],
      ),
    );

    if (dragging) {
      // `.cv-tab.cv-dragging { opacity: 0.6; border-style: dashed }`.
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
      // `.cv-tab` margin-bottom 6.
      padding: const EdgeInsets.only(bottom: 6),
      // `.cv-tab` has `cursor: pointer` but NO hover state (styles-columns.css:
      // 690-700) — a plain container, no Material ink tint or ripple.
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

/// `.cv-scroll-bottom`: 36×36 circle, glass fill, 1px glass border, primary
/// chevron, `--shadow-md`, hover scale 1.1 + primary tint (gap F10). Unlike the
/// single-view `.scroll-to-bottom-btn`, this class has NO light-mode override
/// (styles-themes-responsive.css:607-615 targets `.scroll-to-bottom-btn` only)
/// — it keeps `var(--glass-bg)` / `var(--glass-border)` in both themes, with the
/// theme's `--shadow-md` (light: 0 4px 16px black@0.1).
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
            // `.cv-scroll-bottom` chevron (columns.js:418) — down chevron.
            child: NymSvgIcon(NymIcons.chevronDown, size: 20, color: c.primary),
          ),
        ),
      ),
    );
  }
}

/// The dashed "+ Add column" affordance (`.cv-add-column` / `.cv-tabs-add`).
/// Hover (desktop) swaps the border/label to primary/bright; the strip tile
/// also fills primary@0.04 (`.cv-add-column:hover`) while the tabs footer does
/// NOT (`.cv-tabs-add:hover` sets border/color only) — gate via [hoverFill].
/// Width/height are configurable so it can serve the 220px strip tile, the
/// full-width mobile carousel page, and the 44px tabs-sheet footer.
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
                '+ Add column',
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

/// A 2px dashed rounded border (the CSS `border: 2px dashed var(--glass-border)`
/// on `.cv-add-column`), with an optional [fill] (hover state, F24).
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

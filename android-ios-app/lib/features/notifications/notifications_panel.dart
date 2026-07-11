// notifications_panel.dart - In-app notification history modal
// (`#notificationsModal` + `openNotificationsModal`, notifications.js:439-592).
//
// Foundations ships the STORE (`notificationHistoryProvider`); this builds the
// modal UI that renders its entries (avatar + decorated author wrapped in
// `<…>` brackets + body + context label + timestamp), highlights unread rows
// (cyan wash + primary left rule), exposes a "Mark all as read" action, and opens
// the source conversation on tap (notifications.js:559-585). The shell owns the
// bell + badge and calls [showNotificationsPanel].
//
// Rendered as a centered `.modal` (showDialog) with shared modal chrome: 22px
// UPPERCASE primary header + bottom rule, 32px circular glass close chip.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/nym_avatar.dart';
import '../calls/call_nym.dart';
import '../i18n/i18n.dart';
import '../messages/format/message_content.dart';

/// Opens the notifications history as a centered modal (the PWA renders it as a
/// `.modal` overlay).
///
/// Opening does NOT clear the badge. Entries are marked viewed per item, only
/// as their row actually scrolls into view (≥60% visible in the modal body),
/// deducting the badge one by one — the PWA's `_setupNotificationSeenObserver`
/// (notifications.js:596-642, IntersectionObserver root=body threshold 0.6).
/// Each entry's unread state is SNAPSHOTTED here (before `showDialog`) so the
/// row list and its ordering stay frozen for the modal's lifetime while the
/// live `viewed` flags flip underneath as rows are seen.
Future<void> showNotificationsPanel(BuildContext context) {
  // Read the store before showDialog so the snapshot precedes the shell's
  // on-open markAllViewed() (which flips the same entries' `viewed` bools).
  final container = ProviderScope.containerOf(context);
  final all = container.read(notificationHistoryProvider).entries;
  // PWA openNotificationsModal filters at RENDER time (notifications.js:
  // 456-462): drop entries older than 24h (the store trims only when a new
  // record lands, so a long-running session / stale hydrate can still hold
  // older rows) and entries from blocked senders, then order newest-first
  // regardless of insertion order (historical replay + remote sync merges can
  // leave the store out of order).
  final blocked = container.read(appStateProvider).blockedUsers;
  final cutoff24h =
      DateTime.now().millisecondsSinceEpoch - 24 * 60 * 60 * 1000;
  final entries = [
    for (final e in all)
      if (e.ts > cutoff24h && !blocked.contains(e.senderPubkey ?? '')) e,
  ]..sort((a, b) => b.ts.compareTo(a.ts));
  // Freeze the unread state per entry as a parallel list of bools (a public
  // type, so the widget constructor doesn't leak a private one).
  final viewedAtOpen = [for (final e in entries) e.viewed];
  // `.modal` barrier: solid-ui (default) dark `rgba(0,0,0,0.75)` →
  // `body.solid-ui.light-mode .modal { rgba(0,0,0,0.45) }`
  // (styles-themes-responsive.css:1630-1635).
  final isLight = context.nym.isLight;
  return showDialog<void>(
    context: context,
    barrierColor: isLight
        ? const Color(0x73000000) // black @ 0.45
        : const Color(0xBF000000), // black @ 0.75
    builder: (_) => NotificationsPanel(
      entries: entries,
      viewedAtOpen: viewedAtOpen,
    ),
  );
}

class NotificationsPanel extends ConsumerStatefulWidget {
  const NotificationsPanel({
    super.key,
    required this.entries,
    required this.viewedAtOpen,
  });

  /// Entries snapshotted at open (newest-first).
  final List<NotificationEntry> entries;

  /// Each entry's `viewed` state frozen at open, parallel to [entries] (see
  /// [showNotificationsPanel]) — the rows start from this snapshot and flip
  /// locally as they scroll into view / on "Mark all as read".
  final List<bool> viewedAtOpen;

  @override
  ConsumerState<NotificationsPanel> createState() => _NotificationsPanelState();
}

class _NotificationsPanelState extends ConsumerState<NotificationsPanel> {
  late final List<_NotifRow> _rows = [
    for (var i = 0; i < widget.entries.length; i++)
      _NotifRow(widget.entries[i], widget.viewedAtOpen[i]),
  ];

  /// Drives the "Mark all as read" button + per-row highlight locally so the modal
  /// reflects the action immediately without a provider round-trip.
  late bool _hasUnread = _rows.any((r) => !r.viewed);

  /// The modal body's scroll viewport — the observer `root` the ≥60%
  /// visibility is measured against (notifications.js:639 `{root: body,
  /// threshold: 0.6}`).
  final GlobalKey _bodyKey = GlobalKey();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Fetch kind-0 for every distinct sender shown (the PWA's per-row
    // `queueProfileFetch`, notifications.js:473-481). Senders restored from
    // persisted history on boot never went through a message ingest, so without
    // this their rows show identicons. `ensureProfiles` → `_maybeBackfillProfiles`
    // self-guards (self / already-pictured / staleness), so passing every sender
    // is safe.
    final senders = <String>{
      for (final e in widget.entries)
        if ((e.senderPubkey ?? '').isNotEmpty) e.senderPubkey!,
    };
    if (senders.isNotEmpty) {
      ref.read(nostrControllerProvider).ensureProfiles(senders);
    }
    // Per-item scroll-into-view read semantics (`_setupNotificationSeenObserver`,
    // notifications.js:596-642): rows ≥60% visible in the modal body are marked
    // viewed as they appear, deducting the badge per item instead of zeroing on
    // open. No IntersectionObserver natively — the scroll listener + a
    // first-frame pass measure row geometry against the body viewport instead.
    _scroll.addListener(_markVisibleSeen);
    WidgetsBinding.instance.addPostFrameCallback((_) => _markVisibleSeen());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Marks every unread row currently ≥60% visible in the modal body viewport
  /// as viewed — the observer callback half of the PWA's per-item seen flow
  /// (notifications.js:604-625: flip `viewed`, remember the seen-key, persist,
  /// re-derive the badge, drop the unread styling, and hide "Mark all as read"
  /// once nothing unread remains). [NotificationHistoryNotifier.markEntriesViewed]
  /// owns the store-side half (persist + seen-keys + badge + cross-device sync).
  void _markVisibleSeen() {
    if (!mounted) return;
    final bodyBox =
        _bodyKey.currentContext?.findRenderObject() as RenderBox?;
    if (bodyBox == null || !bodyBox.attached || !bodyBox.hasSize) return;
    final bodyRect = bodyBox.localToGlobal(Offset.zero) & bodyBox.size;
    final seen = <NotificationEntry>[];
    for (final r in _rows) {
      if (r.viewed) continue;
      final ctx = r.key.currentContext;
      final box = ctx?.findRenderObject() as RenderBox?;
      // Off-screen rows aren't built (ListView.builder) or lie outside the
      // viewport — both stay unread, exactly like unobserved PWA items.
      if (box == null || !box.attached || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.height <= 0) continue;
      final overlap = rect.intersect(bodyRect);
      if (overlap.height <= 0 || overlap.width <= 0) continue;
      if (overlap.height / rect.height < 0.6) continue;
      r.viewed = true;
      seen.add(r.entry);
    }
    if (seen.isEmpty) return;
    ref.read(notificationHistoryProvider.notifier).markEntriesViewed(seen);
    setState(() => _hasUnread = _rows.any((r) => !r.viewed));
  }

  void _markAllRead() {
    ref.read(notificationHistoryProvider.notifier).markAllViewed();
    setState(() {
      for (final r in _rows) {
        r.viewed = true;
      }
      _hasUnread = false;
    });
  }

  /// Opens the source conversation for [entry] and closes the modal
  /// (notifications.js:559-585: pm → `openUserPM`, group → `openGroup`, reaction/
  /// mention → the reactor's/author's PM, call → PM or group).
  void _openEntry(NotificationEntry entry) {
    final controller = ref.read(nostrControllerProvider);
    final appState = ref.read(appStateProvider.notifier);
    final route = entry.route ?? '';
    final sender = entry.senderPubkey ?? '';
    final isPubkeyRoute = _isPubkey(route);
    switch (entry.type) {
      case 'group':
        if (route.isNotEmpty) appState.switchView(ChatView.group(route));
        break;
      case 'channel':
      case 'geohash':
        // A channel/geohash mention switches to that channel (the route is the
        // bare channel name; switchChannel auto-detects geohash).
        if (route.isNotEmpty) controller.switchChannel(route);
        break;
      case 'call':
        // Call routes carry a group id (group call) or a pubkey (1:1 call).
        if (isPubkeyRoute) {
          controller.startPM(route);
        } else if (route.isNotEmpty) {
          appState.switchView(ChatView.group(route));
        } else if (sender.isNotEmpty) {
          controller.startPM(sender);
        }
        break;
      case 'pm':
      case 'mention':
      case 'reaction':
      default:
        // These route to the sender's PM (the avatar pubkey).
        final target = sender.isNotEmpty
            ? sender
            : (isPubkeyRoute ? route : '');
        if (target.isNotEmpty) controller.startPM(target);
        break;
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          // .modal-content (radius 24, glass border, shadow + glow + 1px ring),
          // max-width 500, width 90%.
          width: MediaQuery.of(context).size.width * 0.9,
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 640),
          decoration: BoxDecoration(
            color: c.bgSecondary,
            borderRadius: NymRadius.rxl,
            border: Border.all(color: c.glassBorder),
            // `body.light-mode .modal-content { box-shadow: 0 8px 40px
            // rgba(0,0,0,0.12) }` — one soft shadow, no glow, no white ring in
            // light (styles-themes-responsive.css:1050-1052).
            boxShadow: c.isLight
                ? const [
                    BoxShadow(
                      color: Color(0x1F000000), // black @ 0.12
                      blurRadius: 40,
                      offset: Offset(0, 8),
                    ),
                  ]
                : [
                    const BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 32,
                      offset: Offset(0, 8),
                    ),
                    BoxShadow(
                        color: c.primary.withValues(alpha: 0.1),
                        blurRadius: 20),
                    BoxShadow(
                        color: Colors.white.withValues(alpha: 0.05),
                        spreadRadius: 1),
                  ],
          ),
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // .modal-header (`.nm-h-76`): 22px UPPERCASE primary + ls1.5.
                  // In this modal the header drops its own bottom rule (padding
                  // 32/32/10, `border-bottom: none`) — the rule moves onto the
                  // toggle block below (no-inline.css:94). A block element —
                  // full width, LEFT-aligned (never centered).
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(32, 32, 32, 10),
                    child: Text(
                      tr('NOTIFICATIONS'),
                      style: TextStyle(
                        color: c.primary,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  // The three notification preference checkboxes
                  // (`.nm-h-77` block, index.html:2265-2280): Enable / group
                  // mentions-only / friends-only. Carries the header's bottom
                  // rule (no-inline.css:95).
                  const _NotifToggles(),
                  // .notifications-mark-read-row (flex-end, padding 8/24/0).
                  if (_hasUnread)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _MarkReadBtn(onTap: _markAllRead),
                      ),
                    ),
                  // .notifications-modal-body (max-height 60vh, padding
                  // 12/24/24).
                  Flexible(
                    child: _rows.isEmpty
                        ? Padding(
                            // .notifications-empty: centered textDim 14,
                            // padding 40/20.
                            padding: const EdgeInsets.fromLTRB(20, 40, 20, 40),
                            child: Text(
                              tr('No notifications in the last 24 hours'),
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(color: c.textDim, fontSize: 14),
                            ),
                          )
                        : ListView.builder(
                            key: _bodyKey,
                            controller: _scroll,
                            shrinkWrap: true,
                            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                            itemCount: _rows.length,
                            itemBuilder: (ctx, i) => _NotificationRow(
                              // Row geometry handle for the ≥60%-visible
                              // per-item seen pass ([_markVisibleSeen]).
                              key: _rows[i].key,
                              entry: _rows[i].entry,
                              viewed: _rows[i].viewed,
                              isLast: i == _rows.length - 1,
                              onTap: () => _openEntry(_rows[i].entry),
                            ),
                          ),
                  ),
                ],
              ),
              // .modal-close chip.
              Positioned(
                top: 14,
                right: 14,
                child: _CloseChip(
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The notifications modal's three preference checkboxes (`.nm-h-77` block,
/// index.html:2265-2280): "Enable notifications" (`toggleNotificationsEnabled`,
/// settings.js:852), "Only notify for mentions in group chats"
/// (`toggleGroupMentionsOnly`, groups.js:3530), "Only notify for messages from
/// friends" (`toggleNotifyFriendsOnly`, settings.js:859).
///
/// The PWA persists each to localStorage (`nym_notifications_enabled` /
/// `nym_group_notify_mentions_only` / `nym_notify_friends_only`). We mirror
/// that here:
/// * Enable → reactive `Settings.notificationsEnabled` (so the bell glyph
///   chat_pane.dart:713 + the gate nostr_controller.dart:931 flip live) AND the
///   `nym_notifications_enabled` KV key.
/// * The other two → KV only; the gates read those keys directly
///   (nostr_controller.dart:932-938), so no `Settings` field is involved.
///
/// NOT done here (cross-file, deferred): the PWA's `nostrSettingsSave()` push
/// after each toggle (cross-device settings sync) and `_updateNotificationBadge`
/// (the badge is owned by the shell via `notificationHistoryProvider.unread`).
class _NotifToggles extends ConsumerStatefulWidget {
  const _NotifToggles();

  @override
  ConsumerState<_NotifToggles> createState() => _NotifTogglesState();
}

class _NotifTogglesState extends ConsumerState<_NotifToggles> {
  // The two KV-only flags are mirrored into local state so the checkbox flips
  // immediately on tap (the gates read KV directly, so there's no provider to
  // watch). Seeded from KV in initState; 'true' string == on, default off to
  // match the unchecked PWA checkboxes (index.html:2272/2277).
  late bool _mentionsOnly;
  late bool _friendsOnly;

  @override
  void initState() {
    super.initState();
    final kv = ref.read(keyValueStoreProvider);
    _mentionsOnly =
        kv.getString(StorageKeys.groupNotifyMentionsOnly) == 'true';
    _friendsOnly = kv.getString(StorageKeys.notifyFriendsOnly) == 'true';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final kv = ref.read(keyValueStoreProvider);
    // Enable is a real Settings field (watched so the box reflects it live).
    final enabled =
        ref.watch(settingsProvider.select((s) => s.notificationsEnabled));

    return Container(
      // `.nm-h-77`: padding 0/32/16 + 1px glass bottom rule.
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // `.nm-h-78` — top option, no indent.
          _ToggleRow(
            label: tr('Enable notifications'),
            value: enabled,
            onChanged: (v) {
              // Reactive state so the bell + gate update without a relaunch
              // (mirror toggleNotificationsEnabled, settings.js:853-854). The
              // plain `update` escape-hatch keeps this within the panel's
              // ownership (the typed setter lives in settings_provider, owned
              // elsewhere); it does NOT fire the cross-device sync hook.
              ref
                  .read(settingsProvider.notifier)
                  .update((s) => s.copyWith(notificationsEnabled: v));
              kv.setString(StorageKeys.notificationsEnabled, '$v');
            },
          ),
          // `.nm-h-80` — indented sub-options (margin-top 6, margin-left 20).
          _ToggleRow(
            label: tr('Only notify for mentions in group chats'),
            value: _mentionsOnly,
            indent: true,
            onChanged: (v) {
              setState(() => _mentionsOnly = v);
              kv.setString(StorageKeys.groupNotifyMentionsOnly, '$v');
            },
          ),
          _ToggleRow(
            label: tr('Only notify for messages from friends'),
            value: _friendsOnly,
            indent: true,
            onChanged: (v) {
              setState(() => _friendsOnly = v);
              kv.setString(StorageKeys.notifyFriendsOnly, '$v');
            },
          ),
        ],
      ),
    );
  }
}

/// One checkbox + label row (`.nm-h-78` / `.nm-h-80`): primary-accented box,
/// 8px gap, 13px text-dim label, whole row tappable. [indent] applies the
/// sub-option `margin-top: 6; margin-left: 20`.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.indent = false,
  });
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: EdgeInsets.only(top: indent ? 6 : 0, left: indent ? 20 : 0),
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 22×22 primary-accented checkbox (the shared `.modal` checkbox
            // pattern, app_dialog.dart:343-352).
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                activeColor: c.primary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label,
                  style: TextStyle(color: c.textDim, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A snapshotted notification row: the live [entry] plus its [viewed] state
/// frozen at open (then locally flipped as the row scrolls into view / by
/// "Mark all as read"). [key] anchors the built row's RenderBox for the
/// visibility measurement.
class _NotifRow {
  _NotifRow(this.entry, this.viewed);
  final NotificationEntry entry;
  final GlobalKey key = GlobalKey();
  bool viewed;
}

/// True when [s] is a bare 64-hex pubkey (drives the avatar + decorated author,
/// and PM routing).
bool _isPubkey(String s) => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s);

/// `.notifications-mark-read-btn`: borderless primary 12px, underline on hover.
class _MarkReadBtn extends StatefulWidget {
  const _MarkReadBtn({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_MarkReadBtn> createState() => _MarkReadBtnState();
}

class _MarkReadBtnState extends State<_MarkReadBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            tr('Mark all as read'),
            style: TextStyle(
              color: c.primary,
              fontSize: 12,
              decoration:
                  _hover ? TextDecoration.underline : TextDecoration.none,
              decorationColor: c.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationRow extends ConsumerStatefulWidget {
  const _NotificationRow({
    super.key,
    required this.entry,
    required this.viewed,
    required this.isLast,
    required this.onTap,
  });
  final NotificationEntry entry;
  final bool viewed;
  final bool isLast;
  final VoidCallback onTap;

  /// `Jun 23, 14:05` — `toLocaleString({month, day, hour, minute})`.
  String _formatTime(int ms) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, $hh:$mm';
  }

  /// The footer context label (`.notification-item-context`) from the entry
  /// (notifications.js:519-533). The PWA keys off `channelInfo` with
  /// `in #<geohash>` / `in <groupName>` for channel + group sources, so PREFER
  /// the entry's carried [NotificationEntry.contextLabel] when present (the
  /// controller passes `in #<geohash>` for a channel mention / `in <GroupName>`
  /// for a group). Otherwise fall back to the type-derived label. Call bodies
  /// already encode "Missed video/audio call …", so a missed call needs none.
  String? _contextLabel() {
    final carried = entry.contextLabel;
    if (carried != null && carried.isNotEmpty) return carried;
    switch (entry.type) {
      case 'call':
        return entry.body.startsWith('Missed') ? null : tr('Call');
      case 'pm':
        return tr('PM');
      case 'reaction':
        return tr('Reaction');
      case 'mention':
        return tr('Mention');
      case 'group':
        // Fallback when no group name was carried on the entry.
        return tr('Group');
      default:
        return null;
    }
  }

  /// Strips blockquoted (`>`-prefixed) lines and collapses whitespace, matching
  /// the PWA modal body (notifications.js:546-547) so only the new message text
  /// shows — not the quoted context a reply carries.
  String _displayBody() {
    final lines = entry.body
        .split('\n')
        .where((l) => !l.startsWith('>'))
        .join(' ');
    final collapsed = lines.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length > 200 ? collapsed.substring(0, 200) : collapsed;
  }

  @override
  ConsumerState<_NotificationRow> createState() => _NotificationRowState();
}

class _NotificationRowState extends ConsumerState<_NotificationRow> {
  /// `.notification-item:hover` — white@0.05 fill.
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final entry = widget.entry;
    // The avatar + decorated author render from the SENDER pubkey (the PWA modal
    // keys both off `n.senderPubkey || channelInfo.pubkey`, notifications.js:496)
    // — so a group message shows the sender's avatar + nym with `in <Group>` as
    // context, exactly like a PM/channel row. Fall back to the route only when no
    // sender pubkey was carried (older call entries).
    final sender = entry.senderPubkey ?? '';
    final route = entry.route ?? '';
    final pubkey = _isPubkey(sender)
        ? sender
        : (_isPubkey(route) ? route : '');
    final hasPubkey = pubkey.isNotEmpty;
    final label = widget._contextLabel();
    // Real profile picture for the sender avatar (Rule 4).
    final picture =
        hasPubkey ? ref.watch(usersProvider)[pubkey]?.profile?.picture : null;
    final body = widget._displayBody();

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          // Edge rules live OUTSIDE the rounded fill (BoxDecoration can't mix a
          // non-uniform Border with a radius): EVERY row keeps the 1px
          // white@0.04 bottom hairline (none on :last-child), and an unread
          // row ADDS the 2px primary left rule — `.notification-item-unread`
          // sets only border-left, so the separator stays.
          decoration: BoxDecoration(
            border: Border(
              left: widget.viewed
                  ? BorderSide.none
                  : BorderSide(color: c.primary, width: 2),
              bottom: widget.isLast
                  ? BorderSide.none
                  : BorderSide(color: Colors.white.withValues(alpha: 0.04)),
            ),
          ),
          child: AnimatedContainer(
            // transition: background var(--transition) = 0.25s cubic-bezier.
            duration: NymMotion.transition,
            curve: NymMotion.curve,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              // Hover fill white@0.05 — it outranks the unread cyan@6% wash
              // (`.notification-item:hover` is class+pseudo-class, more
              // specific than `.notification-item-unread`), so a hovered
              // unread row shows the white fill while keeping its left rule.
              // (The wash hex is fixed `0,255,255` — NOT the theme primary.)
              // No light-theme overrides exist for any of these.
              color: _hover
                  ? Colors.white.withValues(alpha: 0.05)
                  : (widget.viewed
                      ? Colors.transparent
                      : const Color.fromRGBO(0, 255, 255, 0.06)),
              // border-radius: var(--radius-xs) = 8 rounds the fill.
              borderRadius: NymRadius.rxs,
            ),
            // .notification-item-header: gap 6, align flex-start.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasPubkey) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: NymAvatar(seed: pubkey, size: 28, imageUrl: picture),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // .notification-item-author: `<base#suffix>` in primary,
                      // w600. The `.nym-bracket` `<…>` show in IRC mode only
                      // (the PWA CSS hides them under chat-bubbles), so gate on
                      // the message style to match the in-chat author.
                      _Author(
                        entry: entry,
                        pubkey: pubkey,
                        brackets: !ref.watch(
                            settingsProvider.select((s) => s.useBubbles)),
                      ),
                      const SizedBox(height: 2),
                      // .notification-item-body: text 13, line-height 1.4,
                      // 2-line clamp. Routed through [InlineEmojiText] so a
                      // `:shortcode:` in the previewed message / reaction
                      // renders as its custom-emoji image instead of literal
                      // text (`renderCustomEmojiInEscapedText`,
                      // notifications.js:554); image is the base
                      // `.custom-emoji` 1.75em of 13px (the InlineEmojiText
                      // default).
                      InlineEmojiText(
                        text: body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(color: c.text, fontSize: 13, height: 1.4),
                      ),
                      const SizedBox(height: 2),
                      // .notification-item-footer: context label + time (both
                      // 11px dim).
                      Row(
                        children: [
                          if (label != null) ...[
                            Text(label,
                                style:
                                    TextStyle(color: c.textDim, fontSize: 11)),
                            const SizedBox(width: 6),
                          ],
                          Text(widget._formatTime(entry.ts),
                              style: TextStyle(color: c.textDim, fontSize: 11)),
                        ],
                      ),
                    ],
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

/// `.notification-item-author` — the author wrapped in literal `<…>` brackets
/// (`.nym-bracket`, primary), with the decorated nym (base + dim `#suffix` +
/// badges) inside. For non-pubkey entries the bare title is bracketed.
class _Author extends StatelessWidget {
  const _Author(
      {required this.entry, required this.pubkey, required this.brackets});
  final NotificationEntry entry;

  /// The sender pubkey to decorate (empty → render the bare title).
  final String pubkey;

  /// Whether to wrap the nym in the IRC-style `<…>` `.nym-bracket` pair. The
  /// PWA emits the brackets but its `.nym-bracket` CSS hides them in chat-bubble
  /// mode, so they only show in IRC mode — mirror that by gating on the message
  /// style (bubble → no brackets, matching the in-chat author).
  final bool brackets;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final bracket =
        TextStyle(color: c.primary, fontSize: 13, fontWeight: FontWeight.w600);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (brackets) Text('<', style: bracket),
        Flexible(
          child: pubkey.isNotEmpty
              ? CallNym(
                  pubkey: pubkey,
                  nym: entry.title,
                  baseColor: c.primary,
                  baseStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  badgeSize: 12,
                )
              : Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: c.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
        ),
        if (brackets) Text('>', style: bracket),
      ],
    );
  }
}

/// 32×32 circular glass close chip with a danger hover (`.modal-close`).
class _CloseChip extends StatefulWidget {
  const _CloseChip({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CloseChip> createState() => _CloseChipState();
}

class _CloseChipState extends State<_CloseChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hover
                ? c.danger.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.05),
            border: Border.all(
              color: _hover ? c.danger.withValues(alpha: 0.3) : c.glassBorder,
            ),
          ),
          child: Text(
            '✕',
            style: TextStyle(
              color: _hover ? c.danger : c.textDim,
              fontSize: 16,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

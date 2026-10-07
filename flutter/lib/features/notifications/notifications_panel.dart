// Notification history modal: unread highlighting, "Mark all as read", and tap-to-open the source conversation.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../services/notification_service.dart';
import '../../services/platform/background_connectivity.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/chat/message_row.dart' show formatTime;
import '../calls/call_nym.dart';
import '../i18n/i18n.dart';
import 'notification_route_target.dart';
import 'notification_routing.dart';
import '../messages/format/message_content.dart';
import '../../widgets/common/nym_focusable.dart';
import '../messages/format/nym_format.dart' show NymFormat;
import '../chat_lock/chat_lock.dart' show ChatLockStrings;
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/nym_icons.dart';
import '../chat_lock/chat_lock_providers.dart';
import '../layout/layout_model.dart';
import '../settings/settings_screen.dart' show notificationSoundOptions;
import '../settings/settings_widgets.dart' show FormSelect;
import 'notifications_service.dart' show notificationsServiceProvider;
import '../toasts/event_toast_prefs.dart';
import '../../widgets/common/nym_tooltip.dart';
import '../identity/deleted_notice.dart' show dimNymSuffixes;
import '../search/unified_search_panel.dart' show nymSuffixStyle;

/// Opening doesn't clear the badge; rows are marked viewed once ≥60% visible, with unread state snapshotted before opening.
Future<void> showNotificationsPanel(BuildContext context) {
  final container = ProviderScope.containerOf(context);
  final all = container.read(notificationHistoryProvider).entries;
  // Filter at render time: drop entries older than 24h or from blocked senders, then sort newest first.
  final blocked = container.read(appStateProvider).blockedUsers;
  final cutoff24h = DateTime.now().millisecondsSinceEpoch - 24 * 60 * 60 * 1000;
  final entries = [
    for (final e in all)
      if (e.ts > cutoff24h && !blocked.contains(e.senderPubkey ?? '')) e,
  ]..sort((a, b) => b.ts.compareTo(a.ts));
  // Frozen unread state per entry, as a public type.
  final viewedAtOpen = [for (final e in entries) e.viewed];
  final isLight = context.nym.isLight;
  return showNymSheet<void>(
    context,
    (_) => NotificationsPanel(
      entries: entries,
      viewedAtOpen: viewedAtOpen,
    ),
    barrierColor: isLight
        ? const Color(0x73000000)
        : const Color(0xBF000000),
  );
}

class NotificationsPanel extends ConsumerStatefulWidget {
  const NotificationsPanel({
    super.key,
    required this.entries,
    required this.viewedAtOpen,
  });

  /// Entries snapshotted at open, newest first.
  final List<NotificationEntry> entries;

  /// `viewed` frozen at open, parallel to [entries], flipped locally as rows are seen.
  final List<bool> viewedAtOpen;

  @override
  ConsumerState<NotificationsPanel> createState() => _NotificationsPanelState();
}

class _NotificationsPanelState extends ConsumerState<NotificationsPanel> {
  late final List<_NotifRow> _rows = [
    for (var i = 0; i < widget.entries.length; i++)
      _NotifRow(widget.entries[i], widget.viewedAtOpen[i]),
  ];

  bool _prefsOpen = false;

  late bool _hasUnread = _rows.any((r) => !r.viewed);

  /// Scroll viewport that ≥60% visibility is measured against.
  final GlobalKey _bodyKey = GlobalKey();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Fetch kind 0 for every sender shown; boot-restored history never went through ingest.
    final senders = <String>{
      for (final e in widget.entries)
        if ((e.senderPubkey ?? '').isNotEmpty) e.senderPubkey!,
    };
    if (senders.isNotEmpty) {
      ref.read(nostrControllerProvider).ensureProfiles(senders);
    }
    // Mark rows ≥60% visible as viewed on scroll and after the first frame.
    _scroll.addListener(_markVisibleSeen);
    WidgetsBinding.instance.addPostFrameCallback((_) => _markVisibleSeen());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Marks unread rows ≥60% visible as viewed; the notifier handles persistence, badge and sync.
  void _markVisibleSeen() {
    if (!mounted) return;
    final bodyBox = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
    if (bodyBox == null || !bodyBox.attached || !bodyBox.hasSize) return;
    final bodyRect = bodyBox.localToGlobal(Offset.zero) & bodyBox.size;
    final seen = <NotificationEntry>[];
    for (final r in _rows) {
      if (r.viewed) continue;
      final ctx = r.key.currentContext;
      final box = ctx?.findRenderObject() as RenderBox?;
      // Unbuilt or off-viewport rows stay unread.
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

  /// Opens the source conversation for [entry] and closes the modal.
  void _openEntry(NotificationEntry entry) {
    // Same routing as an OS notification tap.
    openNotificationRoute(
      NotificationRoute(
        type: entry.type,
        route: entry.route ?? '',
        senderPubkey: entry.senderPubkey ?? '',
        // A thread reply's row opens that thread.
        threadRoot: entry.threadRoot ?? '',
      ),
      AppNotificationRouteTarget(
        controller: ref.read(nostrControllerProvider),
        appState: ref.read(appStateProvider.notifier),
        container: ProviderScope.containerOf(context, listen: false),
      ),
    );
    Navigator.of(context).maybePop();
  }

  String _groupTitle(String key, NotificationEntry entry) {
    final lock = ref.read(chatLockProvider);
    if (lock.notificationIsLocked(
        entry.type, entry.route ?? '', entry.senderPubkey ?? '')) {
      return lock.redact('', '', true).title;
    }
    final i = key.indexOf(':');
    final kind = i > 0 ? key.substring(0, i) : key;
    final id = i > 0 ? key.substring(i + 1) : '';
    final app = ref.read(appStateProvider);
    switch (kind) {
      case 'channel':
        return '#$id';
      case 'group':
        for (final g in app.groups) {
          if (g.id == id && g.name.isNotEmpty) return g.name;
        }
        return tr('Group');
      case 'pm':
        final nym = stripPubkeySuffix(app.users[id]?.nym ?? 'nym');
        return '$nym#${getPubkeySuffix(id)}';
    }
    return tr('Other');
  }

  TextStyle _groupTitleStyle(NymColors c) => TextStyle(
        color: c.textDim,
        fontSize: NymType.sm,
        fontWeight: FontWeight.w600,
      );

  List<Widget> _groupedRows(NymColors c) {
    final keys = [
      for (final r in _rows)
        notifGroupKey(
            r.entry.type, r.entry.route ?? '', r.entry.senderPubkey ?? ''),
    ];
    final out = <Widget>[];
    for (final g in groupNotifications(keys)) {
      final unread = g.items.where((i) => !_rows[i].viewed).length;
      out.add(Padding(
        key: ValueKey('notifGroup-${g.key}'),
        padding: EdgeInsets.only(
            top: out.isEmpty ? 0 : NymSpace.s3, bottom: NymSpace.s1),
        child: Row(
          children: [
            Flexible(
              child: Text.rich(
                g.key.startsWith('pm:')
                    ? dimNymSuffixes(
                        _groupTitle(g.key, _rows[g.items.first].entry),
                        nymSuffixStyle(_groupTitleStyle(c)))
                    : TextSpan(
                        text: _groupTitle(g.key, _rows[g.items.first].entry)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _groupTitleStyle(c),
              ),
            ),
            if (unread > 0) ...[
              const SizedBox(width: NymSpace.s2),
              Container(
                key: ValueKey('notifGroupUnread-${g.key}'),
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.primary,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text('$unread',
                    style: TextStyle(color: c.bg, fontSize: NymType.xs)),
              ),
            ],
          ],
        ),
      ));
      for (final i in g.items) {
        out.add(_NotificationRow(
          key: _rows[i].key,
          entry: _rows[i].entry,
          viewed: _rows[i].viewed,
          isLast: i == g.items.last,
          onTap: () => _openEntry(_rows[i].entry),
        ));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

    final body = Stack(
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(32, 32, 96, 10),
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
            if (_hasUnread)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, NymSpace.s2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [_MarkReadBtn(onTap: _markAllRead)],
                ),
              ),
            Flexible(
              child: CustomScrollView(
                key: _bodyKey,
                controller: _scroll,
                shrinkWrap: true,
                slivers: [
                  if (_prefsOpen)
                    const SliverToBoxAdapter(child: _NotifToggles()),
                  if (_rows.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 40, 20, 40),
                        child: Text(
                          tr('No notifications in the last 24 hours'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.textDim, fontSize: 14),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate(_groupedRows(c)),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        Positioned(
          top: 12,
          right: 14,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              NymTooltip(
                message: tr('Notification settings'),
                child: Semantics(
                  button: true,
                  expanded: _prefsOpen,
                  label: tr('Notification settings'),
                  child: InkWell(
                    key: const ValueKey('notifPrefsBtn'),
                    borderRadius: NymRadius.rxs,
                    onTap: () => setState(() => _prefsOpen = !_prefsOpen),
                    child: Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _prefsOpen
                            ? c.primaryA(0.1)
                            : Colors.transparent,
                        borderRadius: NymRadius.rxs,
                      ),
                      child: NymSvgIcon(NymIcons.settings,
                          size: 18,
                          color: _prefsOpen ? c.primary : c.textDim),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _CloseChip(
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
      ],
    );
    return nymSheetOr(
      context,
      body,
      (body) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: MediaQuery.of(context).size.width * 0.9,
            constraints: const BoxConstraints(maxWidth: 500, maxHeight: 640),
            decoration: BoxDecoration(
              color: c.bgSecondary,
              borderRadius: NymRadius.rxl,
              border: Border.all(color: c.glassBorder),
              boxShadow: c.isLight
                  ? const [
                      BoxShadow(
                        color: Color(0x1F000000),
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
            child: body,
          ),
        ),
      ),
    );
  }
}

/// Notification preference checkboxes; Enable is a reactive Settings field, the others KV-only flags read by the gates.
class _NotifToggles extends ConsumerStatefulWidget {
  const _NotifToggles();

  @override
  ConsumerState<_NotifToggles> createState() => _NotifTogglesState();
}

class _NotifTogglesState extends ConsumerState<_NotifToggles> {
  // Mirrored locally so the checkbox flips at once; 'true' means on, default off.
  late bool _mentionsOnly;
  late bool _friendsOnly;
  late bool _threadMentionsOnly;

  /// OS posting permission; Android 13+ and iOS drop everything without it. Null until checked.
  NotificationPermission? _osPermission;

  @override
  void initState() {
    super.initState();
    final kv = ref.read(keyValueStoreProvider);
    _mentionsOnly = kv.getString(StorageKeys.groupNotifyMentionsOnly) == 'true';
    _friendsOnly = kv.getString(StorageKeys.notifyFriendsOnly) == 'true';
    _threadMentionsOnly =
        kv.getString(StorageKeys.threadNotifyMentionsOnly) == 'true';
    _refreshOsPermission();
  }

  Future<void> _refreshOsPermission() async {
    final status = await NotificationService().permissionStatus();
    if (!mounted) return;
    setState(() => _osPermission = status);
  }

  /// Turning notifications on also asks the OS.
  Future<void> _requestOsPermission() async {
    final status = await NotificationService().ensurePermission();
    if (!mounted) return;
    setState(() => _osPermission = status);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final kv = ref.read(keyValueStoreProvider);
    // Watched so the box reflects it live.
    final enabled =
        ref.watch(settingsProvider.select((s) => s.notificationsEnabled));

    return Container(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ToggleRow(
            label: tr('Enable notifications'),
            value: enabled,
            onChanged: (v) {
              // Plain `update` so the bell and gate react live; doesn't fire cross-device sync.
              ref
                  .read(settingsProvider.notifier)
                  .update((s) => s.copyWith(notificationsEnabled: v));
              kv.setString(StorageKeys.notificationsEnabled, '$v');
              if (v) unawaited(_requestOsPermission());
            },
          ),
          _ToggleRow(
            label: tr('Only notify for mentions in group chats'),
            value: _mentionsOnly,
            indent: true,
            onChanged: (v) {
              setState(() => _mentionsOnly = v);
              kv.setString(StorageKeys.groupNotifyMentionsOnly, '$v');
            },
          ),
          // Thread-scoped twin of the group setting; off, replies in threads the user started also notify.
          _ToggleRow(
            label: tr('Only notify for mentions in threads'),
            value: _threadMentionsOnly,
            indent: true,
            onChanged: (v) {
              setState(() => _threadMentionsOnly = v);
              kv.setString(StorageKeys.threadNotifyMentionsOnly, '$v');
            },
          ),
          // Notice when the OS refuses to post despite the in-app setting.
          if (enabled && _osPermission == NotificationPermission.denied)
            _NotifyNotice(
              text: tr('Your system settings are blocking Nymchat '
                  'notifications, so none will appear.'),
              actionLabel: tr('Open settings'),
              onAction: () async {
                await openAppSettings();
                // Re-read the grant on return from system settings so the notice clears.
                await _refreshOsPermission();
              },
            )
          else if (enabled &&
              !ref.watch(settingsProvider
                  .select((s) => s.backgroundConnectivity)) &&
              BackgroundConnectivityService.isSupported)
            _NotifyNotice(
              text: tr('Notifications only arrive while Nymchat is running. '
                  'Turn on "Stay Connected in Background" in Settings → Data '
                  '& Backup to get them when it is closed.'),
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
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Text(tr('Notification Sound'),
                    style: TextStyle(color: c.textDim, fontSize: 13)),
                const SizedBox(width: 12),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: FormSelect<String>(
                      key: const Key('notifSoundSelect'),
                      value: ref.watch(settingsProvider.select((s) => s.sound)),
                      items: notificationSoundOptions(),
                      onChanged: (v) {
                        ref.read(settingsProvider.notifier).setSound(v);
                        final svc = ref.read(notificationsServiceProvider);
                        svc.resetSoundDedupe();
                        unawaited(svc.playSound(v).catchError((_) {}));
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const EventToastPrefsSection(),
        ],
      ),
    );
  }
}

/// Checkbox row, whole row tappable; [indent] for sub-options.
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
              child:
                  Text(label, style: TextStyle(color: c.textDim, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live [entry] plus [viewed] frozen at open; [key] anchors the row for visibility measurement.
class _NotifRow {
  _NotifRow(this.entry, this.viewed);
  final NotificationEntry entry;
  final GlobalKey key = GlobalKey();
  bool viewed;
}

/// True for a bare 64-hex pubkey.
bool _isPubkey(String s) => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s);

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

  /// `Jun 23, 2:05 PM`, with the clock half honoring `timeFormat`.
  String _formatTime(int ms, String timeFormat) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${months[d.month - 1]} ${d.day}, ${formatTime(d, timeFormat)}';
  }

  /// Prefer the entry's carried context label, else derive one from its type; call bodies need none.
  String? _contextLabel() {
    final carried = entry.contextLabel;
    if (carried == 'PM thread') return tr('Private message thread');
    if (carried != null && carried.isNotEmpty) return carried;
    switch (entry.type) {
      case 'call':
        return entry.body.startsWith('Missed') ? null : tr('Call');
      case 'pm':
        return tr('Private message');
      case 'reaction':
        return tr('Reaction');
      case 'mention':
        return tr('Mention');
      case 'group':
        // Fallback when no group name was carried.
        return tr('Group');
      default:
        return null;
    }
  }

  /// Strips quoted lines and collapses whitespace so only the new text shows.
  String _displayBody() {
    final lines = NymFormat.stripForPreview(entry.body)
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
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final entry = widget.entry;
    // Avatar and author come from the sender pubkey, falling back to the route for older entries.
    final sender = entry.senderPubkey ?? '';
    final route = entry.route ?? '';
    final locked = NotificationHistoryNotifier.lockedEntry?.call(entry) ?? false;
    final pubkey = locked
        ? ''
        : (_isPubkey(sender) ? sender : (_isPubkey(route) ? route : ''));
    final hasPubkey = pubkey.isNotEmpty;
    final label =
        locked ? tr(ChatLockStrings.lockedChats) : widget._contextLabel();
    final picture =
        hasPubkey ? ref.watch(usersProvider)[pubkey]?.profile?.picture : null;
    final body = locked ? tr(ChatLockStrings.notifBody) : widget._displayBody();

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          // Edge rules sit outside the rounded fill: every row has a bottom hairline, unread rows add a left rule.
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
            duration: NymMotion.transition,
            curve: NymMotion.curve,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              // Hover fill outranks the unread wash (fixed cyan, not theme primary), keeping the left rule.
              color: _hover
                  ? Colors.white.withValues(alpha: 0.05)
                  : (widget.viewed
                      ? Colors.transparent
                      : const Color.fromRGBO(0, 255, 255, 0.06)),
              borderRadius: NymRadius.rxs,
            ),
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
                      // Brackets show in IRC mode only.
                      _Author(
                        entry: locked
                            ? NotificationEntry(
                                type: entry.type,
                                title: tr(ChatLockStrings.notifTitle),
                                body: body,
                                ts: entry.ts,
                              )
                            : entry,
                        pubkey: pubkey,
                        brackets: !ref.watch(
                            settingsProvider.select((s) => s.useBubbles)),
                      ),
                      const SizedBox(height: 2),
                      // Custom `:shortcode:` emoji render as images; 2-line clamp.
                      InlineEmojiText(
                        text: body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(color: c.text, fontSize: 13, height: 1.4),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (label != null) ...[
                            Text(label,
                                style:
                                    TextStyle(color: c.textDim, fontSize: 11)),
                            const SizedBox(width: 6),
                          ],
                          Text(
                              widget._formatTime(entry.ts,
                                  ref.watch(settingsProvider
                                      .select((s) => s.timeFormat))),
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

/// Author in literal `<…>` brackets with the decorated nym; non-pubkey entries bracket the bare title.
class _Author extends ConsumerWidget {
  const _Author(
      {required this.entry, required this.pubkey, required this.brackets});
  final NotificationEntry entry;

  /// Sender pubkey to decorate; empty renders the bare title.
  final String pubkey;

  /// Brackets only in IRC mode, matching the in-chat author.
  final bool brackets;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final bracket =
        TextStyle(color: c.primary, fontSize: 13, fontWeight: FontWeight.w600);
    // Watch the live profile nym over the one frozen at record time, so rows repaint when the profile arrives.
    final liveNym = pubkey.isEmpty
        ? ''
        : (ref.watch(usersProvider.select((u) => u[pubkey]?.nym)) ?? '');
    final shownNym = pickDisplayNym(liveNym, entry.title);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (brackets) Text('<', style: bracket),
        Flexible(
          child: pubkey.isNotEmpty
              ? CallNym(
                  pubkey: pubkey,
                  nym: shownNym,
                  baseColor: c.primary,
                  baseStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  badgeSize: 12,
                )
              : Text(
                  shownNym,
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
    return NymFocusable(
      onActivate: widget.onTap,
      tooltip: tr('Close'),
      excludeChildSemantics: true,
      radius: const BorderRadius.all(Radius.circular(16)),
      child: MouseRegion(
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
            child: Icon(
              Icons.close,
              size: 16,
              color: _hover ? c.danger : c.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when notifications are on in-app but something outside stops them; [onAction] offers a fix.
class _NotifyNotice extends StatelessWidget {
  const _NotifyNotice({
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: c.warning),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => onAction!(),
              child: Text(
                actionLabel!,
                style: TextStyle(
                  fontSize: 12,
                  color: c.primary,
                  decoration: TextDecoration.underline,
                  decorationColor: c.primary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

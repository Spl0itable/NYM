import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/message_row.dart' show formatTime;
import '../../widgets/common/app_dialog.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/nym_icons.dart';
import '../../widgets/sidebar/conversation_avatar.dart';
import '../group_tools/group_tools_ui.dart';
import '../i18n/i18n.dart';
import '../notifications/notification_route_target.dart';
import '../notifications/notification_routing.dart';
import '../toasts/toast_center.dart';
import 'call_history.dart';
import 'call_history_providers.dart';
import 'call_nym.dart';
import 'call_providers.dart';

Future<void> showCallsScreen(BuildContext context, {bool links = false}) {
  final isLight = context.nym.isLight;
  return showNymSheet<void>(
    context,
    (_) => GtPanelShell(title: tr('Calls'), child: CallsBody(links: links)),
    barrierColor: isLight ? const Color(0x73000000) : const Color(0xBF000000),
  );
}

class CallsBody extends ConsumerStatefulWidget {
  const CallsBody({super.key, this.links = false});

  final bool links;

  @override
  ConsumerState<CallsBody> createState() => _CallsBodyState();
}

class _CallsBodyState extends ConsumerState<CallsBody> {
  late bool _links = widget.links;

  @override
  void initState() {
    super.initState();
    if (!_links) _markSeenSoon();
  }

  void _markSeenSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _links) return;
      if (ref.read(callHistoryMissedProvider) == 0) return;
      ref.read(callHistoryProvider.notifier).markSeen();
    });
  }

  void _select(bool links) {
    if (links == _links) return;
    setState(() => _links = links);
    if (!links) _markSeenSoon();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    Widget tab(String label, bool links, Key key) {
      final on = _links == links;
      return Expanded(
        child: Semantics(
          selected: on,
          button: true,
          child: InkWell(
            key: key,
            onTap: () => _select(links),
            child: Container(
              constraints: const BoxConstraints(minHeight: 40),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: on ? c.primary : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: on ? c.primary : c.textDim,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      key: const ValueKey('callsScreen'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.glassBorder)),
          ),
          child: Row(
            children: [
              tab(tr('Recent'), false, const ValueKey('callsTabRecent')),
              const SizedBox(width: 4),
              tab(tr('Call links'), true, const ValueKey('callsTabLinks')),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_links) const CallLinksBody() else const CallHistoryList(),
      ],
    );
  }
}

class CallHistoryList extends ConsumerWidget {
  const CallHistoryList({super.key});

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final ok = await showAppConfirm(
      context,
      tr("Remove every call from this list on all your devices? This can't be undone."),
      title: tr('Clear call history'),
      okLabel: tr('Clear'),
      danger: true,
    );
    if (ok) ref.read(callHistoryProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final items = ref.watch(callHistoryVisibleProvider);
    if (items.isEmpty) {
      return Padding(
        key: const ValueKey('callsEmpty'),
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr('No calls yet.'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: c.textDim, fontStyle: FontStyle.italic, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              tr('Calls you make and get show up here, on every device signed in with this identity.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textDim, fontSize: 12),
            ),
          ],
        ),
      );
    }
    return Column(
      key: const ValueKey('callsRecent'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: GtButton(
            key: const ValueKey('callsClear'),
            label: tr('Clear history'),
            danger: true,
            onTap: () => _clear(context, ref),
          ),
        ),
        const SizedBox(height: 4),
        for (final r in items) CallHistoryRow(record: r),
      ],
    );
  }
}

class CallHistoryRow extends ConsumerWidget {
  const CallHistoryRow({super.key, required this.record});

  final CallRecord record;

  static const List<String> _months = [
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

  static String when(int ms, String timeFormat) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${_months[d.month - 1]} ${d.day}, ${formatTime(d, timeFormat)}';
  }

  String get _route => record.group.isNotEmpty ? record.group : record.peer;

  bool _open(BuildContext context, WidgetRef ref) {
    final container = ProviderScope.containerOf(context, listen: false);
    final group = record.group.isNotEmpty
        ? ref.read(appStateProvider.notifier).groupById(record.group)
        : null;
    if (record.group.isNotEmpty && group == null) return false;
    return openNotificationRoute(
      NotificationRoute(type: 'call', route: _route, senderPubkey: ''),
      AppNotificationRouteTarget(
        controller: ref.read(nostrControllerProvider),
        appState: ref.read(appStateProvider.notifier),
        container: container,
      ),
    );
  }

  void _openChat(BuildContext context, WidgetRef ref) {
    final nav = Navigator.of(context);
    _open(context, ref);
    nav.maybePop();
  }

  bool _busy(WidgetRef ref) {
    final call = ref.read(currentCallStateProvider);
    return call.isActiveCall ||
        call.isIncoming ||
        ref.read(callServiceProvider).busy;
  }

  void _callBack(BuildContext context, WidgetRef ref) {
    if (_busy(ref)) {
      showToast(tr('Already in a call'));
      return;
    }
    final nav = Navigator.of(context);
    final ok = _open(context, ref);
    nav.maybePop();
    if (!ok) return;
    ref.read(callServiceProvider).callBack(record);
  }

  void _rejoin(BuildContext context, WidgetRef ref) {
    final svc = ref.read(callServiceProvider);
    if (record.group.isEmpty || !svc.canRejoinGroupCall(record.group)) return;
    final nav = Navigator.of(context);
    _open(context, ref);
    nav.maybePop();
    svc.rejoinGroupCall(record.group);
  }

  void _returnToCall(BuildContext context) {
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final users = ref.watch(usersProvider);
    final self = ref.watch(appStateProvider.select((s) => s.selfPubkey));
    final group = record.group.isNotEmpty
        ? ref.watch(appStateProvider
            .select((s) => s.groups.where((g) => g.id == record.group).firstOrNull))
        : null;
    final timeFormat = ref.watch(settingsProvider.select((s) => s.timeFormat));
    final call = ref.watch(currentCallStateProvider);
    final inCall = call.isActiveCall && call.callId == record.id;
    final rejoin = !inCall &&
        record.group.isNotEmpty &&
        call.rejoinCallId == record.id &&
        call.rejoinGroupId == record.group;
    final busy = call.isActiveCall || call.isIncoming;
    final live = inCall ? tr('In call') : (rejoin ? tr('Ongoing') : '');
    final label = switch (CallHistory.label(record)) {
      'missed' => tr('Missed'),
      'incoming' => tr('Incoming'),
      _ => tr('Outgoing'),
    };
    final dur = record.missed || live.isNotEmpty
        ? ''
        : CallHistory.duration(record.dur);
    final metaColor = record.missed ? c.danger : c.textDim;
    final kindColor = live.isNotEmpty ? c.primary : metaColor;
    final kindSvg = record.isVideo ? NymIcons.video : NymIcons.phone;

    final Widget avatar;
    final Widget name;
    if (record.group.isNotEmpty) {
      avatar = group != null
          ? GroupSidebarAvatar(
              group: group, selfPubkey: self, users: users, size: 36)
          : Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.primary.withValues(alpha: 0.1),
                border: Border.all(color: c.primary.withValues(alpha: 0.25)),
              ),
              child: NymSvgIcon(groupChatGlyphSvg, size: 18, color: c.primary),
            );
      name = Text(
        group != null && group.name.isNotEmpty ? group.name : tr('Group call'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: c.textBright, fontSize: 14, fontWeight: FontWeight.w600),
      );
    } else {
      avatar = NymAvatar(
        seed: record.peer,
        size: 36,
        imageUrl: users[record.peer]?.profile?.picture,
      );
      name = CallNym(
        key: ValueKey('callName-${record.id}'),
        pubkey: record.peer,
        nym: callPeerName(ref.watch(appStateProvider), record.peer),
        baseStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      );
    }

    final String actionLabel;
    final String actionGlyph;
    final VoidCallback onAction;
    if (inCall) {
      actionLabel = tr('Return to the call');
      actionGlyph = kindSvg;
      onAction = () => _returnToCall(context);
    } else if (rejoin) {
      actionLabel = tr('Rejoin the call');
      actionGlyph = NymIcons.phoneRejoin;
      onAction = () => _rejoin(context, ref);
    } else {
      actionLabel = tr('Call back');
      actionGlyph = kindSvg;
      onAction = () => _callBack(context, ref);
    }
    final blocked = busy && !inCall && !rejoin;

    final sep = Text('·', style: TextStyle(color: c.textDim, fontSize: 12));
    return Container(
      key: ValueKey('callRow-${record.id}'),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              key: ValueKey('callOpen-${record.id}'),
              onTap: () => _openChat(context, ref),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  children: [
                    SizedBox(width: 36, height: 36, child: Center(child: avatar)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          name,
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Semantics(
                                label: record.isVideo
                                    ? tr('Video call')
                                    : tr('Voice call'),
                                child: NymSvgIcon(kindSvg,
                                    size: 14, color: kindColor),
                              ),
                              const SizedBox(width: 5),
                              if (live.isNotEmpty)
                                Text(live,
                                    key: ValueKey('callLive-${record.id}'),
                                    style: TextStyle(
                                        color: c.primary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600))
                              else
                                Text(label,
                                    key: ValueKey('callDir-${record.id}'),
                                    style: TextStyle(
                                        color: metaColor, fontSize: 12)),
                              const SizedBox(width: 5),
                              sep,
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  when(record.at, timeFormat),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: c.textDim, fontSize: 12),
                                ),
                              ),
                              if (dur.isNotEmpty) ...[
                                const SizedBox(width: 5),
                                sep,
                                const SizedBox(width: 5),
                                Text(dur,
                                    key: ValueKey('callDur-${record.id}'),
                                    style: TextStyle(
                                        color: c.textDim, fontSize: 12)),
                              ],
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
          Semantics(
            container: true,
            button: true,
            enabled: !blocked,
            label: actionLabel,
            hint: blocked ? tr('Already in a call') : null,
            onTap: onAction,
            excludeSemantics: true,
            child: IconButton(
              key: ValueKey('callAction-${record.id}'),
              tooltip: blocked ? tr('Already in a call') : actionLabel,
              onPressed: onAction,
              icon: NymSvgIcon(actionGlyph,
                  size: 18,
                  color:
                      blocked ? c.primary.withValues(alpha: 0.45) : c.primary),
            ),
          ),
        ],
      ),
    );
  }
}

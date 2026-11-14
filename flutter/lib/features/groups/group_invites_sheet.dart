import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/common/nym_sheet.dart';
import '../group_tools/group_tools_ui.dart' show GtPanelShell;
import '../i18n/i18n.dart';
import '../messages/format/discord_timestamp.dart';
import 'group_invites.dart';
import 'group_invites_service.dart';
import 'group_logic.dart' show kMaxGroupMembers;

GlobalKey<NavigatorState>? _invitesNav;

void registerGroupInvitesPrompter(GlobalKey<NavigatorState> navKey) =>
    _invitesNav = navKey;

bool openGroupInvitesFromRoute(String gid) {
  final ctx = _invitesNav?.currentContext;
  if (ctx == null || !ctx.mounted) return false;
  unawaited(showGroupInvitesSheet(ctx, focus: gid));
  return true;
}

Future<void> showGroupInvitesSheet(BuildContext context, {String? focus}) {
  final isLight = context.nym.isLight;
  return showNymSheet<void>(
    context,
    (_) => GtPanelShell(
      title: tr('Group invites'),
      child: _GroupInvitesBody(focus: focus),
    ),
    barrierColor: isLight ? const Color(0x73000000) : const Color(0xBF000000),
  );
}

class GroupInvitesRow extends ConsumerWidget {
  const GroupInvitesRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(groupInvitesListProvider).length;
    if (n < 1) return const SizedBox.shrink();
    final c = context.nym;
    return Semantics(
      key: const ValueKey('group-invites-row'),
      button: true,
      label: tr('Group invites, {n} waiting', {'n': '$n'}),
      excludeSemantics: true,
      onTap: () => showGroupInvitesSheet(context),
      child: InkWell(
        onTap: () => showGroupInvitesSheet(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.group_add_outlined, size: 18, color: c.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr('Group invites'),
                    style: TextStyle(color: c.text, fontSize: 14),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.primary,
                    borderRadius: NymRadius.rxs,
                  ),
                  child: Text(
                    '$n',
                    style: TextStyle(
                      color: c.bg,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
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

class _GroupInvitesBody extends ConsumerStatefulWidget {
  const _GroupInvitesBody({this.focus});

  final String? focus;

  @override
  ConsumerState<_GroupInvitesBody> createState() => _GroupInvitesBodyState();
}

class _GroupInvitesBodyState extends ConsumerState<_GroupInvitesBody> {
  final FocusNode _close = FocusNode(debugLabel: 'group-invites-close');
  final Map<String, FocusNode> _accept = {};
  String? _decided;
  int _decidedAt = 0;
  bool _focusedInitial = false;

  @override
  void dispose() {
    _close.dispose();
    for (final f in _accept.values) {
      f.dispose();
    }
    super.dispose();
  }

  FocusNode _acceptNode(String gid) =>
      _accept.putIfAbsent(gid, () => FocusNode(debugLabel: 'accept-$gid'));

  void _afterDecision(String gid, int index) {
    setState(() {
      _decided = gid;
      _decidedAt = index;
    });
  }

  void _settleFocus(List<Map<String, dynamic>> items) {
    final gone = _decided;
    if (gone != null && !items.any((i) => i['gid'] == gone)) {
      _decided = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (items.isEmpty) {
          _close.requestFocus();
        } else {
          final i = _decidedAt < items.length ? _decidedAt : items.length - 1;
          _acceptNode('${items[i]['gid']}').requestFocus();
        }
      });
    }
    final f = widget.focus;
    if (!_focusedInitial && f != null && items.any((i) => i['gid'] == f)) {
      _focusedInitial = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final node = _accept[f];
        node?.requestFocus();
        final ctx = node?.context;
        if (ctx != null && ctx.mounted) Scrollable.ensureVisible(ctx);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final items = ref.watch(groupInvitesListProvider);
    final ctl = ref.read(nostrControllerProvider);
    _settleFocus(items);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              tr('No group invites.'),
              style: TextStyle(color: c.textDim, fontSize: 13),
            ),
          ),
        for (var i = 0; i < items.length; i++)
          _InviteCard(
            key: ValueKey('group-invite-card-${items[i]['gid']}'),
            item: items[i],
            name: ctl.groupInviteName(items[i]),
            nym: ctl.groupInviteNym(items[i]),
            acceptFocus: _acceptNode('${items[i]['gid']}'),
            onAccept: () async {
              final nav = Navigator.of(context);
              final ok = await ctl.acceptGroupInvite('${items[i]['gid']}');
              if (ok && mounted) {
                unawaited(nav.maybePop());
              }
            },
            onDecline: (block) {
              final gid = '${items[i]['gid']}';
              ctl.declineGroupInvite(gid, block: block);
              _afterDecision(gid, i);
            },
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const ValueKey('group-invites-close'),
            focusNode: _close,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(tr('Close')),
          ),
        ),
      ],
    );
  }
}

class _InviteCard extends StatefulWidget {
  const _InviteCard({
    super.key,
    required this.item,
    required this.name,
    required this.nym,
    required this.acceptFocus,
    required this.onAccept,
    required this.onDecline,
  });

  final Map<String, dynamic> item;
  final String name;
  final String nym;
  final FocusNode acceptFocus;
  final Future<void> Function() onAccept;
  final void Function(bool block) onDecline;

  @override
  State<_InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends State<_InviteCard> {
  final GlobalKey<PopupMenuButtonState<String>> _menu =
      GlobalKey<PopupMenuButtonState<String>>();

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final name = widget.name;
    final nym = widget.nym;
    final onAccept = widget.onAccept;
    final onDecline = widget.onDecline;
    final c = context.nym;
    final gid = '${item['gid']}';
    final at = GroupInvites.toInt(item['it']);
    final line = item['via'] == 'add'
        ? tr('{nym} added you', {'nym': nym})
        : tr('Invited by {nym}', {'nym': nym});
    final dim = TextStyle(color: c.textDim, fontSize: 12);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: NymRadius.rxs,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.groups_outlined, size: 28, color: c.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: c.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(line, style: dim),
                    Text(
                      tr('{n}/{max} members', {
                        'n': '${item['m'] ?? 0}',
                        'max': '$kMaxGroupMembers',
                      }),
                      style: dim,
                    ),
                    if (at > 0) Text(relativeTimestamp(at), style: dim),
                    if (item['left'] == true)
                      Text(tr('You left this group before.'), style: dim),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Semantics(
                key: ValueKey('group-invite-more-$gid'),
                button: true,
                label: tr('More options'),
                excludeSemantics: true,
                onTap: () => _menu.currentState?.showButtonMenu(),
                child: PopupMenuButton<String>(
                  key: _menu,
                  tooltip: tr('More options'),
                  icon: Icon(Icons.more_horiz, color: c.textDim),
                  onSelected: (_) => onDecline(true),
                  itemBuilder: (_) => [
                    PopupMenuItem<String>(
                      value: 'block',
                      child:
                          Text(tr('Decline and block {nym}', {'nym': nym})),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Semantics(
                button: true,
                label: tr('Decline invite to {group}', {'group': name}),
                excludeSemantics: true,
                onTap: () => onDecline(false),
                child: OutlinedButton(
                  key: ValueKey('group-invite-decline-$gid'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: () => onDecline(false),
                  child: Text(tr('Decline')),
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: tr('Accept invite to {group}', {'group': name}),
                excludeSemantics: true,
                onTap: onAccept,
                child: FilledButton(
                  key: ValueKey('group-invite-accept-$gid'),
                  focusNode: widget.acceptFocus,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: onAccept,
                  child: Text(tr('Accept')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../models/channel.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';

/// One entry in the channel `.quick-context-menu` (sidebar-sections.js
/// `_buildSidebarMenuItems`).
class ChannelMenuAction {
  const ChannelMenuAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.danger = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool danger;
}

/// Builds the long-press / right-click action list for a channel row, mirroring
/// the PWA's `_buildSidebarMenuItems` (Favorite/Hide/Block) and adding the
/// task's Share + Copy link affordances. `#nymchat` (the default channel)
/// returns no Block/Leave entries — the PWA gives it an empty menu — but Share
/// and Copy link still apply.
List<ChannelMenuAction> buildChannelMenuActions(
  BuildContext context,
  WidgetRef ref,
  ChannelEntry entry,
) {
  final controller = ref.read(nostrControllerProvider);
  final state = ref.read(appStateProvider);
  final key = entry.key;
  final isDefault = key == kDefaultChannel;
  final isPinned = state.pinnedChannels.contains(key);
  final isHidden = state.hiddenChannels.contains(key);

  // The PWA's `_buildSidebarMenuItems` returns an EMPTY menu for #nymchat
  // (sidebar-sections.js:175) and exactly Favorite / Hide / Block for any
  // other public channel — no Share/Copy/Leave (those belong to group/PM rows).
  if (isDefault) return const <ChannelMenuAction>[];

  return <ChannelMenuAction>[
    ChannelMenuAction(
      label: isPinned ? 'Unfavorite channel' : 'Favorite channel',
      icon: isPinned ? Icons.star : Icons.star_border,
      onSelected: () => controller.togglePin(key),
    ),
    ChannelMenuAction(
      label: isHidden ? 'Unhide channel' : 'Hide channel',
      icon: isHidden ? Icons.visibility : Icons.visibility_off_outlined,
      onSelected: () {
        if (isHidden) {
          ref.read(appStateProvider.notifier).unhideChannel(key);
        } else {
          controller.hideChannel(key);
        }
      },
    ),
    ChannelMenuAction(
      label: 'Block channel',
      icon: Icons.block,
      danger: true,
      onSelected: () => controller.blockChannel(key),
    ),
  ];
}

/// Shows the `.quick-context-menu` for [entry] at [globalPosition] (a small
/// popup of [ChannelMenuAction]s). Mirrors the PWA's floating action menu.
Future<void> showChannelContextMenu(
  BuildContext context,
  WidgetRef ref,
  ChannelEntry entry,
  Offset globalPosition,
) async {
  final actions = buildChannelMenuActions(context, ref, entry);
  if (actions.isEmpty) return;
  final c = context.nym;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return;

  final selected = await showMenu<ChannelMenuAction>(
    context: context,
    color: c.bgTertiary,
    elevation: 8,
    shape: RoundedRectangleBorder(
      borderRadius: NymRadius.rsm,
      side: BorderSide(color: c.glassBorder),
    ),
    position: RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final a in actions)
        PopupMenuItem<ChannelMenuAction>(
          value: a,
          height: 40,
          child: Row(
            children: [
              Icon(
                a.icon,
                size: 16,
                color: a.danger ? c.danger : c.textDim,
              ),
              const SizedBox(width: 12),
              Text(
                a.label,
                style: TextStyle(
                  color: a.danger ? c.danger : c.text,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
    ],
  );
  selected?.onSelected();
}

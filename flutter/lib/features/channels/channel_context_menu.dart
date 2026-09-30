import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../models/channel.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../../widgets/nym_icons.dart';
import '../../widgets/sidebar/pm_context_menu.dart';
import '../i18n/i18n.dart';
import '../settings/settings_screen.dart';

class ChannelMenuAction {
  const ChannelMenuAction({
    required this.label,
    required this.svg,
    required this.onSelected,
    this.danger = false,
  });
  final String label;

  final String svg;
  final VoidCallback onSelected;
  final bool danger;
}

/// Hold-menu actions for a channel row; `#nymchat` can't be favorited, hidden or blocked.
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

  if (isDefault) {
    return <ChannelMenuAction>[
      ChannelMenuAction(
        label: tr('Default landing channel'),
        svg: NymIcons.sidebarHome,
        onSelected: () => SettingsScreen.open(
          context,
          initialSearch: tr('Default Landing Channel'),
          focusLanding: true,
        ),
      ),
    ];
  }

  return <ChannelMenuAction>[
    ChannelMenuAction(
      label: isPinned ? tr('Unfavorite channel') : tr('Favorite channel'),
      svg: NymIcons.sidebarFavorite,
      onSelected: () => controller.togglePin(key),
    ),
    ChannelMenuAction(
      label: isHidden ? tr('Unhide channel') : tr('Hide channel'),
      svg: NymIcons.sidebarHide,
      onSelected: () {
        // Unhide must persist the store itself, or the channel comes back hidden on the next launch.
        if (isHidden) {
          ref.read(appStateProvider.notifier).unhideChannel(key);
          ref.read(keyValueStoreProvider).setString(
                StorageKeys.hiddenChannels,
                jsonEncode(ref.read(appStateProvider).hiddenChannels.toList()),
              );
        } else {
          controller.hideChannel(key);
        }
      },
    ),
    ChannelMenuAction(
      label: tr('Block channel'),
      svg: NymIcons.sidebarBlock,
      danger: true,
      onSelected: () async {
        if (!context.mounted) return;
        final ok = await showAppConfirm(
          context,
          tr('Block channel #{name}? Messages to it will be dropped.',
              {'name': key}),
          danger: true,
          okLabel: tr('Block'),
        );
        if (!ok || !context.mounted) return;
        controller.blockChannel(key);
        ref
            .read(appStateProvider.notifier)
            .addSystemMessage(tr('Blocked channel #{name}', {'name': key}));
      },
    ),
  ];
}

/// Opens the hold menu and reports whether it did, so the caller lets the release tap through otherwise.
bool maybeShowChannelContextMenu(
  BuildContext context,
  WidgetRef ref,
  ChannelEntry entry,
  Offset globalPosition,
) {
  final actions = buildChannelMenuActions(context, ref, entry);
  if (actions.isEmpty) return false;
  unawaited(showSidebarQuickMenu(context, globalPosition, [
    for (final a in actions)
      SidebarQuickMenuItem(
        label: a.label,
        svg: a.svg,
        danger: a.danger,
        onSelected: a.onSelected,
      ),
  ]));
  return true;
}

Future<void> showChannelContextMenu(
  BuildContext context,
  WidgetRef ref,
  ChannelEntry entry,
  Offset globalPosition,
) async {
  maybeShowChannelContextMenu(context, ref, entry, globalPosition);
}

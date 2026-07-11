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

/// One entry in the channel `.quick-context-menu` (sidebar-sections.js
/// `_buildSidebarMenuItems`).
class ChannelMenuAction {
  const ChannelMenuAction({
    required this.label,
    required this.svg,
    required this.onSelected,
    this.danger = false,
  });
  final String label;

  /// The leading glyph as a [NymIcons] SVG string.
  final String svg;
  final VoidCallback onSelected;
  final bool danger;
}

/// Builds the 500ms-hold action list for a channel row, mirroring the PWA's
/// `_buildSidebarMenuItems` channel branch (sidebar-sections.js:167-200):
/// Favorite/Unfavorite → Hide/Unhide → Block (danger). `#nymchat` (the default
/// channel) returns an EMPTY menu (sidebar-sections.js:175).
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

  if (isDefault) return const <ChannelMenuAction>[];

  return <ChannelMenuAction>[
    ChannelMenuAction(
      label: isPinned ? tr('Unfavorite channel') : tr('Favorite channel'),
      // PWA uses the same filled-star `favSvg` for both states.
      svg: NymIcons.sidebarFavorite,
      onSelected: () => controller.togglePin(key),
    ),
    ChannelMenuAction(
      label: isHidden ? tr('Unhide channel') : tr('Hide channel'),
      // PWA uses the same eye-off `hideSvg` for both states.
      svg: NymIcons.sidebarHide,
      onSelected: () {
        // `toggleHideChannel` (channels.js:790-806): toggle + ALWAYS persist
        // `nym_hidden_channels`. The hide path persists inside
        // `controller.hideChannel`; the unhide path must write the store
        // itself — the notifier alone leaves the key hidden on disk, so the
        // channel would come back hidden on the next launch.
        if (isHidden) {
          ref.read(appStateProvider.notifier).unhideChannel(key);
          ref.read(keyValueStoreProvider).setString(
                StorageKeys.hiddenChannels,
                jsonEncode(
                    ref.read(appStateProvider).hiddenChannels.toList()),
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
      // PWA (sidebar-sections.js:187-198): confirm with a danger dialog
      // first, then `blockChannel` + a `Blocked channel #name` system message
      // (the settings blocked-channels list is reactive here, so no explicit
      // `updateBlockedChannelsList` equivalent is needed).
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

/// Fires the row's 500ms-hold `.quick-context-menu`, reporting whether it
/// actually opened. `#nymchat` builds an empty item list and the PWA only sets
/// its click-suppressing `fired` flag when `items.length > 0`
/// (sidebar-sections.js:246-252) — so the caller lets the release-tap through
/// when this returns false.
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

/// Shows the channel `.quick-context-menu` for [entry] at [globalPosition],
/// reusing the shared sidebar overlay ([showSidebarQuickMenu]) so the channel
/// rows match the PM / group rows' look + entrance animation exactly. Mirrors
/// the PWA's floating action menu (`_showSidebarActionMenu`).
Future<void> showChannelContextMenu(
  BuildContext context,
  WidgetRef ref,
  ChannelEntry entry,
  Offset globalPosition,
) async {
  maybeShowChannelContextMenu(context, ref, entry, globalPosition);
}

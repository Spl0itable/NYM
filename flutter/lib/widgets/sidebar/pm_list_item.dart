import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/i18n/i18n.dart';
import '../../features/pms/pm_support_tokens.dart';
import '../../features/shop/cosmetics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/nym_avatar.dart';
import '../context_menu/profile_badges.dart';
import '../../features/chat_nav/chat_nav_providers.dart';
import '../../features/chat_nav/chat_nav_ui.dart';
import '../nym_icons.dart';
import 'pm_context_menu.dart';
import 'row_preview.dart';
import 'sidebar_chrome.dart';
import 'sidebar_row_gestures.dart';
import 'sidebar_row_menu_button.dart';
import 'unread_pill.dart';

/// A sidebar PM thread row; unlike the chat header it has no status dot.
class PMListItem extends ConsumerWidget {
  const PMListItem({
    super.key,
    required this.nym,
    required this.pubkey,
    required this.active,
    required this.unread,
    required this.textSize,
    required this.onTap,
    this.mesh = false,
  });

  final String nym;
  final String pubkey;
  final bool active;
  final int unread;
  final double textSize;
  final VoidCallback onTap;

  final bool mesh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final controller = ref.read(nostrControllerProvider);
    final appState = ref.watch(appStateProvider);
    final picture = appState.users[pubkey]?.profile?.picture;
    final isDev = controller.isVerifiedDeveloper(pubkey);
    final isBot = controller.isVerifiedBot(pubkey);
    final isFriend = appState.isFriend(pubkey);
    final isSupport = ref.watch(pmSupportPeersProvider).contains(pubkey);
    final base = pickDisplayNym(appState.users[pubkey]?.nym, nym);
    final suffix = getPubkeySuffix(pubkey);
    ref.watch(chatNavRevisionProvider);
    final pinned = !active &&
        ref.read(chatNavProvider).pinIndexOfChat('pm-${pubkey.toLowerCase()}') >= 0;

    final preview = pubkey.isEmpty
        ? (text: '', time: '', ts: 0)
        : sidebarRowPreview(ref, 'pm-${pubkey.toLowerCase()}', 'pm');
    final Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: SidebarRowGestures(
        onTap: onTap,
        onShowMenu: (pos) {
          if (pubkey.isEmpty) return false;
          showPmContextMenu(context, ref, pubkey, pos);
          return true;
        },
        builder: (context, hovered) => Stack(
          children: [
            Container(
              key: const ValueKey('sidebarRowBox'),
              constraints: const BoxConstraints(minHeight: kSidebarRowMinH),
              padding: EdgeInsets.fromLTRB(hovered ? 14 : 12, 6, 12, 6),
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
                  SizedBox(
                    key: const ValueKey('sidebarLead'),
                    width: kSidebarIcon,
                    height: kSidebarIcon,
                    child: NymAvatar(
                        seed: pubkey, size: kSidebarIcon, imageUrl: picture),
                  ),
                  const SizedBox(width: kSidebarGap),
                  Expanded(
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: base),
                          TextSpan(
                            text: '#$suffix',
                            style: TextStyle(
                              color: c.textDim.withValues(alpha: 0.7),
                              fontSize: textSize * 0.9,
                              fontWeight: FontWeight.w100,
                            ),
                          ),
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Consumer(
                              builder: (context, ref, _) => CosmeticNymBadges(
                                cosmetics:
                                    ref.watch(userCosmeticsProvider(pubkey)),
                                flairSize: 14,
                                supporterHeight: 14,
                              ),
                            ),
                          ),
                          if (isDev || isBot)
                            const WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                padding: EdgeInsets.only(left: 4),
                                child: VerifiedBadge(size: 14),
                              ),
                            ),
                          if (isFriend)
                            const WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                padding: EdgeInsets.only(left: 2),
                                child: FriendBadge(size: 14),
                              ),
                            ),
                          if (isSupport)
                            const WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                padding: EdgeInsets.only(left: 4),
                                child: _SupportLabel(),
                              ),
                            ),
                          if (mesh)
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: NymSvgIcon(NymIcons.bluetooth,
                                    size: 12, color: c.primary),
                              ),
                            ),
                        ],
                      ),
                      key: const ValueKey('sidebarName'),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textDim,
                        fontSize: textSize,
                        fontWeight: FontWeight.w400,
                        height: 1.3,
                      ),
                    ),
                    if (preview.text.isNotEmpty)
                      rowPreviewLine(context, preview.text, 'pm'),
                    ],
                    ),
                  ),
                  rowTimeLabel(context, preview.time),
                  if (pubkey.isNotEmpty)
                    ChatNavRowBadges(
                        storageKey: 'pm-${pubkey.toLowerCase()}'),
                  if (unread > 0) ...[
                    const SizedBox(width: 5),
                    SidebarUnreadPill(count: unread),
                  ],
                  if (pubkey.isNotEmpty)
                    const SizedBox(width: kSidebarMenuReserve),
                ],
              ),
            ),
            if (pubkey.isNotEmpty)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: SidebarRowMenuButton(
                  onShowMenu: (pos) {
                    showPmContextMenu(context, ref, pubkey, pos);
                    return true;
                  },
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
      storageKey: 'pm-${pubkey.toLowerCase()}',
      onHoldMenu: (pos) {
        if (pubkey.isEmpty) return false;
        showPmContextMenu(context, ref, pubkey, pos);
        return true;
      },
      child: row,
    );
  }
}

class _SupportLabel extends StatelessWidget {
  const _SupportLabel();

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.primaryA(0.10),
        border: Border.all(color: c.primaryA(0.25)),
        borderRadius: const BorderRadius.all(Radius.circular(20)),
      ),
      child: Text(
        tr('Nymbot support'),
        style: TextStyle(
          color: c.primary,
          fontSize: 9,
          fontWeight: FontWeight.w500,
          height: 1.2,
        ),
      ),
    );
  }
}


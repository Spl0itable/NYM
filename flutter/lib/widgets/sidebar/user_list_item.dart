import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/shop/cosmetics.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../chat/bitchat_user_color.dart';
import '../common/nym_avatar.dart';
import '../context_menu/context_menu_actions.dart';
import '../context_menu/context_menu_panel.dart';
import '../context_menu/profile_badges.dart';
import 'sidebar_chrome.dart';

/// One online-nyms row; long-press or right-click opens the profile context menu in profile-only mode.
class UserListItem extends ConsumerStatefulWidget {
  const UserListItem({
    super.key,
    required this.user,
    required this.textSize,
    required this.onTap,
  });

  final User user;
  final double textSize;
  final VoidCallback onTap;

  @override
  ConsumerState<UserListItem> createState() => _UserListItemState();
}

class _UserListItemState extends ConsumerState<UserListItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final user = widget.user;
    final textSize = widget.textSize;
    final controller = ref.read(nostrControllerProvider);
    final isDev = controller.isVerifiedDeveloper(user.pubkey);
    final isBot = controller.isVerifiedBot(user.pubkey);
    // Verified bots always show the online dot, as in the PWA.
    final status = user.effectiveStatus(isVerifiedBot: isBot);
    final app = ref.watch(appStateProvider);
    final isFriend = app.isFriend(user.pubkey);
    final bitchatTheme =
        ref.watch(settingsProvider.select((s) => s.theme)) ==
        NymThemeKey.bitchat;

    // The base nym is truncated to 20 chars before the `#suffix` and badges are appended.
    final base = stripPubkeySuffix(user.nym);
    final displayNym = base.length > 20 ? '${base.substring(0, 20)}...' : base;
    final suffix = getPubkeySuffix(user.pubkey);
    final hueColor = bitchatTheme && user.pubkey != app.selfPubkey
        ? bitchatUserColor(user.pubkey, isLight: c.isLight)
        : null;
    final nymColor = hueColor ?? (_hover ? c.text : c.textDim);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Semantics(
            label: user.nym,
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (d) =>
                showUserContextMenu(context, ref, user, d.globalPosition),
            onSecondaryTapDown: (d) =>
                showUserContextMenu(context, ref, user, d.globalPosition),
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: NymRadius.rxs,
              child: Container(
                key: const ValueKey('sidebarRowBox'),
                constraints: const BoxConstraints(minHeight: kSidebarRowMinH),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _hover
                      ? (c.isLight
                          ? Colors.black.withValues(alpha: 0.04)
                          : Colors.white.withValues(alpha: 0.04))
                      : null,
                  borderRadius: NymRadius.rxs,
                  border: Border.all(color: Colors.transparent, width: 1),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      key: const ValueKey('sidebarLead'),
                      width: kSidebarIcon,
                      height: kSidebarIcon,
                      child: _AvatarWithStatus(
                        seed: user.pubkey,
                        imageUrl: user.profile?.picture,
                        status: status,
                      ),
                    ),
                    const SizedBox(width: kSidebarGap),
                    Flexible(
                      child: Text.rich(
                        key: const ValueKey('sidebarName'),
                        TextSpan(
                          children: [
                            TextSpan(text: displayNym),
                            TextSpan(
                              text: '#$suffix',
                              style: TextStyle(
                                color: nymColor.withValues(alpha: 0.7),
                                fontSize: (textSize - 3) * 0.9,
                                fontWeight: FontWeight.w100,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: nymColor,
                          fontSize: textSize - 3,
                        ),
                      ),
                    ),
                    CosmeticNymBadges(
                      cosmetics: userCosmeticsFromUser(user),
                      flairSize: 13,
                      supporterHeight: 13,
                    ),
                    if (isDev || isBot) ...[
                      const SizedBox(width: 4),
                      const VerifiedBadge(size: 13),
                    ],
                    if (isFriend) ...[
                      const SizedBox(width: 2),
                      const FriendBadge(size: 13),
                    ],
                  ],
                ),
              ),
            ),
          )),
        ),
      ),
    );
  }
}

/// Opens the profile context menu for [user] in profile-only mode; the panel ignores [globalPosition].
void showUserContextMenu(
  BuildContext context,
  WidgetRef ref,
  User user,
  Offset globalPosition,
) {
  if (user.pubkey.isEmpty) return;
  final state = ref.read(appStateProvider);
  final isBot = ref.read(nostrControllerProvider).isVerifiedBot(user.pubkey);
  ContextMenuPanel.show(
    context,
    target: CtxTarget(
      pubkey: user.pubkey,
      nym: stripPubkeySuffix(user.nym),
      isSelf: user.pubkey == state.selfPubkey,
      isBot: isBot,
      profileOnly: true,
    ),
  );
}

class _AvatarWithStatus extends StatelessWidget {
  const _AvatarWithStatus({
    required this.seed,
    required this.imageUrl,
    required this.status,
  });

  final String seed;
  final String? imageUrl;
  final UserStatus status;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        NymAvatar(seed: seed, size: kSidebarIcon, imageUrl: imageUrl),
        if (status != UserStatus.hidden)
          Positioned(
            right: -1,
            bottom: -1,
            // CSS content-box puts the 2px ring outside the 8px dot; ring color is hardcoded, not `--bg`.
            child: Container(
              width: 12,
              height: 12,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: c.isLight
                    ? const Color(0xFFF5F5F2)
                    : const Color(0xFF0A0A0F),
                shape: BoxShape.circle,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: statusColor(status),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

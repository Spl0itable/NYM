import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/shop/cosmetics.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/nym_avatar.dart';
import '../context_menu/context_menu_actions.dart';
import '../context_menu/context_menu_panel.dart';
import '../context_menu/profile_badges.dart';

/// A single ONLINE NYMS row (`.user-item`, users.js `_createUserItem` /
/// `_fillUserLabel`): padding 6/12, margin 2/4, dim text at
/// `calc(--user-text-size - 3px)`, gap 8, a 20px avatar wrapped in
/// `.user-avatar-wrap` with the live `.user-status-dot` (8px, ring) overlaid on
/// its bottom-right, then `nym` + `#suffix` + flair + verified ✓ + friend badge.
///
/// A long-press (mobile) or secondary-tap / right-click (desktop) opens the
/// profile `#contextMenu` panel in profile-only mode (PM / Create Group Chat /
/// Gift Credits / Add-Remove Friend / Report / Block, plus the Copy Pubkey
/// header) — see [showUserContextMenu]. This mirrors the PWA, where a
/// nyms-list click/contextmenu calls `showContextMenu(..., profileOnly=true)`
/// (users.js:1513).
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
  // `@media (hover:hover) .user-item:hover` (styles-shell.css:571-575,
  // 584-590) — MouseRegion only reacts to mouse pointers, matching the media
  // query's hover-capable gate.
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final user = widget.user;
    final textSize = widget.textSize;
    final controller = ref.read(nostrControllerProvider);
    final isDev = controller.isVerifiedDeveloper(user.pubkey);
    final isBot = controller.isVerifiedBot(user.pubkey);
    // Verified bots always show the green online dot (`getEffectiveUserStatus`
    // returns 'online' for `verifiedBotPubkeys`, users.js:1112, feeding
    // `.user-status-dot status-${effectiveStatus}`, users.js:1540).
    final status = user.effectiveStatus(isVerifiedBot: isBot);
    final isFriend = ref.watch(appStateProvider).isFriend(user.pubkey);

    // `_fillUserLabel`: the base nym is hard-truncated to 20 chars + '...'
    // BEFORE the `#suffix` + badges are appended.
    final base = stripPubkeySuffix(user.nym);
    final displayNym = base.length > 20 ? '${base.substring(0, 20)}...' : base;
    final suffix = getPubkeySuffix(user.pubkey);
    // `:hover` brightens the nym span from `--text-dim` to `--text`.
    final nymColor = _hover ? c.text : c.textDim;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  // `:hover` fill white@0.04 (light: black@0.04,
                  // styles-themes-responsive.css:1251-1255), radius-xs.
                  color: _hover
                      ? (c.isLight
                          ? Colors.black.withValues(alpha: 0.04)
                          : Colors.white.withValues(alpha: 0.04))
                      : null,
                  borderRadius: NymRadius.rxs,
                ),
                child: Row(
                  children: [
                    // `.user-avatar-wrap` (20×20, position:relative) with the
                    // `.user-status-dot` overlaid bottom-right (-1px), 8px + a 2px
                    // #0a0a0f ring (content-box → 12px outer).
                    _AvatarWithStatus(
                      seed: user.pubkey,
                      imageUrl: user.profile?.picture,
                      status: status,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: displayNym),
                            TextSpan(
                              // `.nym-suffix`: opacity .7, 0.9em, weight 100.
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
                    // Verified developer / bot ✓ then friend badge
                    // (`_fillUserLabel`: `verified-badge` margin-left 4, friend after).
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
          ),
        ),
      ),
    );
  }
}

/// Opens the profile `#contextMenu` panel for [user] in profile-only mode at
/// [globalPosition] (the anchor is unused — the panel slides in from the right
/// like every other profile menu). Mirrors `call_overlay.showCallUserMenu` /
/// the PWA `showContextMenu(..., profileOnly=true)` for the nyms list. Self is
/// derived from `appState.selfPubkey`; bot status from the controller so the
/// "Create Group Chat" / "Gift Credits" gates match the PWA.
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

/// `.user-avatar-wrap` + `.user-status-dot`: a 20px [NymAvatar] with an 8px
/// status dot overlaid on the bottom-right corner (-1px), ringed by a 2px
/// `#0a0a0f` border (CSS `box-sizing:content-box` → 12px outer). Hidden for the
/// `hidden` status (`.user-avatar-wrap.no-status .user-status-dot`).
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
        NymAvatar(seed: seed, size: 20, imageUrl: imageUrl),
        if (status != UserStatus.hidden)
          Positioned(
            right: -1,
            bottom: -1,
            // CSS `box-sizing:content-box` puts the 2px ring OUTSIDE the 8px
            // dot → 12px border box positioned at bottom/right -1px. The ring
            // color is hardcoded `#0a0a0f` (NOT `--bg`), with a light-mode
            // override to `#f5f5f2` (styles-themes-responsive.css:1309-1311).
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

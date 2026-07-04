import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/shop/cosmetics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/nym_avatar.dart';
import '../context_menu/profile_badges.dart';
import 'pm_context_menu.dart';
import 'sidebar_row_gestures.dart';

/// A single PM thread row (`.pm-item`, pms.js `createPMConversation`). Same box
/// metrics as `.channel-item` with a 26px PM avatar (`margin-right:4px`), the
/// `.pm-name` (`{nym}<span class="nym-suffix">#suffix</span>{flair} {verified}
/// {friend}`) and an optional unread pill. The live sidebar PM row has **no**
/// status dot — that lives only in the chat-header avatar.
///
/// A 500ms press-and-hold (mouse primary button or touch — the PWA binds no
/// `contextmenu` handler) opens the `.quick-context-menu` (Block/Unblock user,
/// Leave conversation) at the press point — see [SidebarRowGestures] /
/// [showPmContextMenu].
class PMListItem extends ConsumerWidget {
  const PMListItem({
    super.key,
    required this.nym,
    required this.pubkey,
    required this.active,
    required this.unread,
    required this.textSize,
    required this.onTap,
  });

  final String nym;
  final String pubkey;
  final bool active;
  final int unread;
  final double textSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final controller = ref.read(nostrControllerProvider);
    final appState = ref.watch(appStateProvider);
    final picture = appState.users[pubkey]?.profile?.picture;
    final isDev = controller.isVerifiedDeveloper(pubkey);
    final isBot = controller.isVerifiedBot(pubkey);
    final isFriend = appState.isFriend(pubkey);
    final base = stripPubkeySuffix(nym);
    final suffix = getPubkeySuffix(pubkey);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      // The PWA's 500ms press-and-hold (mouse button 0 / touch, 10px move
      // cancel) opens the quick menu at the press point and swallows the
      // following tap; right-click deliberately does nothing
      // (sidebar-sections.js:239-303).
      child: SidebarRowGestures(
        onTap: onTap,
        onShowMenu: (pos) {
          if (pubkey.isEmpty) return false;
          showPmContextMenu(context, ref, pubkey, pos);
          return true;
        },
        // `.pm-item.active` shares `.channel-item.active`: primary fill/
        // border/glow + a 3px primary accent bar (NOT purple).
        builder: (context, hovered) => Stack(
            children: [
              Container(
                constraints: const BoxConstraints(minHeight: 36),
                // `:hover { padding-left: 14px }` (rest 12px).
                padding: EdgeInsets.fromLTRB(hovered ? 14 : 12, 9, 12, 9),
                decoration: BoxDecoration(
                  // `.pm-item.active` fill is primary@0.10 + a primary@0.05 glow
                  // (dark); `body.light-mode` neutralises it to black@0.06 with
                  // `box-shadow:none` (styles-themes-responsive.css:1139), the
                  // primary@0.20 border + primary accent bar stay. Hover
                  // (loses to active): white@0.06 dark / black@0.04 light
                  // (styles-shell.css:368-374 / styles-themes-responsive:1132).
                  color: active
                      ? (c.isLight
                          ? Colors.black.withValues(alpha: 0.06)
                          : c.primaryA(0.10))
                      : hovered
                          ? (c.isLight
                              ? Colors.black.withValues(alpha: 0.04)
                              : Colors.white.withValues(alpha: 0.06))
                          : Colors.transparent,
                  borderRadius: NymRadius.rxs,
                  border: Border.all(
                    color: active ? c.primaryA(0.20) : Colors.transparent,
                    width: 1,
                  ),
                  boxShadow: active && !c.isLight
                      ? [BoxShadow(color: c.primaryA(0.05), blurRadius: 12)]
                      : null,
                ),
                child: Row(
                  children: [
                    // `.avatar-pm`: 26px, margin-right 4 (no sidebar status dot).
                    NymAvatar(seed: pubkey, size: 26, imageUrl: picture),
                    const SizedBox(width: 4),
                    Expanded(
                      // `.pm-name { flex: 1 }`: color --text-dim, normal
                      // weight, with a dim `.nym-suffix` tail. `white-space:
                      // normal` + `word-break:break-word` (styles-shell.css:
                      // 418-429) — long names WRAP onto multiple lines, no
                      // ellipsis. Flair/verified/friend badges live INSIDE the
                      // name span in the PWA DOM (pms.js:2759), so they hug
                      // (and wrap with) the text instead of floating right.
                      child: Text.rich(
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
                                builder: (context, ref, _) =>
                                    CosmeticNymBadges(
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
                          ],
                        ),
                        style: TextStyle(
                          color: c.textDim,
                          fontSize: textSize,
                          fontWeight: FontWeight.w400,
                          height: 1.3,
                        ),
                      ),
                    ),
                    // `.channel-badges { margin-left: 5px; flex-shrink: 0 }` —
                    // the unread pill sits flush right, forming a column.
                    if (unread > 0) ...[
                      const SizedBox(width: 5),
                      _UnreadPill(count: unread),
                    ],
                  ],
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
  }
}

class _UnreadPill extends StatelessWidget {
  const _UnreadPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.unread-badge`: bg --primary, text --bg, pill, tabular-nums; caps at 99+.
    return Container(
      constraints: const BoxConstraints(minWidth: 30),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.primary,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: c.bg,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

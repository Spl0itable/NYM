import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/shop/cosmetics.dart';
import '../../models/user.dart';
import '../common/nym_avatar.dart';

/// A single ONLINE NYMS row (`.user-item`, docs/specs/02 §5.3): padding 6/12,
/// margin 2/4, dim text at `calc(--user-text-size - 3px)`, 20px avatar, 6px
/// status dot, gap 8.
class UserListItem extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final c = context.nym;
    final status = user.effectiveStatus();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: NymRadius.rxs,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(borderRadius: NymRadius.rxs),
            child: Row(
              children: [
                NymAvatar(seed: user.nym, size: 20),
                const SizedBox(width: 8),
                StatusDot(status: status, size: 6),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    user.nym,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textDim,
                      fontSize: (textSize - 3).clamp(9, double.infinity),
                    ),
                  ),
                ),
                CosmeticNymBadges(
                  cosmetics: userCosmeticsFromUser(user),
                  flairSize: 13,
                  supporterHeight: 13,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

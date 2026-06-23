import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/shop/cosmetics.dart';
import '../../models/user.dart';
import '../common/nym_avatar.dart';

/// A single PM thread row (`.pm-item`, docs/specs/02 §5.3). Same box metrics as
/// `.channel-item` with a 26px PM avatar and an optional unread pill.
class PMListItem extends StatelessWidget {
  const PMListItem({
    super.key,
    required this.nym,
    required this.pubkey,
    required this.active,
    required this.status,
    required this.unread,
    required this.textSize,
    required this.onTap,
  });

  final String nym;
  final String pubkey;
  final bool active;
  final UserStatus status;
  final int unread;
  final double textSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: NymRadius.rxs,
          // `.pm-item.active` shares `.channel-item.active`: primary fill/border/
          // glow + a 3px primary accent bar (NOT purple).
          child: Stack(
            children: [
              Container(
                constraints: const BoxConstraints(minHeight: 36),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: active ? c.primaryA(0.10) : Colors.transparent,
                  borderRadius: NymRadius.rxs,
                  border: Border.all(
                    color: active ? c.primaryA(0.20) : Colors.transparent,
                    width: 1,
                  ),
                  boxShadow: active
                      ? [BoxShadow(color: c.primaryA(0.05), blurRadius: 12)]
                      : null,
                ),
                child: Row(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        NymAvatar(seed: nym, size: 26),
                        Positioned(
                          right: -1,
                          bottom: -1,
                          child: Container(
                            padding: const EdgeInsets.all(1.5),
                            decoration: BoxDecoration(
                              color: c.bgSecondary,
                              shape: BoxShape.circle,
                            ),
                            child: StatusDot(status: status, size: 7),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      // `.pm-name`: color --text-dim, normal weight.
                      child: Text(
                        nym,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textDim,
                          fontSize: textSize,
                          fontWeight: FontWeight.w400,
                          height: 1.3,
                        ),
                      ),
                    ),
                    Consumer(
                      builder: (context, ref, _) => CosmeticNymBadges(
                        cosmetics: ref.watch(userCosmeticsProvider(pubkey)),
                        flairSize: 14,
                        supporterHeight: 14,
                      ),
                    ),
                    const Spacer(),
                    if (unread > 0) _UnreadPill(count: unread),
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
    // `.unread-badge`: bg --primary, text --bg, pill, tabular-nums.
    return Container(
      constraints: const BoxConstraints(minWidth: 30),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.primary,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
      ),
      child: Text(
        '$count',
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

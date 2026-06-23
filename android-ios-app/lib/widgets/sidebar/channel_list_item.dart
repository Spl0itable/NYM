import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/channels/channel_context_menu.dart';
import '../../models/channel.dart';

/// A single channel row in the sidebar PUBLIC CHANNELS list.
///
/// Mirrors `.channel-item` (docs/specs/02 §5.3): padding 9/12, margin 2/4,
/// radius rxs, min-height 36, 1px transparent border; active state gets a
/// primary@10 fill, primary@20 border, glow, and a 3px left accent bar. Unread
/// count renders as a pill badge; geohash/std channels carry a small badge.
///
/// A long-press (mobile) or secondary-tap / right-click (desktop) opens the
/// `.channel-context-menu` (Favorite/Hide/Share/Copy link/Block/Leave) — see
/// [showChannelContextMenu].
class ChannelListItem extends ConsumerWidget {
  const ChannelListItem({
    super.key,
    required this.entry,
    required this.active,
    required this.unread,
    required this.textSize,
    required this.onTap,
  });

  final ChannelEntry entry;
  final bool active;
  final int unread;
  final double textSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final name = '#${entry.isGeohash ? entry.geohash : entry.channel}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (d) =>
              showChannelContextMenu(context, ref, entry, d.globalPosition),
          onSecondaryTapDown: (d) =>
              showChannelContextMenu(context, ref, entry, d.globalPosition),
          child: InkWell(
            onTap: onTap,
            borderRadius: NymRadius.rxs,
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
                    // `.channel-item.active`: box-shadow 0 0 12px primary@5%.
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: c.primaryA(0.05),
                              blurRadius: 12,
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        // `.channel-name` inherits `--text` weight normal even
                        // when active (active changes bg/border/bar only).
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.text,
                            fontSize: textSize,
                            fontWeight: FontWeight.w400,
                            height: 1.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (entry.isGeohash)
                        _Badge(
                          label: 'geo',
                          color: c.warning,
                          bg: c.warning.withValues(alpha: 0.08),
                          border: c.warning.withValues(alpha: 0.20),
                        )
                      else
                        _Badge(
                          label: 'std',
                          color: c.blue,
                          bg: c.blue.withValues(alpha: 0.10),
                          border: c.blue.withValues(alpha: 0.25),
                        ),
                      if (unread > 0) ...[
                        const SizedBox(width: 6),
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
                            // `::before` accent bar glow 0 0 8px primary@40%.
                            boxShadow: [
                              BoxShadow(
                                color: c.primaryA(0.4),
                                blurRadius: 8,
                              ),
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
      ),
    );
  }
}

/// `.std-badge` / `.geohash-badge`: 9px pill.
class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.color,
    required this.bg,
    required this.border,
  });
  final String label;
  final Color color;
  final Color bg;
  final Color border;

  @override
  Widget build(BuildContext context) {
    // `.std-badge` / `.geohash-badge`: 9px weight 500, 1px border, pill.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: const BorderRadius.all(Radius.circular(20)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// `.unread-badge`: bg primary, text bg-color, pill, 10px weight 600.
class _UnreadPill extends StatelessWidget {
  const _UnreadPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.unread-badge`: min-width 3ch (content-box) + 7px h-padding ≈ 30px.
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

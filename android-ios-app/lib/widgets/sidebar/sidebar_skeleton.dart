import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

/// `.sidebar-skeleton` loading placeholder rows (index.html:503-506 /
/// 543-546 / 577-582, styles-chat.css:2076-2107): each sidebar list shows
/// shimmering skeleton rows until its first real item is inserted
/// (`_clearSidebarSkel`, channels.js:1414 / pms.js:2822), with an 8s safety
/// clear (`init.js:105`). Three variants:
///
/// * `.ssk-channel` — bar only; padding 9/12, margin 2/4, min-height 36;
/// * `.ssk-pm` — 26px avatar + bar, gap 10; padding 9/12, min-height 36;
/// * `.ssk-nym` — 20px avatar + bar, gap 8; padding 6/12.
///
/// Bars are 11px tall, radius 6, `--bg-tertiary` fill; the shimmer is a
/// `transparent → --glass-border → transparent` gradient sweeping
/// `translateX(-100% → 100%)` over 1.4s ease-in-out, repeating
/// (`sk-shimmer`). Bar widths are a percentage of the row content box
/// (`.ssk-w1..w4`: 42 / 58 / 70 / 50%).
class SidebarSkeletonRow extends StatelessWidget {
  /// `.ssk-channel`: bar only.
  const SidebarSkeletonRow.channel({super.key, required this.barWidthFactor})
      : avatarSize = 0,
        gap = 0,
        vPad = 9,
        minHeight = 36;

  /// `.ssk-pm`: 26px avatar + bar, gap 10.
  const SidebarSkeletonRow.pm({super.key, required this.barWidthFactor})
      : avatarSize = 26,
        gap = 10,
        vPad = 9,
        minHeight = 36;

  /// `.ssk-nym`: 20px avatar + bar, gap 8, padding 6/12, no min-height.
  const SidebarSkeletonRow.nym({super.key, required this.barWidthFactor})
      : avatarSize = 20,
        gap = 8,
        vPad = 6,
        minHeight = 0;

  /// `.ssk-w{n}` bar width as a fraction of the row's content box.
  final double barWidthFactor;
  final double avatarSize;
  final double gap;
  final double vPad;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // `margin: 2px 4px` (matches the real list rows).
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Container(
        constraints: BoxConstraints(minHeight: minHeight),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: vPad),
        // `display:flex; align-items:center`.
        alignment: Alignment.centerLeft,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // CSS `%` bar widths resolve against the row's content box (not
            // the remaining flex space next to the avatar).
            final barWidth = constraints.maxWidth * barWidthFactor;
            return Row(
              children: [
                if (avatarSize > 0) ...[
                  _ShimmerBox(
                    width: avatarSize,
                    height: avatarSize,
                    circle: true,
                  ),
                  SizedBox(width: gap),
                ],
                Flexible(
                  child: _ShimmerBox(width: barWidth, height: 11),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One `sk-bar` / `sk-avatar` box: `--bg-tertiary` fill (radius 6, or a
/// circle for avatars) with the `sk-shimmer` gradient sweep as an `::after`
/// overlay (1.4s ease-in-out infinite, `translateX(-100%) → 100%`).
class _ShimmerBox extends StatefulWidget {
  const _ShimmerBox({
    required this.width,
    required this.height,
    this.circle = false,
  });

  final double width;
  final double height;
  final bool circle;

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();
  late final Animation<double> _t =
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final radius = widget.circle
        ? BorderRadius.circular(widget.width)
        : BorderRadius.circular(6);
    return ClipRRect(
      borderRadius: radius,
      child: Container(
        width: widget.width,
        height: widget.height,
        color: c.bgTertiary,
        child: AnimatedBuilder(
          animation: _t,
          builder: (context, child) => FractionalTranslation(
            translation: Offset(-1 + 2 * _t.value, 0),
            child: child,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  c.glassBorder,
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

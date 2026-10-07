import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import 'sidebar_chrome.dart';

/// Shimmering `.sidebar-skeleton` placeholder rows shown until a sidebar list gets its first real item.
class SidebarSkeletonRow extends StatelessWidget {
  const SidebarSkeletonRow.channel({super.key, required this.barWidthFactor})
      : avatarSize = 0,
        gap = 0,
        vPad = 6,
        minHeight = kSidebarRowMinH;

  const SidebarSkeletonRow.pm({super.key, required this.barWidthFactor})
      : avatarSize = kSidebarIcon,
        gap = kSidebarGap,
        vPad = 6,
        minHeight = kSidebarRowMinH;

  const SidebarSkeletonRow.nym({super.key, required this.barWidthFactor})
      : avatarSize = kSidebarIcon,
        gap = kSidebarGap,
        vPad = 6,
        minHeight = kSidebarRowMinH;

  final double barWidthFactor;
  final double avatarSize;
  final double gap;
  final double vPad;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    // Keeps the per-frame shimmer repaint inside the row instead of the whole sidebar layer.
    return RepaintBoundary(
        child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Container(
        constraints: BoxConstraints(minHeight: minHeight),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: vPad),
        alignment: Alignment.centerLeft,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // CSS `%` widths resolve against the row's content box, not the flex space beside the avatar.
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
    ));
  }
}

/// One skeleton bar or avatar box with the shimmer sweep overlay.
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

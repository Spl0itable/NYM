import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

class SidebarUnreadPill extends StatelessWidget {
  const SidebarUnreadPill({super.key, required this.count});
  final int count;

  static Color fill(NymColors c) => c.isLight
      ? Colors.black.withValues(alpha: 0.08)
      : Colors.white.withValues(alpha: 0.12);

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      key: const ValueKey('unreadPill'),
      constraints: const BoxConstraints(minWidth: 30),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: fill(c),
        borderRadius: const BorderRadius.all(Radius.circular(20)),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: c.text,
          fontSize: NymType.xs,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

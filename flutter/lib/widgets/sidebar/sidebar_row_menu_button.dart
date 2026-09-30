import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

/// Always-visible overflow button opening the same menu as a sidebar row's long-press.
class SidebarRowMenuButton extends StatelessWidget {
  const SidebarRowMenuButton({
    super.key,
    required this.onShowMenu,
    this.semanticLabel = 'Conversation menu',
  });

  final bool Function(Offset globalPosition) onShowMenu;

  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          // Anchor to the button's center, not the pointer, so the menu lands in the same place.
          final box = context.findRenderObject() as RenderBox?;
          final anchor = (box != null && box.hasSize)
              ? box.localToGlobal(box.size.center(Offset.zero))
              : Offset.zero;
          onShowMenu(anchor);
        },
        child: SizedBox(
          width: 22,
          height: 22,
          child: Icon(
            Icons.more_vert,
            size: 16,
            color: c.textDim.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

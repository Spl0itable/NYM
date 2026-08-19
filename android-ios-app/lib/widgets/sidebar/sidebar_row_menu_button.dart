// The sidebar row's overflow menu, opening the same menu a 500ms press-and-hold
// opens ([SidebarRowGestures.onShowMenu]). Long-press is undiscoverable — people
// who never think to try it never learn the menu exists — so the affordance is
// always drawn rather than revealed on hover.
//
// It reports its OWN global position, so the menu anchors to the button the way
// the hold anchors to the press point.

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

/// `.row-menu-btn` (styles-shell.css): 22px hit box, dim at rest so it does not
/// compete with the unread pill beside it.
class SidebarRowMenuButton extends StatelessWidget {
  const SidebarRowMenuButton({
    super.key,
    required this.onShowMenu,
    this.semanticLabel = 'Conversation menu',
  });

  /// The row's own menu opener — same callback [SidebarRowGestures] fires on
  /// hold, so the two entry points can never drift apart.
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
          // Anchor to the button's own centre rather than the pointer, so the
          // menu lands in the same place however the row was tapped.
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

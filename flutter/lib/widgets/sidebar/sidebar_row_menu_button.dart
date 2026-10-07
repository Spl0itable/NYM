import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/i18n/i18n.dart';
import '../common/hit_slop.dart';
import '../common/nym_focusable.dart';
import '../nym_icons.dart';
import 'sidebar_chrome.dart';

/// Always-visible overflow button opening the same menu as a sidebar row's long-press.
class SidebarRowMenuButton extends StatefulWidget {
  const SidebarRowMenuButton({
    super.key,
    required this.onShowMenu,
    this.semanticLabel = 'Conversation menu',
  });

  final bool Function(Offset globalPosition) onShowMenu;

  final String semanticLabel;

  @override
  State<SidebarRowMenuButton> createState() => _SidebarRowMenuButtonState();
}

class _SidebarRowMenuButtonState extends State<SidebarRowMenuButton> {
  final _box = GlobalKey();
  bool _hover = false;
  bool _down = false;

  void _show() {
    final box = _box.currentContext?.findRenderObject() as RenderBox?;
    final anchor = (box != null && box.hasSize)
        ? box.localToGlobal(box.size.center(Offset.zero))
        : Offset.zero;
    widget.onShowMenu(anchor);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final lit = _hover || _down;
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: _show,
        child: SizedBox(
          key: const ValueKey('rowMenuHit'),
          width: sidebarRowMenuHit() + kSidebarMenuInset,
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: kSidebarMenuInset),
              child: HitSlop(
                child: NymFocusable(
                onActivate: _show,
                label: widget.semanticLabel,
                tooltip: tr('More'),
                radius: NymRadius.rxs,
                excludeChildSemantics: true,
                child: MouseRegion(
                  onEnter: (_) => setState(() => _hover = true),
                  onExit: (_) => setState(() => _hover = false),
                  child: Container(
                    key: const ValueKey('rowMenuBox'),
                    width: kSidebarMenuBox,
                    height: kSidebarMenuBox,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: lit ? c.primaryA(0.1) : null,
                      borderRadius: NymRadius.rxs,
                    ),
                    child: KeyedSubtree(
                      key: _box,
                      child: NymSvgIcon(
                        NymIcons.rowMenu,
                        key: const ValueKey('rowMenuGlyph'),
                        size: 16,
                        color: lit ? c.text : c.textDim.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

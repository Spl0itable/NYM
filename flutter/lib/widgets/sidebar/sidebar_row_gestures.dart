import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../common/nym_focusable.dart';

/// Sidebar row gestures: a 500ms hold opens the menu, 10px drift cancels, right-click does nothing.
class SidebarRowGestures extends StatefulWidget {
  const SidebarRowGestures({
    super.key,
    required this.onTap,
    required this.onShowMenu,
    required this.builder,
  });

  final VoidCallback onTap;

  /// Returns whether a menu opened; false (empty menu) lets the following tap still open the row.
  final bool Function(Offset globalPosition) onShowMenu;

  /// [hovered] reflects mouse hover only, like CSS `@media (hover: hover)`.
  final Widget Function(BuildContext context, bool hovered) builder;

  static const Duration holdDuration = Duration(milliseconds: 500);

  static const double moveThreshold = 10;

  static bool suppressMenu = false;

  @override
  State<SidebarRowGestures> createState() => _SidebarRowGesturesState();
}

class _SidebarRowGesturesState extends State<SidebarRowGestures> {
  Timer? _pressTimer;
  Offset _start = Offset.zero;
  bool _fired = false;
  bool _hovered = false;

  void _onPointerDown(PointerDownEvent e) {
    // Mouse presses count only for the primary button.
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) {
      return;
    }
    _start = e.position;
    _fired = false;
    _cancelTimer();
    _pressTimer = Timer(SidebarRowGestures.holdDuration, () {
      _pressTimer = null;
      if (!mounted || SidebarRowGestures.suppressMenu) return;
      _fired = widget.onShowMenu(_start);
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_pressTimer == null) return;
    if ((e.position.dx - _start.dx).abs() > SidebarRowGestures.moveThreshold ||
        (e.position.dy - _start.dy).abs() > SidebarRowGestures.moveThreshold) {
      _cancelTimer();
    }
  }

  void _cancelTimer([PointerEvent? _]) {
    _pressTimer?.cancel();
    _pressTimer = null;
  }

  void _onTap() {
    // Swallow the release's tap when the hold menu fired so the row doesn't also open.
    if (_fired) {
      _fired = false;
      return;
    }
    widget.onTap();
  }

  @override
  void dispose() {
    _pressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _cancelTimer,
        onPointerCancel: _cancelTimer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: _onTap,
          child: NymFocusable(
            onActivate: widget.onTap,
            child: widget.builder(context, _hovered),
          ),
        ),
      ),
    );
  }
}

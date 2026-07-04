import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Reproduces the PWA's sidebar row interaction contract
/// (`setupSidebarItemMenus`, sidebar-sections.js:239-303, plus the
/// `@media (hover:hover)` row hover styling, styles-shell.css:368-374):
///
/// * a 500ms press-and-hold — primary mouse button (`e.button === 0`) or
///   touch — opens the row's `.quick-context-menu` at the recorded
///   press-start coordinates (`startX`/`startY`);
/// * pointer drift beyond 10px in EITHER axis during the hold cancels it
///   (`MOVE_THRESHOLD = 10`);
/// * when the menu fired, the release's click is swallowed so the row doesn't
///   also open its conversation (the PWA's `fired` flag, consumed by the
///   capture-phase click handler);
/// * a right-click does NOTHING — the PWA binds no `contextmenu` handler on
///   the sidebar lists, so only the press-and-hold opens the menu;
/// * [builder] receives the live hover flag so rows can paint the explicit
///   `rgba(255,255,255,0.06)` (light: `rgba(0,0,0,0.04)`) hover fill and the
///   `padding-left: 12px → 14px` content shift.
class SidebarRowGestures extends StatefulWidget {
  const SidebarRowGestures({
    super.key,
    required this.onTap,
    required this.onShowMenu,
    required this.builder,
  });

  /// Row tap — opens the channel / PM / group.
  final VoidCallback onTap;

  /// Fired after the 500ms hold with the press-start global position. Returns
  /// whether a menu actually opened: an EMPTY item list (`#nymchat`) reports
  /// false so the following tap still opens the row — the PWA only sets its
  /// click-suppressing `fired` flag once `items.length > 0`
  /// (sidebar-sections.js:246-252).
  final bool Function(Offset globalPosition) onShowMenu;

  /// Builds the row content; [hovered] mirrors the CSS `:hover` state (mouse
  /// pointers only, like `@media (hover: hover)`).
  final Widget Function(BuildContext context, bool hovered) builder;

  /// The `pressTimer` delay (sidebar-sections.js:250).
  static const Duration holdDuration = Duration(milliseconds: 500);

  /// `MOVE_THRESHOLD` (sidebar-sections.js:240).
  static const double moveThreshold = 10;

  @override
  State<SidebarRowGestures> createState() => _SidebarRowGesturesState();
}

class _SidebarRowGesturesState extends State<SidebarRowGestures> {
  Timer? _pressTimer;
  Offset _start = Offset.zero;
  bool _fired = false;
  bool _hovered = false;

  void _onPointerDown(PointerDownEvent e) {
    // Mouse presses count only for the primary button
    // (`if (e.button !== 0) return`, sidebar-sections.js:265).
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) {
      return;
    }
    _start = e.position;
    _fired = false;
    _cancelTimer();
    _pressTimer = Timer(SidebarRowGestures.holdDuration, () {
      _pressTimer = null;
      if (!mounted) return;
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
    // Suppress the click that would open the conversation when the hold menu
    // fired (the PWA's capture-phase click handler, sidebar-sections.js:298).
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
          onTap: _onTap,
          child: widget.builder(context, _hovered),
        ),
      ),
    );
  }
}

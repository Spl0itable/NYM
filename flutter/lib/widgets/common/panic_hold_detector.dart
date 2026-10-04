import 'dart:async';

import 'package:flutter/widgets.dart';

class PanicHoldDetector extends StatefulWidget {
  const PanicHoldDetector({
    super.key,
    required this.child,
    required this.onHold,
    this.onTap,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback onHold;

  static const int holdMs = 2000;

  @override
  State<PanicHoldDetector> createState() => _PanicHoldDetectorState();
}

class _PanicHoldDetectorState extends State<PanicHoldDetector> {
  static const double _moveTolerance = 10;

  Timer? _timer;
  bool _fired = false;
  Offset _downAt = Offset.zero;

  void _start(PointerDownEvent e) {
    _fired = false;
    _downAt = e.position;
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: PanicHoldDetector.holdMs),
      () {
        _fired = true;
        widget.onHold();
      },
    );
  }

  void _cancel([PointerEvent? _]) {
    _timer?.cancel();
    _timer = null;
  }

  void _move(PointerMoveEvent e) {
    if (_timer == null) return;
    if ((e.position - _downAt).distance > _moveTolerance) _cancel();
  }

  void _up(PointerUpEvent _) {
    final held = _timer != null;
    _cancel();
    if (!_fired && held) widget.onTap?.call();
    _fired = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _start,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      child: widget.child,
    );
  }
}

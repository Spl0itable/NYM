import 'dart:math' as math;

import 'package:flutter/widgets.dart';

class ListSwipeBack extends StatefulWidget {
  const ListSwipeBack({
    super.key,
    required this.enabled,
    required this.distance,
    required this.velocity,
    required this.onDrag,
    required this.onBack,
    required this.child,
  });

  final bool enabled;
  final double distance;
  final double velocity;
  final ValueChanged<double?> onDrag;
  final VoidCallback onBack;
  final Widget child;

  @override
  State<ListSwipeBack> createState() => _ListSwipeBackState();
}

class _ListSwipeBackState extends State<ListSwipeBack> {
  Offset? _down;
  double _dx = 0;
  bool _live = false;

  bool _decided = false;
  final List<(Duration, double)> _trail = [];

  void _track(Duration? at) {
    if (at == null) return;
    _trail.add((at, _dx));
    while (_trail.length > 2 &&
        at - _trail.first.$1 > const Duration(milliseconds: 100)) {
      _trail.removeAt(0);
    }
  }

  double _trailVelocity() {
    if (_trail.length < 2) return 0;
    final a = _trail.first;
    final b = _trail.last;
    final ms = (b.$1 - a.$1).inMicroseconds / 1000;
    if (ms <= 0) return 0;
    return (b.$2 - a.$2) / ms * 1000;
  }

  void _start(DragStartDetails d) {
    _live = false;
    _decided = false;
    _dx = 0;
    _trail.clear();
    _down ??= d.globalPosition;
    _decide(d.globalPosition);
    if (_live) _track(d.sourceTimeStamp);
  }

  void _decide(Offset at) {
    final from = _down ?? at;
    final dx = at.dx - from.dx;
    final dy = (at.dy - from.dy).abs();
    if (dx == 0 && dy == 0) return;
    _decided = true;
    _live = dx < 0 && dx.abs() > dy * 1.5;
    if (!_live) return;
    _dx = dx;
    widget.onDrag(_dx);
  }

  void _update(DragUpdateDetails d) {
    if (!_decided) {
      _decide(d.globalPosition);
      if (_live) _track(d.sourceTimeStamp);
      return;
    }
    if (!_live) return;
    _dx = math.min(0, _dx + d.delta.dx);
    _track(d.sourceTimeStamp);
    widget.onDrag(_dx);
  }

  void _end(DragEndDetails d) {
    _down = null;
    _decided = false;
    if (!_live) return;
    _live = false;
    final v = math.min(d.primaryVelocity ?? 0, _trailVelocity());
    _trail.clear();
    final go = _dx < 0 && (-_dx >= widget.distance || -v >= widget.velocity);
    _dx = 0;
    widget.onDrag(null);
    if (go) widget.onBack();
  }

  void _cancel() {
    _down = null;
    if (!_live) return;
    _live = false;
    _dx = 0;
    widget.onDrag(null);
  }

  @override
  void didUpdateWidget(ListSwipeBack old) {
    super.didUpdateWidget(old);
    if (!widget.enabled && _live) {
      _live = false;
      _dx = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.enabled;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragDown: on ? (d) => _down = d.globalPosition : null,
      onHorizontalDragStart: on ? _start : null,
      onHorizontalDragUpdate: on ? _update : null,
      onHorizontalDragEnd: on ? _end : null,
      onHorizontalDragCancel: on ? _cancel : null,
      child: widget.child,
    );
  }
}

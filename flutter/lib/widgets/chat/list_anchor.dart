import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class AnchoredUnits {
  final Map<String, List<BuildContext>> _contexts = {};

  void _register(String id, BuildContext context) {
    final list = _contexts[id] ??= [];
    if (!list.contains(context)) list.add(context);
  }

  void _unregister(String id, BuildContext context) {
    final list = _contexts[id];
    if (list == null) return;
    list.remove(context);
    if (list.isEmpty) _contexts.remove(id);
  }

  BuildContext? contextOf(String id) {
    final list = _contexts[id];
    if (list == null) return null;
    for (final context in list) {
      if (!context.mounted) continue;
      final box = context.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) return context;
    }
    return null;
  }

  ScrollPosition? positionOf(String id) {
    final context = contextOf(id);
    return context == null ? null : Scrollable.maybeOf(context)?.position;
  }

  double? edgeOf(String id) {
    final context = contextOf(id);
    if (context == null) return null;
    final box = context.findRenderObject() as RenderBox;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport is! RenderViewport || !viewport.hasSize) return null;
    final height = viewport.size.height;
    if (height <= 0) return null;
    final reveal = viewport.getOffsetToReveal(box, 0).offset;
    if (!reveal.isFinite) return null;
    return (reveal - viewport.offset.pixels + viewport.anchor * height) /
        height;
  }
}

class AnchoredUnit extends StatefulWidget {
  const AnchoredUnit({
    super.key,
    required this.id,
    required this.units,
    required this.child,
  });

  final String id;
  final AnchoredUnits units;
  final Widget child;

  @override
  State<AnchoredUnit> createState() => _AnchoredUnitState();
}

class _AnchoredUnitState extends State<AnchoredUnit> {
  @override
  void initState() {
    super.initState();
    widget.units._register(widget.id, context);
  }

  @override
  void activate() {
    super.activate();
    widget.units._register(widget.id, context);
  }

  @override
  void didUpdateWidget(AnchoredUnit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id ||
        !identical(oldWidget.units, widget.units)) {
      oldWidget.units._unregister(oldWidget.id, context);
      widget.units._register(widget.id, context);
    }
  }

  @override
  void deactivate() {
    widget.units._unregister(widget.id, context);
    super.deactivate();
  }

  @override
  void dispose() {
    widget.units._unregister(widget.id, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class ListAnchorKeeper {
  ListAnchorKeeper({required this.controller, required this.units});

  final ItemScrollController controller;
  final AnchoredUnits units;

  int? target;
  String? anchorUnit;
  bool pending = false;
  bool _retargeting = false;

  bool get retargeting => _retargeting;

  void reset({int? target, String? anchorUnit}) {
    this.target = target;
    this.anchorUnit = anchorUnit;
    pending = false;
  }

  void keep({
    required Iterable<ItemPosition> positions,
    required String? Function(int index) unitAt,
    required int? Function(String unit) indexOf,
    required double viewportHeight,
    required double bottomInset,
    required bool follow,
  }) {
    if (!controller.isAttached || viewportHeight <= 0) return;
    final sorted = positions.toList()
      ..sort((a, b) => b.index.compareTo(a.index));
    if (sorted.isEmpty) return;
    if (follow) {
      if (target == 0) return;
      final newest = unitAt(0);
      final edge = newest == null ? null : units.edgeOf(newest);
      if (newest != null && edge != null) {
        _jump(0, edge - bottomInset / viewportHeight, newest);
        return;
      }
    }
    final candidates = <String>[];
    for (final p in sorted) {
      final unit = unitAt(p.index);
      if (unit != null && !candidates.contains(unit)) candidates.add(unit);
    }
    final current = anchorUnit;
    if (current != null && candidates.remove(current)) {
      candidates.insert(0, current);
    }
    for (final unit in candidates) {
      final index = indexOf(unit);
      if (index == null) continue;
      if (unit == anchorUnit && index == target) return;
      final edge = units.edgeOf(unit);
      if (edge == null) continue;
      _jump(
          index, edge - (index == 0 ? bottomInset / viewportHeight : 0), unit);
      return;
    }
  }

  bool _dragging = false;
  bool _scrolling = false;
  double _velocity = 0;
  double? _lastPixels;
  Duration? _lastAt;

  void observe(ScrollNotification n) {
    if (_retargeting) return;
    if (n is ScrollStartNotification) {
      _scrolling = true;
      _dragging = n.dragDetails != null;
      _velocity = 0;
      _lastPixels = null;
    } else if (n is ScrollUpdateNotification) {
      _dragging = n.dragDetails != null;
      final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
      final last = _lastPixels;
      final lastAt = _lastAt;
      if (last != null && lastAt != null && now > lastAt) {
        _velocity = (n.metrics.pixels - last) *
            Duration.microsecondsPerSecond /
            (now - lastAt).inMicroseconds;
        _lastPixels = n.metrics.pixels;
        _lastAt = now;
      } else if (last == null || lastAt == null) {
        _lastPixels = n.metrics.pixels;
        _lastAt = now;
      }
    } else if (n is ScrollEndNotification) {
      _scrolling = false;
      _dragging = false;
      _velocity = 0;
      _lastPixels = null;
    }
  }

  void _jump(int index, double alignment, String unit) {
    if (_dragging) {
      pending = true;
      return;
    }
    final position = units.positionOf(unit);
    final velocity = _scrolling ? _velocity : 0.0;
    _retargeting = true;
    try {
      controller.jumpTo(index: index, alignment: alignment);
    } finally {
      _retargeting = false;
    }
    _scrolling = false;
    _velocity = 0;
    _lastPixels = null;
    target = index;
    anchorUnit = unit;
    pending = false;
    if (velocity != 0 &&
        position != null &&
        position is ScrollActivityDelegate) {
      final delegate = position as ScrollActivityDelegate;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (controller.isAttached && position.hasPixels) {
          delegate.goBallistic(velocity);
        }
      });
    }
  }
}

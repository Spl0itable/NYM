import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../models/message.dart';

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

  double? get anchor {
    for (final list in _contexts.values) {
      for (final context in list) {
        if (!context.mounted) continue;
        final box = context.findRenderObject();
        if (box is! RenderBox || !box.attached) continue;
        final viewport = RenderAbstractViewport.maybeOf(box);
        if (viewport is RenderViewport) return viewport.anchor;
      }
    }
    return null;
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

class BottomFollow {
  bool armed = false;
  double Function()? anchor;
  double? Function()? hold;
}

class ReaderAway {
  ReaderAway() {
    HardwareKeyboard.instance
      ..removeHandler(_onKey)
      ..addHandler(_onKey);
  }

  static const double bottom = 2;
  static const Duration _keyWindow = Duration(seconds: 1);
  static final Set<LogicalKeyboardKey> _keys = {
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.space,
  };
  static final Stopwatch _clock = Stopwatch()..start();
  static Duration? _keyAt;

  static bool _onKey(KeyEvent e) {
    if (e is KeyUpEvent || !_keys.contains(e.logicalKey)) return false;
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx != null &&
        (ctx.widget is EditableText ||
            ctx.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return false;
    }
    _keyAt = _clock.elapsed;
    return false;
  }

  static bool get _keyed {
    final at = _keyAt;
    return at != null && _clock.elapsed - at < _keyWindow;
  }

  bool away = false;
  bool _input = false;
  int _jumps = 0;

  void keyed() => _input = true;

  void reset() {
    away = false;
    _input = false;
  }

  void sync(int jumps) {
    if (jumps == _jumps) return;
    _jumps = jumps;
    reset();
  }

  static double gapOf(ScrollMetrics m) =>
      m.axisDirection == AxisDirection.up ||
              m.axisDirection == AxisDirection.left
          ? m.pixels - m.minScrollExtent
          : m.maxScrollExtent - m.pixels;

  void observe(ScrollNotification n) {
    if (n.depth != 0) return;
    if (n is UserScrollNotification) {
      if (n.direction != ScrollDirection.idle) _input = true;
    } else if (n is ScrollUpdateNotification) {
      if (_input || n.dragDetails != null || _keyed) _note(n.metrics);
    } else if (n is ScrollEndNotification) {
      if (_input || _keyed) _note(n.metrics);
      _input = false;
    }
  }

  void _note(ScrollMetrics m) {
    if (!m.hasPixels || !m.hasContentDimensions) return;
    away = gapOf(m) >= bottom;
  }
}

class OwnSend {
  Message? _seen;

  void prime(List<Message> messages) {
    if (messages.isNotEmpty) _seen ??= messages.last;
  }

  bool arrived(List<Message> messages) {
    final seen = _seen;
    _seen = messages.isEmpty ? null : messages.last;
    if (seen == null) return false;
    var mine = false;
    for (var i = messages.length - 1;
        i >= 0 && i >= messages.length - 64;
        i--) {
      final m = messages[i];
      if (identical(m, seen)) return mine;
      if (m.isOwn && !m.isPM && !m.isGroup && !m.isHistorical) mine = true;
    }
    return false;
  }
}

class RowHold {
  RowHold({required this.units, required this.away});

  final AnchoredUnits units;
  final bool Function() away;
  String? _unit;
  double? _at;

  double? _offsetOf(String id) {
    for (final context in units._contexts[id] ?? const <BuildContext>[]) {
      if (!context.mounted) continue;
      RenderObject? child = context.findRenderObject();
      while (child != null && child.attached) {
        final parent = child.parent;
        if (parent is RenderSliverMultiBoxAdaptor) {
          final data = child.parentData;
          if (data is SliverMultiBoxAdaptorParentData &&
              data.layoutOffset != null) {
            return data.layoutOffset;
          }
          break;
        }
        child = parent;
      }
    }
    return null;
  }

  void pick() {
    _unit = null;
    _at = null;
    if (!away()) return;
    String? best;
    double? bestEdge;
    for (final id in units._contexts.keys) {
      final edge = units.edgeOf(id);
      if (edge == null || edge < 0 || edge >= 1) continue;
      if (bestEdge == null || edge < bestEdge) {
        best = id;
        bestEdge = edge;
      }
    }
    _unit = best;
    _at = best == null ? null : _offsetOf(best);
  }

  double? delta() {
    final unit = _unit;
    if (unit == null || !away()) return null;
    final now = _offsetOf(unit);
    final was = _at;
    _at = now;
    if (now == null) _unit = null;
    if (now == null || was == null) return null;
    return now - was;
  }
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

  bool get flinging => _scrolling && !_dragging;

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
    int newestIndex = 0,
    int newestTo = 0,
    String? newestUnitTo,
    bool stable = false,
  }) {
    if (!controller.isAttached || viewportHeight <= 0) return;
    final sorted = positions.toList()
      ..sort((a, b) => b.index.compareTo(a.index));
    if (sorted.isEmpty) return;
    if (follow) {
      if (target == newestTo &&
          (newestUnitTo == null || anchorUnit == newestUnitTo)) {
        return;
      }
      final newest = unitAt(newestIndex);
      final edge = newest == null ? null : units.edgeOf(newest);
      if (newest != null && edge != null) {
        _jump(newestTo, edge - (newestTo == 0 ? bottomInset / viewportHeight : 0),
            newestUnitTo ?? newest);
        return;
      }
    }
    if (stable) return;
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
      } else {
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
    final fling = velocity != 0 && position is ScrollActivityDelegate;
    _retargeting = true;
    try {
      controller.jumpTo(index: index, alignment: alignment);
      if (fling && position!.hasPixels) {
        (position as ScrollActivityDelegate).goBallistic(velocity);
      }
    } finally {
      _retargeting = false;
    }
    _scrolling = fling;
    _velocity = fling ? velocity : 0;
    _lastPixels = null;
    target = index;
    anchorUnit = unit;
    pending = false;
  }
}

class KeepReadingPhysics extends ScrollPhysics {
  const KeepReadingPhysics({super.parent, this.follow});

  final BottomFollow? follow;

  @override
  KeepReadingPhysics applyTo(ScrollPhysics? ancestor) =>
      KeepReadingPhysics(parent: buildParent(ancestor), follow: follow);

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final up = newPosition.axisDirection == AxisDirection.up;
    final still = newPosition.pixels == oldPosition.pixels;
    final away = oldPosition.pixels - oldPosition.minScrollExtent;
    final gate = follow;
    final held = gate?.hold?.call();
    if (held != null && held != 0) {
      return (newPosition.pixels + held).clamp(
          newPosition.minScrollExtent, newPosition.maxScrollExtent);
    }
    if (up &&
        still &&
        gate != null &&
        gate.armed &&
        newPosition.minScrollExtent < oldPosition.minScrollExtent) {
      gate.armed = false;
      return (newPosition.minScrollExtent + (away > 0 ? away : 0.0)).clamp(
          newPosition.minScrollExtent, newPosition.maxScrollExtent);
    }
    final shift = oldPosition.viewportDimension - newPosition.viewportDimension;
    if (shift != 0 && up && oldPosition.extentBefore > 1) {
      final anchor = gate?.anchor?.call() ?? 0.0;
      return (oldPosition.pixels + shift * (1 - anchor)).clamp(
          newPosition.minScrollExtent, newPosition.maxScrollExtent);
    }
    if (shift != 0 && up && still && away <= 1) {
      return newPosition.minScrollExtent;
    }
    if (up &&
        still &&
        away.abs() <= 1 &&
        newPosition.minScrollExtent < oldPosition.minScrollExtent) {
      return (newPosition.minScrollExtent + away).clamp(
          newPosition.minScrollExtent, newPosition.maxScrollExtent);
    }
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}

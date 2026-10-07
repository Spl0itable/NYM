import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

const double kMinTouchTarget = 44;

bool touchPlatform() =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;

class HitSlop extends SingleChildRenderObjectWidget {
  const HitSlop({
    super.key,
    this.minSize = kMinTouchTarget,
    this.mergeSemantics = true,
    super.child,
  });

  final double minSize;
  final bool mergeSemantics;

  @override
  RenderHitSlop createRenderObject(BuildContext context) => RenderHitSlop(
        minSize: touchPlatform() ? minSize : 0,
        mergeSemantics: mergeSemantics,
      );

  @override
  void updateRenderObject(BuildContext context, RenderHitSlop renderObject) {
    renderObject
      ..minSize = touchPlatform() ? minSize : 0
      ..mergeSemantics = mergeSemantics;
  }
}

class RenderHitSlop extends RenderProxyBox {
  RenderHitSlop({required double minSize, required bool mergeSemantics}) {
    _minSize = minSize;
    _mergeSemantics = mergeSemantics;
  }

  late double _minSize;
  double get minSize => _minSize;
  set minSize(double v) {
    if (v == _minSize) return;
    _minSize = v;
    markNeedsSemanticsUpdate();
  }

  static final Set<RenderHitSlop> live = <RenderHitSlop>{};

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    live.add(this);
  }

  @override
  void detach() {
    live.remove(this);
    super.detach();
  }

  late bool _mergeSemantics;
  bool get mergeSemantics => _mergeSemantics;
  set mergeSemantics(bool v) {
    if (v == _mergeSemantics) return;
    _mergeSemantics = v;
    markNeedsSemanticsUpdate();
  }

  Rect get slopRect {
    final dx = math.max(0.0, (_minSize - size.width) / 2);
    final dy = math.max(0.0, (_minSize - size.height) / 2);
    return Rect.fromLTRB(-dx, -dy, size.width + dx, size.height + dy);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (size.contains(position)) {
      return super.hitTest(result, position: position);
    }
    final c = child;
    if (c == null || !slopRect.contains(position)) return false;
    final inside = Offset(
      position.dx.clamp(0.0, math.max(0.0, size.width - 0.01)),
      position.dy.clamp(0.0, math.max(0.0, size.height - 0.01)),
    );
    if (!c.hitTest(result, position: inside) &&
        !c.hitTest(result, position: size.center(Offset.zero))) {
      return false;
    }
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  Rect get semanticBounds => slopRect;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (_mergeSemantics && _minSize > 0) {
      config
        ..isSemanticBoundary = true
        ..isMergingSemanticsOfDescendants = true;
    }
  }
}

class HitSlopScope extends SingleChildRenderObjectWidget {
  const HitSlopScope({super.key, super.child});

  @override
  RenderHitSlopScope createRenderObject(BuildContext context) =>
      RenderHitSlopScope();
}

class RenderHitSlopScope extends RenderProxyBox {
  bool _inside(RenderObject o) {
    for (RenderObject? r = o.parent; r != null; r = r.parent) {
      if (identical(r, this)) return true;
    }
    return false;
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    final near = <({RenderHitSlop slop, Matrix4 toLocal, Offset local, double d})>[];
    for (final s in RenderHitSlop.live) {
      if (s.minSize <= 0 || !s.attached || !s.hasSize || !_inside(s)) continue;
      final toLocal = Matrix4.tryInvert(s.getTransformTo(this));
      if (toLocal == null) continue;
      final local = MatrixUtils.transformPoint(toLocal, position);
      if ((Offset.zero & s.size).contains(local)) {
        final probe = BoxHitTestResult();
        super.hitTest(probe, position: position);
        if (probe.path.any((e) => identical(e.target, s))) {
          return super.hitTest(result, position: position);
        }
      } else if (!s.slopRect.contains(local)) {
        continue;
      }
      near.add((
        slop: s,
        toLocal: toLocal,
        local: local,
        d: (local - s.size.center(Offset.zero)).distance,
      ));
    }
    near.sort((a, b) => a.d.compareTo(b.d));
    for (final n in near) {
      final target = n.slop;
      final edge = Offset(
        n.local.dx.clamp(0.0, math.max(0.0, target.size.width - 0.01)),
        n.local.dy.clamp(0.0, math.max(0.0, target.size.height - 0.01)),
      );
      for (final inside in [edge, target.size.center(Offset.zero)]) {
        final probe = BoxHitTestResult();
        super.hitTest(probe,
            position: MatrixUtils.transformPoint(
                target.getTransformTo(this), inside));
        if (!probe.path.any((e) => identical(e.target, target))) continue;
        result.addWithRawTransform(
          transform: n.toLocal,
          position: position,
          hitTest: (r, _) => target.hitTest(r, position: inside),
        );
        super.hitTest(result, position: position);
        return true;
      }
    }
    return super.hitTest(result, position: position);
  }
}

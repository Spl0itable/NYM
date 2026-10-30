import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class RowTap extends SingleChildRenderObjectWidget {
  const RowTap({
    super.key,
    required this.onTap,
    this.behavior = HitTestBehavior.deferToChild,
    this.excludeFromSemantics = false,
    super.child,
  });

  final VoidCallback? onTap;
  final HitTestBehavior behavior;
  final bool excludeFromSemantics;

  @override
  RenderRowTap createRenderObject(BuildContext context) =>
      RenderRowTap(onTap, excludeFromSemantics, behavior: behavior)
        ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context);

  @override
  void updateRenderObject(BuildContext context, RenderRowTap renderObject) {
    renderObject
      ..onTap = onTap
      ..behavior = behavior
      ..excludeFromSemantics = excludeFromSemantics
      ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context);
  }
}

class RenderRowTap extends RenderProxyBoxWithHitTestBehavior {
  RenderRowTap(this._onTap, this._excludeFromSemantics, {super.behavior});

  TapGestureRecognizer? _tap;
  DeviceGestureSettings? gestureSettings;

  VoidCallback? get onTap => _onTap;
  VoidCallback? _onTap;
  set onTap(VoidCallback? value) {
    if ((value == null) != (_onTap == null)) markNeedsSemanticsUpdate();
    _onTap = value;
  }

  bool get excludeFromSemantics => _excludeFromSemantics;
  bool _excludeFromSemantics;
  set excludeFromSemantics(bool value) {
    if (value == _excludeFromSemantics) return;
    _excludeFromSemantics = value;
    markNeedsSemanticsUpdate();
  }

  void _fire() => _onTap?.call();

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (event is! PointerDownEvent || _onTap == null) return;
    ((_tap ??= TapGestureRecognizer(debugOwner: this)..onTap = _fire)
          ..gestureSettings = gestureSettings)
        .addPointer(event);
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (!_excludeFromSemantics && _onTap != null) config.onTap = _fire;
  }

  @override
  void dispose() {
    _tap?.dispose();
    _tap = null;
    super.dispose();
  }
}

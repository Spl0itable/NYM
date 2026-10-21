import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'layout_model.dart';

const double kDesktopLayoutMin = 1025;

bool desktopLayout(double width) => width >= kDesktopLayoutMin;

bool phoneLayout(double width) => width <= kPhoneMax;

bool hoverLayout({required double width, required bool mouse}) =>
    mouse && !phoneLayout(width);

bool? pointerMeansMouse(PointerEvent e, {bool trustHover = true}) {
  switch (e.kind) {
    case PointerDeviceKind.mouse:
    case PointerDeviceKind.trackpad:
      if (e is PointerHoverEvent) return trustHover ? true : null;
      if (e is PointerDownEvent ||
          e is PointerScrollEvent ||
          e is PointerScaleEvent ||
          e is PointerPanZoomStartEvent) {
        return true;
      }
      return null;
    case PointerDeviceKind.touch:
    case PointerDeviceKind.stylus:
    case PointerDeviceKind.invertedStylus:
      return e is PointerDownEvent ? false : null;
    case PointerDeviceKind.unknown:
      return null;
  }
}

class PointerInput extends ChangeNotifier implements ValueListenable<bool> {
  PointerInput._();

  static final PointerInput instance = PointerInput._();

  bool _mouse = false;
  bool _bound = false;
  bool _hoverIsMouse = true;

  @override
  bool get value {
    ensureBound();
    return _mouse;
  }

  bool get mouse => value;

  void note(PointerEvent e) {
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    if (ios) {
      if (e.kind == PointerDeviceKind.stylus ||
          e.kind == PointerDeviceKind.invertedStylus) {
        _hoverIsMouse = false;
      } else if (e is! PointerHoverEvent && pointerMeansMouse(e) == true) {
        _hoverIsMouse = true;
      }
    }
    final m = pointerMeansMouse(e, trustHover: !ios || _hoverIsMouse);
    if (m == null || m == _mouse) return;
    _mouse = m;
    notifyListeners();
  }

  void ensureBound() {
    if (_bound) return;
    _bound = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(note);
  }

  @visibleForTesting
  void resetForTest({bool mouse = false}) {
    _mouse = mouse;
    _hoverIsMouse = true;
    notifyListeners();
  }

  static bool mouseOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<PointerInputScope>();
    return scope?.notifier?.value ?? instance.value;
  }
}

class PointerInputScope extends InheritedNotifier<PointerInput> {
  PointerInputScope({super.key, required super.child})
      : super(notifier: PointerInput.instance..ensureBound());
}

class PointerModeBuilder extends StatefulWidget {
  const PointerModeBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, bool mouse) builder;

  @override
  State<PointerModeBuilder> createState() => _PointerModeBuilderState();
}

class _PointerModeBuilderState extends State<PointerModeBuilder> {
  @override
  void initState() {
    super.initState();
    PointerInput.instance.addListener(_changed);
  }

  @override
  void dispose() {
    PointerInput.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, PointerInput.instance.value);
}

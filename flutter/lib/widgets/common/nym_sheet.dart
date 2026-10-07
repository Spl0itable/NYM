import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/layout/layout_model.dart';
import '../../features/i18n/i18n.dart';
import 'app_dialog.dart';

const double kNymSheetMaxWidth = 1024;

const double kNymSheetCloseFraction = 0.3;

const double kNymSheetCloseVelocity = 700;

const double kNymSheetExpandMax = kPhoneMax + 0.0;

const double kNymSheetHalf = 0.6;

const double kNymSheetExpandVelocity = 500;

bool nymSheetExpands(double width) => width <= kNymSheetExpandMax;

String nymSheetSettle({
  required double position,
  required double half,
  required double full,
  required double velocity,
}) {
  if (velocity < -kNymSheetExpandVelocity) return 'full';
  if (velocity > kNymSheetCloseVelocity) {
    return position > half + 1 ? 'half' : 'close';
  }
  if (position >= (half + full) / 2) return 'full';
  if (position >= half * (1 - kNymSheetCloseFraction)) return 'half';
  return 'close';
}

bool nymSheetFits(double width) => width <= kNymSheetMaxWidth;

bool useNymSheet(BuildContext context) =>
    nymSheetFits(MediaQuery.sizeOf(context).width);

class NymSheetScope extends InheritedWidget {
  const NymSheetScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NymSheetScope>() != null;

  @override
  bool updateShouldNotify(NymSheetScope oldWidget) => false;
}

Widget nymSheetOr(
  BuildContext context,
  Widget body,
  Widget Function(Widget body) dialog,
) =>
    NymSheetScope.of(context) ? body : dialog(body);

Future<T?> showNymSheet<T>(
  BuildContext context,
  WidgetBuilder builder, {
  Color? barrierColor,
  bool barrierDismissible = true,
  bool useRootNavigator = false,
  bool dragAnywhere = true,
  bool fullHeight = false,
}) {
  if (!useNymSheet(context)) {
    return showDialog<T>(
      context: context,
      barrierColor: barrierColor ?? Colors.black54,
      barrierDismissible: barrierDismissible,
      useRootNavigator: useRootNavigator,
      builder: builder,
    );
  }
  return showNymBottomSheet<T>(
    context,
    builder,
    barrierColor: barrierColor,
    useRootNavigator: useRootNavigator,
    dragAnywhere: dragAnywhere,
    fullHeight: fullHeight,
  );
}

Future<T?> showNymBottomSheet<T>(
  BuildContext context,
  WidgetBuilder builder, {
  Color? barrierColor,
  bool useRootNavigator = false,
  bool dragAnywhere = true,
  bool fullHeight = false,
  bool expandable = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    enableDrag: false,
    useRootNavigator: useRootNavigator,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: barrierColor,
    constraints: const BoxConstraints(maxWidth: kNymSheetMaxWidth),
    builder: (ctx) => KeyboardInset(
      child: NymSheetFrame(
        dragAnywhere: dragAnywhere,
        fullHeight: fullHeight,
        expandable: expandable,
        child: Builder(builder: builder),
      ),
    ),
  );
}

class KeyboardInset extends StatelessWidget {
  const KeyboardInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: child,
      ),
    );
  }
}

class NymSheetFrame extends StatefulWidget {
  const NymSheetFrame({
    super.key,
    required this.child,
    this.dragAnywhere = true,
    this.fullHeight = false,
    this.expandable = false,
  });

  final Widget child;
  final bool dragAnywhere;
  final bool fullHeight;
  final bool expandable;

  @override
  State<NymSheetFrame> createState() => _NymSheetFrameState();
}

class _NymSheetFrameState extends State<NymSheetFrame>
    with SingleTickerProviderStateMixin {
  final GlobalKey _sheetKey = GlobalKey();
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..addListener(_onSettle);
  double _drag = 0;
  double _settleFrom = 0;
  bool _closing = false;
  bool _full = false;
  double? _pos;
  double _startH = 0;
  double _startDy = 0;
  double _halfH = 0;
  double _fullH = 0;

  bool get _expands => widget.expandable && nymSheetExpands(MediaQuery.sizeOf(context).width);

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _onSettle() {
    setState(() => _drag = _settleFrom * (1 - Curves.easeOut.transform(_settle.value)));
  }

  void _dragStart(DragStartDetails d) {
    if (_closing) return;
    _settle.stop();
    if (_expands) {
      _startH = _sheetKey.currentContext?.size?.height ?? 0;
      _startDy = 0;
      if (!_full) _halfH = _startH;
    }
  }

  void _dragUpdate(DragUpdateDetails d) {
    if (_closing) return;
    final dy = d.primaryDelta ?? d.delta.dy;
    if (_expands) {
      _startDy += dy;
      setState(() => _pos = math.min(_fullH, _startH - _startDy));
      return;
    }
    setState(() => _drag = math.max(0, _drag + dy));
  }

  void _dragEnd(DragEndDetails d) {
    if (_closing) return;
    if (_expands) {
      final pos = _pos ?? _startH;
      final target = nymSheetSettle(
        position: pos,
        half: _halfH,
        full: _fullH,
        velocity: d.velocity.pixelsPerSecond.dy,
      );
      if (target == 'close') {
        close();
        return;
      }
      setState(() {
        _full = target == 'full';
        _pos = null;
        _drag = 0;
      });
      return;
    }
    final height = _sheetKey.currentContext?.size?.height ?? 1;
    final v = d.velocity.pixelsPerSecond.dy;
    if (v > kNymSheetCloseVelocity || _drag > height * kNymSheetCloseFraction) {
      close();
    } else {
      _snapBack();
    }
  }

  void _snapBack() {
    if (_drag == 0) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      setState(() => _drag = 0);
      return;
    }
    _settleFrom = _drag;
    _settle.forward(from: 0);
  }

  Future<void> close() async {
    final route = ModalRoute.of(context);
    _closing = true;
    await Navigator.of(context).maybePop();
    _closing = false;
    if (!mounted) return;
    if (route == null || route.isActive) {
      if (_pos != null) setState(() => _pos = null);
      _snapBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_expands) {
      return LayoutBuilder(builder: (context, box) => _build(context, box));
    }
    return _build(context, null);
  }

  Widget _build(BuildContext context, BoxConstraints? box) {
    final c = context.nym;
    final mq = MediaQuery.of(context);
    final avail = mq.size.height - mq.padding.top;
    final expands = box != null;
    var minH = widget.fullHeight ? avail * 0.96 : 0.0;
    var maxH = avail * (widget.fullHeight ? 0.96 : 0.92);
    var offset = _drag;
    var square = false;
    Widget body = NymSheetScope(child: widget.child);
    if (expands) {
      _fullH = box.maxHeight.isFinite ? box.maxHeight : avail;
      final half = _fullH * kNymSheetHalf;
      final pos = _pos;
      if (pos != null) {
        final floor = _halfH > 0 ? _halfH : half;
        if (pos >= floor) {
          minH = pos;
          maxH = pos;
          offset = 0;
        } else {
          minH = 0;
          maxH = floor;
          offset = floor - pos;
        }
      } else if (_full) {
        minH = _fullH;
        maxH = _fullH;
      } else {
        minH = 0;
        maxH = half;
      }
      square = _full && pos == null;
      if (!_full || pos != null) {
        body = ScrollConfiguration(
          behavior: ScrollConfiguration.of(context)
              .copyWith(physics: const NeverScrollableScrollPhysics()),
          child: body,
        );
      }
    }
    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NymSheetDragRegion(child: _Grabber(onTap: close)),
        Flexible(
          fit: widget.fullHeight || (expands && minH > 0) ? FlexFit.tight : FlexFit.loose,
          child: SafeArea(
            top: false,
            child: body,
          ),
        ),
      ],
    );
    content = Container(
      key: _sheetKey,
      constraints: BoxConstraints(maxHeight: maxH, minHeight: minH),
      decoration: BoxDecoration(
        color: c.bgSecondary,
        borderRadius: square
            ? BorderRadius.zero
            : const BorderRadius.vertical(top: Radius.circular(NymRadius.xl)),
        border: square ? null : Border.all(color: c.glassBorder),
        boxShadow: c.isLight
            ? const [BoxShadow(color: Color(0x1F000000), blurRadius: 24)]
            : [BoxShadow(color: c.primaryA(0.08), blurRadius: 20)],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(type: MaterialType.transparency, child: content),
    );
    if (widget.dragAnywhere) {
      content = GestureDetector(
        onVerticalDragStart: _dragStart,
        onVerticalDragUpdate: _dragUpdate,
        onVerticalDragEnd: _dragEnd,
        child: content,
      );
    }
    content = KeyedSubtree(
      key: const ValueKey('nymSheetSurface'),
      child: content,
    );
    return _NymSheetDragScope(
      state: this,
      child: Transform.translate(
        offset: Offset(0, offset),
        child: content,
      ),
    );
  }
}

class _NymSheetDragScope extends InheritedWidget {
  const _NymSheetDragScope({required this.state, required super.child});

  final _NymSheetFrameState state;

  @override
  bool updateShouldNotify(_NymSheetDragScope oldWidget) =>
      oldWidget.state != state;
}

class NymSheetDragRegion extends StatelessWidget {
  const NymSheetDragRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_NymSheetDragScope>();
    if (scope == null || scope.state.widget.dragAnywhere) return child;
    final s = scope.state;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: s._dragStart,
      onVerticalDragUpdate: s._dragUpdate,
      onVerticalDragEnd: s._dragEnd,
      child: child,
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Semantics(
      button: true,
      label: tr('Close sheet'),
      onTap: onTap,
      excludeSemantics: true,
      child: Container(
        height: 26,
        alignment: Alignment.center,
        color: Colors.transparent,
        child: Container(
          key: const ValueKey('nymSheetGrabber'),
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: c.textDim.withValues(alpha: 0.55),
            borderRadius: const BorderRadius.all(Radius.circular(2)),
          ),
        ),
      ),
    );
  }
}

class NymDiscardGuard extends StatelessWidget {
  const NymDiscardGuard({super.key, required this.isDirty, required this.child});

  final bool Function() isDirty;
  final Widget child;

  static Future<bool> confirm(BuildContext context) => showAppConfirm(
        context,
        tr('You have unsaved input. Close and discard it?'),
        title: tr('Discard changes?'),
        okLabel: tr('Discard'),
        cancelLabel: tr('Keep'),
        danger: true,
      );

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (!isDirty()) {
          nav.pop(result);
          return;
        }
        final ok = await confirm(context);
        if (ok && context.mounted) nav.pop(result);
      },
      child: child,
    );
  }
}

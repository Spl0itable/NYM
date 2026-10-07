import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

abstract final class NymTooltipTiming {
  static const Duration wait = Duration(milliseconds: 150);
  static const Duration fadeIn = Duration(milliseconds: 80);
  static const Duration fadeOut = Duration(milliseconds: 75);
  static const Duration warmFor = Duration(milliseconds: 600);
}

abstract final class _Warmth {
  static final ValueNotifier<bool> warm = ValueNotifier<bool>(false);
  static final Set<Object> _showing = <Object>{};
  static Timer? _timer;
  static int _live = 0;

  static void _update() {
    warm.value = _showing.isNotEmpty || (_timer?.isActive ?? false);
  }

  static void shown(Object o) {
    if (_showing.add(o)) _update();
  }

  static void gone(Object o) {
    if (_showing.remove(o)) _update();
  }

  static void left() {
    _timer?.cancel();
    _timer = Timer(NymTooltipTiming.warmFor, _update);
    _update();
  }

  static void _onPointer(PointerEvent e) {
    if (e is! PointerDownEvent) return;
    _timer?.cancel();
    _timer = null;
    _update();
  }

  static void attach() {
    if (_live++ == 0) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    }
  }

  static void detach(Object o) {
    _showing.remove(o);
    if (--_live == 0) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      _timer?.cancel();
      _timer = null;
    }
    _update();
  }
}

class NymTooltipWarmth extends StatelessWidget {
  const NymTooltipWarmth({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _Warmth.warm,
      builder: (context, warm, child) => TooltipTheme(
        data: TooltipTheme.of(context).copyWith(
          waitDuration: warm ? Duration.zero : NymTooltipTiming.wait,
        ),
        child: child!,
      ),
      child: child,
    );
  }
}

class NymTooltip extends Tooltip {
  const NymTooltip({
    super.key,
    super.message,
    super.richMessage,
    super.constraints,
    super.padding,
    super.margin,
    super.verticalOffset,
    super.preferBelow,
    super.excludeFromSemantics,
    super.decoration,
    super.textStyle,
    super.textAlign,
    super.waitDuration,
    super.showDuration,
    super.exitDuration,
    super.enableTapToDismiss,
    super.triggerMode,
    super.enableFeedback,
    super.onTriggered,
    super.mouseCursor,
    super.ignorePointer,
    super.positionDelegate,
    super.child,
  });

  @override
  State<Tooltip> createState() => NymTooltipState();
}

class NymTooltipState extends State<Tooltip> {
  static const AnimationStyle _animation = AnimationStyle(
    curve: Curves.easeOut,
    duration: NymTooltipTiming.fadeIn,
    reverseDuration: NymTooltipTiming.fadeOut,
  );

  final GlobalKey<RawTooltipState> _raw = GlobalKey<RawTooltipState>();
  Animation<double>? _anim;
  bool _showing = false;

  String get _message => widget.message ?? widget.richMessage!.toPlainText();

  bool ensureTooltipVisible() => _raw.currentState?.ensureTooltipVisible() ?? false;

  @override
  void initState() {
    super.initState();
    _Warmth.attach();
    _Warmth.warm.addListener(_onWarm);
  }

  @override
  void dispose() {
    _Warmth.warm.removeListener(_onWarm);
    _anim?.removeStatusListener(_onStatus);
    _Warmth.detach(this);
    super.dispose();
  }

  void _onWarm() {
    if (mounted) setState(() {});
  }

  void _onStatus(AnimationStatus s) {
    _showing = s.isForwardOrCompleted;
    if (_showing) {
      _Warmth.shown(this);
    } else {
      _Warmth.gone(this);
    }
  }

  void _track(Animation<double> a) {
    if (identical(a, _anim)) return;
    _anim?.removeStatusListener(_onStatus);
    _anim = a..addStatusListener(_onStatus);
    scheduleMicrotask(() {
      if (mounted && identical(_anim, a)) _onStatus(a.status);
    });
  }

  void _onExit(PointerExitEvent _) {
    if (_showing) _Warmth.left();
  }

  Offset _position(TooltipPositionContext ctx, TooltipThemeData theme) {
    final dy = widget.verticalOffset ?? theme.verticalOffset ?? 24.0;
    final below = widget.preferBelow ?? theme.preferBelow ?? true;
    final resolved = TooltipPositionContext(
      target: ctx.target,
      targetSize: ctx.targetSize,
      tooltipSize: ctx.tooltipSize,
      overlaySize: ctx.overlaySize,
      verticalOffset: dy,
      preferBelow: below,
    );
    return widget.positionDelegate?.call(resolved) ??
        positionDependentBox(
          size: ctx.overlaySize,
          childSize: ctx.tooltipSize,
          target: ctx.target,
          verticalOffset: dy,
          preferBelow: below,
        );
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child ?? const SizedBox.shrink();
    if (_message.isEmpty) return child;
    final theme = Theme.of(context);
    final tipTheme = TooltipTheme.of(context);
    final desktop = switch (theme.platform) {
      TargetPlatform.macOS || TargetPlatform.linux || TargetPlatform.windows => true,
      _ => false,
    };
    final dark = theme.brightness == Brightness.dark;
    final defaultStyle = theme.textTheme.bodyMedium!.copyWith(
      color: dark ? Colors.black : Colors.white,
      fontSize: desktop ? 12.0 : 14.0,
    );
    final defaultDecoration = BoxDecoration(
      color: dark
          ? Colors.white.withValues(alpha: 0.9)
          : Colors.grey[700]!.withValues(alpha: 0.9),
      borderRadius: const BorderRadius.all(Radius.circular(4)),
    );
    final style = widget.textStyle ?? tipTheme.textStyle ?? defaultStyle;
    final align = widget.textAlign ?? tipTheme.textAlign ?? TextAlign.start;
    final box = ConstrainedBox(
      constraints: widget.constraints ??
          tipTheme.constraints ??
          BoxConstraints(minHeight: desktop ? 24.0 : 32.0),
      child: DefaultTextStyle(
        style: style,
        textAlign: align,
        child: Container(
          decoration: widget.decoration ?? tipTheme.decoration ?? defaultDecoration,
          padding: widget.padding ??
              tipTheme.padding ??
              EdgeInsets.symmetric(horizontal: desktop ? 8.0 : 16.0, vertical: 4.0),
          margin: widget.margin ?? tipTheme.margin ?? EdgeInsets.zero,
          child: Center(
            widthFactor: 1.0,
            heightFactor: 1.0,
            child: Text.rich(
              widget.richMessage ?? TextSpan(text: widget.message),
              style: style,
              textAlign: align,
            ),
          ),
        ),
      ),
    );
    final region = MouseRegion(
      cursor: widget.mouseCursor ?? MouseCursor.defer,
      onExit: _onExit,
      child: child,
    );
    if (!TooltipVisibility.of(context)) return region;
    final exclude = widget.excludeFromSemantics ?? tipTheme.excludeFromSemantics ?? false;
    return RawTooltip(
      key: _raw,
      semanticsTooltip: exclude ? null : _message,
      animationStyle: _animation,
      tooltipBuilder: (context, animation) {
        _track(animation);
        return FadeTransition(opacity: animation, child: box);
      },
      touchDelay: widget.showDuration ??
          tipTheme.showDuration ??
          const Duration(milliseconds: 1500),
      triggerMode: widget.triggerMode ??
          tipTheme.triggerMode ??
          TooltipTriggerMode.longPress,
      enableFeedback: widget.enableFeedback ?? tipTheme.enableFeedback ?? true,
      hoverDelay: widget.waitDuration ??
          (_Warmth.warm.value ? Duration.zero : NymTooltipTiming.wait),
      enableTapToDismiss: widget.enableTapToDismiss,
      onTriggered: widget.onTriggered,
      dismissDelay: widget.exitDuration ??
          tipTheme.exitDuration ??
          const Duration(milliseconds: 100),
      positionDelegate: (ctx) => _position(ctx, tipTheme),
      ignorePointer: widget.ignorePointer ?? widget.message != null,
      child: region,
    );
  }
}

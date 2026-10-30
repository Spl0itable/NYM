import 'package:flutter/widgets.dart';

abstract class Eased<T> extends StatefulWidget {
  const Eased({super.key, required this.duration, this.curve = Curves.linear});

  final Duration duration;
  final Curve curve;

  T get target;

  T lerp(T a, T b, double t);

  Widget show(BuildContext context, T value);

  @override
  State<Eased<T>> createState() => _EasedState<T>();
}

class _EasedState<T> extends State<Eased<T>> with SingleTickerProviderStateMixin {
  AnimationController? _run;
  late T _from = widget.target;
  late T _shown = widget.target;

  @override
  void didUpdateWidget(Eased<T> old) {
    super.didUpdateWidget(old);
    if (widget.target == old.target) return;
    _from = _run?.isAnimating == true ? _shown : old.target;
    _shown = _from;
    final run = _run ??= AnimationController(vsync: this)..addListener(_step);
    run.duration = widget.duration;
    run.forward(from: 0);
  }

  void _step() {
    final run = _run!;
    setState(() => _shown = widget.lerp(_from, widget.target, widget.curve.transform(run.value)));
  }

  @override
  void dispose() {
    _run?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.show(context, _run?.isAnimating == true ? _shown : widget.target);
}

class EasedScale extends Eased<double> {
  const EasedScale({
    super.key,
    required this.scale,
    required super.duration,
    super.curve,
    this.child,
  });

  final double scale;
  final Widget? child;

  @override
  double get target => scale;

  @override
  double lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  Widget show(BuildContext context, double value) =>
      Transform.scale(scale: value, child: child);
}

class EasedContainer extends Eased<Decoration?> {
  const EasedContainer({
    super.key,
    required super.duration,
    super.curve,
    this.boxKey,
    this.constraints,
    this.alignment,
    this.padding,
    this.decoration,
    this.child,
  });

  final Key? boxKey;
  final BoxConstraints? constraints;
  final AlignmentGeometry? alignment;
  final EdgeInsetsGeometry? padding;
  final Decoration? decoration;
  final Widget? child;

  @override
  Decoration? get target => decoration;

  @override
  Decoration? lerp(Decoration? a, Decoration? b, double t) => Decoration.lerp(a, b, t);

  @override
  Widget show(BuildContext context, Decoration? value) => Container(
        key: boxKey,
        constraints: constraints,
        alignment: alignment,
        padding: padding,
        decoration: value,
        child: child,
      );
}

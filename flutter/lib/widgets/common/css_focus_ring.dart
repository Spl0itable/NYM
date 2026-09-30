import 'package:flutter/material.dart';

/// CSS `box-shadow: 0 0 0 3px` focus ring painted only outside [child], unlike a spread [BoxShadow].
class CssFocusRing extends StatelessWidget {
  const CssFocusRing({
    super.key,
    required this.show,
    required this.color,
    required this.radius,
    this.width = 3,
    required this.child,
  });

  /// The band is always laid out and only its color toggles, so a focused TextField is never re-parented.
  final bool show;

  final Color color;

  final BorderRadius radius;

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          left: -width,
          top: -width,
          right: -width,
          bottom: -width,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: _expand(radius, width),
                border: Border.all(
                  color: show ? color : Colors.transparent,
                  width: width,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static BorderRadius _expand(BorderRadius r, double by) => BorderRadius.only(
        topLeft: _grow(r.topLeft, by),
        topRight: _grow(r.topRight, by),
        bottomLeft: _grow(r.bottomLeft, by),
        bottomRight: _grow(r.bottomRight, by),
      );

  // CSS box-shadow corner rule: non-zero radii grow by the spread; sharp corners stay sharp.
  static Radius _grow(Radius r, double by) =>
      Radius.elliptical(r.x <= 0 ? 0 : r.x + by, r.y <= 0 ? 0 : r.y + by);
}

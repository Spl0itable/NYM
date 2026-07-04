import 'package:flutter/material.dart';

/// A CSS `box-shadow: 0 0 0 3px <color>` focus ring: paints ONLY the band
/// OUTSIDE [child]'s rounded box (`.message-input:focus`, styles-chat.css:
/// 1678-1682).
///
/// A Flutter [BoxShadow] with `spreadRadius` also fills the area BEHIND the
/// child — with the composer's translucent field fill (white@0.07 focused)
/// the primary tint bled through the whole field and read as a full-field
/// highlight on focus, which the PWA never shows (its box-shadow hugs the
/// outline only). This widget adds no layout size (the band overhangs, like
/// CSS box-shadow) and keeps [child] in a stable Stack slot so a focused
/// TextField is never re-parented (which would drop its IME connection).
class CssFocusRing extends StatelessWidget {
  const CssFocusRing({
    super.key,
    required this.show,
    required this.color,
    required this.radius,
    this.width = 3,
    required this.child,
  });

  /// Whether the ring is visible (the band is always laid out; only its color
  /// toggles, so showing/hiding never restructures the tree).
  final bool show;

  final Color color;

  /// The child's own border radius; the band's outer radius follows the CSS
  /// rule (non-zero corner radii grow by [width], sharp corners stay sharp).
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

  // CSS box-shadow corner rule: non-zero radii expand by the spread; zero
  // (sharp) corners stay sharp.
  static Radius _grow(Radius r, double by) =>
      Radius.elliptical(r.x <= 0 ? 0 : r.x + by, r.y <= 0 ? 0 : r.y + by);
}

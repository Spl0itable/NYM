import 'package:flutter/widgets.dart';

/// Radii, motion and type metrics ported from `:root` (docs/specs/02 §2.2).
class NymRadius {
  NymRadius._();
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;

  static const BorderRadius rxs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius rsm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rmd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rlg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius rxl = BorderRadius.all(Radius.circular(xl));
}

class NymMotion {
  NymMotion._();

  /// `--transition: 0.25s cubic-bezier(0.4,0,0.2,1)`
  static const Duration transition = Duration(milliseconds: 250);
  static const Curve curve = Cubic(0.4, 0, 0.2, 1);

  /// Sidebar / context-menu slide.
  static const Duration slide = Duration(milliseconds: 150);
}

/// User-adjustable base text size (`--user-text-size`, default 15, range 12–28).
class NymTextSize {
  NymTextSize._();
  static const double defaultSize = 15;
  static const double min = 12;
  static const double max = 28;
}

/// Fixed layout dimensions from the spec.
class NymDimens {
  NymDimens._();
  static const double sidebarWidth = 290;
  static const double sidebarDrawerWidth = 300;
  static const double contextMenuWidth = 320;
  static const double mobileBreakpoint = 768;
  static const double tabletBreakpoint = 1024;
}

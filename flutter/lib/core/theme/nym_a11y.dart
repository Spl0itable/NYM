import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'nym_colors.dart';

class NymA11y extends ThemeExtension<NymA11y> {
  const NymA11y({this.largeTargets = false, this.highContrast = false});

  final bool largeTargets;
  final bool highContrast;

  static const double minContrast = 4.5;

  @override
  NymA11y copyWith({bool? largeTargets, bool? highContrast}) => NymA11y(
        largeTargets: largeTargets ?? this.largeTargets,
        highContrast: highContrast ?? this.highContrast,
      );

  @override
  NymA11y lerp(ThemeExtension<NymA11y>? other, double t) =>
      other is NymA11y && t >= 0.5 ? other : this;

  @override
  bool operator ==(Object other) =>
      other is NymA11y &&
      other.largeTargets == largeTargets &&
      other.highContrast == highContrast;

  @override
  int get hashCode => Object.hash(largeTargets, highContrast);
}

bool nymTouchPlatform() =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;

extension NymA11yContext on BuildContext {
  NymA11y get a11y => Theme.of(this).extension<NymA11y>() ?? const NymA11y();

  bool get largeTargets => a11y.largeTargets;

  bool get largeTouchTargets => a11y.largeTargets && nymTouchPlatform();

  bool get highContrast => a11y.highContrast;
}

double _channel(double v) =>
    v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double relativeLuminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

Color flattenOver(Color fg, Color bg) => Color.alphaBlend(fg, bg.withValues(alpha: 1));

double contrastRatio(Color fg, Color bg) {
  final b = bg.withValues(alpha: 1);
  final a = relativeLuminance(flattenOver(fg, b));
  final l = relativeLuminance(b);
  return (math.max(a, l) + 0.05) / (math.min(a, l) + 0.05);
}

Color legibleOn(Color fg, Color bg, {double min = NymA11y.minContrast}) {
  final base = bg.withValues(alpha: 1);
  var c = flattenOver(fg, base);
  if (contrastRatio(c, base) >= min) return c;
  final toward = relativeLuminance(base) > 0.18 ? Colors.black : Colors.white;
  for (var i = 1; i <= 20; i++) {
    final m = Color.lerp(c, toward, i / 20)!;
    if (contrastRatio(m, base) >= min) return m;
  }
  return toward;
}

Color legibleOnAll(Color fg, List<Color> bgs, {double min = NymA11y.minContrast}) {
  var c = fg;
  for (var i = 0; i < 3; i++) {
    for (final bg in bgs) {
      c = legibleOn(c, bg, min: min);
    }
  }
  return c;
}

Color badgeFill(BuildContext context, Color fill) {
  if (!context.highContrast) return fill;
  var c = fill.withValues(alpha: 1);
  for (var i = 1; i <= 20 && contrastRatio(Colors.white, c) < NymA11y.minContrast; i++) {
    c = Color.lerp(fill.withValues(alpha: 1), Colors.black, i / 20)!;
  }
  return c;
}

double? largeFieldMin(BuildContext context) =>
    context.largeTouchTargets ? 44 : null;

Color sidebarRowBg(NymColors c) => flattenOver(c.bgSecondary, c.bg);

Color bubbleBgFor(NymColors c) => flattenOver(c.bubbleOtherBg, c.bg);

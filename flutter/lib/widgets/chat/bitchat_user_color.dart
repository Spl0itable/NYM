import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Deterministic per-pubkey HSL nym color, a port of the PWA `generateUniqueColor`; null for an empty pubkey.
Color? bitchatUserColor(String pubkey, {required bool isLight, bool contrast = false}) {
  if (pubkey.isEmpty) return null;
  // Full 64-bit accumulator, not masked: JS keeps `hash` a double and only `<<` coerces to int32.
  int h = 0;
  for (var i = 0; i < pubkey.length; i++) {
    // Reproduces JS `hash << 5` ToInt32 semantics.
    final shifted = ((h << 5) & 0xFFFFFFFF).toSigned(32);
    h = pubkey.codeUnitAt(i) + (shifted - h);
  }
  final bucket = h.abs() % 1000;
  return bitchatBucketColor(bucket, isLight: isLight, contrast: contrast);
}

double _lin(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double _lum(List<double> rgb) => 0.2126 * _lin(rgb[0]) + 0.7152 * _lin(rgb[1]) + 0.0722 * _lin(rgb[2]);

List<double> _rgbOf(int h, int sat, int light) {
  final s = sat / 100, l = light / 100;
  double k(int n) => (n + h / 30) % 12;
  final a = s * math.min(l, 1 - l);
  double f(int n) => l - a * math.max(-1.0, math.min(k(n) - 3, math.min(9 - k(n), 1.0)));
  return [f(0), f(8), f(4)];
}

double _ratio(double x, double y) => (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);

final double _lightBubble = _lum([230 / 255, 230 / 255, 224 / 255]);
final double _darkBubble = _lum([42 / 255, 42 / 255, 58 / 255]);

(int, int, int) bitchatBucketHsl(int bucket, {required bool isLight, bool contrast = false}) {
  final hue = bucket * 360 ~/ 1000;
  final sat = isLight ? 55 + (bucket % 35) : 65 + (bucket % 35);
  var light = isLight ? 25 + (bucket % 20) : 60 + (bucket % 25);
  if (contrast) {
    final bg = isLight ? _lightBubble : _darkBubble;
    while (light > 0 && light < 100 && _ratio(_lum(_rgbOf(hue, sat, light)), bg) < 4.6) {
      light += isLight ? -1 : 1;
    }
  }
  return (hue, sat, light);
}

Color bitchatBucketColor(int bucket, {required bool isLight, bool contrast = false}) {
  final (hue, sat, light) = bitchatBucketHsl(bucket, isLight: isLight, contrast: contrast);
  return HSLColor.fromAHSL(1, hue.toDouble(), sat / 100, light / 100).toColor();
}

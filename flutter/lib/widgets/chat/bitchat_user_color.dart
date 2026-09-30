import 'package:flutter/material.dart';

/// Deterministic per-pubkey HSL nym color, a port of the PWA `generateUniqueColor`; null for an empty pubkey.
Color? bitchatUserColor(String pubkey, {required bool isLight}) {
  if (pubkey.isEmpty) return null;
  // Full 64-bit accumulator, not masked: JS keeps `hash` a double and only `<<` coerces to int32.
  int h = 0;
  for (var i = 0; i < pubkey.length; i++) {
    // Reproduces JS `hash << 5` ToInt32 semantics.
    final shifted = ((h << 5) & 0xFFFFFFFF).toSigned(32);
    h = pubkey.codeUnitAt(i) + (shifted - h);
  }
  final bucket = h.abs() % 1000;
  final hue = (bucket * 360 ~/ 1000).toDouble(); // `(…)|0` truncation.
  final sat = (isLight ? 55 + (bucket % 35) : 65 + (bucket % 35)) / 100;
  final light = (isLight ? 25 + (bucket % 20) : 60 + (bucket % 25)) / 100;
  return HSLColor.fromAHSL(1, hue, sat, light).toColor();
}

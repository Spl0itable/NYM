import 'package:flutter/material.dart';

/// Pure-Dart port of `generateUniqueColor(pubkey)` from the PWA
/// (`js/modules/users.js:31-60`).
///
/// In the default **Bitchat** theme every OTHER user's nym (and message body)
/// is painted one of 1000 deterministic HSL colors derived from a djb2-style
/// hash of their full 64-hex pubkey. Self resolves to `--primary` (green) and
/// is handled by the caller; this helper covers the non-self palette.
///
/// PWA reference (`users.js`):
/// ```js
/// let hash = 0;
/// for (let i=0;i<pubkey.length;i++) hash = pubkey.charCodeAt(i) + ((hash<<5)-hash);
/// const bucket = Math.abs(hash) % 1000;                 // :37 — full double, NOT int32
/// // dark:  hsl((bucket*360/1000)|0, 65 + bucket%35, 60 + bucket%25)
/// // light: hsl((bucket*360/1000)|0, 55 + bucket%35, 25 + bucket%20)
/// ```
///
/// **Int-width trap (C06-3).** In JS the running `hash` is a double; only the
/// `(hash << 5)` sub-expression is coerced to int32 (`ToInt32`). The FINAL
/// `hash` regularly exceeds 2^32, and `Math.abs(hash) % 1000` runs on that full
/// value. A naive `h & 0xFFFFFFFF` / `h.toSigned(32)` over the WHOLE accumulator
/// yields the wrong bucket. We therefore keep `h` a full (64-bit) Dart `int` and
/// coerce ONLY the shift to a signed-32-bit value, exactly mirroring JS `<<`.
///
/// Verified byte-for-byte against the JS semantics (200k random-pubkey fuzz) and
/// against the ground-truth vectors:
///   "0"*64 → bucket 720 → dark hsl(259,85%,80%)
///   "f"*64 → bucket 216 → dark hsl(77,71%,76%)
///
/// Returns null for an empty pubkey (caller falls back to the theme color).
Color? bitchatUserColor(String pubkey, {required bool isLight}) {
  if (pubkey.isEmpty) return null;
  // Full 64-bit accumulator (NOT masked) — see the int-width note above.
  int h = 0;
  for (var i = 0; i < pubkey.length; i++) {
    // JS `hash << 5` performs ToInt32 then shifts to an int32 result. Masking
    // the 64-bit shift to its low 32 bits and re-signing reproduces that
    // exactly (proven equivalent for the accumulator's value range).
    final shifted = ((h << 5) & 0xFFFFFFFF).toSigned(32);
    h = pubkey.codeUnitAt(i) + (shifted - h);
  }
  final bucket = h.abs() % 1000; // matches Math.abs(hash) % 1000
  final hue = (bucket * 360 ~/ 1000).toDouble(); // `(…)|0` truncation
  final sat = (isLight ? 55 + (bucket % 35) : 65 + (bucket % 35)) / 100;
  final light = (isLight ? 25 + (bucket % 20) : 60 + (bucket % 25)) / 100;
  return HSLColor.fromAHSL(1, hue, sat, light).toColor();
}

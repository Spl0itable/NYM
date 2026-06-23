import 'package:flutter/material.dart';

/// Pure-Dart port of `generateAvatarSvg(seed)` from the PWA
/// (`js/modules/users.js` 318-376).
///
/// Deterministic 5x5 horizontally-mirrored identicon derived from the seed
/// (the nym / pubkey). Same hashing (FNV-1a 32-bit), same PRNG (Mulberry32),
/// same colour rules and grid layout as the web version, so a given seed yields
/// an identical pattern on both platforms.
///
/// The web renders an 80x80 SVG (5 cols x 16px cells). [NymIdenticon] paints the
/// same grid via a [CustomPainter] and scales it to fit [size].
class IdenticonSpec {
  IdenticonSpec({
    required this.seed,
    required this.fg,
    required this.bg,
    required this.cells,
  });

  /// The seed this spec was derived from.
  final String seed;

  /// Foreground (rect) colour — `hsl(hue, sat%, light%)`.
  final Color fg;

  /// Background colour — `hsl((hue+180)%360, 25%, 18%)`.
  final Color bg;

  /// 5x5 grid of filled cells, row-major (`cells[y*5 + x]`). Already mirrored.
  final List<bool> cells;

  static const int cols = 5;
  static const int rows = 5;

  /// A stable, comparable descriptor of the rendered identicon. Two seeds that
  /// produce the same image share this string; different seeds (almost always)
  /// differ. Used by tests to assert determinism.
  String get descriptor {
    final buf = StringBuffer()
      ..write(_hex(fg))
      ..write('|')
      ..write(_hex(bg))
      ..write('|');
    for (final on in cells) {
      buf.write(on ? '1' : '0');
    }
    return buf.toString();
  }

  static String _hex(Color c) {
    int ch(double v) => (v * 255).round() & 0xff;
    return '${ch(c.r).toRadixString(16).padLeft(2, '0')}'
        '${ch(c.g).toRadixString(16).padLeft(2, '0')}'
        '${ch(c.b).toRadixString(16).padLeft(2, '0')}';
  }

  /// Derives the deterministic identicon spec for [seed], mirroring
  /// `generateAvatarSvg` exactly.
  factory IdenticonSpec.fromSeed(String? seed) {
    final key = seed ?? '';

    // FNV-1a-ish 32-bit hash (JS: h = Math.imul(h, 16777619) >>> 0).
    var h = 2166136261;
    for (var i = 0; i < key.length; i++) {
      h ^= key.codeUnitAt(i);
      h = _imul(h, 16777619) & 0xffffffff;
    }
    var s = h != 0 ? h : 1;

    // Mulberry32 PRNG, identical to the JS `rand()` closure:
    //   s = (s + 0x6D2B79F5) >>> 0;
    //   let t = Math.imul(s ^ (s >>> 15), 1 | s);
    //   t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    //   return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    double next() {
      s = (s + 0x6D2B79F5) & 0xffffffff;
      var t = _imul(s ^ (s >>> 15), 1 | s) & 0xffffffff;
      t = ((t + (_imul(t ^ (t >>> 7), 61 | t) & 0xffffffff)) ^ t) & 0xffffffff;
      return ((t ^ (t >>> 14)) & 0xffffffff) / 4294967296.0;
    }

    final hue = (next() * 360).floor();
    final sat = 60 + (next() * 25).floor();
    final light = 50 + (next() * 15).floor();
    final fg = _hsl(hue.toDouble(), sat / 100, light / 100);
    final bgHue = (hue + 180) % 360;
    final bg = _hsl(bgHue.toDouble(), 0.25, 0.18);

    const cols = IdenticonSpec.cols;
    const rows = IdenticonSpec.rows;
    final half = (cols / 2).ceil();
    final cells = List<bool>.filled(rows * cols, false);
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < half; x++) {
        if (next() < 0.5) {
          cells[y * cols + x] = true;
          final mirror = cols - 1 - x;
          if (mirror != x) cells[y * cols + mirror] = true;
        }
      }
    }

    return IdenticonSpec(seed: key, fg: fg, bg: bg, cells: cells);
  }
}

/// 32-bit signed multiply matching JavaScript's `Math.imul`.
int _imul(int a, int b) {
  final aHi = (a >>> 16) & 0xffff;
  final aLo = a & 0xffff;
  final bHi = (b >>> 16) & 0xffff;
  final bLo = b & 0xffff;
  // (aLo*bLo) + (((aHi*bLo + aLo*bHi) << 16)) | 0
  final lo = aLo * bLo;
  final mid = (aHi * bLo + aLo * bHi) & 0xffffffff;
  return (lo + ((mid << 16) & 0xffffffff)) & 0xffffffff;
}

/// HSL → RGB Color (h in [0,360), s/l in [0,1]).
Color _hsl(double h, double s, double l) {
  return HSLColor.fromAHSL(1, h % 360, s, l).toColor();
}

/// Renders the deterministic [IdenticonSpec] for [seed] as a square avatar.
///
/// Drop-in fallback avatar matching the PWA's generated SVG. Optionally clipped
/// to a circle via [circle]; defaults to the web's square crisp-edges look.
class NymIdenticon extends StatelessWidget {
  const NymIdenticon({
    super.key,
    required this.seed,
    this.size = 80,
    this.circle = false,
  });

  final String seed;
  final double size;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final spec = IdenticonSpec.fromSeed(seed);
    final painter = CustomPaint(
      size: Size(size, size),
      painter: _IdenticonPainter(spec),
    );
    if (!circle) return painter;
    return ClipOval(child: painter);
  }
}

class _IdenticonPainter extends CustomPainter {
  _IdenticonPainter(this.spec);

  final IdenticonSpec spec;

  @override
  void paint(Canvas canvas, Size size) {
    // 80x80 logical grid (5 cols, 16px cells) scaled to the requested size.
    final cell = size.width / IdenticonSpec.cols;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = spec.bg,
    );
    final fg = Paint()..color = spec.fg;
    for (var y = 0; y < IdenticonSpec.rows; y++) {
      for (var x = 0; x < IdenticonSpec.cols; x++) {
        if (spec.cells[y * IdenticonSpec.cols + x]) {
          canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5),
            fg,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_IdenticonPainter old) =>
      old.spec.descriptor != spec.descriptor;
}

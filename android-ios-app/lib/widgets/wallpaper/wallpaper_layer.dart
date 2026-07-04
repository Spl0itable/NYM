import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../state/settings_provider.dart';
import '../common/nym_avatar.dart' show proxiedAvatarUrl;

/// The kind of fill a wallpaper type produces. Mirrors `applyWallpaper`:
/// `pattern` is one of the 7 built-in tiled vector patterns, `none` paints
/// nothing, `custom` is a user-uploaded image.
enum WallpaperFill { none, pattern, custom }

/// A pure, theme-independent description of one wallpaper type. Resolved from
/// a `wallpaperType` string by [WallpaperPattern.forType].
@immutable
class WallpaperPattern {
  const WallpaperPattern({required this.type, required this.fill});

  /// The canonical type string (one of the 9 PWA `data-wallpaper` values).
  final String type;
  final WallpaperFill fill;

  bool get paints => fill != WallpaperFill.none;

  /// Pure mapping from the persisted `nym_wallpaper_type` value to a pattern
  /// descriptor. Unknown values (and `'none'`) resolve to the transparent
  /// [none] pattern, mirroring `applyWallpaper`'s "no class → transparent" path.
  static WallpaperPattern forType(String? type) {
    if (type == 'custom') {
      return const WallpaperPattern(type: 'custom', fill: WallpaperFill.custom);
    }
    if (type != null && presets.contains(type)) {
      return WallpaperPattern(type: type, fill: WallpaperFill.pattern);
    }
    return const WallpaperPattern(type: 'none', fill: WallpaperFill.none);
  }

  /// The 7 selectable preset pattern names (excludes `none` and `custom`).
  static const List<String> presets = [
    'geometric',
    'circuit',
    'dots',
    'waves',
    'topography',
    'hexagons',
    'diamonds',
  ];
}

/// The fixed full-bleed wallpaper layer (`#wallpaperLayer`: fixed, inset 0,
/// `z-index:0`, `pointer-events:none`). Mounts beneath the chat content and is
/// tinted by the active `--primary` (`context.nym.primary`). Driven by
/// `settings.wallpaperType`; supports a custom uploaded image
/// (`nym_wallpaper_custom_url`) overlaid by a dark/light scrim.
class WallpaperLayer extends ConsumerWidget {
  const WallpaperLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the WHOLE settings state — not `.select((s) => s.wallpaperType)`.
    // The custom URL lives KV-only (`nym_wallpaper_custom_url`), so a select
    // on the type string would compare 'custom' == 'custom' and skip the
    // rebuild when a NEW image arrives while custom is already active, leaving
    // the old wallpaper on screen. Both URL writers fire `setWallpaperType`
    // after persisting the URL (upload: settings `_uploadCustomWallpaper`;
    // inbound settings sync: `str('wallpaperType', …)` alongside the URL KV
    // mirror), and that setter always publishes a fresh Settings object even
    // for an unchanged type — so a full watch re-reads the URL below exactly
    // when the PWA re-applies (applyWallpaper on upload, app.js:4198; the
    // sync path's same-type/different-URL `sameAsCurrent` check,
    // app.js:6231-6238).
    final settings = ref.watch(settingsProvider);
    final pattern = WallpaperPattern.forType(settings.wallpaperType);
    if (!pattern.paints) return const SizedBox.shrink();

    final c = context.nym;

    if (pattern.fill == WallpaperFill.custom) {
      final kv = ref.watch(keyValueStoreProvider);
      final url = kv.getString(StorageKeys.wallpaperCustomUrl);
      if (url == null || url.isEmpty) return const SizedBox.shrink();
      // Scrim mirrors users.js applyWallpaper: rgba(10,10,15,0.82) dark /
      // rgba(245,245,242,0.85) light layered over the image.
      final scrim = c.isLight
          ? const Color(0xD9F5F5F2)
          : const Color(0xD10A0A0F);
      // The PWA only ever stores a remote upload URL; the Flutter upload flow
      // (settings `_WallpaperPicker`) persists a locally-picked file's absolute
      // path instead, so a value that isn't an http(s) URL is an on-device file.
      final isRemote = url.startsWith('http://') || url.startsWith('https://');
      final ImageProvider image = isRemote
          // Route the remote custom wallpaper through the media proxy (hide IP /
          // bypass hotlink-403), like every other remote image.
          ? NetworkImage(proxiedAvatarUrl(url) ?? url)
          : FileImage(File(url));
      return IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: image,
              fit: BoxFit.cover,
              colorFilter: ColorFilter.mode(scrim, BlendMode.srcOver),
            ),
          ),
        ),
      );
    }

    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: WallpaperPatternPainter(
          type: pattern.type,
          primary: c.primary,
          isLight: c.isLight,
        ),
      ),
    );
  }
}

/// Paints one of the 7 tiled vector wallpaper patterns, at either the
/// full-screen `#wallpaperLayer.wallpaper-pattern-*` scale
/// (styles-features.css:3250-3304) or — with [preview] — the settings-grid
/// `.wallpaper-preview.wallpaper-*` thumbnail scale
/// (styles-features.css:3184-3243), which uses smaller tiles and stronger
/// alphas so the same geometry reads inside a thumbnail.
///
/// Strokes/fills are the primary color at the pattern's tint alpha (the CSS
/// `rgba(var(--wp-r), var(--wp-g), var(--wp-b), a)` — the wp vars are derived
/// from the active theme's `--primary`, settings.js:1000-1007). Per-shape SVG
/// `stroke-opacity` / `fill-opacity` values multiply the base alpha, exactly
/// like the alpha-channel SVG masks they are ported from. Light mode boosts
/// the masked patterns' tint (layer → 0.45, dots → 0.4,
/// styles-themes-responsive.css:1368-1378; previews → opacity 0.6 over the
/// white `.wallpaper-preview`, styles-themes-responsive.css:1359-1366) so the
/// pattern renders light-primary-on-white.
class WallpaperPatternPainter extends CustomPainter {
  WallpaperPatternPainter({
    required this.type,
    required this.primary,
    required this.isLight,
    this.preview = false,
  });

  /// One of the 7 preset pattern ids ([WallpaperPattern.presets]).
  final String type;
  final Color primary;
  final bool isLight;

  /// False → full-screen `#wallpaperLayer` variant; true → settings-grid
  /// `.wallpaper-preview` thumbnail variant.
  final bool preview;

  Color _tint(double a) => primary.withValues(alpha: a);

  /// The dominant tint alpha for this variant/theme: the SVG-mask
  /// `background-color` alpha (× the preview's `opacity`) or the dots
  /// gradient-stop alpha. Geometric carries its own per-gradient alphas.
  double get _alpha {
    switch (type) {
      case 'circuit':
        // Layer: 0.10 dark / 0.45 light; preview: full color × opacity 0.18
        // dark / 0.6 light.
        return preview ? (isLight ? 0.6 : 0.18) : (isLight ? 0.45 : 0.10);
      case 'dots':
        // Layer: 0.10 dark / 0.4 light; preview: 0.15 (no light override —
        // it reads against the white preview background).
        return preview ? 0.15 : (isLight ? 0.40 : 0.10);
      default: // waves / topography / hexagons / diamonds
        return preview ? (isLight ? 0.6 : 0.12) : (isLight ? 0.45 : 0.08);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    switch (type) {
      case 'geometric':
        _paintGeometric(canvas, size);
      case 'dots':
        _paintDots(canvas, size);
      case 'circuit':
        _tiled(canvas, size,
            preview ? const Size(60, 60) : const Size(80, 80), _circuitTile);
      case 'waves':
        _tiled(canvas, size,
            preview ? const Size(100, 20) : const Size(120, 24), _wavesTile);
      case 'topography':
        _tiled(
            canvas,
            size,
            preview ? const Size(100, 100) : const Size(120, 120),
            _topographyTile);
      case 'hexagons':
        // Same 56×100 honeycomb tile in both variants.
        _tiled(canvas, size, const Size(56, 100), _hexagonsTile);
      case 'diamonds':
        _tiled(canvas, size,
            preview ? const Size(40, 40) : const Size(48, 48), _diamondsTile);
    }
  }

  /// Tiles a per-cell painter across [size] with the CSS `mask-size` tile,
  /// clipping each cell like the repeating SVG tile does.
  void _tiled(Canvas canvas, Size size, Size tile, void Function(Canvas) cell) {
    for (double y = 0; y < size.height; y += tile.height) {
      for (double x = 0; x < size.width; x += tile.width) {
        canvas.save();
        canvas.translate(x, y);
        canvas.clipRect(Rect.fromLTWH(0, 0, tile.width, tile.height));
        cell(canvas);
        canvas.restore();
      }
    }
  }

  // dots: one 1px-radius tinted dot per tile (`radial-gradient(circle, tint
  // 1px, transparent 1px)`; 24×24 layer / 20×20 preview). The gradient
  // defaults to `at center`, so the dot sits at the CENTER of each tile —
  // (12,12) layer / (10,10) preview — not its corner.
  void _paintDots(Canvas canvas, Size size) {
    final p = Paint()..color = _tint(_alpha);
    final step = preview ? 20.0 : 24.0;
    for (double y = 0; y < size.height; y += step) {
      for (double x = 0; x < size.width; x += step) {
        canvas.drawCircle(Offset(x + step / 2, y + step / 2), 1, p);
      }
    }
  }

  // geometric: a 1:1 port of the FIVE stacked repeating `linear-gradient`s —
  // layer: 80×140 tile, alphas .08/.06 (styles-features.css:3250-3258);
  // preview: 40×70 tile, alphas .15/.12 (styles-features.css:3184-3193).
  // Each gradient paints a pair of hard-edged diagonal stripes (CSS stops
  // `c 12%, transparent 12.5%, transparent 87%, c 87.5%` → a band at each END
  // of the gradient line); the four 30°/150° layers (two at offset 0,0 and two
  // phase-shifted by half a tile) interleave into the dense argyle lattice,
  // and a fainter 60° layer (`c 25% … c 75%`) overlays it. Each CSS gradient
  // is reproduced EXACTLY by tiling the same multi-stop `LinearGradient` per
  // cell, with begin/end on the true CSS gradient line for its angle.
  void _paintGeometric(Canvas canvas, Size size) {
    final tw = preview ? 40.0 : 80.0;
    final th = preview ? 70.0 : 140.0;
    final aMain = _tint(preview ? 0.15 : 0.08);
    final aCross = _tint(preview ? 0.12 : 0.06);
    const clear = Colors.transparent;

    // One CSS gradient layer: angle (CSS deg), color, the 4 stop positions,
    // and the tile-phase offset (`background-position`). Painted tiled over
    // [size].
    void layer(
      double degrees,
      Color color,
      List<double> stops,
      double offX,
      double offY,
    ) {
      // CSS angle → screen direction (0deg = up): d = (sinθ, -cosθ). The CSS
      // gradient line runs through the cell center with length
      // L = |w·sinθ| + |h·cosθ|, so the 0%/100% ends map to the alignments
      // ±(dx·L/w, dy·L/h).
      final rad = degrees * math.pi / 180;
      final dx = math.sin(rad), dy = -math.cos(rad);
      final len = (tw * dx).abs() + (th * dy).abs();
      final gradient = LinearGradient(
        begin: Alignment(-dx * len / tw, -dy * len / th),
        end: Alignment(dx * len / tw, dy * len / th),
        colors: [color, clear, clear, color],
        stops: stops,
      );
      final paint = Paint();
      // Tile cells across the canvas, phase-shifted by the CSS
      // background-position.
      for (double y = -th + (offY % th); y < size.height; y += th) {
        for (double x = -tw + (offX % tw); x < size.width; x += tw) {
          final cell = Rect.fromLTWH(x, y, tw, th);
          paint.shader = gradient.createShader(cell);
          canvas.save();
          canvas.clipRect(cell);
          canvas.drawRect(cell, paint);
          canvas.restore();
        }
      }
    }

    const sMain = [0.12, 0.125, 0.87, 0.875];
    const sCross = [0.25, 0.255, 0.75, 0.75];
    layer(30, aMain, sMain, 0, 0);
    layer(150, aMain, sMain, 0, 0);
    layer(30, aMain, sMain, tw / 2, th / 2);
    layer(150, aMain, sMain, tw / 2, th / 2);
    layer(60, aCross, sCross, 0, 0);
  }

  void _strokeShape(Canvas canvas, Path path, double alpha, double width) {
    canvas.drawPath(
      path,
      Paint()
        ..color = _tint(alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width,
    );
  }

  // circuit: inset square, 4 filled corner pads, 4 center stubs, center ring.
  // Layer tile is 80×80 (rect 10→70, pads r2.5, ring r4; stub opacity .85);
  // preview tile is 60×60 (rect 10→50 op .7, pads r2 op .85, stubs op .6,
  // ring r3 op .7) — per the two SVG data-URIs.
  void _circuitTile(Canvas canvas) {
    final a = _alpha;
    if (preview) {
      _strokeShape(canvas,
          Path()..addRect(const Rect.fromLTWH(10, 10, 40, 40)), a * 0.7, 0.5);
      final pad = Paint()..color = _tint(a * 0.85);
      for (final c in const [
        Offset(10, 10), Offset(50, 10), Offset(10, 50), Offset(50, 50),
      ]) {
        canvas.drawCircle(c, 2, pad);
      }
      final stubs = Path()
        ..moveTo(30, 10)..lineTo(30, 25)
        ..moveTo(10, 30)..lineTo(25, 30)
        ..moveTo(30, 50)..lineTo(30, 35)
        ..moveTo(50, 30)..lineTo(35, 30);
      _strokeShape(canvas, stubs, a * 0.6, 0.5);
      _strokeShape(
          canvas,
          Path()..addOval(Rect.fromCircle(center: const Offset(30, 30), radius: 3)),
          a * 0.7,
          0.5);
      return;
    }
    _strokeShape(
        canvas, Path()..addRect(const Rect.fromLTWH(10, 10, 60, 60)), a, 0.5);
    final pad = Paint()..color = _tint(a);
    for (final c in const [
      Offset(10, 10), Offset(70, 10), Offset(10, 70), Offset(70, 70),
    ]) {
      canvas.drawCircle(c, 2.5, pad);
    }
    final stubs = Path()
      ..moveTo(40, 10)..lineTo(40, 30)
      ..moveTo(10, 40)..lineTo(30, 40)
      ..moveTo(40, 70)..lineTo(40, 50)
      ..moveTo(70, 40)..lineTo(50, 40);
    _strokeShape(canvas, stubs, a * 0.85, 0.5);
    _strokeShape(
        canvas,
        Path()..addOval(Rect.fromCircle(center: const Offset(40, 40), radius: 4)),
        a,
        0.5);
  }

  // waves: one quadratic ridge per tile row (layer `M0 12 Q30 0 60 12 Q90 24
  // 120 12`; preview `M0 10 Q25 0 50 10 Q75 20 100 10`), stroke-width 0.8.
  void _wavesTile(Canvas canvas) {
    final p = preview
        ? (Path()
          ..moveTo(0, 10)
          ..quadraticBezierTo(25, 0, 50, 10)
          ..quadraticBezierTo(75, 20, 100, 10))
        : (Path()
          ..moveTo(0, 12)
          ..quadraticBezierTo(30, 0, 60, 12)
          ..quadraticBezierTo(90, 24, 120, 12));
    _strokeShape(canvas, p, _alpha, 0.8);
  }

  // topography: 4 contour strokes per tile with per-path stroke-opacities
  // (layer 120×120: 1/.85/.7/.7; preview 100×100: 1/.8/.6/.7), width 0.7.
  void _topographyTile(Canvas canvas) {
    final a = _alpha;
    Path line(List<double> v) => Path()
      ..moveTo(v[0], v[1])
      ..quadraticBezierTo(v[2], v[3], v[4], v[5])
      ..quadraticBezierTo(v[6], v[7], v[8], v[9]);
    if (preview) {
      _strokeShape(canvas, line([20, 80, 35, 60, 50, 65, 65, 70, 80, 50]), a, 0.7);
      _strokeShape(canvas, line([10, 60, 30, 40, 50, 45, 70, 50, 90, 30]), a * 0.8, 0.7);
      _strokeShape(canvas, line([5, 40, 25, 20, 50, 25, 75, 30, 95, 10]), a * 0.6, 0.7);
      _strokeShape(canvas, line([15, 95, 40, 85, 55, 88, 70, 91, 85, 75]), a * 0.7, 0.7);
      return;
    }
    _strokeShape(canvas, line([20, 100, 40, 75, 60, 80, 80, 85, 100, 60]), a, 0.7);
    _strokeShape(canvas, line([10, 70, 35, 45, 60, 50, 85, 55, 110, 35]), a * 0.85, 0.7);
    _strokeShape(canvas, line([5, 45, 30, 22, 55, 28, 80, 34, 105, 12]), a * 0.7, 0.7);
    _strokeShape(canvas, line([15, 115, 45, 100, 65, 105, 85, 110, 105, 90]), a * 0.7, 0.7);
  }

  // hexagons (56×100 in both variants): two interlocking honeycomb polylines;
  // the second at stroke-opacity .55 (layer) / .6 (preview).
  void _hexagonsTile(Canvas canvas) {
    final a = _alpha;
    Path poly(List<Offset> pts) {
      final p = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final pt in pts.skip(1)) {
        p.lineTo(pt.dx, pt.dy);
      }
      return p;
    }

    _strokeShape(
      canvas,
      poly(const [
        Offset(28, 66), Offset(0, 50), Offset(0, 16), Offset(28, 0),
        Offset(56, 16), Offset(56, 50), Offset(28, 66), Offset(28, 100),
      ]),
      a,
      0.5,
    );
    _strokeShape(
      canvas,
      poly(const [
        Offset(28, 0), Offset(28, 34), Offset(0, 50), Offset(0, 84),
        Offset(28, 100), Offset(56, 84), Offset(56, 50), Offset(28, 34),
      ]),
      a * (preview ? 0.6 : 0.55),
      0.5,
    );
  }

  // diamonds: outer + concentric inner diamond per tile (layer 48×48 r24/r12
  // inner op .55; preview 40×40 r20/r10 inner op .6).
  void _diamondsTile(Canvas canvas) {
    final a = _alpha;
    final r = preview ? 20.0 : 24.0;
    Path diamond(double radius) => Path()
      ..moveTo(r, r - radius)
      ..lineTo(r + radius, r)
      ..lineTo(r, r + radius)
      ..lineTo(r - radius, r)
      ..close();
    _strokeShape(canvas, diamond(r), a, 0.5);
    _strokeShape(canvas, diamond(r / 2), a * (preview ? 0.6 : 0.55), 0.5);
  }

  @override
  bool shouldRepaint(WallpaperPatternPainter old) =>
      old.type != type ||
      old.primary != primary ||
      old.isLight != isLight ||
      old.preview != preview;
}

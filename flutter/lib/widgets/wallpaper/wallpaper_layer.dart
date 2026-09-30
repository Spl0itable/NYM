import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../state/settings_provider.dart';
import '../common/nym_avatar.dart' show proxiedAvatarUrl;
import 'package:http/http.dart' as http;

import 'wallpaper_cache.dart';

enum WallpaperFill { none, pattern, custom }

@immutable
class WallpaperPattern {
  const WallpaperPattern({required this.type, required this.fill});

  final String type;
  final WallpaperFill fill;

  bool get paints => fill != WallpaperFill.none;

  /// Unknown values and `'none'` resolve to the transparent [none] pattern, as in the PWA.
  static WallpaperPattern forType(String? type) {
    if (type == 'custom') {
      return const WallpaperPattern(type: 'custom', fill: WallpaperFill.custom);
    }
    if (type != null && presets.contains(type)) {
      return WallpaperPattern(type: type, fill: WallpaperFill.pattern);
    }
    return const WallpaperPattern(type: 'none', fill: WallpaperFill.none);
  }

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

/// Fire-and-forget fetch through the media proxy into the disk cache so later launches paint locally.
void _warmWallpaperCache(String url) {
  unawaited(WallpaperCache.resolve(url, fetch: (u) async {
    try {
      final res = await http.get(Uri.parse(proxiedAvatarUrl(u) ?? u));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }));
}

class WallpaperLayer extends ConsumerWidget {
  const WallpaperLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch all settings, not a select on the type: a new custom URL keeps type 'custom' and would not rebuild.
    final settings = ref.watch(settingsProvider);
    final pattern = WallpaperPattern.forType(settings.wallpaperType);
    if (!pattern.paints) return const SizedBox.shrink();

    final c = context.nym;

    if (pattern.fill == WallpaperFill.custom) {
      final kv = ref.watch(keyValueStoreProvider);
      final url = kv.getString(StorageKeys.wallpaperCustomUrl);
      if (url == null || url.isEmpty) return const SizedBox.shrink();
      final scrim =
          c.isLight ? const Color(0xD9F5F5F2) : const Color(0xD10A0A0F);
      // A non-http(s) value is a locally picked file path from the Flutter upload flow.
      final isRemote = url.startsWith('http://') || url.startsWith('https://');

      // Prefer the disk-cached copy; Flutter's ImageCache is memory-only, so the url would refetch every cold start.
      final ImageProvider image;
      if (!isRemote) {
        image = FileImage(File(url));
      } else {
        final local = WallpaperCache.cached(url);
        if (local != null) {
          image = FileImage(local);
        } else {
          // Not cached yet: paint via the proxy (hides IP, avoids hotlink 403s) and warm the cache.
          image = NetworkImage(proxiedAvatarUrl(url) ?? url);
          _warmWallpaperCache(url);
        }
      }
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

/// Paints one of the 7 tiled vector wallpaper patterns at full-screen or settings-preview scale.
class WallpaperPatternPainter extends CustomPainter {
  WallpaperPatternPainter({
    required this.type,
    required this.primary,
    required this.isLight,
    this.preview = false,
  });

  final String type;
  final Color primary;
  final bool isLight;

  /// False for the full-screen layer, true for the settings-grid thumbnail.
  final bool preview;

  Color _tint(double a) => primary.withValues(alpha: a);

  double get _alpha {
    switch (type) {
      case 'circuit':
        return preview ? (isLight ? 0.6 : 0.18) : (isLight ? 0.45 : 0.10);
      case 'dots':
        // Preview has no light override; it reads against the white preview background.
        return preview ? 0.15 : (isLight ? 0.40 : 0.10);
      default:
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
        _tiled(canvas, size, preview ? const Size(60, 60) : const Size(80, 80),
            _circuitTile);
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
        _tiled(canvas, size, const Size(56, 100), _hexagonsTile);
      case 'diamonds':
        _tiled(canvas, size, preview ? const Size(40, 40) : const Size(48, 48),
            _diamondsTile);
    }
  }

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

  // The dot sits at the center of each tile, since the CSS radial-gradient defaults to `at center`.
  void _paintDots(Canvas canvas, Size size) {
    final p = Paint()..color = _tint(_alpha);
    final step = preview ? 20.0 : 24.0;
    for (double y = 0; y < size.height; y += step) {
      for (double x = 0; x < size.width; x += step) {
        canvas.drawCircle(Offset(x + step / 2, y + step / 2), 1, p);
      }
    }
  }

  // Port of the five stacked repeating CSS `linear-gradient`s forming the argyle lattice.
  void _paintGeometric(Canvas canvas, Size size) {
    final tw = preview ? 40.0 : 80.0;
    final th = preview ? 70.0 : 140.0;
    final aMain = _tint(preview ? 0.15 : 0.08);
    final aCross = _tint(preview ? 0.12 : 0.06);
    const clear = Colors.transparent;

    void layer(
      double degrees,
      Color color,
      List<double> stops,
      double offX,
      double offY,
    ) {
      // CSS angle to screen direction; the gradient line length is |w·sinθ| + |h·cosθ|.
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

  void _circuitTile(Canvas canvas) {
    final a = _alpha;
    if (preview) {
      _strokeShape(canvas, Path()..addRect(const Rect.fromLTWH(10, 10, 40, 40)),
          a * 0.7, 0.5);
      final pad = Paint()..color = _tint(a * 0.85);
      for (final c in const [
        Offset(10, 10),
        Offset(50, 10),
        Offset(10, 50),
        Offset(50, 50),
      ]) {
        canvas.drawCircle(c, 2, pad);
      }
      final stubs = Path()
        ..moveTo(30, 10)
        ..lineTo(30, 25)
        ..moveTo(10, 30)
        ..lineTo(25, 30)
        ..moveTo(30, 50)
        ..lineTo(30, 35)
        ..moveTo(50, 30)
        ..lineTo(35, 30);
      _strokeShape(canvas, stubs, a * 0.6, 0.5);
      _strokeShape(
          canvas,
          Path()
            ..addOval(Rect.fromCircle(center: const Offset(30, 30), radius: 3)),
          a * 0.7,
          0.5);
      return;
    }
    _strokeShape(
        canvas, Path()..addRect(const Rect.fromLTWH(10, 10, 60, 60)), a, 0.5);
    final pad = Paint()..color = _tint(a);
    for (final c in const [
      Offset(10, 10),
      Offset(70, 10),
      Offset(10, 70),
      Offset(70, 70),
    ]) {
      canvas.drawCircle(c, 2.5, pad);
    }
    final stubs = Path()
      ..moveTo(40, 10)
      ..lineTo(40, 30)
      ..moveTo(10, 40)
      ..lineTo(30, 40)
      ..moveTo(40, 70)
      ..lineTo(40, 50)
      ..moveTo(70, 40)
      ..lineTo(50, 40);
    _strokeShape(canvas, stubs, a * 0.85, 0.5);
    _strokeShape(
        canvas,
        Path()
          ..addOval(Rect.fromCircle(center: const Offset(40, 40), radius: 4)),
        a,
        0.5);
  }

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

  void _topographyTile(Canvas canvas) {
    final a = _alpha;
    Path line(List<double> v) => Path()
      ..moveTo(v[0], v[1])
      ..quadraticBezierTo(v[2], v[3], v[4], v[5])
      ..quadraticBezierTo(v[6], v[7], v[8], v[9]);
    if (preview) {
      _strokeShape(
          canvas, line([20, 80, 35, 60, 50, 65, 65, 70, 80, 50]), a, 0.7);
      _strokeShape(
          canvas, line([10, 60, 30, 40, 50, 45, 70, 50, 90, 30]), a * 0.8, 0.7);
      _strokeShape(
          canvas, line([5, 40, 25, 20, 50, 25, 75, 30, 95, 10]), a * 0.6, 0.7);
      _strokeShape(
          canvas, line([15, 95, 40, 85, 55, 88, 70, 91, 85, 75]), a * 0.7, 0.7);
      return;
    }
    _strokeShape(
        canvas, line([20, 100, 40, 75, 60, 80, 80, 85, 100, 60]), a, 0.7);
    _strokeShape(
        canvas, line([10, 70, 35, 45, 60, 50, 85, 55, 110, 35]), a * 0.85, 0.7);
    _strokeShape(
        canvas, line([5, 45, 30, 22, 55, 28, 80, 34, 105, 12]), a * 0.7, 0.7);
    _strokeShape(canvas, line([15, 115, 45, 100, 65, 105, 85, 110, 105, 90]),
        a * 0.7, 0.7);
  }

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
        Offset(28, 66),
        Offset(0, 50),
        Offset(0, 16),
        Offset(28, 0),
        Offset(56, 16),
        Offset(56, 50),
        Offset(28, 66),
        Offset(28, 100),
      ]),
      a,
      0.5,
    );
    _strokeShape(
      canvas,
      poly(const [
        Offset(28, 0),
        Offset(28, 34),
        Offset(0, 50),
        Offset(0, 84),
        Offset(28, 100),
        Offset(56, 84),
        Offset(56, 50),
        Offset(28, 34),
      ]),
      a * (preview ? 0.6 : 0.55),
      0.5,
    );
  }

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

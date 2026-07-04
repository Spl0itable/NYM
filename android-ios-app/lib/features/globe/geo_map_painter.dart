import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/channel.dart';
import 'geo_projection.dart';
import 'geohash_channel.dart';
import 'topojson.dart';

/// Resolved colors for the map, derived from `context.nym` tokens but mapped to
/// the literal PWA canvas palette (`getMapStyles`) so the globe looks the same
/// regardless of theme. Land/border/graticule come from the dark/light branch of
/// the PWA; primary/warning/joined come from theme tokens.
@immutable
class GeoMapStyle {
  const GeoMapStyle({
    required this.ocean,
    required this.land,
    required this.border,
    required this.adminBorder,
    required this.graticule,
    required this.label,
    required this.adminLabel,
    required this.cityDot,
    required this.cityLabel,
    required this.labelStroke,
    required this.gridLine,
    required this.gridLabel,
    required this.gridLabelStroke,
    required this.daynightFill,
    required this.daynightStroke,
    required this.primary,
    required this.warning,
    required this.joined,
  });

  final Color ocean;
  final Color land;
  final Color border;
  final Color adminBorder;
  final Color graticule;
  final Color label;
  final Color adminLabel;
  final Color cityDot;
  final Color cityLabel;
  final Color labelStroke;
  final Color gridLine;
  final Color gridLabel;
  final Color gridLabelStroke;
  final Color daynightFill;
  final Color daynightStroke;
  final Color primary;
  final Color warning;
  final Color joined;

  /// Builds the style from the active brightness + theme accent colors,
  /// mirroring `getMapStyles()`'s light/dark branches.
  factory GeoMapStyle.resolve({
    required bool isLight,
    required Color primary,
    required Color warning,
  }) {
    return GeoMapStyle(
      ocean: isLight ? const Color(0xFFD6E8F1) : const Color(0xFF0A131E),
      land: isLight ? const Color(0xFFEEF2F4) : const Color(0xFF1C2A39),
      border: isLight ? const Color(0xFF9AAEBA) : const Color(0xFF2C4357),
      // dark: rgba(180,200,220,0.22) -> 0x38 alpha;
      // light: rgba(120,140,160,0.55) -> 0x8C alpha.
      adminBorder:
          isLight ? const Color(0x8C788CA0) : const Color(0x38B4C8DC),
      graticule: isLight
          ? const Color(0x0D000000) // rgba(0,0,0,0.05)
          : const Color(0x0AFFFFFF), // rgba(255,255,255,0.04)
      label: isLight ? const Color(0xD91E2837) : const Color(0xD9DCE8F5),
      // dark: rgba(190,205,220,0.65) -> 0xA6; light: rgba(70,80,95,0.75) -> 0xBF.
      adminLabel:
          isLight ? const Color(0xBF46505F) : const Color(0xA6BECDDC),
      // dark: rgba(220,232,245,0.9) -> 0xE6; light: rgba(60,70,85,0.85) -> 0xD9.
      cityDot: isLight ? const Color(0xD93C4655) : const Color(0xE6DCE8F5),
      // dark: rgba(220,232,245,0.85) -> 0xD9; light: rgba(50,60,75,0.85) -> 0xD9.
      cityLabel: isLight ? const Color(0xD9323C4B) : const Color(0xD9DCE8F5),
      labelStroke: isLight ? const Color(0xD9FFFFFF) : const Color(0xA6000000),
      // dark: rgba(0,220,255,0.35) -> 0x59 alpha; light: rgba(0,100,140,0.45).
      gridLine: isLight ? const Color(0x73006490) : const Color(0x5900DCFF),
      gridLabel: isLight ? const Color(0xD9141E2D) : const Color(0xEBDCF0FF),
      gridLabelStroke:
          isLight ? const Color(0xD9FFFFFF) : const Color(0xB3000000),
      daynightFill: isLight ? const Color(0x47141E37) : const Color(0x80020610),
      daynightStroke:
          isLight ? const Color(0x73283C64) : const Color(0x59B4C8E6),
      primary: primary,
      warning: warning,
      joined: const Color(0xFF28E07A),
    );
  }
}

/// Subsolar point ({lat, lng}) for [date] — a verbatim port of
/// `solarPosition(date)` in geohash-globe.js (drives the day/night terminator).
({double lat, double lng}) solarPosition(DateTime date) {
  const rad = math.pi / 180;
  final n = (date.millisecondsSinceEpoch / 86400000) - 10957.5;
  final L = ((280.46 + 0.9856474 * n) % 360 + 360) % 360;
  final g = ((((357.528 + 0.9856003 * n) % 360 + 360) % 360)) * rad;
  final lambda = (L + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g)) * rad;
  const epsilon = 23.4397 * rad;
  final ra = math.atan2(math.cos(epsilon) * math.sin(lambda), math.cos(lambda));
  final decl = math.asin(math.sin(epsilon) * math.sin(lambda));
  final gmst = (((18.697374558 + 24.06570982441908 * n) % 24) + 24) % 24;
  var lng = (ra / rad) - gmst * 15;
  lng = ((lng % 360) + 540) % 360 - 180;
  return (lat: decl / rad, lng: lng);
}

/// The 256-entry heat gradient palette (`getHeatPalette`): the PWA's exact
/// color stops, sampled to an RGBA lookup keyed by accumulated alpha.
class _HeatPalette {
  _HeatPalette._(this._argb);
  final List<int> _argb; // length 256, non-premultiplied ARGB.

  static _HeatPalette? _cached;
  static _HeatPalette get instance => _cached ??= _build();

  /// The raw alpha-indexed ARGB table (0..255). Mirrors the PWA's 256px palette
  /// canvas (`getHeatPalette`) read back via `getImageData`.
  List<int> get argb => _argb;

  static _HeatPalette _build() {
    // Stops: (offset, r, g, b, a) matching the canvas linear gradient.
    const stops = <List<double>>[
      [0.00, 0, 0, 128, 0.0],
      [0.20, 0, 160, 255, 0.75],
      [0.45, 0, 255, 120, 0.9],
      [0.70, 255, 220, 0, 0.95],
      [1.00, 255, 40, 0, 1.0],
    ];
    final out = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      final t = i / 255.0;
      var lo = stops[0], hi = stops[stops.length - 1];
      for (var s = 0; s < stops.length - 1; s++) {
        if (t >= stops[s][0] && t <= stops[s + 1][0]) {
          lo = stops[s];
          hi = stops[s + 1];
          break;
        }
      }
      final span = (hi[0] - lo[0]);
      final f = span <= 0 ? 0.0 : (t - lo[0]) / span;
      int lerp(int idx) => (lo[idx] + (hi[idx] - lo[idx]) * f).round();
      final r = lerp(1), g = lerp(2), b = lerp(3);
      final a = (lo[4] + (hi[4] - lo[4]) * f) * 255;
      out[i] = (a.round() << 24) | (r << 16) | (g << 8) | b;
    }
    return _HeatPalette._(out);
  }
}

/// Immutable inputs that fully determine a precomputed heatmap image. Used as a
/// cache key so the explorer only rebuilds the `ui.Image` when something that
/// affects it actually changed (view/size/channel activity), matching the PWA's
/// debounced `drawHeatmap`.
@immutable
class HeatmapInput {
  const HeatmapInput({
    required this.view,
    required this.size,
    required this.points,
  });

  final GeoView view;
  final Size size;

  /// (lng, lat, messages) per plotted channel.
  final List<({double lng, double lat, int messages})> points;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! HeatmapInput) return false;
    if (view != other.view || size != other.size) return false;
    if (points.length != other.points.length) return false;
    for (var i = 0; i < points.length; i++) {
      final a = points[i], b = other.points[i];
      if (a.lng != b.lng || a.lat != b.lat || a.messages != b.messages) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        view,
        size,
        points.length,
        // Fold a cheap activity signature so repaints track message changes.
        points.fold<int>(0, (h, p) => h ^ p.messages.hashCode),
      );
}

/// Precomputes the additive-accumulation heatmap as a half-resolution
/// `ui.Image`, a faithful port of `drawHeatmap` (geohash-globe.js:736-797).
///
/// Pipeline (cannot run inside the synchronous `CustomPainter.paint`):
///   1. draw each channel as a **grayscale** radial blob
///      (`rgba(0,0,0,intensity)` → `rgba(0,0,0,0)`) additively (`BlendMode.plus`)
///      into a `(w*0.5, h*0.5)` picture so overlapping alphas SUM;
///   2. rasterize and read back the RGBA bytes;
///   3. per pixel, look up the 256-entry heat palette by the accumulated alpha
///      (`palette.argb[a]`) so dense overlaps climb blue→green→yellow→red;
///   4. `decodeImageFromPixels` back into a `ui.Image` the painter blits to full
///      size with `FilterQuality.low`.
///
/// Returns null when there are no channels (caller clears the image).
Future<ui.Image?> buildHeatmapImage(HeatmapInput input) async {
  final points = input.points;
  if (points.isEmpty) return null;

  const heatScale = 0.5; // HEAT_SCALE
  final size = input.size;
  final view = input.view;
  final w2 = math.max(1, (size.width * heatScale).floor());
  final h2 = math.max(1, (size.height * heatScale).floor());

  // baseRadius = clamp(22,70, 24 + zoom*3.5); radius = baseRadius * HEAT_SCALE.
  final baseRadius = (24 + view.zoom * 3.5).clamp(22.0, 70.0).toDouble();
  final radius = baseRadius * heatScale;

  var maxMsg = 1;
  for (final p in points) {
    if (p.messages > maxMsg) maxMsg = p.messages;
  }
  final denom = math.log(maxMsg + 1) == 0 ? 1.0 : math.log(maxMsg + 1);

  // 1) Accumulate grayscale blobs additively into a half-res picture.
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, w2.toDouble(), h2.toDouble()),
  );
  for (final pt in points) {
    final p = view.project(pt.lng, pt.lat, size);
    final sx = p.dx * heatScale, sy = p.dy * heatScale;
    if (sx < -radius ||
        sx > w2 + radius ||
        sy < -radius ||
        sy > h2 + radius) {
      continue;
    }
    final weight = math.log(pt.messages + 1) / denom;
    final intensity = (0.18 + 0.82 * weight).clamp(0.0, 1.0);
    final a = (intensity * 255).round();
    final center = Offset(sx, sy);
    // Grayscale (black) radial falloff: alpha at center, 0 at the edge. With
    // BlendMode.plus the alpha channel sums across overlapping blobs.
    final shader = ui.Gradient.radial(center, radius, [
      Color.fromARGB(a, 0, 0, 0),
      const Color.fromARGB(0, 0, 0, 0),
    ]);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = shader
        ..blendMode = BlendMode.plus,
    );
  }

  final picture = recorder.endRecording();
  final accum = await picture.toImage(w2, h2);
  picture.dispose();
  final bytes =
      await accum.toByteData(format: ui.ImageByteFormat.rawRgba);
  accum.dispose();
  if (bytes == null) return null;

  // 2/3) Remap each pixel's accumulated alpha through the heat palette.
  final argb = _HeatPalette.instance.argb;
  final data = bytes.buffer.asUint8List();
  for (var i = 0; i < data.length; i += 4) {
    final a = data[i + 3];
    if (a == 0) continue;
    final c = argb[a]; // non-premultiplied ARGB at this accumulated alpha.
    data[i] = (c >> 16) & 0xFF; // R
    data[i + 1] = (c >> 8) & 0xFF; // G
    data[i + 2] = c & 0xFF; // B
    data[i + 3] = (c >> 24) & 0xFF; // A (the palette's own alpha at index `a`)
  }

  // 4) Decode the remapped pixels back into an image.
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    data,
    w2,
    h2,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Paints the equirectangular world map exactly like geohash-globe.js `draw()`:
/// ocean → graticule → countries (evenodd) → labels → heatmap-or-dots →
/// day/night → geohash grid → user location.
class GeoMapPainter extends CustomPainter {
  GeoMapPainter({
    required this.view,
    required this.style,
    required this.features,
    required this.channels,
    required this.heatmap,
    required this.daynight,
    required this.grid,
    this.admin1Features = const [],
    this.cities = const [],
    this.hoveredGeohash,
    this.userLocation,
    this.heatmapImage,
    this.repaint,
  }) : super(repaint: repaint);

  final GeoView view;
  final GeoMapStyle style;
  final List<GeoFeature> features;

  /// Admin-1 (state/province) borders + labels, lazy-loaded once the view
  /// reaches `_admin1ZoomThreshold` (F2/F3). Empty until loaded.
  final List<GeoFeature> admin1Features;

  /// Populated-place dots + labels, lazy-loaded once the view reaches
  /// `_cityZoomThreshold` (F4). Empty until loaded.
  final List<CityPoint> cities;
  final List<GeohashChannelPoint> channels;
  final bool heatmap;
  final bool daynight;
  final bool grid;
  final String? hoveredGeohash;
  final ({double lat, double lng})? userLocation;

  /// Precomputed half-res accumulation+palette heatmap (`buildHeatmapImage`).
  /// Built off the paint pass by the explorer; blitted to full size here.
  final ui.Image? heatmapImage;
  final Listenable? repaint;

  // Zoom thresholds for the lazy detail layers (geohash-globe.js:10-11).
  static const double _admin1ZoomThreshold = 2.5; // ADMIN1_ZOOM_THRESHOLD
  static const double _cityZoomThreshold = 2.5; // CITY_ZOOM_THRESHOLD

  bool _inView(Offset p, double pad, Size size) =>
      p.dx >= -pad &&
      p.dx <= size.width + pad &&
      p.dy >= -pad &&
      p.dy <= size.height + pad;

  @override
  void paint(Canvas canvas, Size size) {
    // Ocean fill.
    canvas.drawRect(Offset.zero & size, Paint()..color = style.ocean);

    _drawGraticule(canvas, size);
    _drawWorld(canvas, size);
    // Admin-1 (state/province) borders fade in from zoom 2.5 (F2), then country
    // labels, then admin-1 labels at zoom >= 4 (F3) — mirrors `draw()` order.
    _drawAdmin1(canvas, size);
    _drawLabels(canvas, size);
    _drawAdmin1Labels(canvas, size);
    if (heatmap) {
      _drawHeatmap(canvas, size);
    } else {
      // City dots + progressive labels (F4) draw under the channel dots.
      _drawCities(canvas, size);
      _drawChannels(canvas, size);
    }
    if (daynight) _drawDaynight(canvas, size);
    if (grid) _drawGrid(canvas, size);
    _drawUserLocation(canvas, size);
  }

  void _drawGraticule(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = style.graticule
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final step = view.zoom > 4 ? 10.0 : 30.0;
    final path = Path();
    for (var lng = -180.0; lng <= 180; lng += step) {
      final a = view.project(lng, 85, size);
      final b = view.project(lng, -85, size);
      path.moveTo(a.dx, a.dy);
      path.lineTo(b.dx, b.dy);
    }
    for (var lat = -60.0; lat <= 60; lat += step) {
      final a = view.project(-180, lat, size);
      final b = view.project(180, lat, size);
      path.moveTo(a.dx, a.dy);
      path.lineTo(b.dx, b.dy);
    }
    canvas.drawPath(path, paint);
  }

  void _drawWorld(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = style.land
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = style.border
      ..strokeWidth = 0.5
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final feat in features) {
      final path = Path()..fillType = PathFillType.evenOdd;
      for (final poly in feat.polygons) {
        for (final ring in poly) {
          if (ring.length < 2) continue;
          var prevLng = ring[0][0];
          final first = view.project(prevLng, ring[0][1], size);
          path.moveTo(first.dx, first.dy);
          for (var i = 1; i < ring.length; i++) {
            final lng = ring[i][0];
            final p = view.project(lng, ring[i][1], size);
            // Avoid drawing the wrap-around seam across the antimeridian.
            if ((lng - prevLng).abs() > 180) {
              path.close();
              path.moveTo(p.dx, p.dy);
            } else {
              path.lineTo(p.dx, p.dy);
            }
            prevLng = lng;
          }
          path.close();
        }
      }
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }
  }

  void _drawLabels(Canvas canvas, Size size) {
    if (features.isEmpty) return;
    for (final feat in features) {
      if (feat.name.isEmpty) continue;
      final bb = feat.bounds;
      final a = view.project(bb[0], bb[3], size);
      final b = view.project(bb[2], bb[1], size);
      final widthPx = (b.dx - a.dx).abs();
      final heightPx = (b.dy - a.dy).abs();
      final span = math.max(widthPx, heightPx);
      final text = feat.name;
      final minSpan = math.max(28.0, text.length * 5.0);
      if (span < minSpan) continue;

      final c = feat.centroid;
      final p = view.project(c[0], c[1], size);
      if (!_inView(p, 40, size)) continue;
      _strokedText(canvas, text, p, 10, style.label, style.labelStroke, 3);
    }
  }

  /// Admin-1 (state/province) borders, faded in over [2.5, 4.0] (F2). Port of
  /// `drawAdmin1` (geohash-globe.js:580-621): stroke `style.adminBorder` width
  /// 0.4, bounds-culled, with the antimeridian seam broken via `moveTo` (NOT
  /// closed — these are open border strokes, unlike the filled world polygons).
  /// The PWA's `globalAlpha = t` is folded into the stroke color's alpha.
  void _drawAdmin1(Canvas canvas, Size size) {
    if (view.zoom < _admin1ZoomThreshold || admin1Features.isEmpty) return;
    const fadeStart = _admin1ZoomThreshold;
    const fadeEnd = fadeStart + 1.5; // [2.5 .. 4.0]
    final t = ((view.zoom - fadeStart) / (fadeEnd - fadeStart)).clamp(0.0, 1.0);
    if (t <= 0) return;

    final stroke = Paint()
      ..color = style.adminBorder.withValues(alpha: style.adminBorder.a * t)
      ..strokeWidth = 0.4
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final path = Path();
    for (final feat in admin1Features) {
      final bb = feat.bounds;
      final a = view.project(bb[0], bb[3], size);
      final b = view.project(bb[2], bb[1], size);
      if (b.dx < -10 ||
          a.dx > size.width + 10 ||
          b.dy < -10 ||
          a.dy > size.height + 10) {
        continue;
      }
      for (final poly in feat.polygons) {
        for (final ring in poly) {
          if (ring.length < 2) continue;
          var prevLng = ring[0][0];
          final first = view.project(prevLng, ring[0][1], size);
          path.moveTo(first.dx, first.dy);
          for (var i = 1; i < ring.length; i++) {
            final lng = ring[i][0];
            final p = view.project(lng, ring[i][1], size);
            if ((lng - prevLng).abs() > 180) {
              path.moveTo(p.dx, p.dy);
            } else {
              path.lineTo(p.dx, p.dy);
            }
            prevLng = lng;
          }
        }
      }
    }
    canvas.drawPath(path, stroke);
  }

  /// Admin-1 labels at zoom >= 4 (F3). Port of `drawAdmin1Labels`
  /// (geohash-globe.js:623-651): weight 500, fontSize 9, fill `style.adminLabel`,
  /// stroke width 2.5, drawn only where the feature's projected span >=
  /// max(40, name.length*5.5).
  void _drawAdmin1Labels(Canvas canvas, Size size) {
    if (view.zoom < 4 || admin1Features.isEmpty) return;
    for (final feat in admin1Features) {
      if (feat.name.isEmpty) continue;
      final bb = feat.bounds;
      final a = view.project(bb[0], bb[3], size);
      final b = view.project(bb[2], bb[1], size);
      final span = math.max((b.dx - a.dx).abs(), (b.dy - a.dy).abs());
      final text = feat.name;
      final minSpan = math.max(40.0, text.length * 5.5);
      if (span < minSpan) continue;

      final c = feat.centroid;
      final p = view.project(c[0], c[1], size);
      if (!_inView(p, 30, size)) continue;
      _strokedText(canvas, text, p, 9, style.adminLabel, style.labelStroke, 2.5,
          weight: FontWeight.w500);
    }
  }

  /// City dots + progressive labels at zoom >= 2.5 (F4). Port of `drawCities`
  /// (geohash-globe.js:653-689): a zoom-stepped `rankCutoff` ladder filters
  /// `cities` by scalerank, 1.5px dots in `style.cityDot`, and at zoom >= 3
  /// left-aligned stroked labels (offset +4px) in `style.cityLabel`.
  void _drawCities(Canvas canvas, Size size) {
    if (view.zoom < _cityZoomThreshold || cities.isEmpty) return;

    // scalerank: 0 = world's largest. Higher zoom -> show smaller cities.
    final rankCutoff = view.zoom < 3
        ? 2
        : view.zoom < 4
            ? 4
            : view.zoom < 6
                ? 6
                : view.zoom < 8
                    ? 8
                    : 10;

    const dotR = 1.5;
    final showLabels = view.zoom >= 3;
    final dotPaint = Paint()..color = style.cityDot;

    for (final city in cities) {
      // cities are rank-sorted ascending; once we pass the cutoff, stop.
      if (city.rank > rankCutoff) break;
      final p = view.project(city.lng, city.lat, size);
      if (!_inView(p, 80, size)) continue;

      canvas.drawCircle(p, dotR, dotPaint);

      if (showLabels && city.name.isNotEmpty) {
        _strokedTextLeft(canvas, city.name, Offset(p.dx + 4, p.dy), 9,
            style.cityLabel, style.labelStroke, 2.5);
      }
    }
  }

  void _drawChannels(Canvas canvas, Size size) {
    const baseR = 4.0;
    for (final ch in channels) {
      final p = view.project(ch.lng, ch.lat, size);
      if (!_inView(p, 12, size)) continue;
      final isHover = hoveredGeohash != null && hoveredGeohash == ch.geohash;
      final r = isHover ? baseR + 2 : baseR;
      final color = ch.isJoined ? style.joined : style.primary;
      canvas.drawCircle(p, r, Paint()..color = color);
      canvas.drawCircle(
        p,
        r,
        Paint()
          ..color = const Color(0x8C000000) // rgba(0,0,0,0.55)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }
  }

  void _drawHeatmap(Canvas canvas, Size size) {
    if (channels.isEmpty) return;

    // Blit the precomputed half-res accumulation+palette image to full size
    // (PWA: `drawImage(heatCanvas, 0,0, cssWidth, cssHeight)` with
    // imageSmoothingQuality='low'). If the image hasn't been built yet (the
    // explorer recomputes it asynchronously on view/activity change) just skip
    // this frame — the next rebuild paints it.
    final img = heatmapImage;
    if (img != null) {
      final src = Rect.fromLTWH(
          0, 0, img.width.toDouble(), img.height.toDouble());
      final dst = Offset.zero & size;
      canvas.drawImageRect(
        img,
        src,
        dst,
        Paint()..filterQuality = FilterQuality.low,
      );
    }

    if (hoveredGeohash != null) {
      for (final ch in channels) {
        if (ch.geohash != hoveredGeohash) continue;
        final p = view.project(ch.lng, ch.lat, size);
        if (_inView(p, 12, size)) {
          canvas.drawCircle(
            p,
            6,
            Paint()
              ..color = const Color(0xFFFFFFFF)
              ..strokeWidth = 2
              ..style = PaintingStyle.stroke,
          );
        }
      }
    }
  }

  void _drawDaynight(Canvas canvas, Size size) {
    final sun = solarPosition(DateTime.now());
    final declRad = sun.lat * math.pi / 180;
    var tanDecl = math.tan(declRad);
    if (tanDecl.abs() < 1e-4) tanDecl = (declRad >= 0 ? 1 : -1) * 1e-4;

    const step = 2.0;
    final points = <Offset>[];
    for (var lng = -180.0; lng <= 180; lng += step) {
      final dLng = (lng - sun.lng) * math.pi / 180;
      final lat = math.atan(-math.cos(dLng) / tanDecl) * 180 / math.pi;
      points.add(view.project(lng, lat, size));
    }
    if (points.isEmpty) return;

    final closeBottom = sun.lat >= 0;
    final yEdge = closeBottom ? size.height + 4 : -4.0;

    final fillPath = Path()..moveTo(points[0].dx, points[0].dy);
    for (var i = 1; i < points.length; i++) {
      fillPath.lineTo(points[i].dx, points[i].dy);
    }
    final last = points.last;
    fillPath.lineTo(last.dx, yEdge);
    fillPath.lineTo(points[0].dx, yEdge);
    fillPath.close();
    canvas.drawPath(fillPath, Paint()..color = style.daynightFill);

    final linePath = Path()..moveTo(points[0].dx, points[0].dy);
    for (var i = 1; i < points.length; i++) {
      linePath.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = style.daynightStroke
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawGrid(Canvas canvas, Size size) {
    final precision = computeGridPrecision(view, size);
    final cell = geohashCellSize(precision);
    final lngStep = cell.lngStep, latStep = cell.latStep;
    final s = view.scale(size);
    final halfLng = (size.width / 2) / s;
    final halfLat = (size.height / 2) / s;
    final lngMin = math.max(-180.0, view.cx - halfLng);
    final lngMax = math.min(180.0, view.cx + halfLng);
    final latMin = math.max(-90.0, view.cy - halfLat);
    final latMax = math.min(90.0, view.cy + halfLat);

    final startGi = ((lngMin + 180) / lngStep).floor();
    final endGi = ((lngMax + 180) / lngStep).ceil();
    final startLi = ((latMin + 90) / latStep).floor();
    final endLi = ((latMax + 90) / latStep).ceil();

    final linePaint = Paint()
      ..color = style.gridLine
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var gi = startGi; gi < endGi; gi++) {
      final lng0 = -180 + gi * lngStep;
      final a = view.project(lng0, latMax, size);
      final b = view.project(lng0, latMin, size);
      path.moveTo(a.dx, a.dy);
      path.lineTo(b.dx, b.dy);
    }
    for (var li = startLi; li < endLi; li++) {
      final lat0 = -90 + li * latStep;
      final a = view.project(lngMin, lat0, size);
      final b = view.project(lngMax, lat0, size);
      path.moveTo(a.dx, a.dy);
      path.lineTo(b.dx, b.dy);
    }
    canvas.drawPath(path, linePaint);

    final cellPxW = lngStep * s;
    final cellPxH = latStep * s;
    if (cellPxW >= 38 && cellPxH >= 22) {
      final fontSize =
          (math.min(cellPxW, cellPxH) / 5).floor().clamp(9, 14).toDouble();
      for (var li = startLi; li < endLi; li++) {
        final cellLat = -90 + li * latStep + latStep / 2;
        if (cellLat < -90 || cellLat > 90) continue;
        for (var gi = startGi; gi < endGi; gi++) {
          final cellLng = -180 + gi * lngStep + lngStep / 2;
          if (cellLng < -180 || cellLng > 180) continue;
          final gh = encodeGeohash(cellLat, cellLng, precision: precision);
          final p = view.project(cellLng, cellLat, size);
          if (!_inView(p, 0, size)) continue;
          _strokedText(canvas, gh, p, fontSize, style.gridLabel,
              style.gridLabelStroke, 3,
              weight: FontWeight.w600);
        }
      }
    }
  }

  void _drawUserLocation(Canvas canvas, Size size) {
    final loc = userLocation;
    if (loc == null) return;
    final p = view.project(loc.lng, loc.lat, size);
    if (!_inView(p, 10, size)) return;
    canvas.drawCircle(p, 5.5, Paint()..color = style.warning);
    canvas.drawCircle(
      p,
      5.5,
      Paint()
        ..color = const Color(0x99000000)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );
  }

  void _strokedText(
    Canvas canvas,
    String text,
    Offset center,
    double fontSize,
    Color fill,
    Color stroke,
    double strokeWidth, {
    FontWeight weight = FontWeight.w600,
  }) {
    TextPainter make(Paint fg) => TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: weight,
              foreground: fg,
            ),
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();

    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..color = stroke;
    final fillPaint = Paint()..color = fill;

    final tpStroke = make(strokePaint);
    final tpFill = make(fillPaint);
    final offset =
        center - Offset(tpFill.width / 2, tpFill.height / 2);
    tpStroke.paint(canvas, offset);
    tpFill.paint(canvas, offset);
  }

  /// Left-aligned, vertically-centered stroked label whose left edge sits at
  /// [anchor].dx and whose vertical middle sits at [anchor].dy — matching the
  /// PWA's `textAlign='left'` + `textBaseline='middle'` city labels.
  void _strokedTextLeft(
    Canvas canvas,
    String text,
    Offset anchor,
    double fontSize,
    Color fill,
    Color stroke,
    double strokeWidth, {
    FontWeight weight = FontWeight.w500,
  }) {
    TextPainter make(Paint fg) => TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: weight,
              foreground: fg,
            ),
          ),
          textAlign: TextAlign.left,
          textDirection: TextDirection.ltr,
        )..layout();

    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..color = stroke;
    final fillPaint = Paint()..color = fill;

    final tpStroke = make(strokePaint);
    final tpFill = make(fillPaint);
    final offset = Offset(anchor.dx, anchor.dy - tpFill.height / 2);
    tpStroke.paint(canvas, offset);
    tpFill.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant GeoMapPainter old) =>
      old.view != view ||
      old.features != features ||
      old.admin1Features != admin1Features ||
      old.cities != cities ||
      old.channels != channels ||
      old.heatmap != heatmap ||
      old.daynight != daynight ||
      old.grid != grid ||
      old.hoveredGeohash != hoveredGeohash ||
      old.userLocation != userLocation ||
      old.heatmapImage != heatmapImage ||
      old.style != style;
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../core/theme/nym_theme.dart';
import '../../models/channel.dart';
import 'geo_detail.dart';
import 'geo_explore.dart';
import 'geo_projection.dart';
import 'geohash_channel.dart';
import 'topojson.dart';

/// Map colors: land, border and graticule use the PWA's literal canvas palette; accents come from theme tokens.
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
    required this.lake,
    required this.river,
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
  final Color lake;
  final Color river;

  factory GeoMapStyle.resolve({
    required bool isLight,
    required Color primary,
    required Color warning,
  }) {
    return GeoMapStyle(
      ocean: isLight ? const Color(0xFFD6E8F1) : const Color(0xFF0A131E),
      land: isLight ? const Color(0xFFEEF2F4) : const Color(0xFF1C2A39),
      border: isLight ? const Color(0xFF9AAEBA) : const Color(0xFF2C4357),
      adminBorder: isLight ? const Color(0x8C788CA0) : const Color(0x38B4C8DC),
      graticule: isLight
          ? const Color(0x0D000000)
          : const Color(0x0AFFFFFF),
      label: isLight ? const Color(0xD91E2837) : const Color(0xD9DCE8F5),
      adminLabel: isLight ? const Color(0xBF46505F) : const Color(0xA6BECDDC),
      cityDot: isLight ? const Color(0xD93C4655) : const Color(0xE6DCE8F5),
      cityLabel: isLight ? const Color(0xD9323C4B) : const Color(0xD9DCE8F5),
      labelStroke: isLight ? const Color(0xD9FFFFFF) : const Color(0xA6000000),
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
      lake: isLight ? const Color(0xFFD6E8F1) : const Color(0xFF0A131E),
      river: isLight ? const Color(0xB35A96BE) : const Color(0x8C4678A0),
    );
  }
}

/// Subsolar point for [date], driving the day/night terminator.
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

/// 256-entry heat gradient palette keyed by accumulated alpha.
class _HeatPalette {
  _HeatPalette._(this._argb);
  final List<int> _argb; // length 256, non-premultiplied ARGB.

  static _HeatPalette? _cached;
  static _HeatPalette get instance => _cached ??= _build();

  /// Raw alpha-indexed ARGB table (0..255).
  List<int> get argb => _argb;

  static _HeatPalette _build() {
    // Stops: (offset, r, g, b, a) of the canvas linear gradient.
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

/// Inputs that fully determine a heatmap image, used as a cache key so it rebuilds only on real changes.
@immutable
class HeatmapInput {
  const HeatmapInput({
    required this.view,
    required this.size,
    required this.points,
    this.dpr = 1,
  });

  final GeoView view;
  final Size size;
  final double dpr;

  final List<({double lng, double lat, int messages})> points;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! HeatmapInput) return false;
    if (view != other.view || size != other.size || dpr != other.dpr) {
      return false;
    }
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
        dpr,
        points.length,
        // Cheap activity signature so repaints track message changes.
        points.fold<int>(0, (h, p) => h ^ p.messages.hashCode),
      );
}

/// Half-res additive heatmap: blobs summed with `BlendMode.plus`, then alpha mapped through the heat palette.
Future<ui.Image?> buildHeatmapImage(HeatmapInput input) async {
  final points = input.points;
  if (points.isEmpty) return null;

  final heatScale = 0.5 * input.dpr;
  final size = input.size;
  final view = input.view;
  final w2 = math.max(1, (size.width * heatScale).floor());
  final h2 = math.max(1, (size.height * heatScale).floor());

  // baseRadius = clamp(22, 70, 24 + zoom*3.5); radius = baseRadius * heatScale.
  final baseRadius = (24 + view.zoom * 3.5).clamp(22.0, 70.0).toDouble();
  final radius = baseRadius * heatScale;

  var maxMsg = 1;
  for (final p in points) {
    if (p.messages > maxMsg) maxMsg = p.messages;
  }
  final denom = math.log(maxMsg + 1) == 0 ? 1.0 : math.log(maxMsg + 1);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, w2.toDouble(), h2.toDouble()),
  );
  for (final pt in points) {
    final p = view.project(pt.lng, pt.lat, size);
    final sx = p.dx * heatScale, sy = p.dy * heatScale;
    if (sx < -radius || sx > w2 + radius || sy < -radius || sy > h2 + radius) {
      continue;
    }
    final weight = math.log(pt.messages + 1) / denom;
    final intensity = (0.18 + 0.82 * weight).clamp(0.0, 1.0);
    final a = (intensity * 255).round();
    final center = Offset(sx, sy);
    // Alpha at center fading to 0; with `BlendMode.plus` alpha sums across overlaps.
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
  final bytes = await accum.toByteData(format: ui.ImageByteFormat.rawRgba);
  accum.dispose();
  if (bytes == null) return null;

  final argb = _HeatPalette.instance.argb;
  final data = bytes.buffer.asUint8List();
  for (var i = 0; i < data.length; i += 4) {
    final a = data[i + 3];
    if (a == 0) continue;
    final c = argb[a]; // non-premultiplied ARGB at this accumulated alpha.
    data[i] = (c >> 16) & 0xFF;
    data[i + 1] = (c >> 8) & 0xFF;
    data[i + 2] = c & 0xFF;
    data[i + 3] = (c >> 24) & 0xFF; // A is the palette's own alpha at index `a`.
  }

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

const double kSelectedRingRadius = 9;

const Color kSavedMarkerColor = Color(0xFFF5C518);

/// Paints the map in the PWA's order: ocean, graticule, countries, labels, heat or dots, day/night, grid, location.
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
    this.selectedGeohash,
    this.selectPulse,
    this.clusters = const [],
    this.recentGeohashes = const {},
    this.ambient,
    this.savedGeohashes = const {},
    this.dpr = 1,
    this.tiers = const [],
    this.tierLabels = const [],
    this.mapSize,
    this.occupied = const [],
  }) : super(repaint: repaint);

  final List<Rect> occupied;

  final double dpr;

  final List<GeoTierPaths?> tiers;

  final List<List<GeoLabelFeature>?> tierLabels;

  final Size? mapSize;

  final String? selectedGeohash;

  final double? selectPulse;

  final List<GeoCluster> clusters;

  final Set<String> recentGeohashes;

  final double? ambient;

  final Set<String> savedGeohashes;

  final GeoView view;
  final GeoMapStyle style;
  final List<GeoFeature> features;

  /// Admin-1 borders and labels, lazy-loaded past `_admin1ZoomThreshold`; empty until loaded.
  final List<GeoFeature> admin1Features;

  /// City dots and labels, lazy-loaded past `_cityZoomThreshold`; empty until loaded.
  final List<CityPoint> cities;
  final List<GeohashChannelPoint> channels;
  final bool heatmap;
  final bool daynight;
  final bool grid;
  final String? hoveredGeohash;
  final ({double lat, double lng})? userLocation;

  /// Precomputed half-res heatmap, blitted to full size here.
  final ui.Image? heatmapImage;
  final Listenable? repaint;

  static const double _admin1ZoomThreshold = 2.5;
  static const double _cityZoomThreshold = 2.5;

  bool _inView(Offset p, double pad, Size size) =>
      p.dx >= -pad &&
      p.dx <= size.width + pad &&
      p.dy >= -pad &&
      p.dy <= size.height + pad;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = style.ocean);

    _drawGraticule(canvas, size);
    _drawWorld(canvas, size);
    _drawAdmin1(canvas, size);
    if (heatmap) {
      _drawPlaceLabels(canvas, size);
      _drawHeatmap(canvas, size);
    } else {
      _drawPlaceLabels(canvas, size);
      _drawSaved(canvas, size);
      _drawRecent(canvas, size);
      _drawChannels(canvas, size);
    }
    if (daynight) _drawDaynight(canvas, size);
    if (grid) _drawGrid(canvas, size);
    _drawSelected(canvas, size);
    _drawUserLocation(canvas, size);
  }

  void _drawSaved(Canvas canvas, Size size) {
    if (savedGeohashes.isEmpty) return;
    final paint = Paint()
      ..color = kSavedMarkerColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final halo = Paint()
      ..color = const Color(0x8C000000)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    for (final gh in savedGeohashes) {
      final b = geoCellBounds(gh);
      if (b == null) continue;
      final p = view.project(
          (b.lngLo + b.lngHi) / 2, (b.latLo + b.latHi) / 2, size);
      if (!_inView(p, 12, size)) continue;
      canvas.drawCircle(p, 7, halo);
      canvas.drawCircle(p, 7, paint);
    }
  }

  void _drawRecent(Canvas canvas, Size size) {
    final t = ambient;
    if (t == null || recentGeohashes.isEmpty) return;
    final paint = Paint()
      ..color = style.primary.withValues(alpha: (1 - t) * 0.6)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final ch in channels) {
      if (!recentGeohashes.contains(ch.geohash)) continue;
      final p = view.project(ch.lng, ch.lat, size);
      if (!_inView(p, 24, size)) continue;
      canvas.drawCircle(p, 5 + 13 * t, paint);
    }
  }

  void _drawSelected(Canvas canvas, Size size) {
    final gh = selectedGeohash;
    if (gh == null) return;
    final b = geoCellBounds(gh);
    if (b == null) return;
    final tl = view.project(b.lngLo, b.latHi, size);
    final br = view.project(b.lngHi, b.latLo, size);
    final rect = Rect.fromPoints(tl, br);
    if (rect.width >= 16 && rect.height >= 12) {
      canvas.drawRect(rect, Paint()..color = style.primary.withValues(alpha: 0.08));
      canvas.drawRect(
        rect,
        Paint()
          ..color = style.primary.withValues(alpha: 0.7)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
    }
    final p = view.project(
        (b.lngLo + b.lngHi) / 2, (b.latLo + b.latHi) / 2, size);
    if (!_inView(p, 40, size)) return;
    final t = selectPulse;
    if (t != null) {
      canvas.drawCircle(
        p,
        kSelectedRingRadius + 22 * t,
        Paint()
          ..color = style.primary.withValues(alpha: (1 - t) * 0.8)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
    canvas.drawCircle(
      p,
      kSelectedRingRadius,
      Paint()
        ..color = const Color(0x99000000)
        ..strokeWidth = 5.5
        ..style = PaintingStyle.stroke,
    );
    canvas.drawCircle(
      p,
      kSelectedRingRadius,
      Paint()
        ..color = const Color(0xE6FFFFFF)
        ..strokeWidth = 3.5
        ..style = PaintingStyle.stroke,
    );
    canvas.drawCircle(
      p,
      kSelectedRingRadius,
      Paint()
        ..color = style.primary
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
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

  int get tier => tierFor(mapSize ?? Size.zero);

  int tierFor(Size size) {
    var t = geoTierFor(view.scale(size));
    while (t > 0 && (t >= tiers.length || tiers[t] == null)) {
      t--;
    }
    return t;
  }

  void _withWorld(Canvas canvas, Size size, void Function(double s) body) {
    final s = view.scale(size);
    canvas.save();
    canvas.translate(size.width / 2 - view.cx * s, size.height / 2 + view.cy * s);
    canvas.scale(s);
    body(s);
    canvas.restore();
  }

  void _drawLayer(Canvas canvas, Size size, GeoLayerPaths lp, double s,
      {Paint? fill, Paint? stroke, Paint? Function(int rank)? strokeFor}) {
    final vb = geoViewBounds(view, size, padPx: 2);
    final layer = lp.layer;
    for (var p = 0; p < layer.partCount; p++) {
      if (!geoPartVisible(layer, p, vb, s, minPx: kGeoMinPartPx)) continue;
      final path = lp.paths[p];
      if (fill != null) canvas.drawPath(path, fill);
      final st = strokeFor != null ? strokeFor(layer.partRank[p]) : stroke;
      if (st != null) canvas.drawPath(path, st);
    }
  }

  void _drawWorld(Canvas canvas, Size size) {
    final t = tierFor(size);
    final tp = t < tiers.length ? tiers[t] : null;
    final countries = tp?.countries ?? geoPathsFor(features);
    if (countries == null) return;
    _withWorld(canvas, size, (s) {
      final fill = Paint()
        ..color = style.land
        ..style = PaintingStyle.fill;
      final stroke = Paint()
        ..color = style.border
        ..strokeWidth = 0.5 / s
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      _drawLayer(canvas, size, countries, s, fill: fill, stroke: stroke);
      if (tp == null) return;
      final lakeFill = Paint()
        ..color = style.lake
        ..style = PaintingStyle.fill;
      final lakeStroke = Paint()
        ..color = style.border.withValues(alpha: style.border.a * 0.8)
        ..strokeWidth = 0.4 / s
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      _drawLayer(canvas, size, tp.lakes, s, fill: lakeFill, stroke: lakeStroke);
      final major = Paint()
        ..color = style.river
        ..strokeWidth = 0.9 / s
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      final minor = Paint()
        ..color = style.river
        ..strokeWidth = 0.6 / s
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      _drawLayer(canvas, size, tp.rivers, s,
          strokeFor: (rank) => rank <= 2 ? major : minor);
    });
  }

  void _drawAdmin1(Canvas canvas, Size size) {
    if (view.zoom < _admin1ZoomThreshold || admin1Features.isEmpty) return;
    const fadeStart = _admin1ZoomThreshold;
    const fadeEnd = fadeStart + 1.5;
    final t = ((view.zoom - fadeStart) / (fadeEnd - fadeStart)).clamp(0.0, 1.0);
    if (t <= 0) return;
    final lp = geoPathsFor(admin1Features, closed: false);
    if (lp == null) return;
    _withWorld(canvas, size, (s) {
      final stroke = Paint()
        ..color = style.adminBorder.withValues(alpha: style.adminBorder.a * t)
        ..strokeWidth = 0.4 / s
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      _drawLayer(canvas, size, lp, s, stroke: stroke);
    });
  }

  List<GeoMapLabel> layoutLabels(Size size) {
    final out = <GeoMapLabel>[];
    final boxes = <GeoLabelBox>[];
    final cands = <GeoMapLabel>[];
    void add(GeoMapLabel? l) {
      if (l == null) return;
      cands.add(l);
      boxes.add(l.box);
    }

    final t = tierFor(size);
    final tl = t > 0 && t < tierLabels.length ? tierLabels[t] : null;
    final countryFeats = tl ??
        [
          for (final f in features)
            GeoLabelFeature(
                name: f.name, bounds: f.bounds, centroid: f.centroid, area: f.area),
        ];
    for (final f in countryFeats) {
      if (f.name.isEmpty) continue;
      final bb = f.bounds;
      final a = view.project(bb[0], bb[3], size);
      final b = view.project(bb[2], bb[1], size);
      final span = math.max((b.dx - a.dx).abs(), (b.dy - a.dy).abs());
      if (span < math.max(28.0, f.name.length * 5.0)) continue;
      final p = view.project(f.centroid[0], f.centroid[1], size);
      if (!_inView(p, 0, size)) continue;
      add(_label(f.name, 'country', p, 11, FontWeight.w600, style.label, 3, size,
          center: true));
    }

    if (!heatmap && view.zoom >= 3 && cities.isNotEmpty) {
      final cutoff = geoCityRankCutoff(view.zoom);
      for (final c in _citiesByPriority(cities)) {
        if (c.rank > cutoff) break;
        if (c.name.isEmpty) continue;
        final p = view.project(c.lng, c.lat, size);
        if (!_inView(p, 0, size)) continue;
        final big = c.rank <= 2;
        add(_label(c.name, 'city', p, big ? 10 : 9,
            big ? FontWeight.w600 : FontWeight.w500, style.cityLabel, 2.5, size,
            center: false));
      }
    }

    if (view.zoom >= 4) {
      for (final f in admin1Features) {
        if (f.name.isEmpty) continue;
        final bb = f.bounds;
        final a = view.project(bb[0], bb[3], size);
        final b = view.project(bb[2], bb[1], size);
        final span = math.max((b.dx - a.dx).abs(), (b.dy - a.dy).abs());
        if (span < math.max(40.0, f.name.length * 5.5)) continue;
        final p = view.project(f.centroid[0], f.centroid[1], size);
        if (!_inView(p, 0, size)) continue;
        add(_label(f.name, 'admin1', p, 9, FontWeight.w500, style.adminLabel,
            2.5, size,
            center: true));
      }
    }

    final blocked = [
      for (final r in occupied) GeoLabelBox(r.left, r.top, r.right, r.bottom),
      for (final k in clusters)
        if (k.count > 1) GeoLabelBox(k.x - k.r, k.y - k.r, k.x + k.r, k.y + k.r),
    ];
    for (final i in placeGeoLabels(boxes, blocked: blocked)) {
      out.add(cands[i]);
    }
    return out;
  }

  GeoMapLabel? _label(String text, String kind, Offset p, double fontSize,
      FontWeight weight, Color color, double halo, Size size,
      {required bool center}) {
    final tp =
        _labelPainters(text, fontSize, weight, color, halo, style.labelStroke);
    final w = tp.$2.width, h = tp.$2.height;
    final box = center
        ? GeoLabelBox(p.dx - w / 2 - 1, p.dy - h / 2, p.dx + w / 2 + 1, p.dy + h / 2)
        : GeoLabelBox(p.dx - 2.5, p.dy - h / 2, p.dx + 4 + w + 1, p.dy + h / 2);
    final fit = fitGeoLabelBox(box,
        anchorX: p.dx, side: !center, width: size.width, height: size.height);
    if (fit == null) return null;
    return GeoMapLabel(
        text: text,
        kind: kind,
        anchor: p,
        box: fit.box,
        center: center,
        flipped: fit.flipped,
        stroke: tp.$1,
        fill: tp.$2);
  }

  void _drawPlaceLabels(Canvas canvas, Size size) {
    if (!heatmap &&
        view.zoom >= _cityZoomThreshold &&
        view.zoom < 3 &&
        cities.isNotEmpty) {
      final dot = Paint()..color = style.cityDot;
      final cutoff = geoCityRankCutoff(view.zoom);
      for (final city in cities) {
        if (city.rank > cutoff) break;
        final p = view.project(city.lng, city.lat, size);
        if (!_inView(p, 4, size)) continue;
        canvas.drawCircle(p, 1.5, dot);
      }
    }
    final dot = Paint()..color = style.cityDot;
    for (final l in layoutLabels(size)) {
      final cy = (l.box.y0 + l.box.y1) / 2;
      if (l.center) {
        final o = Offset((l.box.x0 + l.box.x1) / 2 - l.fill.width / 2,
            cy - l.fill.height / 2);
        l.stroke.paint(canvas, o);
        l.fill.paint(canvas, o);
      } else {
        canvas.drawCircle(l.anchor, 1.5, dot);
        final o = Offset(
            l.flipped ? l.anchor.dx - 4 - l.fill.width : l.anchor.dx + 4,
            cy - l.fill.height / 2);
        l.stroke.paint(canvas, o);
        l.fill.paint(canvas, o);
      }
    }
  }

  void _drawClusterMarker(Canvas canvas, GeoCluster k) {
    final p = Offset(k.x, k.y);
    final r = k.r;
    canvas.drawCircle(p, r + 2, Paint()..color = const Color(0x8C000000));
    canvas.drawCircle(p, r, Paint()..color = style.primary.withValues(alpha: 0.9));
    final tp = TextPainter(
      text: TextSpan(
        text: '${k.count}',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFF000000),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawChannels(Canvas canvas, Size size) {
    const baseR = 4.0;
    final hidden = <String>{};
    for (final k in clusters) {
      if (k.count < 2) continue;
      hidden.addAll(k.ids);
      if (_inView(Offset(k.x, k.y), 24, size)) _drawClusterMarker(canvas, k);
    }
    for (final ch in channels) {
      if (hidden.contains(ch.geohash)) continue;
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
          ..color = const Color(0x8C000000)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }
  }

  void _drawHeatmap(Canvas canvas, Size size) {
    if (channels.isEmpty) return;

    // Skip until the async heatmap build lands; the next rebuild paints it.
    final img = heatmapImage;
    if (img != null) {
      final src =
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
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
    final offset = center - Offset(tpFill.width / 2, tpFill.height / 2);
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
      old.selectedGeohash != selectedGeohash ||
      old.selectPulse != selectPulse ||
      old.clusters != clusters ||
      old.recentGeohashes != recentGeohashes ||
      old.ambient != ambient ||
      old.savedGeohashes != savedGeohashes ||
      old.dpr != dpr ||
      !listEquals(old.tiers, tiers) ||
      !listEquals(old.tierLabels, tierLabels) ||
      !listEquals(old.occupied, occupied) ||
      old.style != style;
}

@immutable
class GeoMapLabel {
  const GeoMapLabel({
    required this.text,
    required this.kind,
    required this.anchor,
    required this.box,
    required this.center,
    required this.stroke,
    required this.fill,
    this.flipped = false,
  });

  final bool flipped;
  final String text;
  final String kind;
  final Offset anchor;
  final GeoLabelBox box;
  final bool center;
  final TextPainter stroke;
  final TextPainter fill;
}

final Expando<GeoLayerPaths> _closedPaths = Expando<GeoLayerPaths>();
final Expando<GeoLayerPaths> _openPaths = Expando<GeoLayerPaths>();

GeoLayerPaths? geoPathsFor(List<GeoFeature> features, {bool closed = true}) {
  if (features.isEmpty) return null;
  final cache = closed ? _closedPaths : _openPaths;
  return cache[features] ??=
      buildGeoLayerPathsSync(geoLayerFromFeatures(features, closed: closed));
}

Future<void> prewarmGeoPaths(List<GeoFeature> features,
    {bool closed = true}) async {
  if (features.isEmpty) return;
  final cache = closed ? _closedPaths : _openPaths;
  if (cache[features] != null) return;
  final built =
      await buildGeoLayerPaths(geoLayerFromFeatures(features, closed: closed));
  cache[features] ??= built;
}

final Expando<List<CityPoint>> _cityOrder = Expando<List<CityPoint>>();

List<CityPoint> _citiesByPriority(List<CityPoint> cities) =>
    _cityOrder[cities] ??= ([...cities]..sort((a, b) {
        final r = a.rank.compareTo(b.rank);
        return r != 0 ? r : b.pop.compareTo(a.pop);
      }));

final Map<String, (TextPainter, TextPainter)> _labelCache = {};

(TextPainter, TextPainter) _labelPainters(String text, double fontSize,
    FontWeight weight, Color color, double halo, Color haloColor) {
  final key =
      '$text|$fontSize|${weight.value}|${color.toARGB32()}|$halo|${haloColor.toARGB32()}';
  final hit = _labelCache[key];
  if (hit != null) return hit;
  if (_labelCache.length > 1500) _labelCache.clear();
  TextPainter make(Paint fg) => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
              fontFamily: kSansFont,
              fontSize: fontSize,
              fontWeight: weight,
              foreground: fg),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
  final stroke = make(Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = halo
    ..strokeJoin = StrokeJoin.round
    ..color = haloColor);
  final fill = make(Paint()..color = color);
  final out = (stroke, fill);
  _labelCache[key] = out;
  return out;
}

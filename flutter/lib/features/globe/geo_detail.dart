import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'geo_projection.dart';
import 'topojson.dart';

const List<String> kGeoTierAssets = [
  kWorldTopoAsset,
  'assets/data/geo-detail-50m.json',
  'assets/data/geo-detail-10m.json',
];

@immutable
class GeoLayer {
  const GeoLayer({
    required this.coords,
    required this.ringOff,
    required this.partRing,
    required this.bbox,
    required this.partLen,
    required this.partRank,
    required this.closed,
  });

  final Float32List coords;
  final Int32List ringOff;
  final Int32List partRing;
  final Float32List bbox;
  final Float32List partLen;
  final Int32List partRank;
  final bool closed;

  int get partCount => partRing.length - 1;
  int get pointCount => coords.length ~/ 2;

  int partPoints(int p) => ringOff[partRing[p + 1]] - ringOff[partRing[p]];

  static final GeoLayer empty = GeoLayer(
    coords: Float32List(0),
    ringOff: Int32List.fromList(const [0]),
    partRing: Int32List.fromList(const [0]),
    bbox: Float32List(0),
    partLen: Float32List(0),
    partRank: Int32List(0),
    closed: true,
  );
}

@immutable
class GeoLabelFeature {
  const GeoLabelFeature({
    required this.name,
    required this.bounds,
    required this.centroid,
    required this.area,
  });

  final String name;
  final List<double> bounds;
  final List<double> centroid;
  final double area;
}

@immutable
class GeoTierGeometry {
  const GeoTierGeometry({
    required this.countries,
    required this.lakes,
    required this.rivers,
    required this.countryLabels,
  });

  final GeoLayer countries;
  final GeoLayer lakes;
  final GeoLayer rivers;
  final List<GeoLabelFeature> countryLabels;
}

class _LayerBuilder {
  _LayerBuilder(this.closed);
  final bool closed;
  final List<double> coords = [];
  final List<int> ringOff = [0];
  final List<int> partRing = [0];
  final List<double> bbox = [];
  final List<double> partLen = [];
  final List<int> partRank = [];

  void addPart(List<List<List<double>>> rings, int rank) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    var len = 0.0;
    var added = 0;
    for (final ring in rings) {
      if (ring.length < 2) continue;
      for (var i = 0; i < ring.length; i++) {
        final x = ring[i][0], y = ring[i][1];
        coords
          ..add(x)
          ..add(y);
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        if (i > 0) {
          final dx = x - ring[i - 1][0];
          if (dx.abs() <= 180) {
            len += math.sqrt(dx * dx + math.pow(y - ring[i - 1][1], 2));
          }
        }
      }
      ringOff.add(coords.length ~/ 2);
      added++;
    }
    if (added == 0) return;
    partRing.add(ringOff.length - 1);
    bbox.addAll([minX, minY, maxX, maxY]);
    partLen.add(len);
    partRank.add(rank);
  }

  GeoLayer build() => GeoLayer(
        coords: Float32List.fromList(coords),
        ringOff: Int32List.fromList(ringOff),
        partRing: Int32List.fromList(partRing),
        bbox: Float32List.fromList(bbox),
        partLen: Float32List.fromList(partLen),
        partRank: Int32List.fromList(partRank),
        closed: closed,
      );
}

GeoLayer geoLayerFromFeatures(List<GeoFeature> features, {bool closed = true}) {
  final b = _LayerBuilder(closed);
  for (final f in features) {
    for (final poly in f.polygons) {
      b.addPart(poly, 0);
    }
  }
  return b.build();
}

GeoTierGeometry decodeGeoTier(String jsonString) {
  final topo = json.decode(jsonString) as Map<String, dynamic>;
  final tx = (topo['transform'] as Map?) ?? const {};
  final scale = (tx['scale'] as List?) ?? const [1, 1];
  final translate = (tx['translate'] as List?) ?? const [0, 0];
  final sx = (scale[0] as num).toDouble(), sy = (scale[1] as num).toDouble();
  final dx = (translate[0] as num).toDouble(), dy = (translate[1] as num).toDouble();
  final arcs = <List<List<double>>>[];
  for (final a in topo['arcs'] as List) {
    var x = 0, y = 0;
    final pts = <List<double>>[];
    for (final d in a as List) {
      x += (d[0] as num).toInt();
      y += (d[1] as num).toInt();
      pts.add([x * sx + dx, y * sy + dy]);
    }
    arcs.add(pts);
  }
  List<List<double>> stitch(List idxs) {
    final out = <List<double>>[];
    for (var i = 0; i < idxs.length; i++) {
      final k = (idxs[i] as num).toInt();
      final a = k >= 0 ? arcs[k] : arcs[~k].reversed.toList();
      out.addAll(i == 0 ? a : a.skip(1));
    }
    return out;
  }

  final objects = (topo['objects'] as Map?) ?? const {};
  List geoms(String name) =>
      ((objects[name] as Map?)?['geometries'] as List?) ?? const [];
  int rankOf(Map g) =>
      (((g['properties'] as Map?)?['rank']) as num?)?.toInt() ?? 0;

  final countries = _LayerBuilder(true);
  final lakes = _LayerBuilder(true);
  final rivers = _LayerBuilder(false);
  final labels = <GeoLabelFeature>[];
  for (final (name, builder) in [('countries', countries), ('lakes', lakes)]) {
    for (final g in geoms(name)) {
      final m = g as Map;
      final type = m['type'];
      final polys = type == 'Polygon'
          ? [m['arcs'] as List]
          : type == 'MultiPolygon'
              ? (m['arcs'] as List).cast<List>()
              : const <List>[];
      final rings = <List<List<List<double>>>>[];
      for (final p in polys) {
        final poly = [for (final r in p) stitch(r as List)];
        builder.addPart(poly, rankOf(m));
        rings.add(poly);
      }
      if (name == 'countries' && rings.isNotEmpty) {
        final label = (m['properties'] as Map?)?['name'] as String? ?? '';
        if (label.isNotEmpty) labels.add(_labelFeature(label, rings));
      }
    }
  }
  for (final g in geoms('rivers')) {
    final m = g as Map;
    final type = m['type'];
    final lines = type == 'LineString'
        ? [m['arcs'] as List]
        : type == 'MultiLineString'
            ? (m['arcs'] as List).cast<List>()
            : const <List>[];
    rivers.addPart([for (final l in lines) stitch(l)], rankOf(m));
  }
  labels.sort((a, b) => b.area.compareTo(a.area));
  return GeoTierGeometry(
    countries: countries.build(),
    lakes: lakes.build(),
    rivers: rivers.build(),
    countryLabels: labels,
  );
}

GeoLabelFeature _labelFeature(
    String name, List<List<List<List<double>>>> polys) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  List<List<double>>? largest;
  var largestArea = -1.0;
  for (final poly in polys) {
    if (poly.isEmpty) continue;
    final outer = poly[0];
    var a = 0.0;
    for (var i = 0; i < outer.length - 1; i++) {
      a += outer[i][0] * outer[i + 1][1] - outer[i + 1][0] * outer[i][1];
    }
    a = (a / 2).abs();
    if (a > largestArea) {
      largestArea = a;
      largest = outer;
    }
    for (final ring in poly) {
      for (final p in ring) {
        if (p[0] < minX) minX = p[0];
        if (p[0] > maxX) maxX = p[0];
        if (p[1] < minY) minY = p[1];
        if (p[1] > maxY) maxY = p[1];
      }
    }
  }
  var cx = 0.0, cy = 0.0;
  if (largest != null && largest.isNotEmpty) {
    for (final p in largest) {
      cx += p[0];
      cy += p[1];
    }
    cx /= largest.length;
    cy /= largest.length;
  }
  return GeoLabelFeature(
    name: name,
    bounds: [minX, minY, maxX, maxY],
    centroid: [cx, cy],
    area: largestArea,
  );
}

({double lngLo, double lngHi, double latLo, double latHi}) geoViewBounds(
    GeoView view, ui.Size size,
    {double padPx = 0}) {
  final s = view.scale(size);
  final hw = (size.width / 2 + padPx) / s, hh = (size.height / 2 + padPx) / s;
  return (
    lngLo: view.cx - hw,
    lngHi: view.cx + hw,
    latLo: view.cy - hh,
    latHi: view.cy + hh,
  );
}

bool geoPartVisible(GeoLayer layer, int p,
    ({double lngLo, double lngHi, double latLo, double latHi}) vb, double s,
    {double minPx = 0}) {
  final o = p * 4;
  final x0 = layer.bbox[o], y0 = layer.bbox[o + 1];
  final x1 = layer.bbox[o + 2], y1 = layer.bbox[o + 3];
  if (x1 < vb.lngLo || x0 > vb.lngHi || y1 < vb.latLo || y0 > vb.latHi) {
    return false;
  }
  if (minPx > 0 && (x1 - x0) * s < minPx && (y1 - y0) * s < minPx) {
    return false;
  }
  return true;
}

int geoVerticesInView(GeoLayer layer, GeoView view, ui.Size size) {
  final vb = geoViewBounds(view, size);
  final s = view.scale(size);
  var n = 0;
  for (var p = 0; p < layer.partCount; p++) {
    if (geoPartVisible(layer, p, vb, s, minPx: kGeoMinPartPx)) {
      n += layer.partPoints(p);
    }
  }
  return n;
}

double geoSegmentPxInView(GeoLayer layer, GeoView view, ui.Size size) {
  final vb = geoViewBounds(view, size);
  final s = view.scale(size);
  var len = 0.0;
  var segs = 0;
  for (var p = 0; p < layer.partCount; p++) {
    if (!geoPartVisible(layer, p, vb, s, minPx: kGeoMinPartPx)) continue;
    len += layer.partLen[p];
    segs += layer.partPoints(p) - (layer.partRing[p + 1] - layer.partRing[p]);
  }
  return segs == 0 ? 0 : len * s / segs;
}

const double kGeoMinPartPx = 0.6;

class GeoLayerPaths {
  GeoLayerPaths(this.layer, this.paths);
  final GeoLayer layer;
  final List<ui.Path> paths;
}

@immutable
class GeoTierPaths {
  const GeoTierPaths({
    required this.countries,
    required this.lakes,
    required this.rivers,
  });

  final GeoLayerPaths countries;
  final GeoLayerPaths lakes;
  final GeoLayerPaths rivers;
}

ui.Path geoPartPath(GeoLayer layer, int p) {
  final path = ui.Path()..fillType = ui.PathFillType.evenOdd;
  final c = layer.coords;
  for (var r = layer.partRing[p]; r < layer.partRing[p + 1]; r++) {
    final a = layer.ringOff[r], b = layer.ringOff[r + 1];
    if (b - a < 2) continue;
    var prev = c[a * 2];
    path.moveTo(prev, -c[a * 2 + 1]);
    for (var i = a + 1; i < b; i++) {
      final x = c[i * 2], y = -c[i * 2 + 1];
      if ((x - prev).abs() > 180) {
        if (layer.closed) path.close();
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      prev = x;
    }
    if (layer.closed) path.close();
  }
  return path;
}

Future<GeoLayerPaths> buildGeoLayerPaths(GeoLayer layer,
    {int pointsPerSlice = 40000}) async {
  final paths = <ui.Path>[];
  var budget = 0;
  for (var p = 0; p < layer.partCount; p++) {
    paths.add(geoPartPath(layer, p));
    budget += layer.partPoints(p);
    if (budget >= pointsPerSlice) {
      budget = 0;
      await Future<void>.delayed(Duration.zero);
    }
  }
  return GeoLayerPaths(layer, paths);
}

GeoLayerPaths buildGeoLayerPathsSync(GeoLayer layer) => GeoLayerPaths(
    layer, [for (var p = 0; p < layer.partCount; p++) geoPartPath(layer, p)]);

Future<GeoTierPaths> buildGeoTierPaths(GeoTierGeometry g) async =>
    GeoTierPaths(
      countries: await buildGeoLayerPaths(g.countries),
      lakes: await buildGeoLayerPaths(g.lakes),
      rivers: await buildGeoLayerPaths(g.rivers),
    );

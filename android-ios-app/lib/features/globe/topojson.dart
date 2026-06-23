import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A render-ready country feature: a list of polygons, each polygon a list of
/// rings, each ring a flat list of [lon, lat] pairs. Mirrors the shape produced
/// by `js/geo-decode.js` `decodeWorld` (Polygon/MultiPolygon collapsed into a
/// uniform `polygons` list) plus the per-feature bounds/centroid/area
/// annotation used for label placement and area sorting.
@immutable
class GeoFeature {
  const GeoFeature({
    required this.name,
    required this.polygons,
    required this.bounds,
    required this.centroid,
    required this.area,
  });

  /// Country name (`properties.name`), '' if absent.
  final String name;

  /// polygon -> ring -> list of [lon, lat] points.
  final List<List<List<List<double>>>> polygons;

  /// [minLng, minLat, maxLng, maxLat].
  final List<double> bounds;

  /// [lng, lat] centroid of the largest ring.
  final List<double> centroid;

  /// Absolute area of the largest ring (in squared degrees).
  final double area;
}

/// Decodes the bundled `countries-110m.json` (world-atlas TopoJSON) into a list
/// of [GeoFeature], sorted largest-area first — a faithful Dart port of
/// `decodeTopoJson` + `annotateFeature` + `decodeWorld` from `js/geo-decode.js`.
///
/// [jsonString] is the raw asset text. Pure (no Flutter bindings), so it can
/// run inside a `compute`/Isolate off the UI thread.
List<GeoFeature> decodeWorldTopoJson(String jsonString) {
  final topo = json.decode(jsonString) as Map<String, dynamic>;
  return _decodeWorld(topo);
}

List<GeoFeature> _decodeWorld(Map<String, dynamic> topo) {
  // Quantization transform: x_real = x*scale + translate (delta-decoded arcs).
  final tx = (topo['transform'] as Map?) ?? const {};
  final scale = (tx['scale'] as List?) ?? const [1, 1];
  final translate = (tx['translate'] as List?) ?? const [0, 0];
  final sx = (scale[0] as num).toDouble();
  final sy = (scale[1] as num).toDouble();
  final dx = (translate[0] as num).toDouble();
  final dy = (translate[1] as num).toDouble();

  // Delta-decode + dequantize each arc into absolute [lon, lat] points.
  final rawArcs = <List<List<double>>>[];
  for (final arc in (topo['arcs'] as List)) {
    var x = 0.0;
    var y = 0.0;
    final pts = <List<double>>[];
    for (final p in (arc as List)) {
      x += (p[0] as num).toDouble();
      y += (p[1] as num).toDouble();
      pts.add([x * sx + dx, y * sy + dy]);
    }
    rawArcs.add(pts);
  }

  // Arc lookup: negative index i means reversed arc ~i.
  List<List<double>> arcAt(int i) {
    if (i >= 0) return rawArcs[i];
    return rawArcs[~i].reversed.toList();
  }

  // Stitch a ring's arc indices into one continuous point list (dropping the
  // shared first vertex on each subsequent arc).
  List<List<double>> stitchRing(List arcIdxs) {
    final out = <List<double>>[];
    for (var i = 0; i < arcIdxs.length; i++) {
      final a = arcAt(arcIdxs[i] as int);
      if (i > 0) {
        for (var j = 1; j < a.length; j++) {
          out.add(a[j]);
        }
      } else {
        out.addAll(a);
      }
    }
    return out;
  }

  List<List<List<double>>> buildPolygon(List rings) =>
      [for (final r in rings) stitchRing(r as List)];

  final objects = topo['objects'] as Map<String, dynamic>;
  final obj = (objects['countries'] ?? objects[objects.keys.first])
      as Map<String, dynamic>;
  final geoms = obj['type'] == 'GeometryCollection'
      ? (obj['geometries'] as List)
      : [obj];

  final features = <GeoFeature>[];
  for (final g in geoms) {
    final gm = g as Map<String, dynamic>;
    final props = (gm['properties'] as Map?) ?? const {};
    final name = (props['name'] as String?) ?? '';
    final type = gm['type'];
    List<List<List<List<double>>>> polys;
    if (type == 'Polygon') {
      polys = [buildPolygon(gm['arcs'] as List)];
    } else if (type == 'MultiPolygon') {
      polys = [for (final p in (gm['arcs'] as List)) buildPolygon(p as List)];
    } else {
      continue;
    }
    features.add(_annotate(name, polys));
  }

  features.sort((a, b) => b.area.compareTo(a.area));
  return features;
}

double _ringSignedArea(List<List<double>> ring) {
  var a = 0.0;
  for (var i = 0, n = ring.length - 1; i < n; i++) {
    a += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1];
  }
  return a / 2;
}

GeoFeature _annotate(String name, List<List<List<List<double>>>> polys) {
  var minLng = double.infinity,
      maxLng = double.negativeInfinity,
      minLat = double.infinity,
      maxLat = double.negativeInfinity;
  List<List<double>>? largestRing;
  var largestArea = double.negativeInfinity;

  for (final poly in polys) {
    if (poly.isEmpty) continue;
    final outer = poly[0];
    final area = _ringSignedArea(outer).abs();
    if (area > largestArea) {
      largestArea = area;
      largestRing = outer;
    }
    for (final ring in poly) {
      for (final pt in ring) {
        final lng = pt[0], lat = pt[1];
        if (lng < minLng) minLng = lng;
        if (lng > maxLng) maxLng = lng;
        if (lat < minLat) minLat = lat;
        if (lat > maxLat) maxLat = lat;
      }
    }
  }

  var cx = 0.0, cy = 0.0;
  if (largestRing != null && largestRing.isNotEmpty) {
    for (final pt in largestRing) {
      cx += pt[0];
      cy += pt[1];
    }
    cx /= largestRing.length;
    cy /= largestRing.length;
  }

  return GeoFeature(
    name: name,
    polygons: polys,
    bounds: [minLng, minLat, maxLng, maxLat],
    centroid: [cx, cy],
    area: largestArea.isFinite ? largestArea : 0,
  );
}

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Render-ready country feature with polygons of [lon, lat] rings plus bounds, centroid and area.
@immutable
class GeoFeature {
  const GeoFeature({
    required this.name,
    required this.polygons,
    required this.bounds,
    required this.centroid,
    required this.area,
  });

  final String name;

  /// polygon -> ring -> [lon, lat] points.
  final List<List<List<List<double>>>> polygons;

  /// [minLng, minLat, maxLng, maxLat].
  final List<double> bounds;

  /// [lng, lat] centroid of the largest ring.
  final List<double> centroid;

  /// Absolute area of the largest ring, in squared degrees.
  final double area;
}

/// Render-ready city point; the globe filters by [rank] against a zoom cutoff.
@immutable
class CityPoint {
  const CityPoint({
    required this.lng,
    required this.lat,
    required this.name,
    required this.rank,
    required this.pop,
  });

  final double lng;
  final double lat;

  final String name;

  /// `scalerank` (0 = largest); higher zoom reveals higher ranks; defaults to 10.
  final int rank;

  /// `pop_max` (or `pop_min`), 0 if absent.
  final int pop;
}

/// Bundled world TopoJSON, shared by the globe and the place-name fallback.
const String kWorldTopoAsset = 'assets/data/countries-110m.json';

/// Decodes the world TopoJSON into features, largest area first; pure, so it can run in an isolate.
List<GeoFeature> decodeWorldTopoJson(String jsonString) {
  final topo = json.decode(jsonString) as Map<String, dynamic>;
  return _decodeWorld(topo);
}

/// Decodes the admin-1 GeoJSON (~1.7 MB), largest area first; decode it off the UI thread.
List<GeoFeature> decodeAdmin1GeoJson(String jsonString) {
  final geo = json.decode(jsonString) as Map<String, dynamic>;
  return _decodeAdmin1(geo);
}

/// Decodes populated places, sorted by ascending rank; pure, so it can run in an isolate.
List<CityPoint> decodeCitiesGeoJson(String jsonString) {
  final geo = json.decode(jsonString) as Map<String, dynamic>;
  return _decodeCities(geo);
}

List<GeoFeature> _decodeAdmin1(Map<String, dynamic> geo) {
  final featuresJson = geo['features'];
  if (featuresJson is! List) return const [];

  final feats = <GeoFeature>[];
  for (final f in featuresJson) {
    if (f is! Map) continue;
    final geom = f['geometry'];
    if (geom is! Map) continue;
    final props = (f['properties'] as Map?) ?? const {};
    final name =
        (props['name'] as String?) ?? (props['name_en'] as String?) ?? '';
    final type = geom['type'];
    final coords = geom['coordinates'];
    List<List<List<List<double>>>> polys;
    if (type == 'Polygon') {
      polys = [_coordsToPolygon(coords as List)];
    } else if (type == 'MultiPolygon') {
      polys = [for (final p in (coords as List)) _coordsToPolygon(p as List)];
    } else {
      continue;
    }
    feats.add(_annotate(name, polys));
  }

  feats.sort((a, b) => b.area.compareTo(a.area));
  return feats;
}

List<CityPoint> _decodeCities(Map<String, dynamic> geo) {
  final featuresJson = geo['features'];
  if (featuresJson is! List) return const [];

  final out = <CityPoint>[];
  for (final f in featuresJson) {
    if (f is! Map) continue;
    final geom = f['geometry'];
    final coords = geom is Map ? geom['coordinates'] : null;
    if (coords is! List || coords.length < 2) continue;
    final props = (f['properties'] as Map?) ?? const {};

    final rankRaw = props['scalerank'] ?? props['SCALERANK'];
    final rank = rankRaw is num ? rankRaw.toInt() : 10;

    final popRaw = props['pop_max'] ?? props['POP_MAX'] ?? props['pop_min'];
    final pop = popRaw is num ? popRaw.toInt() : 0;

    out.add(CityPoint(
      lng: (coords[0] as num).toDouble(),
      lat: (coords[1] as num).toDouble(),
      name: (props['name'] as String?) ?? (props['NAME'] as String?) ?? '',
      rank: rank,
      pop: pop,
    ));
  }

  out.sort((a, b) => a.rank.compareTo(b.rank));
  return out;
}

List<List<List<double>>> _coordsToPolygon(List rings) => [
      for (final ring in rings)
        [
          for (final pt in (ring as List))
            [(pt[0] as num).toDouble(), (pt[1] as num).toDouble()],
        ],
    ];

List<GeoFeature> _decodeWorld(Map<String, dynamic> topo) {
  // Quantization transform: real = x*scale + translate, arcs delta-encoded.
  final tx = (topo['transform'] as Map?) ?? const {};
  final scale = (tx['scale'] as List?) ?? const [1, 1];
  final translate = (tx['translate'] as List?) ?? const [0, 0];
  final sx = (scale[0] as num).toDouble();
  final sy = (scale[1] as num).toDouble();
  final dx = (translate[0] as num).toDouble();
  final dy = (translate[1] as num).toDouble();

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

  // Negative index i means reversed arc ~i.
  List<List<double>> arcAt(int i) {
    if (i >= 0) return rawArcs[i];
    return rawArcs[~i].reversed.toList();
  }

  // Drops the shared first vertex on each subsequent arc.
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
  final geoms =
      obj['type'] == 'GeometryCollection' ? (obj['geometries'] as List) : [obj];

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

/// Ray-casting point-in-polygon over one ring.
bool _pointInRing(List<List<double>> ring, double lng, double lat) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i][0], yi = ring[i][1];
    final xj = ring[j][0], yj = ring[j][1];
    final dy = (yj - yi) == 0 ? 1e-12 : (yj - yi);
    if ((yi > lat) != (yj > lat) && lng < (xj - xi) * (lat - yi) / dy + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/// Inside the outer ring and outside every hole.
bool pointInFeature(GeoFeature feat, double lng, double lat) {
  final b = feat.bounds;
  if (b.length == 4 &&
      (lng < b[0] || lng > b[2] || lat < b[1] || lat > b[3])) {
    return false;
  }
  for (final poly in feat.polygons) {
    if (poly.isEmpty || !_pointInRing(poly[0], lng, lat)) continue;
    var inHole = false;
    for (var h = 1; h < poly.length; h++) {
      if (_pointInRing(poly[h], lng, lat)) {
        inHole = true;
        break;
      }
    }
    if (!inHole) return true;
  }
  return false;
}

/// Country containing the point, or ''; walked smallest-first so enclaves win.
String countryAt(List<GeoFeature> features, double lat, double lng) {
  for (var i = features.length - 1; i >= 0; i--) {
    if (pointInFeature(features[i], lng, lat)) return features[i].name;
  }
  return '';
}

double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0, rad = math.pi / 180;
  final dLat = (lat2 - lat1) * rad, dLng = (lng2 - lng1) * rad;
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * rad) *
          math.cos(lat2 * rad) *
          math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}

/// Nearest country at sea, measured to the nearest vertex, which is accurate enough at 110m.
({String name, double km}) nearestCountry(
    List<GeoFeature> features, double lat, double lng) {
  var best = '';
  var bestKm = double.infinity;
  for (final feat in features) {
    final b = feat.bounds;
    if (b.length == 4) {
      // Cheap reject when even the nearest bbox latitude edge is farther than the best so far.
      final dLat = lat < b[1] ? b[1] - lat : (lat > b[3] ? lat - b[3] : 0.0);
      if (dLat * 111 > bestKm) continue;
    }
    for (final poly in feat.polygons) {
      for (final ring in poly) {
        for (final pt in ring) {
          final km = _haversineKm(lat, lng, pt[1], pt[0]);
          if (km < bestKm) {
            bestKm = km;
            best = feat.name;
          }
        }
      }
    }
  }
  return (name: best, km: bestKm);
}

/// Describes an unnamed place from shipped map data, never coordinates; must agree with the PWA's `describeRegion`.
String describeRegion(List<GeoFeature> features, double lat, double lng) {
  if (features.isEmpty) return '';
  final land = countryAt(features, lat, lng);
  if (land.isNotEmpty) return land;
  // Natural Earth's Antarctica ring is clipped near -85.6, so everything below is continent.
  if (lat <= -85.5) return 'Antarctica';
  // Proximity before polar names, so near-coast points name the coast.
  final near = nearestCountry(features, lat, lng);
  if (near.name.isNotEmpty && near.km <= 300) {
    return 'Off the coast of ${near.name}';
  }
  if (lat >= 66.5) return 'Arctic Ocean';
  if (lat <= -60) return 'Southern Ocean';
  if (near.name.isNotEmpty && near.km <= 1200) return 'Ocean near ${near.name}';
  return 'Open ocean';
}

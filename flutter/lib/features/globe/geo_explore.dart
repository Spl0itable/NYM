import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Size;

import 'topojson.dart';

const String kGeoBase32 = '0123456789bcdefghjkmnpqrstuvwxyz';
const List<int> kGeoWindowOptions = [1, 24, 168];
const int kGeoClusterCellPx = 48;
const int kGeoClusterGridZoom = 4;
const int kGeoClusterSeedPx = 6;
const int kGeoClusterGapPx = 2;
const int kGeoClusterZoomSteps = 4;
const double kGeoMaxZoom = 32768;
const double kGeoGridAutoPxPerDeg = 400;
const double kGeoGridLabelDx = 6;
const double kGeoGridLabelDy = 5;
const int kGeoPulseWindowMs = 300000;
const int kGeoOnlineWindowSec = 300;
const int kGeoSearchMinChars = 2;
const int kGeoSearchLimit = 8;
const int kGeoMinTouchPx = 44;
const int kGeoPeekContentMax = 140;
const int kGeoPeekFetchCap = 500;

const List<String> kGeoPrecisionLabels = [
  'Subcontinent',
  'Large region',
  'Region',
  'Metro area',
  'Town or district',
  'Neighborhood',
  'Street block',
  'Building',
  'Room',
  'Spot',
  'Pinpoint',
  'Pinpoint',
];

const Map<String, int> kGeoKindPrecision = {
  'country': 2,
  'admin1': 3,
  'city': 4,
};

const Map<String, int> _kKindOrder = {'country': 0, 'admin1': 1, 'city': 2};

const List<(String, String)> _kFoldGroups = [
  ('àáâãäåāăą', 'a'),
  ('çćĉċč', 'c'),
  ('ďđð', 'd'),
  ('èéêëēĕėęě', 'e'),
  ('ĝğġģ', 'g'),
  ('ĥħ', 'h'),
  ('ìíîïĩīĭįı', 'i'),
  ('ĵ', 'j'),
  ('ķ', 'k'),
  ('ĺļľŀł', 'l'),
  ('ñńņňŉ', 'n'),
  ('òóôõöøōŏő', 'o'),
  ('ŕŗř', 'r'),
  ('śŝşšș', 's'),
  ('ţťŧț', 't'),
  ('ùúûüũūŭůűų', 'u'),
  ('ŵ', 'w'),
  ('ýÿŷ', 'y'),
  ('źżž', 'z'),
  ('ß', 'ss'),
  ('æ', 'ae'),
  ('œ', 'oe'),
  ('þ', 'th'),
];

final Map<int, String> _kFold = () {
  final m = <int, String>{};
  for (final (chars, to) in _kFoldGroups) {
    for (final r in chars.runes) {
      m[r] = to;
    }
  }
  return m;
}();

int _cmp(String a, String b) => a.compareTo(b);

String foldGeoText(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    b.write(_kFold[r] ?? String.fromCharCode(r));
  }
  return b
      .toString()
      .replaceAll(RegExp("['’`]"), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String normalizeGeoQuery(String raw) =>
    foldGeoText(raw).replaceFirst(RegExp(r'^#+'), '').trim();

bool _isBase32(String s) {
  for (final r in s.runes) {
    if (!kGeoBase32.contains(String.fromCharCode(r))) return false;
  }
  return true;
}

bool isGeoGeohash(String s) =>
    s.isNotEmpty && s.length <= 12 && _isBase32(s.toLowerCase());

@immutable
class GeoQueryClass {
  const GeoQueryClass(this.type, {this.geohash, this.reason});

  final String type;
  final String? geohash;
  final String? reason;

  Map<String, Object?> toJson() => {
        'type': type,
        if (geohash != null) 'geohash': geohash,
        if (reason != null) 'reason': reason,
      };
}

GeoQueryClass classifyGeoQuery(String raw) {
  final q = normalizeGeoQuery(raw);
  if (q.isEmpty) return const GeoQueryClass('empty');
  if (!RegExp(r'^[0-9a-z]+$').hasMatch(q)) return const GeoQueryClass('place');
  final chars = _isBase32(q);
  final valid = chars && q.length <= 12;
  if (RegExp(r'[0-9]').hasMatch(q)) {
    if (valid) return GeoQueryClass('geohash', geohash: q);
    return GeoQueryClass('invalid', reason: chars ? 'length' : 'chars');
  }
  return valid
      ? GeoQueryClass('maybe', geohash: q)
      : const GeoQueryClass('place');
}

String encodeGeoGeohash(double lat, double lng, int precision) {
  var latLo = -90.0, latHi = 90.0, lngLo = -180.0, lngHi = 180.0;
  var isEven = true;
  var bit = 0, ch = 0;
  final out = StringBuffer();
  var len = 0;
  while (len < precision) {
    if (isEven) {
      final mid = (lngLo + lngHi) / 2;
      if (lng >= mid) {
        ch = (ch << 1) + 1;
        lngLo = mid;
      } else {
        ch = ch << 1;
        lngHi = mid;
      }
    } else {
      final mid = (latLo + latHi) / 2;
      if (lat >= mid) {
        ch = (ch << 1) + 1;
        latLo = mid;
      } else {
        ch = ch << 1;
        latHi = mid;
      }
    }
    isEven = !isEven;
    if (++bit == 5) {
      out.write(kGeoBase32[ch]);
      len++;
      bit = 0;
      ch = 0;
    }
  }
  return out.toString();
}

({double latLo, double latHi, double lngLo, double lngHi})? geoCellBounds(
    String geohash) {
  if (!isGeoGeohash(geohash)) return null;
  var latLo = -90.0, latHi = 90.0, lngLo = -180.0, lngHi = 180.0;
  var isEven = true;
  for (final r in geohash.toLowerCase().runes) {
    final cd = kGeoBase32.indexOf(String.fromCharCode(r));
    for (var j = 4; j >= 0; j--) {
      final on = (cd >> j) & 1;
      if (isEven) {
        final mid = (lngLo + lngHi) / 2;
        if (on == 1) {
          lngLo = mid;
        } else {
          lngHi = mid;
        }
      } else {
        final mid = (latLo + latHi) / 2;
        if (on == 1) {
          latLo = mid;
        } else {
          latHi = mid;
        }
      }
      isEven = !isEven;
    }
  }
  return (latLo: latLo, latHi: latHi, lngLo: lngLo, lngHi: lngHi);
}

@immutable
class GeoPlace {
  const GeoPlace({
    required this.kind,
    required this.name,
    this.alt = '',
    this.country = '',
    this.region = '',
    this.code = '',
    required this.lat,
    required this.lng,
    this.size = 0,
  });

  final String kind;
  final String name;
  final String alt;
  final String country;
  final String region;
  final String code;
  final double lat;
  final double lng;
  final double size;
}

@immutable
class GeoPlaceMatch {
  const GeoPlaceMatch(this.place, this.tier);
  final GeoPlace place;
  final int tier;
}

String placeGeohash(GeoPlace p) =>
    encodeGeoGeohash(p.lat, p.lng, kGeoKindPrecision[p.kind] ?? 4);

List<String> _wordsOf(String s) =>
    s.split(RegExp(r'[\s\-.,()/]+')).where((w) => w.isNotEmpty).toList();

int _matchTier(List<String> keys, String q) {
  var best = -1;
  for (final k in keys) {
    var t = -1;
    if (k == q) {
      t = 0;
    } else if (k.startsWith(q)) {
      t = 1;
    } else if (_wordsOf(k).any((w) => w.startsWith(q))) {
      t = 2;
    } else if (q.length >= 3 && k.contains(q)) {
      t = 3;
    }
    if (t >= 0 && (best < 0 || t < best)) best = t;
  }
  return best;
}

List<GeoPlaceMatch> rankGeoPlaces(List<GeoPlace> places, String raw,
    {int limit = kGeoSearchLimit}) {
  final q = normalizeGeoQuery(raw);
  final parts = q.split(',');
  final main = parts.first.trim();
  final qual = parts.skip(1).join(',').trim();
  if (main.length < kGeoSearchMinChars) return const [];
  final out = <(GeoPlaceMatch, String)>[];
  for (final p in places) {
    if (p.name.isEmpty) continue;
    final keys = <String>[];
    for (final k in [foldGeoText(p.name), foldGeoText(p.alt)]) {
      if (k.isNotEmpty && !keys.contains(k)) keys.add(k);
    }
    final tier = _matchTier(keys, main);
    if (tier < 0) continue;
    if (qual.isNotEmpty) {
      final ok = foldGeoText(p.country).startsWith(qual) ||
          foldGeoText(p.region).startsWith(qual) ||
          (p.code.isNotEmpty && p.code == qual);
      if (!ok) continue;
    }
    out.add((GeoPlaceMatch(p, tier), foldGeoText(p.name)));
  }
  out.sort((x, y) {
    final a = x.$1, b = y.$1;
    var c = a.tier - b.tier;
    if (c != 0) return c;
    c = (_kKindOrder[a.place.kind] ?? 3) - (_kKindOrder[b.place.kind] ?? 3);
    if (c != 0) return c;
    c = b.place.size.compareTo(a.place.size);
    if (c != 0) return c;
    c = _cmp(x.$2, y.$2);
    if (c != 0) return c;
    c = _cmp(a.place.country, b.place.country);
    if (c != 0) return c;
    c = a.place.lat.compareTo(b.place.lat);
    if (c != 0) return c;
    return a.place.lng.compareTo(b.place.lng);
  });
  final n = limit > 0 ? limit : kGeoSearchLimit;
  return [for (final e in out.take(n)) e.$1];
}

@immutable
class GeoSearchResult {
  const GeoSearchResult.place(GeoPlaceMatch this.match, String this.geohash)
      : type = 'place',
        reason = null;
  const GeoSearchResult.geohash(String this.geohash)
      : type = 'geohash',
        match = null,
        reason = null;
  const GeoSearchResult.invalid(String this.reason)
      : type = 'invalid',
        match = null,
        geohash = null;

  final String type;
  final GeoPlaceMatch? match;
  final String? geohash;
  final String? reason;

  Map<String, Object?> toJson() => switch (type) {
        'place' => {
            'type': 'place',
            'kind': match!.place.kind,
            'name': match!.place.name,
            'country': match!.place.country,
            'region': match!.place.region,
            'tier': match!.tier,
            'geohash': geohash,
          },
        'geohash' => {
            'type': 'geohash',
            'geohash': geohash,
            'precision': geohash!.length,
          },
        _ => {'type': 'invalid', 'reason': reason},
      };
}

List<GeoSearchResult> buildGeoSearchResults(List<GeoPlace> places, String raw,
    {int limit = kGeoSearchLimit}) {
  final n = limit > 0 ? limit : kGeoSearchLimit;
  final c = classifyGeoQuery(raw);
  if (c.type == 'empty') return const [];
  final matches = [
    for (final m in rankGeoPlaces(places, raw, limit: n))
      GeoSearchResult.place(m, placeGeohash(m.place)),
  ];
  final List<GeoSearchResult> out;
  if (c.type == 'geohash' || c.type == 'maybe') {
    out = [GeoSearchResult.geohash(c.geohash!), ...matches];
  } else if (c.type == 'invalid') {
    out = [GeoSearchResult.invalid(c.reason!), ...matches];
  } else {
    out = matches;
  }
  return out.take(n).toList();
}

String roomPlaceLabel(List<GeoPlace> places, String geohash) {
  final b = geoCellBounds(geohash);
  if (b == null || geohash.length < 3) return '';
  final lat = (b.latLo + b.latHi) / 2;
  final lng = (b.lngLo + b.lngHi) / 2;
  final maxKm = math.max(25.0, haversineKm(lat, lng, b.latHi, b.lngHi));
  GeoPlace? best;
  var bestKm = double.infinity;
  for (final p in places) {
    if (p.kind != 'city' || p.name.isEmpty) continue;
    final km = haversineKm(lat, lng, p.lat, p.lng);
    if (km < bestKm ||
        (km == bestKm &&
            best != null &&
            (p.size > best.size ||
                (p.size == best.size && _cmp(p.name, best.name) < 0)))) {
      best = p;
      bestKm = km;
    }
  }
  if (best == null || bestKm > maxKm) return '';
  return best.country.isNotEmpty ? '${best.name}, ${best.country}' : best.name;
}

double? _num(Object? v) =>
    v is num && v.isFinite ? v.toDouble() : null;

String _str(Object? v) => v is String ? v : '';

String _iso(Object? v) {
  final s = v is String ? v.toLowerCase() : '';
  return RegExp(r'^[a-z]{2}$').hasMatch(s) ? s : '';
}

List<GeoPlace> buildGeoPlaceIndex({
  Object? cities,
  Object? admin1,
  List<GeoFeature> countries = const [],
}) {
  final out = <GeoPlace>[];
  List<dynamic> feats(Object? src) {
    if (src is Map && src['features'] is List) return src['features'] as List;
    return const [];
  }

  for (final f in feats(cities)) {
    if (f is! Map) continue;
    final p = f['properties'] is Map ? f['properties'] as Map : const {};
    final g = f['geometry'];
    final coords = g is Map && g['coordinates'] is List
        ? g['coordinates'] as List
        : const [];
    final lat = _num(p['latitude']) ?? (coords.length > 1 ? _num(coords[1]) : null);
    final lng = _num(p['longitude']) ?? (coords.isNotEmpty ? _num(coords[0]) : null);
    final name = _str(p['name']);
    if (name.isEmpty || lat == null || lng == null) continue;
    out.add(GeoPlace(
      kind: 'city',
      name: name,
      alt: _str(p['nameascii']),
      country: _str(p['adm0name']),
      region: _str(p['adm1name']),
      code: _iso(p['iso_a2']),
      lat: lat,
      lng: lng,
      size: _num(p['pop_max']) ?? 0,
    ));
  }
  for (final f in feats(admin1)) {
    if (f is! Map) continue;
    final p = f['properties'] is Map ? f['properties'] as Map : const {};
    final lat = _num(p['latitude']);
    final lng = _num(p['longitude']);
    final name = _str(p['name']);
    if (name.isEmpty || lat == null || lng == null) continue;
    out.add(GeoPlace(
      kind: 'admin1',
      name: name,
      country: _str(p['admin']),
      code: _iso(p['iso_a2']),
      lat: lat,
      lng: lng,
      size: _num(p['area_sqkm']) ?? 0,
    ));
  }
  for (final f in countries) {
    if (f.name.isEmpty || f.centroid.length < 2) continue;
    out.add(GeoPlace(
      kind: 'country',
      name: f.name,
      lat: f.centroid[1],
      lng: f.centroid[0],
      size: f.area,
    ));
  }
  return out;
}

String formatGeoLength(double m) {
  if (m >= 10000) return '${(m / 1000).round()} km';
  if (m >= 1000) return '${(m / 1000).toStringAsFixed(1)} km';
  if (m >= 10) return '${m.round()} m';
  if (m >= 1) return '${m.toStringAsFixed(1)} m';
  return '${(m * 100).round()} cm';
}

({double w, double h})? geoCellSizeMeters(String geohash) {
  final b = geoCellBounds(geohash);
  if (b == null) return null;
  final latC = (b.latLo + b.latHi) / 2;
  return (
    w: (b.lngHi - b.lngLo) * 111320 * math.cos(latC * math.pi / 180),
    h: (b.latHi - b.latLo) * 110574,
  );
}

@immutable
class GeoPrecisionStep {
  const GeoPrecisionStep({
    required this.geohash,
    required this.length,
    required this.label,
    required this.size,
  });
  final String geohash;
  final int length;
  final String label;
  final String size;
}

List<GeoPrecisionStep> geohashPrecisionSteps(String geohash) {
  if (!isGeoGeohash(geohash)) return const [];
  final gh = geohash.toLowerCase();
  return [
    for (var i = 1; i <= gh.length; i++)
      () {
        final prefix = gh.substring(0, i);
        final s = geoCellSizeMeters(prefix)!;
        return GeoPrecisionStep(
          geohash: prefix,
          length: i,
          label: kGeoPrecisionLabels[i - 1],
          size: '${formatGeoLength(s.w)} × ${formatGeoLength(s.h)}',
        );
      }(),
  ];
}

double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * (2 * math.atan2(math.sqrt(a), math.sqrt(1 - a)));
}

String formatGeoDistanceKm(double km) {
  if (km < 0.9995) return '${(km * 1000).round()} m';
  if (km < 9.95) return '${km.toStringAsFixed(1)} km';
  return '${km.round()} km';
}

@immutable
class GeoActivity {
  const GeoActivity({
    required this.geohash,
    required this.lat,
    required this.lng,
    required this.messages,
  });
  final String geohash;
  final double lat;
  final double lng;
  final int messages;
}

List<T> rankGeoActive<T extends GeoActivity>(List<T> channels) {
  final out = List<T>.of(channels);
  out.sort((a, b) {
    final c = b.messages - a.messages;
    return c != 0 ? c : _cmp(a.geohash, b.geohash);
  });
  return out;
}

List<({T item, double distanceKm})> rankGeoNearby<T extends GeoActivity>(
    List<T> channels, ({double lat, double lng})? loc) {
  if (loc == null || !loc.lat.isFinite || !loc.lng.isFinite) return const [];
  final out = [
    for (final c in channels)
      (item: c, distanceKm: haversineKm(loc.lat, loc.lng, c.lat, c.lng)),
  ];
  out.sort((a, b) {
    var c = a.distanceKm.compareTo(b.distanceKm);
    if (c != 0) return c;
    c = b.item.messages - a.item.messages;
    if (c != 0) return c;
    return _cmp(a.item.geohash, b.item.geohash);
  });
  return out;
}

@immutable
class GeoClusterInput {
  const GeoClusterInput({
    required this.id,
    required this.lat,
    required this.lng,
    required this.messages,
  });
  final String id;
  final double lat;
  final double lng;
  final int messages;
}

@immutable
class GeoWorldCluster {
  const GeoWorldCluster({
    required this.ids,
    required this.lat,
    required this.lng,
    required this.count,
    required this.messages,
    required this.r,
  });
  final List<String> ids;
  final double lat;
  final double lng;
  final int count;
  final int messages;
  final int r;
}

@immutable
class GeoCluster {
  const GeoCluster({
    required this.ids,
    required this.x,
    required this.y,
    required this.count,
    required this.messages,
    this.lat = 0,
    this.lng = 0,
  });
  final List<String> ids;
  final double x;
  final double y;
  final int count;
  final int messages;
  final double lat;
  final double lng;

  double get r => geoClusterRadius(count).toDouble();
}

int geoClusterRadius(int count) {
  if (count < 2) return 4;
  var bits = 0;
  for (var n = count; n > 1; n ~/= 2) {
    bits++;
  }
  return 12 + math.min(6, 2 * bits);
}

class _WorkCluster {
  _WorkCluster(this.members, double s)
      : key = members.first.id,
        r = geoClusterRadius(members.length) {
    var sLat = 0.0, sLng = 0.0;
    var msgs = 0;
    for (final p in members) {
      sLat += p.lat;
      sLng += p.lng;
      msgs += p.messages;
    }
    lat = sLat / members.length;
    lng = sLng / members.length;
    wx = (lng + 180) * s;
    wy = (90 - lat) * s;
    messages = msgs;
  }

  final List<GeoClusterInput> members;
  final String key;
  final int r;
  late final double lat;
  late final double lng;
  late final double wx;
  late final double wy;
  late final int messages;
}

double geoClusterZoomStep(double zoom) {
  final z = zoom > 0 ? math.min(zoom, kGeoMaxZoom) : 1.0;
  if (z < kGeoClusterGridZoom) {
    return math.max(
        1.0, (z * kGeoClusterZoomSteps).floor() / kGeoClusterZoomSteps);
  }
  var base = kGeoClusterGridZoom.toDouble();
  while (base * 2 <= z) {
    base *= 2;
  }
  final q = base / kGeoClusterZoomSteps;
  return base + ((z - base) / q).floor() * q;
}

double _geoStepAt(int i) {
  const below = (kGeoClusterGridZoom - 1) * kGeoClusterZoomSteps;
  if (i < below) return 1 + i / kGeoClusterZoomSteps;
  final j = i - below;
  return kGeoClusterGridZoom *
      math.pow(2, j ~/ kGeoClusterZoomSteps).toDouble() *
      (1 + (j % kGeoClusterZoomSteps) / kGeoClusterZoomSteps);
}

int _geoStepIndex(double zq) {
  var i = 0;
  while (_geoStepAt(i) < zq) {
    i++;
  }
  return i;
}

double? geoClusterSplitZoom(
    List<GeoClusterInput> points, double zoom, Size viewport) {
  bool splits(double z) => clusterGeoChannels(points, z, viewport).length > 1;
  if (!splits(kGeoMaxZoom)) return null;
  var lo = _geoStepIndex(geoClusterZoomStep(zoom));
  if (splits(_geoStepAt(lo))) return _geoStepAt(lo);
  var hi = _geoStepIndex(kGeoMaxZoom);
  while (hi - lo > 1) {
    final mid = (lo + hi) ~/ 2;
    if (splits(_geoStepAt(mid))) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return _geoStepAt(hi);
}

bool geoDeepGrid(double pxPerDeg) => pxPerDeg >= kGeoGridAutoPxPerDeg;

({double x, double y})? geoGridCornerLabel(
    GeoLabelBox cell, double textW, double lineH,
    {required double width,
    required double height,
    List<GeoLabelBox> blocked = const []}) {
  final x = math.max(cell.x0, 0.0) + kGeoGridLabelDx;
  final y = math.max(cell.y0, 0.0) + kGeoGridLabelDy;
  if (x + textW > width || y + lineH > height) return null;
  if (x + textW > cell.x1 || y + lineH > cell.y1) return null;
  if (cell.y0 < 0 && cell.y1 + kGeoGridLabelDy - y < 2 * lineH) return null;
  if (cell.x0 < 0 && cell.x1 + kGeoGridLabelDx - (x + textW) < lineH) {
    return null;
  }
  final x1 = x + textW, y1 = y + lineH;
  for (final b in blocked) {
    if (x < b.x1 && x1 > b.x0 && y < b.y1 && y1 > b.y0) return null;
  }
  return (x: x, y: y);
}

class _GeoPair {
  _GeoPair(this.a, this.b, this.d);
  final _WorkCluster a;
  final _WorkCluster b;
  final double d;
}

List<GeoWorldCluster> clusterGeoChannels(
    List<GeoClusterInput> points, double zoom, Size viewport) {
  final w = viewport.width > 0 ? viewport.width : 1.0;
  final h = viewport.height > 0 ? viewport.height : 1.0;
  final zq = geoClusterZoomStep(zoom);
  final s = math.max(w / 360, h / 180) * zq;
  final cell = kGeoClusterCellPx.toDouble();
  final seed =
      (zq < kGeoClusterGridZoom ? kGeoClusterCellPx : kGeoClusterSeedPx)
          .toDouble();
  _WorkCluster make(List<GeoClusterInput> members) =>
      _WorkCluster(List.of(members)..sort((a, b) => _cmp(a.id, b.id)), s);
  final groups = <String, List<GeoClusterInput>>{};
  for (final p in points) {
    if (!p.lat.isFinite || !p.lng.isFinite) continue;
    final key =
        '${((p.lng + 180) * s / seed).floor()},${((90 - p.lat) * s / seed).floor()}';
    groups.putIfAbsent(key, () => []).add(p);
  }
  var list = [for (final g in groups.values) make(g)];
  String bucketOf(_WorkCluster k) =>
      '${(k.wx / cell).floor()},${(k.wy / cell).floor()}';
  final buckets = <String, Set<_WorkCluster>>{};
  void put(_WorkCluster k) =>
      buckets.putIfAbsent(bucketOf(k), () => <_WorkCluster>{}).add(k);
  List<_GeoPair> near(_WorkCluster k) {
    final out = <_GeoPair>[];
    final bx = (k.wx / cell).floor(), by = (k.wy / cell).floor();
    for (var ox = -1; ox <= 1; ox++) {
      for (var oy = -1; oy <= 1; oy++) {
        final b = buckets['${bx + ox},${by + oy}'];
        if (b == null) continue;
        for (final o in b) {
          if (identical(o, k)) continue;
          final lo = _cmp(k.key, o.key) < 0 ? k : o;
          final hi = identical(lo, k) ? o : k;
          final dx = hi.wx - lo.wx, dy = hi.wy - lo.wy;
          final lim = lo.r + hi.r + kGeoClusterGapPx;
          final d = dx * dx + dy * dy;
          if (d < lim * lim) out.add(_GeoPair(lo, hi, d));
        }
      }
    }
    return out;
  }

  list.forEach(put);
  var pairs = <_GeoPair>[
    for (final k in list)
      for (final p in near(k))
        if (identical(p.a, k)) p,
  ];
  while (pairs.isNotEmpty) {
    pairs.sort((x, y) {
      final c = x.d.compareTo(y.d);
      if (c != 0) return c;
      final c2 = _cmp(x.a.key, y.a.key);
      if (c2 != 0) return c2;
      return _cmp(x.b.key, y.b.key);
    });
    final used = <_WorkCluster>{};
    final merged = <_WorkCluster>[];
    for (final p in pairs) {
      if (used.contains(p.a) || used.contains(p.b)) continue;
      used
        ..add(p.a)
        ..add(p.b);
      merged.add(make([...p.a.members, ...p.b.members]));
    }
    for (final k in used) {
      buckets[bucketOf(k)]!.remove(k);
    }
    pairs = [
      for (final p in pairs)
        if (!used.contains(p.a) && !used.contains(p.b)) p,
    ];
    merged.forEach(put);
    final fresh = merged.toSet();
    for (final m in merged) {
      for (final p in near(m)) {
        final o = identical(p.a, m) ? p.b : p.a;
        if (fresh.contains(o) && !identical(p.a, m)) continue;
        pairs.add(p);
      }
    }
    list = [
      for (final k in list)
        if (!used.contains(k)) k,
      ...merged,
    ];
  }
  list.sort((a, b) => _cmp(a.key, b.key));
  return [
    for (final k in list)
      GeoWorldCluster(
        ids: [for (final p in k.members) p.id],
        lat: k.lat,
        lng: k.lng,
        count: k.members.length,
        messages: k.messages,
        r: k.r,
      ),
  ];
}

bool isGeoRecent(int lastMs, int nowMs) =>
    lastMs > 0 && nowMs - lastMs <= kGeoPulseWindowMs;

int normalizeGeoWindowHours(Object? h) =>
    h is int && kGeoWindowOptions.contains(h) ? h : 24;

@immutable
class GeoPeekMessage {
  const GeoPeekMessage({
    required this.id,
    required this.pubkey,
    required this.nym,
    required this.content,
    required this.createdAt,
  });
  final String id;
  final String pubkey;
  final String nym;
  final String content;
  final int createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'pubkey': pubkey,
        'nym': nym,
        'content': content,
        'createdAt': createdAt,
      };
}

@immutable
class GeoPeekSummary {
  const GeoPeekSummary({
    required this.messages,
    required this.online,
    required this.total,
    this.capped = false,
  });
  final List<GeoPeekMessage> messages;
  final int online;
  final int total;
  final bool capped;

  Map<String, Object?> toJson() => {
        'messages': [for (final m in messages) m.toJson()],
        'online': online,
        'total': total,
        'capped': capped,
      };
}

bool geoPeekCapped(List<Map<String, dynamic>> events) {
  var n = 0;
  for (final e in events) {
    if (e['kind'] != 9735) n++;
  }
  return n >= kGeoPeekFetchCap;
}

String geoPeekCountLabel(GeoPeekSummary? summary) {
  if (summary == null) return '';
  return '${summary.total}${summary.capped ? '+' : ''}';
}

String? _tagValue(Object? tags, String name) {
  if (tags is! List) return null;
  for (final t in tags) {
    if (t is List && t.length > 1 && t[0] == name && t[1] is String) {
      return t[1] as String;
    }
  }
  return null;
}

String _clip(String s) {
  final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final cps = flat.runes.toList();
  return cps.length > kGeoPeekContentMax
      ? '${String.fromCharCodes(cps.take(kGeoPeekContentMax))}…'
      : flat;
}

GeoPeekSummary summarizeGeoPeek(
  List<Map<String, dynamic>> events, {
  required String geohash,
  required int nowSec,
  Set<String> blocked = const {},
  List<String> localOnline = const [],
  int limit = 5,
  bool capped = false,
}) {
  final gh = geohash.toLowerCase();
  final seen = <String>{};
  final valid = <Map<String, dynamic>>[];
  for (final e in events) {
    if (e['kind'] != 20000 || e['id'] is! String) continue;
    final id = e['id'] as String;
    if (seen.contains(id)) continue;
    final g = _tagValue(e['tags'], 'g');
    if (g == null || g.toLowerCase() != gh) continue;
    if (_tagValue(e['tags'], 'edit') != null) continue;
    final pk = e['pubkey'];
    if (pk is! String || blocked.contains(pk)) continue;
    final content = e['content'];
    if (content is! String || content.trim().isEmpty) continue;
    if (e['created_at'] is! int) continue;
    seen.add(id);
    valid.add(e);
  }
  final online = <String>{
    for (final pk in localOnline)
      if (!blocked.contains(pk)) pk,
  };
  for (final e in valid) {
    if ((e['created_at'] as int) >= nowSec - kGeoOnlineWindowSec) {
      online.add(e['pubkey'] as String);
    }
  }
  final newest = List<Map<String, dynamic>>.of(valid)
    ..sort((a, b) {
      final c = (b['created_at'] as int) - (a['created_at'] as int);
      return c != 0 ? c : _cmp(a['id'] as String, b['id'] as String);
    });
  final picked = newest.take(limit > 0 ? limit : 5).toList().reversed;
  return GeoPeekSummary(
    messages: [
      for (final e in picked)
        GeoPeekMessage(
          id: e['id'] as String,
          pubkey: e['pubkey'] as String,
          nym: _tagValue(e['tags'], 'n') ?? '',
          content: _clip(e['content'] as String),
          createdAt: e['created_at'] as int,
        ),
    ],
    online: online.length,
    total: valid.length,
    capped: capped,
  );
}

const double kGeoMaxDpr = 2;
const List<double> kGeoTierPxPerDeg = [7, 40];
const double kGeoLabelPad = 3;

double capGeoDpr(double? dpr) {
  if (dpr == null || dpr.isNaN || !dpr.isFinite || dpr <= 0) return 1;
  return math.min(dpr, kGeoMaxDpr);
}

int geoTierFor(double pxPerDeg) {
  var t = 0;
  for (final th in kGeoTierPxPerDeg) {
    if (pxPerDeg >= th) t++;
  }
  return t;
}

int geoCityRankCutoff(double zoom) => zoom < 3
    ? 2
    : zoom < 4
        ? 4
        : zoom < 6
            ? 6
            : zoom < 8
                ? 8
                : 10;

@immutable
class GeoLabelBox {
  const GeoLabelBox(this.x0, this.y0, this.x1, this.y1);
  final double x0;
  final double y0;
  final double x1;
  final double y1;

  bool hits(GeoLabelBox o, double pad) =>
      x0 - pad < o.x1 && o.x0 < x1 + pad && y0 - pad < o.y1 && o.y0 < y1 + pad;
}

List<int> placeGeoLabels(List<GeoLabelBox> boxes,
    {double pad = kGeoLabelPad, List<GeoLabelBox> blocked = const []}) {
  const cell = 64.0;
  final grid = <int, List<int>>{};
  final out = <int>[];
  final all = [...blocked, ...boxes];
  int key(int gx, int gy) => gx * 100003 + gy;
  void occupy(int j) {
    final b = all[j];
    final gx0 = ((b.x0 - pad) / cell).floor(), gx1 = ((b.x1 + pad) / cell).floor();
    final gy0 = ((b.y0 - pad) / cell).floor(), gy1 = ((b.y1 + pad) / cell).floor();
    for (var gx = gx0; gx <= gx1; gx++) {
      for (var gy = gy0; gy <= gy1; gy++) {
        (grid[key(gx, gy)] ??= <int>[]).add(j);
      }
    }
  }

  for (var j = 0; j < blocked.length; j++) {
    occupy(j);
  }
  for (var i = 0; i < boxes.length; i++) {
    final b = boxes[i];
    final gx0 = ((b.x0 - pad) / cell).floor(), gx1 = ((b.x1 + pad) / cell).floor();
    final gy0 = ((b.y0 - pad) / cell).floor(), gy1 = ((b.y1 + pad) / cell).floor();
    var free = true;
    for (var gx = gx0; gx <= gx1 && free; gx++) {
      for (var gy = gy0; gy <= gy1 && free; gy++) {
        final list = grid[key(gx, gy)];
        if (list == null) continue;
        for (final j in list) {
          if (b.hits(all[j], pad)) {
            free = false;
            break;
          }
        }
      }
    }
    if (!free) continue;
    out.add(i);
    occupy(blocked.length + i);
  }
  return out;
}

@immutable
class GeoLabelFit {
  const GeoLabelFit(this.box, this.flipped);
  final GeoLabelBox box;
  final bool flipped;

  Map<String, Object> toJson() => {
        'x0': box.x0,
        'y0': box.y0,
        'x1': box.x1,
        'y1': box.y1,
        'flipped': flipped,
      };
}

GeoLabelFit? fitGeoLabelBox(GeoLabelBox box,
    {required double anchorX,
    required bool side,
    required double width,
    required double height,
    double pad = kGeoLabelPad}) {
  final lo = pad, hiX = width - pad, hiY = height - pad;
  var x0 = box.x0, y0 = box.y0, x1 = box.x1, y1 = box.y1;
  final bw = x1 - x0, bh = y1 - y0;
  if (bw > hiX - lo || bh > hiY - lo) return null;
  var flipped = false;
  if (side) {
    if (anchorX - 2.5 < lo || anchorX + 2.5 > hiX) return null;
    if (x1 > hiX) {
      x1 = anchorX + 2.5;
      x0 = x1 - bw;
      flipped = true;
    }
    if (x0 < lo) return null;
    final dy = y0 < lo ? lo - y0 : (y1 > hiY ? hiY - y1 : 0.0);
    if (dy.abs() > bh / 2) return null;
    y0 += dy;
    y1 += dy;
  } else {
    final dx = x0 < lo ? lo - x0 : (x1 > hiX ? hiX - x1 : 0.0);
    final dy = y0 < lo ? lo - y0 : (y1 > hiY ? hiY - y1 : 0.0);
    x0 += dx;
    x1 += dx;
    y0 += dy;
    y1 += dy;
  }
  return GeoLabelFit(GeoLabelBox(x0, y0, x1, y1), flipped);
}

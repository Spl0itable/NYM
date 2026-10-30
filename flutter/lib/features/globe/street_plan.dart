import 'dart:convert';
import 'dart:math' as math;

class StreetParams {
  const StreetParams();
  final int minZ = 5;
  final int maxZ = 15;
  final double tileBias = 0.5;
  final int maxViewTiles = 48;
  final int settleMs = 150;
  final int concurrent = 4;
  final int maxPer10s = 120;
  final int windowMs = 10000;
  final int maxBodyBytes = 524288;
  final int metaTtlMs = 3600000;
  final int unavailableRetryMs = 600000;
  final int tooLargeRetryMs = 86400000;
  final int malformedRetryMs = 86400000;
  final int cacheTtlMs = 2592000000;
  final int pwaCacheBytes = 50331648;
  final int flutterCacheBytes = 100663296;
  final int memDecodedTiles = 96;
  final int memGzipBytes = 16777216;
}

const StreetParams kStreet = StreetParams();

const double kStreetMercMaxLat = 85.0511287798;

typedef StreetTileId = ({int z, int x, int y});

String streetTileKey(StreetTileId t) => '${t.z}/${t.x}/${t.y}';

double streetZvOf(double pxPerDeg) => math.log(pxPerDeg * 360 / 256) / math.ln2;

int streetBucketExp(double pxPerDeg) =>
    (2 * math.log(pxPerDeg) / math.ln2).round();

double streetBucketZvOf(int e) => e / 2 + math.log(360 / 256) / math.ln2;

double streetBucketScaleOf(int e) => math.pow(2, e / 2).toDouble();

double streetBucketScale(double pxPerDeg) =>
    streetBucketScaleOf(streetBucketExp(pxPerDeg));

int? streetTileZoomOfBucket(int e) {
  final t = (streetBucketZvOf(e) - kStreet.tileBias).floor();
  return t < kStreet.minZ ? null : math.min(kStreet.maxZ, t);
}

int? streetBaseTileZoom(double pxPerDeg) =>
    streetTileZoomOfBucket(streetBucketExp(pxPerDeg));

double _mercY(double lat) {
  final r = lat * math.pi / 180;
  return (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2;
}

double streetTileLatOf(double y, int z) =>
    (2 * math.atan(math.exp(math.pi * (1 - 2 * y / math.pow(2, z)))) - math.pi / 2) *
    180 /
    math.pi;

({int x0, int x1, int y0, int y1})? streetTileRange(
    double w, double e, double s, double n, int z) {
  final side = 1 << z;
  final ww = math.max(-180.0, w), ee = math.min(180.0, e);
  final ss = math.max(-kStreetMercMaxLat, s), nn = math.min(kStreetMercMaxLat, n);
  if (ww >= ee || ss >= nn) return null;
  return (
    x0: math.max(0, ((ww + 180) / 360 * side).floor()),
    x1: math.min(side - 1, ((ee + 180) / 360 * side).ceil() - 1),
    y0: math.max(0, (_mercY(nn) * side).floor()),
    y1: math.min(side - 1, (_mercY(ss) * side).ceil() - 1),
  );
}

class StreetPlan {
  const StreetPlan(this.zv, this.bucketExp, this.bucketZv, this.tz, this.draw,
      this.visible, this.tiles);
  final double zv;
  final int bucketExp;
  final double bucketZv;
  final int? tz;
  final bool draw;
  final int visible;
  final List<StreetTileId> tiles;

  static const StreetPlan none = StreetPlan(0, 0, 0, null, false, 0, []);
}

StreetPlan planStreetTiles({
  required double cx,
  required double cy,
  required double pxPerDeg,
  required double width,
  required double height,
  bool on = true,
}) {
  final zv = streetZvOf(pxPerDeg);
  final e = streetBucketExp(pxPerDeg);
  final bz = streetBucketZvOf(e);
  final empty = StreetPlan(zv, e, bz, null, false, 0, const []);
  if (!on) return empty;
  var tz = streetTileZoomOfBucket(e);
  if (tz == null) return empty;
  final hw = width / 2 / pxPerDeg, hh = height / 2 / pxPerDeg;
  ({int x0, int x1, int y0, int y1})? range(int z) =>
      streetTileRange(cx - hw, cx + hw, cy - hh, cy + hh, z);
  int count(({int x0, int x1, int y0, int y1}) q) =>
      (q.x1 - q.x0 + 1) * (q.y1 - q.y0 + 1);
  var r = range(tz);
  if (r == null) return empty;
  while (count(r!) > kStreet.maxViewTiles && tz! > kStreet.minZ) {
    tz--;
    r = range(tz);
  }
  if (count(r) > kStreet.maxViewTiles) return empty;
  final side = 1 << tz!;
  final list = <(double, StreetTileId)>[];
  for (var y = r.y0; y <= r.y1; y++) {
    for (var x = r.x0; x <= r.x1; x++) {
      final lng = (x + 0.5) / side * 360 - 180, lat = streetTileLatOf(y + 0.5, tz);
      final dx = lng - cx, dy = lat - cy;
      list.add((dx * dx + dy * dy, (z: tz, x: x, y: y)));
    }
  }
  list.sort((a, b) {
    final d = a.$1.compareTo(b.$1);
    if (d != 0) return d;
    final dy = a.$2.y.compareTo(b.$2.y);
    return dy != 0 ? dy : a.$2.x.compareTo(b.$2.x);
  });
  return StreetPlan(zv, e, bz, tz, true, list.length, [for (final q in list) q.$2]);
}

List<StreetTileId> streetFallbackFor(
    StreetTileId want, bool Function(StreetTileId t) has) {
  if (has(want)) return [want];
  for (var k = 1; want.z - k >= kStreet.minZ; k++) {
    final p = (z: want.z - k, x: want.x >> k, y: want.y >> k);
    if (has(p)) return [p];
  }
  final kids = <StreetTileId>[];
  if (want.z < kStreet.maxZ) {
    for (final (dx, dy) in const [(0, 0), (1, 0), (0, 1), (1, 1)]) {
      final c = (z: want.z + 1, x: 2 * want.x + dx, y: 2 * want.y + dy);
      if (has(c)) kids.add(c);
    }
  }
  return kids;
}

({List<String> start, int waitMs}) nextStreetTileFetches({
  required List<String> queue,
  required int inflight,
  required List<int> sent,
  required int now,
}) {
  final recent = [for (final t in sent) if (now - t < kStreet.windowMs) t]..sort();
  final slots = math.max(
      0,
      math.min(kStreet.concurrent - inflight, kStreet.maxPer10s - recent.length));
  final start = queue.take(slots).toList();
  final capped = queue.length > start.length && recent.length >= kStreet.maxPer10s;
  return (
    start: start,
    waitMs: capped ? recent.first + kStreet.windowMs - now : 0,
  );
}

List<String> streetCancelSet(List<String> inflight, Iterable<String> wanted) {
  final w = wanted.toSet();
  return [for (final k in inflight) if (!w.contains(k)) k];
}

enum StreetAction { ok, rebuild, negative, pause, stop }

({StreetAction kind, int ms, int? build}) streetStatusAction(int status,
    [String? body]) {
  if (status == 200) return (kind: StreetAction.ok, ms: 0, build: null);
  if (status == 404) {
    try {
      final j = jsonDecode(body ?? '');
      if (j is Map && j['error'] == 'build' && j['build'] is int && (j['build'] as int) > 0) {
        return (kind: StreetAction.rebuild, ms: 0, build: j['build'] as int);
      }
    } catch (_) {}
    return (kind: StreetAction.stop, ms: 0, build: null);
  }
  if (status == 413) {
    return (kind: StreetAction.negative, ms: kStreet.tooLargeRetryMs, build: null);
  }
  if (status == 422) {
    return (kind: StreetAction.negative, ms: kStreet.malformedRetryMs, build: null);
  }
  if (status == 0 || status == 429 || status >= 500) {
    return (kind: StreetAction.pause, ms: kStreet.unavailableRetryMs, build: null);
  }
  return (kind: StreetAction.stop, ms: 0, build: null);
}

const List<double> _widthZv = [6, 8, 10, 12, 14, 16, 18];

const Map<String, List<double>> _widths = {
  'hw': [0.6, 0.9, 1.2, 1.6, 2, 5, 10],
  'major': [0.4, 0.5, 0.7, 1.1, 1.6, 4, 8],
  'minor': [0.3, 0.3, 0.4, 0.5, 0.8, 2.6, 5],
  'service': [0.3, 0.3, 0.3, 0.4, 0.5, 1.4, 3],
  'path': [0.3, 0.3, 0.3, 0.4, 0.5, 1, 1.5],
  'rail': [0.4, 0.5, 0.6, 0.7, 0.8, 1.2, 1.5],
  'river': [0.5, 0.6, 0.8, 0.9, 1, 2.5, 4],
  'stream': [0.3, 0.3, 0.4, 0.4, 0.5, 1, 1.5],
};

double streetWidthAt(String cls, double zv) {
  final w = _widths[cls];
  if (w == null) return 1;
  if (zv <= _widthZv[0]) return w[0];
  for (var i = 1; i < _widthZv.length; i++) {
    if (zv <= _widthZv[i]) {
      return w[i - 1] +
          (w[i] - w[i - 1]) * (zv - _widthZv[i - 1]) / (_widthZv[i] - _widthZv[i - 1]);
    }
  }
  return w.last;
}

const Map<String, double> kStreetLabelFrom = {
  'hw': 7.99,
  'major': 11.49,
  'minor': 14.49,
  'service': 14.49,
  'path': 14.49,
  'river': 9.99,
  'stream': 12.99,
  'wlabel': 5.99,
};

bool streetLabelAllowed(String cls, double bucketZv) {
  final f = kStreetLabelFrom[cls];
  return f != null && bucketZv >= f;
}

int streetMaxLabels(double bucketZv) {
  if (bucketZv < 9.99) return 12;
  if (bucketZv < 12.99) return 24;
  return 40;
}

bool streetRoadDrawn(num? minZoom, double bucketZv) =>
    minZoom == null || minZoom <= bucketZv - kStreet.tileBias;

String? streetLabelText(String cls, Map<String, Object?> props) {
  String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
  if (cls == 'hw' || cls == 'major') return str(props['name']) ?? str(props['ref']);
  if (const {'rail', 'land', 'water', 'green', 'landuse', 'bld'}.contains(cls)) return null;
  return str(props['name']);
}

String streetTilePath(int build, int z, int x, int y) => '/api/map/v2/$build/$z/$x/$y';

String streetCacheKey(int build, int z, int x, int y) => '$build/$z/$x/$y';

String streetFlutterFile(int build, int z, int x, int y) =>
    'nym-map/v2/$build/$z-$x-$y.mvt.gz';

final RegExp kStreetCacheKeyRe =
    RegExp(r'^([1-9][0-9]{7})/(0|[1-9][0-9]?)/(0|[1-9][0-9]{0,4})/(0|[1-9][0-9]{0,4})$');

({int build, int z, int x, int y})? parseStreetCacheKey(String key) {
  final m = kStreetCacheKeyRe.firstMatch(key);
  if (m == null) return null;
  final z = int.parse(m[2]!), x = int.parse(m[3]!), y = int.parse(m[4]!);
  if (z < kStreet.minZ || z > kStreet.maxZ || x >= 1 << z || y >= 1 << z) return null;
  return (build: int.parse(m[1]!), z: z, x: x, y: y);
}

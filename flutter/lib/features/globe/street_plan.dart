import 'dart:math' as math;

import 'geo_explore.dart';
import 'geo_projection.dart';

class StreetParams {
  const StreetParams();
  final double drawZv = 13.5;
  final double fetchZv = 14;
  final int maxCells = 6;
  final int cellsPerMinute = 12;
  final int concurrent = 2;
  final int settleMs = 400;
  final int unavailableRetryMs = 600000;
  final int tooLargeRetryMs = 86400000;
  final int cacheTtlMs = 2592000000;
  final int pwaCacheBytes = 50331648;
  final int flutterCacheBytes = 100663296;
}

const StreetParams kStreet = StreetParams();

const double kStreetMercMaxLat = 85.0511287798066;
const double _p5 = 360 / 8192;
const int _minuteMs = 60000;

double streetZvOf(double pxPerDeg) => math.log(pxPerDeg * 360 / 256) / math.ln2;

int streetBucketExp(double pxPerDeg) =>
    (2 * math.log(pxPerDeg) / math.ln2).round();

double streetBucketScaleOf(int e) => math.pow(2, e / 2).toDouble();

double streetBucketScale(double pxPerDeg) =>
    streetBucketScaleOf(streetBucketExp(pxPerDeg));

({double s, double n, double w, double e}) streetCellBounds(String cell) {
  final b = geohashBounds(cell);
  if (b == null) throw ArgumentError.value(cell, 'cell');
  return (s: b.latLo, n: b.latHi, w: b.lngLo, e: b.lngHi);
}

double _mercY(double lat) {
  final r = lat * math.pi / 180;
  return (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2;
}

List<({int z, int x, int y})> streetCellTiles(String cell, int zmin, int zmax) {
  final b = streetCellBounds(cell);
  final s = math.max(b.s, -kStreetMercMaxLat), n = math.min(b.n, kStreetMercMaxLat);
  final out = <({int z, int x, int y})>[];
  if (s >= n) return out;
  for (var z = zmin; z <= zmax; z++) {
    final side = 1 << z;
    final x0 = ((b.w + 180) / 360 * side).floor();
    final x1 = ((b.e + 180) / 360 * side).ceil() - 1;
    final y0 = math.max(0, (_mercY(n) * side).floor());
    final y1 = math.min(side - 1, (_mercY(s) * side).ceil() - 1);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        out.add((z: z, x: x, y: y));
      }
    }
  }
  return out;
}

class StreetPlan {
  const StreetPlan(this.zv, this.draw, this.fetch, this.cells, this.visible);
  final double zv;
  final bool draw;
  final bool fetch;
  final List<String> cells;
  final int visible;

  static const StreetPlan none = StreetPlan(0, false, false, [], 0);
}

StreetPlan planStreetCells({
  required double cx,
  required double cy,
  required double pxPerDeg,
  required double width,
  required double height,
  bool on = true,
}) {
  final zv = streetZvOf(pxPerDeg);
  final draw = on && zv >= kStreet.drawZv;
  final fetch = draw && zv >= kStreet.fetchZv;
  if (!draw) return StreetPlan(zv, false, false, const [], 0);
  final hw = width / 2 / pxPerDeg, hh = height / 2 / pxPerDeg;
  final w = math.max(-180.0, cx - hw), e = math.min(180.0, cx + hw);
  final s = math.max(-85.0511287798, cy - hh), n = math.min(85.0511287798, cy + hh);
  if (w >= e || s >= n) return StreetPlan(zv, draw, fetch, const [], 0);
  final c0 = ((w + 180) / _p5).floor(), c1 = ((e + 180) / _p5).ceil() - 1;
  final r0 = ((s + 90) / _p5).floor(), r1 = ((n + 90) / _p5).ceil() - 1;
  final list = <(double, String)>[];
  for (var r = r0; r <= r1; r++) {
    for (var c = c0; c <= c1; c++) {
      final lat = -90 + (r + 0.5) * _p5, lng = -180 + (c + 0.5) * _p5;
      final dy = lat - cy, dx = lng - cx;
      list.add((dy * dy + dx * dx, encodeGeoGeohash(lat, lng, 5)));
    }
  }
  list.sort((a, b) {
    final d = a.$1.compareTo(b.$1);
    return d != 0 ? d : a.$2.compareTo(b.$2);
  });
  return StreetPlan(zv, draw, fetch,
      [for (final x in list.take(kStreet.maxCells)) x.$2], list.length);
}

int? streetTileZoomFor(double zv, List<int> available) {
  final a = [...available]..sort();
  int? pick;
  for (final z in a) {
    if (z <= zv + 0.25) pick = z;
  }
  return pick ?? (a.isEmpty ? null : a.first);
}

({List<String> start, int waitMs}) nextStreetFetches({
  required List<int> sent,
  required int inflight,
  required List<String> missing,
  required int now,
}) {
  final recent = [for (final t in sent) if (now - t < _minuteMs) t]..sort();
  final slots = math.max(
      0,
      math.min(kStreet.concurrent - inflight,
          kStreet.cellsPerMinute - recent.length));
  final order = [...missing]..sort();
  final start = order.take(slots).toList();
  final capped =
      order.length > start.length && recent.length >= kStreet.cellsPerMinute;
  return (
    start: start,
    waitMs: capped ? recent.first + _minuteMs - now : 0,
  );
}

enum StreetAction { ok, negative, pause, stop }

({StreetAction kind, int ms}) streetStatusAction(int status) {
  if (status == 200) return (kind: StreetAction.ok, ms: 0);
  if (status == 413) {
    return (kind: StreetAction.negative, ms: kStreet.tooLargeRetryMs);
  }
  if (status == 0 || status == 429 || status >= 500) {
    return (kind: StreetAction.pause, ms: kStreet.unavailableRetryMs);
  }
  return (kind: StreetAction.stop, ms: 0);
}

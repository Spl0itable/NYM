import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// The equirectangular camera (`view{cx,cy,zoom}` in geohash-globe.js), plus the
/// `project`/`unproject` math ported verbatim. lng/lat ↔ pixel is a plain linear
/// mapping; the camera centers on (cx, cy) in degrees at a given zoom (1–16).
@immutable
class GeoView {
  const GeoView({this.cx = 0, this.cy = 0, this.zoom = 1});

  /// Center longitude (degrees).
  final double cx;

  /// Center latitude (degrees).
  final double cy;

  /// Zoom factor (minZoom..maxZoom).
  final double zoom;

  static const double minZoom = 1;
  static const double maxZoom = 16;

  GeoView copyWith({double? cx, double? cy, double? zoom}) =>
      GeoView(cx: cx ?? this.cx, cy: cy ?? this.cy, zoom: zoom ?? this.zoom);

  /// Pixels-per-degree at zoom 1, fitting the world to [size] (same as
  /// `baseScale()`: `max(w/360, h/180)` — fills the viewport, may crop).
  static double baseScale(Size size) =>
      math.max(size.width / 360.0, size.height / 180.0);

  /// Effective pixels-per-degree at the current zoom.
  double scale(Size size) => baseScale(size) * zoom;

  /// lng/lat → canvas pixel (`project`).
  Offset project(double lng, double lat, Size size) {
    final s = scale(size);
    return Offset(
      (lng - cx) * s + size.width / 2,
      (cy - lat) * s + size.height / 2,
    );
  }

  /// canvas pixel → lng/lat (`unproject`).
  ({double lng, double lat}) unproject(double x, double y, Size size) {
    final s = scale(size);
    return (
      lng: (x - size.width / 2) / s + cx,
      lat: cy - (y - size.height / 2) / s,
    );
  }

  /// Clamps zoom to [minZoom, maxZoom] and keeps the viewport over the world
  /// (recenters axes that are fully visible), matching `clampView()`.
  GeoView clamped(Size size) {
    var z = zoom.clamp(minZoom, maxZoom);
    final s = baseScale(size) * z;
    final halfLng = (size.width / 2) / s;
    final halfLat = (size.height / 2) / s;
    var ncx = cx, ncy = cy;
    if (halfLng >= 180) {
      ncx = 0;
    } else {
      ncx = ncx.clamp(-180 + halfLng, 180 - halfLng);
    }
    if (halfLat >= 90) {
      ncy = 0;
    } else {
      ncy = ncy.clamp(-90 + halfLat, 90 - halfLat);
    }
    return GeoView(cx: ncx, cy: ncy, zoom: z);
  }

  /// Zoom by [factor] keeping the geo point under pixel [focus] fixed
  /// (zoom-to-cursor), then clamp. Ports the `onWheel`/`zoomBy` math.
  GeoView zoomedAt(double factor, Offset focus, Size size) {
    final before = unproject(focus.dx, focus.dy, size);
    final z = (zoom * factor).clamp(minZoom, maxZoom);
    final mid = copyWith(zoom: z);
    final after = mid.unproject(focus.dx, focus.dy, size);
    return GeoView(
      cx: cx + (before.lng - after.lng),
      cy: cy + (before.lat - after.lat),
      zoom: z,
    ).clamped(size);
  }

  /// Fits [bounds] (lat:[lo,hi], lng:[lo,hi]) with [padding], as `zoomToBounds`.
  GeoView fitBounds(
    ({double latLo, double latHi, double lngLo, double lngHi}) bounds,
    Size size, {
    double padding = 0.7,
  }) {
    final lngSpan = math.max(1e-6, bounds.lngHi - bounds.lngLo);
    final latSpan = math.max(1e-6, bounds.latHi - bounds.latLo);
    final s = baseScale(size);
    final zLng = (size.width * padding) / (lngSpan * s);
    final zLat = (size.height * padding) / (latSpan * s);
    final target = math.min(zLng, zLat).clamp(minZoom, maxZoom);
    return GeoView(
      cx: (bounds.lngLo + bounds.lngHi) / 2,
      cy: (bounds.latLo + bounds.latHi) / 2,
      zoom: target,
    ).clamped(size);
  }
}

/// Geohash cell longitude/latitude step at a given precision, matching
/// `geohashCellSize` (lng gets `ceil(5p/2)` bits, lat `floor(5p/2)`).
({double lngStep, double latStep}) geohashCellSize(int precision) {
  final totalBits = 5 * precision;
  final lngBits = (totalBits / 2).ceil();
  final latBits = (totalBits / 2).floor();
  return (
    lngStep: 360.0 / math.pow(2, lngBits),
    latStep: 180.0 / math.pow(2, latBits),
  );
}

/// Auto grid precision from the current pixel scale (`computeGridPrecision`):
/// the finest precision whose next-level cell would still be ≥ 50px wide.
int computeGridPrecision(GeoView view, Size size) {
  final s = view.scale(size);
  var p = 1;
  while (p < 9) {
    final next = geohashCellSize(p + 1);
    if (next.lngStep * s < 50) break;
    p++;
  }
  return p;
}

/// Decodes a geohash to its bounding box (`decodeGeohashBoundsRaw`); null if a
/// character is invalid.
({double latLo, double latHi, double lngLo, double lngHi})? geohashBounds(
    String geohash) {
  const base32 = '0123456789bcdefghjkmnpqrstuvwxyz';
  var latLo = -90.0, latHi = 90.0, lngLo = -180.0, lngHi = 180.0;
  var isEven = true;
  for (final ch in geohash.toLowerCase().split('')) {
    final cd = base32.indexOf(ch);
    if (cd < 0) return null;
    for (var j = 4; j >= 0; j--) {
      final bit = (cd >> j) & 1;
      if (isEven) {
        final mid = (lngLo + lngHi) / 2;
        if (bit == 1) {
          lngLo = mid;
        } else {
          lngHi = mid;
        }
      } else {
        final mid = (latLo + latHi) / 2;
        if (bit == 1) {
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

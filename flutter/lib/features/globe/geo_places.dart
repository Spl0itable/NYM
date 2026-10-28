import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

const String kGeoPlacesLoAsset = 'assets/data/geo-places-lo.nyp.gz';
const String kGeoPlacesHiAsset = 'assets/data/geo-places-hi.nyp.gz';
const List<String> kGeoPlacesAssets = [kGeoPlacesLoAsset, kGeoPlacesHiAsset];
const String kGeoPlacesCredit =
    'Places: GeoNames (geonames.org), CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/), filtered.';
const List<String> kGeoMapCredits = [
  'Streets: © OpenStreetMap contributors (ODbL 1.0), via Protomaps',
  kGeoPlacesCredit,
  'Natural Earth',
];

const double kGeoPlacesLoZv = 6;
const double kGeoPlacesHiZv = 11;
const double kGeoPlacesDotMaxZv = 12;
const double kGeoPlacesMarginPx = 32;
const int kGeoPlacesMaxCandidates = 200;
const int kGeoPlacesMaxLabels = 60;
const double kGeoPlacesHalo = 3;
const double _zvEps = 1e-6;
const int _gridW = 360;
const int _gridH = 180;

class GeoPlacePack {
  GeoPlacePack({
    required this.count,
    required this.scale,
    required this.lat,
    required this.lng,
    required this.meta,
    required this.names,
    required this.nameOff,
    required this.cellStart,
    required this.cellItems,
  });

  final int count;
  final int scale;
  final Int32List lat;
  final Int32List lng;
  final Uint8List meta;
  final Uint8List names;
  final Uint32List nameOff;
  final Uint32List cellStart;
  final Uint32List cellItems;
  final Map<int, String> _nameCache = {};

  String nameOf(int i) {
    final hit = _nameCache[i];
    if (hit != null) return hit;
    if (_nameCache.length > 4000) _nameCache.clear();
    final s = utf8.decode(
        Uint8List.sublistView(names, nameOff[i], nameOff[i + 1]),
        allowMalformed: true);
    _nameCache[i] = s;
    return s;
  }
}

class GeoPlaceCandidate {
  const GeoPlaceCandidate({
    required this.pack,
    required this.i,
    required this.lat,
    required this.lng,
    required this.zv,
    required this.kind,
    required this.pc,
    required this.name,
  });

  final int pack;
  final int i;
  final double lat;
  final double lng;
  final double zv;
  final int kind;
  final int pc;
  final String name;
}

class GeoPlaceStyle {
  const GeoPlaceStyle(this.fontSize, this.weight,
      {this.italic = false, this.admin = false});

  final double fontSize;
  final FontWeight weight;
  final bool italic;
  final bool admin;
}

const List<GeoPlaceStyle> _styles = [
  GeoPlaceStyle(12, FontWeight.w600),
  GeoPlaceStyle(12, FontWeight.w600),
  GeoPlaceStyle(11, FontWeight.w500),
  GeoPlaceStyle(10, FontWeight.w500),
  GeoPlaceStyle(10, FontWeight.w500, italic: true, admin: true),
];

double geoZvOf(double pxPerDeg) => math.log(pxPerDeg * 360 / 256) / math.ln2;

int geoPlacesWanted(double zv) =>
    zv >= kGeoPlacesHiZv ? 2 : (zv >= kGeoPlacesLoZv ? 1 : 0);

GeoPlaceStyle geoPlaceStyle(int kind) =>
    _styles[kind >= 0 && kind < _styles.length ? kind : 3];

bool geoPlaceHasDot(int kind, double zv) =>
    kind <= 2 && zv < kGeoPlacesDotMaxZv;

int _gridX(double deg) => (deg + 180).floor().clamp(0, _gridW - 1);

int _gridY(double deg) => (deg + 90).floor().clamp(0, _gridH - 1);

GeoPlacePack decodeGeoPlacesGz(Uint8List gz) =>
    decodeGeoPlaces(Uint8List.fromList(gzip.decode(gz)));

GeoPlacePack decodeGeoPlaces(Uint8List b) {
  if (b.length < 24) throw const FormatException('places: short header');
  if (b[0] != 0x4e || b[1] != 0x59 || b[2] != 0x50 || b[3] != 0x31) {
    throw const FormatException('places: bad magic');
  }
  final bd = ByteData.sublistView(b);
  final count = bd.getUint32(4, Endian.little);
  final latBytes = bd.getUint32(8, Endian.little);
  final lngBytes = bd.getUint32(12, Endian.little);
  final nameBytes = bd.getUint32(16, Endian.little);
  final scale = bd.getUint32(20, Endian.little);
  if (scale == 0 ||
      24 + latBytes + lngBytes + 2 * count + nameBytes != b.length) {
    throw const FormatException('places: bad lengths');
  }
  var pos = 24;
  int varint(int end) {
    var v = 0, shift = 0, byte = 0;
    do {
      if (pos >= end) throw const FormatException('places: truncated');
      byte = b[pos++];
      v |= (byte & 127) << shift;
      shift += 7;
    } while (byte & 128 != 0);
    return v;
  }

  Int32List column(int end) {
    final out = Int32List(count);
    var prev = 0;
    for (var i = 0; i < count; i++) {
      final v = varint(end);
      prev += (v >> 1) ^ -(v & 1);
      out[i] = prev;
    }
    if (pos != end) throw const FormatException('places: column length');
    return out;
  }

  final lat = column(24 + latBytes);
  final lng = column(24 + latBytes + lngBytes);
  final meta = Uint8List.fromList(Uint8List.sublistView(b, pos, pos + 2 * count));
  pos += 2 * count;
  final nameEnd = pos + nameBytes;
  final nameOff = Uint32List(count + 1);
  final names = Uint8List(nameBytes);
  var w = 0;
  for (var i = 0; i < count; i++) {
    final len = varint(nameEnd);
    if (pos + len > nameEnd) throw const FormatException('places: truncated');
    nameOff[i] = w;
    names.setRange(w, w + len, b, pos);
    w += len;
    pos += len;
  }
  nameOff[count] = w;
  if (pos != nameEnd) throw const FormatException('places: names length');
  final cellStart = Uint32List(_gridW * _gridH + 1);
  final cellOf = Uint32List(count);
  for (var i = 0; i < count; i++) {
    final c = _gridY(lat[i] / scale) * _gridW + _gridX(lng[i] / scale);
    cellOf[i] = c;
    cellStart[c + 1]++;
  }
  for (var c = 0; c < _gridW * _gridH; c++) {
    cellStart[c + 1] += cellStart[c];
  }
  final fill = Uint32List.fromList(Uint32List.sublistView(cellStart, 0, _gridW * _gridH));
  final cellItems = Uint32List(count);
  for (var i = 0; i < count; i++) {
    cellItems[fill[cellOf[i]]++] = i;
  }
  return GeoPlacePack(
    count: count,
    scale: scale,
    lat: lat,
    lng: lng,
    meta: meta,
    names: names,
    nameOff: nameOff,
    cellStart: cellStart,
    cellItems: cellItems,
  );
}

({
  List<GeoPlacePack?> packs,
  double cx,
  double cy,
  double pxPerDeg,
  double width,
  double height,
  List<GeoPlaceCandidate> out,
})? _lastSelect;

bool _sameSelect(List<GeoPlacePack?> packs, double cx, double cy,
    double pxPerDeg, double width, double height) {
  final m = _lastSelect;
  if (m == null ||
      m.cx != cx ||
      m.cy != cy ||
      m.pxPerDeg != pxPerDeg ||
      m.width != width ||
      m.height != height ||
      m.packs.length != packs.length) {
    return false;
  }
  for (var p = 0; p < packs.length; p++) {
    if (!identical(m.packs[p], packs[p])) return false;
  }
  return true;
}

List<GeoPlaceCandidate> selectGeoPlaces(
  List<GeoPlacePack?> packs, {
  required double cx,
  required double cy,
  required double pxPerDeg,
  required double width,
  required double height,
}) {
  if (_sameSelect(packs, cx, cy, pxPerDeg, width, height)) {
    return _lastSelect!.out;
  }
  final zv = geoZvOf(pxPerDeg);
  final lim = zv * 2 + _zvEps;
  final hw = (width / 2 + kGeoPlacesMarginPx) / pxPerDeg;
  final hh = (height / 2 + kGeoPlacesMarginPx) / pxPerDeg;
  final x0 = _gridX(cx - hw), x1 = _gridX(cx + hw);
  final y0 = _gridY(cy - hh), y1 = _gridY(cy + hh);
  final hits = <int>[];
  for (var p = 0; p < packs.length; p++) {
    final pk = packs[p];
    if (pk == null) continue;
    final meta = pk.meta, lat = pk.lat, lng = pk.lng, scale = pk.scale;
    for (var gy = y0; gy <= y1; gy++) {
      for (var gx = x0; gx <= x1; gx++) {
        final c = gy * _gridW + gx;
        for (var k = pk.cellStart[c], e = pk.cellStart[c + 1]; k < e; k++) {
          final i = pk.cellItems[k];
          if (meta[2 * i] > lim) break;
          if ((lng[i] / scale - cx).abs() > hw ||
              (lat[i] / scale - cy).abs() > hh) {
            continue;
          }
          hits
            ..add(p)
            ..add(i);
        }
      }
    }
  }
  final n = hits.length ~/ 2;
  final idx = List<int>.generate(n, (j) => j);
  int key(int j, int o) => packs[hits[2 * j]]!.meta[2 * hits[2 * j + 1] + o];
  idx.sort((a, b) {
    final za = key(a, 0), zb = key(b, 0);
    if (za != zb) return za - zb;
    final ma = key(a, 1), mb = key(b, 1);
    if ((ma >> 5) != (mb >> 5)) return (ma >> 5) - (mb >> 5);
    if ((ma & 31) != (mb & 31)) return (mb & 31) - (ma & 31);
    final dp = hits[2 * a] - hits[2 * b];
    return dp != 0 ? dp : hits[2 * a + 1] - hits[2 * b + 1];
  });
  final out = <GeoPlaceCandidate>[];
  for (var j = 0; j < n && out.length < kGeoPlacesMaxCandidates; j++) {
    final p = hits[2 * idx[j]], i = hits[2 * idx[j] + 1];
    final pk = packs[p]!;
    final m = pk.meta[2 * i + 1];
    out.add(GeoPlaceCandidate(
      pack: p,
      i: i,
      lat: pk.lat[i] / pk.scale,
      lng: pk.lng[i] / pk.scale,
      zv: pk.meta[2 * i] / 2,
      kind: m >> 5,
      pc: m & 31,
      name: pk.nameOf(i),
    ));
  }
  final result = List<GeoPlaceCandidate>.unmodifiable(out);
  _lastSelect = (
    packs: List<GeoPlacePack?>.of(packs),
    cx: cx,
    cy: cy,
    pxPerDeg: pxPerDeg,
    width: width,
    height: height,
    out: result,
  );
  return result;
}

typedef GeoPlacePackLoader = Future<GeoPlacePack?> Function(int pack);

final List<Future<GeoPlacePack?>?> _bundledPacks = [null, null];

Future<GeoPlacePack?> loadBundledGeoPlacePack(int pack) =>
    _bundledPacks[pack] ??= () async {
      try {
        final data = await rootBundle.load(kGeoPlacesAssets[pack]);
        final bytes = Uint8List.sublistView(data);
        return await compute(decodeGeoPlacesGz, bytes);
      } catch (_) {
        _bundledPacks[pack] = null;
        return null;
      }
    }();

final geoPlacePackLoaderProvider =
    Provider<GeoPlacePackLoader>((ref) => loadBundledGeoPlacePack);

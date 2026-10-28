import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

class MvtFeature {
  const MvtFeature(this.id, this.type, this.props, this.cmds);
  final int? id;
  final int type;
  final Map<String, Object?> props;
  final List<int> cmds;
}

class MvtLayer {
  MvtLayer(this.name, this.version, this.extent, this.features);
  final String name;
  final int version;
  final int extent;
  final List<MvtFeature> features;
}

class _Reader {
  _Reader(this.b);
  final Uint8List b;
  int i = 0;

  int varint() {
    var v = 0, shift = 0, x = 0;
    do {
      x = b[i++];
      v |= (x & 0x7f) << shift;
      shift += 7;
    } while (x & 0x80 != 0);
    return v;
  }

  void skip(int wt) {
    if (wt == 0) {
      varint();
    } else if (wt == 1) {
      i += 8;
    } else if (wt == 2) {
      final n = varint();
      i += n;
    } else if (wt == 5) {
      i += 4;
    } else {
      throw FormatException('wire type $wt');
    }
  }

  String string() {
    final n = varint();
    final s = utf8.decode(b.sublist(i, i + n), allowMalformed: true);
    i += n;
    return s;
  }

  List<int> packed() {
    final n = varint(), end = i + n, out = <int>[];
    while (i < end) {
      out.add(varint());
    }
    return out;
  }

  ByteData view(int n) => ByteData.sublistView(b, i, i + n);
}

Object? _value(_Reader r, int end) {
  Object? v;
  while (r.i < end) {
    final k = r.varint(), f = k >> 3, wt = k & 7;
    if (f == 1) {
      v = r.string();
    } else if (f == 2) {
      v = r.view(4).getFloat32(0, Endian.little);
      r.i += 4;
    } else if (f == 3) {
      v = r.view(8).getFloat64(0, Endian.little);
      r.i += 8;
    } else if (f == 4) {
      v = r.varint();
    } else if (f == 5) {
      v = r.varint();
    } else if (f == 6) {
      final z = r.varint();
      v = z.isOdd ? -((z + 1) ~/ 2) : z ~/ 2;
    } else if (f == 7) {
      v = r.varint() != 0;
    } else {
      r.skip(wt);
    }
  }
  return v;
}

List<MvtLayer> decodeMvt(Uint8List b) {
  final r = _Reader(b);
  final layers = <MvtLayer>[];
  while (r.i < b.length) {
    final k = r.varint();
    if (k >> 3 != 3 || k & 7 != 2) {
      r.skip(k & 7);
      continue;
    }
    final n = r.varint(), end = r.i + n;
    var name = '', version = 1, extent = 4096;
    final keys = <String>[];
    final values = <Object?>[];
    final raw = <(int?, int, List<int>, List<int>)>[];
    while (r.i < end) {
      final t = r.varint(), f = t >> 3, wt = t & 7;
      if (f == 1) {
        name = r.string();
      } else if (f == 2) {
        final m = r.varint(), fe = r.i + m;
        int? id;
        var type = 0;
        var tags = const <int>[], cmds = const <int>[];
        while (r.i < fe) {
          final q = r.varint(), ff = q >> 3;
          if (ff == 1) {
            id = r.varint();
          } else if (ff == 2) {
            tags = r.packed();
          } else if (ff == 3) {
            type = r.varint();
          } else if (ff == 4) {
            cmds = r.packed();
          } else {
            r.skip(q & 7);
          }
        }
        raw.add((id, type, tags, cmds));
      } else if (f == 3) {
        keys.add(r.string());
      } else if (f == 4) {
        final m = r.varint(), ve = r.i + m;
        values.add(_value(r, ve));
        r.i = ve;
      } else if (f == 5) {
        extent = r.varint();
      } else if (f == 15) {
        version = r.varint();
      } else {
        r.skip(wt);
      }
    }
    final feats = <MvtFeature>[];
    for (final (id, type, tags, cmds) in raw) {
      final props = <String, Object?>{};
      for (var j = 0; j + 1 < tags.length; j += 2) {
        if (tags[j] < keys.length && tags[j + 1] < values.length) {
          props[keys[tags[j]]] = values[tags[j + 1]];
        }
      }
      feats.add(MvtFeature(id, type, props, cmds));
    }
    layers.add(MvtLayer(name, version, extent, feats));
  }
  return layers;
}

List<List<int>> mvtParts(List<int> cmds) {
  final parts = <List<int>>[];
  List<int>? cur;
  var x = 0, y = 0, i = 0;
  while (i < cmds.length) {
    final c = cmds[i++], id = c & 7, n = c >> 3;
    if (id == 7) {
      cur = null;
      continue;
    }
    for (var k = 0; k < n && i + 1 < cmds.length; k++) {
      final dx = cmds[i++], dy = cmds[i++];
      x += (dx >> 1) ^ -(dx & 1);
      y += (dy >> 1) ^ -(dy & 1);
      if (id == 1 || cur == null) {
        cur = <int>[];
        parts.add(cur);
      }
      cur.add(x);
      cur.add(y);
    }
  }
  return parts;
}

double _ringArea(List<int> r) {
  var a = 0.0;
  final n = r.length ~/ 2;
  for (var i = 0; i < n; i++) {
    final j = (i + 1) % n;
    a += r[2 * i] * r[2 * j + 1] - r[2 * j] * r[2 * i + 1];
  }
  return a / 2;
}

List<List<List<int>>> mvtPolygons(List<List<int>> parts) {
  final polys = <List<List<int>>>[];
  for (final r in parts) {
    final a = _ringArea(r);
    if (a == 0 || r.length < 6) continue;
    if (a > 0 || polys.isEmpty) {
      polys.add([r]);
    } else {
      polys.last.add(r);
    }
  }
  return polys;
}

List<List<int>> _pairs(List<int> r) =>
    [for (var i = 0; i + 1 < r.length; i += 2) [r[i], r[i + 1]]];

List<Object> mvtGeometry(int type, List<int> cmds) {
  final parts = mvtParts(cmds);
  if (type == 1) return [for (final p in parts) ..._pairs(p)];
  if (type == 2) return [for (final p in parts) if (p.length >= 4) _pairs(p)];
  return [
    for (final poly in mvtPolygons(parts)) [for (final r in poly) _pairs(r)]
  ];
}

double streetTileLat(double y, int z) =>
    (2 * math.atan(math.exp(math.pi * (1 - 2 * y / math.pow(2, z)))) -
        math.pi / 2) *
    180 /
    math.pi;

({double lng, double lat, double u, double w}) streetReproject(
    int z, int x, int y, num px, num py, int extent) {
  final n = math.pow(2, z).toDouble();
  final lng = (x + px / extent) / n * 360 - 180;
  final lat = streetTileLat(y + py / extent, z);
  final latN = streetTileLat(y.toDouble(), z);
  final latS = streetTileLat(y + 1.0, z);
  return (lng: lng, lat: lat, u: px / extent, w: (latN - lat) / (latN - latS));
}

const Set<String> kStreetGreen = {
  'park', 'forest', 'wood', 'grass', 'garden', 'cemetery', 'golf_course',
  'nature_reserve', 'playground', 'pitch', 'recreation_ground',
  'village_green', 'meadow', 'scrub', 'allotments',
};

const Map<String, String> _roadClass = {
  'highway': 'hw',
  'major_road': 'major',
  'path': 'path',
  'rail': 'rail',
};

const Map<String, int> kStreetLabelRank = {
  'hw': 0,
  'major': 1,
  'minor': 2,
  'service': 3,
  'path': 4,
  'river': 5,
  'stream': 5,
};

String? classifyStreet(String layer, Map<String, Object?> p, int type) {
  switch (layer) {
    case 'earth':
      return type == 3 ? 'land' : null;
    case 'water':
      if (type == 3) return 'water';
      if (type == 2) {
        return p['kind'] == 'river' || p['kind'] == 'canal' ? 'river' : 'stream';
      }
      if (type == 1) {
        final n = p['name'];
        return n is String && n.isNotEmpty ? 'waterLabel' : null;
      }
      return null;
    case 'landuse':
      if (type != 3) return null;
      return kStreetGreen.contains(p['kind']) ? 'green' : 'landuse';
    case 'buildings':
      return type == 3 ? 'bld' : null;
    case 'roads':
      if (type != 2) return null;
      if (p['kind'] == 'minor_road') {
        return p['kind_detail'] == 'service' ? 'service' : 'minor';
      }
      return _roadClass[p['kind']];
  }
  return null;
}

class StreetGroup {
  StreetGroup(this.cls, this.st, this.mz, this.poly, this.pts, this.parts);
  final String cls;
  final int st;
  final double mz;
  final bool poly;
  final Float32List pts;
  final Uint32List parts;
}

class StreetLabelSource {
  StreetLabelSource(this.name, this.rank, this.point, this.pts);
  final String name;
  final int rank;
  final bool point;
  final Float32List pts;
}

class StreetTile {
  StreetTile(this.z, this.x, this.y, this.w, this.h, this.lngW, this.latN,
      this.groups, this.labels);
  final int z;
  final int x;
  final int y;
  final double w;
  final double h;
  final double lngW;
  final double latN;
  final List<StreetGroup> groups;
  final List<StreetLabelSource> labels;

  String get key => '$z/$x/$y';
}

class _GroupBuilder {
  _GroupBuilder(this.cls, this.st, this.mz, this.poly);
  final String cls;
  final int st;
  final double mz;
  final bool poly;
  final List<double> pts = [];
  final List<int> parts = [];
}

StreetTile buildStreetTile(Uint8List raw, int z, int x, int y) {
  final n = math.pow(2, z).toDouble();
  final w = 360 / n;
  final latN = streetTileLat(y.toDouble(), z);
  final h = latN - streetTileLat(y + 1.0, z);
  final groups = <String, _GroupBuilder>{};
  final labels = <StreetLabelSource>[];
  final yCache = <int, double>{};
  var lastExt = -1;
  double ly(int py, int ext) {
    if (ext != lastExt) {
      yCache.clear();
      lastExt = ext;
    }
    return yCache[py] ??= latN - streetTileLat(y + py / ext, z);
  }

  Float32List local(List<int> r, int ext) {
    final out = Float32List(r.length);
    final sx = w / ext;
    for (var i = 0; i + 1 < r.length; i += 2) {
      out[i] = r[i] * sx;
      out[i + 1] = ly(r[i + 1], ext);
    }
    return out;
  }

  for (final l in decodeMvt(raw)) {
    final ext = l.extent == 0 ? 4096 : l.extent;
    for (final f in l.features) {
      final cls = classifyStreet(l.name, f.props, f.type);
      if (cls == null) continue;
      final parts = mvtParts(f.cmds);
      if (cls == 'waterLabel') {
        for (final r in parts) {
          if (r.length < 2) continue;
          labels.add(StreetLabelSource(
              '${f.props['name']}', 6, true, local(r.sublist(0, 2), ext)));
        }
        continue;
      }
      final road = l.name == 'roads';
      final st = road
          ? (f.props['is_tunnel'] == true
              ? 1
              : (f.props['is_bridge'] == true ? 2 : 0))
          : 0;
      final mzv = f.props['min_zoom'];
      final mz = road && mzv is num ? mzv.toDouble() : 0.0;
      final poly = f.type == 3;
      final g = groups.putIfAbsent(
          '$cls|$st|$mz', () => _GroupBuilder(cls, st, mz, poly));
      final use = poly
          ? [for (final p in mvtPolygons(parts)) ...p]
          : [for (final r in parts) if (r.length >= 4) r];
      final rank = kStreetLabelRank[cls];
      for (final r in use) {
        g.parts.add(g.pts.length ~/ 2);
        final loc = local(r, ext);
        g.pts.addAll(loc);
        if (!poly && rank != null) {
          final nm = f.props['name'];
          final ref = f.props['ref'];
          final name = nm is String && nm.isNotEmpty
              ? nm
              : (cls == 'hw' && ref is String ? ref : '');
          if (name.isNotEmpty && (road || nm is String)) {
            labels.add(StreetLabelSource(name, rank, false, loc));
          }
        }
      }
    }
  }
  final out = <StreetGroup>[];
  for (final g in groups.values) {
    if (g.parts.isEmpty) continue;
    g.parts.add(g.pts.length ~/ 2);
    out.add(StreetGroup(g.cls, g.st, g.mz, g.poly, Float32List.fromList(g.pts),
        Uint32List.fromList(g.parts)));
  }
  return StreetTile(z, x, y, w, h, x / n * 360 - 180, latN, out, labels);
}

class StreetTileJob {
  const StreetTileJob(
      {required this.z, required this.x, required this.y, required this.gz});
  final int z;
  final int x;
  final int y;
  final Uint8List gz;
}

List<StreetTile?> decodeStreetTilesSync(List<StreetTileJob> jobs) => [
      for (final j in jobs)
        j.gz.isEmpty
            ? null
            : _tryBuild(j),
    ];

StreetTile? _tryBuild(StreetTileJob j) {
  try {
    return buildStreetTile(
        Uint8List.fromList(gzip.decode(j.gz)), j.z, j.x, j.y);
  } catch (_) {
    return null;
  }
}

Future<List<StreetTile?>> decodeStreetTiles(List<StreetTileJob> jobs) =>
    Isolate.run(() => decodeStreetTilesSync(jobs));

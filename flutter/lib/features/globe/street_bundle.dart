import 'dart:typed_data';

final RegExp kStreetCellRe = RegExp(r'^[0-9b-hjkmnp-z]{5}$');

class StreetBundleError implements Exception {
  const StreetBundleError(this.code);
  final String code;

  @override
  String toString() => 'StreetBundleError($code)';
}

class StreetBundleEntry {
  const StreetBundleEntry(this.z, this.flags, this.x, this.y, this.off, this.len);
  final int z;
  final int flags;
  final int x;
  final int y;
  final int off;
  final int len;

  bool get missing => flags & 1 != 0 || len == 0;
  bool get buildingsDropped => flags & 2 != 0;
  String get key => '$z/$x/$y';
}

class StreetBundle {
  StreetBundle._(this.bytes, this.version, this.level, this.zmin, this.zmax,
      this.cell, this.flags, this.count, this.build, this.payload, this.layers,
      this.tiles, this.base);

  final Uint8List bytes;
  final int version;
  final int level;
  final int zmin;
  final int zmax;
  final String cell;
  final int flags;
  final int count;
  final int build;
  final int payload;
  final int layers;
  final List<StreetBundleEntry> tiles;
  final int base;

  Uint8List tileBytes(StreetBundleEntry t) =>
      Uint8List.sublistView(bytes, base + t.off, base + t.off + t.len);

  List<int> get availableZooms => ({for (final t in tiles) t.z}.toList()..sort());
}

StreetBundle parseStreetBundle(Uint8List b, {String? expectCell}) {
  if (b.length < 32 || String.fromCharCodes(b.sublist(0, 4)) != 'NMT1') {
    throw const StreetBundleError('bad-magic');
  }
  if (b[4] != 1) throw const StreetBundleError('bad-version');
  final d = ByteData.sublistView(b);
  final n = d.getUint16(14, Endian.little);
  final payload = d.getUint32(20, Endian.little);
  final base = 32 + 16 * n;
  if (n > 512) throw const StreetBundleError('too-many-tiles');
  if (b.length < base) throw const StreetBundleError('truncated-index');
  if (b.length != base + payload) throw const StreetBundleError('bad-length');
  final cell = String.fromCharCodes(b.sublist(8, 13));
  if (!kStreetCellRe.hasMatch(cell)) throw const StreetBundleError('bad-cell');
  final zmin = b[6], zmax = b[7];
  final tiles = <StreetBundleEntry>[];
  for (var i = 0; i < n; i++) {
    final o = 32 + i * 16;
    final t = StreetBundleEntry(
      b[o],
      b[o + 1],
      d.getUint16(o + 2, Endian.little),
      d.getUint16(o + 4, Endian.little),
      d.getUint32(o + 8, Endian.little),
      d.getUint32(o + 12, Endian.little),
    );
    final side = 1 << t.z;
    if (t.z < zmin || t.z > zmax || t.x >= side || t.y >= side) {
      throw const StreetBundleError('bad-entry');
    }
    if (t.off + t.len > payload) throw const StreetBundleError('bad-range');
    tiles.add(t);
  }
  if (expectCell != null && cell != expectCell) {
    throw const StreetBundleError('cell-mismatch');
  }
  return StreetBundle._(b, b[4], b[5], zmin, zmax, cell, b[13], n,
      d.getUint32(16, Endian.little), payload, d.getUint32(24, Endian.little),
      tiles, base);
}

// Golomb-Coded Set filters for gossip sync, transcribed byte for byte from bitchat's `GCSFilter.swift`.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

class GcsParams {
  const GcsParams({
    required this.p,
    required this.m,
    required this.data,
    required this.includedCount,
  });

  final int p;

  /// Hash range (`count * 2^P`) that ids map into.
  final int m;

  final Uint8List data;

  /// Ids actually encoded; with newest-first input the covered set is a newest prefix.
  final int includedCount;
}

class GcsFilter {
  const GcsFilter._();

  /// Highest P accepted from the wire; larger values would overflow the decode shifts.
  static const int maxP = 32;

  /// P from a target false-positive rate (~1/2^P).
  static int deriveP(double targetFpr) {
    final f = math.max(0.000001, math.min(0.25, targetFpr));
    final p = (math.log(1.0 / f) / math.ln2).ceil();
    return math.max(1, p);
  }

  /// Rough element capacity of [sizeBytes], at about `P + 2` bits each.
  static int estimateMaxElements({required int sizeBytes, required int p}) {
    final bits = math.max(8, sizeBytes * 8);
    final per = math.max(3, p + 2);
    return math.max(1, bits ~/ per);
  }

  /// Builds a filter over newest-first [ids]; `m` stays fixed while the tail is trimmed to fit.
  static GcsParams buildFilter({
    required List<Uint8List> ids,
    required int maxBytes,
    required double targetFpr,
  }) {
    final p = deriveP(targetFpr);
    if (ids.isEmpty) {
      return GcsParams(p: p, m: 1, data: Uint8List(0), includedCount: 0);
    }

    final cap = estimateMaxElements(sizeBytes: maxBytes, p: p);
    final range = math.max(1, _hashRange(math.min(ids.length, cap), p));
    final modulo = range;

    Uint8List encodeFirst(int count) {
      final mapped = <int>[
        for (var i = 0; i < count; i++) _mapHash(_h64(ids[i]), modulo),
      ]..sort();
      final normalized = _normalize(mapped, modulo);
      return normalized.isEmpty ? Uint8List(0) : _encode(normalized, p);
    }

    var count = math.min(ids.length, cap);
    var encoded = encodeFirst(count);
    while (encoded.length > maxBytes && count > 1) {
      count = math.max(1, (count * 9) ~/ 10);
      encoded = encodeFirst(count);
    }
    // A single element that still overflows cannot be represented.
    if (encoded.length > maxBytes) {
      return GcsParams(p: p, m: range, data: Uint8List(0), includedCount: 0);
    }
    return GcsParams(
      p: p,
      m: range,
      data: encoded,
      includedCount: encoded.isEmpty ? 0 : count,
    );
  }

  /// Decodes to sorted buckets; bad parameters yield empty, which safely means resend everything.
  static List<int> decodeToSortedSet({
    required int p,
    required int m,
    required Uint8List data,
  }) {
    if (p < 1 || p > maxP || m <= 1) return const [];
    final values = <int>[];
    final reader = _BitReader(data);
    var acc = 0;
    while (true) {
      final q = reader.readUnary();
      if (q == null) break;
      final r = reader.readBits(p);
      if (r == null) break;
      final x = (q << p) + r + 1;
      acc += x;
      if (acc >= m) break;
      values.add(acc);
    }
    return values;
  }

  static bool contains(List<int> sortedValues, int candidate) {
    var lo = 0;
    var hi = sortedValues.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = sortedValues[mid];
      if (v == candidate) return true;
      if (v < candidate) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return false;
  }

  /// The bucket [id] maps to under modulus [m].
  static int bucket(Uint8List id, int m) {
    final modulo = math.max(1, m);
    if (modulo <= 1) return 0;
    return _mapHash(_h64(id), modulo);
  }

  /// First 8 bytes of SHA-256 over the id, top bit cleared to stay positive in signed 64-bit.
  static int _h64(Uint8List id16) {
    final digest = sha256.convert(id16).bytes;
    var x = 0;
    final take = math.min(8, digest.length);
    for (var i = 0; i < take; i++) {
      x = (x << 8) | digest[i];
    }
    return x & 0x7fffffffffffffff;
  }

  static int _hashRange(int count, int p) {
    if (count <= 0) return 1;
    if (p >= 64) return 0xFFFFFFFF;
    // 2^p can exceed 32 bits on its own; check before multiplying.
    if (p >= 32) return 0xFFFFFFFF;
    final multiplier = 1 << p;
    if (count > 0xFFFFFFFF ~/ multiplier) return 0xFFFFFFFF;
    final product = count * multiplier;
    if (product == 0) return 1;
    return product > 0xFFFFFFFF ? 0xFFFFFFFF : product;
  }

  static int _mapHash(int hash, int modulo) {
    if (modulo <= 1) return 0;
    final value = hash % modulo;
    return value == 0 ? 1 : value;
  }

  /// Clamps and dedupes into a strictly increasing sequence, since a zero delta is not representable.
  static List<int> _normalize(List<int> values, int modulo) {
    if (modulo <= 1 || values.isEmpty) return const [];
    final result = <int>[];
    var last = 0;
    for (final value in values) {
      final normalized = math.min(value, modulo - 1);
      if (normalized > last) {
        result.add(normalized);
        last = normalized;
      }
    }
    return result;
  }

  static Uint8List _encode(List<int> sorted, int p) {
    final writer = _BitWriter();
    var prev = 0;
    final mask = p >= 63 ? ~0 : ((1 << p) - 1);
    for (final v in sorted) {
      final x = v - prev;
      prev = v;
      final q = (x - 1) >> p;
      final r = (x - 1) & mask;
      if (q > 0) writer.writeOnes(q);
      writer.writeBit(0);
      writer.writeBits(r, p);
    }
    return writer.toBytes();
  }
}

/// bitchat `PacketIdUtil`: SHA-256(type | senderID | ts BE64 | payload)[:16], excluding TTL and signature.
Uint8List packetIdFor({
  required int type,
  required Uint8List senderID,
  required int timestampMs,
  required Uint8List payload,
}) {
  final ts = Uint8List(8);
  ByteData.view(ts.buffer).setUint64(0, timestampMs, Endian.big);
  final digest = sha256.convert([
    type,
    ...senderID,
    ...ts,
    ...payload,
  ]).bytes;
  return Uint8List.fromList(digest.sublist(0, 16));
}

class _BitWriter {
  final BytesBuilder _buf = BytesBuilder();
  int _cur = 0;
  int _nbits = 0;

  void writeBit(int bit) {
    _cur = ((_cur << 1) | (bit & 1)) & 0xFF;
    _nbits++;
    if (_nbits == 8) {
      _buf.addByte(_cur);
      _cur = 0;
      _nbits = 0;
    }
  }

  void writeOnes(int count) {
    for (var i = 0; i < count; i++) {
      writeBit(1);
    }
  }

  void writeBits(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      writeBit((value >> i) & 1);
    }
  }

  Uint8List toBytes() {
    if (_nbits > 0) {
      _buf.addByte((_cur << (8 - _nbits)) & 0xFF);
      _cur = 0;
      _nbits = 0;
    }
    return _buf.toBytes();
  }
}

/// MSB-first bit reader; returns null once exhausted.
class _BitReader {
  _BitReader(this._data) {
    if (_data.isNotEmpty) {
      _cur = _data[0];
      _left = 8;
    }
  }

  final Uint8List _data;
  int _idx = 0;
  int _cur = 0;
  int _left = 0;

  int? readBit() {
    if (_idx >= _data.length) return null;
    final bit = (_cur >> 7) & 1;
    _cur = (_cur << 1) & 0xFF;
    _left--;
    if (_left == 0) {
      _idx++;
      if (_idx < _data.length) {
        _cur = _data[_idx];
        _left = 8;
      }
    }
    return bit;
  }

  int? readUnary() {
    var q = 0;
    while (true) {
      final b = readBit();
      if (b == null) return null;
      if (b == 1) {
        q++;
      } else {
        break;
      }
    }
    return q;
  }

  int? readBits(int count) {
    var v = 0;
    for (var i = 0; i < count; i++) {
      final b = readBit();
      if (b == null) return null;
      v = (v << 1) | b;
    }
    return v;
  }
}

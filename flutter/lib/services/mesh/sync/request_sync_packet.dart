// REQUEST_SYNC (0x21), transcribed from bitchat's `RequestSyncPacket`; TLV numbers and bit table must match.

import 'dart:typed_data';

import '../protocol/mesh_message_type.dart';
import 'gcs_filter.dart';

/// Packet types a sync round covers, as a trimmed little-endian bitfield; unknown bits map to no type.
class SyncTypeFlags {
  const SyncTypeFlags(this.rawValue);

  /// Drops bits that map to no known type.
  factory SyncTypeFlags.masked(int raw) => SyncTypeFlags(raw & _knownMask);

  final int rawValue;

  // Bit to packet type, as bitchat; courier envelopes, voice frames and Nymchat 0x5x types are deliberately absent.
  static const Map<int, int> _bitToType = {
    0: MeshMessageType.announce,
    1: MeshMessageType.message,
    2: MeshMessageType.leave,
    3: MeshMessageType.noiseHandshake,
    4: MeshMessageType.noiseEncrypted,
    5: MeshMessageType.fragment,
    6: MeshMessageType.requestSync,
    7: MeshMessageType.fileTransfer,
    // Bit 9 is bitchat's prekey-bundle bit.
    9: MeshMessageType.prekeyBundle,
  };

  static final int _knownMask = () {
    var mask = 0;
    for (final bit in _bitToType.keys) {
      mask |= 1 << bit;
    }
    return mask;
  }();

  static int? _bitFor(int type) {
    for (final e in _bitToType.entries) {
      if (e.value == type) return e.key;
    }
    return null;
  }

  /// Announces, public messages and prekey bundles, which must travel while their owner is away.
  static SyncTypeFlags get publicMessages => SyncTypeFlags.masked(
        (1 << 0) | (1 << 1) | (1 << 9),
      );

  bool contains(int meshType) {
    final bit = _bitFor(meshType);
    if (bit == null) return false;
    return (rawValue & (1 << bit)) != 0;
  }

  bool get isEmpty => rawValue == 0;

  /// Little-endian, trailing zero bytes trimmed, at least one byte.
  Uint8List toBytes() {
    final out = <int>[];
    var v = rawValue;
    for (var i = 0; i < 8; i++) {
      out.add(v & 0xFF);
      v >>= 8;
    }
    while (out.length > 1 && out.last == 0) {
      out.removeLast();
    }
    return Uint8List.fromList(out);
  }

  /// Accepts 1–8 bytes only.
  static SyncTypeFlags? decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 8) return null;
    var raw = 0;
    for (var i = bytes.length - 1; i >= 0; i--) {
      raw = (raw << 8) | bytes[i];
    }
    return SyncTypeFlags.masked(raw);
  }
}

/// REQUEST_SYNC TLV (len16 BE): 0x01 P, 0x02 M, 0x03 GCS data, 0x04 types, 0x05 sinceTimestamp.
class RequestSyncPacket {
  const RequestSyncPacket({
    required this.p,
    required this.m,
    required this.data,
    this.types,
    this.sinceTimestampMs,
  });

  final int p;
  final int m;
  final Uint8List data;
  final SyncTypeFlags? types;

  /// Lower bound of the filter, so responders don't resend the older tail every round.
  final int? sinceTimestampMs;

  Uint8List encode() {
    final out = BytesBuilder();
    void tlv(int t, List<int> v) {
      out.addByte(t);
      out.addByte((v.length >> 8) & 0xFF);
      out.addByte(v.length & 0xFF);
      out.add(v);
    }

    tlv(0x01, [p & 0xFF]);
    final mBytes = Uint8List(4);
    ByteData.view(mBytes.buffer).setUint32(0, m, Endian.big);
    tlv(0x02, mBytes);
    tlv(0x03, data);
    final t = types;
    if (t != null) tlv(0x04, t.toBytes());
    final since = sinceTimestampMs;
    if (since != null) {
      final tsBytes = Uint8List(8);
      ByteData.view(tsBytes.buffer).setUint64(0, since, Endian.big);
      tlv(0x05, tsBytes);
    }
    return out.toBytes();
  }

  /// Null for a malformed payload; [maxAcceptBytes] bounds the filter a peer can make us hold.
  static RequestSyncPacket? decode(Uint8List data,
      {int maxAcceptBytes = 1024}) {
    var off = 0;
    int? p;
    int? m;
    Uint8List? payload;
    SyncTypeFlags? types;
    int? since;

    while (off + 3 <= data.length) {
      final t = data[off];
      off += 1;
      if (off + 2 > data.length) return null;
      final len = (data[off] << 8) | data[off + 1];
      off += 2;
      if (off + len > data.length) return null;
      final v = Uint8List.sublistView(data, off, off + len);
      off += len;
      switch (t) {
        case 0x01:
          if (v.length == 1) p = v[0];
        case 0x02:
          if (v.length == 4) {
            var mm = 0;
            for (final b in v) {
              mm = (mm << 8) | b;
            }
            m = mm;
          }
        case 0x03:
          if (v.length > maxAcceptBytes) return null;
          payload = Uint8List.fromList(v);
        case 0x04:
          final decoded = SyncTypeFlags.decode(Uint8List.fromList(v));
          if (decoded != null) types = decoded;
        case 0x05:
          if (v.length == 8) {
            var ts = 0;
            for (final b in v) {
              ts = (ts << 8) | b;
            }
            since = ts;
          }
        default:
        // Forward compatible: an unknown TLV is skipped.
      }
    }

    if (p == null || m == null || payload == null) return null;
    if (p < 1 || p > GcsFilter.maxP || m < 1) return null;
    return RequestSyncPacket(
      p: p,
      m: m,
      data: payload,
      types: types,
      sinceTimestampMs: since,
    );
  }
}

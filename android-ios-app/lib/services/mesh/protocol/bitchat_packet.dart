import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'message_padding.dart';

/// Broadcast recipient id — all `0xFF`, matching bitchat's `SpecialRecipients`.
final Uint8List kBroadcastRecipient = Uint8List(8)..fillRange(0, 8, 0xFF);

/// A decoded bitchat mesh packet — the on-air unit of the BLE mesh. This is a
/// 1:1 port of bitchat's `BitchatPacket` + `BinaryProtocol` (iOS/Android), and
/// wire-compatibility with those clients depends on the exact layout below.
///
/// Header (14 bytes for v1, 16 bytes for v2):
/// ```
/// version:1 | type:1 | ttl:1 | timestamp:8 (u64 BE, ms) | flags:1 |
/// payloadLength:2 (v1) / 4 (v2), BE
/// ```
/// Variable sections: `senderID:8`, `recipientID:8` (if HAS_RECIPIENT),
/// optional v2 route (`count:1` + `count*8`), payload, `signature:64`
/// (if HAS_SIGNATURE). Compressed payloads (HAS_COMPRESSED) prepend the original
/// size (2 bytes v1 / 4 bytes v2) before the raw-DEFLATE bytes.
class BitchatPacket {
  BitchatPacket({
    this.version = 1,
    required this.type,
    required this.senderID,
    this.recipientID,
    required this.timestamp,
    required this.payload,
    this.signature,
    required this.ttl,
    this.route,
  });

  final int version;
  final int type;
  final Uint8List senderID; // 8 bytes
  final Uint8List? recipientID; // 8 bytes when present
  final int timestamp; // u64 milliseconds, big-endian on the wire
  final Uint8List payload;
  Uint8List? signature; // 64 bytes when present
  int ttl;
  final List<Uint8List>? route; // v2 source route, 8 bytes/hop

  bool get isBroadcast =>
      recipientID == null || _bytesEqual(recipientID!, kBroadcastRecipient);

  /// Serialises for transmission (optionally padded to a privacy block size).
  Uint8List? toBytes({bool padding = true}) =>
      BinaryProtocol.encode(this, padding: padding);

  /// Deterministic bytes used for Ed25519 signing/verification: the packet with
  /// no signature and a fixed TTL of 0 (TTL mutates during relay, so it must be
  /// excluded), then PKCS#7-padded to the optimal block size. This byte-for-byte
  /// matches bitchat's `toBinaryDataForSigning`, which calls `encode(...)` with
  /// its default `padding = true` — so cross-client signatures verify. (Signing
  /// the UNpadded form silently breaks interop: bitchat rejects our signed
  /// announce as "unknown" and drops our signed public/#mesh messages, and we
  /// would reject theirs.)
  Uint8List? toBytesForSigning() => BinaryProtocol.encode(
        BitchatPacket(
          version: version,
          type: type,
          senderID: senderID,
          recipientID: recipientID,
          timestamp: timestamp,
          payload: payload,
          signature: null,
          ttl: 0,
          route: route,
        ),
        padding: true,
      );

  BitchatPacket copyWith({int? ttl, Uint8List? signature}) => BitchatPacket(
        version: version,
        type: type,
        senderID: senderID,
        recipientID: recipientID,
        timestamp: timestamp,
        payload: payload,
        signature: signature ?? this.signature,
        ttl: ttl ?? this.ttl,
        route: route,
      );

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Binary encoder/decoder for [BitchatPacket] — supports protocol v1 and v2 and
/// is byte-for-byte compatible with bitchat's `BinaryProtocol`.
class BinaryProtocol {
  const BinaryProtocol._();

  static const int headerSizeV1 = 14;
  static const int headerSizeV2 = 16;
  static const int senderIdSize = 8;
  static const int recipientIdSize = 8;
  static const int signatureSize = 64;

  /// Upper bound on a decoded payload — mirrors bitchat's `MAX_PAYLOAD_LENGTH`
  /// (10 MiB), guarding against hostile length fields and decompression bombs.
  static const int maxPayloadLength = 10 * 1024 * 1024;

  // Flag bits (the `flags` header byte).
  static const int flagHasRecipient = 0x01;
  static const int flagHasSignature = 0x02;
  static const int flagIsCompressed = 0x04;
  static const int flagHasRoute = 0x08;

  static final ZLibCodec _rawDeflate = ZLibCodec(raw: true);

  static int _headerSize(int version) =>
      version == 1 ? headerSizeV1 : headerSizeV2;

  /// Encodes [packet]. We never compress on send (an uncompressed frame is
  /// always valid to a peer); we still fully support decoding compressed frames.
  /// Returns null if the payload exceeds the v1 length field.
  static Uint8List? encode(BitchatPacket packet, {bool padding = true}) {
    final payload = packet.payload;
    if (payload.length > maxPayloadLength) return null;

    final version = packet.version;
    final headerSize = _headerSize(version);
    final hasRecipient = packet.recipientID != null;
    final hasSignature = packet.signature != null;
    final hasRoute =
        version >= 2 && packet.route != null && packet.route!.isNotEmpty;

    final routeBytes =
        hasRoute ? 1 + (packet.route!.length.clamp(0, 255) * senderIdSize) : 0;
    final capacity = headerSize +
        senderIdSize +
        (hasRecipient ? recipientIdSize : 0) +
        routeBytes +
        payload.length +
        (hasSignature ? signatureSize : 0) +
        16;

    final buf = _ByteWriter(capacity < 512 ? 512 : capacity);

    buf.u8(version);
    buf.u8(packet.type);
    buf.u8(packet.ttl);
    buf.u64(packet.timestamp);

    var flags = 0;
    if (hasRecipient) flags |= flagHasRecipient;
    if (hasSignature) flags |= flagHasSignature;
    if (hasRoute) flags |= flagHasRoute;
    buf.u8(flags);

    if (version >= 2) {
      buf.u32(payload.length);
    } else {
      if (payload.length > 0xFFFF) return null;
      buf.u16(payload.length);
    }

    buf.bytesFixed(packet.senderID, senderIdSize);

    if (hasRecipient) {
      buf.bytesFixed(packet.recipientID!, recipientIdSize);
    }

    if (hasRoute) {
      final count = packet.route!.length.clamp(0, 255);
      buf.u8(count);
      for (var i = 0; i < count; i++) {
        buf.bytesFixed(packet.route![i], senderIdSize);
      }
    }

    buf.bytes(payload);

    if (hasSignature) {
      buf.bytesFixed(packet.signature!, signatureSize);
    }

    final result = buf.toBytes();
    if (padding) {
      return MessagePadding.pad(
          result, MessagePadding.optimalBlockSize(result.length));
    }
    return result;
  }

  /// Decodes a received frame. Tries the raw bytes first (robust when no padding
  /// was applied) then retries after stripping PKCS#7 padding — bitchat's exact
  /// two-pass strategy.
  static BitchatPacket? decode(Uint8List data) {
    final direct = _decodeCore(data);
    if (direct != null) return direct;
    final unpadded = MessagePadding.unpad(data);
    if (identical(unpadded, data) || unpadded.length == data.length)
      return null;
    return _decodeCore(unpadded);
  }

  static BitchatPacket? _decodeCore(Uint8List raw) {
    try {
      if (raw.length < headerSizeV1 + senderIdSize) return null;
      final r = _ByteReader(raw);

      final version = r.u8();
      if (version != 1 && version != 2) return null;

      final type = r.u8();
      final ttl = r.u8();
      final timestamp = r.u64();
      final flags = r.u8();
      final hasRecipient = (flags & flagHasRecipient) != 0;
      final hasSignature = (flags & flagHasSignature) != 0;
      final isCompressed = (flags & flagIsCompressed) != 0;
      final hasRoute = version >= 2 && (flags & flagHasRoute) != 0;

      final payloadLength = version >= 2 ? r.u32() : r.u16();
      if (payloadLength > maxPayloadLength) return null;

      // Bounds pre-check (mirrors bitchat): confirm the frame is large enough
      // for every declared section before consuming it.
      var expected = _headerSize(version) + senderIdSize + payloadLength;
      if (hasRecipient) expected += recipientIdSize;
      var routeCount = 0;
      if (hasRoute) {
        var routeOffset = r.offset + senderIdSize;
        if (hasRecipient) routeOffset += recipientIdSize;
        if (raw.length >= routeOffset + 1) routeCount = raw[routeOffset];
        expected += 1 + (routeCount * senderIdSize);
      }
      if (hasSignature) expected += signatureSize;
      if (raw.length < expected) return null;

      final senderID = r.take(senderIdSize);
      final recipientID = hasRecipient ? r.take(recipientIdSize) : null;

      List<Uint8List>? route;
      if (hasRoute) {
        final count = r.u8();
        if (count > 0) {
          route = [for (var i = 0; i < count; i++) r.take(senderIdSize)];
        }
      }

      Uint8List payload;
      if (isCompressed) {
        final lenFieldBytes = version >= 2 ? 4 : 2;
        if (payloadLength < lenFieldBytes) return null;
        final originalSize = version >= 2 ? r.u32() : r.u16();
        if (originalSize <= 0 || originalSize > maxPayloadLength) return null;
        final compressedSize = payloadLength - lenFieldBytes;
        if (compressedSize <= 0) return null;
        // Decompression-bomb guard, identical ratio to bitchat.
        if (originalSize / compressedSize > 50000.0) return null;
        final compressed = r.take(compressedSize);
        final expanded = Uint8List.fromList(_rawDeflate.decode(compressed));
        if (expanded.length != originalSize) return null;
        payload = expanded;
      } else {
        payload = r.take(payloadLength);
      }

      final signature = hasSignature ? r.take(signatureSize) : null;

      return BitchatPacket(
        version: version,
        type: type,
        senderID: senderID,
        recipientID: recipientID,
        timestamp: timestamp,
        payload: payload,
        signature: signature,
        ttl: ttl,
        route: route,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Minimal big-endian byte writer.
class _ByteWriter {
  _ByteWriter(int capacity) : _buf = Uint8List(capacity);
  Uint8List _buf;
  int _pos = 0;

  void _ensure(int extra) {
    if (_pos + extra <= _buf.length) return;
    var newLen = _buf.length * 2;
    while (newLen < _pos + extra) {
      newLen *= 2;
    }
    _buf = Uint8List(newLen)..setRange(0, _pos, _buf);
  }

  void u8(int v) {
    _ensure(1);
    _buf[_pos++] = v & 0xFF;
  }

  void u16(int v) {
    _ensure(2);
    _buf[_pos++] = (v >> 8) & 0xFF;
    _buf[_pos++] = v & 0xFF;
  }

  void u32(int v) {
    _ensure(4);
    _buf[_pos++] = (v >> 24) & 0xFF;
    _buf[_pos++] = (v >> 16) & 0xFF;
    _buf[_pos++] = (v >> 8) & 0xFF;
    _buf[_pos++] = v & 0xFF;
  }

  void u64(int v) {
    _ensure(8);
    // Dart ints are 64-bit on native; write big-endian via BigInt to stay safe
    // for full-width millisecond timestamps.
    final b = BigInt.from(v);
    for (var i = 7; i >= 0; i--) {
      _buf[_pos++] = ((b >> (i * 8)) & BigInt.from(0xFF)).toInt();
    }
  }

  void bytes(Uint8List src) {
    _ensure(src.length);
    _buf.setRange(_pos, _pos + src.length, src);
    _pos += src.length;
  }

  /// Writes exactly [size] bytes from [src], zero-padding or truncating.
  void bytesFixed(Uint8List src, int size) {
    _ensure(size);
    final n = src.length < size ? src.length : size;
    _buf.setRange(_pos, _pos + n, src);
    for (var i = n; i < size; i++) {
      _buf[_pos + i] = 0;
    }
    _pos += size;
  }

  Uint8List toBytes() => Uint8List.sublistView(_buf, 0, _pos);
}

/// Minimal big-endian byte reader.
class _ByteReader {
  _ByteReader(this._buf);
  final Uint8List _buf;
  int offset = 0;

  int u8() => _buf[offset++];

  int u16() {
    final v = (_buf[offset] << 8) | _buf[offset + 1];
    offset += 2;
    return v;
  }

  int u32() {
    final v = (_buf[offset] << 24) |
        (_buf[offset + 1] << 16) |
        (_buf[offset + 2] << 8) |
        _buf[offset + 3];
    offset += 4;
    return v;
  }

  int u64() {
    var v = BigInt.zero;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | BigInt.from(_buf[offset + i]);
    }
    offset += 8;
    return v.toInt();
  }

  Uint8List take(int n) {
    final out = Uint8List.sublistView(_buf, offset, offset + n);
    offset += n;
    return Uint8List.fromList(out);
  }
}

import 'dart:typed_data';

/// bitchat's Noise-sealed peer-state (0x21) `version:1 | TLV caps | TLV signing key`; gates private media.
class AuthenticatedPeerStatePacket {
  AuthenticatedPeerStatePacket({
    required this.capabilities,
    required this.signingPublicKey,
  });

  /// Minimal little-endian capabilities bitfield (1..8 bytes).
  final Uint8List capabilities;

  /// 32-byte Ed25519 announce signing public key.
  final Uint8List signingPublicKey;

  static const int currentVersion = 0x01;
  static const int _tlvCapabilities = 0x01;
  static const int _tlvSigningKey = 0x02;
  static const int _signingKeyLength = 32;

  /// bitchat `PeerCapabilities.privateMedia` (`1 << 8`).
  static const int capPrivateMedia = 1 << 8;

  /// Minimal LE encoding as bitchat `PeerCapabilities.encoded()`: at least one byte, trailing zeros dropped.
  static Uint8List encodeCapabilities(int bits) {
    final out = BytesBuilder();
    var v = bits;
    do {
      out.addByte(v & 0xFF);
      v >>= 8;
    } while (v != 0);
    return out.toBytes();
  }

  /// Decodes a little-endian bitfield; bytes past 8 are truncated.
  static int decodeCapabilities(Uint8List bytes) {
    var v = 0;
    for (var i = 0; i < bytes.length && i < 8; i++) {
      v |= bytes[i] << (8 * i);
    }
    return v;
  }

  /// Encodes the versioned TLV stream, or null if a field is malformed.
  Uint8List? encode() {
    if (signingPublicKey.length != _signingKeyLength) return null;
    if (capabilities.isEmpty || capabilities.length > 8) return null;
    final out = BytesBuilder();
    out.addByte(currentVersion);
    out.addByte(_tlvCapabilities);
    out.addByte(capabilities.length);
    out.add(capabilities);
    out.addByte(_tlvSigningKey);
    out.addByte(signingPublicKey.length);
    out.add(signingPublicKey);
    return out.toBytes();
  }

  /// Null on an unknown version, bad length or missing field; bitchat ignores such messages.
  static AuthenticatedPeerStatePacket? decode(Uint8List data) {
    if (data.isEmpty || data[0] != currentVersion) return null;
    var offset = 1;
    Uint8List? caps;
    Uint8List? signing;
    while (offset + 2 <= data.length) {
      final type = data[offset];
      final length = data[offset + 1];
      offset += 2;
      if (offset + length > data.length) return null;
      final value = Uint8List.fromList(
          Uint8List.sublistView(data, offset, offset + length));
      offset += length;
      switch (type) {
        case _tlvCapabilities:
          if (length < 1 || length > 8) return null;
          caps ??= value;
          break;
        case _tlvSigningKey:
          if (length != _signingKeyLength) return null;
          signing ??= value;
          break;
        default:
          break; // Ignore unknown TLVs.
      }
    }
    if (caps == null || signing == null) return null;
    return AuthenticatedPeerStatePacket(
        capabilities: caps, signingPublicKey: signing);
  }

  bool get supportsPrivateMedia =>
      (decodeCapabilities(capabilities) & capPrivateMedia) != 0;
}

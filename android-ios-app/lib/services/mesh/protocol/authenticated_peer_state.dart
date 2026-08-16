import 'dart:typed_data';

/// Bitchat's `AuthenticatedPeerStatePacket` — the session-authenticated
/// capability proof exchanged inside the Noise channel as
/// [NoisePayloadType.authenticatedPeerState] (`0x21`) right after a
/// completed/rekeyed handshake.
///
/// This is what actually unlocks **encrypted private media**. The public
/// announce capabilities bit ([IdentityAnnouncement] TLV 0x05) is only a
/// discovery hint that starts a Noise handshake; a peer is treated as
/// private-media-capable — and stops showing the "does not advertise encrypted
/// private media" warning, and starts *accepting* our Noise-sealed `0x20` media
/// — only once it has received this signed-session proof (bitchat
/// `BLEService`/`BLEPrivateMediaSessionStore`).
///
/// Wire format of the decrypted Noise payload *data* (i.e. after the `0x21`
/// [NoisePayload] type byte):
/// ```
/// version:1            (0x01)
/// TLV 0x01 CAPABILITIES minimal little-endian PeerCapabilities bitfield, 1..8 B
/// TLV 0x02 SIGNING_KEY  32-byte Ed25519 announce signing key
/// ```
/// Each TLV is `type:1 | length:1 | value`. Unknown trailing TLVs are ignored
/// for forward-compatibility.
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

  /// The `privateMedia` capability bit — bitchat `PeerCapabilities` `1 << 8`.
  static const int capPrivateMedia = 1 << 8;

  /// Minimal little-endian encoding of a capabilities bitfield, matching
  /// bitchat's `PeerCapabilities.encoded()`: always at least one byte (so an
  /// empty set is distinguishable from an absent TLV), least-significant byte
  /// first, trailing zero bytes dropped.
  static Uint8List encodeCapabilities(int bits) {
    final out = BytesBuilder();
    var v = bits;
    do {
      out.addByte(v & 0xFF);
      v >>= 8;
    } while (v != 0);
    return out.toBytes();
  }

  /// Decodes a little-endian capabilities bitfield back to an int (caps > 8
  /// bytes are truncated, matching a 64-bit `OptionSet`).
  static int decodeCapabilities(Uint8List bytes) {
    var v = 0;
    for (var i = 0; i < bytes.length && i < 8; i++) {
      v |= bytes[i] << (8 * i);
    }
    return v;
  }

  /// Encodes to the versioned TLV byte stream, or null if a field is malformed.
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

  /// Decodes a peer-state payload. Returns null on an unknown version, a
  /// malformed length, or a missing required field (bitchat ignores such
  /// messages without changing state).
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
          break; // ignore unknown TLVs
      }
    }
    if (caps == null || signing == null) return null;
    return AuthenticatedPeerStatePacket(
        capabilities: caps, signingPublicKey: signing);
  }

  /// True when the advertised capabilities include the `privateMedia` bit.
  bool get supportsPrivateMedia =>
      (decodeCapabilities(capabilities) & capPrivateMedia) != 0;
}

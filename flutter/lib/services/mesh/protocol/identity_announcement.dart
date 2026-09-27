import 'dart:convert';
import 'dart:typed_data';

/// The TLV payload of a [MeshMessageType.announce] packet — a byte-for-byte port
/// of bitchat's `IdentityAnnouncement`. It binds a peer's advertised nickname to
/// its two long-term public keys, and the enclosing packet is Ed25519-signed so
/// the binding is authenticated.
///
/// TLV stream (`type:1 | length:1 | value`):
/// * `0x01` NICKNAME (UTF-8)
/// * `0x02` NOISE_PUBLIC_KEY (32-byte Curve25519 static key)
/// * `0x03` SIGNING_PUBLIC_KEY (32-byte Ed25519 key)
/// * `0x05` CAPABILITIES (optional little-endian feature bitfield)
///
/// Unknown TLV types are preserved for forward compatibility (bitchat may add
/// fields we don't parse; we must not drop them when re-encoding).
class IdentityAnnouncement {
  IdentityAnnouncement({
    required this.nickname,
    required this.noisePublicKey,
    required this.signingPublicKey,
    this.capabilities,
    this.nostrLink,
    this.unknownTlvs = const [],
  });

  final String nickname;
  final Uint8List noisePublicKey; // 32 bytes
  final Uint8List signingPublicKey; // 32 bytes
  final Uint8List? capabilities;

  /// Nymchat-specific link binding this peer to a Nostr identity (see
  /// [NostrLink]): `nostrPubkey(32) ‖ schnorr signature(64)`. Null for bitchat
  /// peers and Nymchat peers signing remotely (no local key). bitchat treats
  /// this as an unknown TLV and preserves/ignores it.
  final Uint8List? nostrLink;

  final List<AnnouncementTlv> unknownTlvs;

  static const int _tlvNickname = 0x01;
  static const int _tlvNoisePublicKey = 0x02;
  static const int _tlvSigningPublicKey = 0x03;
  static const int _tlvCapabilities = 0x05;

  /// Nymchat extension TLV — a Nostr-identity link. Chosen above bitchat's
  /// assigned range (0x01–0x05) so it never collides.
  static const int _tlvNostrLink = 0x50;

  /// Encodes to the TLV byte stream. Returns null if any value exceeds the
  /// single-byte length field (255), matching bitchat's guard.
  Uint8List? encode() {
    final nickBytes = utf8.encode(nickname);
    if (nickBytes.length > 255 ||
        noisePublicKey.length > 255 ||
        signingPublicKey.length > 255 ||
        unknownTlvs.any((t) => t.value.length > 255)) {
      return null;
    }
    final out = BytesBuilder();
    void tlv(int type, List<int> value) {
      out.addByte(type);
      out.addByte(value.length);
      out.add(value);
    }

    tlv(_tlvNickname, nickBytes);
    tlv(_tlvNoisePublicKey, noisePublicKey);
    tlv(_tlvSigningPublicKey, signingPublicKey);
    final caps = capabilities;
    if (caps != null && caps.length <= 255) {
      tlv(_tlvCapabilities, caps);
    }
    final link = nostrLink;
    if (link != null && link.length <= 255) {
      tlv(_tlvNostrLink, link);
    }
    for (final t in unknownTlvs) {
      tlv(t.type, t.value);
    }
    return out.toBytes();
  }

  static IdentityAnnouncement? decode(Uint8List data) {
    var offset = 0;
    String? nickname;
    Uint8List? noisePublicKey;
    Uint8List? signingPublicKey;
    Uint8List? capabilities;
    Uint8List? nostrLink;
    final unknown = <AnnouncementTlv>[];

    while (offset + 2 <= data.length) {
      final type = data[offset];
      final length = data[offset + 1];
      offset += 2;
      if (offset + length > data.length) return null;
      final value = Uint8List.fromList(
          Uint8List.sublistView(data, offset, offset + length));
      offset += length;
      switch (type) {
        case _tlvNickname:
          nickname = utf8.decode(value, allowMalformed: true);
          break;
        case _tlvNoisePublicKey:
          noisePublicKey = value;
          break;
        case _tlvSigningPublicKey:
          signingPublicKey = value;
          break;
        case _tlvCapabilities:
          capabilities = value;
          break;
        case _tlvNostrLink:
          nostrLink = value;
          break;
        default:
          unknown.add(AnnouncementTlv(type, value));
      }
    }

    if (nickname == null ||
        noisePublicKey == null ||
        signingPublicKey == null) {
      return null;
    }
    return IdentityAnnouncement(
      nickname: nickname,
      noisePublicKey: noisePublicKey,
      signingPublicKey: signingPublicKey,
      capabilities: capabilities,
      nostrLink: nostrLink,
      unknownTlvs: unknown,
    );
  }
}

/// An announcement TLV whose type this client does not interpret. Retained so
/// re-encoding a decoded announcement preserves bitchat extensions.
class AnnouncementTlv {
  AnnouncementTlv(this.type, this.value);
  final int type;
  final Uint8List value;
}

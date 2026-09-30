import 'dart:convert';
import 'dart:typed_data';

/// bitchat `IdentityAnnouncement` TLV; unknown types are preserved so re-encoding keeps bitchat extensions.
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
  final Uint8List noisePublicKey;
  final Uint8List signingPublicKey;
  final Uint8List? capabilities;

  /// Nymchat [NostrLink] `pubkey(32) ‖ sig(64)`; null for bitchat and remote-signer peers.
  final Uint8List? nostrLink;

  final List<AnnouncementTlv> unknownTlvs;

  static const int _tlvNickname = 0x01;
  static const int _tlvNoisePublicKey = 0x02;
  static const int _tlvSigningPublicKey = 0x03;
  static const int _tlvCapabilities = 0x05;

  /// Nymchat extension TLV, above bitchat's 0x01–0x05 range.
  static const int _tlvNostrLink = 0x50;

  /// Returns null when any value exceeds the 1-byte length field, as bitchat does.
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

class AnnouncementTlv {
  AnnouncementTlv(this.type, this.value);
  final int type;
  final Uint8List value;
}

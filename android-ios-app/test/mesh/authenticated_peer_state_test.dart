import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/mesh/protocol/authenticated_peer_state.dart';
import 'package:nym_bar/services/mesh/protocol/mesh_message_type.dart';
import 'package:nym_bar/services/mesh/protocol/noise_payload.dart';

void main() {
  group('AuthenticatedPeerStatePacket', () {
    test('encodes the bitchat versioned-TLV wire format (privateMedia)', () {
      final signing = Uint8List.fromList(List.filled(32, 0x77));
      final caps = AuthenticatedPeerStatePacket.encodeCapabilities(
          AuthenticatedPeerStatePacket.capPrivateMedia);
      // privateMedia = 1<<8 = 0x100 → minimal little-endian [0x00, 0x01].
      expect(caps, Uint8List.fromList([0x00, 0x01]));

      final encoded = AuthenticatedPeerStatePacket(
        capabilities: caps,
        signingPublicKey: signing,
      ).encode();
      expect(encoded, isNotNull);

      // version(0x01) | TLV 0x01 len=2 [00 01] | TLV 0x02 len=32 <key>
      final expected = <int>[
        0x01, // version
        0x01, 0x02, 0x00, 0x01, // capabilities TLV
        0x02, 0x20, ...List.filled(32, 0x77), // signing key TLV
      ];
      expect(encoded, Uint8List.fromList(expected));
    });

    test('round-trips through decode and reports privateMedia support', () {
      final signing = Uint8List.fromList(List.generate(32, (i) => i));
      final packet = AuthenticatedPeerStatePacket(
        capabilities: AuthenticatedPeerStatePacket.encodeCapabilities(
            AuthenticatedPeerStatePacket.capPrivateMedia),
        signingPublicKey: signing,
      );
      final decoded = AuthenticatedPeerStatePacket.decode(packet.encode()!);
      expect(decoded, isNotNull);
      expect(decoded!.signingPublicKey, signing);
      expect(decoded.supportsPrivateMedia, isTrue);
    });

    test('tolerates unknown trailing TLVs (forward-compat)', () {
      final signing = Uint8List.fromList(List.filled(32, 0xAB));
      final base = AuthenticatedPeerStatePacket(
        capabilities: AuthenticatedPeerStatePacket.encodeCapabilities(
            AuthenticatedPeerStatePacket.capPrivateMedia),
        signingPublicKey: signing,
      ).encode()!;
      final withUnknown =
          Uint8List.fromList([...base, 0xFF, 0x01, 0xAB]); // unknown TLV
      final decoded = AuthenticatedPeerStatePacket.decode(withUnknown);
      expect(decoded, isNotNull);
      expect(decoded!.supportsPrivateMedia, isTrue);
    });

    test('rejects wrong version, short key, and oversized caps', () {
      final signing = Uint8List.fromList(List.filled(32, 0x01));
      // wrong version byte
      expect(
        AuthenticatedPeerStatePacket.decode(Uint8List.fromList(
            [0x02, 0x01, 0x01, 0x08, 0x02, 0x20, ...signing])),
        isNull,
      );
      // signing key one byte short
      expect(
        AuthenticatedPeerStatePacket.decode(Uint8List.fromList(
            [0x01, 0x01, 0x01, 0x08, 0x02, 0x1F, ...signing.sublist(1)])),
        isNull,
      );
      // capabilities field claims 9 bytes (> 8)
      expect(
        AuthenticatedPeerStatePacket.decode(Uint8List.fromList([
          0x01,
          0x01,
          0x09,
          ...List.filled(9, 0x01),
          0x02,
          0x20,
          ...signing,
        ])),
        isNull,
      );
    });

    test('decodeCapabilities recovers absent privateMedia bit', () {
      // groups = 1<<3 only, no privateMedia.
      final caps = AuthenticatedPeerStatePacket.encodeCapabilities(1 << 3);
      final packet = AuthenticatedPeerStatePacket(
        capabilities: caps,
        signingPublicKey: Uint8List.fromList(List.filled(32, 0x02)),
      );
      final decoded = AuthenticatedPeerStatePacket.decode(packet.encode()!);
      expect(decoded!.supportsPrivateMedia, isFalse);
    });

    test('wraps as NoisePayload type 0x21', () {
      final encoded = AuthenticatedPeerStatePacket(
        capabilities: AuthenticatedPeerStatePacket.encodeCapabilities(
            AuthenticatedPeerStatePacket.capPrivateMedia),
        signingPublicKey: Uint8List.fromList(List.filled(32, 0x77)),
      ).encode()!;
      final payload =
          NoisePayload(NoisePayloadType.authenticatedPeerState, encoded)
              .encode();
      expect(payload.first, 0x21);
      final round = NoisePayload.decode(payload)!;
      expect(round.type, NoisePayloadType.authenticatedPeerState);
      expect(round.data, encoded);
    });
  });
}

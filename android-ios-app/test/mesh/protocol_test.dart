import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/mesh/protocol/bitchat_message.dart';
import 'package:nym_bar/services/mesh/protocol/bitchat_packet.dart';
import 'package:nym_bar/services/mesh/protocol/fragment_payload.dart';
import 'package:nym_bar/services/mesh/protocol/identity_announcement.dart';
import 'package:nym_bar/services/mesh/protocol/mesh_message_type.dart';
import 'package:nym_bar/services/mesh/protocol/message_padding.dart';
import 'package:nym_bar/services/mesh/protocol/noise_payload.dart';

Uint8List _seq(int n, [int start = 0]) =>
    Uint8List.fromList(List.generate(n, (i) => (start + i) & 0xFF));

void main() {
  group('MessagePadding', () {
    test('optimalBlockSize picks the smallest block (with tag headroom)', () {
      expect(MessagePadding.optimalBlockSize(10), 256);
      expect(MessagePadding.optimalBlockSize(240), 256);
      expect(MessagePadding.optimalBlockSize(241), 512); // 241 + 16 > 256
      expect(MessagePadding.optimalBlockSize(1000), 1024);
      expect(MessagePadding.optimalBlockSize(5000), 5000); // too big to pad
    });

    test('pad/unpad round-trips with strict PKCS#7', () {
      final data = _seq(100);
      final padded = MessagePadding.pad(data, 256);
      expect(padded.length, 256);
      expect(padded.last, 256 - 100);
      expect(MessagePadding.unpad(padded), equals(data));
    });

    test('unpad leaves non-padded data untouched', () {
      final data = _seq(50);
      // Last byte 49 > remaining? valid-looking marker but not uniform run.
      final out = MessagePadding.unpad(data);
      expect(out, equals(data));
    });
  });

  group('BinaryProtocol', () {
    test('broadcast packet round-trips through padding', () {
      final packet = BitchatPacket(
        type: MeshMessageType.message,
        senderID: _seq(8, 1),
        timestamp: 1723600000123,
        payload: _seq(40, 5),
        ttl: 7,
      );
      final bytes = packet.toBytes();
      expect(bytes, isNotNull);
      final decoded = BinaryProtocol.decode(bytes!);
      expect(decoded, isNotNull);
      expect(decoded!.type, MeshMessageType.message);
      expect(decoded.ttl, 7);
      expect(decoded.timestamp, 1723600000123);
      expect(decoded.senderID, equals(_seq(8, 1)));
      expect(decoded.payload, equals(_seq(40, 5)));
      expect(decoded.recipientID, isNull);
    });

    test('directed packet with recipient + signature round-trips', () {
      final packet = BitchatPacket(
        type: MeshMessageType.noiseEncrypted,
        senderID: _seq(8, 1),
        recipientID: _seq(8, 100),
        timestamp: 42,
        payload: _seq(64, 9),
        signature: _seq(64, 200),
        ttl: 5,
      );
      final bytes = packet.toBytes()!;
      final decoded = BinaryProtocol.decode(bytes)!;
      expect(decoded.recipientID, equals(_seq(8, 100)));
      expect(decoded.signature, equals(_seq(64, 200)));
      expect(decoded.payload, equals(_seq(64, 9)));
      expect(decoded.isBroadcast, isFalse);
    });

    test('signing bytes exclude TTL and signature', () {
      final base = BitchatPacket(
        type: MeshMessageType.announce,
        senderID: _seq(8, 1),
        timestamp: 100,
        payload: _seq(20),
        ttl: 7,
      );
      final a = base.toBytesForSigning();
      final b = base.copyWith(ttl: 3).toBytesForSigning();
      expect(a, equals(b), reason: 'TTL must not affect the signed bytes');
    });

    test('decode rejects truncated frames', () {
      expect(BinaryProtocol.decode(Uint8List(5)), isNull);
    });
  });

  group('FragmentPayload', () {
    test('encode/decode round-trips', () {
      final frag = FragmentPayload(
        fragmentID: _seq(8, 3),
        index: 2,
        total: 5,
        originalType: MeshMessageType.message,
        data: _seq(120, 7),
      );
      final decoded = FragmentPayload.decode(frag.encode())!;
      expect(decoded.fragmentID, equals(_seq(8, 3)));
      expect(decoded.index, 2);
      expect(decoded.total, 5);
      expect(decoded.originalType, MeshMessageType.message);
      expect(decoded.data, equals(_seq(120, 7)));
    });
  });

  group('IdentityAnnouncement', () {
    test('TLV encode/decode round-trips and preserves unknown TLVs', () {
      final ann = IdentityAnnouncement(
        nickname: 'alice',
        noisePublicKey: _seq(32, 1),
        signingPublicKey: _seq(32, 50),
        capabilities: Uint8List.fromList([0x01, 0x00]),
        unknownTlvs: [AnnouncementTlv(0x04, _seq(6, 9))],
      );
      final decoded = IdentityAnnouncement.decode(ann.encode()!)!;
      expect(decoded.nickname, 'alice');
      expect(decoded.noisePublicKey, equals(_seq(32, 1)));
      expect(decoded.signingPublicKey, equals(_seq(32, 50)));
      expect(decoded.capabilities, equals([0x01, 0x00]));
      expect(decoded.unknownTlvs.single.type, 0x04);
      expect(decoded.unknownTlvs.single.value, equals(_seq(6, 9)));
    });

    test('decode fails when required keys are missing', () {
      final partial = Uint8List.fromList([0x01, 0x03, 97, 98, 99]); // nick only
      expect(IdentityAnnouncement.decode(partial), isNull);
    });
  });

  group('NoisePayload / PrivateMessagePacket', () {
    test('private message TLV round-trips', () {
      final pkt = PrivateMessagePacket(
          messageID: 'ABCDEF01-2345-6789-ABCD-EF0123456789',
          content: 'hello mesh');
      final decoded = PrivateMessagePacket.decode(pkt.encode()!)!;
      expect(decoded.messageID, pkt.messageID);
      expect(decoded.content, 'hello mesh');
    });

    test('content over 255 bytes is rejected (caller must chunk)', () {
      final pkt = PrivateMessagePacket(messageID: 'id', content: 'x' * 256);
      expect(pkt.encode(), isNull);
    });

    test('NoisePayload envelope + receipt helpers', () {
      final env = NoisePayload(NoisePayloadType.privateMessage, _seq(10));
      final decoded = NoisePayload.decode(env.encode())!;
      expect(decoded.type, NoisePayloadType.privateMessage);
      expect(decoded.data, equals(_seq(10)));

      final delivered = NoisePayload.delivered('msg-123');
      expect(delivered.type, NoisePayloadType.delivered);
      expect(NoisePayload.decode(delivered.encode())!.receiptMessageId(),
          'msg-123');
    });
  });

  group('BitchatMessage (public broadcast)', () {
    test('binary payload round-trips with optional fields', () {
      final msg = BitchatMessage(
        id: 'msg-1',
        sender: 'alice',
        content: 'gm #bitchat @bob',
        timestampMs: 1723600000000,
        senderPeerID: 'a1b2c3d4e5f60718',
        mentions: ['bob'],
        channel: '#bitchat',
      );
      final decoded = BitchatMessage.fromBinaryPayload(msg.toBinaryPayload())!;
      expect(decoded.id, 'msg-1');
      expect(decoded.sender, 'alice');
      expect(decoded.content, 'gm #bitchat @bob');
      expect(decoded.timestampMs, 1723600000000);
      expect(decoded.senderPeerID, 'a1b2c3d4e5f60718');
      expect(decoded.mentions, equals(['bob']));
      expect(decoded.channel, '#bitchat');
    });
  });
}

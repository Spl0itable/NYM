// Emits mesh wire vectors as JSON so the PWA implementation can be checked
// byte-for-byte against this one.
// Run: flutter test test/mesh_vectors_emit_test.dart --plain-name emit
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

import 'package:nym_bar/services/mesh/noise/noise_crypto.dart';
import 'package:nym_bar/services/mesh/noise/noise_handshake.dart';
import 'package:nym_bar/services/mesh/noise/noise_identity.dart';
import 'package:nym_bar/services/mesh/noise/nostr_link.dart';
import 'package:nym_bar/services/mesh/protocol/bitchat_message.dart';
import 'package:nym_bar/services/mesh/protocol/bitchat_packet.dart';
import 'package:nym_bar/services/mesh/protocol/identity_announcement.dart';
import 'package:nym_bar/services/mesh/protocol/message_padding.dart';
import 'package:nym_bar/services/mesh/protocol/noise_payload.dart';
import 'package:nym_bar/services/mesh/protocol/mesh_message_identity.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List seed(int fill) => Uint8List(32)..fillRange(0, 32, fill);

Future<void> main() async {
  test('emit mesh wire vectors', () async {
    final out = <String, dynamic>{};

  // Deterministic identities.
  final a = await NoiseIdentity.fromSeeds(
      staticPrivate: seed(0x11), signingSeed: seed(0x22));
  final b = await NoiseIdentity.fromSeeds(
      staticPrivate: seed(0x33), signingSeed: seed(0x44));
  out['identityA'] = {
    'staticPublic': hex(a.staticPublic),
    'signingPublic': hex(a.signingPublic),
    'peerID': a.peerID,
    'fingerprint': a.fingerprint,
  };
  out['identityB'] = {
    'staticPublic': hex(b.staticPublic),
    'signingPublic': hex(b.signingPublic),
    'peerID': b.peerID,
  };

  // Padding.
  out['padding'] = {
    'optimal_100': MessagePadding.optimalBlockSize(100),
    'optimal_600': MessagePadding.optimalBlockSize(600),
    'optimal_5000': MessagePadding.optimalBlockSize(5000),
    'pad_5_to_16': hex(MessagePadding.pad(
        Uint8List.fromList([1, 2, 3, 4, 5]), 16)),
  };

  // A signed broadcast packet, padded, as it goes on air.
  final payload = Uint8List.fromList(utf8.encode('hello mesh'));
  final packet = BitchatPacket(
    type: 0x02,
    senderID: a.peerIdBytes,
    recipientID: kBroadcastRecipient,
    timestamp: 1750000000123,
    payload: payload,
    ttl: 7,
  );
  final signing = packet.toBytesForSigning()!;
  packet.signature = await a.sign(signing);
  out['packet'] = {
    'signingBytes': hex(signing),
    'signature': hex(packet.signature!),
    'encoded': hex(packet.toBytes()!),
    'unpadded': hex(packet.toBytes(padding: false)!),
  };

  // Identity announcement TLV, including the Nostr link extension.
  final link = NostrLink.build('ab' * 32, 'cd' * 64);
  final ann = IdentityAnnouncement(
    nickname: 'nym#beef',
    noisePublicKey: a.staticPublic,
    signingPublicKey: a.signingPublic,
    capabilities: Uint8List.fromList([0x03]),
    nostrLink: link,
  );
  out['announce'] = {
    'encoded': hex(ann.encode()!),
    'linkMessageHex': NostrLink.messageHex(a.staticPublic),
  };

  // BitchatMessage TLV for a named channel.
  final msg = BitchatMessage(
    id: 'abc-123',
    sender: 'nym#beef',
    content: 'hi channel',
    timestampMs: 1750000000123,
    senderPeerID: a.peerID,
    channel: 'nymchat',
    mentions: ['alice', 'bob'],
  );
  out['bitchatMessage'] = {'encoded': hex(msg.toBinaryPayload())};

  // Noise payload envelopes.
  out['noisePayload'] = {
    'privateMessage': hex(NoisePayload(0x01,
            PrivateMessagePacket(messageID: 'm1', content: 'secret').encode()!)
        .encode()),
    'delivered': hex(NoisePayload.delivered('m1').encode()),
  };

  // Noise XX with deterministic statics (ephemerals are random, so only the
  // derived transport keys of a full run are comparable — instead expose the
  // symmetric-state primitives the JS must match).
  final sym = NoiseSymmetricState.initialize(kNoiseProtocolName);
  sym.mixHash(Uint8List(0));
  out['noiseInit'] = {'h_after_empty_prologue': hex(sym.handshakeHash)};
  out['hkdf'] = {
    'out': NoiseCrypto.hkdf(seed(0x01), seed(0x02), 3).map(hex).toList(),
  };
  out['nonce12_1'] = hex(NoiseCrypto.nonce12(1));
  out['nonce12_258'] = hex(NoiseCrypto.nonce12(258));
  out['aead'] = {
    'ct': hex(await NoiseCrypto.aeadEncrypt(seed(0x05), 7, seed(0x06),
        Uint8List.fromList(utf8.encode('aead vector')))),
  };

  out['stableId'] = MeshMessageIdentity.stableId(
      senderIdHex: a.peerID, timestampMs: 1750000000123, content: ' hello mesh ');

    print('BEGIN_VECTORS' + jsonEncode(out) + 'END_VECTORS');
  });
}

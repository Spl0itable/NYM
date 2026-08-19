import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart' show randomBytes;
import 'package:nym_bar/services/mesh/noise/noise_identity.dart';
import 'package:nym_bar/services/mesh/noise/noise_session.dart';

void main() {
  group('Noise XX handshake', () {
    late NoiseIdentity alice;
    late NoiseIdentity bob;

    setUp(() async {
      alice = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32),
        signingSeed: randomBytes(32),
      );
      bob = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32),
        signingSeed: randomBytes(32),
      );
    });

    Future<(NoiseSession, NoiseSession)> completeHandshake() async {
      final initiator = NoiseSession(
        peerID: bob.peerID,
        isInitiator: true,
        staticPrivate: alice.staticPrivate,
        staticPublic: alice.staticPublic,
      );
      final responder = NoiseSession(
        peerID: alice.peerID,
        isInitiator: false,
        staticPrivate: bob.staticPrivate,
        staticPublic: bob.staticPublic,
      );

      final msg1 = await initiator.startHandshake();
      expect(msg1.length, 32, reason: 'XX message 1 is a bare ephemeral key');

      final msg2 = await responder.processHandshakeMessage(msg1);
      expect(msg2, isNotNull);
      expect(msg2!.length, 96, reason: 'XX message 2 is e, ee, s, es + tag');

      final msg3 = await initiator.processHandshakeMessage(msg2);
      expect(msg3, isNotNull);
      expect(msg3!.length, 64,
          reason: 'XX message 3 is enc(s) + empty payload');

      final none = await responder.processHandshakeMessage(msg3);
      expect(none, isNull);

      expect(initiator.isEstablished, isTrue);
      expect(responder.isEstablished, isTrue);
      return (initiator, responder);
    }

    test('both sides establish and learn the correct remote static key',
        () async {
      final (initiator, responder) = await completeHandshake();
      expect(initiator.remoteStaticPublicKey, equals(bob.staticPublic));
      expect(responder.remoteStaticPublicKey, equals(alice.staticPublic));
      // Handshake hash (channel binding) must match on both sides.
      expect(initiator.handshakeHash, equals(responder.handshakeHash));
    });

    test('peerID binding matches derived identity', () async {
      final (initiator, _) = await completeHandshake();
      expect(
        NoiseIdentity.matchesClaimedPeerID(
            bob.peerID, initiator.remoteStaticPublicKey!),
        isTrue,
      );
    });

    test('transport encryption round-trips in both directions', () async {
      final (initiator, responder) = await completeHandshake();

      for (var i = 0; i < 5; i++) {
        final plain = Uint8List.fromList(
            List.generate(20 + i, (j) => (i * 7 + j) & 0xFF));
        final wire = await initiator.encrypt(plain);
        // 4-byte nonce prefix + ciphertext + 16-byte tag.
        expect(wire.length, plain.length + 4 + 16);
        final got = await responder.decrypt(wire);
        expect(got, equals(plain));
      }

      final reply = Uint8List.fromList([1, 2, 3, 4, 5]);
      final wireBack = await responder.encrypt(reply);
      expect(await initiator.decrypt(wireBack), equals(reply));
    });

    test('replayed transport frame is rejected', () async {
      final (initiator, responder) = await completeHandshake();
      final wire = await initiator.encrypt(Uint8List.fromList([9, 9, 9]));
      expect(await responder.decrypt(wire), equals([9, 9, 9]));
      // Second delivery of the same frame must fail the replay window.
      expect(() => responder.decrypt(wire), throwsA(isA<StateError>()));
    });

    test('tampered ciphertext fails authentication', () async {
      final (initiator, responder) = await completeHandshake();
      final wire = await initiator.encrypt(Uint8List.fromList([5, 6, 7, 8]));
      wire[wire.length - 1] ^= 0xFF; // flip a tag bit
      expect(() => responder.decrypt(wire), throwsA(anything));
    });
  });

  test('mesh identity peerID is first 16 hex of SHA-256(static pubkey)',
      () async {
    final id = await NoiseIdentity.fromSeeds(
      staticPrivate: randomBytes(32),
      signingSeed: randomBytes(32),
    );
    expect(id.peerID.length, 16);
    expect(id.fingerprint.length, 64);
    expect(id.fingerprint.startsWith(id.peerID), isTrue);
    expect(NoiseIdentity.derivePeerID(id.staticPublic), id.peerID);
  });
}

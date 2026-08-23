// Settings sync under the hybrid post-quantum transport.
//
// Settings are a self-addressed gift wrap like any other, and they carry more
// about a user than most single messages do — the conversation list, the group
// ephemeral keys, the message history categories. They were the last
// self-addressed thing still on plain NIP-44 after the PMs, the groups and the
// D1 archive moved, which made them the weakest thing on the relay: readable by
// anyone who breaks secp256k1 regardless of how carefully the messages
// themselves were sealed.
//
// Two properties matter here and neither is about the happy path. Reading must
// need no migration — a blob written before this device had an ML-KEM key, or
// by a device signing through an extension, has to stay readable. And the
// hybrid's size cost has to be known, because a settings category close to the
// relay's frame limit cannot absorb it and must fall back rather than go
// unpublished.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/ml_kem.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/core/crypto/pq.dart' as pq;

/// A settings payload of the shape the sync actually publishes.
String _payload({int groups = 1}) => jsonEncode({
      'theme': 'matrix',
      'translateLanguage': 'es',
      'groupEphemeralKeys': {
        for (var i = 0; i < groups; i++)
          'group$i': {
            'self': {'sk': 'a' * 64, 'prev': []}
          },
      },
    });

void main() {
  late Uint8List sk;
  late String pk;
  late MlKemKeyPair kem;
  late pq.PqIdentity self;

  setUp(() {
    sk = randomBytes(32);
    pk = getPublicKeyHex(sk);
    kem = pq.pqKeypairFromPrivkey(sk, 0);
    self = pq.PqIdentity(
        privkey: sk, kemSecretKey: kem.secretKey, kemPublicKey: kem.publicKey);
  });

  group('self-encrypted blob', () {
    test('round-trips', () {
      final plaintext = _payload();
      final ct = pq.pqEncrypt(plaintext, sk, pk, kem.publicKey);
      expect(pq.isPqPayload(ct), isTrue);
      expect(pq.pqDecrypt(ct, pk, self), plaintext);
    });

    test('another identity cannot read it', () {
      final ct = pq.pqEncrypt(_payload(), sk, pk, kem.publicKey);
      final otherSk = randomBytes(32);
      final otherKem = pq.pqKeypairFromPrivkey(otherSk, 0);
      expect(
        () => pq.pqDecrypt(
          ct,
          pk,
          pq.PqIdentity(
            privkey: otherSk,
            kemSecretKey: otherKem.secretKey,
            kemPublicKey: otherKem.publicKey,
          ),
        ),
        throwsA(anything),
      );
    });

    test('a key rotation still opens the older blob', () {
      // The epoch keypair stays derivable from the nsec, so the decrypt walks
      // the epochs rather than losing everything written before a rotation.
      final ct = pq.pqEncrypt(_payload(), sk, pk, kem.publicKey);
      final rotated = pq.pqKeypairFromPrivkey(sk, 1);
      final withNewKeyOnly = pq.PqIdentity(
        privkey: sk,
        kemSecretKey: rotated.secretKey,
        kemPublicKey: rotated.publicKey,
      );
      expect(() => pq.pqDecrypt(ct, pk, withNewKeyOnly), throwsA(anything));
      // ...and the old epoch, which the reader also holds, does open it.
      expect(pq.pqDecrypt(ct, pk, self), _payload());
    });
  });

  group('no migration needed', () {
    test('a legacy NIP-44 blob is not mistaken for a hybrid one', () {
      final legacy = nip44.encrypt(
          _payload(), nip44.getConversationKey(sk, pk));
      expect(pq.isPqPayload(legacy), isFalse);
      expect(
        nip44.decrypt(legacy, nip44.getConversationKey(sk, pk)),
        _payload(),
      );
    });

    test('the prefix is what picks the path', () {
      final hybrid = pq.pqEncrypt(_payload(), sk, pk, kem.publicKey);
      final legacy = nip44.encrypt(
          _payload(), nip44.getConversationKey(sk, pk));
      expect(hybrid.startsWith('pq1.'), isTrue);
      expect(legacy.startsWith('pq1.'), isFalse);
    });
  });

  group('size', () {
    test('the hybrid costs under 2 KB a layer', () {
      // The number the publisher budgets against the 65000-byte relay frame:
      // two layers, so ~3 KB total. A category near the cap falls back to
      // NIP-44 instead of going unpublished.
      final hybrid = pq.pqEncrypt(_payload(), sk, pk, kem.publicKey);
      final legacy = nip44.encrypt(
          _payload(), nip44.getConversationKey(sk, pk));
      final overhead = hybrid.length - legacy.length;
      expect(overhead, greaterThan(1024));
      expect(overhead, lessThan(2048));
    });

    test('the overhead is flat, not proportional to the payload', () {
      // If it scaled with the settings it would push every large category over
      // the cap rather than a few.
      int overheadFor(int groups) {
        final p = _payload(groups: groups);
        return pq.pqEncrypt(p, sk, pk, kem.publicKey).length -
            nip44.encrypt(p, nip44.getConversationKey(sk, pk)).length;
      }

      expect((overheadFor(50) - overheadFor(1)).abs(), lessThan(64));
    });
  });
}

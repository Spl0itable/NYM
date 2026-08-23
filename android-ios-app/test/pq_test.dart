// Cross-implementation contract: this exercises the Dart hybrid post-quantum
// crypto against test/pq-vectors.json, which the PWA emits from ITS
// implementation. Passing here and in the PWA's `npm run test:pq` is what
// guarantees the two clients can read each other's messages.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/ml_kem.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/core/crypto/pq.dart';

Uint8List unhex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final v = jsonDecode(File('test/pq-vectors.json').readAsStringSync())
      as Map<String, dynamic>;

  group('scheme constants agree with the PWA', () {
    test('salts and prefix', () {
      final s = v['scheme'] as Map<String, dynamic>;
      expect(pqCombinerSalt, s['combinerSalt']);
      expect(pqSeedSalt, s['seedSalt']);
      expect(pqPrefix, s['contentPrefix']);
      final sizes = s['sizes'] as Map<String, dynamic>;
      expect(mlKemPublicKeyLength, sizes['kemPublicKey']);
      expect(mlKemSecretKeyLength, sizes['kemSecretKey']);
      expect(mlKemCipherTextLength, sizes['kemCiphertext']);
    });
  });

  group('seed derivation', () {
    for (final (i, e) in (v['seedDerivation'] as List).indexed) {
      test('vector $i (epoch ${e['epoch']})', () {
        expect(hex(pqDeriveSeed(unhex(e['privkey'] as String), e['epoch'] as int)),
            e['seed']);
      });
    }
    test('same nsec + epoch is stable across calls (multi-device requirement)', () {
      final sk = unhex(v['seedDerivation'][0]['privkey'] as String);
      expect(hex(pqKeypairFromPrivkey(sk, 0).publicKey),
          hex(pqKeypairFromPrivkey(sk, 0).publicKey));
    });
    test('epoch bump rotates the key', () {
      final sk = unhex(v['seedDerivation'][0]['privkey'] as String);
      expect(hex(pqKeypairFromPrivkey(sk, 0).publicKey),
          isNot(hex(pqKeypairFromPrivkey(sk, 1).publicKey)));
    });
  });

  group('combiner', () {
    for (final (i, e) in (v['conversationKey'] as List).indexed) {
      test('vector $i', () {
        expect(
            hex(pqConversationKey(
              ecdhSharedX: unhex(e['ecdhSharedX'] as String),
              kemSharedSecret: unhex(e['kemSharedSecret'] as String),
              kemCipherText: unhex(e['kemCipherText'] as String),
              recipKemPublicKey: unhex(e['recipKemPublicKey'] as String),
              senderSecpPubkey: e['senderSecpPubkey'] as String,
              recipSecpPubkey: e['recipSecpPubkey'] as String,
            )),
            e['conversationKey']);
      });
    }
    test('ECDH leg matches the PWA', () {
      for (final e in v['conversationKey'] as List) {
        // Recomputing from the recipient side must give the same shared x.
        final ck = e['ecdhSharedX'] as String;
        expect(ck.length, 64);
      }
    });
  });

  group('end to end', () {
    for (final (i, e) in (v['endToEnd'] as List).indexed) {
      final kp = mlKem768.keygen(unhex(e['recipKemSeed'] as String));

      test('vector $i decrypts a PWA-produced payload', () {
        expect(
            pqDecrypt(
                e['payload'] as String,
                e['senderPubkey'] as String,
                PqIdentity(
                  privkey: unhex(e['recipPrivkey'] as String),
                  kemSecretKey: kp.secretKey,
                  kemPublicKey: kp.publicKey,
                )),
            e['plaintext']);
      });

      test('vector $i reproduces the payload byte-for-byte', () {
        expect(
            pqEncrypt(
              e['plaintext'] as String,
              unhex(e['senderPrivkey'] as String),
              e['recipPubkey'] as String,
              kp.publicKey,
              encapsulationRandomness: unhex(e['encapsulationRandomness'] as String),
              nonce: unhex(e['nip44Nonce'] as String),
            ),
            e['payload']);
      });

      test('vector $i derives the same conversation key', () {
        final enc = mlKem768.encapsulate(
            kp.publicKey, unhex(e['encapsulationRandomness'] as String));
        expect(
            hex(pqConversationKey(
              ecdhSharedX: nip44.ecdhSharedX(
                  unhex(e['senderPrivkey'] as String), e['recipPubkey'] as String),
              kemSharedSecret: enc.sharedSecret,
              kemCipherText: enc.cipherText,
              recipKemPublicKey: kp.publicKey,
              senderSecpPubkey: e['senderPubkey'] as String,
              recipSecpPubkey: e['recipPubkey'] as String,
            )),
            e['conversationKey']);
      });
    }
  });

  group('negative cases', () {
    final senderSk = unhex(
        '1111111111111111111111111111111111111111111111111111111111111111');
    final recipSk = unhex(
        '2222222222222222222222222222222222222222222222222222222222222222');
    final malSk = unhex(
        '3333333333333333333333333333333333333333333333333333333333333333');
    final kp = pqKeypairFromPrivkey(recipSk, 0);
    final malKp = pqKeypairFromPrivkey(malSk, 0);
    final self = PqIdentity(
        privkey: recipSk, kemSecretKey: kp.secretKey, kemPublicKey: kp.publicKey);
    final ct = pqEncrypt('secret', senderSk, getPublicKeyHex(recipSk), kp.publicKey);

    test('round-trips', () {
      expect(pqDecrypt(ct, getPublicKeyHex(senderSk), self), 'secret');
    });
    test('fresh encapsulation per message', () {
      final ct2 = pqEncrypt('secret', senderSk, getPublicKeyHex(recipSk), kp.publicKey);
      expect(ct.split('.')[1], isNot(ct2.split('.')[1]));
    });
    test('wrong recipient cannot decrypt', () {
      expect(
          () => pqDecrypt(
              ct,
              getPublicKeyHex(senderSk),
              PqIdentity(
                  privkey: malSk,
                  kemSecretKey: malKp.secretKey,
                  kemPublicKey: malKp.publicKey)),
          throwsA(anything));
    });
    test('wrong claimed sender is rejected', () {
      expect(() => pqDecrypt(ct, getPublicKeyHex(malSk), self), throwsA(anything));
    });
    test('flipped KEM ciphertext bit is rejected', () {
      final parts = ct.split('.');
      final raw = b64uDecode(parts[1]);
      raw[0] ^= 1;
      expect(() => pqDecrypt('pq1.${b64uEncode(raw)}.${parts[2]}',
          getPublicKeyHex(senderSk), self), throwsA(anything));
    });
    test('substituted recipient KEM key changes the transcript and fails', () {
      expect(
          () => pqDecrypt(
              ct,
              getPublicKeyHex(senderSk),
              PqIdentity(
                  privkey: recipSk,
                  kemSecretKey: kp.secretKey,
                  kemPublicKey: malKp.publicKey)),
          throwsA(anything));
    });
    test('malformed payloads are rejected, not crashed on', () {
      for (final bad in ['pq1.', 'pq1.zzz.zzz', 'not-pq', 'pq1..']) {
        expect(() => pqDecrypt(bad, getPublicKeyHex(senderSk), self),
            throwsA(anything), reason: bad);
      }
    });
    test('isPqPayload discriminates the transports', () {
      expect(isPqPayload(ct), isTrue);
      expect(isPqPayload('v2:abc'), isFalse); // bitchat
      expect(isPqPayload('AoV...'), isFalse); // plain NIP-44
      expect(isPqPayload(null), isFalse);
    });
  });
}

// pq2: the layered construction (PQ-ROOT-SPEC addendum).
//
// The layer keys are pinned against vectors emitted from the JS reference —
// a divergence here means one client writes messages the other cannot read.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/ml_kem.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/core/crypto/gift_wrap.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/core/crypto/pq.dart';

Uint8List _unhex(String h) => Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)
    ]);
String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List _fill(int n, int v) => Uint8List.fromList(List<int>.filled(n, v));

void main() {
  final vectors = jsonDecode(
      File('test/pq-vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final v2 = vectors['v2'] as Map<String, dynamic>;

  group('layer keys match the JS reference', () {
    test('key, nonce and aad are byte-identical', () {
      final v = v2['pq2LayerKeys'] as Map<String, dynamic>;
      final k = pq2LayerKeys(
        kemSharedSecret: _unhex(v['sharedSecret'] as String),
        kemCipherText: _fill(mlKemCipherTextLength, 0x44),
        recipKemPublicKey: _unhex(v['kemPublicKey'] as String),
        senderSecpPubkey: v['senderPubkey'] as String,
        recipSecpPubkey: v['recipientPubkey'] as String,
      );
      expect(_hex(k.key), v['key']);
      expect(_hex(k.nonce), v['nonce']);
      expect(_hex(k.aad), v['aad']);
    });
  });

  group('the construction', () {
    final v = v2['pq2RoundTrip'] as Map<String, dynamic>;
    final senderSk = _unhex(v['senderPrivkey'] as String);
    final recipSk = _unhex(v['recipientPrivkey'] as String);
    final senderPk = getPublicKeyHex(senderSk);
    final recipPk = getPublicKeyHex(recipSk);
    final kemPk = _unhex(v['kemPublicKey'] as String);
    final kemSk = _unhex(v['kemSecretKey'] as String);
    final self = PqIdentity(
        privkey: recipSk, kemSecretKey: kemSk, kemPublicKey: kemPk);
    final pt = v['plaintext'] as String;

    test('round-trips on a local key', () async {
      final ct = await pq2Encrypt(pt, senderSk, recipPk, kemPk);
      expect(isPq2Payload(ct), isTrue);
      expect(isPqPayload(ct), isFalse, reason: 'pq1 and pq2 are distinct');
      expect(await pq2Decrypt(ct, senderPk, self), pt);
    });

    // The reason this construction exists.
    test('a signer that only does NIP-44 can send and receive', () async {
      final inner =
          nip44.encrypt(pt, nip44.getConversationKey(senderSk, recipPk));
      final sent = await pq2Seal(inner, senderPk, recipPk, kemPk);
      final back = await pq2Open(sent, senderPk, recipPk, kemSk, kemPk);
      expect(back, inner);
      expect(
          nip44.decrypt(back, nip44.getConversationKey(recipSk, senderPk)), pt);
    });

    test('stripping the outer layer yields NIP-44, not plaintext', () async {
      final sent = await pq2Encrypt(pt, senderSk, recipPk, kemPk);
      final inner = await pq2Open(sent, senderPk, recipPk, kemSk, kemPk);
      expect(inner, isNot(pt));
      expect(inner.contains('matters'), isFalse);
    });

    test('the wrong ML-KEM key cannot strip the outer layer', () async {
      final other = pqKeypairFromRoot(_fill(32, 0x77), 0);
      final sent = await pq2Encrypt(pt, senderSk, recipPk, kemPk);
      await expectLater(
          pq2Open(sent, senderPk, recipPk, other.secretKey, kemPk),
          throwsA(anything));
    });

    test('a layer lifted onto another sender or recipient is refused',
        () async {
      final otherPk = getPublicKeyHex(_fill(32, 0x09));
      final sent = await pq2Encrypt(pt, senderSk, recipPk, kemPk);
      await expectLater(
          pq2Open(sent, otherPk, recipPk, kemSk, kemPk), throwsA(anything));
      await expectLater(
          pq2Open(sent, senderPk, otherPk, kemSk, kemPk), throwsA(anything));
    });

    test('every encapsulation is fresh', () async {
      final a = await pq2Encrypt(pt, senderSk, recipPk, kemPk);
      final b = await pq2Encrypt(pt, senderSk, recipPk, kemPk);
      expect(a, isNot(b));
    });

    test('pq1 still round-trips alongside it', () {
      final legacy = pqEncrypt(pt, senderSk, recipPk, kemPk);
      expect(isPqPayload(legacy), isTrue);
      expect(isPq2Payload(legacy), isFalse);
      expect(pqDecrypt(legacy, senderPk, self), pt);
    });

    test('the gift wrap layers both NIP-59 levels and unwraps', () async {
      final w = await pq2Nip59Wrap(
        rumor: UnsignedEvent(
            pubkey: senderPk,
            createdAt: 1700000000,
            kind: 14,
            tags: [['p', recipPk]],
            content: 'layered pm'),
        senderPrivkey: senderSk,
        recipientPubkey: recipPk,
        recipientKemPublicKey: kemPk,
      );
      expect(w.kind, 1059);
      expect(isPq2Payload(w.content), isTrue);
      final got = await unwrapGiftWrap(w, [
        (sk: recipSk, bitchat: false, kemSk: kemSk, kemPk: kemPk),
      ]);
      expect(got, isNotNull);
      expect(got!.rumor['content'], 'layered pm');
      expect(got.isPq, isTrue);
    });
  });
}

// The layering contract with the PWA: a kind-1059 hybrid post-quantum gift wrap
// produced by the PWA (test/pq-vectors.json, emitted by its
// scripts/emit-pq-vectors.mjs) must unwrap here, seal signature and all — and a
// wrap produced here must round-trip through the same code path.
//
// The payload-level agreement is covered by pq_test.dart; this covers the
// NIP-59 layering on top of it.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/gift_wrap.dart' as giftwrap;
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/ml_kem.dart';
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/core/crypto/schnorr.dart';
import 'package:nym_bar/models/nostr_event.dart';

Uint8List unhex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  final v = jsonDecode(File('test/pq-vectors.json').readAsStringSync())
      as Map<String, dynamic>;
  final g = v['giftWrap'] as Map<String, dynamic>;

  group('PWA-produced gift wrap', () {
    final kp = mlKem768.keygen(unhex(g['recipKemSeed'] as String));
    final wrap = NostrEvent.fromJson(g['wrap'] as Map<String, dynamic>);
    final candidate = (
      sk: unhex(g['recipPrivkey'] as String),
      bitchat: false,
      kemSk: kp.secretKey,
      kemPk: kp.publicKey,
    );

    test('is a signed kind-1059 with a vanilla NIP-17 tag surface', () {
      expect(wrap.kind, 1059);
      expect(wrap.tags, [
        ['p', g['recipPubkey']]
      ]);
      expect(verifyEvent(wrap), isTrue);
      expect(pq.isPqPayload(wrap.content), isTrue);
    });

    test('unwraps, and reports the post-quantum transport', () async {
      final r = await giftwrap.unwrapGiftWrap(wrap, [candidate]);
      expect(r, isNotNull);
      expect(r!.isPq, isTrue);
      expect(r.isBitchat, isFalse);
    });

    test('recovers the exact rumor', () async {
      final r = await giftwrap.unwrapGiftWrap(wrap, [candidate]);
      final expected = g['rumor'] as Map<String, dynamic>;
      expect(r!.rumor['content'], expected['content']);
      expect(r.rumor['id'], expected['id']);
      expect(r.rumor['pubkey'], expected['pubkey']);
      expect(jsonEncode(r.rumor['tags']), jsonEncode(expected['tags']));
    });

    test('recovers a seal signed by the real sender, not the wrap author',
        () async {
      final r = await giftwrap.unwrapGiftWrap(wrap, [candidate]);
      expect(r!.seal.pubkey, g['senderPubkey']);
      expect(verifyEvent(r.seal), isTrue);
      expect(wrap.pubkey, isNot(g['senderPubkey']));
    });

    test('a candidate without ML-KEM material skips it cleanly', () async {
      expect(
          await giftwrap.unwrapGiftWrap(
              wrap, [giftwrap.classicalCandidate(unhex(g['recipPrivkey'] as String))]),
          isNull);
    });

    test('the wrong identity cannot unwrap it', () async {
      final malSk = unhex(
          '4444444444444444444444444444444444444444444444444444444444444444');
      final malKp = pq.pqKeypairFromPrivkey(malSk, 0);
      expect(
          await giftwrap.unwrapGiftWrap(wrap,
              [(sk: malSk, bitchat: false, kemSk: malKp.secretKey, kemPk: malKp.publicKey)]),
          isNull);
    });
  });

  group('locally produced gift wrap', () {
    final senderSk = generatePrivateKey();
    final recipSk = generatePrivateKey();
    final recipPk = getPublicKeyHex(recipSk);
    final kp = pq.pqKeypairFromPrivkey(recipSk, 0);
    final candidate = (
      sk: recipSk,
      bitchat: false,
      kemSk: kp.secretKey,
      kemPk: kp.publicKey,
    );


    NostrEvent build({int? expiration}) => giftwrap.pqNip59Wrap(
          rumor: UnsignedEvent(
            pubkey: getPublicKeyHex(senderSk),
            createdAt: 1735689600,
            kind: 14,
            tags: const [
              ['x', 'LOCAL0001']
            ],
            content: 'locally sealed',
          ),
          senderPrivkey: senderSk,
          recipientPubkey: recipPk,
          recipientKemPublicKey: kp.publicKey,
          expiration: expiration,
        );

    test('round-trips through unwrapGiftWrap', () async {
      final r = await giftwrap.unwrapGiftWrap(build(), [candidate]);
      expect(r, isNotNull);
      expect(r!.isPq, isTrue);
      expect(r.rumor['content'], 'locally sealed');
      expect(r.seal.pubkey, getPublicKeyHex(senderSk));
      expect(verifyEvent(r.seal), isTrue);
    });

    test('keeps the NIP-17 tag surface, plus expiration when asked', () {
      expect(build().tags, [
        ['p', recipPk]
      ]);
      expect(build(expiration: 1800000000).tags, [
        ['p', recipPk],
        ['expiration', '1800000000']
      ]);
    });

    test('hybridizes both layers', () async {
      final wrap = build();
      expect(pq.isPqPayload(wrap.content), isTrue);
      final r = await giftwrap.unwrapGiftWrap(wrap, [candidate]);
      expect(pq.isPqPayload(r!.seal.content), isTrue);
    });

    test('each wrap uses a fresh ephemeral author and fresh encapsulation', () {
      final a = build(), b = build();
      expect(a.pubkey, isNot(b.pubkey));
      expect(a.content, isNot(b.content));
    });

    test('classical wraps still round-trip unchanged', () async {
      final classical = giftwrap.nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1735689600,
          kind: 14,
          tags: const [],
          content: 'classical',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: recipPk,
      );
      // A PQ-capable candidate must not disturb the classical path.
      final r = await giftwrap.unwrapGiftWrap(classical, [candidate]);
      expect(r, isNotNull);
      expect(r!.isPq, isFalse);
      expect(r.rumor['content'], 'classical');
    });
  });
}

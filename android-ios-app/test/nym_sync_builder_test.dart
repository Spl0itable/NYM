// nym_sync_builder.dart: the off-main-isolate nym-sync constructions must be
// byte-compatible with what the inline signer path produces — every artifact
// round-trips through the SAME decrypt paths the receiving devices use
// (nip44 / pq2Open), and the size gates reject exactly what the inline path
// rejects. Run directly (not via compute) — same pure functions either way.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/core/crypto/keys.dart' as keys;
import 'package:nym_bar/core/crypto/ml_kem.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/core/crypto/nym_sync_builder.dart';
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/models/nostr_event.dart';

void main() {
  final sk = keys.generatePrivateKey();
  final self = keys.getPublicKeyHex(sk);
  const outerD = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4';
  final rumorMap = {
    'id': 'f' * 64,
    'pubkey': self,
    'created_at': 1700000000,
    'kind': 30078,
    'tags': [
      ['d', 'nymchat-settings']
    ],
    'content': jsonEncode({'theme': 'dark', 'hugeish': 'x' * 500}),
  };
  final rumorJson = jsonEncode(rumorMap);

  Map<String, dynamic> baseJob() => {
        'sk': keys.bytesToHex(sk),
        'self': self,
        'rumorJson': rumorJson,
        'outerD': outerD,
      };

  NostrEvent asEvent(Map<String, dynamic> json) => NostrEvent.fromJson(json);

  test('classical local build round-trips through the receiving decrypts',
      () async {
    final json = await buildNymSyncWrapIsolate(baseJob());
    expect(json, isNotNull);
    final wrap = asEvent(json!);
    expect(wrap.kind, 1059);
    expect(schnorr.verifyEvent(wrap), isTrue);
    expect(
        wrap.tags,
        containsAll([
          ['p', self],
          ['d', outerD],
          ['k', 'nym-sync'],
        ]));
    // Receiver: wrap layer opens with ck(selfSk, ephPubkey).
    final sealJson = nip44.decrypt(
        wrap.content, nip44.getConversationKey(sk, wrap.pubkey));
    final seal = NostrEvent.fromJson(jsonDecode(sealJson));
    expect(seal.kind, 13);
    expect(seal.pubkey, self);
    expect(schnorr.verifyEvent(seal), isTrue);
    // Seal layer: ck(selfSk, self).
    final rumorOut =
        nip44.decrypt(seal.content, nip44.getConversationKey(sk, self));
    expect(rumorOut, rumorJson);
  });

  test('hybrid (pq2) local build round-trips through pq2Open + nip44',
      () async {
    final kem = mlKem768.keygen(keys.randomBytes(64));
    final json =
        await buildNymSyncWrapIsolate({...baseJob(), 'kemPk': kem.publicKey});
    expect(json, isNotNull);
    final wrap = asEvent(json!);
    expect(schnorr.verifyEvent(wrap), isTrue);
    expect(pq.isPq2Payload(wrap.content), isTrue,
        reason: 'kemPk present → the wrap layer must be hybrid');
    // Wrap layer: pq2 sealed sender=eph, recipient=self.
    final innerWrap = await pq.pq2Open(
        wrap.content, wrap.pubkey, self, kem.secretKey, kem.publicKey);
    final sealJson = nip44.decrypt(
        innerWrap, nip44.getConversationKey(sk, wrap.pubkey));
    final seal = NostrEvent.fromJson(jsonDecode(sealJson));
    expect(schnorr.verifyEvent(seal), isTrue);
    // Seal layer: pq2 sealed self→self.
    expect(pq.isPq2Payload(seal.content), isTrue);
    final innerSeal = await pq.pq2Open(
        seal.content, self, self, kem.secretKey, kem.publicKey);
    final rumorOut =
        nip44.decrypt(innerSeal, nip44.getConversationKey(sk, self));
    expect(rumorOut, rumorJson);
  });

  test('a rumor whose SEAL outgrows the NIP-44 ceiling is rejected (null, '
      'no throw) — the 65535 rumor gate itself stays with the caller',
      () async {
    // ~48 KB rumor passes the caller's 65535 gate, but its sealed event JSON
    // (NIP-44 padding + base64 + seal scaffolding) crosses 65535 — the same
    // seal gate the inline path applies.
    final big = jsonEncode({...rumorMap, 'content': 'y' * 48000});
    expect(big.length <= 65535, isTrue);
    final json =
        await buildNymSyncWrapIsolate({...baseJob(), 'rumorJson': big});
    expect(json, isNull);
  });

  test('wrapNymSyncSealIsolate wraps an externally-signed seal (remote path)',
      () async {
    // The "remote signer" seal: inner NIP-44 + signature produced elsewhere.
    final sealed = schnorr.finalizeEvent(
      UnsignedEvent(
        pubkey: self,
        createdAt: 1700000000,
        kind: 13,
        tags: const [],
        content:
            nip44.encrypt(rumorJson, nip44.getConversationKey(sk, self)),
      ),
      sk,
    );
    final sealJson = jsonEncode(sealed.toJson());
    final json = await wrapNymSyncSealIsolate({
      'sealJson': sealJson,
      'self': self,
      'outerD': outerD,
    });
    expect(json, isNotNull);
    final wrap = asEvent(json!);
    expect(schnorr.verifyEvent(wrap), isTrue);
    final sealOut = nip44.decrypt(
        wrap.content, nip44.getConversationKey(sk, wrap.pubkey));
    expect(sealOut, sealJson);
  });

  test('encryptToSelfIsolate classical + hybrid round-trip (_decryptFromSelf '
      'shapes)', () async {
    final classical = await encryptToSelfIsolate({
      'sk': keys.bytesToHex(sk),
      'self': self,
      'plaintext': 'settings blob',
    });
    expect(classical, isNotNull);
    expect(
        nip44.decrypt(classical!, nip44.getConversationKey(sk, self)),
        'settings blob');

    final kem = mlKem768.keygen(keys.randomBytes(64));
    final hybrid = await encryptToSelfIsolate({
      'sk': keys.bytesToHex(sk),
      'self': self,
      'plaintext': 'settings blob',
      'kemPk': kem.publicKey,
    });
    expect(hybrid, isNotNull);
    expect(pq.isPq2Payload(hybrid!), isTrue);
    final inner =
        await pq.pq2Open(hybrid, self, self, kem.secretKey, kem.publicKey);
    expect(nip44.decrypt(inner, nip44.getConversationKey(sk, self)),
        'settings blob');
  });
}

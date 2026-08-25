/// The combined format needs the raw ECDH output, which no signer returns, so
/// pq1 excluded every extension and remote-signer login from RECEIVING. The
/// layered format keys only its outer layer from ML-KEM and leaves an ordinary
/// NIP-44 payload inside, which is exactly what a signer performs.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/gift_wrap.dart' as gw;
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/features/identity/pq_registry.dart';
import 'package:nym_bar/models/nostr_event.dart';

void main() {
  group('a signer login can receive', () {
    test('the layered wrap opens with the root key and no secp key at all',
        () async {
      final aliceSk = generatePrivateKey();
      final alicePub = getPublicKeyHex(aliceSk);
      final bobSk = generatePrivateKey();
      final bobPub = getPublicKeyHex(bobSk);
      final bobRoot = pq.pqGenerateRoot();
      final bobKem = pq.pqKeypairFromRoot(bobRoot, 0);

      final wrap = await gw.pq2Nip59Wrap(
        rumor: UnsignedEvent(
            pubkey: alicePub, createdAt: 1, kind: 14, tags: const [], content: 'hi'),
        senderPrivkey: aliceSk,
        recipientPubkey: bobPub,
        recipientKemPublicKey: bobKem.publicKey,
      );
      expect(pq.isPq2Payload(wrap.content), isTrue);

      // Bob holds NO secp secret of his own in this path: the ML-KEM half is
      // all he needs to strip the outer layer.
      final innerSeal = await pq.pq2Open(
          wrap.content, wrap.pubkey, bobPub, bobKem.secretKey, bobKem.publicKey);
      expect(innerSeal, isNotEmpty);

      // The signer does the ordinary NIP-44 half.
      String signerDecrypt(String peer, String ct) =>
          nip44.decrypt(ct, nip44.getConversationKey(bobSk, peer));
      final seal =
          jsonDecode(signerDecrypt(wrap.pubkey, innerSeal)) as Map<String, dynamic>;
      final innerRumor = await pq.pq2Open(seal['content'] as String,
          seal['pubkey'] as String, bobPub, bobKem.secretKey, bobKem.publicKey);
      final rumor = jsonDecode(signerDecrypt(seal['pubkey'] as String, innerRumor))
          as Map<String, dynamic>;

      expect(rumor['content'], 'hi');
      expect(seal['pubkey'], alicePub, reason: 'the sender stays bound');
    });

    test('a wrong ML-KEM key is refused', () async {
      final aliceSk = generatePrivateKey();
      final bobPub = getPublicKeyHex(generatePrivateKey());
      final bobKem = pq.pqKeypairFromRoot(pq.pqGenerateRoot(), 0);
      final other = pq.pqKeypairFromRoot(pq.pqGenerateRoot(), 0);
      final wrap = await gw.pq2Nip59Wrap(
        rumor: UnsignedEvent(
            pubkey: getPublicKeyHex(aliceSk),
            createdAt: 1,
            kind: 14,
            tags: const [],
            content: 'hi'),
        senderPrivkey: aliceSk,
        recipientPubkey: bobPub,
        recipientKemPublicKey: bobKem.publicKey,
      );
      expect(
          () => pq.pq2Open(wrap.content, wrap.pubkey, bobPub, other.secretKey,
              other.publicKey),
          throwsA(anything));
    });
  });

  // An older build has never heard of pk2. Advertising `pk` to it would have it
  // seal the combined format to a login that can never open it.
  group('what each login advertises', () {
    final kem = pq.pqKeypairFromRoot(pq.pqGenerateRoot(), 0);

    Map<String, dynamic> encoded({required bool legacyCapable}) =>
        jsonDecode(PqAnnouncement.encode(
          publicKey: kem.publicKey,
          expiresAt: 2000000000,
          epoch: 0,
          devices: const [],
          rootSeeded: true,
          legacyCapable: legacyCapable,
        )) as Map<String, dynamic>;

    test('an nsec login advertises both formats, as the same key', () {
      final j = encoded(legacyCapable: true);
      expect(j['pk'], isA<String>());
      expect(j['pk2'], isA<String>());
      expect(j['pk'], j['pk2']);
    });

    test('a signer login advertises only the layered one', () {
      final j = encoded(legacyCapable: false);
      expect(j.containsKey('pk'), isFalse);
      expect(j['pk2'], isA<String>());
      expect(j['nym'], 1,
          reason: 'still a Nymchat client, so peers skip the Bitchat wrap');
    });

    test('an older peer reads that as "no post-quantum key"', () {
      // Exactly what a build predating pk2 does: it looks only at `pk`.
      final j = encoded(legacyCapable: false);
      expect(j['pk'], isNull,
          reason: 'so it sends plain NIP-44, which a signer CAN read');
    });

    test('parsing keeps which formats the peer accepts', () {
      final both = PqAnnouncement.parse(
          PqAnnouncement.encode(
            publicKey: kem.publicKey,
            expiresAt: 2000000000,
            epoch: 0,
            devices: const [],
            legacyCapable: true,
          ))!;
      expect(both.acceptsLegacy, isTrue);
      expect(both.acceptsLayered, isTrue);

      final layeredOnly = PqAnnouncement.parse(
          PqAnnouncement.encode(
            publicKey: kem.publicKey,
            expiresAt: 2000000000,
            epoch: 0,
            devices: const [],
            legacyCapable: false,
          ))!;
      expect(layeredOnly.acceptsLegacy, isFalse);
      expect(layeredOnly.acceptsLayered, isTrue);
      expect(layeredOnly.publicKey, isNotNull);
    });

    test('a pre-split announcement is the combined format only', () {
      final legacy = jsonEncode({
        'v': 1,
        'alg': 'mlkem768',
        'nym': 1,
        'epoch': 0,
        'pk': pq.b64uEncode(kem.publicKey),
        'exp': 2000000000,
      });
      final ann = PqAnnouncement.parse(legacy)!;
      expect(ann.acceptsLegacy, isTrue);
      expect(ann.acceptsLayered, isFalse);
    });
  });

  group('the send plan picks a format the recipient can open', () {
    final kem = pq.pqKeypairFromRoot(pq.pqGenerateRoot(), 0);

    test('layered when the peer accepts it', () {
      final plan = PqPmPlan.decide(
        recipientKemKey: kem.publicKey,
        knownBitchat: false,
        knownNym: true,
        recipientAcceptsLayered: true,
      );
      expect(plan.pq, isTrue);
      expect(plan.layered, isTrue);
    });

    test('combined for a peer that predates it', () {
      final plan = PqPmPlan.decide(
        recipientKemKey: kem.publicKey,
        knownBitchat: false,
        knownNym: true,
        recipientAcceptsLayered: false,
      );
      expect(plan.pq, isTrue);
      expect(plan.layered, isFalse);
    });

    test('never layered without a key to encapsulate to', () {
      final plan = PqPmPlan.decide(
        recipientKemKey: null,
        knownBitchat: false,
        knownNym: true,
        recipientAcceptsLayered: true,
      );
      expect(plan.pq, isFalse);
      expect(plan.layered, isFalse);
    });
  });

  group('capability', () {
    test('the root alone makes a login able to receive', () {
      expect(
          PqPolicy.capable(privkey: null, root: Uint8List(32)), isTrue);
      expect(PqPolicy.capable(privkey: null, root: null), isFalse);
      expect(PqPolicy.capable(privkey: Uint8List(32), root: null), isTrue);
    });

    test('but the combined format still needs the nsec', () {
      expect(PqPolicy.legacyCapable(privkey: null), isFalse);
      expect(PqPolicy.legacyCapable(privkey: Uint8List(32)), isTrue);
    });
  });

  // A self-copy has to be readable by every device on the account.
  group('self-addressed copies', () {
    const now = 1700000000;
    test('layered when every live device can open it', () {
      expect(
          PqPolicy.allDevicesLayered([
            const PqDevice(
                id: 'b',
                version: 'v1',
                seenAt: now,
                postQuantumCapable: true,
                layeredCapable: true)
          ], 'a', nowSec: now),
          isTrue);
    });

    test('combined as soon as one device predates the split', () {
      expect(
          PqPolicy.allDevicesLayered([
            const PqDevice(
                id: 'b', version: 'v1', seenAt: now, postQuantumCapable: true)
          ], 'a', nowSec: now),
          isFalse,
          reason: 'sealing layered would lock it out of its own settings');
    });

    test('a stale device does not hold the account back', () {
      expect(
          PqPolicy.allDevicesLayered([
            const PqDevice(
                id: 'b', version: 'v1', seenAt: 0, postQuantumCapable: true)
          ], 'a', nowSec: now),
          isTrue);
    });

    test('our own roster entry never gates us', () {
      expect(
          PqPolicy.allDevicesLayered([
            const PqDevice(
                id: 'a', version: 'v1', seenAt: now, postQuantumCapable: true)
          ], 'a', nowSec: now),
          isTrue);
    });
  });
}

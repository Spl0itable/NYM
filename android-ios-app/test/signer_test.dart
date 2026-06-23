import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/gift_wrap.dart' as gw;
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';

/// A fake "remote" [EventSigner] backed by a known local key. It signs +
/// NIP-44 encrypts/decrypts in-memory (exactly what a real NIP-46 signer does
/// over RPC) but reports [isRemote] = true. Proves the remote seal-signing /
/// seal-encryption path in [nip59WrapAsync] is correctly wired.
class _FakeRemoteSigner implements EventSigner {
  _FakeRemoteSigner(this._sk) : _pub = getPublicKeyHex(_sk);
  final Uint8List _sk;
  final String _pub;

  int signCalls = 0;
  int encryptCalls = 0;
  int decryptCalls = 0;

  @override
  String get pubkey => _pub;

  @override
  bool get isRemote => true;

  @override
  Future<NostrEvent> sign(UnsignedEvent unsigned) async {
    signCalls++;
    return schnorr.finalizeEvent(unsigned, _sk);
  }

  @override
  Future<String> nip44Encrypt(String peerPubkey, String plaintext) async {
    encryptCalls++;
    return nip44.encrypt(plaintext, nip44.getConversationKey(_sk, peerPubkey));
  }

  @override
  Future<String> nip44Decrypt(String peerPubkey, String ciphertext) async {
    decryptCalls++;
    return nip44.decrypt(ciphertext, nip44.getConversationKey(_sk, peerPubkey));
  }
}

void main() {
  group('LocalSigner', () {
    test('sign produces a verifiable event with the identity author', () async {
      final sk = generatePrivateKey();
      final signer = LocalSigner(sk);
      expect(signer.isRemote, isFalse);
      expect(signer.pubkey, getPublicKeyHex(sk));

      final unsigned = UnsignedEvent(
        pubkey: signer.pubkey,
        createdAt: 1700000000,
        kind: 1,
        tags: const [],
        content: 'hello',
      );
      final signed = await signer.sign(unsigned);
      expect(signed.pubkey, signer.pubkey);
      expect(signed.id, isNotEmpty);
      expect(signed.sig, isNotEmpty);
      expect(schnorr.verifyEvent(signed), isTrue);
    });

    test('nip44 encrypt/decrypt round-trips between two parties', () async {
      final aSk = generatePrivateKey();
      final bSk = generatePrivateKey();
      final a = LocalSigner(aSk);
      final b = LocalSigner(bSk);

      final ct = await a.nip44Encrypt(b.pubkey, 'private payload');
      final pt = await b.nip44Decrypt(a.pubkey, ct);
      expect(pt, 'private payload');
    });
  });

  group('nip59WrapAsync', () {
    test('LocalSigner wrap -> unwrap recovers rumor + sender (sync parity)',
        () async {
      final senderSk = generatePrivateKey();
      final recipientSk = generatePrivateKey();
      final senderPub = getPublicKeyHex(senderSk);
      final recipientPub = getPublicKeyHex(recipientSk);

      final rumor = UnsignedEvent(
        pubkey: senderPub,
        createdAt: 1700000000,
        kind: 14,
        tags: [
          ['p', recipientPub]
        ],
        content: 'async wrap contents',
      );

      final wrap = await gw.nip59WrapAsync(
        rumor: rumor,
        senderSigner: LocalSigner(senderSk),
        recipientPubkey: recipientPub,
      );
      expect(wrap.kind, 1059);
      expect(wrap.tagValue('p'), recipientPub);
      expect(schnorr.verifyEvent(wrap), isTrue);

      final result = await gw.unwrapGiftWrap(wrap, [
        (sk: recipientSk, bitchat: false),
      ]);
      expect(result, isNotNull);
      expect(result!.rumor['content'], 'async wrap contents');
      expect(result.rumor['pubkey'], senderPub);
      // Seal must be authored by the real sender (NIP-59 sender auth).
      expect(result.seal.pubkey, senderPub);
      expect(schnorr.verifyEvent(result.seal), isTrue);
      expect(result.isBitchat, isFalse);
    });

    test('expiration tag is carried on the wrap', () async {
      final senderSk = generatePrivateKey();
      final recipientPub = getPublicKeyHex(generatePrivateKey());
      final wrap = await gw.nip59WrapAsync(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1700000000,
          kind: 14,
          tags: const [],
          content: 'x',
        ),
        senderSigner: LocalSigner(senderSk),
        recipientPubkey: recipientPub,
        expiration: 1800000000,
      );
      expect(wrap.tagValue('expiration'), '1800000000');
    });

    test('fake REMOTE signer drives the wrap; result unwraps + verifies',
        () async {
      final senderSk = generatePrivateKey();
      final recipientSk = generatePrivateKey();
      final senderPub = getPublicKeyHex(senderSk);
      final recipientPub = getPublicKeyHex(recipientSk);
      final remote = _FakeRemoteSigner(senderSk);

      final rumor = UnsignedEvent(
        pubkey: senderPub,
        createdAt: 1700000000,
        kind: 14,
        tags: const [],
        content: 'remote-sealed DM',
      );

      final wrap = await gw.nip59WrapAsync(
        rumor: rumor,
        senderSigner: remote,
        recipientPubkey: recipientPub,
      );

      // The remote signer sealed (one sign + one encrypt for the seal); the
      // wrap layer is local-ephemeral, so no extra remote calls.
      expect(remote.signCalls, 1);
      expect(remote.encryptCalls, 1);
      expect(wrap.kind, 1059);
      expect(schnorr.verifyEvent(wrap), isTrue);

      // Recipient recovers the rumor with their local key, proving the seal was
      // encrypted to them via the remote signer's conversation key.
      final result = await gw.unwrapGiftWrap(wrap, [
        (sk: recipientSk, bitchat: false),
      ]);
      expect(result, isNotNull);
      expect(result!.rumor['content'], 'remote-sealed DM');
      expect(result.rumor['pubkey'], senderPub);
      expect(result.seal.pubkey, senderPub);
      expect(schnorr.verifyEvent(result.seal), isTrue);
    });

    test('remote-decrypt parity: recipient remote signer recovers the seal',
        () async {
      // The inbound DM-decrypt path under NIP-46 decrypts the wrap + seal via
      // the remote `nip44_decrypt` RPC. Model that with a fake remote signer
      // keyed by the recipient and decrypt the two layers manually.
      final senderSk = generatePrivateKey();
      final recipientSk = generatePrivateKey();
      final senderPub = getPublicKeyHex(senderSk);
      final recipientPub = getPublicKeyHex(recipientSk);

      final wrap = await gw.nip59WrapAsync(
        rumor: UnsignedEvent(
          pubkey: senderPub,
          createdAt: 1700000000,
          kind: 14,
          tags: const [],
          content: 'two-layer remote decrypt',
        ),
        senderSigner: LocalSigner(senderSk),
        recipientPubkey: recipientPub,
      );

      final recipientRemote = _FakeRemoteSigner(recipientSk);
      final sealJson =
          await recipientRemote.nip44Decrypt(wrap.pubkey, wrap.content);
      final seal =
          NostrEvent.fromJson(jsonDecode(sealJson) as Map<String, dynamic>);
      final rumorJson =
          await recipientRemote.nip44Decrypt(seal.pubkey, seal.content);
      final rumor = jsonDecode(rumorJson) as Map<String, dynamic>;

      expect(seal.pubkey, senderPub);
      expect(rumor['content'], 'two-layer remote decrypt');
      expect(rumor['pubkey'], senderPub);
    });
  });

  group('friend presence (kind 25054)', () {
    test('friend-presence rumor round-trips through a gift wrap', () async {
      final senderSk = generatePrivateKey();
      final friendSk = generatePrivateKey();
      final senderPub = getPublicKeyHex(senderSk);
      final friendPub = getPublicKeyHex(friendSk);

      // Mirrors NostrService.sendFriendPresence rumor shape.
      final rumor = UnsignedEvent(
        pubkey: senderPub,
        createdAt: 1700000000,
        kind: 25054,
        tags: [
          ['status', 'away'],
          ['n', 'alice'],
          ['away', 'brb'],
        ],
        content: '',
      );

      final wrap = await gw.nip59WrapAsync(
        rumor: rumor,
        senderSigner: LocalSigner(senderSk),
        recipientPubkey: friendPub,
      );

      final result = await gw.unwrapGiftWrap(wrap, [
        (sk: friendSk, bitchat: false),
      ]);
      expect(result, isNotNull);
      expect(result!.rumor['kind'], 25054);
      expect(result.rumor['pubkey'], senderPub);
      // Verified sender (seal authored by the real friend key).
      expect(result.seal.pubkey, senderPub);
      expect(schnorr.verifyEvent(result.seal), isTrue);

      final tags = (result.rumor['tags'] as List)
          .map((t) => (t as List).map((e) => e as String).toList())
          .toList();
      String? tag(String k) =>
          tags.firstWhere((t) => t.isNotEmpty && t[0] == k,
              orElse: () => const []).let((t) => t.length > 1 ? t[1] : null);
      expect(tag('status'), 'away');
      expect(tag('n'), 'alice');
      expect(tag('away'), 'brb');
    });
  });
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

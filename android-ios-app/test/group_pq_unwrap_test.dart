import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/gift_wrap.dart' as giftwrap;
import 'package:nym_bar/core/crypto/keys.dart' as keys;
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';
import 'package:nym_bar/services/nostr/identity_service.dart';
import 'package:nym_bar/services/nostr/nostr_service.dart';
import 'package:nym_bar/services/relay/relay_pool.dart';

/// A group post-quantum wrap uses two DIFFERENT keys: the classical leg goes to
/// the member's rotating ephemeral secp key, the KEM leg to their long-lived
/// identity ML-KEM key. Opening one therefore needs a candidate carrying BOTH.
void main() {
  late Uint8List senderSk;
  late Uint8List identitySk;
  late Uint8List ephemeralSk;
  late ({Uint8List kemSk, Uint8List kemPk}) identityKem;

  setUp(() async {
    senderSk = keys.generatePrivateKey();
    identitySk = keys.generatePrivateKey();
    ephemeralSk = keys.generatePrivateKey();
    final kp = pq.pqKeypairFromPrivkey(identitySk, 0);
    identityKem = (kemSk: kp.secretKey, kemPk: kp.publicKey);
  });

  Future<NostrEvent> groupWrap() => giftwrap.pq2Nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: keys.getPublicKeyHex(senderSk),
          createdAt: 1,
          kind: 14,
          tags: const [],
          content: 'group hello',
        ),
        senderPrivkey: senderSk,
        // The classical leg is addressed to our EPHEMERAL group key...
        recipientPubkey: keys.getPublicKeyHex(ephemeralSk),
        // ...while the KEM leg encapsulates to our IDENTITY key.
        recipientKemPublicKey: identityKem.kemPk,
      );

  test('the identity key paired with ML-KEM cannot open a group wrap', () async {
    final res = await giftwrap.unwrapGiftWrap(await groupWrap(), [
      (
        sk: identitySk,
        bitchat: false,
        kemSk: identityKem.kemSk,
        kemPk: identityKem.kemPk
      ),
    ]);
    expect(res, isNull);
  });

  test('a classical-only ephemeral candidate cannot open a group wrap',
      () async {
    final res = await giftwrap.unwrapGiftWrap(
        await groupWrap(), [giftwrap.classicalCandidate(ephemeralSk)]);
    expect(res, isNull);
  });

  test('the two together, as separate candidates, still cannot', () async {
    final res = await giftwrap.unwrapGiftWrap(await groupWrap(), [
      (
        sk: identitySk,
        bitchat: false,
        kemSk: identityKem.kemSk,
        kemPk: identityKem.kemPk
      ),
      giftwrap.classicalCandidate(ephemeralSk),
    ]);
    expect(res, isNull,
        reason: 'the ephemeral secp key and the identity ML-KEM key must be '
            'paired in ONE candidate, not offered as two');
  });

  test('the ephemeral secp key paired with the identity ML-KEM key opens it',
      () async {
    final res = await giftwrap.unwrapGiftWrap(await groupWrap(), [
      (
        sk: ephemeralSk,
        bitchat: false,
        kemSk: identityKem.kemSk,
        kemPk: identityKem.kemPk
      ),
    ]);
    expect(res, isNotNull);
    expect(res!.isPq, isTrue);
    expect(res.rumor['content'], 'group hello');
    expect(jsonDecode(jsonEncode(res.rumor))['pubkey'],
        keys.getPublicKeyHex(senderSk));
  });

  // The candidate list NostrService actually builds, driven through the
  // service rather than restated here.
  group('the service pairs them', () {
    NostrService svc({bool withPq = true}) => NostrService(
          identity: Identity(
              pubkey: keys.getPublicKeyHex(identitySk),
              privkey: identitySk,
              nym: 'me#0001'),
          signer: LocalSigner(identitySk),
          pool: _NullTransport(),
        )
          ..setPqSelfKeys(withPq ? [identityKem] : const [])
          ..setEphemeralKeys([keys.generatePrivateKey(), ephemeralSk]);

    test('a group wrap opens through the service candidate list', () async {
      final w = await groupWrap();
      expect(await giftwrap.unwrapGiftWrap(w, svc().unwrapCandidatesForTest(w)),
          isNotNull);
    });

    test('the ephemeral key the wrap names is paired first', () async {
      final w = await groupWrap();
      final paired = svc().unwrapCandidatesForTest(w).where((c) =>
          c.kemSk != null &&
          keys.getPublicKeyHex(c.sk) != keys.getPublicKeyHex(identitySk));
      expect(keys.getPublicKeyHex(paired.first.sk),
          keys.getPublicKeyHex(ephemeralSk));
    });

    test('a classical group wrap still opens', () async {
      final w = giftwrap.nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: keys.getPublicKeyHex(senderSk),
          createdAt: 1,
          kind: 14,
          tags: const [],
          content: 'classical hello',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: keys.getPublicKeyHex(ephemeralSk),
      );
      final res =
          await giftwrap.unwrapGiftWrap(w, svc().unwrapCandidatesForTest(w));
      expect(res, isNotNull);
      expect(res!.isPq, isFalse);
      expect(res.rumor['content'], 'classical hello');
    });

    test('with no ML-KEM keys yet nothing is paired', () {
      expect(
          svc(withPq: false)
              .unwrapCandidatesForTest(null)
              .every((c) => c.kemSk == null),
          isTrue);
    });
  });
}

class _NullTransport implements PoolTransport {
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

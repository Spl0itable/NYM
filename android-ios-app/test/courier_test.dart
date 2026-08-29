// Opportunistic couriers: mail carried by peers who cannot read it.
//
// A DM to someone out of radio range has nowhere to go, and with no internet
// on either side the sender outbox cannot help either. A courier envelope is
// the last delivery path: seal the message to the recipient's static key and
// hand sealed copies to whoever is nearby, who carry it and deliver it if they
// meet the recipient.
//
// Two things are under test, and the second matters more than the first. That
// the seal works — a courier learns nothing, the recipient learns who wrote it.
// And that the deposit REFUSES in the cases where carrying mail would leak the
// very thing another feature exists to protect: a ghost identity.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/mesh/courier/courier_envelope.dart';
import 'package:nym_bar/services/mesh/courier/courier_store.dart';
import 'package:nym_bar/services/mesh/noise/noise_crypto.dart';

Uint8List _b(List<int> v) => Uint8List.fromList(v);

Uint8List _tag(int seed) => Uint8List(16)..fillRange(0, 16, seed);

CourierEnvelope _env({
  int tagSeed = 1,
  int expiryMs = 2000000000000,
  Uint8List? ciphertext,
  int copies = 1,
}) =>
    CourierEnvelope(
      recipientTag: _tag(tagSeed),
      expiryMs: expiryMs,
      ciphertext: ciphertext ?? _b(List.filled(80, 7)),
      copies: copies,
    );

void main() {
  const now = 1700000000000;

  group('the seal', () {
    test('the recipient reads it, and learns who wrote it', () async {
      final (aPriv, aPub) = await NoiseCrypto.x25519Generate();
      final (bPriv, bPub) = await NoiseCrypto.x25519Generate();
      final payload = _b(utf8.encode('carried by hand'));

      final sealed = await CourierSeal.seal(
        payload: payload,
        recipientStaticKey: bPub,
        senderStaticPrivate: aPriv,
        senderStaticPublic: aPub,
      );
      final (opened, senderKey) = await CourierSeal.open(
        ciphertext: sealed,
        localStaticPrivate: bPriv,
        localStaticPublic: bPub,
      );
      expect(utf8.decode(opened), 'carried by hand');
      // The `ss` DH authenticates the sender: this is who really wrote it, not
      // whoever handed it over.
      expect(senderKey, aPub);
    });

    test('the courier carrying it cannot open it', () async {
      final (aPriv, aPub) = await NoiseCrypto.x25519Generate();
      final (_, bPub) = await NoiseCrypto.x25519Generate();
      final (cPriv, cPub) = await NoiseCrypto.x25519Generate();
      final sealed = await CourierSeal.seal(
        payload: _b(utf8.encode('private')),
        recipientStaticKey: bPub,
        senderStaticPrivate: aPriv,
        senderStaticPublic: aPub,
      );
      // C is the courier. Trying to open is exactly how a holder tests whether
      // mail is theirs, so a failure here is the ordinary path, not an error.
      await expectLater(
        CourierSeal.open(
          ciphertext: sealed,
          localStaticPrivate: cPriv,
          localStaticPublic: cPub,
        ),
        throwsA(anything),
      );
    });

    test('a tampered envelope will not open', () async {
      final (aPriv, aPub) = await NoiseCrypto.x25519Generate();
      final (bPriv, bPub) = await NoiseCrypto.x25519Generate();
      final sealed = await CourierSeal.seal(
        payload: _b(utf8.encode('intact')),
        recipientStaticKey: bPub,
        senderStaticPrivate: aPriv,
        senderStaticPublic: aPub,
      );
      final tampered = Uint8List.fromList(sealed);
      tampered[tampered.length - 1] ^= 0xFF;
      await expectLater(
        CourierSeal.open(
          ciphertext: tampered,
          localStaticPrivate: bPriv,
          localStaticPublic: bPub,
        ),
        throwsA(anything),
      );
    });

    test('two seals of the same message differ', () async {
      // A fresh ephemeral per envelope: identical ciphertext would let an
      // observer link two deposits as the same message.
      final (aPriv, aPub) = await NoiseCrypto.x25519Generate();
      final (_, bPub) = await NoiseCrypto.x25519Generate();
      Future<Uint8List> once() => CourierSeal.seal(
            payload: _b(utf8.encode('same words')),
            recipientStaticKey: bPub,
            senderStaticPrivate: aPriv,
            senderStaticPublic: aPub,
          );
      expect(await once(), isNot(await once()));
    });

    test('a short or empty ciphertext is rejected, not misread', () async {
      final (bPriv, bPub) = await NoiseCrypto.x25519Generate();
      await expectLater(
        CourierSeal.open(
          ciphertext: Uint8List(10),
          localStaticPrivate: bPriv,
          localStaticPublic: bPub,
        ),
        throwsA(anything),
      );
    });
  });

  group('the recipient tag', () {
    test('is computable only by someone who knows the static key', () async {
      final (_, bPub) = await NoiseCrypto.x25519Generate();
      final (_, cPub) = await NoiseCrypto.x25519Generate();
      final day = CourierEnvelope.epochDayFor(now);
      final forB =
          await CourierEnvelope.recipientTagFor(noiseStaticKey: bPub, epochDay: day);
      final forC =
          await CourierEnvelope.recipientTagFor(noiseStaticKey: cPub, epochDay: day);
      expect(forB, hasLength(CourierEnvelope.tagLength));
      expect(forB, isNot(forC));
    });

    test('rotates daily, so envelopes do not correlate across days', () async {
      final (_, bPub) = await NoiseCrypto.x25519Generate();
      final day = CourierEnvelope.epochDayFor(now);
      final today =
          await CourierEnvelope.recipientTagFor(noiseStaticKey: bPub, epochDay: day);
      final tomorrow = await CourierEnvelope.recipientTagFor(
          noiseStaticKey: bPub, epochDay: day + 1);
      expect(today, isNot(tomorrow));
    });

    test('the candidate set spans the day boundary', () async {
      // An envelope sealed just before midnight — or under clock skew between
      // two phones that have never synchronised — must still match.
      final (_, bPub) = await NoiseCrypto.x25519Generate();
      final tags =
          await CourierEnvelope.candidateTagsFor(noiseStaticKey: bPub, nowMs: now);
      expect(tags, hasLength(3));
      final day = CourierEnvelope.epochDayFor(now);
      // `equals` and not the bare value: `contains` compares with `==`, and two
      // Uint8Lists holding identical bytes are never `==`.
      expect(
        tags,
        contains(equals(await CourierEnvelope.recipientTagFor(
            noiseStaticKey: bPub, epochDay: day - 1))),
      );
    });
  });

  group('the envelope wire format', () {
    test('round-trips', () {
      final e = _env(copies: 4);
      final decoded = CourierEnvelope.decode(e.encode()!)!;
      expect(decoded.recipientTag, e.recipientTag);
      expect(decoded.expiryMs, e.expiryMs);
      expect(decoded.ciphertext, e.ciphertext);
      expect(decoded.copies, 4);
    });

    test('a carry-only envelope omits the copies TLV', () {
      // Byte-identical to the pre-spray wire form, so an older bitchat sees
      // exactly what it used to.
      final one = _env().encode()!;
      final two = _env(copies: 2).encode()!;
      expect(two.length, greaterThan(one.length));
      expect(CourierEnvelope.decode(one)!.copies, 1);
    });

    test('an unknown TLV is skipped so we still carry the mail', () {
      final base = _env().encode()!;
      final extended =
          Uint8List.fromList([...base, 0x7F, 0x00, 0x02, 1, 2]);
      expect(CourierEnvelope.decode(extended), isNotNull);
    });

    test('malformed input decodes to null', () {
      expect(CourierEnvelope.decode(_b([0x01, 0x00])), isNull);
      expect(CourierEnvelope.decode(_b([0x01, 0x00, 0x40])), isNull);
      expect(CourierEnvelope.decode(Uint8List(0)), isNull);
    });

    test('the copy budget is clamped at both ends', () {
      expect(_env(copies: 0).copies, 1);
      expect(_env(copies: 99).copies, CourierEnvelope.maxCopies);
    });

    test('an oversized ciphertext will not encode', () {
      final huge = _env(
          ciphertext: Uint8List(CourierEnvelope.maxCiphertextBytes + 1));
      expect(huge.encode(), isNull);
    });
  });

  group('who may deposit — the privacy gate', () {
    test('a ghost-pinned conversation NEVER deposits', () {
      // The peer met us as a ghost and knows us only as that. Asking a stranger
      // to carry mail for that conversation is exactly the link the ghost
      // identity exists to prevent — the same reason the sender outbox refuses
      // to republish it to Nostr.
      expect(
        CourierStore.mayDeposit(
          isGhostPinned: true,
          isGhostMode: false,
          hasRecipientStaticKey: true,
        ),
        isFalse,
      );
    });

    test('a ghosted sender NEVER deposits', () {
      // The deposit outlives the epoch: after we rotate, someone is still
      // carrying a message that associates the throwaway identity with us.
      expect(
        CourierStore.mayDeposit(
          isGhostPinned: false,
          isGhostMode: true,
          hasRecipientStaticKey: true,
        ),
        isFalse,
      );
    });

    test('no static key means nothing to seal to', () {
      expect(
        CourierStore.mayDeposit(
          isGhostPinned: false,
          isGhostMode: false,
          hasRecipientStaticKey: false,
        ),
        isFalse,
      );
    });

    test('an ordinary conversation may', () {
      expect(
        CourierStore.mayDeposit(
          isGhostPinned: false,
          isGhostMode: false,
          hasRecipientStaticKey: true,
        ),
        isTrue,
      );
    });
  });

  group('who may carry', () {
    test('only a verified peer', () {
      // An unverified peer is a radio claiming a name; handing it an envelope
      // tells an unknown party that we are sending mail.
      expect(
        CourierStore.mayCourier(
            isVerified: false, isSelf: false, isRecipient: false),
        isFalse,
      );
      expect(
        CourierStore.mayCourier(
            isVerified: true, isSelf: false, isRecipient: false),
        isTrue,
      );
    });

    test('never ourselves, never the recipient', () {
      expect(
        CourierStore.mayCourier(
            isVerified: true, isSelf: true, isRecipient: false),
        isFalse,
      );
      // The recipient gets it delivered, not couriered.
      expect(
        CourierStore.mayCourier(
            isVerified: true, isSelf: false, isRecipient: true),
        isFalse,
      );
    });
  });

  group('spray and wait', () {
    test('the budget halves at each hand-off', () {
      expect(CourierStore.sprayShare(8), 4);
      expect(CourierStore.keepShare(8), 4);
      expect(CourierStore.sprayShare(5), 2);
      expect(CourierStore.keepShare(5), 3);
    });

    test('at 1 the message stops spreading but is still carried', () {
      // This is what makes it spray-and-WAIT rather than a flood.
      expect(CourierStore.sprayShare(1), 0);
      expect(CourierStore.keepShare(1), 1);
    });

    test('spreading is bounded — a budget cannot grow', () {
      var total = 8;
      var rounds = 0;
      var copies = 8;
      while (CourierStore.sprayShare(copies) > 0 && rounds < 20) {
        final share = CourierStore.sprayShare(copies);
        expect(share + CourierStore.keepShare(copies), copies);
        copies = CourierStore.keepShare(copies);
        rounds++;
      }
      expect(total, 8); // the sum is conserved, never multiplied
      expect(copies, 1);
    });
  });

  group('the carried store', () {
    test('accepts mail and hands it over on a tag match', () {
      final s = CourierStore(nowMs: () => now);
      expect(s.accept(_env(tagSeed: 3), 'k1'), isTrue);
      expect(s.forTags([_tag(3)]), hasLength(1));
      expect(s.forTags([_tag(9)]), isEmpty);
    });

    test('the same envelope from two couriers is carried once', () {
      final s = CourierStore(nowMs: () => now);
      expect(s.accept(_env(), 'k1'), isTrue);
      expect(s.accept(_env(), 'k1'), isFalse);
      expect(s.length, 1);
    });

    test('expired mail is neither accepted nor kept', () {
      var t = now;
      final s = CourierStore(nowMs: () => t);
      expect(s.accept(_env(expiryMs: now - 1), 'k1'), isFalse);
      s.accept(_env(expiryMs: now + 1000), 'k2');
      t = now + 2000;
      expect(s.prune(), isTrue);
      expect(s.length, 0);
    });

    test('the cap evicts oldest-received first', () {
      final s = CourierStore(capacity: 2, nowMs: () => now);
      s.accept(_env(tagSeed: 1), 'k1');
      s.accept(_env(tagSeed: 2), 'k2');
      s.accept(_env(tagSeed: 3), 'k3');
      expect(s.length, 2);
      expect(s.forTags([_tag(1)]), isEmpty);
    });

    test('a peer already given a share is not given another', () {
      // Re-spraying the same peer burns budget without adding a carrier.
      final s = CourierStore(nowMs: () => now);
      s.accept(_env(copies: 4), 'k1');
      expect(s.sprayableTo('peerA'), hasLength(1));
      s.markHandedTo('k1', 'peerA');
      expect(s.sprayableTo('peerA'), isEmpty);
      expect(s.sprayableTo('peerB'), hasLength(1));
    });

    test('carry-only mail is never sprayed', () {
      final s = CourierStore(nowMs: () => now);
      s.accept(_env(copies: 1), 'k1');
      expect(s.sprayableTo('peerA'), isEmpty);
    });

    test('delivery drops it', () {
      final s = CourierStore(nowMs: () => now);
      s.accept(_env(), 'k1');
      expect(s.drop('k1'), isTrue);
      expect(s.length, 0);
    });
  });
}

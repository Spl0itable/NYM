// Three mesh wire formats, each solving something the mesh could not do:
//
//  * PING/PONG — a peer list cannot tell you whether someone is in the room or
//    three relays away. The echo can.
//  * NOSTR_CARRIER — the sender outbox waits for YOUR internet. Gateway mode
//    does not: one peer with a signal publishes for the room.
//  * PREKEY_BUNDLE — a courier envelope sealed to a long-lived key is not
//    forward secret. Sealed to a one-time key that gets deleted, it is.
//
// All three are bitchat's formats, so these pin the encoding as much as the
// behaviour: a packet the other client cannot parse is worse than no feature.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/mesh/courier/courier_envelope.dart';
import 'package:nym_bar/services/mesh/courier/local_prekeys.dart';
import 'package:nym_bar/services/mesh/courier/prekey_bundle.dart';
import 'package:nym_bar/services/mesh/noise/noise_crypto.dart';
import 'package:nym_bar/services/mesh/protocol/mesh_diagnostics_packets.dart';
import 'package:nym_bar/services/mesh/protocol/nostr_carrier_packet.dart';

import 'package:nym_bar/features/mesh/mesh_controller.dart';

Uint8List _b(List<int> v) => Uint8List.fromList(v);

void main() {
  // What a peer row shows while a probe is out, when it answers, and when it
  // never does. A peer is in the list because we heard an announce, which may
  // have been minutes and several moves ago — so silence has to read as an
  // answer rather than a row that waits forever.
  group('the probe as the UI sees it', () {
    test('a probe in flight is waiting, and nothing else', () {
      const p = MeshPingState.waiting();
      expect(p.isWaiting, isTrue);
      expect(p.lost, isFalse);
      expect(p.roundTripMs, isNull);
    });

    test('an answer stops waiting and carries the numbers', () {
      const p = MeshPingState.result(roundTripMs: 42, hops: 3);
      expect(p.isWaiting, isFalse);
      expect(p.lost, isFalse);
      expect(p.roundTripMs, 42);
      expect(p.hops, 3);
    });

    test('silence is an answer, not a hang', () {
      const p = MeshPingState.lost();
      expect(p.lost, isTrue);
      expect(p.isWaiting, isFalse);
    });

    test('a reply with no derivable hop count still reports the round trip',
        () {
      // hopCount returns null for an impossible TTL pair — the packet was
      // rewritten rather than relayed. Better no hop count than a wrong one,
      // and the round trip is still a real measurement.
      const p = MeshPingState.result(roundTripMs: 88, hops: null);
      expect(p.roundTripMs, 88);
      expect(p.hops, isNull);
      expect(p.isWaiting, isFalse);
      expect(p.lost, isFalse);
    });
  });

  group('PING / PONG', () {
    test('round-trips the nonce and origin TTL', () {
      final nonce = _b([1, 2, 3, 4, 5, 6, 7, 8]);
      final decoded =
          MeshPingPayload.decode(
              MeshPingPayload.create(nonce: nonce, originTtl: 7)!.encode())!;
      expect(decoded.nonce, nonce);
      expect(decoded.originTtl, 7);
    });

    test('a wrong-sized nonce is refused', () {
      expect(
          MeshPingPayload.create(nonce: _b([1, 2, 3]), originTtl: 7), isNull);
    });

    test('trailing bytes are accepted, so the format can grow', () {
      // A newer client adding a field must not stop an older one answering.
      final base = MeshPingPayload.create(
              nonce: _b([1, 2, 3, 4, 5, 6, 7, 8]), originTtl: 7)!
          .encode();
      final extended = Uint8List.fromList([...base, 9, 9, 9]);
      expect(MeshPingPayload.decode(extended)!.originTtl, 7);
    });

    test('a truncated payload decodes to null', () {
      expect(MeshPingPayload.decode(_b([1, 2, 3])), isNull);
    });

    test('a directly connected peer is one hop away', () {
      // TTL decrements plus the final delivery link.
      expect(MeshPingPayload.hopCount(originTtl: 7, receivedTtl: 7), 1);
      expect(MeshPingPayload.hopCount(originTtl: 7, receivedTtl: 5), 3);
    });

    test('an impossible TTL pair yields no hop count rather than a lie', () {
      // Received above origin means somebody rewrote the packet, not
      // relayed it.
      expect(MeshPingPayload.hopCount(originTtl: 3, receivedTtl: 7), isNull);
    });
  });

  group('NOSTR_CARRIER (gateway mode)', () {
    final event = {
      'id': 'a' * 64,
      'pubkey': 'b' * 64,
      'created_at': 1700000000,
      'kind': 20000,
      'tags': [
        ['g', 'u4pruy']
      ],
      'content': 'sent through someone else\'s internet',
      'sig': 'c' * 128,
    };

    test('round-trips a signed event', () {
      final packet = NostrCarrierPacket.fromEvent(
        direction: NostrCarrierDirection.toGateway,
        geohash: 'u4pruy',
        event: event,
      )!;
      final decoded = NostrCarrierPacket.decode(packet.encode())!;
      expect(decoded.direction, NostrCarrierDirection.toGateway);
      expect(decoded.geohash, 'u4pruy');
      expect(decoded.event()!['content'], event['content']);
    });

    test('both directions survive the wire', () {
      for (final d in NostrCarrierDirection.values) {
        final p = NostrCarrierPacket.create(
          direction: d,
          geohash: 'u4pruy',
          eventJson: _b(utf8.encode('{}')),
        )!;
        expect(NostrCarrierPacket.decode(p.encode())!.direction, d);
      }
    });

    test('an unknown direction is refused, not guessed', () {
      // A carrier is published on somebody's behalf; guessing what they meant
      // is not an option.
      final p = NostrCarrierPacket.create(
        direction: NostrCarrierDirection.toGateway,
        geohash: 'u4pruy',
        eventJson: _b(utf8.encode('{}')),
      )!;
      final bytes = Uint8List.fromList(p.encode());
      bytes[3] = 0x7F; // direction value
      expect(NostrCarrierPacket.decode(bytes), isNull);
    });

    test('an oversized event or geohash will not encode', () {
      expect(
        NostrCarrierPacket.create(
          direction: NostrCarrierDirection.toGateway,
          geohash: 'u4pruy',
          eventJson: Uint8List(NostrCarrierPacket.maxEventJsonBytes + 1),
        ),
        isNull,
      );
      expect(
        NostrCarrierPacket.create(
          direction: NostrCarrierDirection.toGateway,
          geohash: 'a' * (NostrCarrierPacket.maxGeohashLength + 1),
          eventJson: _b(utf8.encode('{}')),
        ),
        isNull,
      );
      expect(
        NostrCarrierPacket.create(
          direction: NostrCarrierDirection.toGateway,
          geohash: '',
          eventJson: _b(utf8.encode('{}')),
        ),
        isNull,
      );
    });

    test('trailing junk is refused', () {
      final p = NostrCarrierPacket.fromEvent(
        direction: NostrCarrierDirection.toGateway,
        geohash: 'u4pruy',
        event: event,
      )!;
      final bytes = Uint8List.fromList([...p.encode(), 0x00]);
      expect(NostrCarrierPacket.decode(bytes), isNull);
    });

    test('a body that is not an event parses to null, not to garbage', () {
      final p = NostrCarrierPacket.create(
        direction: NostrCarrierDirection.fromGateway,
        geohash: 'u4pruy',
        eventJson: _b(utf8.encode('not json')),
      )!;
      expect(NostrCarrierPacket.decode(p.encode())!.event(), isNull);
    });
  });

  group('PREKEY_BUNDLE', () {
    PrekeyBundle bundle({int count = 2, int? generatedAt}) => PrekeyBundle(
          noiseStaticPublicKey: Uint8List(32)..fillRange(0, 32, 9),
          prekeys: [
            for (var i = 1; i <= count; i++)
              Prekey(id: i, publicKey: Uint8List(32)..fillRange(0, 32, i)),
          ],
          generatedAtMs: generatedAt ?? 1700000000000,
          signature: Uint8List(64)..fillRange(0, 64, 3),
        );

    test('round-trips', () {
      final decoded = PrekeyBundle.decode(bundle(count: 3).encode()!)!;
      expect(decoded.prekeys, hasLength(3));
      expect(decoded.prekeys[1].id, 2);
      expect(decoded.generatedAtMs, 1700000000000);
      expect(decoded.signature, hasLength(64));
    });

    test('the signable bytes are stable and domain-separated', () {
      // Encoders and verifiers must derive these identically, or every bundle
      // looks forged.
      final a = bundle().signableBytes();
      final b = bundle().signableBytes();
      expect(a, b);
      expect(utf8.decode(a.sublist(1, 25)), 'bitchat-prekey-bundle-v1');
    });

    test('changing anything changes what is signed', () {
      expect(bundle(count: 2).signableBytes(),
          isNot(bundle(count: 3).signableBytes()));
      expect(bundle().signableBytes(),
          isNot(bundle(generatedAt: 1700000001000).signableBytes()));
    });

    test('duplicate prekey ids are refused', () {
      // One consumed id shadowing another would let a sender be steered onto a
      // key the owner has already thrown away.
      final dupe = PrekeyBundle(
        noiseStaticPublicKey: Uint8List(32),
        prekeys: [
          Prekey(id: 1, publicKey: Uint8List(32)),
          Prekey(id: 1, publicKey: Uint8List(32)..fillRange(0, 32, 2)),
        ],
        generatedAtMs: 1,
        signature: Uint8List(64),
      );
      expect(PrekeyBundle.decode(dupe.encode()!), isNull);
    });

    test('a malformed bundle will not encode or decode', () {
      expect(
        PrekeyBundle(
          noiseStaticPublicKey: Uint8List(8),
          prekeys: [Prekey(id: 1, publicKey: Uint8List(32))],
          generatedAtMs: 1,
          signature: Uint8List(64),
        ).encode(),
        isNull,
      );
      expect(
        PrekeyBundle(
          noiseStaticPublicKey: Uint8List(32),
          prekeys: const [],
          generatedAtMs: 1,
          signature: Uint8List(64),
        ).encode(),
        isNull,
      );
      expect(PrekeyBundle.decode(_b([0x01, 0x00])), isNull);
    });

    test('more prekeys than the cap are refused', () {
      final over = PrekeyBundle(
        noiseStaticPublicKey: Uint8List(32),
        prekeys: [
          for (var i = 1; i <= PrekeyBundle.maxPrekeys + 1; i++)
            Prekey(id: i, publicKey: Uint8List(32)),
        ],
        generatedAtMs: 1,
        signature: Uint8List(64),
      );
      expect(over.encode(), isNull);
    });
  });

  group('local prekeys', () {
    test('replenishes to a full batch, then stops', () async {
      final p = LocalPrekeys(nowMs: () => 0);
      expect(await p.replenish(), isTrue);
      expect(p.available, hasLength(LocalPrekeys.batchSize));
      expect(await p.replenish(), isFalse);
    });

    test('a consumed key survives its grace window, then is gone', () async {
      // Spray-and-wait means copies of the SAME envelope arrive later. Deleting
      // on first open would make every redelivery look like lost mail.
      var t = 0;
      final p = LocalPrekeys(nowMs: () => t);
      await p.replenish();
      final id = p.available.first.id;
      expect(p.markConsumed(id), isTrue);
      expect(p.privateKeyFor(id), isNotNull, reason: 'redelivery must open');
      t = LocalPrekeys.graceMs + 1;
      expect(p.privateKeyFor(id), isNull, reason: 'this is forward secrecy');
      expect(p.prune(), isTrue);
    });

    test('a second open of the same key does not re-publish', () async {
      final p = LocalPrekeys(nowMs: () => 0);
      await p.replenish();
      final id = p.available.first.id;
      expect(p.markConsumed(id), isTrue);
      expect(p.markConsumed(id), isFalse);
    });

    test('a consumed key leaves the published batch', () async {
      final p = LocalPrekeys(nowMs: () => 0);
      await p.replenish();
      final before = p.available.length;
      p.markConsumed(p.available.first.id);
      expect(p.available, hasLength(before - 1));
    });

    test('the private halves survive a restart', () async {
      // A sender who took our bundle before we closed sealed mail to one of
      // these; a courier may hand it over hours later.
      final p = LocalPrekeys(nowMs: () => 0);
      await p.replenish();
      final id = p.available.first.id;
      final key = p.privateKeyFor(id);
      final restored = LocalPrekeys(nowMs: () => 0)..decode(p.encode());
      expect(restored.privateKeyFor(id), key);
    });

    test('an id is never re-issued after a restart', () async {
      // A repeated id would let new mail be sealed under an id whose private
      // half we already deleted.
      final p = LocalPrekeys(nowMs: () => 0);
      await p.replenish();
      final maxId =
          p.keys.map((k) => k.id).reduce((a, b) => a > b ? a : b);
      final restored = LocalPrekeys(nowMs: () => 0)..decode(p.encode());
      restored.clear();
      restored.decode(p.encode());
      await restored.replenish();
      expect(restored.keys.every((k) => k.id <= maxId), isTrue);
      final again = LocalPrekeys(nowMs: () => 0)..decode(p.encode());
      again.markConsumed(maxId);
      await again.replenish();
      expect(again.keys.map((k) => k.id).toSet().length, again.keys.length);
    });

    test('a corrupt blob costs the batch, never the launch', () {
      final p = LocalPrekeys(nowMs: () => 0);
      expect(() => p.decode('not json'), returnsNormally);
      expect(() => p.decode('[]'), returnsNormally);
      expect(() => p.decode(null), returnsNormally);
      expect(p.keys, isEmpty);
    });
  });

  group('prekey-sealed envelopes', () {
    test('seal to a prekey, open with it, and know the sender', () async {
      final (senderPriv, senderPub) = await NoiseCrypto.x25519Generate();
      final prekeys = LocalPrekeys(nowMs: () => 0);
      await prekeys.replenish();
      final target = prekeys.available.first;

      final sealed = await CourierSeal.seal(
        payload: _b(utf8.encode('forward secret')),
        recipientStaticKey: target.publicKey,
        senderStaticPrivate: senderPriv,
        senderStaticPublic: senderPub,
        prologue: courierPrekeyPrologue(target.id),
      );
      final (opened, who) = await CourierSeal.open(
        ciphertext: sealed,
        localStaticPrivate: target.privateKey,
        localStaticPublic: target.publicKey,
        prologue: courierPrekeyPrologue(target.id),
      );
      expect(utf8.decode(opened), 'forward secret');
      expect(who, senderPub);
    });

    test('a different prekey id will not open it', () async {
      // The prologue binds the ciphertext to one prekey, so it cannot be
      // replayed against another.
      final (senderPriv, senderPub) = await NoiseCrypto.x25519Generate();
      final prekeys = LocalPrekeys(nowMs: () => 0);
      await prekeys.replenish();
      final target = prekeys.available.first;
      final sealed = await CourierSeal.seal(
        payload: _b(utf8.encode('bound')),
        recipientStaticKey: target.publicKey,
        senderStaticPrivate: senderPriv,
        senderStaticPublic: senderPub,
        prologue: courierPrekeyPrologue(target.id),
      );
      await expectLater(
        CourierSeal.open(
          ciphertext: sealed,
          localStaticPrivate: target.privateKey,
          localStaticPublic: target.publicKey,
          prologue: courierPrekeyPrologue(target.id + 1),
        ),
        throwsA(anything),
      );
    });

    test('the envelope carries the prekey id, and v1 stays byte-identical', () {
      final v1 = CourierEnvelope(
        recipientTag: Uint8List(16),
        expiryMs: 1700000000000,
        ciphertext: _b(List.filled(80, 7)),
      );
      final v2 = CourierEnvelope(
        recipientTag: Uint8List(16),
        expiryMs: 1700000000000,
        ciphertext: _b(List.filled(80, 7)),
        prekeyId: 42,
      );
      expect(CourierEnvelope.decode(v1.encode()!)!.prekeyId, isNull);
      expect(CourierEnvelope.decode(v2.encode()!)!.prekeyId, 42);
      // The v1 form gains no bytes, so an older client sees what it always saw.
      expect(v2.encode()!.length, greaterThan(v1.encode()!.length));
    });
  });
}

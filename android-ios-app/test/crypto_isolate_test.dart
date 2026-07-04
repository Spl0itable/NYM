import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/crypto_worker.dart';
import 'package:nym_bar/core/crypto/gift_wrap.dart' as gw;
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/models/nostr_event.dart';

/// Tests for the off-main-thread gift-wrap worker (`crypto_worker.dart`).
///
/// `compute` does not spawn a background isolate under `flutter test` (there is
/// no Flutter engine binding to host it), so these tests exercise the PURE
/// top-level isolate entrypoints — [wrapBatchIsolate] / [unwrapBatchIsolate] —
/// directly with the exact same inputs the `compute` payload would carry. That
/// is the load-bearing code: the `CryptoWorker` facade only batches/marshals
/// calls into these functions, and on web / on isolate failure it runs the same
/// `giftwrap.*` functions inline. The `CryptoWorker.wrapMany`/`unwrap` facade is
/// also smoke-tested (on the test host it resolves via the inline/fallback
/// path), proving the marshalling round-trips.
void main() {
  /// Builds the unwrap-isolate job map for [wrap] + [candidates], matching the
  /// `compute` payload shape produced inside `crypto_worker.dart`.
  Map<String, dynamic> unwrapJob(
    NostrEvent wrap,
    List<gw.UnwrapCandidate> candidates,
  ) =>
      {
        'wrap': wrap.toJson(),
        'cands': [
          for (final c in candidates)
            {'sk': bytesToHex(c.sk), 'bc': c.bitchat},
        ],
      };

  /// Builds the wrap-isolate job map for one recipient.
  Map<String, dynamic> wrapJob({
    required UnsignedEvent rumor,
    required Uint8List senderPrivkey,
    required String recipientPubkey,
    int? expiration,
  }) =>
      {
        'rumor': rumor.toJson(),
        'sk': bytesToHex(senderPrivkey),
        'rcpt': recipientPubkey,
        if (expiration != null) 'exp': expiration,
      };

  group('wrapBatchIsolate (outbound wrap entrypoint)', () {
    test('ROUND-TRIP: wrap to a recipient then unwrap yields the rumor', () async {
      final senderSk = generatePrivateKey();
      final recipientSk = generatePrivateKey();
      final senderPub = getPublicKeyHex(senderSk);
      final recipientPub = getPublicKeyHex(recipientSk);

      final rumor = UnsignedEvent(
        pubkey: senderPub,
        createdAt: 1700000000,
        kind: 14,
        tags: [
          ['p', recipientPub],
        ],
        content: 'isolate round-trip secret',
      );

      final wraps = wrapBatchIsolate([
        wrapJob(
          rumor: rumor,
          senderPrivkey: senderSk,
          recipientPubkey: recipientPub,
        ),
      ]);
      expect(wraps.length, 1);
      final wrap = NostrEvent.fromJson(wraps.first!);
      expect(wrap.kind, 1059);
      expect(wrap.tagValue('p'), recipientPub);
      // A worker-produced wrap is a fully valid, signed kind-1059 event.
      expect(schnorr.verifyEvent(wrap), isTrue);

      // Unwrap it (also through the isolate entrypoint) → original rumor.
      final results = await unwrapBatchIsolate([
        unwrapJob(wrap, [(sk: recipientSk, bitchat: false)]),
      ]);
      expect(results.length, 1);
      final res = results.first!;
      final unwrappedRumor = (res['rumor'] as Map).cast<String, dynamic>();
      expect(unwrappedRumor['content'], 'isolate round-trip secret');
      expect(unwrappedRumor['pubkey'], senderPub);
      final seal = NostrEvent.fromJson(res['seal'] as Map<String, dynamic>);
      expect(seal.pubkey, senderPub);
      expect(res['isBitchat'], isFalse);
    });

    test('expiration tag is carried through the wrap entrypoint', () {
      final senderSk = generatePrivateKey();
      final recipientPub = getPublicKeyHex(generatePrivateKey());
      final wraps = wrapBatchIsolate([
        wrapJob(
          rumor: UnsignedEvent(
            pubkey: getPublicKeyHex(senderSk),
            createdAt: 1700000000,
            kind: 14,
            content: 'x',
          ),
          senderPrivkey: senderSk,
          recipientPubkey: recipientPub,
          expiration: 1800000000,
        ),
      ]);
      final wrap = NostrEvent.fromJson(wraps.first!);
      expect(wrap.tagValue('expiration'), '1800000000');
    });

    test('batches the whole recipient list in one call, positionally aligned',
        () async {
      final senderSk = generatePrivateKey();
      final senderPub = getPublicKeyHex(senderSk);
      final r0 = generatePrivateKey();
      final r1 = generatePrivateKey();
      final r2 = generatePrivateKey();
      final pubs = [getPublicKeyHex(r0), getPublicKeyHex(r1), getPublicKeyHex(r2)];

      final rumor = UnsignedEvent(
        pubkey: senderPub,
        createdAt: 1700000000,
        kind: 14,
        content: 'group fan-out',
      );
      final wraps = wrapBatchIsolate([
        for (final pk in pubs)
          wrapJob(rumor: rumor, senderPrivkey: senderSk, recipientPubkey: pk),
      ]);
      expect(wraps.length, 3);
      // Each wrap targets its OWN recipient (positional alignment).
      for (var i = 0; i < 3; i++) {
        expect(wraps[i]!['tags'].toString().contains(pubs[i]), isTrue);
      }
      // And only the matching recipient key can unwrap each (no cross-talk).
      final sks = [r0, r1, r2];
      for (var i = 0; i < 3; i++) {
        final wrap = NostrEvent.fromJson(wraps[i]!);
        final ok = await unwrapBatchIsolate([
          unwrapJob(wrap, [(sk: sks[i], bitchat: false)]),
        ]);
        expect(ok.first, isNotNull, reason: 'recipient $i should decrypt');
        final wrong = await unwrapBatchIsolate([
          unwrapJob(wrap, [(sk: sks[(i + 1) % 3], bitchat: false)]),
        ]);
        expect(wrong.first, isNull, reason: 'wrong key must not decrypt');
      }
    });
  });

  group('unwrapBatchIsolate (inbound unwrap entrypoint)', () {
    test('EQUIVALENCE: isolate unwrap == synchronous unwrapGiftWrap', () async {
      final senderSk = generatePrivateKey();
      final recipientSk = generatePrivateKey();
      final senderPub = getPublicKeyHex(senderSk);
      final recipientPub = getPublicKeyHex(recipientSk);

      // Build a real wrap with the existing sync path.
      final wrap = gw.nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: senderPub,
          createdAt: 1700000000,
          kind: 14,
          tags: [
            ['p', recipientPub],
          ],
          content: 'equivalence check payload',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: recipientPub,
      );

      final candidates = <gw.UnwrapCandidate>[
        (sk: recipientSk, bitchat: false),
      ];

      // Existing synchronous reference output.
      final sync = await gw.unwrapGiftWrap(wrap, candidates);
      expect(sync, isNotNull);

      // Worker entrypoint output for the same input.
      final batch = await unwrapBatchIsolate([unwrapJob(wrap, candidates)]);
      final iso = batch.first;
      expect(iso, isNotNull);

      // The recovered rumor + seal + bitchat flag must match byte-for-byte.
      expect(iso!['rumor'], sync!.rumor);
      expect(iso['isBitchat'], sync.isBitchat);
      final isoSeal = NostrEvent.fromJson(iso['seal'] as Map<String, dynamic>);
      expect(isoSeal.id, sync.seal.id);
      expect(isoSeal.pubkey, sync.seal.pubkey);
      expect(isoSeal.sig, sync.seal.sig);
      expect(isoSeal.content, sync.seal.content);
    });

    test('EQUIVALENCE for bitchat (v2:) wraps too', () async {
      final senderSk = generatePrivateKey();
      final recipientSk = generatePrivateKey();
      final recipientPub = getPublicKeyHex(recipientSk);

      final wrap = await gw.bitchatWrap(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1700000000,
          kind: 14,
          content: 'bitchat over isolate',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: recipientPub,
      );
      final candidates = <gw.UnwrapCandidate>[
        (sk: recipientSk, bitchat: true),
      ];

      final sync = await gw.unwrapGiftWrap(wrap, candidates);
      final batch = await unwrapBatchIsolate([unwrapJob(wrap, candidates)]);
      final iso = batch.first;
      expect(iso, isNotNull);
      expect(iso!['rumor'], sync!.rumor);
      expect(iso['isBitchat'], isTrue);
      expect(sync.isBitchat, isTrue);
    });

    test('non-decryptable wrap yields null (skip, no throw)', () async {
      final senderSk = generatePrivateKey();
      final recipientPub = getPublicKeyHex(generatePrivateKey());
      final stranger = generatePrivateKey();
      final wrap = gw.nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1700000000,
          kind: 14,
          content: 'not for the stranger',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: recipientPub,
      );
      // Wrong candidate key — must skip to null, never throw.
      final batch = await unwrapBatchIsolate([
        unwrapJob(wrap, [(sk: stranger, bitchat: false)]),
      ]);
      expect(batch.length, 1);
      expect(batch.first, isNull);
    });

    test('per-job isolation: one undecryptable job nulls only its own slot',
        () async {
      final senderSk = generatePrivateKey();
      final goodSk = generatePrivateKey();
      final goodPub = getPublicKeyHex(goodSk);
      final stranger = generatePrivateKey();

      final goodWrap = gw.nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1700000000,
          kind: 14,
          content: 'good',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: goodPub,
      );
      final badWrap = gw.nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1700000000,
          kind: 14,
          content: 'bad',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: getPublicKeyHex(generatePrivateKey()),
      );

      final batch = await unwrapBatchIsolate([
        unwrapJob(goodWrap, [(sk: goodSk, bitchat: false)]),
        unwrapJob(badWrap, [(sk: stranger, bitchat: false)]),
      ]);
      expect(batch.length, 2);
      expect(batch[0], isNotNull); // decryptable
      expect(batch[1], isNull); // skipped
    });

    test('candidate try/next: succeeds on a later candidate in the list',
        () async {
      final senderSk = generatePrivateKey();
      final recipientSk = generatePrivateKey();
      final recipientPub = getPublicKeyHex(recipientSk);
      final wrap = gw.nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1700000000,
          kind: 14,
          content: 'second candidate wins',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: recipientPub,
      );
      // First candidate is wrong, second is the real recipient.
      final batch = await unwrapBatchIsolate([
        unwrapJob(wrap, [
          (sk: generatePrivateKey(), bitchat: false),
          (sk: recipientSk, bitchat: false),
        ]),
      ]);
      final res = batch.first;
      expect(res, isNotNull);
      expect(
        (res!['rumor'] as Map)['content'],
        'second candidate wins',
      );
    });
  });

  group('CryptoWorker facade (marshalling round-trip via inline/fallback)', () {
    test('wrapMany then unwrap recovers the rumor for every recipient',
        () async {
      final worker = CryptoWorker();
      final senderSk = generatePrivateKey();
      final senderPub = getPublicKeyHex(senderSk);
      final r0 = generatePrivateKey();
      final r1 = generatePrivateKey();
      final pubs = [getPublicKeyHex(r0), getPublicKeyHex(r1)];

      final rumor = UnsignedEvent(
        pubkey: senderPub,
        createdAt: 1700000000,
        kind: 14,
        content: 'facade fan-out',
      );
      final wraps = await worker.wrapMany(
        rumor: rumor,
        senderPrivkey: senderSk,
        recipientPubkeys: pubs,
      );
      expect(wraps.length, 2);
      expect(wraps.every((w) => w != null), isTrue);

      final sks = [r0, r1];
      for (var i = 0; i < 2; i++) {
        final res = await worker.unwrap(
          wraps[i]!,
          [(sk: sks[i], bitchat: false)],
        );
        expect(res, isNotNull);
        expect(res!.rumor['content'], 'facade fan-out');
        expect(res.rumor['pubkey'], senderPub);
      }
    });

    test('wrapMany with empty recipients returns empty (no isolate hop)',
        () async {
      final worker = CryptoWorker();
      final wraps = await worker.wrapMany(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(generatePrivateKey()),
          createdAt: 1700000000,
          kind: 14,
          content: 'none',
        ),
        senderPrivkey: generatePrivateKey(),
        recipientPubkeys: const [],
      );
      expect(wraps, isEmpty);
    });

    test('unwrap returns null for the wrong recipient (facade skip)', () async {
      final worker = CryptoWorker();
      final senderSk = generatePrivateKey();
      final recipientPub = getPublicKeyHex(generatePrivateKey());
      final wrap = gw.nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1700000000,
          kind: 14,
          content: 'nope',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: recipientPub,
      );
      final res = await worker.unwrap(
        wrap,
        [(sk: generatePrivateKey(), bitchat: false)],
      );
      expect(res, isNull);
    });

    test('debugEncodeUnwrapJob produces a sendable, decodable payload', () {
      final senderSk = generatePrivateKey();
      final recipientSk = generatePrivateKey();
      final recipientPub = getPublicKeyHex(recipientSk);
      final wrap = gw.nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1700000000,
          kind: 14,
          content: 'payload codec',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: recipientPub,
      );
      final job = debugEncodeUnwrapJob(wrap, [(sk: recipientSk, bitchat: false)]);
      // The encoded job is a plain JSON-able map carrying the key as hex.
      expect(job['wrap'], isA<Map<String, dynamic>>());
      final cands = (job['cands'] as List).cast<Map<String, dynamic>>();
      expect(cands.single['sk'], bytesToHex(recipientSk));
      expect(cands.single['bc'], isFalse);
    });
  });
}

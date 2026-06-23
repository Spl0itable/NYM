import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/nymbot/nymbot_providers.dart';
import 'package:nym_bar/features/p2p/p2p_models.dart';

void main() {
  // ===========================================================================
  // Nymbot routing decision (?cmd / @Nymbot / normal text)
  // ===========================================================================
  group('nymbot interception routing', () {
    test('?ask x is a bot command', () {
      expect(isBotCommand('?ask x'), isTrue);
      expect(isNymbotMention('?ask x'), isFalse);
    });

    test('?flip (no args) is a bot command', () {
      expect(isBotCommand('?flip'), isTrue);
    });

    test('"? " or "?" alone is NOT a command (needs a token)', () {
      expect(isBotCommand('? foo'), isFalse);
      expect(isBotCommand('?'), isFalse);
    });

    test('@Nymbot hi is a mention but not a ? command', () {
      expect(isNymbotMention('@Nymbot hi'), isTrue);
      expect(isBotCommand('@Nymbot hi'), isFalse);
    });

    test('@Nymbot mention is case-insensitive and word-bounded', () {
      expect(isNymbotMention('hey @nymbot what is nostr'), isTrue);
      expect(isNymbotMention('@NYMBOT yo'), isTrue);
      // Not part of a longer handle.
      expect(isNymbotMention('@Nymbotz hello'), isFalse);
    });

    test('normal text routes to neither', () {
      expect(isBotCommand('hello world'), isFalse);
      expect(isNymbotMention('hello world'), isFalse);
      expect(isBotCommand('a ? in the middle'), isFalse);
    });

    test('stripNymbotMention turns @Nymbot q into the ?ask args', () {
      expect(stripNymbotMention('@Nymbot what is nostr'), 'what is nostr');
      expect(stripNymbotMention('hey @nymbot how are you'), 'hey how are you');
    });
  });

  // ===========================================================================
  // P2P chunking: 16 KiB split + final partial, round-trip, SHA-256 integrity
  // ===========================================================================
  group('p2p chunking', () {
    Uint8List randomBytes(int n, int seed) {
      final rng = Random(seed);
      return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
    }

    test('exact multiple of chunk size splits cleanly (no partial)', () {
      final bytes = randomBytes(P2PConstants.chunkSize * 3, 1);
      final chunks = chunkBytes(bytes);
      expect(chunks.length, 3);
      for (final c in chunks) {
        expect(c.length, P2PConstants.chunkSize);
      }
    });

    test('non-multiple yields N full chunks + a final partial', () {
      final bytes = randomBytes(P2PConstants.chunkSize * 2 + 123, 2);
      final chunks = chunkBytes(bytes);
      expect(chunks.length, 3);
      expect(chunks[0].length, P2PConstants.chunkSize);
      expect(chunks[1].length, P2PConstants.chunkSize);
      expect(chunks[2].length, 123); // final partial
    });

    test('reassembly round-trips the exact bytes', () {
      final bytes = randomBytes(P2PConstants.chunkSize * 4 + 7, 3);
      final chunks = chunkBytes(bytes);
      final back = reassembleChunks(chunks);
      expect(back, equals(bytes));
    });

    test('SHA-256 of reassembled == SHA-256 of original', () {
      final bytes = randomBytes(P2PConstants.chunkSize * 5 + 999, 4);
      final original = sha256.convert(bytes).toString();
      final back = reassembleChunks(chunkBytes(bytes));
      expect(sha256Hex(back), original);
    });

    test('empty buffer yields no chunks and an empty reassembly', () {
      final chunks = chunkBytes(Uint8List(0));
      expect(chunks, isEmpty);
      expect(reassembleChunks(chunks), isEmpty);
    });

    test('chunk size constant matches the PWA (16384)', () {
      expect(P2PConstants.chunkSize, 16384);
      expect(P2PConstants.maxFileSize, 2 * 1024 * 1024 * 1024);
    });
  });

  // ===========================================================================
  // FileOffer builder + offer tag shape (publishFileOffer / parseFileOfferTag)
  // ===========================================================================
  group('file offer builder + tag', () {
    final bytes = Uint8List.fromList(utf8.encode('hello p2p world'));
    final seeder = 'a' * 64;

    test('fromBytes computes the hash and offerId = hash[:16]-base36(now)', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final offer = FileOffer.fromBytes(
        bytes: bytes,
        name: 'note.txt',
        type: 'text/plain',
        seederPubkey: seeder,
        now: now,
      );
      final fullHash = sha256.convert(bytes).toString();
      expect(offer.hash, fullHash);
      expect(offer.size, bytes.length);
      expect(offer.seederPubkey, seeder);
      expect(offer.type, 'text/plain');
      expect(
        offer.offerId,
        '${fullHash.substring(0, 16)}-${now.millisecondsSinceEpoch.toRadixString(36)}',
      );
      expect(offer.timestamp, now.millisecondsSinceEpoch ~/ 1000);
    });

    test("empty mime defaults to application/octet-stream", () {
      final offer = FileOffer.fromBytes(
        bytes: bytes,
        name: 'blob',
        type: '',
        seederPubkey: seeder,
      );
      expect(offer.type, 'application/octet-stream');
    });

    test('fileOfferTag is ["offer", JSON] and round-trips via parse', () {
      final offer = FileOffer.fromBytes(
        bytes: bytes,
        name: 'note.txt',
        type: 'text/plain',
        seederPubkey: seeder,
      );
      final tag = fileOfferTag(offer);
      expect(tag[0], 'offer');
      final decoded = jsonDecode(tag[1]) as Map<String, dynamic>;
      expect(decoded['offerId'], offer.offerId);
      expect(decoded['name'], 'note.txt');
      expect(decoded['hash'], offer.hash);

      // parseFileOfferTag binds seederPubkey to the actual sender.
      final parsed = parseFileOfferTag([tag], seeder);
      expect(parsed, isNotNull);
      expect(parsed!.offerId, offer.offerId);
      expect(parsed.seederPubkey, seeder);
    });

    test('parseFileOfferTag rejects a seeder/sender mismatch', () {
      final offer = FileOffer.fromBytes(
        bytes: bytes,
        name: 'x',
        type: 'text/plain',
        seederPubkey: seeder,
      );
      final tag = fileOfferTag(offer);
      // Different sender than the advertised seederPubkey → rejected.
      expect(parseFileOfferTag([tag], 'b' * 64), isNull);
    });

    test('parseFileOfferTag returns null when no offer tag present', () {
      expect(parseFileOfferTag([
        ['n', 'alice'],
        ['g', '9q8y'],
      ], seeder), isNull);
    });
  });

  // ===========================================================================
  // Wire payload shapes — kind 25051 signaling + kind 25052 file status
  // ===========================================================================
  group('p2p wire payloads', () {
    test('25051 signaling payload is p-tagged with the JSON data as content', () {
      final target = 'c' * 64;
      final data = offerSignal(
        sdp: {'type': 'offer', 'sdp': 'v=0...'},
        transferId: 'tx1',
        offerId: 'of1',
      );
      final payload = buildSignalPayload(targetPubkey: target, data: data);
      expect(payload.tags, [
        ['p', target],
      ]);
      final decoded = jsonDecode(payload.content) as Map<String, dynamic>;
      expect(decoded['type'], 'offer');
      expect(decoded['transferId'], 'tx1');
      expect(decoded['offerId'], 'of1');
      expect((decoded['sdp'] as Map)['sdp'], 'v=0...');
    });

    test('answer + ice signal shapes', () {
      final answer = answerSignal(
        sdp: {'type': 'answer', 'sdp': 'a=...'},
        transferId: 'tx2',
      );
      expect(answer['type'], 'answer');
      expect(answer['transferId'], 'tx2');

      final ice = iceSignal(
        candidate: {'candidate': 'candidate:1 ...', 'sdpMLineIndex': 0},
        transferId: 'tx2',
      );
      expect(ice['type'], 'ice-candidate');
      expect(ice['transferId'], 'tx2');
      expect((ice['candidate'] as Map)['sdpMLineIndex'], 0);
    });

    test('25052 unseeded payload carries offer_id/status/x tags + JSON', () {
      final offer = FileOffer.fromBytes(
        bytes: Uint8List.fromList([1, 2, 3]),
        name: 'song.mp3',
        type: 'audio/mpeg',
        seederPubkey: 'd' * 64,
      );
      final payload = buildUnseededPayload(offer: offer, geohash: '9q8y');
      bool hasTag(List<String> t) => payload.tags
          .any((x) => x.length == t.length && x[0] == t[0] && x[1] == t[1]);
      expect(hasTag(['offer_id', offer.offerId]), isTrue);
      expect(hasTag(['status', 'unseeded']), isTrue);
      expect(hasTag(['x', offer.hash]), isTrue);
      expect(hasTag(['g', '9q8y']), isTrue);
      final decoded = jsonDecode(payload.content) as Map<String, dynamic>;
      expect(decoded['offerId'], offer.offerId);
      expect(decoded['name'], 'song.mp3');
      expect(decoded['status'], 'unseeded');
    });

    test('unseeded payload omits the geohash tag when none provided', () {
      final offer = FileOffer.fromBytes(
        bytes: Uint8List.fromList([9]),
        name: 'f',
        type: 'text/plain',
        seederPubkey: 'e' * 64,
      );
      final payload = buildUnseededPayload(offer: offer);
      expect(payload.tags.any((t) => t[0] == 'g'), isFalse);
    });

    test('signaling/file-status kinds match the PWA (25051/25052)', () {
      expect(P2PConstants.signalingKind, 25051);
      expect(P2PConstants.fileStatusKind, 25052);
    });
  });

  // ===========================================================================
  // Upload flow (pure builder part) — Blossom auth + size cap helpers
  // ===========================================================================
  group('upload helpers', () {
    test('formatFileSize matches the PWA thresholds', () {
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(1536), '1.5 KB');
      expect(formatFileSize(5 * 1024 * 1024), '5.0 MB');
    });

    test('sanitizeDownloadFilename strips path separators + control chars', () {
      expect(sanitizeDownloadFilename('a/b\\c.txt'), 'a_b_c.txt');
      expect(sanitizeDownloadFilename('...hidden'), 'hidden');
      expect(sanitizeDownloadFilename(''), 'download');
    });
  });
}

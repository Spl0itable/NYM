import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/bech32_codec.dart' as b19;
import 'package:nym_bar/core/crypto/isolate_verifier.dart';
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/core/crypto/bitchat.dart' as bitchat;
import 'package:nym_bar/core/crypto/gift_wrap.dart' as gw;
import 'package:nym_bar/core/crypto/pow.dart' as pow;

void main() {
  group('keys', () {
    test('generatePrivateKey produces a valid 32-byte key', () {
      final sk = generatePrivateKey();
      expect(sk.length, 32);
    });

    test('getPublicKeyHex returns 64-hex x-only pubkey', () {
      final sk = generatePrivateKey();
      final pub = getPublicKeyHex(sk);
      expect(pub.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(pub), isTrue);
    });

    test('hex round-trips', () {
      final bytes = Uint8List.fromList([0, 1, 255, 16, 171]);
      expect(bytesToHex(bytes), '0001ff10ab');
      expect(hexToBytes('0001ff10ab'), bytes);
    });
  });

  group('bech32 / NIP-19', () {
    test('npub known vector (NIP-19)', () {
      const hexPub =
          '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d';
      const npub =
          'npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6';
      expect(b19.encodeNpub(hexPub), npub);
      expect(b19.decodeNpub(npub), hexPub);
    });

    test('nsec known vector (NIP-19)', () {
      const hexSec =
          '67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa';
      const nsec =
          'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';
      expect(b19.encodeNsec(hexSec), nsec);
      expect(bytesToHex(b19.decodeNsec(nsec)), hexSec);
    });

    test('npub/nsec/note round-trip for random keys', () {
      final sk = generatePrivateKey();
      final pub = getPublicKeyHex(sk);
      final npub = b19.encodeNpub(pub);
      expect(b19.decodeNpub(npub), pub);

      final nsec = b19.encodeNsecBytes(sk);
      expect(b19.decodeNsec(nsec), sk);

      final id = 'a' * 64; // 64-char hex placeholder id
      final note = b19.encodeNote(id);
      expect(b19.decodeNote(note), id);
    });
  });

  group('schnorr / events', () {
    test('sign then verify round-trips', () {
      final sk = generatePrivateKey();
      final unsigned = UnsignedEvent(
        pubkey: getPublicKeyHex(sk),
        createdAt: 1700000000,
        kind: 1,
        tags: const [],
        content: 'hello nostr',
      );
      final event = schnorr.finalizeEvent(unsigned, sk);
      expect(event.sig.length, 128);
      expect(schnorr.verifyEvent(event), isTrue);
    });

    test('tampered event fails verify', () {
      final sk = generatePrivateKey();
      final event = schnorr.finalizeEvent(
        UnsignedEvent(
          pubkey: getPublicKeyHex(sk),
          createdAt: 1700000000,
          kind: 1,
          content: 'original',
        ),
        sk,
      );
      // Tamper with content; id no longer matches.
      final tampered = NostrEvent(
        id: event.id,
        pubkey: event.pubkey,
        createdAt: event.createdAt,
        kind: event.kind,
        tags: event.tags,
        content: 'tampered',
        sig: event.sig,
      );
      expect(schnorr.verifyEvent(tampered), isFalse);

      // Tamper with the signature directly.
      final badSig = NostrEvent(
        id: event.id,
        pubkey: event.pubkey,
        createdAt: event.createdAt,
        kind: event.kind,
        tags: event.tags,
        content: event.content,
        // Flip the first hex char to one guaranteed to differ.
        sig: '${event.sig[0] == 'a' ? 'b' : 'a'}${event.sig.substring(1)}',
      );
      expect(schnorr.verifyEvent(badSig), isFalse);
    });
  });

  group('isolate verifier (off-thread batch verification)', () {
    NostrEvent signedEvent(String content) {
      final sk = generatePrivateKey();
      return schnorr.finalizeEvent(
        UnsignedEvent(
          pubkey: getPublicKeyHex(sk),
          createdAt: 1700000000,
          kind: 1,
          content: content,
        ),
        sk,
      );
    }

    NostrEvent forge(NostrEvent valid, String newContent) => NostrEvent(
          id: valid.id, // stale id; no longer matches the tampered content
          pubkey: valid.pubkey,
          createdAt: valid.createdAt,
          kind: valid.kind,
          tags: valid.tags,
          content: newContent,
          sig: valid.sig,
        );

    test('verifyEventsBatch returns one positionally-aligned verdict per event',
        () {
      final good0 = signedEvent('zero');
      final good2 = signedEvent('two');
      final bad1 = forge(good0, 'tampered');
      // Order: valid, INVALID, valid. The verdict list must line up exactly.
      final results = verifyEventsBatch(
        [good0.toJson(), bad1.toJson(), good2.toJson()],
      );
      expect(results, [true, false, true]);
    });

    test('verifyEventsBatch agrees with synchronous verifyEvent element-wise',
        () {
      final events = [
        signedEvent('a'),
        forge(signedEvent('b'), 'b!'),
        signedEvent('c'),
        signedEvent('d'),
      ];
      final batch = verifyEventsBatch([for (final e in events) e.toJson()]);
      final sync = [for (final e in events) schnorr.verifyEvent(e)];
      expect(batch, sync);
    });

    test('empty batch yields empty result (no drops, no spurious passes)', () {
      expect(verifyEventsBatch(const []), isEmpty);
    });

    test(
        'IsolateVerifier resolves each event to its own verdict across a burst',
        () async {
      final verifier = IsolateVerifier();
      final good0 = signedEvent('keep-0');
      final good1 = signedEvent('keep-1');
      final bad = forge(good0, 'forged');
      final good2 = signedEvent('keep-2');
      // Submit all in the SAME synchronous turn so they coalesce into one
      // isolate hop; each future must still get its own positional verdict.
      final futures = <Future<bool>>[
        verifier.verify(good0),
        verifier.verify(bad),
        verifier.verify(good1),
        verifier.verify(good2),
      ];
      final results = await Future.wait(futures);
      expect(results, [true, false, true, true]);
    });

    test('IsolateVerifier never drops a valid event in a large batch', () async {
      final verifier = IsolateVerifier(maxBatch: 8);
      // More events than maxBatch so the buffer flushes mid-turn; all valid.
      final events = [for (var i = 0; i < 20; i++) signedEvent('e$i')];
      final results =
          await Future.wait([for (final e in events) verifier.verify(e)]);
      expect(results.length, events.length);
      expect(results.every((ok) => ok), isTrue);
    });
  });

  group('NIP-44 v2 official vectors', () {
    test('get_conversation_key vectors', () {
      const vectors = [
        [
          '315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268',
          'c2f9d9948dc8c7c38321e4b85c8558872eafa0641cd269db76848a6073e69133',
          '3dfef0ce2a4d80a25e7a328accf73448ef67096f65f79588e358d9a0eb9013f1',
        ],
        [
          'a1e37752c9fdc1273be53f68c5f74be7c8905728e8de75800b94262f9497c86e',
          '03bb7947065dde12ba991ea045132581d0954f042c84e06d8c00066e23c1a800',
          '4d14f36e81b8452128da64fe6f1eae873baae2f444b02c950b90e43553f2178b',
        ],
        [
          '98a5902fd67518a0c900f0fb62158f278f94a21d6f9d33d30cd3091195500311',
          'aae65c15f98e5e677b5050de82e3aba47a6fe49b3dab7863cf35d9478ba9f7d1',
          '9c00b769d5f54d02bf175b7284a1cbd28b6911b06cda6666b2243561ac96bad7',
        ],
      ];
      for (final v in vectors) {
        final ck = nip44.getConversationKey(hexToBytes(v[0]), v[1]);
        expect(bytesToHex(ck), v[2]);
      }
    });

    test('encrypt with fixed nonce produces exact payload + decrypt', () {
      const vectors = [
        [
          'c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d',
          '0000000000000000000000000000000000000000000000000000000000000001',
          'a',
          'AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb',
        ],
        [
          'c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d',
          'f00000000000000000000000000000f00000000000000000000000000000000f',
          '🍕🫃',
          'AvAAAAAAAAAAAAAAAAAAAPAAAAAAAAAAAAAAAAAAAAAPSKSK6is9ngkX2+cSq85Th16oRTISAOfhStnixqZziKMDvB0QQzgFZdjLTPicCJaV8nDITO+QfaQ61+KbWQIOO2Yj',
        ],
        [
          '3e2b52a63be47d34fe0a80e34e73d436d6963bc8f39827f327057a9986c20a45',
          'b635236c42db20f021bb8d1cdff5ca75dd1a0cc72ea742ad750f33010b24f73b',
          '表ポあA鷗ŒéＢ逍Üßªąñ丂㐀𠀀',
          'ArY1I2xC2yDwIbuNHN/1ynXdGgzHLqdCrXUPMwELJPc7s7JqlCMJBAIIjfkpHReBPXeoMCyuClwgbT419jUWU1PwaNl4FEQYKCDKVJz+97Mp3K+Q2YGa77B6gpxB/lr1QgoqpDf7wDVrDmOqGoiPjWDqy8KzLueKDcm9BVP8xeTJIxs=',
        ],
      ];
      for (final v in vectors) {
        final ck = hexToBytes(v[0]);
        final nonce = hexToBytes(v[1]);
        final payload = nip44.encrypt(v[2], ck, nonce: nonce);
        expect(payload, v[3], reason: 'encrypt "${v[2]}"');
        expect(nip44.decrypt(v[3], ck), v[2], reason: 'decrypt "${v[2]}"');
      }
    });

    test('encrypt -> decrypt round-trip with derived conversation key', () {
      final skA = generatePrivateKey();
      final skB = generatePrivateKey();
      final pubA = getPublicKeyHex(skA);
      final pubB = getPublicKeyHex(skB);
      final ckA = nip44.getConversationKey(skA, pubB);
      final ckB = nip44.getConversationKey(skB, pubA);
      expect(bytesToHex(ckA), bytesToHex(ckB)); // shared

      const message = 'Wire-compatible secret 🤫';
      final payload = nip44.encrypt(message, ckA);
      expect(nip44.decrypt(payload, ckB), message);
    });

    test('decrypt fails on tampered MAC', () {
      final ck = hexToBytes(
          'c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d');
      final payload = nip44.encrypt('tamper me', ck);
      final raw = base64.decode(payload);
      raw[raw.length - 1] ^= 0x01; // flip a MAC bit
      final bad = base64.encode(raw);
      expect(() => nip44.decrypt(bad, ck), throwsA(anything));
    });
  });

  group('bitchat transport', () {
    test('encrypt -> decrypt round-trip', () async {
      final skA = generatePrivateKey();
      final skB = generatePrivateKey();
      final pubA = getPublicKeyHex(skA);
      final pubB = getPublicKeyHex(skB);

      const message = 'bitchat interop 🛰️';
      final ct = await bitchat.encryptBitchat(message, skA, pubB);
      expect(ct.startsWith('v2:'), isTrue);

      final pt = await bitchat.decryptBitchat(ct, pubA, skB);
      expect(pt, message);
    });

    // Encrypt with A's key to B; B decrypts using A's pubkey. The bitchat ECDH
    // shared point is the 33-byte COMPRESSED point, and `sk_A·lift02(P_B)` vs
    // `sk_B·lift02(P_A)` share the same x but can differ in y-parity (02 vs 03),
    // so decrypt must try BOTH lifts of the sender pubkey. Sweep many keypairs
    // so the odd-parity branch is exercised (~50% of pairs).
    test('cross-key round-trip exercises both 02/03 parity lifts', () async {
      var ok = 0;
      for (var i = 0; i < 24; i++) {
        final skA = generatePrivateKey();
        final skB = generatePrivateKey();
        final pubA = getPublicKeyHex(skA);
        final pubB = getPublicKeyHex(skB);
        final msg = 'parity sweep #$i';
        final ct = await bitchat.encryptBitchat(msg, skA, pubB);
        final pt = await bitchat.decryptBitchat(ct, pubA, skB);
        expect(pt, msg);
        ok++;
      }
      expect(ok, 24);
    });

    test('decodeBitchatPacket extracts text + id from a bitchat1: packet', () {
      const text = 'hi from the bitchat app';
      const id = '07DFE7B7-151D-40D8-BA38-B93C7B0E0A11';
      final packet = _encodeBitchatPrivateMessage(text, id);
      expect(bitchat.isBitchatPacket(packet), isTrue);

      final decoded = bitchat.decodeBitchatPacket(packet);
      expect(decoded, isNotNull);
      expect(decoded!.isPrivateMessage, isTrue);
      expect(decoded.content, text);
      expect(decoded.messageId, id);
    });

    test('decodeBitchatPacket handles content > 255 bytes (extended length)',
        () {
      final text = 'x' * 600; // forces the 0x80 extended-length TLV path
      const id = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
      final decoded =
          bitchat.decodeBitchatPacket(_encodeBitchatPrivateMessage(text, id));
      expect(decoded, isNotNull);
      expect(decoded!.content, text);
      expect(decoded.messageId, id);
    });
  });

  group('gift wrap (NIP-59)', () {
    test('randomNow is within +/- 2h of now', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final t = gw.randomNow();
      expect(t, lessThanOrEqualTo(now));
      expect(t, greaterThanOrEqualTo(now - 7201));
    });

    test('nip59 wrap -> unwrap recovers rumor + sender', () async {
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
        content: 'secret DM contents',
      );

      final wrap = gw.nip59Wrap(
        rumor: rumor,
        senderPrivkey: senderSk,
        recipientPubkey: recipientPub,
      );
      expect(wrap.kind, 1059);
      expect(wrap.tagValue('p'), recipientPub);
      expect(schnorr.verifyEvent(wrap), isTrue);

      final result = await gw.unwrapGiftWrap(wrap, [
        (sk: recipientSk, bitchat: false),
      ]);
      expect(result, isNotNull);
      expect(result!.rumor['content'], 'secret DM contents');
      expect(result.rumor['pubkey'], senderPub);
      expect(result.seal.pubkey, senderPub);
      expect(result.isBitchat, isFalse);
    });

    test('nip59 wrap with expiration tag', () {
      final senderSk = generatePrivateKey();
      final recipientPub = getPublicKeyHex(generatePrivateKey());
      final wrap = gw.nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1700000000,
          kind: 14,
          content: 'x',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: recipientPub,
        expiration: 1800000000,
      );
      expect(wrap.tagValue('expiration'), '1800000000');
    });

    test('bitchat wrap -> unwrap recovers rumor', () async {
      final senderSk = generatePrivateKey();
      final recipientSk = generatePrivateKey();
      final senderPub = getPublicKeyHex(senderSk);
      final recipientPub = getPublicKeyHex(recipientSk);

      final wrap = await gw.bitchatWrap(
        rumor: UnsignedEvent(
          pubkey: senderPub,
          createdAt: 1700000000,
          kind: 14,
          content: 'bitchat DM',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: recipientPub,
      );
      expect(wrap.kind, 1059);
      expect(wrap.content.startsWith('v2:'), isTrue);

      final result = await gw.unwrapGiftWrap(wrap, [
        (sk: recipientSk, bitchat: true),
      ]);
      expect(result, isNotNull);
      expect(result!.isBitchat, isTrue);
      expect(result.rumor['content'], 'bitchat DM');
      expect(result.rumor['pubkey'], senderPub);
    });

    // Full two-layer bitchat unwrap of a real-Bitchat-shaped PM: the rumor
    // content is a `bitchat1:` BitchatPacket (not plain text). The wrap and seal
    // are both `v2:` (raw-ECDH), the seal is signed by the sender's real key,
    // and the wrap by a throwaway. After unwrap, decoding the packet must yield
    // the original text + bitchat message id.
    test('bitchat wrap with bitchat1: payload unwraps + decodes', () async {
      final senderSk = generatePrivateKey();
      final recipientSk = generatePrivateKey();
      final senderPub = getPublicKeyHex(senderSk);
      final recipientPub = getPublicKeyHex(recipientSk);

      const text = 'message from a bitchat user';
      const msgId = '12345678-90AB-CDEF-1234-567890ABCDEF';
      final packet = _encodeBitchatPrivateMessage(text, msgId);

      final wrap = await gw.bitchatWrap(
        rumor: UnsignedEvent(
          pubkey: senderPub,
          createdAt: 1700000000,
          kind: 14,
          tags: [
            ['p', recipientPub]
          ],
          content: packet,
        ),
        senderPrivkey: senderSk,
        recipientPubkey: recipientPub,
      );
      expect(wrap.content.startsWith('v2:'), isTrue);

      final result = await gw.unwrapGiftWrap(wrap, [
        (sk: recipientSk, bitchat: true),
      ]);
      expect(result, isNotNull);
      expect(result!.isBitchat, isTrue);
      // The crypto layer recovers the raw bitchat1: envelope...
      expect((result.rumor['content'] as String).startsWith('bitchat1:'),
          isTrue);
      // ...and the BitchatPacket decoder yields the human-readable text + id.
      final decoded =
          bitchat.decodeBitchatPacket(result.rumor['content'] as String);
      expect(decoded, isNotNull);
      expect(decoded!.content, text);
      expect(decoded.messageId, msgId);
    });

    test('unwrap returns null for wrong recipient', () async {
      final senderSk = generatePrivateKey();
      final recipientPub = getPublicKeyHex(generatePrivateKey());
      final stranger = generatePrivateKey();
      final wrap = gw.nip59Wrap(
        rumor: UnsignedEvent(
          pubkey: getPublicKeyHex(senderSk),
          createdAt: 1700000000,
          kind: 14,
          content: 'not for you',
        ),
        senderPrivkey: senderSk,
        recipientPubkey: recipientPub,
      );
      final result = await gw.unwrapGiftWrap(wrap, [
        (sk: stranger, bitchat: false),
      ]);
      expect(result, isNull);
    });
  });

  group('PoW (NIP-13)', () {
    test('getPow counts leading zero bits', () {
      expect(pow.getPow('00000000${'f' * 56}'), 32);
      // 0x00 0x2f -> 8 + clz(00101111)=2 = 10 leading zero bits.
      expect(
          pow.getPow(
              '002f00000000000000000000000000000000000000000000000000000000000a'),
          10);
      expect(pow.getPow('f${'0' * 63}'), 0);
    });

    test('minePow difficulty 8 yields id with >=8 leading zero bits', () {
      final sk = generatePrivateKey();
      final ev = UnsignedEvent(
        pubkey: getPublicKeyHex(sk),
        createdAt: 1700000000,
        kind: 1,
        content: 'mine me',
      );
      final mined = pow.minePow(ev, 8, sk);
      expect(pow.getPow(mined.id), greaterThanOrEqualTo(8));
      expect(pow.validatePow(mined, 8), isTrue);
      expect(schnorr.verifyEvent(mined), isTrue);
      // nonce tag commits the target difficulty.
      expect(mined.tagsNamed('nonce').first[2], '8');
    });

    test('validatePow false when difficulty unmet', () {
      final ev = NostrEvent(
        id: 'ff${'0' * 62}',
        pubkey: 'a' * 64,
        createdAt: 1,
        kind: 1,
        tags: [
          ['nonce', '0', '8']
        ],
        content: '',
      );
      expect(pow.validatePow(ev, 8), isFalse);
    });
  });
}

/// Builds a `bitchat1:` BitchatPacket carrying a PRIVATE_MESSAGE, mirroring the
/// PWA `encodeBitchatMessage` (nostr-core.js): 14-byte header, 8-byte sender id,
/// 8-byte recipient id (HAS_RECIPIENT), then NoisePayload = `0x01` +
/// TLV[MESSAGE_ID=0x00] + TLV[CONTENT=0x01], padded to a 256/512/1024/2048
/// block with 0xBE. Used to prove the Flutter decoder round-trips real packets.
String _encodeBitchatPrivateMessage(String content, String messageId) {
  final contentBytes = utf8.encode(content);
  final idBytes = utf8.encode(messageId);

  final tlv = <int>[];
  void pushTlv(int type, List<int> value) {
    if (value.length <= 0xFF) {
      tlv
        ..add(type)
        ..add(value.length);
    } else {
      tlv
        ..add(type | 0x80)
        ..add((value.length >> 8) & 0xFF)
        ..add(value.length & 0xFF);
    }
    tlv.addAll(value);
  }

  pushTlv(0x00, idBytes); // MESSAGE_ID
  pushTlv(0x01, contentBytes); // CONTENT

  final noisePayload = <int>[0x01, ...tlv]; // 0x01 = PRIVATE_MESSAGE

  final parts = <int>[];
  parts..add(0x01)..add(0x11)..add(0x07); // version, NOISE_ENCRYPTED, TTL
  final ts = DateTime.now().millisecondsSinceEpoch;
  for (var i = 7; i >= 0; i--) {
    parts.add((ts >> (i * 8)) & 0xFF);
  }
  parts.add(0x01); // flags: HAS_RECIPIENT
  parts..add((noisePayload.length >> 8) & 0xFF)..add(noisePayload.length & 0xFF);
  for (var i = 0; i < 8; i++) {
    parts.add(0x11); // sender id (arbitrary 8 bytes)
  }
  for (var i = 0; i < 8; i++) {
    parts.add(0x22); // recipient id (arbitrary 8 bytes)
  }
  parts.addAll(noisePayload);

  const blocks = [256, 512, 1024, 2048];
  final target = blocks.firstWhere((s) => s >= parts.length, orElse: () => 2048);
  while (parts.length < target) {
    parts.add(0xBE);
  }

  final b64 = base64
      .encode(Uint8List.fromList(parts))
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('=', '');
  return 'bitchat1:$b64';
}

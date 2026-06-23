import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/bech32_codec.dart' as b19;
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

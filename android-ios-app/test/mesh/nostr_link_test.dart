import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart'
    show generatePrivateKey, getPublicKeyHex, randomBytes;
import 'package:nym_bar/core/crypto/schnorr.dart' show signId;
import 'package:nym_bar/services/mesh/noise/nostr_link.dart';
import 'package:nym_bar/services/mesh/protocol/identity_announcement.dart';

void main() {
  group('NostrLink', () {
    late Uint8List priv;
    late String pubkey;
    late Uint8List noiseKey;

    setUp(() {
      priv = generatePrivateKey();
      pubkey = getPublicKeyHex(priv);
      noiseKey = randomBytes(32);
    });

    Uint8List buildLink() {
      final sig = signId(NostrLink.messageHex(noiseKey), priv);
      return NostrLink.build(pubkey, sig);
    }

    test('a valid link verifies and yields the Nostr pubkey', () {
      final link = buildLink();
      expect(link.length, NostrLink.length);
      expect(NostrLink.verify(link, noiseKey), pubkey);
    });

    test('verification fails when bound to a different Noise key', () {
      final link = buildLink();
      expect(NostrLink.verify(link, randomBytes(32)), isNull);
    });

    test('a tampered signature is rejected', () {
      final link = buildLink();
      link[NostrLink.length - 1] ^= 0xFF;
      expect(NostrLink.verify(link, noiseKey), isNull);
    });

    test('announcement carries the link through a TLV round-trip', () {
      final link = buildLink();
      final ann = IdentityAnnouncement(
        nickname: 'alice',
        noisePublicKey: noiseKey,
        signingPublicKey: randomBytes(32),
        nostrLink: link,
      );
      final decoded = IdentityAnnouncement.decode(ann.encode()!)!;
      expect(decoded.nostrLink, equals(link));
      expect(
          NostrLink.verify(decoded.nostrLink!, decoded.noisePublicKey), pubkey);
    });

    test('a bitchat-style announcement (no link) decodes with a null link', () {
      final ann = IdentityAnnouncement(
        nickname: 'bob',
        noisePublicKey: noiseKey,
        signingPublicKey: randomBytes(32),
      );
      final decoded = IdentityAnnouncement.decode(ann.encode()!)!;
      expect(decoded.nostrLink, isNull);
    });
  });
}

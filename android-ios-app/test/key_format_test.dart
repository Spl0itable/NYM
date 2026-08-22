// npub/hex and nsec/hex duality. The first test is the load-bearing one: the
// `#xxxx` identity suffix must keep coming from the HEX key, because npub's
// tail is a bech32 checksum and bitchat resolves people by the hex suffix.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/bech32_codec.dart';
import 'package:nym_bar/core/crypto/key_format.dart';
import 'package:nym_bar/core/crypto/keys.dart';

const _hex = '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d';

void main() {
  final npub = encodeNpub(_hex);

  test('npub does NOT share the hex suffix — the # tag stays hex-derived', () {
    expect(npub, 'npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6');
    expect(npub.substring(npub.length - 4), isNot(_hex.substring(_hex.length - 4)));
  });

  group('public key input', () {
    test('accepts hex in any case', () {
      expect(normalizePubkeyInput(_hex.toUpperCase()), _hex);
    });

    test('accepts npub', () {
      expect(normalizePubkeyInput(npub), _hex);
    });

    test('accepts a nostr: URI and a leading @', () {
      expect(normalizePubkeyInput('nostr:$npub'), _hex);
      expect(normalizePubkeyInput('@$npub'), _hex);
      expect(normalizePubkeyInput('  $npub  '), _hex);
    });

    test('rejects anything else', () {
      expect(normalizePubkeyInput('hello'), isNull);
      expect(normalizePubkeyInput('npub1zzzz'), isNull);
      expect(normalizePubkeyInput('bob#a1b2'), isNull);
      expect(normalizePubkeyInput(''), isNull);
      expect(normalizePubkeyInput(null), isNull);
      // one hex char short
      expect(normalizePubkeyInput(_hex.substring(1)), isNull);
    });

    test('isPubkeyInput agrees with the normaliser', () {
      expect(isPubkeyInput(npub), isTrue);
      expect(isPubkeyInput(_hex), isTrue);
      expect(isPubkeyInput('bob#a1b2'), isFalse);
    });
  });

  group('display', () {
    test('renders either form', () {
      expect(formatPubkeyForDisplay(_hex, PubkeyFormat.npub), npub);
      expect(formatPubkeyForDisplay(_hex, PubkeyFormat.hex), _hex);
    });

    test('an unencodable value passes through rather than throwing', () {
      expect(npubOrHex('not-a-key'), 'not-a-key');
    });
  });

  group('private key input', () {
    final skBytes = hexToBytes(_hex);
    final nsec = encodeNsecBytes(skBytes);

    test('accepts nsec and bare hex, and they agree', () {
      expect(normalizePrivkeyInput(nsec), skBytes);
      expect(normalizePrivkeyInput(_hex.toUpperCase()), skBytes);
    });

    test('both forms derive the same identity', () {
      expect(getPublicKeyHex(normalizePrivkeyInput(nsec)!),
          getPublicKeyHex(normalizePrivkeyInput(_hex)!));
    });

    test('rejects anything else', () {
      expect(normalizePrivkeyInput('nope'), isNull);
      expect(normalizePrivkeyInput('nsec1zzzz'), isNull);
      expect(normalizePrivkeyInput(npub), isNull); // a pubkey is not a privkey
      expect(normalizePrivkeyInput(''), isNull);
    });
  });

  group('nprofile', () {
    // The NIP-19 spec's own vector — the same pubkey as [_hex], wrapped in TLV
    // alongside two relay records the decoder has to skip past.
    const nprofile = 'nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd2'
        '4mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjl'
        'yr9p';

    test('an nprofile yields its pubkey', () {
      expect(decodeNprofilePubkey(nprofile), _hex);
      expect(normalizePubkeyInput(nprofile), _hex);
      expect(normalizePubkeyInput('nostr:$nprofile'), _hex);
    });

    test('a malformed nprofile is rejected, not thrown', () {
      expect(normalizePubkeyInput('nprofile1qqs'), isNull);
    });
  });
}

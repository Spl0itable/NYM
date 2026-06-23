import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/api.dart' show KeyParameter;

import 'keys.dart';

/// bitchat interop transport (matches the PWA `encryptBitchat`/`decryptBitchat`
/// in nym-crypto.js).
///
/// Layout: shared point = secp256k1.getSharedSecret(sk, '02'+recipientPub),
/// i.e. the **33-byte compressed** encoding of `sk * liftEven(recipientPub)`.
/// prk = HKDF-Extract(SHA256, ikm = sharedPoint(33), salt = empty);
/// key = HKDF-Expand(prk, info = utf8('nip44-v2'), 32);
/// XChaCha20-Poly1305 with a 24-byte random nonce;
/// output `v2:<base64url(nonce || ciphertext_with_tag)>`.

final _secp = ECCurve_secp256k1();
final _xchacha = Xchacha20.poly1305Aead();

Uint8List _hmacSha256(Uint8List key, Uint8List data) {
  final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
  return mac.process(data);
}

Uint8List _hkdfExtract(Uint8List salt, Uint8List ikm) =>
    _hmacSha256(salt, ikm);

Uint8List _hkdfExpand(Uint8List prk, Uint8List info, int length) {
  const hashLen = 32;
  final n = (length + hashLen - 1) ~/ hashLen;
  final okm = Uint8List(n * hashLen);
  var prev = Uint8List(0);
  var pos = 0;
  for (var i = 1; i <= n; i++) {
    final input = Uint8List(prev.length + info.length + 1)
      ..setRange(0, prev.length, prev)
      ..setRange(prev.length, prev.length + info.length, info)
      ..[prev.length + info.length] = i;
    prev = _hmacSha256(prk, input);
    okm.setRange(pos, pos + hashLen, prev);
    pos += hashLen;
  }
  return okm.sublist(0, length);
}

/// Returns the 33-byte compressed shared point: `sk * liftEven(pubkeyHex)`
/// where [parityPrefix] is '02' or '03' applied to the recipient pubkey before
/// lifting. nostr-tools/noble defaults to lifting with even y ('02').
Uint8List _sharedPointCompressed(
    Uint8List sk, String pubkeyHex, String parityPrefix) {
  final compressed = hexToBytes('$parityPrefix${pubkeyHex.padLeft(64, '0')}');
  final point = _secp.curve.decodePoint(compressed);
  if (point == null) {
    throw FormatException('Invalid public key: $pubkeyHex');
  }
  final d = _bytesToBigInt(sk);
  final shared = (point * d)!;
  // Encode result as compressed (33 bytes) — getEncoded(true).
  return Uint8List.fromList(shared.getEncoded(true));
}

Uint8List _deriveKey(Uint8List sharedPoint) {
  final prk = _hkdfExtract(Uint8List(0), sharedPoint);
  return _hkdfExpand(
    prk,
    Uint8List.fromList(utf8.encode('nip44-v2')),
    32,
  );
}

String _b64UrlNoPad(Uint8List bytes) {
  return base64.encode(bytes).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

Uint8List _b64UrlDecode(String s) {
  var t = s.replaceAll('-', '+').replaceAll('_', '/');
  while (t.length % 4 != 0) {
    t += '=';
  }
  return base64.decode(t);
}

/// Encrypts [plaintext] to [recipientPub] using [sk]. Returns a `v2:` payload.
Future<String> encryptBitchat(
    String plaintext, Uint8List sk, String recipientPub) async {
  final sharedPoint = _sharedPointCompressed(sk, recipientPub, '02');
  final key = _deriveKey(sharedPoint);
  final nonce = randomBytes(24);
  final secretBox = await _xchacha.encrypt(
    utf8.encode(plaintext),
    secretKey: SecretKey(key),
    nonce: nonce,
  );
  // concatenation() => nonce || cipherText || mac, matching JS nonce||ct(+tag).
  final payload = secretBox.concatenation();
  return 'v2:${_b64UrlNoPad(payload)}';
}

/// Decrypts a bitchat `v2:` payload from [senderPub] using [sk]. Tries both the
/// even ('02') and odd ('03') lift of the sender pubkey, matching the PWA.
Future<String> decryptBitchat(
    String content, String senderPub, Uint8List sk) async {
  var c = content;
  if (c.startsWith('v2:')) c = c.substring(3);
  final payload = _b64UrlDecode(c);
  if (payload.length < 24 + 16) {
    throw FormatException('bitchat payload too short');
  }
  final secretBox = SecretBox.fromConcatenation(
    payload,
    nonceLength: 24,
    macLength: 16,
  );
  for (final prefix in const ['02', '03']) {
    try {
      final sharedPoint = _sharedPointCompressed(sk, senderPub, prefix);
      final key = _deriveKey(sharedPoint);
      final clear = await _xchacha.decrypt(
        secretBox,
        secretKey: SecretKey(key),
      );
      return utf8.decode(clear);
    } catch (_) {
      // try next parity
    }
  }
  throw FormatException('bitchat decrypt failed');
}

BigInt _bytesToBigInt(Uint8List bytes) {
  var r = BigInt.zero;
  for (final b in bytes) {
    r = (r << 8) | BigInt.from(b);
  }
  return r;
}

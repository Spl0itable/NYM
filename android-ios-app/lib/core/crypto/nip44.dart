import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/stream/chacha7539.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;

import 'keys.dart';

/// NIP-44 v2 implementation (HKDF-SHA256 + ChaCha20 + HMAC-SHA256).
///
/// Wire format of a payload:
///   base64( 0x02 || nonce[32] || ciphertext || mac[32] )
/// where ciphertext = ChaCha20(plaintext padded with a 2-byte BE length
/// prefix), mac = HMAC-SHA256(hmac_key, aad = nonce || ciphertext).

final _secp = ECCurve_secp256k1();

// --- HMAC / HKDF primitives -------------------------------------------------

Uint8List _hmacSha256(Uint8List key, Uint8List data) {
  final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
  return mac.process(data);
}

/// HKDF-Extract(salt, ikm) -> PRK.
Uint8List _hkdfExtract(Uint8List salt, Uint8List ikm) =>
    _hmacSha256(salt, ikm);

/// HKDF-Expand(prk, info, length) -> OKM.
Uint8List _hkdfExpand(Uint8List prk, Uint8List info, int length) {
  final hashLen = 32;
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

// --- ECDH -------------------------------------------------------------------

/// secp256k1 ECDH on x-only pubkeys: lift [pubkeyHex] to the point with even
/// y, multiply by [privkey], and return the 32-byte big-endian x coordinate.
Uint8List _ecdhSharedX(Uint8List privkey, String pubkeyHex) {
  // Compressed, even-y encoding: 0x02 || x.
  final compressed = hexToBytes('02${pubkeyHex.padLeft(64, '0')}');
  final point = _secp.curve.decodePoint(compressed);
  if (point == null) {
    throw FormatException('Invalid public key: $pubkeyHex');
  }
  final d = _bytesToBigInt(privkey);
  final shared = (point * d)!;
  final x = shared.x!.toBigInteger()!;
  return _bigIntTo32(x);
}

/// Derives the NIP-44 v2 conversation key:
/// HKDF-Extract(salt="nip44-v2", ikm = ecdh_shared_x).
Uint8List getConversationKey(Uint8List privkey, String pubkeyHex) {
  final sharedX = _ecdhSharedX(privkey, pubkeyHex);
  return _hkdfExtract(
    Uint8List.fromList(utf8.encode('nip44-v2')),
    sharedX,
  );
}

// --- Per-message keys / padding ---------------------------------------------

({Uint8List chachaKey, Uint8List chachaNonce, Uint8List hmacKey})
    _messageKeys(Uint8List conversationKey, Uint8List nonce) {
  final keys = _hkdfExpand(conversationKey, nonce, 76);
  return (
    chachaKey: keys.sublist(0, 32),
    chachaNonce: keys.sublist(32, 44),
    hmacKey: keys.sublist(44, 76),
  );
}

int _calcPaddedLen(int unpadded) {
  if (unpadded <= 0) {
    throw ArgumentError('plaintext too short');
  }
  if (unpadded <= 32) return 32;
  final nextPower = 1 << (_bitLength(unpadded - 1));
  final chunk = nextPower <= 256 ? 32 : nextPower ~/ 8;
  return chunk * (((unpadded - 1) ~/ chunk) + 1);
}

int _bitLength(int v) {
  var n = 0;
  while (v > 0) {
    v >>= 1;
    n++;
  }
  return n;
}

Uint8List _pad(String plaintext) {
  final bytes = Uint8List.fromList(utf8.encode(plaintext));
  final len = bytes.length;
  if (len < 1 || len > 65535) {
    throw ArgumentError('invalid plaintext length: $len');
  }
  final paddedLen = _calcPaddedLen(len);
  final out = Uint8List(2 + paddedLen);
  out[0] = (len >> 8) & 0xff;
  out[1] = len & 0xff;
  out.setRange(2, 2 + len, bytes);
  return out;
}

String _unpad(Uint8List padded) {
  if (padded.length < 2) throw FormatException('invalid padding');
  final unpaddedLen = (padded[0] << 8) | padded[1];
  final unpadded = padded.sublist(2, 2 + unpaddedLen);
  if (unpaddedLen == 0 ||
      unpadded.length != unpaddedLen ||
      padded.length != 2 + _calcPaddedLen(unpaddedLen)) {
    throw FormatException('invalid padding');
  }
  return utf8.decode(unpadded);
}

// --- ChaCha20 (RFC 7539, 12-byte nonce) -------------------------------------

Uint8List _chacha20(Uint8List key, Uint8List nonce12, Uint8List data) {
  final cipher = ChaCha7539Engine()
    ..init(true, ParametersWithIV(KeyParameter(key), nonce12));
  return cipher.process(data);
}

// --- Public encrypt/decrypt -------------------------------------------------

/// Encrypts [plaintext] under [conversationKey]. A random 32-byte nonce is
/// generated unless [nonce] is supplied (used for test vectors).
String encrypt(String plaintext, Uint8List conversationKey,
    {Uint8List? nonce}) {
  final n = nonce ?? randomBytes(32);
  if (n.length != 32) throw ArgumentError('nonce must be 32 bytes');
  final mk = _messageKeys(conversationKey, n);
  final padded = _pad(plaintext);
  final ciphertext = _chacha20(mk.chachaKey, mk.chachaNonce, padded);
  final aad = Uint8List(n.length + ciphertext.length)
    ..setRange(0, n.length, n)
    ..setRange(n.length, n.length + ciphertext.length, ciphertext);
  final mac = _hmacSha256(mk.hmacKey, aad);
  final payload = Uint8List(1 + 32 + ciphertext.length + 32);
  payload[0] = 0x02;
  payload.setRange(1, 33, n);
  payload.setRange(33, 33 + ciphertext.length, ciphertext);
  payload.setRange(33 + ciphertext.length, payload.length, mac);
  return base64.encode(payload);
}

/// Decrypts a NIP-44 v2 [payload] under [conversationKey]. Throws on a bad
/// version byte, malformed length, or MAC mismatch.
String decrypt(String payload, Uint8List conversationKey) {
  if (payload.isNotEmpty && payload[0] == '#') {
    throw FormatException('unsupported version');
  }
  final data = base64.decode(payload);
  if (data.isEmpty || data[0] != 0x02) {
    throw FormatException('unknown version ${data.isEmpty ? '?' : data[0]}');
  }
  if (data.length < 1 + 32 + 32 + 32) {
    throw FormatException('payload too short');
  }
  final nonce = Uint8List.fromList(data.sublist(1, 33));
  final mac = data.sublist(data.length - 32);
  final ciphertext =
      Uint8List.fromList(data.sublist(33, data.length - 32));
  final mk = _messageKeys(conversationKey, nonce);
  final aad = Uint8List(nonce.length + ciphertext.length)
    ..setRange(0, nonce.length, nonce)
    ..setRange(nonce.length, nonce.length + ciphertext.length, ciphertext);
  final calcMac = _hmacSha256(mk.hmacKey, aad);
  if (!_constantTimeEquals(calcMac, mac)) {
    throw FormatException('invalid MAC');
  }
  final padded = _chacha20(mk.chachaKey, mk.chachaNonce, ciphertext);
  return _unpad(padded);
}

// --- helpers ----------------------------------------------------------------

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

BigInt _bytesToBigInt(Uint8List bytes) {
  var r = BigInt.zero;
  for (final b in bytes) {
    r = (r << 8) | BigInt.from(b);
  }
  return r;
}

Uint8List _bigIntTo32(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  for (var i = 31; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  return out;
}

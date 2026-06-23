import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:convert/convert.dart' as convert;

/// secp256k1 curve order (n). A valid private key scalar is in [1, n-1].
final BigInt _secpN = BigInt.parse(
  'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
  radix: 16,
);

final Random _rng = Random.secure();

/// Encodes [bytes] as a lowercase hex string.
String bytesToHex(List<int> bytes) => convert.hex.encode(bytes);

/// Decodes a hex string into bytes. Accepts upper or lower case.
Uint8List hexToBytes(String hexStr) {
  var s = hexStr;
  if (s.length.isOdd) s = '0$s';
  return Uint8List.fromList(convert.hex.decode(s));
}

/// Returns 32 cryptographically-random bytes.
Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

/// Generates a valid secp256k1 private key (32 random bytes that form a
/// scalar in [1, n-1]).
Uint8List generatePrivateKey() {
  while (true) {
    final candidate = randomBytes(32);
    final d = _bytesToBigInt(candidate);
    if (d >= BigInt.one && d < _secpN) return candidate;
  }
}

/// Derives the 32-byte x-only (BIP340) public key for [privkey] and returns
/// it as 64-char lowercase hex.
String getPublicKeyHex(Uint8List privkey) {
  return bip340.getPublicKey(bytesToHex(privkey));
}

BigInt _bytesToBigInt(Uint8List bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

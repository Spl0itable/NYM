import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:convert/convert.dart' as convert;

import 'native_schnorr.dart';

/// secp256k1 curve order n; a valid private key is in [1, n-1].
final BigInt _secpN = BigInt.parse(
  'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
  radix: 16,
);

final Random _rng = Random.secure();

String bytesToHex(List<int> bytes) => convert.hex.encode(bytes);

Uint8List hexToBytes(String hexStr) {
  var s = hexStr;
  if (s.length.isOdd) s = '0$s';
  return Uint8List.fromList(convert.hex.decode(s));
}

Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

/// Generates a valid secp256k1 private key.
Uint8List generatePrivateKey() {
  while (true) {
    final candidate = randomBytes(32);
    final d = _bytesToBigInt(candidate);
    if (d >= BigInt.one && d < _secpN) return candidate;
  }
}

/// Returns the x-only (BIP340) public key hex, using native libsecp256k1 when loaded in this isolate.
String getPublicKeyHex(Uint8List privkey) {
  final native = NativeSchnorr.xOnlyPubkeyHex(privkey);
  if (native != null) return native;
  return bip340.getPublicKey(bytesToHex(privkey));
}

BigInt _bytesToBigInt(Uint8List bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

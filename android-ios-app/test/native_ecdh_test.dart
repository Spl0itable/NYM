// Native libsecp256k1 ECDH (core/crypto/native_ecdh.dart): the raw-X
// binding NIP-44 routes through when the shared library is present
// (build/libsecp256k1.so on the host — same skip policy as
// native_schnorr_test.dart: without it every call site falls back to the
// pure-Dart pointycastle path, which the NIP-44 official vectors in
// crypto_test.dart cover).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

import 'package:nym_bar/core/crypto/keys.dart' as keys;
import 'package:nym_bar/core/crypto/native_ecdh.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;

/// The pure-Dart multiply native_ecdh replaces, reimplemented here so the two
/// can be compared even after the native library has loaded (once loaded,
/// nip44.ecdhSharedX always prefers it).
Uint8List _pureDartSharedX(Uint8List privkey, String pubkeyHex) {
  final secp = ECCurve_secp256k1();
  final point =
      secp.curve.decodePoint(keys.hexToBytes('02${pubkeyHex.padLeft(64, '0')}'))!;
  var d = BigInt.zero;
  for (final b in privkey) {
    d = (d << 8) | BigInt.from(b);
  }
  final x = (point * d)!.x!.toBigInteger()!;
  final out = Uint8List(32);
  var v = x;
  for (var i = 31; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

void main() {
  // Loading is lazy: the first sharedX call attempts it.
  final probe = NativeEcdh.sharedX(
    privkey: Uint8List.fromList(List.filled(31, 0) + [1]), // sk = 1
    pubkeyHex:
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798', // G.x
  );
  final native = probe != null;

  test('native library loads on the host (build/libsecp256k1.so)', () {
    if (!native) {
      markTestSkipped('libsecp256k1 not available — pure-Dart fallback path '
          'is in use (build it into build/libsecp256k1.so to exercise native '
          'ECDH here)');
      return;
    }
    expect(NativeEcdh.isAvailable, isTrue);
    // sk=1 · G has shared X = G.x itself.
    expect(
      keys.bytesToHex(probe),
      '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
    );
  });

  test('native ECDH agrees with the pure-Dart multiply on random keys', () {
    if (!native) {
      markTestSkipped('libsecp256k1 not available');
      return;
    }
    for (var i = 0; i < 10; i++) {
      final sk = keys.generatePrivateKey();
      final pk = keys.getPublicKeyHex(keys.generatePrivateKey());
      final nativeX = NativeEcdh.sharedX(privkey: sk, pubkeyHex: pk)!;
      expect(keys.bytesToHex(nativeX), keys.bytesToHex(_pureDartSharedX(sk, pk)));
      // And the routed entry point (native when loaded) matches too.
      expect(keys.bytesToHex(nip44.ecdhSharedX(sk, pk)),
          keys.bytesToHex(nativeX));
    }
  });

  test('ECDH is symmetric through getConversationKey (native path)', () {
    if (!native) {
      markTestSkipped('libsecp256k1 not available');
      return;
    }
    final skA = keys.generatePrivateKey();
    final skB = keys.generatePrivateKey();
    final pkA = keys.getPublicKeyHex(skA);
    final pkB = keys.getPublicKeyHex(skB);
    expect(
      keys.bytesToHex(nip44.getConversationKey(skA, pkB)),
      keys.bytesToHex(nip44.getConversationKey(skB, pkA)),
    );
  });

  test('invalid inputs throw (matching the pure-Dart path), not crash', () {
    if (!native) {
      markTestSkipped('libsecp256k1 not available');
      return;
    }
    // An x with no curve point (p-1 is a quadratic non-residue case; use an
    // obviously invalid all-ff x).
    expect(
      () => NativeEcdh.sharedX(
        privkey: keys.generatePrivateKey(),
        pubkeyHex: 'f' * 64,
      ),
      throwsFormatException,
    );
    expect(
      () => NativeEcdh.sharedX(
        privkey: Uint8List(31),
        pubkeyHex:
            '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
      ),
      throwsFormatException,
    );
    // A zero seckey is rejected by libsecp256k1 (returns 0 → throws).
    expect(
      () => NativeEcdh.sharedX(
        privkey: Uint8List(32),
        pubkeyHex:
            '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
      ),
      throwsFormatException,
    );
  });

  test('native vs pure-Dart ECDH throughput (informational)', () {
    if (!native) {
      markTestSkipped('libsecp256k1 not available');
      return;
    }
    const n = 50;
    final sks = [for (var i = 0; i < n; i++) keys.generatePrivateKey()];
    final pk = keys.getPublicKeyHex(keys.generatePrivateKey());
    final sw = Stopwatch()..start();
    for (final sk in sks) {
      NativeEcdh.sharedX(privkey: sk, pubkeyHex: pk);
    }
    sw.stop();
    // ignore: avoid_print
    print('NATIVE ECDH: $n ops in ${sw.elapsedMilliseconds}ms '
        '=> ${(sw.elapsedMicroseconds / n).toStringAsFixed(0)} us/op');
    // Must beat the ~15 ms/op pure-Dart baseline by a wide margin.
    expect(sw.elapsedMicroseconds / n < 5000, isTrue);
  });
}

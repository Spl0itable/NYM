// Native secp256k1 ECDH (raw shared-point X) for NIP-44, with graceful
// absence.
//
// The CPU profile of a live session showed pure-Dart EC point multiplication
// (`pointycastle`'s `_wNafMultiplier` inside `_ecdhSharedX`) as the single
// largest main-isolate cost — ~15 ms of BigInt math per ECDH, several ECDH
// per gift wrap / settings-sync publish, all landing between frames. The
// libsecp256k1 shared library that `coinlib_flutter` already bundles does the
// same multiply in ~50 µs, but coinlib's own `ecdh()` API returns
// SHA256(compressed point) — the BIP-standard KDF — while NIP-44 needs the
// RAW 32-byte X coordinate. So this binds `secp256k1_ecdh` directly with a
// custom hash callback that copies X through unhashed.
//
// Like [NativeSchnorr], state is per-isolate and every failure mode resolves
// to "unavailable": callers fall back to the pure-Dart path (notably web,
// where there is no dart:ffi — the stub keeps this file importable there).

import 'dart:typed_data';

import 'native_ecdh_stub.dart'
    if (dart.library.ffi) 'native_ecdh_ffi.dart' as impl;

class NativeEcdh {
  NativeEcdh._();

  /// Whether the native library is loaded in THIS isolate (loading is lazy —
  /// this is false until the first [sharedX] call attempts it).
  static bool get isAvailable => impl.isAvailable;

  /// secp256k1 ECDH on an x-only pubkey: lifts [pubkeyHex] to the even-y
  /// point, multiplies by [privkey], and returns the raw 32-byte big-endian X
  /// coordinate of the shared point — NIP-44's `ecdh_shared_x`.
  ///
  /// Returns null when the native library is unavailable in this isolate (the
  /// caller runs the pure-Dart path instead). Throws [FormatException] when
  /// the library IS available but the inputs are invalid (a pubkey not on the
  /// curve, a zero/overflowing seckey) — the same inputs make the pure-Dart
  /// path throw too, so the two paths agree on every verdict.
  static Uint8List? sharedX({
    required Uint8List privkey,
    required String pubkeyHex,
  }) =>
      impl.sharedX(privkey: privkey, pubkeyHex: pubkeyHex);
}

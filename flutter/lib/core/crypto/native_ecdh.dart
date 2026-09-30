// Native secp256k1 ECDH returning the raw shared X NIP-44 needs; unavailable means pure-Dart fallback.

import 'dart:typed_data';

import 'native_ecdh_stub.dart'
    if (dart.library.ffi) 'native_ecdh_ffi.dart' as impl;

class NativeEcdh {
  NativeEcdh._();

  /// Whether the native library loaded in this isolate; false until the first [sharedX] call.
  static bool get isAvailable => impl.isAvailable;

  /// NIP-44 `ecdh_shared_x`, or null when native is unavailable; throws [FormatException] on invalid inputs.
  static Uint8List? sharedX({
    required Uint8List privkey,
    required String pubkeyHex,
  }) =>
      impl.sharedX(privkey: privkey, pubkeyHex: pubkeyHex);
}

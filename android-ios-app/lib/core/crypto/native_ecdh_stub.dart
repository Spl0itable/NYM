// Web / no-FFI stand-in for native_ecdh_ffi.dart: the native library can
// never load, so [sharedX] always defers to the caller's pure-Dart fallback.

import 'dart:typed_data';

bool get isAvailable => false;

Uint8List? sharedX({
  required Uint8List privkey,
  required String pubkeyHex,
}) =>
    null;

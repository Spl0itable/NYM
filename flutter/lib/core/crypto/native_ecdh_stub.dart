// No-FFI stand-in: the native library never loads, so [sharedX] always defers to the Dart fallback.

import 'dart:typed_data';

bool get isAvailable => false;

Uint8List? sharedX({
  required Uint8List privkey,
  required String pubkeyHex,
}) =>
    null;

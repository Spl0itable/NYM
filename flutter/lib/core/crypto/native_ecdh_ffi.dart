// FFI binding of `secp256k1_ecdh` with a hash callback returning raw X, since NIP-44 hashes X itself.

import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'keys.dart';

typedef _CtxCreateN = Pointer<Void> Function(UnsignedInt flags);
typedef _CtxCreateD = Pointer<Void> Function(int flags);
typedef _RandomizeN = Int32 Function(Pointer<Void> ctx, Pointer<Uint8> seed32);
typedef _RandomizeD = int Function(Pointer<Void> ctx, Pointer<Uint8> seed32);
typedef _PubkeyParseN = Int32 Function(Pointer<Void> ctx, Pointer<Uint8> out,
    Pointer<Uint8> input, Size inputLen);
typedef _PubkeyParseD = int Function(
    Pointer<Void> ctx, Pointer<Uint8> out, Pointer<Uint8> input, int inputLen);

/// `secp256k1_ecdh_hash_function`: writes the KDF of (x32, y32) into output.
typedef _HashFnN = Int32 Function(Pointer<Uint8> output, Pointer<Uint8> x32,
    Pointer<Uint8> y32, Pointer<Void> data);
typedef _EcdhN = Int32 Function(
    Pointer<Void> ctx,
    Pointer<Uint8> output,
    Pointer<Uint8> pubkey,
    Pointer<Uint8> seckey,
    Pointer<NativeFunction<_HashFnN>> hashfp,
    Pointer<Void> data);
typedef _EcdhD = int Function(
    Pointer<Void> ctx,
    Pointer<Uint8> output,
    Pointer<Uint8> pubkey,
    Pointer<Uint8> seckey,
    Pointer<NativeFunction<_HashFnN>> hashfp,
    Pointer<Void> data);

/// Copies the shared X through unhashed; static for [Pointer.fromFunction]; returns 1.
int _copyX(Pointer<Uint8> output, Pointer<Uint8> x32, Pointer<Uint8> y32,
    Pointer<Void> data) {
  for (var i = 0; i < 32; i++) {
    output[i] = x32[i];
  }
  return 1;
}

class _Lib {
  _Lib(DynamicLibrary lib)
      : ecdh = lib.lookupFunction<_EcdhN, _EcdhD>('secp256k1_ecdh'),
        pubkeyParse = lib.lookupFunction<_PubkeyParseN, _PubkeyParseD>(
            'secp256k1_ec_pubkey_parse') {
    final create = lib
        .lookupFunction<_CtxCreateN, _CtxCreateD>('secp256k1_context_create');
    // SECP256K1_CONTEXT_NONE: ecdh/parse need no precomputed tables.
    ctx = create(1);
    // Best-effort blinding, as coinlib does.
    try {
      final randomize = lib.lookupFunction<_RandomizeN, _RandomizeD>(
          'secp256k1_context_randomize');
      final rnd = Random.secure();
      for (var i = 0; i < 32; i++) {
        seed32[i] = rnd.nextInt(256);
      }
      randomize(ctx, seed32);
      for (var i = 0; i < 32; i++) {
        seed32[i] = 0;
      }
    } catch (_) {
      // An unrandomized context still computes correct ECDH.
    }
  }

  late final Pointer<Void> ctx;
  final _EcdhD ecdh;
  final _PubkeyParseD pubkeyParse;

  // Shared scratch buffers are safe: calls are synchronous on a single-threaded isolate.
  final Pointer<Uint8> seed32 = calloc<Uint8>(32);
  final Pointer<Uint8> seckey = calloc<Uint8>(32);
  final Pointer<Uint8> compressed = calloc<Uint8>(33);
  final Pointer<Uint8> pubkey = calloc<Uint8>(64); // Opaque secp256k1_pubkey.
  final Pointer<Uint8> output = calloc<Uint8>(32);
}

/// Null until the once-per-isolate load is attempted.
_Lib? _lib;
bool _loadFailed = false;

final Pointer<NativeFunction<_HashFnN>> _copyXPtr =
    Pointer.fromFunction<_HashFnN>(_copyX, 0);

String _libraryPath() {
  // Mirrors coinlib's secp256k1_io.dart so both bindings load the same library file.
  const name = 'secp256k1';
  final String localLib, flutterLib;
  if (Platform.isLinux || Platform.isAndroid) {
    flutterLib = localLib = 'lib$name.so';
  } else if (Platform.isMacOS || Platform.isIOS) {
    localLib = 'lib$name.dylib';
    flutterLib = '$name.framework/$name';
  } else if (Platform.isWindows) {
    flutterLib = localLib = '$name.dll';
  } else {
    throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
  }
  final buildPath =
      '${Directory.current.path}${Platform.pathSeparator}build${Platform.pathSeparator}$localLib';
  if (File(buildPath).existsSync()) return buildPath;
  return flutterLib;
}

_Lib? _ensure() {
  if (_loadFailed) return null;
  final lib = _lib;
  if (lib != null) return lib;
  try {
    return _lib = _Lib(DynamicLibrary.open(_libraryPath()));
  } catch (_) {
    _loadFailed = true;
    return null;
  }
}

bool get isAvailable => _lib != null;

Uint8List? sharedX({
  required Uint8List privkey,
  required String pubkeyHex,
}) {
  final lib = _ensure();
  if (lib == null) return null;
  if (privkey.length != 32) {
    throw FormatException('Invalid private key length: ${privkey.length}');
  }
  // Lift the x-only pubkey to the even-y point: 0x02 || x.
  final xBytes = hexToBytes(pubkeyHex.padLeft(64, '0'));
  if (xBytes.length != 32) {
    throw FormatException('Invalid public key: $pubkeyHex');
  }
  lib.compressed[0] = 0x02;
  for (var i = 0; i < 32; i++) {
    lib.compressed[i + 1] = xBytes[i];
    lib.seckey[i] = privkey[i];
  }
  try {
    if (lib.pubkeyParse(lib.ctx, lib.pubkey, lib.compressed, 33) != 1) {
      throw FormatException('Invalid public key: $pubkeyHex');
    }
    if (lib.ecdh(
            lib.ctx, lib.output, lib.pubkey, lib.seckey, _copyXPtr, nullptr) !=
        1) {
      throw const FormatException('ECDH failed (invalid private key?)');
    }
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = lib.output[i];
    }
    return out;
  } finally {
    // Never leave key material in the native heap.
    for (var i = 0; i < 32; i++) {
      lib.seckey[i] = 0;
      lib.output[i] = 0;
    }
  }
}

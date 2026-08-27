// dart:ffi implementation behind native_ecdh.dart — see that file for the
// why. Binds `secp256k1_ecdh` from the SAME shared library coinlib loads
// (bundled per platform by coinlib_flutter; `build/libsecp256k1.so` for the
// host test runner), with a custom hash callback that returns the raw shared
// X instead of libsecp256k1's default SHA256(point) — NIP-44 hashes the X
// itself (HKDF-Extract with the "nip44-v2" salt), so the default would
// double-hash and derive the wrong conversation key.

import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'keys.dart';

// --- libsecp256k1 signatures -------------------------------------------------

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

/// The NIP-44 "KDF": copy the shared X through unhashed. Static so it can
/// cross the FFI boundary via [Pointer.fromFunction]; libsecp256k1 calls it
/// synchronously on this isolate's thread. Returns 1 = success.
int _copyX(Pointer<Uint8> output, Pointer<Uint8> x32, Pointer<Uint8> y32,
    Pointer<Void> data) {
  for (var i = 0; i < 32; i++) {
    output[i] = x32[i];
  }
  return 1;
}

// --- lazy per-isolate load ---------------------------------------------------

class _Lib {
  _Lib(DynamicLibrary lib)
      : ecdh = lib.lookupFunction<_EcdhN, _EcdhD>('secp256k1_ecdh'),
        pubkeyParse = lib.lookupFunction<_PubkeyParseN, _PubkeyParseD>(
            'secp256k1_ec_pubkey_parse') {
    final create = lib
        .lookupFunction<_CtxCreateN, _CtxCreateD>('secp256k1_context_create');
    // SECP256K1_CONTEXT_NONE — ecdh/parse need no precomputed tables.
    ctx = create(1);
    // Blind the context like coinlib does its own; best-effort (ECDH's
    // ecmult_const doesn't strictly need it, but it's one cheap call).
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
      // Unrandomized context still computes correct ECDH.
    }
  }

  late final Pointer<Void> ctx;
  final _EcdhD ecdh;
  final _PubkeyParseD pubkeyParse;

  // One set of scratch buffers per isolate: calls are synchronous and a Dart
  // isolate is single-threaded, so they can never be in use twice at once.
  final Pointer<Uint8> seed32 = calloc<Uint8>(32);
  final Pointer<Uint8> seckey = calloc<Uint8>(32);
  final Pointer<Uint8> compressed = calloc<Uint8>(33);
  final Pointer<Uint8> pubkey = calloc<Uint8>(64); // opaque secp256k1_pubkey
  final Pointer<Uint8> output = calloc<Uint8>(32);
}

/// null = not attempted; the load runs once per isolate on first use (dlopen
/// of an already-resident library is a refcount bump, so this is cheap even
/// though coinlib opened the same file).
_Lib? _lib;
bool _loadFailed = false;

final Pointer<NativeFunction<_HashFnN>> _copyXPtr =
    Pointer.fromFunction<_HashFnN>(_copyX, 0);

String _libraryPath() {
  // Mirrors coinlib's secp256k1_io.dart so both bindings resolve the SAME
  // library file on every platform.
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
  // Lift the x-only pubkey to the even-y point: compressed 0x02 || x.
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
    // Never leave key material sitting in the native heap.
    for (var i = 0; i < 32; i++) {
      lib.seckey[i] = 0;
      lib.output[i] = 0;
    }
  }
}

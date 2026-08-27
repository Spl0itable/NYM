// Native libsecp256k1 BIP340 verification (via coinlib), with graceful
// absence.
//
// Pure-Dart `bip340.verify` measures ~12 ms per event; libsecp256k1 does the
// same check in well under 100 µs. For the boot/resume replay of a heavy
// account — thousands of stored events re-verified — that difference is the
// gap between seconds of pegged CPU and an imperceptible blip, so
// verification prefers the native path wherever the shared library is
// available (bundled for Android/iOS/desktop by `coinlib_flutter`; a
// `build/libsecp256k1.so` covers the host test runner) and falls back to the
// existing pure-Dart implementation everywhere else (notably web, and any
// platform where the library fails to load).
//
// State is PER-ISOLATE (statics don't cross isolate boundaries): the batch
// verifier's `compute` isolate loads the library itself before its loop —
// see `verifyEventsBatch` — and the main isolate loads during controller
// init for the few inline verify call sites.

import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:flutter/foundation.dart' show kIsWeb;

import 'keys.dart';

class NativeSchnorr {
  NativeSchnorr._();

  /// null = not attempted yet in this isolate; true/false = load outcome.
  static bool? _available;
  static Future<bool>? _loading;

  /// Whether native verification is usable RIGHT NOW in this isolate.
  static bool get isAvailable => _available ?? false;

  /// Attempts to load libsecp256k1 once per isolate; resolves to whether the
  /// native path is usable. Never throws. On web the pure-Dart path is kept
  /// (the WASM build is untested for this app), so this resolves false there.
  static Future<bool> ensureLoaded() {
    final known = _available;
    if (known != null) return Future<bool>.value(known);
    if (kIsWeb) return Future<bool>.value(_available = false);
    return _loading ??= coinlib
        .loadCoinlib()
        .then<bool>((_) => _available = true)
        .catchError((Object _) => _available = false);
  }

  /// Signs the 32-byte [idHex] with [privkey] natively (BIP340, deterministic
  /// — libsecp256k1 self-verifies the result before returning). Returns the
  /// 128-char hex signature, or null when the native library isn't loaded in
  /// this isolate or signing failed — the caller falls back to pure-Dart
  /// bip340. Pure-Dart signing is ~10–20 ms of BigInt math; the CPU profile
  /// showed it landing on the MAIN isolate for every outgoing event (sends,
  /// receipts, presence), which is scroll-time jank. Native is ~50 µs.
  static String? sign({
    required Uint8List privkey,
    required String idHex,
  }) {
    if (!isAvailable) return null;
    try {
      final sig = coinlib.SchnorrSignature.sign(
        coinlib.ECPrivateKey(privkey),
        Uint8List.fromList(hexToBytes(idHex)),
      );
      return bytesToHex(sig.data);
    } catch (_) {
      return null;
    }
  }

  /// Derives the x-only (BIP340) public key for [privkey] natively, as
  /// 64-char lowercase hex. Returns null when the library isn't loaded in
  /// this isolate or the key is invalid — the caller falls back to the
  /// pure-Dart derivation. Pure-Dart `getPublicKey` is ~10 ms of BigInt
  /// point math and the CPU profile showed it as the top main-isolate cost
  /// once ECDH went native — every ephemeral gift-wrap key pays it.
  static String? xOnlyPubkeyHex(Uint8List privkey) {
    if (!isAvailable) return null;
    try {
      return coinlib.ECPrivateKey(privkey).pubkey.xhex;
    } catch (_) {
      return null;
    }
  }

  /// Verifies a BIP340 signature natively. Call only when [isAvailable];
  /// returns false on any malformed input or verify failure.
  static bool verify({
    required String pubkeyHex,
    required String idHex,
    required String sigHex,
  }) {
    try {
      final sig = coinlib.SchnorrSignature(hexToBytes(sigHex));
      final pubkey = coinlib.ECPublicKey.fromXOnlyHex(pubkeyHex);
      return sig.verify(pubkey, Uint8List.fromList(hexToBytes(idHex)));
    } catch (_) {
      return false;
    }
  }
}

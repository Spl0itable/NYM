// Native libsecp256k1 BIP340 via coinlib, with a pure-Dart fallback; loaded state is per isolate.

import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' as coinlib;
import 'package:flutter/foundation.dart' show kIsWeb;

import 'keys.dart';

class NativeSchnorr {
  NativeSchnorr._();

  /// Null until attempted in this isolate; then the load outcome.
  static bool? _available;
  static Future<bool>? _loading;

  static bool get isAvailable => _available ?? false;

  /// Loads libsecp256k1 once per isolate and never throws; always false on web.
  static Future<bool> ensureLoaded() {
    final known = _available;
    if (known != null) return Future<bool>.value(known);
    if (kIsWeb) return Future<bool>.value(_available = false);
    return _loading ??= Future<void>(() => coinlib.loadCoinlib())
        .then<bool>((_) => _available = true)
        .catchError((Object _) => _available = false);
  }

  /// Deterministic native BIP340 signature hex, or null when unavailable so the caller uses pure Dart.
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

  /// Native x-only pubkey hex, or null when unavailable or the key is invalid.
  static String? xOnlyPubkeyHex(Uint8List privkey) {
    if (!isAvailable) return null;
    try {
      return coinlib.ECPrivateKey(privkey).pubkey.xhex;
    } catch (_) {
      return null;
    }
  }

  /// Call only when [isAvailable]; false on malformed input or verify failure.
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

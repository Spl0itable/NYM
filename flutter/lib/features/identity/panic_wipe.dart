import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/storage/at_rest_cipher.dart';
import '../../services/storage/cache_store.dart';
import '../../services/storage/mesh_file_store.dart';
import '../../services/storage/secure_store.dart';
import 'biometric_secret_store.dart';
import 'panic_purge.dart';

/// Store abstractions so tests can inject fakes and assert they were cleared.
abstract class PanicPrefsStore {
  Future<void> wipe();
}

abstract class PanicSecureStore {
  Future<void> wipe();
}

abstract class PanicCacheStore {
  Future<void> wipe();
}

abstract class PanicFileStore {
  Future<void> wipe();
}

class _SharedPrefsAdapter implements PanicPrefsStore {
  @override
  Future<void> wipe() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().toList();
    final rng = Random.secure();
    // Encrypt every value under a discarded AES-GCM-256 key so any surviving bytes are unrecoverable.
    try {
      final algo = AesGcm.with256bits();
      final key = await algo.newSecretKey();
      for (final k in keys) {
        try {
          final v = prefs.get(k);
          if (v == null) continue;
          final box = await algo.encrypt(
            utf8.encode(v.toString()),
            secretKey: key,
          );
          await prefs.setString(
            k,
            'panic:${base64.encode([
                  ...box.nonce,
                  ...box.cipherText,
                  ...box.mac.bytes
                ])}',
          );
        } catch (_) {}
      }
    } catch (_) {}
    // Junk-overwrite, then clear.
    for (final k in keys) {
      try {
        await prefs.setString(k, _junk(rng));
      } catch (_) {}
    }
    await prefs.clear();
  }
}

class _SecureStoreAdapter implements PanicSecureStore {
  _SecureStoreAdapter(this._store);
  final SecureStore _store;
  @override
  Future<void> wipe() async {
    try {
      await PlatformBiometricSecretStore().delete();
    } catch (_) {}
    await _store.wipeAll();
  }
}

class _AtRestFilesAdapter implements PanicFileStore {
  _AtRestFilesAdapter(this._files, this._cipher);
  final MeshFileStore _files;
  final AtRestCipher _cipher;
  @override
  Future<void> wipe() async {
    try {
      await _files.wipe();
    } catch (_) {}
    await _cipher.destroyKey();
  }
}

class _CacheStoreAdapter implements PanicCacheStore {
  _CacheStoreAdapter(this._store);
  final CacheStore _store;
  @override
  Future<void> wipe() async {
    // Overwrite and clear every store, then delete the DB file; the open is isolated so a corrupt DB still gets deleted.
    try {
      if (!_store.isOpen) await _store.open();
    } catch (_) {}
    try {
      await _store.panicWipe();
    } catch (_) {}
    try {
      await CacheStore.deleteAllAccountFiles();
    } catch (_) {}
  }
}

String _junk(Random rng) {
  final b = List<int>.generate(256, (_) => rng.nextInt(256));
  return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

class PanicWipeReport {
  const PanicWipeReport({this.unremoved = 0});

  final int unremoved;
}

/// Emergency wipe of prefs, secure storage and the sqflite cache DB; the caller handles restart-to-first-run.
class PanicWipe {
  PanicWipe({
    required this._prefs,
    required this._secure,
    required this._cache,
    this._files,
    this._purge,
    this._purgeBudget = defaultPurgeBudget,
  });

  factory PanicWipe.production({
    SecureStore? secure,
    CacheStore? cache,
    PanicIdentityPurge? purge,
    Duration purgeBudget = defaultPurgeBudget,
  }) =>
      PanicWipe(
        prefs: _SharedPrefsAdapter(),
        secure: _SecureStoreAdapter(secure ?? SecureStore()),
        cache: _CacheStoreAdapter(cache ?? CacheStore()),
        files: _AtRestFilesAdapter(
            MeshFileStore.instance, AtRestCipher.instance),
        purge: purge,
        purgeBudget: purgeBudget,
      );

  static const Duration defaultPurgeBudget = Duration(seconds: 3);

  final PanicPrefsStore _prefs;
  final PanicSecureStore _secure;
  final PanicCacheStore _cache;
  final PanicFileStore? _files;
  final PanicIdentityPurge? _purge;
  final Duration _purgeBudget;

  /// True while a wipe runs; persistence paths check it and refuse to write so nothing re-writes data mid-wipe.
  static bool inProgress = false;

  /// Destroys every local store, each step isolated so one failure can't abort the others.
  Future<PanicWipeReport> wipe({void Function(String status)? onStatus}) async {
    // Stop persistence before destroying anything.
    inProgress = true;
    final clock = Stopwatch()..start();
    Duration left() {
      final rest = _purgeBudget - clock.elapsed;
      return rest.isNegative ? Duration.zero : rest;
    }

    final purge = _purge;
    List<Future<bool>>? pending;
    if (purge != null) {
      try {
        pending = await purge.start().timeout(left());
      } catch (_) {}
    }
    // Order: key/value store, then the local database, then the secure keystore last.
    try {
      onStatus?.call('Encrypting local store with a random key…');
    } catch (_) {}
    try {
      await _prefs.wipe();
    } catch (_) {}
    try {
      onStatus?.call('Shredding local databases…');
    } catch (_) {}
    try {
      await _cache.wipe();
    } catch (_) {}
    try {
      await _files?.wipe();
    } catch (_) {}
    try {
      onStatus?.call('Purging caches…');
    } catch (_) {}
    try {
      await _secure.wipe();
    } catch (_) {}
    if (purge == null) return const PanicWipeReport();
    if (pending == null) return PanicWipeReport(unremoved: purge.expected);
    final wait = left();
    final outcomes = await Future.wait([
      for (final f in pending)
        f.timeout(wait, onTimeout: () => false).catchError((_) => false),
    ]);
    return PanicWipeReport(
        unremoved: outcomes.where((ok) => !ok).length);
  }
}

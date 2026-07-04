import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/storage/cache_store.dart';
import '../../services/storage/secure_store.dart';

/// Abstractions over the data stores the panic wipe destroys, so tests can
/// inject fakes and assert they were cleared.
abstract class PanicPrefsStore {
  Future<void> wipe();
}

abstract class PanicSecureStore {
  Future<void> wipe();
}

abstract class PanicCacheStore {
  Future<void> wipe();
}

/// Default adapters around the real stores used in production.
class _SharedPrefsAdapter implements PanicPrefsStore {
  @override
  Future<void> wipe() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().toList();
    final rng = Random.secure();
    // 1) Encrypt every value under a fresh, non-extractable AES-GCM-256 key that
    //    goes out of scope when this returns — so any bytes that survive deletion
    //    are ciphertext nobody can recover (mirrors `_panicEncryptStorage`).
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
            'panic:${base64.encode([...box.nonce, ...box.cipherText, ...box.mac.bytes])}',
          );
        } catch (_) {}
      }
    } catch (_) {}
    // 2) Junk-overwrite, then clear (mirrors the PWA junk-overwrite + clear).
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
  Future<void> wipe() => _store.wipeAll();
}

class _CacheStoreAdapter implements PanicCacheStore {
  _CacheStoreAdapter(this._store);
  final CacheStore _store;
  @override
  Future<void> wipe() async {
    // Junk-overwrite every store, clear it, then close + DELETE the database
    // file itself — the PWA overwrites + `indexedDB.deleteDatabase`s every DB
    // (panic.js:95-106), it does not merely empty the stores. The open is
    // isolated so a corrupt DB that won't open still gets its file deleted.
    try {
      if (!_store.isOpen) await _store.open();
    } catch (_) {}
    try {
      await _store.panicWipe();
    } catch (_) {}
  }
}

String _junk(Random rng) {
  final b = List<int>.generate(256, (_) => rng.nextInt(256));
  return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

/// Performs the emergency wipe (`panicWipe`, docs/specs/04 §10.3): clears
/// SharedPreferences, flutter_secure_storage (`deleteAll`), and shreds +
/// DELETES the sqflite cache DB file, then resolves. The UI
/// restart-to-first-run is handled by the caller after this completes.
///
/// All three stores are injectable so the wipe can be unit-tested against
/// fakes; production callers use [PanicWipe.production].
class PanicWipe {
  PanicWipe({
    required PanicPrefsStore prefs,
    required PanicSecureStore secure,
    required PanicCacheStore cache,
  })  : _prefs = prefs,
        _secure = secure,
        _cache = cache;

  /// The production wipe wired to the real stores.
  factory PanicWipe.production({
    SecureStore? secure,
    CacheStore? cache,
  }) =>
      PanicWipe(
        prefs: _SharedPrefsAdapter(),
        secure: _SecureStoreAdapter(secure ?? SecureStore()),
        cache: _CacheStoreAdapter(cache ?? CacheStore()),
      );

  final PanicPrefsStore _prefs;
  final PanicSecureStore _secure;
  final PanicCacheStore _cache;

  /// True while a panic wipe is destroying the stores (and until
  /// `resetAfterPanic` finishes the teardown). The controller's persistence
  /// paths check this and refuse to write — the native analogue of panic.js
  /// setting `_cacheDisabled = true` and clearing every persist timer FIRST
  /// (panic.js:63-67) so nothing re-writes data mid-wipe.
  static bool inProgress = false;

  /// Destroy every local store. Each step is best-effort and isolated so one
  /// failing store can't abort the others (matching the PWA's try/catch wrap).
  ///
  /// [onStatus] receives the PWA's stage strings (panic.js:84/96/109) as each
  /// destruction stage starts, so the overlay's status line tracks the real
  /// progress instead of jumping straight to the final state.
  Future<void> wipe({void Function(String status)? onStatus}) async {
    // Stop persistence before destroying anything (panic.js `_cacheDisabled`).
    inProgress = true;
    // Order mirrors the PWA (`panic.js`): encrypt-with-discarded-key + junk +
    // clear the key/value store (web-storage analogue) first, then shred the
    // local database (IndexedDB analogue), then the secure keystore (the
    // vault's remaining at-rest bytes — the PWA's final purge stage).
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
      onStatus?.call('Purging caches…');
    } catch (_) {}
    try {
      await _secure.wipe();
    } catch (_) {}
  }
}

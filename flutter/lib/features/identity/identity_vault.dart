import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/constants/storage_keys.dart';
import '../../services/platform/background_refresh.dart';
import '../../services/storage/key_value_store.dart';
import '../../services/storage/secure_store.dart';
import 'biometric_secret_store.dart';

/// The [SecureStore] subset the vault uses, so tests can inject an in-memory fake.
abstract class SecureStoreLike {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
  Future<void> wipeAll();
}

class SecureStoreAdapter implements SecureStoreLike {
  SecureStoreAdapter(this._store);
  final SecureStore _store;
  @override
  Future<String?> get(String key) => _store.get(key);
  @override
  Future<void> set(String key, String value) => _store.set(key, value);
  @override
  Future<void> remove(String key) => _store.remove(key);
  @override
  Future<void> wipeAll() => _store.wipeAll();
}

/// Identity encryption at rest: PBKDF2-SHA256 (310k iterations) to AES-GCM-256, blobs `enc:v1:<b64 iv>:<b64 ct>` like the PWA.
class IdentityVault {
  IdentityVault(this._kv, this._secure,
      {bool? escrow, BiometricSecretStore? biometric})
      : _escrow = escrow ?? BackgroundRefreshService.isSupported,
        _biometric = biometric ?? PlatformBiometricSecretStore();

  final KeyValueStore _kv;
  final SecureStoreLike _secure;
  final bool _escrow;
  final BiometricSecretStore _biometric;

  static const String bioSecretName = 'nym_vault_bio_secret';
  static const String wrongPasswordOrPin = 'Wrong password or PIN. Try again.';

  static const int _iterations = 310000;
  static const String _checkPlaintext = 'nymchat-vault-ok';

  /// Includes the post-quantum root, which must not sit in plaintext beside an encrypted nsec (PQ-ROOT-SPEC §5.3).
  static const List<String> vaultKeys = SecretKeys.all;

  bool get isEnabled => _kv.getBool(StorageKeys.vaultEnabled);

  /// `'password'`, `'pin'`, or `'biometric'`.
  String get method => _kv.getString(StorageKeys.vaultMethod) ?? 'password';

  static final _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  );
  static final _aes = AesGcm.with256bits();

  /// Derived key kept after [enable]/[unlock] so later [secretSet] writes stay encrypted; cleared by [disable]/[reset].
  SecretKey? _sessionKey;

  /// Vault enabled and its session key is in memory.
  bool get isUnlocked => _sessionKey != null;

  Future<SecretKey> _deriveKey(String password, List<int> salt) {
    return _pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  Future<String> _encrypt(SecretKey key, String plaintext) async {
    final nonce = _aes.newNonce(); // 12-byte IV
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    // Ciphertext with the 16-byte GCM tag appended, as the PWA does.
    final ct = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    return 'enc:v1:${base64.encode(nonce)}:${base64.encode(ct)}';
  }

  Future<String> _decrypt(SecretKey key, String blob) async {
    final parts = blob.split(':');
    if (parts.length != 4 || parts[0] != 'enc' || parts[1] != 'v1') {
      throw const FormatException('bad blob');
    }
    final nonce = base64.decode(parts[2]);
    final all = base64.decode(parts[3]);
    // Last 16 bytes are the GCM tag.
    final tag = all.sublist(all.length - 16);
    final cipherText = all.sublist(0, all.length - 16);
    final clear = await _aes.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
      secretKey: key,
    );
    return utf8.decode(clear);
  }

  /// Derives a key from [password], encrypts existing plaintext secrets, and persists salt, method and check token.
  Future<void> enable(
      {required String method, required String password}) async {
    if (isEnabled) throw StateError('Encryption is already enabled.');
    final isBio = method == 'biometric';
    if (!isBio && password.length < 4) {
      throw ArgumentError('Choose a password or PIN of at least 4 characters.');
    }
    final salt = _randomBytes(16);
    final key = await _deriveKey(password, salt);

    for (final name in vaultKeys) {
      final cur = await _secure.get(name);
      if (cur == null || cur.startsWith('enc:v1:')) continue;
      await _secure.set(name, await _encrypt(key, cur));
    }

    await _kv.setString(StorageKeys.vaultSalt, base64.encode(salt));
    // PIN persists as `'password'`; only biometric is distinct.
    await _kv.setString(
        StorageKeys.vaultMethod, isBio ? 'biometric' : 'password');
    await _kv.setString(
        StorageKeys.vaultCheck, await _encrypt(key, _checkPlaintext));
    await _kv.setBool(StorageKeys.vaultEnabled, true);
    await _kv.setBool(StorageKeys.encryptAtRestPref, true);
    await _kv.remove(StorageKeys.encryptAtRestPromptDismissed);
    // Enabling leaves the vault unlocked for this session.
    _sessionKey = key;
    await _escrowBackgroundKey(key);
  }

  // Vault key escrow for iOS background wakes, kept in the same [SecureStore] so a panic wipe clears it.
  static const String _bgKeyName = 'nym_vault_bg_key';

  Future<void> _escrowBackgroundKey(SecretKey key) async {
    if (!_escrow) return clearBackgroundKey();
    try {
      final bytes = await key.extractBytes();
      await _secure.set(_bgKeyName, base64.encode(bytes));
    } catch (_) {
      // A refused keystore write only costs background catch-up; never fail an unlock over it.
    }
  }

  /// Drop the escrow so background wakes do nothing until the next foreground unlock.
  Future<void> clearBackgroundKey() async {
    try {
      await _secure.remove(_bgKeyName);
    } catch (_) {}
  }

  /// Unlocks with the escrowed key for a background wake only; null without a valid escrow.
  Future<Map<String, String>?> unlockForBackgroundWake() async {
    if (!isEnabled) return null;
    final stored = await _secure.get(_bgKeyName);
    if (stored == null || stored.isEmpty) return null;
    final SecretKey key;
    try {
      key = SecretKey(base64.decode(stored));
    } catch (_) {
      return null;
    }
    // The factor may have changed since the escrow was written.
    final check = _kv.getString(StorageKeys.vaultCheck);
    if (check != null && check.startsWith('enc:v1:')) {
      try {
        if (await _decrypt(key, check) != _checkPlaintext) return null;
      } catch (_) {
        await clearBackgroundKey();
        return null;
      }
    }
    _sessionKey = key;
    final out = <String, String>{};
    for (final name in vaultKeys) {
      final blob = await _secure.get(name);
      if (blob == null) continue;
      try {
        out[name] = blob.startsWith('enc:v1:') ? await _decrypt(key, blob) : blob;
      } catch (_) {
        return null;
      }
    }
    return out;
  }

  /// Checks [password] against the stored check token without unlocking.
  Future<bool> verifyPassword(String password) async {
    try {
      final saltB64 = _kv.getString(StorageKeys.vaultSalt);
      final blob = _kv.getString(StorageKeys.vaultCheck);
      if (saltB64 == null || blob == null) return false;
      final key = await _deriveKey(password, base64.decode(saltB64));
      final v = await _decrypt(key, blob);
      return v == _checkPlaintext;
    } catch (_) {
      return false;
    }
  }

  /// Derives the key, verifies the check token, and returns decrypted secrets by name; throws on a wrong factor.
  Future<Map<String, String>> unlock(String password) async {
    if (!isEnabled) return {};
    final saltB64 = _kv.getString(StorageKeys.vaultSalt);
    if (saltB64 == null) throw StateError('Vault metadata is corrupt.');
    final key = await _deriveKey(password, base64.decode(saltB64));

    final check = _kv.getString(StorageKeys.vaultCheck);
    if (check != null && check.startsWith('enc:v1:')) {
      // Any check-token failure surfaces as one user-facing message.
      try {
        final v = await _decrypt(key, check); // throws on wrong key
        if (v != _checkPlaintext) {
          throw StateError('Vault verification failed.');
        }
      } catch (_) {
        throw StateError(wrongPasswordOrPin);
      }
    }
    // Retain the key for the session so post-boot secret writes stay encrypted.
    _sessionKey = key;
    await _escrowBackgroundKey(key);
    final out = <String, String>{};
    for (final name in vaultKeys) {
      final blob = await _secure.get(name);
      if (blob == null) continue;
      out[name] = blob.startsWith('enc:v1:') ? await _decrypt(key, blob) : blob;
    }
    return out;
  }

  Future<bool> changePassword(String current, String next) async {
    if (!isEnabled || method == 'biometric') return false;
    if (next.length < 4) {
      throw ArgumentError('Use at least 4 characters.');
    }
    final saltB64 = _kv.getString(StorageKeys.vaultSalt);
    final check = _kv.getString(StorageKeys.vaultCheck);
    if (saltB64 == null || check == null) return false;
    final oldKey = await _deriveKey(current, base64.decode(saltB64));
    try {
      if (await _decrypt(oldKey, check) != _checkPlaintext) return false;
    } catch (_) {
      return false;
    }
    final salt = _randomBytes(16);
    final key = await _deriveKey(next, salt);
    final before = <String, String?>{};
    final blobs = <String, String>{};
    for (final name in vaultKeys) {
      final blob = await _secure.get(name);
      if (blob == null || !blob.startsWith('enc:v1:')) continue;
      before[name] = blob;
      blobs[name] = await _encrypt(key, await _decrypt(oldKey, blob));
    }
    final newCheck = await _encrypt(key, _checkPlaintext);
    try {
      for (final e in blobs.entries) {
        await _secure.set(e.key, e.value);
      }
      await _kv.setString(StorageKeys.vaultSalt, base64.encode(salt));
      await _kv.setString(StorageKeys.vaultCheck, newCheck);
    } catch (_) {
      for (final e in before.entries) {
        try {
          await _secure.set(e.key, e.value!);
        } catch (_) {}
      }
      try {
        await _kv.setString(StorageKeys.vaultSalt, saltB64);
        await _kv.setString(StorageKeys.vaultCheck, check);
      } catch (_) {}
      rethrow;
    }
    _sessionKey = key;
    await _escrowBackgroundKey(key);
    return true;
  }

  /// Decrypts secrets back to plaintext and clears metadata; requires the correct [password].
  Future<void> disable(String password) async {
    if (!isEnabled) return;
    final saltB64 = _kv.getString(StorageKeys.vaultSalt);
    if (saltB64 == null) throw StateError('Vault metadata is corrupt.');
    final key = await _deriveKey(password, base64.decode(saltB64));
    if (!await verifyPassword(password)) {
      throw StateError('Re-authentication failed.');
    }
    for (final name in vaultKeys) {
      final blob = await _secure.get(name);
      if (blob != null && blob.startsWith('enc:v1:')) {
        await _secure.set(name, await _decrypt(key, blob));
      }
    }
    _sessionKey = null; // Secrets are plaintext again.
    await clearBackgroundKey();
    await _clearMeta();
  }

  /// Discards the vault and its encrypted secrets (forgotten-password escape hatch).
  Future<void> reset() async {
    _sessionKey = null;
    final wasBiometric = method == 'biometric';
    await clearBackgroundKey();
    for (final name in vaultKeys) {
      await _secure.remove(name);
    }
    await _clearMeta();
    if (wasBiometric) await _dropBiometricSecrets();
  }

  bool get biometricProtected => _kv.getBool(StorageKeys.vaultBioProtected);

  Future<bool> biometricAvailable() async {
    try {
      return await _biometric.isAvailable();
    } catch (_) {
      return false;
    }
  }

  Future<BiometricKind> biometricKind() async {
    try {
      return await _biometric.kind();
    } catch (_) {
      return BiometricKind.generic;
    }
  }

  Future<void> enableBiometric() async {
    if (isEnabled) throw StateError('Encryption is already enabled.');
    if (!await biometricAvailable()) {
      throw const BiometricVaultException(BiometricVaultFailure.unavailable);
    }
    final secret = base64.encode(_randomBytes(32));
    try {
      await _biometric.write(secret);
      final back = await _biometric.read();
      if (back != secret) {
        throw const BiometricVaultException(BiometricVaultFailure.verifyFailed);
      }
    } catch (e) {
      await _dropProtectedSecret();
      if (e is BiometricCanceled) {
        throw const BiometricVaultException(BiometricVaultFailure.canceled);
      }
      if (e is BiometricVaultException) rethrow;
      if (e is BiometricStoreError && e.code == 'unavailable') {
        throw const BiometricVaultException(BiometricVaultFailure.unavailable);
      }
      throw const BiometricVaultException(BiometricVaultFailure.verifyFailed);
    }
    await _kv.setBool(StorageKeys.vaultBioProtected, true);
    try {
      await enable(method: 'biometric', password: secret);
    } catch (_) {
      await _kv.remove(StorageKeys.vaultBioProtected);
      rethrow;
    }
    await _dropPlainSecret();
  }

  Future<Map<String, String>> unlockBiometric() async {
    if (!isEnabled) return {};
    final plain = biometricProtected ? null : await _secure.get(bioSecretName);
    if (plain == null || plain.isEmpty) {
      final out = await _unlockWithBiometricSecret(await _readProtectedSecret());
      if (!biometricProtected) {
        await _kv.setBool(StorageKeys.vaultBioProtected, true);
      }
      await _dropPlainSecret();
      return out;
    }
    return _unlockAndMigrate(plain);
  }

  Future<void> disableBiometric() async {
    if (!isEnabled) return;
    final plain = biometricProtected ? null : await _secure.get(bioSecretName);
    final String secret;
    if (plain == null || plain.isEmpty) {
      secret = await _readProtectedSecret();
    } else {
      if (!await _biometric.confirmPresence()) {
        throw const BiometricVaultException(BiometricVaultFailure.canceled);
      }
      secret = plain;
    }
    await disable(secret);
    await _dropBiometricSecrets();
  }

  Future<Map<String, String>> _unlockAndMigrate(String plain) async {
    if (await biometricAvailable()) {
      String? back;
      try {
        await _biometric.write(plain);
        back = await _biometric.read();
      } on BiometricCanceled {
        throw const BiometricVaultException(BiometricVaultFailure.canceled);
      } catch (_) {
        back = null;
      }
      if (back == plain) {
        final out = await _unlockWithBiometricSecret(plain);
        await _kv.setBool(StorageKeys.vaultBioProtected, true);
        await _dropPlainSecret();
        return out;
      }
    }
    if (!await _biometric.confirmPresence()) {
      throw const BiometricVaultException(BiometricVaultFailure.canceled);
    }
    return _unlockWithBiometricSecret(plain);
  }

  Future<Map<String, String>> _unlockWithBiometricSecret(String secret) async {
    try {
      return await unlock(secret);
    } on StateError catch (e) {
      if (e.message != wrongPasswordOrPin) rethrow;
      throw const BiometricVaultException(BiometricVaultFailure.failed);
    }
  }

  Future<String> _readProtectedSecret() async {
    final String? secret;
    try {
      secret = await _biometric.read();
    } on BiometricCanceled {
      throw const BiometricVaultException(BiometricVaultFailure.canceled);
    } catch (_) {
      throw const BiometricVaultException(BiometricVaultFailure.failed);
    }
    if (secret == null || secret.isEmpty) {
      throw const BiometricVaultException(BiometricVaultFailure.invalidated);
    }
    return secret;
  }

  Future<void> _dropBiometricSecrets() async {
    await _dropProtectedSecret();
    await _dropPlainSecret();
  }

  Future<void> _dropProtectedSecret() async {
    try {
      await _biometric.delete();
    } catch (_) {}
  }

  Future<void> _dropPlainSecret() async {
    try {
      await _secure.remove(bioSecretName);
    } catch (_) {}
  }

  /// Stores an `enc:v1:` blob while the vault is unlocked, otherwise plaintext.
  Future<void> secretSet(String name, String value) async {
    final key = _sessionKey;
    if (isEnabled && key != null) {
      var blob = await _encrypt(key, value);
      final now = _sessionKey;
      if (now != null && !identical(now, key)) blob = await _encrypt(now, value);
      await _secure.set(name, blob);
    } else {
      await _secure.set(name, value);
    }
  }

  Future<void> _clearMeta() async {
    await _kv.remove(StorageKeys.vaultBioProtected);
    await _kv.remove(StorageKeys.vaultEnabled);
    await _kv.remove(StorageKeys.vaultSalt);
    await _kv.remove(StorageKeys.vaultMethod);
    await _kv.remove(StorageKeys.vaultCred);
    await _kv.remove(StorageKeys.vaultCheck);
  }

  /// Whether any identity secret is stored in plaintext, not `enc:v1:`-wrapped.
  Future<bool> hasUnencryptedSecret() async {
    for (final name in vaultKeys) {
      final cur = await _secure.get(name);
      if (cur != null && cur.isNotEmpty && !cur.startsWith('enc:v1:')) {
        return true;
      }
    }
    return false;
  }

  bool get encryptAtRestPromptDismissed =>
      _kv.getBool(StorageKeys.encryptAtRestPromptDismissed);

  /// Offer encryption only when the vault is off, not dismissed, preferred on some device, and a secret is unencrypted.
  Future<bool> shouldPromptEncryptAtRest() async {
    if (isEnabled) return false;
    if (encryptAtRestPromptDismissed) return false;
    if (!_kv.getBool(StorageKeys.encryptAtRestPref)) return false;
    return hasUnencryptedSecret();
  }

  /// Persists "Not now" so the prompt won't fire again.
  Future<void> declineEncryptAtRest() async {
    await _kv.setBool(StorageKeys.encryptAtRestPromptDismissed, true);
  }

  final Random _rng = Random.secure();

  Uint8List _randomBytes(int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }
}

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/constants/storage_keys.dart';
import '../../services/storage/key_value_store.dart';
import '../../services/storage/secure_store.dart';

/// The subset of [SecureStore] the vault uses. Declared as an interface so the
/// real [SecureStore] (which matches structurally) can be passed in production
/// while tests inject an in-memory fake. [SecureStore] satisfies this shape.
abstract class SecureStoreLike {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
  Future<void> wipeAll();
}

/// Adapts a concrete [SecureStore] to [SecureStoreLike].
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

/// Optional encryption-at-rest for the identity secret keys, ported from
/// `js/modules/key-vault.js` (docs/specs/01 §2.2).
///
/// The factor (password / PIN — or biometric, handled by the UI via
/// `local_auth`) derives an AES-GCM-256 key via PBKDF2-SHA256 (310 000
/// iterations), which encrypts each identity secret in place. A known check
/// token (`nymchat-vault-ok`) is stored encrypted so unlock can verify the key.
///
/// Blob format matches the PWA exactly: `enc:v1:<b64(iv)>:<b64(ciphertext)>`.
class IdentityVault {
  IdentityVault(this._kv, this._secure);

  final KeyValueStore _kv;
  final SecureStoreLike _secure;

  static const int _iterations = 310000;
  static const String _checkPlaintext = 'nymchat-vault-ok';

  /// The four identity secrets protected by the vault (matches the PWA).
  static const List<String> vaultKeys = SecretKeys.all;

  bool get isEnabled => _kv.getBool(StorageKeys.vaultEnabled);

  /// `'password'`, `'pin'`, or `'biometric'`. (Web also has `'passkey'`.)
  String get method => _kv.getString(StorageKeys.vaultMethod) ?? 'password';

  // ---------------------------------------------------------------------------
  // Crypto primitives (PBKDF2 → AES-GCM), mirroring _deriveKeyFromPassword /
  // _vaultEncrypt / _vaultDecrypt.
  // ---------------------------------------------------------------------------

  static final _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  );
  static final _aes = AesGcm.with256bits();

  /// The derived AES session key, retained after a successful [enable] /
  /// [unlock] — the native analogue of the PWA's `this._vaultKey`
  /// (key-vault.js `unlockVault`). Lets [secretSet] keep encrypting secrets
  /// written AFTER boot (nsec login, NIP-46 session, key rotation) instead of
  /// silently downgrading them to plaintext. Cleared by [disable] / [reset].
  SecretKey? _sessionKey;

  /// Whether the vault is enabled AND its session key is in memory (the PWA's
  /// `vaultUnlocked()`, key-vault.js:26).
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
    // The PWA appends the 16-byte GCM tag to the ciphertext, then base64s the
    // whole thing. We match: ct = cipherText + mac.
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

  // ---------------------------------------------------------------------------
  // Enable / disable / unlock
  // ---------------------------------------------------------------------------

  /// Enable the vault: derive a key from [password], encrypt the existing
  /// plaintext secrets, and persist the salt/method/check-token + flag.
  /// Mirrors `enableVault`. [method] is `'password'`, `'pin'` or `'biometric'`.
  Future<void> enable({required String method, required String password}) async {
    if (isEnabled) throw StateError('Encryption is already enabled.');
    final isBio = method == 'biometric';
    if (!isBio && password.length < 4) {
      throw ArgumentError('Choose a password or PIN of at least 4 characters.');
    }
    final salt = _randomBytes(16);
    final key = await _deriveKey(password, salt);

    // Encrypt each currently-plaintext secret in secure storage.
    for (final name in vaultKeys) {
      final cur = await _secure.get(name);
      if (cur == null || cur.startsWith('enc:v1:')) continue;
      await _secure.set(name, await _encrypt(key, cur));
    }

    await _kv.setString(
        StorageKeys.vaultSalt, base64.encode(salt));
    // The PWA stores `'password'` for both password AND PIN factors (a PIN is a
    // digit-only password); only biometric is distinct (key-vault.js:180).
    await _kv.setString(
        StorageKeys.vaultMethod, isBio ? 'biometric' : 'password');
    await _kv.setString(
        StorageKeys.vaultCheck, await _encrypt(key, _checkPlaintext));
    await _kv.setBool(StorageKeys.vaultEnabled, true);
    await _kv.setBool(StorageKeys.encryptAtRestPref, true);
    await _kv.remove(StorageKeys.encryptAtRestPromptDismissed);
    // Enabling leaves the vault unlocked for this session (key-vault.js
    // `enableVault` sets `this._vaultKey = key`), so later [secretSet] writes
    // stay encrypted.
    _sessionKey = key;
  }

  /// Verify [password] against the stored check token without unlocking.
  /// Returns true on a correct factor. Mirrors `_verifyPassword`.
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

  /// Unlock the vault: derive the key from [password], verify the check token,
  /// and return the decrypted secrets keyed by name. Mirrors `unlockVault`.
  /// Throws on a wrong factor.
  Future<Map<String, String>> unlock(String password) async {
    if (!isEnabled) return {};
    final saltB64 = _kv.getString(StorageKeys.vaultSalt);
    if (saltB64 == null) throw StateError('Vault metadata is corrupt.');
    final key = await _deriveKey(password, base64.decode(saltB64));

    final check = _kv.getString(StorageKeys.vaultCheck);
    if (check != null && check.startsWith('enc:v1:')) {
      // The PWA wraps any check-token failure (bad decrypt OR a mismatched
      // plaintext) into one user-facing message (key-vault.js:262-274).
      try {
        final v = await _decrypt(key, check); // throws on wrong key
        if (v != _checkPlaintext) {
          throw StateError('Vault verification failed.');
        }
      } catch (_) {
        throw StateError('Wrong password/PIN or unrecognised passkey.');
      }
    }
    // Verified — retain the key for the session (`this._vaultKey = key`,
    // key-vault.js `unlockVault`) so [secretSet] keeps encrypting post-boot
    // secret writes.
    _sessionKey = key;
    final out = <String, String>{};
    for (final name in vaultKeys) {
      final blob = await _secure.get(name);
      if (blob == null) continue;
      out[name] = blob.startsWith('enc:v1:')
          ? await _decrypt(key, blob)
          : blob;
    }
    return out;
  }

  /// Disable the vault: decrypt the secrets back to plaintext and clear the
  /// metadata. Requires the correct [password]. Mirrors `disableVault`.
  Future<void> disable(String password) async {
    if (!isEnabled) return;
    final saltB64 = _kv.getString(StorageKeys.vaultSalt);
    if (saltB64 == null) throw StateError('Vault metadata is corrupt.');
    final key = await _deriveKey(password, base64.decode(saltB64));
    // Verify first.
    if (!await verifyPassword(password)) {
      throw StateError('Re-authentication failed.');
    }
    for (final name in vaultKeys) {
      final blob = await _secure.get(name);
      if (blob != null && blob.startsWith('enc:v1:')) {
        await _secure.set(name, await _decrypt(key, blob));
      }
    }
    _sessionKey = null; // Secrets are plaintext again (key-vault.js:307).
    await _clearMeta();
  }

  /// Discard the vault and its encrypted secrets entirely (forgotten-password
  /// escape hatch). Mirrors `resetVault`.
  Future<void> reset() async {
    _sessionKey = null;
    for (final name in vaultKeys) {
      await _secure.remove(name);
    }
    await _clearMeta();
  }

  /// Vault-aware secret write — the PWA's `secretSet` (key-vault.js:38-48).
  /// With the vault enabled AND unlocked ([_sessionKey] retained by [enable] /
  /// [unlock]) the value is stored as an `enc:v1:` blob; otherwise it is
  /// stored as-is (the vault-disabled else-branch). Wired into
  /// `IdentityService(secretWrite: …)` so identity secrets persisted after
  /// boot keep the encryption-at-rest guarantee.
  Future<void> secretSet(String name, String value) async {
    final key = _sessionKey;
    if (isEnabled && key != null) {
      await _secure.set(name, await _encrypt(key, value));
    } else {
      await _secure.set(name, value);
    }
  }

  Future<void> _clearMeta() async {
    await _kv.remove(StorageKeys.vaultEnabled);
    await _kv.remove(StorageKeys.vaultSalt);
    await _kv.remove(StorageKeys.vaultMethod);
    await _kv.remove(StorageKeys.vaultCred);
    await _kv.remove(StorageKeys.vaultCheck);
  }

  // ---------------------------------------------------------------------------
  // Encrypt-at-rest prompt trigger (key-vault.js `maybePromptEncryptAtRest` /
  // `_hasPersistedSecret`). The boot/setup flow calls [shouldPromptEncryptAtRest]
  // to decide whether to offer turning on identity encryption; [declineEncryptAtRest]
  // persists the user's "Not now" so we don't nag again.
  // ---------------------------------------------------------------------------

  /// Whether any identity secret is stored **in plaintext** (not already
  /// `enc:v1:`-wrapped). Mirrors key-vault.js `_hasPersistedSecret` but, because
  /// the native secrets live in the keystore, it also confirms the secret is
  /// actually unencrypted-at-rest (an enabled vault stores `enc:v1:` blobs, so
  /// those don't count as "exposed").
  Future<bool> hasUnencryptedSecret() async {
    for (final name in vaultKeys) {
      final cur = await _secure.get(name);
      if (cur != null && cur.isNotEmpty && !cur.startsWith('enc:v1:')) {
        return true;
      }
    }
    return false;
  }

  /// Whether the user previously dismissed the encrypt-at-rest prompt
  /// (`nym_encrypt_at_rest_prompt_dismissed === '1'`).
  bool get encryptAtRestPromptDismissed =>
      _kv.getBool(StorageKeys.encryptAtRestPromptDismissed);

  /// True when the boot/setup flow should offer to enable encryption-at-rest.
  /// Mirrors key-vault.js `maybePromptEncryptAtRest` EXACTLY (lines 415-421):
  /// the vault is **not** already enabled, the user hasn't dismissed the prompt,
  /// the cross-device `encryptAtRestPreferred` hint is set (line 419 hard-requires
  /// `nym_encrypt_at_rest_pref === '1'`), and an identity secret is sitting in
  /// storage unencrypted. The flag is set when the user enables the vault on this
  /// device (so it persists across a reset) OR when it arrives via settings sync
  /// from another device — so the "protect your identity here too" offer only
  /// appears when the user already uses encryption-at-rest somewhere.
  Future<bool> shouldPromptEncryptAtRest() async {
    if (isEnabled) return false;
    if (encryptAtRestPromptDismissed) return false;
    if (!_kv.getBool(StorageKeys.encryptAtRestPref)) return false;
    return hasUnencryptedSecret();
  }

  /// Persists the user's "Not now" so [shouldPromptEncryptAtRest] won't fire
  /// again (key-vault.js `dismiss()` →
  /// `localStorage.setItem('nym_encrypt_at_rest_prompt_dismissed', '1')`).
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

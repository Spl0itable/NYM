import 'dart:convert';
import 'dart:typed_data';

import '../../core/constants/storage_keys.dart';
import '../../core/crypto/bech32_codec.dart' as bech32;
import '../../core/crypto/key_format.dart' show normalizePrivkeyInput;
import '../../core/crypto/keys.dart';
import '../../core/utils/nym_utils.dart';
import '../storage/key_value_store.dart';
import '../storage/secure_store.dart';
import 'nym_generator.dart';

/// The active identity: keys, display nym and login method.
class Identity {
  Identity({
    required this.pubkey,
    required this.privkey,
    required this.nym,
    this.loginMethod,
  });

  final String pubkey; // 64-hex
  final Uint8List? privkey; // Null when signing is delegated (extension/NIP-46).
  String nym;
  final String? loginMethod; // null = ephemeral | 'extension' | 'nsec' | 'nip46'

  String get npub => bech32.encodeNpub(pubkey);
  bool get canSign => privkey != null;
}

/// Vault-aware secret writer that stores an `enc:v1:` blob while the vault is enabled and unlocked.
typedef SecretWriter = Future<void> Function(String name, String value);

/// Boots and persists the identity: reuse the saved session nsec, else generate a keypair and random nym.
class IdentityService {
  IdentityService({
    required this._kv,
    required this._secure,
    NymGenerator? nymGenerator,
    this._secretWrite,
  })  : _nymGen = nymGenerator ?? NymGenerator();

  final KeyValueStore _kv;
  final SecureStore _secure;
  final NymGenerator _nymGen;

  /// Injected vault-aware writer; null falls back to a plain [SecureStore.set].
  final SecretWriter? _secretWrite;

  Future<void> _secretSet(String name, String value) {
    final write = _secretWrite;
    if (write != null) return write(name, value);
    return _secure.set(name, value);
  }

  /// Prefers an in-memory [unlocked] value so the at-rest `enc:v1:` blob is never read directly.
  Future<String?> _secretGet(String name, Map<String, String>? unlocked) async {
    final mem = unlocked?[name];
    if (mem != null && mem.isNotEmpty) return mem;
    return _secure.get(name);
  }

  /// Cached kind-0 name for the durable login (`nym_nostr_login_profile`); null when absent or corrupt.
  String? _cachedLoginProfileName() {
    final raw = _kv.getString(StorageKeys.nostrLoginProfile);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final name = decoded['name'];
        if (name is String && name.isNotEmpty) return name;
      }
    } catch (_) {}
    return null;
  }

  /// Durable login nym from the cached profile name (or 'nym'), never the ephemeral nick.
  String _durableLoginNym(String pubkey) =>
      getNymFromPubkey(_cachedLoginProfileName() ?? 'nym', pubkey);

  /// Restores a saved nsec account, else boots ephemeral; NIP-46/extension logins restore in their own flow.
  Future<Identity> boot({Map<String, String>? unlockedSecrets}) async {
    final method = _kv.getString(StorageKeys.nostrLoginMethod);
    if (method == 'nsec') {
      final savedNsec =
          await _secretGet(SecretKeys.nostrLoginNsec, unlockedSecrets);
      if (savedNsec != null && savedNsec.isNotEmpty) {
        try {
          final sk = bech32.decodeNsec(savedNsec);
          final pubkey = getPublicKeyHex(sk);
          return Identity(
            pubkey: pubkey,
            privkey: sk,
            nym: _durableLoginNym(pubkey),
            loginMethod: 'nsec',
          );
        } catch (_) {
          await _secure.remove(SecretKeys.nostrLoginNsec);
        }
      }
    }
    return bootEphemeral(unlockedSecrets: unlockedSecrets);
  }

  /// Imports [nsec] as the persisted durable login; throws [FormatException] on an invalid key.
  Future<Identity> loginWithNsec(String nsec) async {
    // Accepts `nsec1…` or a bare 64-char hex key.
    final sk = normalizePrivkeyInput(nsec);
    if (sk == null || sk.length != 32) {
      throw const FormatException(
          'expected an nsec1… or a 64-character hex private key');
    }
    // Always persist the canonical nsec, since [boot] decodes it as bech32.
    final input = bech32.encodeNsecBytes(sk);
    final pubkey = getPublicKeyHex(sk);

    await _kv.setString(StorageKeys.nostrLoginMethod, 'nsec');
    await _kv.setString(StorageKeys.nostrLoginPubkey, pubkey);
    await _secretSet(SecretKeys.nostrLoginNsec, input);
    try {
      await _kv.setString(
          StorageKeys.nostrLoginNpub, bech32.encodeNpub(pubkey));
    } catch (_) {}

    // Drop ephemeral profile data so it doesn't clobber the persistent identity.
    await _kv.remove(StorageKeys.avatarUrl);
    await _kv.remove(StorageKeys.bannerUrl);

    return Identity(
      pubkey: pubkey,
      privkey: sk,
      nym: _durableLoginNym(pubkey),
      loginMethod: 'nsec',
    );
  }

  bool generatedFreshKey = false;

  Future<Identity> bootEphemeral({Map<String, String>? unlockedSecrets}) async {
    generatedFreshKey = false;
    final randomPerSession =
        _kv.getBool(StorageKeys.randomKeypairPerSession, defaultValue: false);
    final savedNick = _kv.getString(StorageKeys.autoEphemeralNick);
    final nickStyle = _kv.getString(StorageKeys.nickStyle) ?? 'fancy';

    if (!randomPerSession) {
      final savedNsec =
          await _secretGet(SecretKeys.sessionNsec, unlockedSecrets);
      if (savedNsec != null && savedNsec.isNotEmpty) {
        try {
          final sk = bech32.decodeNsec(savedNsec);
          final pubkey = getPublicKeyHex(sk);
          final nym = (savedNick != null && savedNick.isNotEmpty)
              ? savedNick
              : _nymGen.generate(pubkey, style: nickStyle);
          return Identity(pubkey: pubkey, privkey: sk, nym: nym);
        } catch (_) {
          await _secure.remove(SecretKeys.sessionNsec);
        }
      }
    }

    final sk = generatePrivateKey();
    final pubkey = getPublicKeyHex(sk);
    generatedFreshKey = true;
    final nym = (!randomPerSession && savedNick != null && savedNick.isNotEmpty)
        ? savedNick
        : _nymGen.generate(pubkey, style: nickStyle);

    if (!randomPerSession) {
      await _secretSet(SecretKeys.sessionNsec, bech32.encodeNsecBytes(sk));
      if (savedNick == null || savedNick.isEmpty) {
        await _kv.setString(StorageKeys.autoEphemeralNick, nym);
      }
    }

    return Identity(pubkey: pubkey, privkey: sk, nym: nym);
  }

  /// Hardcore mode: fresh keypair and random nym per message; durable logins are returned unchanged.
  Future<Identity> rotateEphemeral(Identity current) async {
    if (current.loginMethod != null) return current;

    final randomPerSession =
        _kv.getBool(StorageKeys.randomKeypairPerSession, defaultValue: false);
    final nickStyle = _kv.getString(StorageKeys.nickStyle) ?? 'fancy';

    // Fresh keypair and always-random nym.
    final sk = generatePrivateKey();
    final pubkey = getPublicKeyHex(sk);
    final nym = _nymGen.generate(pubkey, style: nickStyle);

    if (!randomPerSession) {
      // Persist for a same-session reconnect, as [bootEphemeral] does.
      await _secretSet(SecretKeys.sessionNsec, bech32.encodeNsecBytes(sk));
      await _kv.setString(StorageKeys.autoEphemeralNick, nym);
    }

    return Identity(pubkey: pubkey, privkey: sk, nym: nym);
  }

  Future<void> setNym(Identity identity, String nym) async {
    identity.nym = nym;
    await _kv.setString(StorageKeys.autoEphemeralNick, nym);
  }
}

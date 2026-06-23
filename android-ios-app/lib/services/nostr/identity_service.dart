import 'dart:typed_data';

import '../../core/constants/storage_keys.dart';
import '../../core/crypto/bech32_codec.dart' as bech32;
import '../../core/crypto/keys.dart';
import '../storage/key_value_store.dart';
import '../storage/secure_store.dart';
import 'nym_generator.dart';

/// The active identity (keys + display nym + login method).
class Identity {
  Identity({
    required this.pubkey,
    required this.privkey,
    required this.nym,
    this.loginMethod,
  });

  final String pubkey; // 64-hex
  final Uint8List? privkey; // null when signing is delegated (ext/nip46)
  String nym;
  final String? loginMethod; // null=ephemeral | 'extension' | 'nsec' | 'nip46'

  String get npub => bech32.encodeNpub(pubkey);
  bool get canSign => privkey != null;
}

/// Boots and persists the user identity. Mirrors the PWA's ephemeral-identity
/// path (docs/specs/01 §2.1): reuse the saved session nsec if present, else
/// generate a fresh keypair + random nym and persist them.
class IdentityService {
  IdentityService({
    required KeyValueStore kv,
    required SecureStore secure,
    NymGenerator? nymGenerator,
  })  : _kv = kv,
        _secure = secure,
        _nymGen = nymGenerator ?? NymGenerator();

  final KeyValueStore _kv;
  final SecureStore _secure;
  final NymGenerator _nymGen;

  /// Reads a secret, preferring an in-memory [unlocked] value (from the vault
  /// boot unlock, the native analogue of `_vaultMem`) over the at-rest store —
  /// so the encrypted `enc:v1:` blob in secure storage is never read directly.
  Future<String?> _secretGet(String name, Map<String, String>? unlocked) async {
    final mem = unlocked?[name];
    if (mem != null && mem.isNotEmpty) return mem;
    return _secure.get(name);
  }

  /// Boots the appropriate identity for the saved login method
  /// (`checkSavedConnection`, docs/specs/01 §7): an saved nsec account is
  /// restored with its real keypair; ephemeral / unknown falls back to
  /// [bootEphemeral]. NIP-46 / extension logins (no local key) are restored at
  /// runtime by their login flow, so they fall through to ephemeral here.
  ///
  /// [unlockedSecrets] holds the in-memory decrypted vault secrets when the
  /// identity vault is enabled (so we never read the encrypted blob at rest).
  Future<Identity> boot({Map<String, String>? unlockedSecrets}) async {
    final method = _kv.getString(StorageKeys.nostrLoginMethod);
    if (method == 'nsec') {
      final savedNsec =
          await _secretGet(SecretKeys.nostrLoginNsec, unlockedSecrets);
      if (savedNsec != null && savedNsec.isNotEmpty) {
        try {
          final sk = bech32.decodeNsec(savedNsec);
          final pubkey = getPublicKeyHex(sk);
          final nym = _kv.getString(StorageKeys.customNick) ??
              _kv.getString(StorageKeys.autoEphemeralNick) ??
              _nymGen.generate(pubkey,
                  style: _kv.getString(StorageKeys.nickStyle) ?? 'fancy');
          return Identity(
            pubkey: pubkey,
            privkey: sk,
            nym: nym,
            loginMethod: 'nsec',
          );
        } catch (_) {
          await _secure.remove(SecretKeys.nostrLoginNsec);
        }
      }
    }
    return bootEphemeral(unlockedSecrets: unlockedSecrets);
  }

  /// Loads the persisted ephemeral identity or creates a new one.
  Future<Identity> bootEphemeral({Map<String, String>? unlockedSecrets}) async {
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

    // Generate a fresh keypair.
    final sk = generatePrivateKey();
    final pubkey = getPublicKeyHex(sk);
    final nym = (!randomPerSession && savedNick != null && savedNick.isNotEmpty)
        ? savedNick
        : _nymGen.generate(pubkey, style: nickStyle);

    if (!randomPerSession) {
      // Persist for reuse next session.
      await _secure.set(SecretKeys.sessionNsec, bech32.encodeNsecBytes(sk));
      if (savedNick == null || savedNick.isEmpty) {
        await _kv.setString(StorageKeys.autoEphemeralNick, nym);
      }
    }

    return Identity(pubkey: pubkey, privkey: sk, nym: nym);
  }

  /// Sets a new display nym (persisted for the ephemeral session).
  Future<void> setNym(Identity identity, String nym) async {
    identity.nym = nym;
    await _kv.setString(StorageKeys.autoEphemeralNick, nym);
  }
}

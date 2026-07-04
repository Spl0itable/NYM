import 'dart:convert';
import 'dart:typed_data';

import '../../core/constants/storage_keys.dart';
import '../../core/crypto/bech32_codec.dart' as bech32;
import '../../core/crypto/keys.dart';
import '../../core/utils/nym_utils.dart';
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

  /// The cached kind-0 profile name persisted for the durable login — the
  /// PWA's `nym_nostr_login_profile` instant-restore cache (written by
  /// `updateSidebarFromProfile`, app.js:5523-5527, whenever the SELF kind-0
  /// resolves — the controller's `_syncSelfNymFromProfile` — and read on boot
  /// BEFORE relays connect, app.js:4514-4522). Null when absent/corrupt.
  /// Parsing matches the controller's `_cachedLoginProfileName` byte-for-byte.
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

  /// A durable login's display nym: the cached kind-0 profile name (falling
  /// back to `'nym'` until the live kind-0 resolves), suffixed via
  /// [getNymFromPubkey] — exactly the seed the controller applies at init
  /// (nostr_controller.dart `_cachedLoginProfileName(kv) ?? 'nym'`) and the
  /// PWA's boot restore (app.js:4514-4522). NEVER the ephemeral
  /// customNick / autoEphemeralNick — those belong to the ephemeral identity
  /// and would mislabel the account until its profile fetch landed.
  String _durableLoginNym(String pubkey) =>
      getNymFromPubkey(_cachedLoginProfileName() ?? 'nym', pubkey);

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

  /// Imports a pasted [nsec] as the durable login identity and PERSISTS it so a
  /// later [boot] restores the same account. Mirrors the PWA's
  /// `nostrLoginWithNsec` (app.js:5036-5074) + the identity-switch half of
  /// `applyNostrLogin` (app.js:5487-5504):
  ///   * validate via [bech32.decodeNsec] (32 bytes) — throws [FormatException]
  ///     on an invalid key (the caller shows "Invalid nsec key …"),
  ///   * derive the pubkey ([getPublicKeyHex]),
  ///   * persist `nostr_login_method='nsec'` + `nostr_login_pubkey` (KV),
  ///     `nostr_login_npub` (KV), and the nsec in secure storage
  ///     (`nym_nostr_login_nsec`, the PWA's `nymSecretSet`),
  ///   * clear the ephemeral `nym_avatar_url`/`nym_banner_url` so they don't
  ///     overwrite the persistent identity's profile (app.js:5494-5495).
  ///
  /// Returns the durable [Identity] (`loginMethod:'nsec'`) with its nym resolved
  /// exactly like [boot] (cached kind-0 login-profile name → 'nym' fallback,
  /// via [_durableLoginNym]).
  Future<Identity> loginWithNsec(String nsec) async {
    final input = nsec.trim();
    final sk = bech32.decodeNsec(input); // throws on invalid (len-checked below)
    if (sk.length != 32) {
      throw const FormatException('nsec must decode to 32 bytes');
    }
    final pubkey = getPublicKeyHex(sk);

    // Persist the durable login (KV) + the nsec (secure store), mirroring the
    // PWA's localStorage + nymSecretSet writes.
    await _kv.setString(StorageKeys.nostrLoginMethod, 'nsec');
    await _kv.setString(StorageKeys.nostrLoginPubkey, pubkey);
    await _secure.set(SecretKeys.nostrLoginNsec, input);
    try {
      await _kv.setString(StorageKeys.nostrLoginNpub, bech32.encodeNpub(pubkey));
    } catch (_) {}

    // Drop ephemeral profile data so it doesn't clobber the persistent identity
    // (app.js:5494-5495 `removeItem nym_avatar_url / nym_banner_url`).
    await _kv.remove(StorageKeys.avatarUrl);
    await _kv.remove(StorageKeys.bannerUrl);

    return Identity(
      pubkey: pubkey,
      privkey: sk,
      nym: _durableLoginNym(pubkey),
      loginMethod: 'nsec',
    );
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

  /// Rotates the in-memory ephemeral identity: a brand-new keypair + a fresh
  /// RANDOM nym, returned as a new ephemeral [Identity] (loginMethod=null).
  ///
  /// This is the "hardcore" keypair mode (messages.js:2392-2404): after every
  /// sent message the PWA calls `generateKeypair()` then
  /// `this.nym = this.generateRandomNym()`, so the durable ephemeral identity is
  /// replaced wholesale and the nym is always freshly random (never the saved
  /// nick). Only valid for an ephemeral [current] identity — a durable login
  /// (nsec/extension/NIP-46, i.e. `loginMethod != null`) is returned unchanged,
  /// so a key rotation can never clobber a real account.
  ///
  /// The new key is persisted exactly like [bootEphemeral] does (the
  /// `nym_session_nsec` secret), so a same-session reconnect restores the
  /// just-rotated identity rather than an older one — kept consistent with the
  /// `randomKeypairPerSession` flag (hardcore sets it, so we skip persistence to
  /// match `bootEphemeral`'s "fresh each session" behaviour).
  Future<Identity> rotateEphemeral(Identity current) async {
    if (current.loginMethod != null) return current;

    final randomPerSession =
        _kv.getBool(StorageKeys.randomKeypairPerSession, defaultValue: false);
    final nickStyle = _kv.getString(StorageKeys.nickStyle) ?? 'fancy';

    // Fresh keypair + always-fresh random nym (PWA `generateRandomNym`).
    final sk = generatePrivateKey();
    final pubkey = getPublicKeyHex(sk);
    final nym = _nymGen.generate(pubkey, style: nickStyle);

    if (!randomPerSession) {
      // Persist for a same-session reconnect (mirrors [bootEphemeral]).
      await _secure.set(SecretKeys.sessionNsec, bech32.encodeNsecBytes(sk));
      await _kv.setString(StorageKeys.autoEphemeralNick, nym);
    }

    return Identity(pubkey: pubkey, privkey: sk, nym: nym);
  }

  /// Sets a new display nym (persisted for the ephemeral session).
  Future<void> setNym(Identity identity, String nym) async {
    identity.nym = nym;
    await _kv.setString(StorageKeys.autoEphemeralNick, nym);
  }
}

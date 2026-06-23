import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/crypto/bech32_codec.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/features/identity/identity_vault.dart';
import 'package:nym_bar/features/identity/nym_identicon.dart';
import 'package:nym_bar/features/identity/panic_wipe.dart';
import 'package:nym_bar/features/shop/shop_controller.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';

void main() {
  // ---------------------------------------------------------------------------
  // 1. Identicon — deterministic per seed, varies by seed.
  // ---------------------------------------------------------------------------
  group('NymIdenticon (generateAvatarSvg port)', () {
    test('same seed -> identical descriptor', () {
      final a = IdenticonSpec.fromSeed('alice#1a2b');
      final b = IdenticonSpec.fromSeed('alice#1a2b');
      expect(a.descriptor, b.descriptor);
    });

    test('different seeds -> different descriptors', () {
      final a = IdenticonSpec.fromSeed('alice#1a2b');
      final b = IdenticonSpec.fromSeed('bob#3c4d');
      expect(a.descriptor, isNot(b.descriptor));
    });

    test('empty/null seed is stable and produces a 5x5 grid', () {
      final a = IdenticonSpec.fromSeed('');
      final b = IdenticonSpec.fromSeed(null);
      expect(a.descriptor, b.descriptor);
      expect(a.cells.length, IdenticonSpec.rows * IdenticonSpec.cols);
    });

    test('grid is horizontally mirrored (col x == col 4-x)', () {
      final s = IdenticonSpec.fromSeed('mirror-check');
      for (var y = 0; y < IdenticonSpec.rows; y++) {
        for (var x = 0; x < IdenticonSpec.cols; x++) {
          final mirror = IdenticonSpec.cols - 1 - x;
          expect(
            s.cells[y * IdenticonSpec.cols + x],
            s.cells[y * IdenticonSpec.cols + mirror],
            reason: 'cell ($x,$y) should mirror ($mirror,$y)',
          );
        }
      }
    });

    test('descriptor varies across many seeds (not all collapse)', () {
      final seen = <String>{};
      for (var i = 0; i < 100; i++) {
        seen.add(IdenticonSpec.fromSeed('seed-$i').descriptor);
      }
      // Expect high uniqueness; allow a tiny margin for rare collisions.
      expect(seen.length, greaterThan(90));
    });
  });

  // ---------------------------------------------------------------------------
  // 2. nsec paste validation (decodeNsec).
  // ---------------------------------------------------------------------------
  group('nsec validation', () {
    test('a freshly-generated valid nsec decodes to 32 bytes', () {
      final priv = generatePrivateKey();
      final nsec = encodeNsecBytes(priv);
      final decoded = decodeNsec(nsec);
      expect(decoded.length, 32);
      expect(decoded, priv);
    });

    test('junk strings are rejected', () {
      for (final junk in ['nsec1junk', 'hello', '', 'npub1abc', '   ']) {
        expect(() => decodeNsec(junk), throwsA(anything),
            reason: '"$junk" should not decode as nsec');
      }
    });

    test('an npub is rejected by decodeNsec (wrong hrp)', () {
      final priv = generatePrivateKey();
      final npub = encodeNpub(getPublicKeyHex(priv));
      expect(() => decodeNsec(npub), throwsFormatException);
    });
  });

  // ---------------------------------------------------------------------------
  // 3. Panic wipe helper clears the injected stores.
  // ---------------------------------------------------------------------------
  group('PanicWipe', () {
    test('clears all three injected stores', () async {
      final prefs = _FakeStore();
      final secure = _FakeStore();
      final cache = _FakeStore();

      final wipe = PanicWipe(prefs: prefs, secure: secure, cache: cache);
      await wipe.wipe();

      expect(prefs.wiped, isTrue);
      expect(secure.wiped, isTrue);
      expect(cache.wiped, isTrue);
    });

    test('a failing store does not abort the others', () async {
      final prefs = _FakeStore();
      final secure = _ThrowingStore();
      final cache = _FakeStore();

      final wipe = PanicWipe(prefs: prefs, secure: secure, cache: cache);
      await wipe.wipe(); // must not throw

      expect(prefs.wiped, isTrue);
      expect(cache.wiped, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // 4. Shop — applying a cosmetic persists active style/flair, reads back.
  // ---------------------------------------------------------------------------
  group('ShopController cosmetics persist', () {
    late KeyValueStore kv;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      kv = await KeyValueStore.open();
    });

    test('activating a style persists nym_active_style and reads back',
        () async {
      final ctrl = ShopController(kv);
      await ctrl.grant('style-matrix');
      await ctrl.toggleStyle('style-matrix');

      expect(kv.getString(StorageKeys.activeStyle), 'style-matrix');

      // A fresh controller reads the persisted active style back.
      final reloaded = ShopController(kv);
      expect(reloaded.state.active.style, 'style-matrix');
    });

    test('activating a flair persists nym_active_flair and reads back',
        () async {
      final ctrl = ShopController(kv);
      await ctrl.grant('flair-crown');
      await ctrl.toggleFlair('flair-crown');

      expect(kv.getString(StorageKeys.activeFlair), 'flair-crown');

      final reloaded = ShopController(kv);
      expect(reloaded.state.active.flair, contains('flair-crown'));
    });

    test('toggling off clears the active key', () async {
      final ctrl = ShopController(kv);
      await ctrl.grant('style-neon');
      await ctrl.toggleStyle('style-neon');
      expect(kv.getString(StorageKeys.activeStyle), 'style-neon');
      await ctrl.toggleStyle('style-neon');
      expect(kv.getString(StorageKeys.activeStyle), isNull);
    });

    test('only one style and one flair active at a time', () async {
      final ctrl = ShopController(kv);
      await ctrl.grant('style-matrix');
      await ctrl.grant('style-neon');
      await ctrl.toggleStyle('style-matrix');
      await ctrl.toggleStyle('style-neon');
      // Switching styles replaces, not accumulates.
      expect(ctrl.state.active.style, 'style-neon');

      await ctrl.grant('flair-crown');
      await ctrl.grant('flair-star');
      await ctrl.toggleFlair('flair-crown');
      await ctrl.toggleFlair('flair-star');
      expect(ctrl.state.active.flair, ['flair-star']);
    });

    test('cannot activate an unowned item', () async {
      final ctrl = ShopController(kv);
      await ctrl.toggleStyle('style-fire'); // not owned
      expect(ctrl.state.active.style, isNull);
    });

    test('owned items persist in the purchases cache', () async {
      final ctrl = ShopController(kv);
      await ctrl.grant('flair-skull', code: 'NYM-${'A' * 32}');
      final reloaded = ShopController(kv);
      expect(reloaded.state.owns('flair-skull'), isTrue);
      expect(reloaded.state.owned['flair-skull']!.code, 'NYM-${'A' * 32}');
    });

    test('recovery-code format validation', () {
      expect(ShopController.isValidRecoveryCode('NYM-${'A' * 32}'), isTrue);
      expect(ShopController.isValidRecoveryCode('nym-${'a' * 32}'), isTrue);
      expect(ShopController.isValidRecoveryCode('NYM-tooshort'), isFalse);
      expect(ShopController.isValidRecoveryCode('garbage'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 5. Identity vault round-trip (PBKDF2 / AES-GCM).
  // ---------------------------------------------------------------------------
  group('IdentityVault', () {
    late KeyValueStore kv;
    late _MemSecure secure;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      kv = await KeyValueStore.open();
      secure = _MemSecure();
    });

    test('enable encrypts secrets, unlock with right password recovers them',
        () async {
      final priv = generatePrivateKey();
      final nsec = encodeNsecBytes(priv);
      await secure.set(SecretKeys.sessionNsec, nsec);

      final vault = IdentityVault(kv, secure.asSecureStore());
      await vault.enable(method: 'password', password: 'hunter2');

      expect(vault.isEnabled, isTrue);
      // Stored value is now ciphertext.
      final stored = secure.map[SecretKeys.sessionNsec]!;
      expect(stored.startsWith('enc:v1:'), isTrue);
      expect(stored, isNot(nsec));

      final recovered = await vault.unlock('hunter2');
      expect(recovered[SecretKeys.sessionNsec], nsec);
    });

    test('unlock with wrong password throws', () async {
      await secure.set(SecretKeys.sessionNsec, 'nsec-placeholder');
      final vault = IdentityVault(kv, secure.asSecureStore());
      await vault.enable(method: 'password', password: 'correct');
      await expectLater(vault.unlock('wrong'), throwsA(anything));
    });

    test('verifyPassword distinguishes right from wrong', () async {
      final vault = IdentityVault(kv, secure.asSecureStore());
      await vault.enable(method: 'pin', password: '1234');
      expect(await vault.verifyPassword('1234'), isTrue);
      expect(await vault.verifyPassword('0000'), isFalse);
    });
  });
}

/// A wipe-target store fake that records whether it was wiped.
class _FakeStore
    implements PanicPrefsStore, PanicSecureStore, PanicCacheStore {
  bool wiped = false;
  @override
  Future<void> wipe() async => wiped = true;
}

/// A wipe-target fake that throws, to prove isolation.
class _ThrowingStore implements PanicSecureStore {
  @override
  Future<void> wipe() async => throw Exception('boom');
}

/// In-memory secure storage used to exercise the vault crypto without the
/// platform keystore. Adapts to a [SecureStoreLike] via a thin subclass.
class _MemSecure {
  final Map<String, String> map = {};

  Future<String?> get(String key) async => map[key];
  Future<void> set(String key, String value) async => map[key] = value;
  Future<void> remove(String key) async => map.remove(key);
  Future<void> wipeAll() async => map.clear();

  /// Returns a [SecureStore] proxy backed by this in-memory map.
  _MemSecureStore asSecureStore() => _MemSecureStore(this);
}

/// SecureStore subclass that delegates to the in-memory map (the real
/// FlutterSecureStorage is never touched in tests).
class _MemSecureStore implements SecureStoreLike {
  _MemSecureStore(this._mem);
  final _MemSecure _mem;
  @override
  Future<String?> get(String key) => _mem.get(key);
  @override
  Future<void> set(String key, String value) => _mem.set(key, value);
  @override
  Future<void> remove(String key) => _mem.remove(key);
  @override
  Future<void> wipeAll() => _mem.wipeAll();
}

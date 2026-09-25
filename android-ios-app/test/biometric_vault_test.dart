import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/identity/biometric_secret_store.dart';
import 'package:nym_bar/features/identity/identity_vault.dart';
import 'package:nym_bar/features/identity/vault_boot_unlock.dart';
import 'package:nym_bar/features/identity/vault_settings_modal.dart'
    show identityVaultProvider;
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';

class _MemSecure implements SecureStoreLike {
  final Map<String, String> map = {};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
  @override
  Future<void> remove(String key) async => map.remove(key);
  @override
  Future<void> wipeAll() async => map.clear();
}

class _FakeBio implements BiometricSecretStore {
  bool available = true;
  bool presence = true;
  bool cancelWrite = false;
  bool cancelRead = false;
  bool failRead = false;
  bool corruptRead = false;
  bool unavailableWrite = false;
  String? stored;
  int prompts = 0;
  int presenceChecks = 0;

  void enrollNewBiometric() => stored = null;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<String?> read() async {
    prompts++;
    if (cancelRead) throw const BiometricCanceled();
    if (failRead) throw Exception('keystore error');
    if (corruptRead) return 'not-the-secret';
    return stored;
  }

  @override
  Future<void> write(String secret) async {
    prompts++;
    if (cancelWrite) throw const BiometricCanceled();
    if (unavailableWrite) throw const BiometricStoreError('unavailable');
    stored = secret;
  }

  @override
  Future<void> delete() async => stored = null;

  @override
  Future<bool> confirmPresence() async {
    presenceChecks++;
    return presence;
  }
}

const _nsecName = 'nym_session_nsec';
const _nsec = 'nsec1thesecret';

Future<KeyValueStore> _kv() async {
  SharedPreferences.setMockInitialValues({});
  return KeyValueStore(await SharedPreferences.getInstance());
}

Future<(IdentityVault, _MemSecure, _FakeBio, KeyValueStore)> _setup(
    {bool escrow = false}) async {
  final kv = await _kv();
  final secure = _MemSecure();
  await secure.set(_nsecName, _nsec);
  final bio = _FakeBio();
  final vault = IdentityVault(kv, secure, escrow: escrow, biometric: bio);
  return (vault, secure, bio, kv);
}

Future<void> _legacyEnable(IdentityVault vault, _MemSecure secure) async {
  const plain = 'bGVnYWN5LWRldmljZS1zZWNyZXQtMzItYnl0ZXMhIQ==';
  await secure.set(IdentityVault.bioSecretName, plain);
  await vault.enable(method: 'biometric', password: plain);
}

Matcher _failure(BiometricVaultFailure f) =>
    isA<BiometricVaultException>().having((e) => e.failure, 'failure', f);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('enabling', () {
    test('keeps the secret only in the biometric store and verifies it',
        () async {
      final (vault, secure, bio, _) = await _setup();

      await vault.enableBiometric();

      expect(vault.isEnabled, isTrue);
      expect(vault.method, 'biometric');
      expect(vault.biometricProtected, isTrue);
      expect(bio.stored, isNotNull);
      expect(bio.prompts, 2);
      expect(secure.map[IdentityVault.bioSecretName], isNull);
      expect(secure.map[_nsecName], startsWith('enc:v1:'));

      final secrets = await vault.unlockBiometric();
      expect(secrets[_nsecName], _nsec);
      expect(bio.prompts, 3);
      expect(bio.presenceChecks, 0);
    });

    test('a canceled prompt leaves the identity unencrypted', () async {
      final (vault, secure, bio, _) = await _setup();
      bio.cancelWrite = true;

      await expectLater(vault.enableBiometric(),
          throwsA(_failure(BiometricVaultFailure.canceled)));

      expect(vault.isEnabled, isFalse);
      expect(vault.biometricProtected, isFalse);
      expect(secure.map[_nsecName], _nsec);
      expect(bio.stored, isNull);
    });

    test('a canceled read-back leaves the identity unencrypted', () async {
      final (vault, secure, bio, _) = await _setup();
      bio.cancelRead = true;

      await expectLater(vault.enableBiometric(),
          throwsA(_failure(BiometricVaultFailure.canceled)));

      expect(vault.isEnabled, isFalse);
      expect(secure.map[_nsecName], _nsec);
      expect(bio.stored, isNull);
    });

    test('a read-back that does not match is refused', () async {
      final (vault, secure, bio, _) = await _setup();
      bio.corruptRead = true;

      await expectLater(vault.enableBiometric(),
          throwsA(_failure(BiometricVaultFailure.verifyFailed)));

      expect(vault.isEnabled, isFalse);
      expect(secure.map[_nsecName], _nsec);
      expect(bio.stored, isNull);
    });

    test('is refused on a device without a strong biometric', () async {
      final (vault, secure, bio, _) = await _setup();
      bio.available = false;

      await expectLater(vault.enableBiometric(),
          throwsA(_failure(BiometricVaultFailure.unavailable)));

      expect(vault.isEnabled, isFalse);
      expect(secure.map[_nsecName], _nsec);
      expect(bio.prompts, 0);
    });
  });

  test('a store that reports no strong biometric is refused as unavailable',
      () async {
    final (vault, secure, bio, _) = await _setup();
    bio.unavailableWrite = true;

    await expectLater(vault.enableBiometric(),
        throwsA(_failure(BiometricVaultFailure.unavailable)));

    expect(vault.isEnabled, isFalse);
    expect(secure.map[_nsecName], _nsec);
  });

  group('platform channel', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];

    void answer(Object? Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(PlatformBiometricSecretStore.channel,
          (call) async {
        calls.add(call);
        return handler(call);
      });
    }

    setUp(calls.clear);
    tearDown(() => messenger.setMockMethodCallHandler(
        PlatformBiometricSecretStore.channel, null));

    test('load returns the secret and passes the prompt text', () async {
      answer((_) => 'the-secret');
      expect(await PlatformBiometricSecretStore().read(), 'the-secret');
      expect(calls.single.method, 'load');
      expect((calls.single.arguments as Map)['cancel'], 'Cancel');
    });

    test('store sends the secret', () async {
      answer((_) => null);
      await PlatformBiometricSecretStore().write('s3cret');
      expect(calls.single.method, 'store');
      expect((calls.single.arguments as Map)['secret'], 's3cret');
    });

    test('cancelled maps to a cancel', () async {
      answer((_) => throw PlatformException(code: 'cancelled'));
      await expectLater(PlatformBiometricSecretStore().read(),
          throwsA(isA<BiometricCanceled>()));
    });

    test('invalidated reads as nothing stored', () async {
      answer((_) => throw PlatformException(code: 'invalidated'));
      expect(await PlatformBiometricSecretStore().read(), isNull);
    });

    test('other codes are store errors', () async {
      answer((_) => throw PlatformException(code: 'unavailable'));
      await expectLater(
          PlatformBiometricSecretStore().write('x'),
          throwsA(isA<BiometricStoreError>()
              .having((e) => e.code, 'code', 'unavailable')));
      answer((_) => throw PlatformException(code: 'failed'));
      await expectLater(PlatformBiometricSecretStore().read(),
          throwsA(isA<BiometricStoreError>()));
    });

    test('erase never throws', () async {
      answer((_) => throw PlatformException(code: 'failed'));
      await PlatformBiometricSecretStore().delete();
      expect(calls.single.method, 'erase');
    });
  });

  group('unlocking', () {
    test('a canceled prompt keeps the vault locked and intact', () async {
      final (vault, _, bio, _) = await _setup();
      await vault.enableBiometric();

      bio.cancelRead = true;
      await expectLater(vault.unlockBiometric(),
          throwsA(_failure(BiometricVaultFailure.canceled)));
      expect(vault.isEnabled, isTrue);
      expect(bio.stored, isNotNull);

      bio.cancelRead = false;
      expect((await vault.unlockBiometric())[_nsecName], _nsec);
    });

    test('a new biometric enrollment is reported and forget resets cleanly',
        () async {
      final (vault, secure, bio, _) = await _setup();
      await vault.enableBiometric();

      bio.enrollNewBiometric();

      await expectLater(vault.unlockBiometric(),
          throwsA(_failure(BiometricVaultFailure.invalidated)));
      expect(secure.map[_nsecName], startsWith('enc:v1:'));
      expect(bio.presenceChecks, 0);

      await vault.reset();
      expect(vault.isEnabled, isFalse);
      expect(vault.biometricProtected, isFalse);
      expect(secure.map[_nsecName], isNull);
    });

    test('a keystore error is a failure, never a fallback to presence',
        () async {
      final (vault, _, bio, _) = await _setup();
      await vault.enableBiometric();
      bio.failRead = true;

      await expectLater(vault.unlockBiometric(),
          throwsA(_failure(BiometricVaultFailure.failed)));
      expect(bio.presenceChecks, 0);
    });
  });

  group('migrating a vault from before the biometric store', () {
    test('moves the plain secret into the biometric store on unlock', () async {
      final (vault, secure, bio, _) = await _setup();
      await _legacyEnable(vault, secure);
      final plain = secure.map[IdentityVault.bioSecretName];

      final secrets = await vault.unlockBiometric();

      expect(secrets[_nsecName], _nsec);
      expect(bio.stored, plain);
      expect(vault.biometricProtected, isTrue);
      expect(secure.map[IdentityVault.bioSecretName], isNull);
      expect(bio.presenceChecks, 0);

      bio.prompts = 0;
      expect((await vault.unlockBiometric())[_nsecName], _nsec);
      expect(bio.prompts, 1);
    });

    test('a failure part-way keeps the plain copy and still unlocks', () async {
      final (vault, secure, bio, _) = await _setup();
      await _legacyEnable(vault, secure);
      final plain = secure.map[IdentityVault.bioSecretName];
      bio.failRead = true;

      final secrets = await vault.unlockBiometric();

      expect(secrets[_nsecName], _nsec);
      expect(bio.presenceChecks, 1);
      expect(vault.biometricProtected, isFalse);
      expect(secure.map[IdentityVault.bioSecretName], plain);

      bio.failRead = false;
      expect((await vault.unlockBiometric())[_nsecName], _nsec);
      expect(vault.biometricProtected, isTrue);
      expect(secure.map[IdentityVault.bioSecretName], isNull);
    });

    test('a canceled migration keeps the plain copy', () async {
      final (vault, secure, bio, _) = await _setup();
      await _legacyEnable(vault, secure);
      final plain = secure.map[IdentityVault.bioSecretName];
      bio.cancelRead = true;

      await expectLater(vault.unlockBiometric(),
          throwsA(_failure(BiometricVaultFailure.canceled)));

      expect(vault.biometricProtected, isFalse);
      expect(secure.map[IdentityVault.bioSecretName], plain);
    });

    test('a device without the biometric store keeps the old behavior',
        () async {
      final (vault, secure, bio, _) = await _setup();
      await _legacyEnable(vault, secure);
      final plain = secure.map[IdentityVault.bioSecretName];
      bio.available = false;

      expect((await vault.unlockBiometric())[_nsecName], _nsec);
      expect(bio.presenceChecks, 1);
      expect(bio.prompts, 0);
      expect(vault.biometricProtected, isFalse);
      expect(secure.map[IdentityVault.bioSecretName], plain);

      bio.presence = false;
      await expectLater(vault.unlockBiometric(),
          throwsA(_failure(BiometricVaultFailure.canceled)));
      expect(secure.map[IdentityVault.bioSecretName], plain);
    });
  });

  test('turning it off decrypts and deletes both copies of the secret',
      () async {
    final (vault, secure, bio, _) = await _setup();
    await vault.enableBiometric();
    await secure.set(IdentityVault.bioSecretName, 'leftover');

    await vault.disableBiometric();

    expect(vault.isEnabled, isFalse);
    expect(secure.map[_nsecName], _nsec);
    expect(bio.stored, isNull);
    expect(secure.map[IdentityVault.bioSecretName], isNull);
  });

  test('a background wake still unlocks from the escrow without a prompt',
      () async {
    final (vault, secure, bio, kv) = await _setup(escrow: true);
    await vault.enableBiometric();
    final prompts = bio.prompts;

    final woken = IdentityVault(kv, secure, escrow: true, biometric: bio);
    final secrets = await woken.unlockForBackgroundWake();

    expect(secrets?[_nsecName], _nsec);
    expect(bio.prompts, prompts);
  });

  group('unlock screen', () {
    Widget host(KeyValueStore kv, IdentityVault vault, Widget child) {
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );
      return ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(kv),
          identityVaultProvider.overrideWithValue(vault),
        ],
        child: MaterialApp(theme: buildNymThemeData(colors), home: child),
      );
    }

    testWidgets('explains a changed enrollment and offers forget',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        StorageKeys.vaultEnabled: '1',
        StorageKeys.vaultMethod: 'biometric',
        StorageKeys.vaultBioProtected: '1',
        StorageKeys.vaultSalt: 'AAAAAAAAAAAAAAAAAAAAAA==',
      });
      final kv = await KeyValueStore.open();
      final bio = _FakeBio();
      final vault = IdentityVault(kv, _MemSecure(), biometric: bio);

      var unlocked = false;
      await tester.pumpWidget(host(
        kv,
        vault,
        VaultBootUnlock(onUnlocked: (_) => unlocked = true, onForget: () {}),
      ));
      await tester.pump();

      await tester.tap(find.text('UNLOCK'));
      await tester.pumpAndSettle();

      expect(unlocked, isFalse);
      expect(
        find.text(
            const BiometricVaultException(BiometricVaultFailure.invalidated)
                .message),
        findsOneWidget,
      );
      expect(find.text('FORGET IDENTITY'), findsOneWidget);
    });
  });
}

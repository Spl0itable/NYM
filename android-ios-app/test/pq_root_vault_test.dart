// The root is identity key material, so it lives where identity key material
// lives (PQ-ROOT-SPEC §5.3): inside the at-rest vault's protected set, and
// cleared by every path that clears the nsec.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/features/identity/identity_vault.dart';
import 'package:nym_bar/features/identity/pq_root.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';

const String _passphrase = 'a-vault-password';

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

Future<(KeyValueStore, _MemSecure, IdentityVault)> _fixture() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final secure = _MemSecure();
  return (kv, secure, IdentityVault(kv, secure));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the root is in the vault\'s protected set', () {
    expect(IdentityVault.vaultKeys, contains(StorageKeys.pqRoot));
    expect(SecretKeys.all, contains(SecretKeys.pqRoot));
    expect(SecretKeys.pqRoot, 'nym_pq_root');
  });

  test('enabling the vault encrypts the stored root', () async {
    final (_, secure, vault) = await _fixture();
    final code = pqRootToCode(pq.pqGenerateRoot());
    await secure.set(SecretKeys.sessionNsec, 'nsec1plaintext');
    await secure.set(SecretKeys.pqRoot, code);

    await vault.enable(method: 'password', password: _passphrase);

    final atRest = await secure.get(SecretKeys.pqRoot);
    expect(atRest, isNotNull);
    expect(atRest!.startsWith('enc:v1:'), isTrue,
        reason: 'an encrypted nsec beside a plaintext root is not '
            'encryption-at-rest');
    expect(atRest, isNot(code));
    expect(atRest.contains(code), isFalse);
    // And the nsec went the same way, so this is not an ordering accident.
    expect((await secure.get(SecretKeys.sessionNsec))!.startsWith('enc:v1:'),
        isTrue);
  });

  test('unlocking returns the root in the clear, so boot can use it', () async {
    final (_, secure, vault) = await _fixture();
    final code = pqRootToCode(pq.pqGenerateRoot());
    await secure.set(SecretKeys.pqRoot, code);
    await vault.enable(method: 'password', password: _passphrase);

    final fresh = IdentityVault(await KeyValueStore.open(), secure);
    final secrets = await fresh.unlock(_passphrase);
    expect(secrets[SecretKeys.pqRoot], code,
        reason: 'with the vault on this is the only source of the plaintext '
            'root; without it boot cannot open its own root-sealed rows');
    expect(pqRootFromCode(secrets[SecretKeys.pqRoot]!), isNotNull);
  });

  test('a root written after boot is encrypted too', () async {
    final (_, secure, vault) = await _fixture();
    await vault.enable(method: 'password', password: _passphrase);
    // enable() leaves the vault unlocked, which is the path a new root takes.
    final code = pqRootToCode(pq.pqGenerateRoot());
    await vault.secretSet(SecretKeys.pqRoot, code);
    expect((await secure.get(SecretKeys.pqRoot))!.startsWith('enc:v1:'), isTrue);
  });

  test('a plaintext root alone raises the encrypt-at-rest prompt', () async {
    final (kv, secure, vault) = await _fixture();
    await secure.set(SecretKeys.pqRoot, pqRootToCode(pq.pqGenerateRoot()));
    expect(await vault.hasUnencryptedSecret(), isTrue);
    await kv.setBool(StorageKeys.encryptAtRestPref, true);
    expect(await vault.shouldPromptEncryptAtRest(), isTrue);
  });

  test('reset clears the root along with the identity', () async {
    final (_, secure, vault) = await _fixture();
    await secure.set(SecretKeys.sessionNsec, 'nsec1plaintext');
    await secure.set(SecretKeys.pqRoot, pqRootToCode(pq.pqGenerateRoot()));
    await vault.enable(method: 'password', password: _passphrase);

    await vault.reset();

    expect(await secure.get(SecretKeys.pqRoot), isNull,
        reason: 'a root outliving its identity is a liability with no owner');
    expect(await secure.get(SecretKeys.sessionNsec), isNull);
  });

  test('disable returns the root to plaintext rather than stranding it',
      () async {
    final (_, secure, vault) = await _fixture();
    final code = pqRootToCode(pq.pqGenerateRoot());
    await secure.set(SecretKeys.pqRoot, code);
    await vault.enable(method: 'password', password: _passphrase);
    await vault.disable(_passphrase);
    expect(await secure.get(SecretKeys.pqRoot), code,
        reason: 'a stranded enc:v1: blob would read as no root at all');
  });

  test('a background wake recovers the root without a human', () async {
    final (_, secure, vault) = await _fixture();
    final code = pqRootToCode(pq.pqGenerateRoot());
    await secure.set(SecretKeys.pqRoot, code);
    await vault.enable(method: 'password', password: _passphrase);

    final woken = IdentityVault(await KeyValueStore.open(), secure);
    final secrets = await woken.unlockForBackgroundWake();
    expect(secrets?[SecretKeys.pqRoot], code);
  });

  // The panic sweep is a keystore-wide wipeAll, which only covers the root
  // while it lives in the secure store rather than in SharedPreferences.
  test('the root is in secure storage, not the key/value store', () async {
    final (kv, secure, _) = await _fixture();
    await secure.set(SecretKeys.pqRoot, pqRootToCode(pq.pqGenerateRoot()));
    expect(kv.getString(StorageKeys.pqRoot), isNull);
    await secure.wipeAll();
    expect(await secure.get(SecretKeys.pqRoot), isNull);
  });

  test('the controller drops the in-memory root on panic and sign-out', () {
    final controller =
        File('lib/state/nostr_controller.dart').readAsStringSync();
    for (final fn in [
      'Future<void> resetAfterPanic() async {',
      'Future<void> signOut() async {',
    ]) {
      final start = controller.indexOf(fn);
      expect(start, greaterThan(-1), reason: fn);
      final end = controller.indexOf('\n  Future<', start + fn.length);
      final body = controller.substring(start, end);
      expect(body.contains('_pqRoot = null;'), isTrue,
          reason: '$fn must not leave the old identity\'s root in memory');
    }
  });
}

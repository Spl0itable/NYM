// The vault escrows its derived key so an iOS background wake can catch up
// without a human to type a password. These pin the properties that make that
// tolerable: it only unlocks for a background wake, it goes through the same
// secure store a panic wipe sweeps, it dies with the vault, and a stale key
// from a changed factor is refused.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/features/identity/identity_vault.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';

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

Future<KeyValueStore> _kv() async {
  SharedPreferences.setMockInitialValues({});
  return KeyValueStore(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a background wake unlocks from the escrow without a password',
      () async {
    final kv = await _kv();
    final secure = _MemSecure();
    await secure.set('nym_session_nsec', 'the-secret');
    final vault = IdentityVault(kv, secure);

    await vault.enable(method: 'password', password: 'hunter2');
    final woken = await vault.unlockForBackgroundWake();
    expect(woken, isNotNull);
    expect(woken!['nym_session_nsec'], 'the-secret');
  });

  test('no escrow means a background wake cannot unlock', () async {
    final kv = await _kv();
    final secure = _MemSecure();
    await secure.set('nym_session_nsec', 'the-secret');
    final vault = IdentityVault(kv, secure);
    await vault.enable(method: 'password', password: 'hunter2');

    await vault.clearBackgroundKey();
    expect(await vault.unlockForBackgroundWake(), isNull);
  });

  test('the escrow lives where a panic wipe sweeps', () async {
    // PanicWipe calls SecureStore.wipeAll(), which deletes every item under the
    // app's Keychain service. The escrow must be in that store — not a separate
    // one — or a panic would leave the vault key behind on the device.
    final kv = await _kv();
    final secure = _MemSecure();
    final vault = IdentityVault(kv, secure);
    await vault.enable(method: 'password', password: 'hunter2');

    expect(secure.map.containsKey('nym_vault_bg_key'), isTrue,
        reason: 'escrow must be written through the shared secure store');
    await secure.wipeAll();
    expect(secure.map, isEmpty);
    expect(await vault.unlockForBackgroundWake(), isNull);
  });

  test('disabling the vault clears the escrow', () async {
    final kv = await _kv();
    final secure = _MemSecure();
    await secure.set('nym_session_nsec', 'the-secret');
    final vault = IdentityVault(kv, secure);
    await vault.enable(method: 'password', password: 'hunter2');

    await vault.disable('hunter2');
    expect(secure.map.containsKey('nym_vault_bg_key'), isFalse);
  });

  test('resetting the vault clears the escrow', () async {
    final kv = await _kv();
    final secure = _MemSecure();
    final vault = IdentityVault(kv, secure);
    await vault.enable(method: 'password', password: 'hunter2');

    await vault.reset();
    expect(secure.map.containsKey('nym_vault_bg_key'), isFalse);
  });

  test('a stale escrow from a changed factor is refused and dropped', () async {
    final kv = await _kv();
    final secure = _MemSecure();
    final vault = IdentityVault(kv, secure);
    await vault.enable(method: 'password', password: 'hunter2');

    // Re-key the vault under a different factor, leaving the old escrow behind.
    final stale = secure.map['nym_vault_bg_key'];
    await vault.disable('hunter2');
    await vault.enable(method: 'password', password: 'different');
    secure.map['nym_vault_bg_key'] = stale!;

    expect(await vault.unlockForBackgroundWake(), isNull);
    expect(secure.map.containsKey('nym_vault_bg_key'), isFalse,
        reason: 'a key that no longer opens the vault should not linger');
  });

  test('a vault that is off never reports a background unlock', () async {
    final kv = await _kv();
    final vault = IdentityVault(kv, _MemSecure());
    expect(kv.getBool(StorageKeys.vaultEnabled), isFalse);
    expect(await vault.unlockForBackgroundWake(), isNull);
  });
}

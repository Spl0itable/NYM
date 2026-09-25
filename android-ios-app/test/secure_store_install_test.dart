import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/mesh/noise/noise_identity.dart';
import 'package:nym_bar/services/storage/cache_store.dart';
import 'package:nym_bar/services/storage/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keychain items stay on this device', () {
    expect(SecureStore.platform.iOptions.toMap()['accessibility'],
        'first_unlock_this_device');
  });

  test('a fresh install clears what an earlier install left behind', () async {
    FlutterSecureStorage.setMockInitialValues(
        {'nym_session_nsec': 'old-nsec', 'nym_mesh_ed25519_seed': 'old'});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    expect(await SecureStore.settleInstall(prefs), isTrue);
    expect(await SecureStore().get('nym_session_nsec'), isNull);
    expect(prefs.containsKey(SecureStore.installedKey), isTrue);

    await SecureStore().set('nym_session_nsec', 'new-nsec');
    expect(await SecureStore.settleInstall(prefs), isFalse);
    expect(await SecureStore().get('nym_session_nsec'), 'new-nsec');
  });

  test('an existing install keeps its keys when it is first marked', () async {
    FlutterSecureStorage.setMockInitialValues({'nym_session_nsec': 'kept'});
    SharedPreferences.setMockInitialValues({'nym_theme': 'dark'});
    final prefs = await SharedPreferences.getInstance();

    expect(await SecureStore.settleInstall(prefs), isFalse);
    expect(await SecureStore().get('nym_session_nsec'), 'kept');
  });

  test('a wipe also removes the mesh identity', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final first = await NoiseIdentity.loadOrCreate();
    await SecureStore().wipeAll();
    final second = await NoiseIdentity.loadOrCreate();
    expect(second.fingerprint, isNot(first.fingerprint));
  });

  test('a database whose key is gone is dropped, a plaintext one is kept',
      () async {
    final dir = await Directory.systemTemp.createTemp('nym_cache');
    final locked = File('${dir.path}/locked.db')
      ..writeAsBytesSync(List<int>.generate(64, (i) => (i * 37) % 256));
    File('${locked.path}-wal').writeAsBytesSync([1, 2, 3]);
    final plain = File('${dir.path}/plain.db')
      ..writeAsStringSync('SQLite format 3\u0000 rest');

    await CacheStore().dropUnreadable(locked.path);
    await CacheStore().dropUnreadable(plain.path);

    expect(locked.existsSync(), isFalse);
    expect(File('${locked.path}-wal').existsSync(), isFalse);
    expect(plain.existsSync(), isTrue);
    await dir.delete(recursive: true);
  });
}

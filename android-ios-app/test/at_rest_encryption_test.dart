import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/features/identity/panic_wipe.dart';
import 'package:nym_bar/services/storage/at_rest_cipher.dart';
import 'package:nym_bar/services/storage/at_rest_wipe.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/services/storage/mesh_file_store.dart';
import 'package:nym_bar/services/storage/sealed_key_value.dart';

class _MemoryKeyStore implements AtRestKeyStore {
  String? value;
  int writes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async {
    writes++;
    value = v;
  }

  @override
  Future<void> delete() async => value = null;
}

class _Flag
    implements
        PanicPrefsStore,
        PanicSecureStore,
        PanicCacheStore,
        PanicFileStore {
  bool wiped = false;
  @override
  Future<void> wipe() async => wiped = true;
}

Future<KeyValueStore> _kv([Map<String, Object> seed = const {}]) async {
  SharedPreferences.setMockInitialValues(seed);
  return KeyValueStore.open();
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nym_at_rest_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('AtRestCipher', () {
    test('string round-trip hides the plaintext', () async {
      final cipher = AtRestCipher(_MemoryKeyStore());
      const plain = '{"g1":{"name":"Secret Club","members":["abc"]}}';
      final sealed = await cipher.encryptString(plain);
      expect(AtRestCipher.isEncryptedString(sealed), isTrue);
      expect(sealed.contains('Secret Club'), isFalse);
      expect(await cipher.decryptString(sealed), plain);
    });

    test('bytes round-trip and fresh nonce per seal', () async {
      final cipher = AtRestCipher(_MemoryKeyStore());
      final plain =
          Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
      final a = await cipher.encryptBytes(plain);
      final b = await cipher.encryptBytes(plain);
      expect(AtRestCipher.isEncryptedBytes(a), isTrue);
      expect(a, isNot(equals(b)));
      expect(await cipher.decryptBytes(a), plain);
      expect(AtRestCipher.isEncryptedBytes(plain), isFalse);
    });

    test('creates the key once and reuses it across instances', () async {
      final keys = _MemoryKeyStore();
      final sealed = await AtRestCipher(keys).encryptString('hello');
      final again = AtRestCipher(keys);
      expect(await again.decryptString(sealed), 'hello');
      expect(keys.writes, 1);
    });

    test('a different or destroyed key cannot open old ciphertext', () async {
      final keys = _MemoryKeyStore();
      final cipher = AtRestCipher(keys);
      final sealed = await cipher.encryptString('hello');
      await cipher.destroyKey();
      expect(keys.value, isNull);
      await expectLater(cipher.decryptString(sealed), throwsA(anything));
    });

    test('the key lives in secure storage under its own name', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final cipher = AtRestCipher(SecureAtRestKeyStore());
      await cipher.encryptString('x');
      const storage = FlutterSecureStorage();
      final stored = await storage.read(key: SecureAtRestKeyStore.keyName);
      expect(base64.decode(stored!).length, 32);
      await cipher.destroyKey();
      expect(await storage.read(key: SecureAtRestKeyStore.keyName), isNull);
    });
  });

  group('SealedKeyValue', () {
    test('writes ciphertext and reads it back', () async {
      final kv = await _kv();
      final store = SealedKeyValue(kv, cipher: AtRestCipher(_MemoryKeyStore()));
      store.write('nym_groups_abc', '{"g":"Secret Club"}');
      await store.idle;
      final raw = kv.getString('nym_groups_abc')!;
      expect(AtRestCipher.isEncryptedString(raw), isTrue);
      expect(raw.contains('Secret Club'), isFalse);
      expect(await store.read('nym_groups_abc'), '{"g":"Secret Club"}');
    });

    test('migrates a legacy plaintext value on first read', () async {
      const legacy = '{"g1":{"name":"Old Group"}}';
      final kv = await _kv({'nym_groups_abc': legacy});
      final keys = _MemoryKeyStore();
      final store = SealedKeyValue(kv, cipher: AtRestCipher(keys));
      expect(await store.read('nym_groups_abc'), legacy);
      await store.idle;
      final raw = kv.getString('nym_groups_abc')!;
      expect(AtRestCipher.isEncryptedString(raw), isTrue);
      expect(raw.contains('Old Group'), isFalse);
      final fresh = SealedKeyValue(kv, cipher: AtRestCipher(keys));
      expect(await fresh.read('nym_groups_abc'), legacy);
    });

    test('an unreadable value reads as missing', () async {
      final kv = await _kv();
      final writer =
          SealedKeyValue(kv, cipher: AtRestCipher(_MemoryKeyStore()));
      writer.write('k', 'v');
      await writer.idle;
      final other = SealedKeyValue(kv, cipher: AtRestCipher(_MemoryKeyStore()));
      expect(await other.read('k'), isNull);
    });

    test('writes nothing while blocked', () async {
      final kv = await _kv();
      final store = SealedKeyValue(kv,
          cipher: AtRestCipher(_MemoryKeyStore()), blocked: () => true);
      store.write('k', 'v');
      await store.idle;
      expect(kv.getString('k'), isNull);
    });
  });

  group('MeshFileStore', () {
    MeshFileStore storeFor(AtRestCipher cipher) =>
        MeshFileStore(cipher: cipher, baseDirectory: () async => tmp);

    test('saves ciphertext and reads plaintext back', () async {
      final store = storeFor(AtRestCipher(_MemoryKeyStore()));
      final plain = Uint8List.fromList(utf8.encode('mesh photo bytes'));
      final path = await store.save('photo 1.jpg', plain);
      expect(path, isNotNull);
      expect(path!.startsWith('${tmp.path}/mesh_files/'), isTrue);
      final onDisk = await File(path).readAsBytes();
      expect(AtRestCipher.isEncryptedBytes(onDisk), isTrue);
      expect(utf8.decode(onDisk, allowMalformed: true).contains('mesh photo'),
          isFalse);
      expect(await store.read(path), plain);
    });

    test('migrates a legacy plaintext file on first read', () async {
      final store = storeFor(AtRestCipher(_MemoryKeyStore()));
      final dir = await store.directory();
      dir.createSync(recursive: true);
      final legacy = File('${dir.path}/1_old.txt');
      final plain = Uint8List.fromList(utf8.encode('old plaintext file'));
      await legacy.writeAsBytes(plain);
      expect(await store.read(legacy.path), plain);
      final onDisk = await legacy.readAsBytes();
      expect(AtRestCipher.isEncryptedBytes(onDisk), isTrue);
      expect(await store.read(legacy.path), plain);
      expect(File('${legacy.path}.sealing').existsSync(), isFalse);
    });

    test('wipe removes the folder', () async {
      final store = storeFor(AtRestCipher(_MemoryKeyStore()));
      await store.save('a.bin', Uint8List.fromList([1, 2, 3]));
      await store.wipe();
      expect((await store.directory()).existsSync(), isFalse);
    });
  });

  test('forgetAtRestData drops group stores, mesh files and the key', () async {
    final kv = await _kv({
      'nym_groups_abc': 'nymenc:v1:xyz',
      'nym_groups_def': 'legacy',
      StorageKeys.pendingGroupInvite: 'keep',
    });
    final keys = _MemoryKeyStore();
    final cipher = AtRestCipher(keys);
    final files = MeshFileStore(cipher: cipher, baseDirectory: () async => tmp);
    await files.save('a.bin', Uint8List.fromList([1, 2, 3]));
    expect(keys.value, isNotNull);

    await forgetAtRestData(kv, cipher: cipher, files: files);

    expect(kv.getString('nym_groups_abc'), isNull);
    expect(kv.getString('nym_groups_def'), isNull);
    expect(kv.getString(StorageKeys.pendingGroupInvite), 'keep');
    expect((await files.directory()).existsSync(), isFalse);
    expect(keys.value, isNull);
  });

  test('panic wipe also wipes the at-rest files store', () async {
    final prefs = _Flag();
    final secure = _Flag();
    final cache = _Flag();
    final files = _Flag();
    await PanicWipe(prefs: prefs, secure: secure, cache: cache, files: files)
        .wipe();
    PanicWipe.inProgress = false;
    expect(files.wiped, isTrue);
    expect(prefs.wiped && secure.wiped && cache.wiped, isTrue);
  });
}

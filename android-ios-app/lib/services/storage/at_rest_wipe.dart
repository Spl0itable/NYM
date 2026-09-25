import '../../core/constants/storage_keys.dart';
import 'at_rest_cipher.dart';
import 'key_value_store.dart';
import 'mesh_file_store.dart';

Future<void> forgetAtRestData(
  KeyValueStore kv, {
  AtRestCipher? cipher,
  MeshFileStore? files,
}) async {
  final sealedKeys = kv.keys
      .where((k) =>
          k.startsWith(StorageKeys.groupStorePrefix) ||
          StorageKeys.sealedPrefs.contains(k))
      .toList();
  for (final key in sealedKeys) {
    try {
      await kv.remove(key);
    } catch (_) {}
  }
  try {
    await (cipher ?? AtRestCipher.instance).destroyKey();
  } catch (_) {}
  try {
    await (files ?? MeshFileStore.instance).wipe();
  } catch (_) {}
}

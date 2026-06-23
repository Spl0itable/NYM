import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores the four identity secrets in the platform keystore (Keychain /
/// Android Keystore), the native equivalent of the PWA key vault
/// (docs/specs/01 §2.2). Names match [SecretKeys].
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  final FlutterSecureStorage _storage;

  Future<String?> get(String key) => _storage.read(key: key);

  Future<void> set(String key, String value) =>
      _storage.write(key: key, value: value);

  Future<void> remove(String key) => _storage.delete(key: key);

  Future<void> wipeAll() => _storage.deleteAll();
}

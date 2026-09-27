import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores the four identity secrets in the platform keystore (Keychain /
/// Android Keystore), the native equivalent of the PWA key vault
/// (docs/specs/01 §2.2). Names match [SecretKeys].
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? platform,
        _sweep = storage ?? _anyAccess;

  static const AndroidOptions _android =
      AndroidOptions(encryptedSharedPreferences: true);

  static const FlutterSecureStorage platform = FlutterSecureStorage(
    aOptions: _android,
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static const FlutterSecureStorage _anyAccess = FlutterSecureStorage(
    aOptions: _android,
    iOptions: IOSOptions(accessibility: null),
  );

  static const String installedKey = 'nym_installed';

  final FlutterSecureStorage _storage;
  final FlutterSecureStorage _sweep;

  Future<String?> get(String key) => _storage.read(key: key);

  Future<void> set(String key, String value) =>
      _storage.write(key: key, value: value);

  Future<void> remove(String key) => _sweep.delete(key: key);

  Future<void> wipeAll() => _sweep.deleteAll();

  static Future<bool> settleInstall(SharedPreferences prefs,
      {FlutterSecureStorage? storage}) async {
    if (prefs.containsKey(installedKey)) return false;
    final fresh = prefs.getKeys().isEmpty;
    if (fresh) {
      try {
        await (storage ?? _anyAccess).deleteAll();
      } catch (_) {}
    }
    await prefs.setString(installedKey, '1');
    return fresh;
  }
}

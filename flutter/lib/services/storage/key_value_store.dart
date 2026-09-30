import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences wrapper mirroring the PWA's localStorage access pattern.
class KeyValueStore {
  KeyValueStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<KeyValueStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return KeyValueStore(prefs);
  }

  String? getString(String key) => _prefs.getString(key);

  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  Future<void> remove(String key) => _prefs.remove(key);

  /// Drops every stored key for the panic wipe; never used on sign-out, which keeps device prefs.
  Future<void> clear() => _prefs.clear();

  bool contains(String key) => _prefs.containsKey(key);

  Set<String> get keys => _prefs.getKeys();

  /// PWA semantics: `localStorage.getItem(k) === 'true'`.
  bool getBool(String key, {bool defaultValue = false}) {
    final v = _prefs.getString(key);
    if (v == null) return defaultValue;
    return v == 'true' || v == '1';
  }

  Future<void> setBool(String key, bool value) =>
      _prefs.setString(key, value ? 'true' : 'false');

  int getInt(String key, {required int defaultValue}) {
    final v = _prefs.getString(key);
    if (v == null) return defaultValue;
    return int.tryParse(v) ?? defaultValue;
  }

  Future<void> setInt(String key, int value) =>
      _prefs.setString(key, value.toString());

  Set<String> getStringSet(String key) {
    final v = _prefs.getString(key);
    if (v == null || v.isEmpty) return <String>{};
    // PWA persists these as JSON arrays.
    final trimmed = v.trim();
    if (trimmed.startsWith('[')) {
      return trimmed
          .substring(1, trimmed.length - 1)
          .split(',')
          .map((s) => s.trim().replaceAll('"', ''))
          .where((s) => s.isNotEmpty)
          .toSet();
    }
    return v.split(',').where((s) => s.isNotEmpty).toSet();
  }
}

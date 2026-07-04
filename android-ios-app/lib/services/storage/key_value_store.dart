import 'package:shared_preferences/shared_preferences.dart';

/// Thin wrapper over SharedPreferences that mirrors the PWA's localStorage
/// access pattern (string get/set/remove, with typed helpers). All Nymchat
/// preference keys (see [StorageKeys]) flow through this.
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

  /// Drops EVERY stored key — the panic path's final
  /// `localStorage.clear()` sweep (panic.js:136). Never used on sign-out,
  /// which keeps device-level prefs like the theme (app.js `signOut` removes
  /// only its explicit key list).
  Future<void> clear() => _prefs.clear();

  bool contains(String key) => _prefs.containsKey(key);

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
      // best-effort parse without importing dart:convert here
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

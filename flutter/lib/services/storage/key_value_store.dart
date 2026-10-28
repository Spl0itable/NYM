import 'package:shared_preferences/shared_preferences.dart';

import 'storage_guard.dart';

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
      guardedSetString(_prefs, key, value);

  static Future<void> guardedSetString(
      SharedPreferences prefs, String key, String value) async {
    final r = await StorageGuard.write(
      key: key,
      value: value,
      lang: _currentLang(prefs),
      set: prefs.setString,
      remove: prefs.remove,
      keys: prefs.getKeys,
      sizeOf: (k) => (prefs.get(k)?.toString() ?? '').length,
    );
    if (!r.ok && r.user) StorageGuard.reportFull(key);
  }

  static String _currentLang(SharedPreferences prefs) {
    try {
      final v = prefs.get('nym_ui_language');
      return v is String ? v : '';
    } catch (_) {
      return '';
    }
  }

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
      guardedSetString(_prefs, key, value ? 'true' : 'false');

  int getInt(String key, {required int defaultValue}) {
    final v = _prefs.getString(key);
    if (v == null) return defaultValue;
    return int.tryParse(v) ?? defaultValue;
  }

  Future<void> setInt(String key, int value) =>
      guardedSetString(_prefs, key, value.toString());

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

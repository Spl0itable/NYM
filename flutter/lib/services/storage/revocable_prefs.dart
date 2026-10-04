import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final sharedPrefsProvider = FutureProvider<SharedPreferences>(
  (ref) => SharedPreferences.getInstance(),
);

class RevocablePrefs implements SharedPreferences {
  RevocablePrefs(this.inner);

  final SharedPreferences inner;
  bool _revoked = false;

  bool get revoked => _revoked;

  void revoke() => _revoked = true;

  @override
  Set<String> getKeys() => _revoked ? <String>{} : inner.getKeys();

  @override
  Object? get(String key) => _revoked ? null : inner.get(key);

  @override
  bool? getBool(String key) => _revoked ? null : inner.getBool(key);

  @override
  int? getInt(String key) => _revoked ? null : inner.getInt(key);

  @override
  double? getDouble(String key) => _revoked ? null : inner.getDouble(key);

  @override
  String? getString(String key) => _revoked ? null : inner.getString(key);

  @override
  bool containsKey(String key) => !_revoked && inner.containsKey(key);

  @override
  List<String>? getStringList(String key) =>
      _revoked ? null : inner.getStringList(key);

  Future<bool> _drop() async => false;

  @override
  Future<bool> setBool(String key, bool value) =>
      _revoked ? _drop() : inner.setBool(key, value);

  @override
  Future<bool> setInt(String key, int value) =>
      _revoked ? _drop() : inner.setInt(key, value);

  @override
  Future<bool> setDouble(String key, double value) =>
      _revoked ? _drop() : inner.setDouble(key, value);

  @override
  Future<bool> setString(String key, String value) =>
      _revoked ? _drop() : inner.setString(key, value);

  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _revoked ? _drop() : inner.setStringList(key, value);

  @override
  Future<bool> remove(String key) => _revoked ? _drop() : inner.remove(key);

  @override
  Future<bool> commit() async => !_revoked;

  @override
  Future<bool> clear() => _revoked ? _drop() : inner.clear();

  @override
  Future<void> reload() => inner.reload();
}

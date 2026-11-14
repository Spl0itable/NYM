import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'revocable_prefs.dart';
import 'storage_guard.dart';

/// SharedPreferences wrapper mirroring the PWA's localStorage access pattern.
class KeyValueStore {
  KeyValueStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<KeyValueStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return KeyValueStore(prefs);
  }

  static final Map<String, _Held> _held = {};
  static Timer? _retry;
  static const Duration retryEvery = Duration(seconds: 30);
  static const Duration settleAtMost = Duration(seconds: 3);
  static int _seq = 0;
  static final List<(int, bool Function(String key))> _cuts = [];
  static final Map<Future<void>, _Flight> _writing = {};

  static List<String> get held => _held.keys.toList();

  static final Map<Object, Iterable<String> Function()> _sessionNeedles = {};
  static final Map<SharedPreferences, Map<String, String>> _sessionOnly = {};

  static void holdSessionKeysFor(
      Object owner, Iterable<String> Function()? needles) {
    if (needles == null) {
      _sessionNeedles.remove(owner);
    } else {
      _sessionNeedles[owner] = needles;
    }
    if (_sessionNeedles.isEmpty) _sessionOnly.clear();
  }

  static bool _namesSession(String key, String value) {
    for (final fn in _sessionNeedles.values.toList()) {
      Iterable<String> list;
      try {
        list = fn();
      } catch (_) {
        continue;
      }
      for (final n in list) {
        if (n.isNotEmpty && (key.contains(n) || value.contains(n))) return true;
      }
    }
    return false;
  }

  static Map<String, String>? sessionOnlyFor(SharedPreferences prefs) =>
      _sessionOnly[prefs];

  static String? heldValue(String key) => _held[key]?.value;

  static SharedPreferences _root(SharedPreferences p) =>
      p is RevocablePrefs ? p.inner : p;

  static bool _dead(SharedPreferences p) => p is RevocablePrefs && p.revoked;

  static void _cut(bool Function(String key) where) {
    _seq++;
    if (_writing.isNotEmpty) _cuts.add((_seq, where));
  }

  static bool _live(String key, int since) {
    for (final (at, where) in _cuts) {
      if (at > since && where(key)) return false;
    }
    return true;
  }

  static Future<void> settle({Duration within = settleAtMost}) async {
    final until = DateTime.now().add(within);
    while (_writing.isNotEmpty) {
      final left = until.difference(DateTime.now());
      if (left <= Duration.zero) return;
      try {
        await Future.wait(_writing.keys.toList()).timeout(left);
      } catch (_) {
        return;
      }
    }
  }

  static void dropHeld([String? key]) {
    _cut(key == null ? (_) => true : (k) => k == key);
    if (key != null) {
      _held.remove(key);
      return;
    }
    _held.clear();
    _retry?.cancel();
    _retry = null;
  }

  static Future<void> flushHeld() async {
    _retry?.cancel();
    _retry = null;
    for (final e in _held.entries.toList()) {
      final h = e.value;
      if (!identical(_held[e.key], h)) continue;
      final r = await _write(
          h.prefs, e.key, h.value, () => identical(_held[e.key], h));
      if (r.ok && identical(_held[e.key], h)) _held.remove(e.key);
    }
    if (_held.isNotEmpty) _arm();
  }

  static Map<String, String> takeHeld(
      SharedPreferences prefs, bool Function(String key) where) {
    final out = <String, String>{};
    final root = _root(prefs);
    for (final e in _held.entries.toList()) {
      if (!identical(e.value.prefs, root) || !where(e.key)) continue;
      out[e.key] = e.value.value;
      _held.remove(e.key);
    }
    for (final f in _writing.values) {
      if (f.stale || !identical(f.prefs, root) || !where(f.key)) continue;
      if (_live(f.key, f.since)) out[f.key] = f.value;
    }
    _cut(where);
    if (_held.isEmpty) {
      _retry?.cancel();
      _retry = null;
    }
    return out;
  }

  static void _arm() {
    _retry ??= Timer(retryEvery, () {
      _retry = null;
      unawaited(flushHeld());
    });
  }

  void releaseSession(Iterable<String> retired) {
    final mem = _sessionOnly.remove(_prefs);
    if (mem == null || mem.isEmpty) return;
    final list = [for (final n in retired) if (n.isNotEmpty) n];
    for (final e in mem.entries) {
      if (list.any((n) => e.key.contains(n) || e.value.contains(n))) continue;
      unawaited(guardedSetString(_prefs, e.key, e.value));
    }
  }

  String? getString(String key) {
    if (_dead(_prefs)) return _prefs.getString(key);
    return _sessionOnly[_prefs]?[key] ?? heldValue(key) ?? _prefs.getString(key);
  }

  Future<void> setString(String key, String value) =>
      guardedSetString(_prefs, key, value);

  static Future<void> guardedSetString(
      SharedPreferences prefs, String key, String value) async {
    if (_dead(prefs)) return;
    if (_sessionNeedles.isNotEmpty && _namesSession(key, value)) {
      (_sessionOnly[prefs] ??= {})[key] = value;
      dropHeld(key);
      final prior = prefs.get(key);
      if (prior != null && _namesSession(key, '$prior')) await prefs.remove(key);
      return;
    }
    _sessionOnly[prefs]?.remove(key);
    final root = _root(prefs);
    final since = _seq;
    final done = Completer<void>();
    for (final f in _writing.values) {
      if (f.key == key && identical(f.prefs, root)) f.stale = true;
    }
    _writing[done.future] = _Flight(root, key, value, since);
    try {
      final r = await _write(prefs, key, value, () => _live(key, since));
      if (!_live(key, since)) return;
      if (r.ok) {
        _held.remove(key);
      } else if (r.user) {
        _held[key] = _Held(root, value);
        _arm();
      }
    } finally {
      _writing.remove(done.future);
      done.complete();
      if (_writing.isEmpty) _cuts.clear();
    }
  }

  static Future<StorageWriteResult> _write(
          SharedPreferences prefs, String key, String value,
          [bool Function()? live]) =>
      StorageGuard.write(
        key: key,
        value: value,
        lang: _currentLang(prefs),
        set: (k, v) {
          if (k == key && live != null && !live()) return true;
          return prefs.setString(k, v);
        },
        remove: prefs.remove,
        keys: prefs.getKeys,
        sizeOf: (k) => (prefs.get(k)?.toString() ?? '').length,
        get: (k) {
          final v = prefs.get(k);
          return v is String ? v : null;
        },
      );

  static String _currentLang(SharedPreferences prefs) {
    try {
      final v = prefs.get('nym_ui_language');
      return v is String ? v : '';
    } catch (_) {
      return '';
    }
  }

  Future<void> remove(String key) {
    if (!_dead(_prefs)) dropHeld(key);
    _sessionOnly[_prefs]?.remove(key);
    return _prefs.remove(key);
  }

  /// Drops every stored key for the panic wipe; never used on sign-out, which keeps device prefs.
  Future<void> clear() {
    if (!_dead(_prefs)) dropHeld();
    _sessionOnly.remove(_prefs);
    return _prefs.clear();
  }

  bool contains(String key) =>
      (!_dead(_prefs) &&
          (_held.containsKey(key) ||
              (_sessionOnly[_prefs]?.containsKey(key) ?? false))) ||
      _prefs.containsKey(key);

  Set<String> get keys {
    final mem = _dead(_prefs) ? null : _sessionOnly[_prefs];
    if (mem == null || mem.isEmpty) return _prefs.getKeys();
    return {..._prefs.getKeys(), ...mem.keys};
  }

  /// PWA semantics: `localStorage.getItem(k) === 'true'`.
  bool getBool(String key, {bool defaultValue = false}) {
    final v = getString(key);
    if (v == null) return defaultValue;
    return v == 'true' || v == '1';
  }

  Future<void> setBool(String key, bool value) =>
      guardedSetString(_prefs, key, value ? 'true' : 'false');

  int getInt(String key, {required int defaultValue}) {
    final v = getString(key);
    if (v == null) return defaultValue;
    return int.tryParse(v) ?? defaultValue;
  }

  Future<void> setInt(String key, int value) =>
      guardedSetString(_prefs, key, value.toString());

  Set<String> getStringSet(String key) {
    final v = getString(key);
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

class _Held {
  _Held(this.prefs, this.value);

  final SharedPreferences prefs;
  final String value;
}

class _Flight {
  _Flight(this.prefs, this.key, this.value, this.since);

  final SharedPreferences prefs;
  final String key;
  final String value;
  final int since;
  bool stale = false;
}

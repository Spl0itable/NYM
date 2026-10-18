import 'dart:async';
import 'dart:convert';

bool syncBlank(Object? v) {
  if (v == null || v == false || v == 0) return true;
  if (v is String) return v.isEmpty;
  if (v is List) return v.isEmpty;
  if (v is Map) return v.values.every(syncBlank);
  return false;
}

Object? _canonOf(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    final byName = {for (final e in v.entries) '${e.key}': e.value};
    return {for (final k in keys) k: _canonOf(byName[k])};
  }
  if (v is List) return [for (final x in v) _canonOf(x)];
  return v;
}

String syncCanon(Object? v) => jsonEncode(_canonOf(v));

bool _scalarSame(Object? a, Object? b) =>
    a is num && b is num ? a == b : a == b;

bool syncCovers(Object? have, Object? want) {
  if (want == null) return true;
  if (have == null) return syncBlank(want);
  if (want is Map) {
    if (have is! Map) return false;
    for (final e in want.entries) {
      if (!syncCovers(have[e.key], e.value)) return false;
    }
    return true;
  }
  if (want is List) {
    if (have is! List) return false;
    Set<String>? canon;
    for (final x in want) {
      canon ??= {for (final y in have) syncCanon(y)};
      if (canon.contains(syncCanon(x))) continue;
      if (x is Map || x is List) {
        if (have.any((y) => syncCovers(y, x))) continue;
        return false;
      }
      if (!have.any((y) => _scalarSame(y, x))) return false;
    }
    return true;
  }
  return _scalarSame(have, want);
}

bool syncSame(Object? a, Object? b) => syncCovers(a, b) && syncCovers(b, a);

enum SyncRowMode { snapshot, gated }

class SyncRowLedger {
  SyncRowLedger(this.pubkey, {String? Function()? read, this.write}) {
    final raw = read?.call();
    if (raw == null || raw.isEmpty) return;
    try {
      final m = jsonDecode(raw);
      if (m is! Map || m['pk'] != pubkey) return;
      void fill(Object? src, Map<String, String> into) {
        if (src is! Map) return;
        src.forEach((k, v) {
          if (k is String && v is String) into[k] = v;
        });
      }

      fill(m['s'], _synced);
      fill(m['d'], _d1);
      final at = m['ua'];
      if (at is num) unsentAt = at.toInt();
      final rows = m['ur'];
      if (rows is List) unsentRows.addAll(rows.whereType<String>());
    } catch (_) {}
  }

  static const String kvKey = 'nym_sync_rows';
  static const int cap = 4000;

  final String pubkey;
  final void Function(String value)? write;
  final Map<String, String> _synced = {};
  final Map<String, String> _d1 = {};
  int unsentAt = 0;
  final Set<String> unsentRows = {};
  bool _saveQueued = false;

  String? synced(String category) => _synced[category];

  String? d1(String category) => _d1[category];

  String? d1Mode(String category) {
    final v = _d1[category];
    if (v == null) return null;
    final i = v.indexOf(':');
    return i < 0 ? null : v.substring(0, i);
  }

  String? d1Hash(String category) {
    final v = _d1[category];
    if (v == null) return null;
    final i = v.indexOf(':');
    return i < 0 ? v : v.substring(i + 1);
  }

  bool unsent(String dTag) => unsentAt > 0 || unsentRows.contains(dTag);

  static void _put(Map<String, String> m, String k, String v) {
    m.remove(k);
    m[k] = v;
    while (m.length > cap) {
      m.remove(m.keys.first);
    }
  }

  void noteSynced(String category, String hash) {
    if (_synced[category] == hash) return;
    _put(_synced, category, hash);
    _queueSave();
  }

  void noteWritten(String category, String hash, String mode, String d1Hash,
      String dTag) {
    _put(_synced, category, hash);
    _put(_d1, category, '$mode:$d1Hash');
    unsentRows.remove(dTag);
    _queueSave();
  }

  bool noteRead(String category, String mode, String d1Hash) {
    final next = '$mode:$d1Hash';
    if (_d1[category] == next) return false;
    _put(_d1, category, next);
    _queueSave();
    return true;
  }

  void forgetSynced(String category) {
    if (_synced.remove(category) != null) _queueSave();
  }

  void forgetRow(String category) {
    final a = _synced.remove(category);
    final b = _d1.remove(category);
    if (a != null || b != null) _queueSave();
  }

  void clearSynced() {
    if (_synced.isEmpty) return;
    _synced.clear();
    _queueSave();
  }

  int _gen = 0;

  int get unsentGen => _gen;

  void markUnsent(int nowMs) {
    _gen++;
    if (unsentAt > 0) return;
    unsentAt = nowMs > 0 ? nowMs : 1;
    _queueSave();
  }

  void markUnsentRow(String dTag) {
    if (unsentRows.add(dTag)) _queueSave();
  }

  void flushDone(int gen) {
    if (gen != _gen || unsentAt == 0) return;
    unsentAt = 0;
    _queueSave();
  }

  String encode() => jsonEncode({
        'pk': pubkey,
        's': _synced,
        'd': _d1,
        if (unsentAt > 0) 'ua': unsentAt,
        if (unsentRows.isNotEmpty) 'ur': unsentRows.toList()..sort(),
      });

  void _queueSave() {
    final w = write;
    if (w == null || _saveQueued) return;
    _saveQueued = true;
    scheduleMicrotask(() {
      _saveQueued = false;
      try {
        w(encode());
      } catch (_) {}
    });
  }

  void saveNow() {
    final w = write;
    if (w == null) return;
    _saveQueued = false;
    try {
      w(encode());
    } catch (_) {}
  }
}

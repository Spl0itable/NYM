import 'dart:convert';

import '../../core/constants/storage_keys.dart';
import '../../services/storage/key_value_store.dart';
import 'pref_stamps.dart';
import 'sync_merge.dart';

class SetStamps {
  const SetStamps._();

  static const String storeKey = 'nym_set_sync';

  static Map<String, Object?> read(KeyValueStore kv) {
    try {
      final raw = jsonDecode(kv.getString(storeKey) ?? '{}');
      if (raw is Map) return {for (final e in raw.entries) '${e.key}': e.value};
    } catch (_) {}
    return <String, Object?>{};
  }

  static void write(KeyValueStore kv, Map<String, Object?> states) {
    final out = <String, Object?>{
      for (final e in states.entries)
        e.key: e.value is SetState ? (e.value as SetState).toJson() : e.value,
    };
    final json = jsonEncode(out);
    if (kv.getString(storeKey) == json) return;
    kv.setString(storeKey, json);
  }

  static Map<String, SetState> observe(
      KeyValueStore kv, Map<String, List<dynamic>> lists, int now) {
    final prev = read(kv);
    final next = <String, SetState>{
      for (final name in kSyncedSets.keys)
        name: setObserve(prev[name], name, lists[name] ?? const [], now),
    };
    write(kv, next);
    return next;
  }

  static void adopt(KeyValueStore kv, Map<String, SetState> states,
      Map<String, List<dynamic>> lists, int now) {
    if (states.isEmpty) return;
    final cur = read(kv);
    states.forEach((name, st) {
      cur[name] = setAdopt(st, name, lists[name] ?? const [], now);
    });
    write(kv, cur);
  }
}

class ColStamps {
  const ColStamps._();

  static const String storeKey = 'nym_columns_set';

  static Map<String, dynamic>? read(KeyValueStore kv) {
    try {
      final raw = jsonDecode(kv.getString(storeKey) ?? 'null');
      if (raw is Map) return {for (final e in raw.entries) '${e.key}': e.value};
    } catch (_) {}
    return null;
  }

  static void write(KeyValueStore kv, ColState st) {
    final json = jsonEncode(st.toJson());
    if (kv.getString(storeKey) == json) return;
    kv.setString(storeKey, json);
  }

  static List<dynamic> layout(KeyValueStore kv) {
    try {
      final v = jsonDecode(kv.getString(StorageKeys.columnsLayout) ?? '[]');
      return v is List ? v : const [];
    } catch (_) {
      return const [];
    }
  }

  static ColState observe(KeyValueStore kv, List<dynamic> list, int now, int stamp) {
    final st = colObserve(read(kv), list, now, 0, stamp);
    write(kv, st);
    return st;
  }

  static void ensure(KeyValueStore kv, int now) {
    if (read(kv) != null) return;
    write(
        kv,
        colObserve(null, layout(kv), now, 0,
            PrefStamps.read(kv)['columnsLayout'] ?? 0));
  }

  static void saveLayout(KeyValueStore kv, String json) {
    final now = DateTime.now().millisecondsSinceEpoch;
    ensure(kv, now);
    if (json != (kv.getString(StorageKeys.columnsLayout) ?? '[]')) {
      PrefStamps.touch(kv, 'columnsLayout');
    }
    kv.setString(StorageKeys.columnsLayout, json);
    observe(kv, layout(kv), now, PrefStamps.read(kv)['columnsLayout'] ?? 0);
  }

  static void reset(KeyValueStore kv, int now) =>
      write(kv, colObserve(read(kv), const [], now, now, now));
}

import 'dart:convert';

import '../../core/constants/storage_keys.dart';
import '../../services/storage/key_value_store.dart';
import 'sync_merge.dart';

class PrefStamps {
  const PrefStamps._();

  static const String storeKey = 'nym_pref_sync_ts';

  static Map<String, int> read(KeyValueStore kv) {
    Map<String, int> m;
    try {
      m = tsMapNorm(jsonDecode(kv.getString(storeKey) ?? '{}'));
    } catch (_) {
      m = <String, int>{};
    }
    return _withEarlierChoices(kv, m);
  }

  static Map<String, int> _withEarlierChoices(
      KeyValueStore kv, Map<String, int> m) {
    try {
      if ((m['botProModel'] ?? 0) <= 0 &&
          (kv.getString(StorageKeys.botpmProModel) ?? '').isNotEmpty) {
        m['botProModel'] = 1;
      }
      if ((m['streetDetail'] ?? 0) <= 0 &&
          kv.getString(StorageKeys.streetDetail) == '0') {
        m['streetDetail'] = 1;
      }
      if ((m['columnsLayout'] ?? 0) <= 0 &&
          _hasLayout(kv.getString(StorageKeys.columnsLayout))) {
        m['columnsLayout'] = 1;
      }
    } catch (_) {}
    return m;
  }

  static bool _hasLayout(String? raw) {
    if (raw == null || raw.isEmpty) return false;
    try {
      final v = jsonDecode(raw);
      return v is List && v.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static int get(KeyValueStore kv, String name) => read(kv)[name] ?? 0;

  static void set(KeyValueStore kv, String name, int ts) {
    final m = read(kv);
    if (ts > 0) {
      m[name] = ts;
    } else {
      m.remove(name);
    }
    kv.setString(storeKey, jsonEncode(m));
  }

  static void touch(KeyValueStore kv, String name, [int? nowMs]) =>
      set(kv, name, nowMs ?? DateTime.now().millisecondsSinceEpoch);

  static bool take(KeyValueStore kv, String name, Object? remoteTs) =>
      prefTake(get(kv, name), remoteTs);
}

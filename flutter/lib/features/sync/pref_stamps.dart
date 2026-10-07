import 'dart:convert';

import '../../services/storage/key_value_store.dart';
import 'sync_merge.dart';

class PrefStamps {
  const PrefStamps._();

  static const String storeKey = 'nym_pref_sync_ts';

  static Map<String, int> read(KeyValueStore kv) {
    try {
      return tsMapNorm(jsonDecode(kv.getString(storeKey) ?? '{}'));
    } catch (_) {
      return <String, int>{};
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

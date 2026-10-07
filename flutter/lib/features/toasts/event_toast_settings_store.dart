import 'dart:convert';

import '../../core/constants/storage_keys.dart';
import '../../services/storage/key_value_store.dart';
import 'event_toasts.dart';

EventToastSettings readEventToastSettings(KeyValueStore kv) {
  final raw = kv.getString(StorageKeys.eventToasts);
  if (raw == null || raw.isEmpty) return EventToasts.defaults;
  try {
    return EventToastSettings.normalize(jsonDecode(raw));
  } catch (_) {
    return EventToasts.defaults;
  }
}

Future<void> writeEventToastSettings(KeyValueStore kv, EventToastSettings s) =>
    kv.setString(StorageKeys.eventToasts, jsonEncode(s.toJson()));

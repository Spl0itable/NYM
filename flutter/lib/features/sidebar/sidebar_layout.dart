import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/nostr_controller.dart' show bootEpochProvider;
import '../../state/settings_provider.dart';

const List<String> kSidebarSections = ['channels', 'pms', 'nyms'];

List<String> decodeSidebarIds(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) return [for (final e in decoded) e.toString()];
  } catch (_) {
    return [
      for (final s in raw.split(','))
        if (s.trim().isNotEmpty) s.trim(),
    ];
  }
  return const [];
}

List<String> normalizeSidebarOrder(Iterable<String> ids) {
  final next = <String>[];
  for (final id in ids) {
    if (kSidebarSections.contains(id) && !next.contains(id)) next.add(id);
  }
  for (final id in kSidebarSections) {
    if (!next.contains(id)) next.add(id);
  }
  return List.unmodifiable(next);
}

class SidebarSectionOrder extends StateNotifier<List<String>> {
  SidebarSectionOrder(this._kv, this._push)
      : super(normalizeSidebarOrder(
            decodeSidebarIds(_kv.getString(StorageKeys.sidebarSectionOrder))));

  final KeyValueStore _kv;
  final void Function() _push;

  void move(String id, int delta) {
    final i = state.indexOf(id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= state.length) return;
    final next = List.of(state)
      ..removeAt(i)
      ..insert(j, id);
    _kv.setString(StorageKeys.sidebarSectionOrder, jsonEncode(next));
    state = List.unmodifiable(next);
    _push();
  }

  List<String> get current => state;

  void setOrder(List<String> ids) {
    final next = normalizeSidebarOrder(ids);
    if (listEquals(next, state)) return;
    _kv.setString(StorageKeys.sidebarSectionOrder, jsonEncode(next));
    state = next;
    _push();
  }

  void applyRemote(List<String> ids) {
    _kv.setString(StorageKeys.sidebarSectionOrder, jsonEncode(ids));
    final next = normalizeSidebarOrder(ids);
    if (!listEquals(next, state)) state = next;
  }
}

final sidebarSectionOrderProvider =
    StateNotifierProvider<SidebarSectionOrder, List<String>>((ref) {
  ref.watch(bootEpochProvider);
  final kv = ref.watch(keyValueStoreProvider);
  return SidebarSectionOrder(
      kv,
      () => ref
          .read(settingsProvider.notifier)
          .notePrefChanged('sidebarSectionOrder'));
});

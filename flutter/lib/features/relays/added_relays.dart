import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/relays.dart';
import '../../core/constants/storage_keys.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/settings_provider.dart';
import '../sync/pref_stamps.dart';
import 'blocked_relays.dart';
import 'relay_add.dart';

class AddedRelaysController extends StateNotifier<List<String>> {
  AddedRelaysController(this._kv, {Iterable<String> blocked = const []})
      : _blocked = blocked.toSet(),
        super(const []) {
    state = _normalized();
  }

  final KeyValueStore _kv;
  Set<String> _blocked;

  void Function()? onLocalChange;

  static const List<String> _defaults = RelayConfig.defaultRelays;

  int get cap => RelayAdd.cap(_defaults);

  List<Object?> _stored() {
    try {
      final raw = _kv.getString(StorageKeys.addedRelays);
      if (raw == null || raw.isEmpty) return const [];
      final v = jsonDecode(raw);
      return v is List ? v : const [];
    } catch (_) {
      return const [];
    }
  }

  List<String> get all => RelayAdd.norm(_stored(), defaults: _defaults);

  List<String> _normalized() =>
      RelayAdd.listed(_stored(), defaults: _defaults, blocked: _blocked);

  List<String> get active =>
      RelayAdd.inUse(_stored(), defaults: _defaults, blocked: _blocked);

  bool isAdded(String url) => state.contains(RelayAdd.normalize(url).url ?? url);

  bool overCap(String url) {
    final u = RelayAdd.normalize(url).url ?? url;
    return state.contains(u) && !active.contains(u);
  }

  bool get off {
    if (_kv.getString(StorageKeys.nostrLoginMethod) != null) return false;
    final mode = _kv.getString(StorageKeys.keypairMode) ??
        (_kv.getBool(StorageKeys.randomKeypairPerSession)
            ? 'random'
            : 'persistent');
    return mode == 'random' || mode == 'hardcore';
  }

  List<String> get inUse => off ? const <String>[] : active;

  RelayAddCheck check(String input) => RelayAdd.check(input,
      defaults: _defaults, added: all, blocked: _blocked, keypair: off);

  String add(String input) {
    final r = check(input);
    if (r.status != 'ok') return r.status;
    _write(RelayAdd.add(all, r.url!, defaults: _defaults, blocked: _blocked));
    _localChange();
    return 'ok';
  }

  bool remove(String url) {
    final before = all;
    final next = RelayAdd.remove(before, url);
    if (next.length == before.length) return false;
    _write(next);
    _localChange();
    return true;
  }

  void applySynced(Object? list, int ts) {
    _write(RelayAdd.norm(list, defaults: _defaults));
    PrefStamps.set(_kv, RelayAdd.syncKey, ts);
  }

  void setBlocked(Iterable<String> blocked, {bool local = false}) {
    final before = _blocked;
    _blocked = blocked.toSet();
    final back = before.difference(_blocked);
    if (back.isNotEmpty) {
      final stored = all;
      final next = RelayAdd.restore(stored, back,
          defaults: _defaults, blocked: _blocked);
      if (jsonEncode(next) != jsonEncode(stored)) {
        _write(next);
        if (local) _localChange();
        return;
      }
    }
    _refresh();
  }

  void _localChange() {
    PrefStamps.touch(_kv, RelayAdd.syncKey);
    onLocalChange?.call();
  }

  void _write(List<String> next) {
    try {
      _kv.setString(StorageKeys.addedRelays, jsonEncode(next));
    } catch (_) {}
    _refresh();
  }

  void _refresh() {
    final list = _normalized();
    if (list.length != state.length ||
        !List.generate(list.length, (i) => list[i] == state[i]).every((x) => x)) {
      state = list;
    }
  }
}

final StateNotifierProvider<AddedRelaysController, List<String>>
    addedRelaysProvider =
    StateNotifierProvider<AddedRelaysController, List<String>>((ref) {
  final c = AddedRelaysController(ref.read(keyValueStoreProvider),
      blocked: ref.read(blockedRelaysProvider));
  ref.listen<List<String>>(
      blockedRelaysProvider,
      (_, next) => c.setBlocked(next,
          local: ref.read(blockedRelaysProvider.notifier).changingLocally));
  return c;
});

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/settings_provider.dart';
import 'relay_block.dart';

class BlockedRelaysController extends StateNotifier<List<String>> {
  BlockedRelaysController(this._kv, {int Function()? now})
      : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        super(const []) {
    _state = RelayBlock.norm(_read(), _now());
    state = RelayBlock.list(_state);
  }

  final KeyValueStore _kv;
  final int Function() _now;
  Map<String, Map<String, int>> _state = const {'items': {}, 'removed': {}};

  void Function()? onLocalChange;

  Object? _read() {
    try {
      final raw = _kv.getString(StorageKeys.blockedRelays);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Set<String> get blockedSet => state.toSet();

  bool isBlocked(String url) => RelayBlock.isBlocked(blockedSet, url);

  Map<String, Map<String, int>> forSync() => RelayBlock.norm(_state, _now());

  String guard(String url, {String? signer}) =>
      RelayBlock.guard(url, blocked: blockedSet, signer: signer);

  String block(String url, {String? signer, bool confirmed = false}) {
    final why = guard(url, signer: signer);
    if (why != 'ok' && !(why == 'signer' && confirmed)) return why;
    _set(RelayBlock.block(_state, url, _now()));
    onLocalChange?.call();
    return 'blocked';
  }

  bool unblock(String url) {
    if (!isBlocked(url)) return false;
    _set(RelayBlock.unblock(_state, url, _now()));
    onLocalChange?.call();
    return true;
  }

  bool applySynced(Object? remote) {
    final now = _now();
    final merged =
        RelayBlock.keepReader(RelayBlock.merge(_state, remote, now), now);
    final behind =
        jsonEncode(merged) != jsonEncode(RelayBlock.norm(remote, now));
    _set(merged);
    return behind;
  }

  void reset() => _set(const {'items': {}, 'removed': {}});

  void _set(Map<String, Map<String, int>> next) {
    _state = next;
    try {
      _kv.setString(StorageKeys.blockedRelays, jsonEncode(next));
    } catch (_) {}
    final list = RelayBlock.list(next);
    if (list.length != state.length || !list.every(state.contains)) {
      state = list;
    }
  }
}

final StateNotifierProvider<BlockedRelaysController, List<String>>
    blockedRelaysProvider =
    StateNotifierProvider<BlockedRelaysController, List<String>>(
  (ref) => BlockedRelaysController(ref.read(keyValueStoreProvider)),
);

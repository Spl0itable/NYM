import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/storage/key_value_store.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../chat_lock/chat_lock_providers.dart';
import '../sync/pref_stamps.dart';
import '../sync/sync_merge.dart';
import 'call_history.dart';

class CallHistoryKeys {
  static const String history = 'nym_call_history';
  static const String keep = 'nym_keep_call_history';
  static const String cleared = 'nym_call_history_cleared';
}

class CallHistoryController extends StateNotifier<CallHistoryStore> {
  CallHistoryController(this._kv, this.owner, [this._onLocalChange])
      : super(owner.isEmpty
            ? CallHistory.empty('')
            : CallHistory.decode(_kv.getString(CallHistoryKeys.history), owner));

  final KeyValueStore _kv;
  final String owner;
  final void Function()? _onLocalChange;

  bool get keep => _kv.getString(CallHistoryKeys.keep) != 'off';

  int get missed => CallHistory.missedCount(state);

  String get _clearedKey => '${CallHistoryKeys.cleared}:$owner';

  int get clearedAt => _kv.getInt(_clearedKey, defaultValue: 0);

  void _changed() {
    final cb = _onLocalChange;
    if (cb != null) cb();
  }

  void _save(CallHistoryStore next) {
    state = next;
    if (next.items.isEmpty && next.seen == 0) {
      _kv.remove(CallHistoryKeys.history);
    } else {
      _kv.setString(CallHistoryKeys.history, CallHistory.encode(next));
    }
  }

  void record(CallRecord rec) {
    if (owner.isEmpty || !keep) return;
    _save(CallHistory.upsert(state, rec));
    _changed();
  }

  void markSeen([int? nowMs]) {
    if (owner.isEmpty || CallHistory.missedCount(state) == 0) return;
    _save(CallHistory.markSeen(
        state, nowMs ?? DateTime.now().millisecondsSinceEpoch));
    _changed();
  }

  void answeredElsewhere(String callId) {
    if (owner.isEmpty) return;
    for (final r in state.items) {
      if (r.id == callId && r.missed) {
        _save(CallHistory.upsert(state, r.copyWith(missed: false)));
        _changed();
        return;
      }
    }
  }

  void _clearLocal([int? nowMs]) {
    if (owner.isNotEmpty) {
      final at = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      if (at > clearedAt) _kv.setInt(_clearedKey, at);
    }
    state = CallHistory.empty(owner);
    _kv.remove(CallHistoryKeys.history);
  }

  void clear([int? nowMs]) {
    _clearLocal(nowMs);
    _changed();
  }

  int get keepTs => PrefStamps.get(_kv, 'keepCallHistory');

  void setKeep(bool on, {int? syncedTs}) {
    final was = keep;
    if (on) {
      _kv.remove(CallHistoryKeys.keep);
      if (!was && owner.isNotEmpty) {
        final at = (syncedTs != null && syncedTs > 0)
            ? syncedTs
            : DateTime.now().millisecondsSinceEpoch;
        if (at > clearedAt) _kv.setInt(_clearedKey, at);
      }
    } else {
      _kv.setString(CallHistoryKeys.keep, 'off');
      if (was || state.items.isNotEmpty) _clearLocal();
    }
    state = CallHistoryStore(
        owner: state.owner, seen: state.seen, items: state.items);
    if (syncedTs != null) {
      PrefStamps.set(_kv, 'keepCallHistory', syncedTs);
    } else {
      PrefStamps.touch(_kv, 'keepCallHistory');
      _changed();
    }
  }

  Map<String, dynamic>? syncPayload() {
    if (owner.isEmpty) return null;
    if (!keep) return {'on': false, 'clearedAt': clearedAt};
    return {
      'on': true,
      ...CallsSync(clearedAt, state.seen, state.items).toJson(),
      'keepTs': keepTs,
    };
  }

  String reconcileRow(Object? row) {
    final act = callsRowAction(keep, keepTs, row);
    if ((act == 'clear' || act == 'delete') &&
        (state.items.isNotEmpty || state.seen != 0)) {
      _clearLocal();
    }
    return act;
  }

  void applySynced(Object? raw) {
    if (owner.isEmpty || raw is! Map) return;
    final remote = callsNorm(raw);
    if (remote.clearedAt > clearedAt) _kv.setInt(_clearedKey, remote.clearedAt);
    if (!keep) return;
    final merged = callsMerge(
        CallsSync(clearedAt, state.seen, state.items), remote);
    final next = CallHistoryStore(
        owner: owner, seen: merged.seen, items: merged.items);
    if (CallHistory.encode(next) != CallHistory.encode(state)) _save(next);
  }

  void forget() {
    state = CallHistory.empty(owner);
  }
}

final callHistoryProvider =
    StateNotifierProvider<CallHistoryController, CallHistoryStore>((ref) {
  final kv = ref.watch(keyValueStoreProvider);
  final owner = ref.watch(appStateProvider.select((s) => s.selfPubkey));
  return CallHistoryController(kv, owner, () {
    try {
      ref.read(settingsProvider.notifier).notifySyncedChange();
    } catch (_) {}
  });
});

final callHistoryHiddenProvider =
    Provider<bool Function(CallRecord r)>((ref) {
  ref.watch(chatLockRevisionProvider);
  final lock = ref.watch(chatLockProvider);
  ref.watch(contentFilterRevisionProvider);
  final app = ref.read(appStateProvider);
  return (r) {
    if (r.group.isEmpty && r.peer.isNotEmpty && app.isPersonHidden(r.peer)) {
      return true;
    }
    try {
      return lock.notificationIsLocked(
          'call', r.group.isNotEmpty ? r.group : r.peer, r.peer);
    } catch (_) {
      return false;
    }
  };
});

final callHistoryVisibleProvider = Provider<List<CallRecord>>((ref) {
  return CallHistory.visible(
      ref.watch(callHistoryProvider), ref.watch(callHistoryHiddenProvider));
});

final callHistoryMissedProvider = Provider<int>((ref) {
  return CallHistory.missedCount(
      ref.watch(callHistoryProvider), ref.watch(callHistoryHiddenProvider));
});

const String kKeepCallHistoryHint =
    'Keep a list of your recent calls. It syncs encrypted to your other devices signed in with this identity, and each identity has its own list. Turning this off deletes the list on every device.';

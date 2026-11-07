import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../services/storage/key_value_store.dart';
import '../../services/storage/sealed_key_value.dart';
import 'folders.dart';

typedef FoldersPublish = Future<({bool ok, bool changed})> Function(
    Map<String, dynamic> state, bool ping);

class SidebarFoldersHooks {
  const SidebarFoldersHooks({
    required this.selfPubkey,
    required this.syncAllowed,
    required this.online,
    required this.hydrated,
    this.switching,
    this.publish,
    this.onChanged,
    this.onCollapse,
    this.now,
  });

  final String Function() selfPubkey;
  final bool Function() syncAllowed;
  final bool Function() online;
  final bool Function() hydrated;
  final bool Function()? switching;
  final FoldersPublish? publish;
  final void Function()? onChanged;
  final void Function()? onCollapse;
  final int Function()? now;
}

class SidebarFoldersService {
  SidebarFoldersService(this._kv, this._sealed, this.hooks);

  static const Duration syncDebounce = Duration(milliseconds: 1500);
  static const Duration joinWait = Duration(seconds: 8);

  final KeyValueStore _kv;
  final SealedKeyValue _sealed;
  final SidebarFoldersHooks hooks;

  FoldersState? _mem;
  Set<String> _memCollapsed = <String>{};
  FoldersState? _cache;
  String _cachePk = '';
  FoldersState? _queued;
  String _queuedPk = '';
  Future<bool>? _loading;
  String _loadingPk = '';
  int _lastTry = 0;
  int _rev = 0;
  bool _syncing = false;
  bool _resync = false;
  bool _join = false;
  Timer? _syncTimer;
  Timer? _joinTimer;
  bool _disposed = false;

  int get _nowMs => hooks.now?.call() ?? DateTime.now().millisecondsSinceEpoch;

  bool get memoryOnly => !hooks.syncAllowed();

  String get _pk => hooks.selfPubkey();

  String _stateKey(String pk) => '${FoldersKeys.state}$pk';
  String _pendingKey(String pk) => '${FoldersKeys.pending}$pk';
  String _collapsedKey(String pk) => '${FoldersKeys.collapsed}$pk';

  bool get ready {
    if (memoryOnly) return true;
    final pk = _pk;
    return pk.isNotEmpty && _cache != null && _cachePk == pk;
  }

  FoldersState get state {
    if (memoryOnly) return _mem ??= emptyFolders();
    if (ready) return _cache!;
    _kick();
    return emptyFolders();
  }

  bool get hasFolders => ready && state.folders.isNotEmpty;

  void _kick() {
    final pk = _pk;
    if (pk.isEmpty || _disposed) return;
    if (_loading != null && _loadingPk == pk) return;
    final now = _nowMs;
    if (_loadingPk == pk && now - _lastTry < 5000) return;
    _lastTry = now;
    unawaited(load());
  }

  Future<bool> load() {
    if (memoryOnly) {
      _mem ??= emptyFolders();
      return Future.value(true);
    }
    final pk = _pk;
    if (pk.isEmpty) return Future.value(false);
    if (ready) return Future.value(true);
    final running = _loading;
    if (running != null && _loadingPk == pk) return running;
    _loadingPk = pk;
    final f = _load(pk);
    _loading = f;
    return f.whenComplete(() {
      if (identical(_loading, f)) _loading = null;
    });
  }

  Future<bool> _load(String pk) async {
    SealedRead read;
    try {
      read = await _sealed.readDetailed(_stateKey(pk));
    } catch (_) {
      return false;
    }
    if (_disposed || _pk != pk) return false;
    if (ready) return true;
    if (read.status == SealedReadStatus.locked) return false;
    var s = emptyFolders();
    final raw = read.value;
    if (raw != null && raw.isNotEmpty && read.status != SealedReadStatus.unreadable) {
      try {
        s = normalizeFolders(jsonDecode(raw), _nowMs);
      } catch (_) {
        s = emptyFolders();
      }
    }
    _cache = s;
    _cachePk = pk;
    final queued = _queuedPk == pk ? _queued : null;
    _queued = null;
    _queuedPk = '';
    if (queued != null) applyRemote(queued.toJson());
    _changed();
    if (pending) _syncSoon(Duration.zero);
    return true;
  }

  void _persist(FoldersState s) {
    if (memoryOnly) {
      _mem = s;
      return;
    }
    final pk = _pk;
    if (pk.isEmpty) return;
    _cache = s;
    _cachePk = pk;
    _sealed.write(_stateKey(pk), s.json);
  }

  bool get pending {
    if (memoryOnly) return false;
    final pk = _pk;
    return pk.isNotEmpty && _kv.getString(_pendingKey(pk)) == '1';
  }

  void _setPending(bool on) {
    if (memoryOnly) return;
    final pk = _pk;
    if (pk.isEmpty) return;
    if (on) {
      _kv.setString(_pendingKey(pk), '1');
    } else {
      _kv.remove(_pendingKey(pk));
    }
  }

  Set<String> get collapsed {
    if (memoryOnly) return Set.of(_memCollapsed);
    final pk = _pk;
    if (pk.isEmpty) return <String>{};
    try {
      final v = jsonDecode(_kv.getString(_collapsedKey(pk)) ?? '[]');
      return v is List
          ? {for (final id in v) if (folderValidFid(id)) id as String}
          : <String>{};
    } catch (_) {
      return <String>{};
    }
  }

  void _setCollapsed(Set<String> set) {
    final live = state.folders;
    final list = [for (final id in set) if (folderValidFid(id) && live.containsKey(id)) id]
      ..sort();
    if (memoryOnly) {
      _memCollapsed = list.toSet();
    } else {
      final pk = _pk;
      if (pk.isEmpty) return;
      if (list.isEmpty) {
        _kv.remove(_collapsedKey(pk));
      } else {
        _kv.setString(_collapsedKey(pk), jsonEncode(list));
      }
    }
    hooks.onCollapse?.call();
  }

  void toggleCollapsed(String fid) {
    final set = collapsed;
    if (!set.remove(fid)) set.add(fid);
    _setCollapsed(set);
  }

  void setCollapsed(String fid, bool closed) {
    final set = collapsed;
    if (closed ? set.add(fid) : set.remove(fid)) _setCollapsed(set);
  }

  bool commit(FoldersState s, {bool joinSettings = false}) {
    if (_disposed || !ready) return false;
    _persist(s);
    _rev++;
    if (!memoryOnly) _setPending(true);
    _changed();
    if (joinSettings && !memoryOnly) {
      _syncTimer?.cancel();
      _syncTimer = null;
      _join = true;
      _joinTimer?.cancel();
      _joinTimer = Timer(joinWait, () {
        _joinTimer = null;
        if (_join) {
          _join = false;
          _syncSoon();
        }
      });
    } else {
      _syncSoon();
    }
    return true;
  }

  void _syncSoon([Duration? after]) {
    if (memoryOnly || _disposed) return;
    _syncTimer?.cancel();
    _syncTimer = Timer(after ?? syncDebounce, () {
      _syncTimer = null;
      unawaited(sync());
    });
  }

  bool get _canPublish {
    if (memoryOnly || !ready || !pending) return false;
    if (hooks.publish == null) return false;
    if (hooks.switching?.call() ?? false) return false;
    return _pk.isNotEmpty && hooks.online() && hooks.hydrated();
  }

  Map<String, dynamic> _payload() => foldersPublishable(state).toJson();

  Future<String> sync() async {
    if (_disposed) return 'disposed';
    if (memoryOnly) return 'local';
    if (!pending) return 'synced';
    if (!_canPublish) return 'pending';
    if (_syncing) {
      _resync = true;
      return 'pending';
    }
    _syncing = true;
    _resync = false;
    _join = false;
    final rev = _rev;
    final pk = _pk;
    var ok = false;
    try {
      ok = (await hooks.publish!(_payload(), true)).ok;
    } catch (_) {
      ok = false;
    } finally {
      _syncing = false;
    }
    if (_disposed || _pk != pk) return 'pending';
    if (ok && rev == _rev) _setPending(false);
    if (_resync || (ok && rev != _rev)) {
      _resync = false;
      return sync();
    }
    return pending ? 'pending' : 'synced';
  }

  Future<bool> joinSettingsPing() async {
    if (!_join) return false;
    _join = false;
    _joinTimer?.cancel();
    _joinTimer = null;
    if (!_canPublish || _syncing) {
      _syncSoon();
      return false;
    }
    _syncing = true;
    final rev = _rev;
    final pk = _pk;
    var ok = false;
    var changed = false;
    try {
      final r = await hooks.publish!(_payload(), false);
      ok = r.ok;
      changed = r.changed;
    } catch (_) {
      ok = false;
    } finally {
      _syncing = false;
    }
    if (_disposed || _pk != pk) return false;
    if (ok && rev == _rev) {
      _setPending(false);
    } else {
      _syncSoon();
    }
    return changed;
  }

  void retry() {
    if (memoryOnly || _disposed) return;
    if (!ready) {
      _kick();
      return;
    }
    if (pending) unawaited(sync());
  }

  void applyRemote(Object? remote) {
    if (remote is! Map || memoryOnly) return;
    final now = _nowMs;
    if (!ready) {
      final pk = _pk;
      final prev = _queuedPk == pk ? _queued : null;
      _queued = prev != null
          ? mergeFolders(prev, remote, now)
          : normalizeFolders(remote, now);
      _queuedPk = pk;
      _kick();
      return;
    }
    final local = state;
    final merged = capRepair(mergeFolders(local, remote, now), now).state;
    if (!merged.sameAs(local)) {
      _persist(merged);
      _rev++;
      _changed();
    }
    final mine = foldersPublishable(merged).json;
    final theirs = foldersPublishable(normalizeFolders(remote, now)).json;
    if (mine != theirs) {
      _setPending(true);
      _syncSoon(Duration.zero);
    }
  }

  String newId() {
    final used = state;
    final rnd = Random.secure();
    for (var i = 0; i < 20; i++) {
      final id = folderIdFrom([for (var j = 0; j < 32; j++) rnd.nextInt(256)]);
      if (id.isNotEmpty &&
          !used.folders.containsKey(id) &&
          !used.deleted.containsKey(id)) {
        return id;
      }
    }
    return '';
  }

  void dropRef(String ref) {
    if (!ready || ref.isEmpty) return;
    final s = state;
    final fid = folderOfState(s, ref);
    if (fid.isEmpty) return;
    commit(folderRemove(s, fid, [ref], _nowMs).state);
  }

  int get nowMs => _nowMs;

  void _changed() {
    if (_disposed) return;
    hooks.onChanged?.call();
  }

  void dispose() {
    _disposed = true;
    _syncTimer?.cancel();
    _joinTimer?.cancel();
  }
}

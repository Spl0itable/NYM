import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../state/settings_provider.dart';
import '../../services/storage/sealed_key_value.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../identity/panic_wipe.dart';
import 'group_invites.dart';

class GroupInvitesHooks {
  const GroupInvitesHooks({
    required this.selfPubkey,
    required this.syncAllowed,
    this.publish,
    this.forget,
    this.now,
    this.onChanged,
  });

  final String Function() selfPubkey;
  final bool Function() syncAllowed;
  final Future<bool> Function(Map<String, dynamic> payload)? publish;
  final void Function(String gid)? forget;
  final int Function()? now;
  final void Function()? onChanged;
}

class GroupInvitesService {
  GroupInvitesService(this._kv, this._hooks);

  final SealedKeyValue _kv;
  final GroupInvitesHooks _hooks;
  String _pk = '';
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  Map<String, Map<String, dynamic>> _dec = <String, Map<String, dynamic>>{};
  Object? _ns;
  Object? _as;
  Object? _us;
  Map<String, List<String>> _lr = <String, List<String>>{};
  Map<String, dynamic> _hold = GroupInvites.holdNew();
  final Map<String, Object> _held = <String, Object>{};
  Timer? _syncTimer;
  bool _disposed = false;

  static int _wall() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  int _now() => (_hooks.now ?? _wall)();

  String get _key => '${StorageKeys.groupInvitesPrefix}$_pk';

  bool get ready => _pk.isNotEmpty && _pk == _hooks.selfPubkey();

  List<Map<String, dynamic>> get items =>
      ready ? List<Map<String, dynamic>>.of(_items) : const [];

  Map<String, Map<String, dynamic>> get decisions =>
      ready ? Map.of(_dec) : const {};

  Map<String, dynamic>? item(String gid) {
    if (!ready) return null;
    for (final i in _items) {
      if (i['gid'] == gid) return i;
    }
    return null;
  }

  Map<String, dynamic>? decision(String gid) => ready ? _dec[gid] : null;

  Future<bool>? _loading;

  Future<bool> load() {
    final pk = _hooks.selfPubkey();
    if (pk.isNotEmpty && _pk == pk) return Future.value(true);
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<bool> _load() async {
    final pk = _hooks.selfPubkey();
    if (pk.isEmpty) return false;
    if (_pk == pk) return true;
    final read =
        await _kv.readDetailed('${StorageKeys.groupInvitesPrefix}$pk');
    if (read.locked || _disposed) return false;
    if (_hooks.selfPubkey() != pk) return false;
    if (_pk == pk) return true;
    final now = _now();
    var items = <Map<String, dynamic>>[];
    var dec = <String, Map<String, dynamic>>{};
    Object? ns;
    Object? as;
    Object? us;
    var lr = <String, List<String>>{};
    try {
      final p = jsonDecode(read.value ?? '');
      if (p is Map) {
        items = GroupInvites.normalizeItems(p['items'], now);
        dec = GroupInvites.normalizeDecisions(p['dec'], now);
        ns = GroupInvites.notifyState(p['ns'], now);
        as = GroupInvites.notifyState(p['as'], now);
        us = GroupInvites.unbanState(p['us'], now);
        lr = GroupInvites.leftRoles(p['lr']);
      }
    } catch (_) {}
    _pk = pk;
    _items = items;
    _dec = dec;
    _ns = ns;
    _as = as;
    _us = us;
    _lr = lr;
    _hold = GroupInvites.holdNew();
    _held.clear();
    _changed();
    return true;
  }

  void _persist() {
    if (!ready) return;
    _kv.write(
        _key,
        jsonEncode({
          'v': 1,
          'items': _items,
          'dec': _dec,
          'ns': _ns ?? GroupInvites.notifyState(null, _now()),
          'as': _as ?? GroupInvites.notifyState(null, _now()),
          'us': _us ?? GroupInvites.unbanState(null, _now()),
          'lr': _lr,
        }));
  }

  void _changed() => _hooks.onChanged?.call();

  void _forget(String gid) {
    _dropHold(gid);
    _hooks.forget?.call(gid);
  }

  PendingApplyResult apply(
      Map verdict, Map<String, dynamic> item, List friends) {
    if (!ready) return const PendingApplyResult([], [], false);
    final r = GroupInvites.pendingApply(_items, verdict, item, friends);
    if (!r.changed) return r;
    _items = r.list;
    for (final g in r.evicted) {
      _forget(g);
    }
    _persist();
    _changed();
    return r;
  }

  Map<String, dynamic> notifyDecision(Map x) {
    final d = GroupInvites.notifyDecision(_ns, x);
    _ns = d['state'];
    _persist();
    return d;
  }

  bool? leftRole(String gid, String sender) =>
      ready ? GroupInvites.leftRole(_lr, gid, sender) : null;

  Map<String, List<String>> leftRolesForSync(
          Iterable<String> leftGroups, Map<String, int> times) =>
      ready
          ? GroupInvites.leftRolesSync(_lr, leftGroups, times)
          : const <String, List<String>>{};

  Future<void> mergeLeftRoles(Object? incoming, Iterable<String> leftGroups) async {
    if (incoming is! Map || !await load() || !ready) return;
    final next = GroupInvites.leftRolesMerge(_lr, incoming, leftGroups);
    if (jsonEncode(next) == jsonEncode(_lr)) return;
    _lr = next;
    _persist();
  }

  Future<void> noteLeft(String gid, String? owner, List<String> mods,
      Iterable<String> leftGroups) async {
    if (!await load() || !ready) return;
    final next = GroupInvites.leftRolesNote(_lr, gid, owner, mods, leftGroups);
    if (jsonEncode(next) == jsonEncode(_lr)) return;
    _lr = next;
    _persist();
  }

  Map<String, dynamic> unbanNotice(Map x) {
    if (!ready) return {'notice': false, 'archive': false, 'r': 'not-ready'};
    final d = GroupInvites.unbanNotice(_us, x);
    if (jsonEncode(d['state']) != jsonEncode(_us)) {
      _us = d['state'];
      _persist();
    }
    return d;
  }

  bool archiveDecision(Map x) {
    if (!ready) return false;
    final d = GroupInvites.archiveDecision(_as, x);
    _as = d['state'];
    _persist();
    return d['archive'] == true;
  }

  void decide(String gid, String s, int it) {
    if (!ready) return;
    _items = GroupInvites.pendingRemove(_items, gid);
    _dec = GroupInvites.decide(_dec, gid, s, it, _now());
    _persist();
    _changed();
    _syncSoon();
  }

  void remove(String gid) {
    if (!ready) return;
    _items = GroupInvites.pendingRemove(_items, gid);
    _forget(gid);
    _persist();
    _changed();
  }

  Map<String, dynamic> payload() => {
        GroupInvites.payloadKey: jsonDecode(jsonEncode(GroupInvites.publishable(
            GroupInvites.normalizeDecisions(_dec, _now())))),
      };

  Future<bool> sync() async {
    final publish = _hooks.publish;
    if (!ready || publish == null || !_hooks.syncAllowed()) return false;
    try {
      return await publish(payload());
    } catch (_) {
      return false;
    }
  }

  void _syncSoon() {
    if (!_hooks.syncAllowed() || _hooks.publish == null) return;
    _syncTimer?.cancel();
    _syncTimer = Timer(Duration.zero, () {
      _syncTimer = null;
      if (!_disposed) unawaited(sync());
    });
  }

  List<String> applyRemote(Object? remote) {
    if (!ready || !_hooks.syncAllowed()) return const [];
    final now = _now();
    final theirs = GroupInvites.normalizeDecisions(
        GroupInvites.fromPayload(remote), now);
    final merged = GroupInvites.mergeDecisions(_dec, theirs, now);
    final gone = <String>[];
    for (final gid in merged.keys) {
      final i = item(gid);
      if (i != null &&
          GroupInvites.toInt(i['it']) <= (merged[gid]!['dt'] as int)) {
        gone.add(gid);
      }
    }
    final changed = jsonEncode(merged) != jsonEncode(_dec) || gone.isNotEmpty;
    _dec = merged;
    for (final gid in gone) {
      _items = GroupInvites.pendingRemove(_items, gid);
      _forget(gid);
    }
    if (changed) {
      _persist();
      _changed();
    }
    if (jsonEncode(merged) != jsonEncode(theirs)) _syncSoon();
    return gone;
  }

  bool holdPut(String gid, String id, int ts, int bytes, Object data) {
    if (!ready) return false;
    final r = GroupInvites.holdAdd(
        _hold, {'gid': gid, 'id': id, 'ts': ts, 'b': bytes});
    _hold = r.state;
    for (final d in r.dropped) {
      _held.remove('${d['gid']}|${d['id']}');
    }
    if (r.accepted) _held['$gid|$id'] = data;
    return r.accepted;
  }

  int heldCount(String gid) {
    final g = _hold['g'];
    final l = g is Map ? g[gid] : null;
    return l is List ? l.length : 0;
  }

  List<Object> holdTake(String gid) {
    final r = GroupInvites.holdTake(_hold, gid);
    _hold = r.state;
    final out = <Object>[];
    for (final id in r.ids) {
      final d = _held.remove('$gid|$id');
      if (d != null) out.add(d);
    }
    return out;
  }

  void _dropHold(String gid) => holdTake(gid);

  void dispose() {
    _disposed = true;
    _syncTimer?.cancel();
  }
}

final groupInvitesRevisionProvider = StateProvider<int>((ref) => 0);

final groupInvitesProvider = Provider<GroupInvitesService>((ref) {
  ref.watch(bootEpochProvider);
  final kv = ref.watch(keyValueStoreProvider);
  var bump = false;
  var disposed = false;
  final service = GroupInvitesService(
    SealedKeyValue(kv, blocked: () => PanicWipe.inProgress),
    GroupInvitesHooks(
      selfPubkey: () => ref.read(appStateProvider).selfPubkey,
      syncAllowed: () => ref.read(nostrControllerProvider).savedSyncAllowed,
      publish: (p) => ref.read(nostrControllerProvider).publishGroupInvites(p),
      forget: (gid) => ref
          .read(notificationHistoryProvider.notifier)
          .removeByEventId(GroupInvites.notifyId(gid)),
      onChanged: () {
        if (bump) return;
        bump = true;
        Future.microtask(() {
          bump = false;
          if (!disposed) ref.read(groupInvitesRevisionProvider.notifier).state++;
        });
      },
    ),
  );
  ref.onDispose(() {
    disposed = true;
    service.dispose();
  });
  return service;
});

final groupInvitesListProvider = Provider<List<Map<String, dynamic>>>((ref) {
  ref.watch(groupInvitesRevisionProvider);
  final svc = ref.watch(groupInvitesProvider);
  if (!svc.ready) unawaited(svc.load());
  return svc.items;
});

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/storage/account_scope.dart';
import '../../services/storage/at_rest_cipher.dart';
import '../../services/storage/cache_store.dart';
import '../../services/storage/mesh_file_store.dart';
import '../../services/storage/secure_store.dart';
import '../identity/biometric_secret_store.dart';
import 'account_logic.dart';

abstract class AccountSecretBackend {
  Future<Map<String, String>> readAll();
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecretBackend implements AccountSecretBackend {
  const PlatformSecretBackend();

  static const FlutterSecureStorage _sweep = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: null),
  );

  @override
  Future<Map<String, String>> readAll() => _sweep.readAll();

  @override
  Future<void> write(String key, String value) =>
      SecureStore.platform.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _sweep.delete(key: key);
}

class _RecordingStore implements AccountKeyStore {
  _RecordingStore(Map<String, Object> snapshot) : map = Map.of(snapshot);

  final Map<String, Object> map;
  final List<(String, Object?)> ops = [];

  @override
  Iterable<String> get keys => map.keys;

  @override
  Object? read(String key) => map[key];

  @override
  void write(String key, Object value) {
    map[key] = value;
    ops.add((key, value));
  }

  @override
  void delete(String key) {
    map.remove(key);
    ops.add((key, null));
  }
}

class AccountRuntime {
  AccountRuntime({
    required this.prefs,
    AccountSecretBackend? secrets,
    Future<void> Function(String ns)? dropFiles,
    Future<void> Function()? dropBiometric,
    String Function()? newId,
    int Function()? now,
  })  : _secrets = secrets ?? const PlatformSecretBackend(),
        _dropFiles = dropFiles ?? _defaultDropFiles,
        _dropBiometric = dropBiometric ?? _defaultDropBiometric,
        _newId = newId ?? AccountLogic.randomId,
        _now = now ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  static Future<void> _defaultDropFiles(String ns) async {
    try {
      await CacheStore.deleteAccountFiles(ns);
    } catch (_) {}
    try {
      await MeshFileStore(account: ns).wipe();
    } catch (_) {}
  }

  static Future<void> _defaultDropBiometric() =>
      PlatformBiometricSecretStore().delete();

  final SharedPreferences prefs;
  final AccountSecretBackend _secrets;
  final Future<void> Function(String ns) _dropFiles;
  final Future<void> Function() _dropBiometric;
  final String Function() _newId;
  final int Function() _now;

  final ValueNotifier<AccountIndex> changes =
      ValueNotifier<AccountIndex>(AccountLogic.emptyIndex());

  AccountIndex get index => changes.value;

  AccountEntry? get active => index.activeAccount;

  String get activeNs => active?.ns ?? '';

  String? _get(String key) {
    final v = prefs.get(key);
    return v is String ? v : (v == null ? null : '$v');
  }

  Future<AccountIndex> boot() async {
    final stored = prefs.get(AccountLogic.indexKey);
    var next = AccountLogic.loadOrMigrate(_get, _newId(), _now());
    final journal = next.journal;
    if (journal != null) {
      await _runEffects(journal.effects, next);
      await _dropDbs(journal.dbs);
      next = next.withJournal(null);
    }
    if (next.accounts.isNotEmpty || stored != null) {
      await prefs.setString(AccountLogic.indexKey, next.encode());
    }
    changes.value = next;
    activateScope(next.activeAccount?.ns ?? '');
    return next;
  }

  void forget() {
    changes.value = AccountLogic.emptyIndex();
    activateScope('');
  }

  static void activateScope(String ns) {
    AccountScope.namespace = ns;
    AtRestCipher.instance = AtRestCipher(SecureAtRestKeyStore());
    MeshFileStore.instance = MeshFileStore(account: ns);
  }

  String newId() {
    for (var i = 0; i < 8; i++) {
      final id = _newId();
      if (index.byId(id) == null) return id;
    }
    return _newId();
  }

  int now() => _now();

  AccountPlan plan(AccountOp op) => AccountLogic.plan(index, op);

  Future<void> commit(AccountPlan plan) async {
    if (!plan.ok) return;
    final before = index;
    final effects = [
      for (final e in plan.effects)
        if (e != 'reload') e,
    ];
    final dbs = AccountLogic.journalDbs(before, effects);
    final dropBio = _wipesBiometricOwner(before, effects);
    if (plan.needsBoot) {
      await prefs.setString(AccountLogic.indexKey,
          plan.index.withJournal(AccountJournal(effects, dbs)).encode());
    }
    await _runEffects(effects, before);
    await _dropDbs(dbs);
    if (dropBio) {
      try {
        await _dropBiometric();
      } catch (_) {}
    }
    final next = plan.index.withJournal(null);
    await prefs.setString(AccountLogic.indexKey, next.encode());
    changes.value = next;
    if (plan.needsBoot) activateScope(next.activeAccount?.ns ?? '');
  }

  Future<void> touchActive({String? avatar}) async {
    final a = active;
    if (a == null || avatar == null || avatar == a.avatar) return;
    final next = AccountIndex(active: index.active, accounts: [
      for (final e in index.accounts) e.id == a.id ? e.copyWith(avatar: avatar) : e,
    ]);
    await prefs.setString(AccountLogic.indexKey, next.encode());
    changes.value = next;
  }

  bool _wipesBiometricOwner(AccountIndex before, List<String> effects) {
    for (final e in effects) {
      if (!e.startsWith('wipe:')) continue;
      final id = e.substring(5);
      String key(String k) =>
          id == before.active ? k : AccountLogic.nsKey(id, k);
      if (_get(key('nym_vault_method')) == 'biometric' &&
          _get(key('nym_vault_enabled')) == 'true') {
        return true;
      }
    }
    return false;
  }

  bool biometricHeldByOther() {
    final cur = index.active;
    for (final a in index.accounts) {
      if (a.id == cur) continue;
      if (_get(AccountLogic.nsKey(a.id, 'nym_vault_method')) == 'biometric' &&
          _get(AccountLogic.nsKey(a.id, 'nym_vault_enabled')) == 'true') {
        return true;
      }
    }
    return false;
  }

  Future<String?> storedSecret(String id, String key) async {
    final name = id == index.active ? key : AccountLogic.nsKey(id, key);
    try {
      final all = await _secrets.readAll();
      return all[name];
    } catch (_) {
      return null;
    }
  }

  Future<void> _runEffects(List<String> effects, AccountIndex before) async {
    final snapshot = <String, Object>{};
    for (final k in prefs.getKeys()) {
      final v = prefs.get(k);
      if (v != null) snapshot[k] = v;
    }
    final store = _RecordingStore(snapshot);
    AccountLogic.runEffects(store, effects,
        classifier: AccountLogic.classifyNative);
    for (final (key, value) in store.ops) {
      if (value == null) {
        await prefs.remove(key);
      } else if (value is String) {
        await prefs.setString(key, value);
      } else if (value is bool) {
        await prefs.setBool(key, value);
      } else if (value is int) {
        await prefs.setInt(key, value);
      } else if (value is double) {
        await prefs.setDouble(key, value);
      } else if (value is List) {
        await prefs.setStringList(key, [for (final x in value) '$x']);
      }
    }
    Map<String, String> secrets;
    try {
      secrets = await _secrets.readAll();
    } catch (_) {
      return;
    }
    final secretStore = _RecordingStore(secrets);
    AccountLogic.runEffects(secretStore, effects,
        classifier: AccountLogic.classifyNative);
    for (final (key, value) in secretStore.ops) {
      try {
        if (value == null) {
          await _secrets.delete(key);
        } else {
          await _secrets.write(key, '$value');
        }
      } catch (_) {}
    }
  }

  Future<void> _dropDbs(List<String> dbs) async {
    for (final name in dbs) {
      final ns = name == AccountLogic.cacheDb
          ? ''
          : (name.startsWith('${AccountLogic.cacheDb}~')
              ? name.substring(AccountLogic.cacheDb.length + 1)
              : null);
      if (ns == null) continue;
      try {
        await _dropFiles(ns);
      } catch (_) {}
    }
  }
}

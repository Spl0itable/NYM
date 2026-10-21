import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../services/api/api_config.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/settings_provider.dart';
import 'contact_wakes.dart';

bool shouldShareWake({
  required String acceptCalls,
  required bool isFriend,
  required bool registered,
}) {
  if (!registered) return false;
  if (acceptCalls == 'disabled') return false;
  if (acceptCalls == 'friends' && !isFriend) return false;
  return true;
}

final RegExp _wakeRe = RegExp(r'^[0-9a-f]{64}$');

String? parseWake(Object? v) {
  if (v is! String) return null;
  final w = v.trim().toLowerCase();
  return _wakeRe.hasMatch(w) ? w : null;
}

String newWakeSecret([Random? rng]) {
  final r = rng ?? Random.secure();
  final b = StringBuffer();
  for (var i = 0; i < 32; i++) {
    b.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

class CallWakeBook {
  CallWakeBook(this._kv, {int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const String key = 'nym_call_wakes';
  static const int maxEntries = 300;
  static const int ttlMs = 60 * 86400000;

  final KeyValueStore _kv;
  final int Function() _clock;
  Map<String, Map<String, dynamic>>? _map;

  Map<String, Map<String, dynamic>> _load() {
    final cached = _map;
    if (cached != null) return cached;
    final out = <String, Map<String, dynamic>>{};
    try {
      final raw = _kv.getString(key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (k is String && v is Map) out[k] = Map<String, dynamic>.from(v);
          });
        }
      }
    } catch (_) {}
    return _map = out;
  }

  void remember(String self, String peer, Object? value) {
    final wake = parseWake(value);
    if (wake == null || self.isEmpty || peer.isEmpty) return;
    final map = _load();
    final now = _clock();
    map['$self:$peer'] = {'w': wake, 't': now};
    final keys = map.keys
        .where((k) => now - ((map[k]?['t'] as num?)?.toInt() ?? 0) <= ttlMs)
        .toList()
      ..sort((a, b) => ((map[b]?['t'] as num?)?.toInt() ?? 0)
          .compareTo((map[a]?['t'] as num?)?.toInt() ?? 0));
    final kept = <String, Map<String, dynamic>>{
      for (final k in keys.take(maxEntries)) k: map[k]!,
    };
    _map = kept;
    unawaited(_kv.setString(key, jsonEncode(kept)).catchError((_) {}));
  }

  List<String> peersFor(String self) {
    if (self.isEmpty) return const [];
    final now = _clock();
    final prefix = '$self:';
    return [
      for (final e in _load().entries)
        if (e.key.startsWith(prefix) &&
            now - ((e.value['t'] as num?)?.toInt() ?? 0) <= ttlMs)
          e.key.substring(prefix.length),
    ];
  }

  String? wakeFor(String self, String peer) {
    if (self.isEmpty || peer.isEmpty) return null;
    final r = _load()['$self:$peer'];
    if (r == null) return null;
    final t = (r['t'] as num?)?.toInt() ?? 0;
    if (_clock() - t > ttlMs) return null;
    return parseWake(r['w']);
  }
}

class RingClient {
  RingClient({http.Client? client, Uri? endpoint})
      : _client = client ?? http.Client(),
        _endpoint = endpoint ?? Uri.https(ApiConfig.apiHost, '/ring/');

  final http.Client _client;
  final Uri _endpoint;

  Future<bool> post(String path, Map<String, String> body) =>
      _postJson(path, jsonEncode(body));

  Future<bool> send(String path, Map<String, Object> body) =>
      _postJson(path, jsonEncode(body));

  Future<bool> _postJson(String path, String body) async {
    try {
      final res = await _client
          .post(
            _endpoint.resolve(path),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': ApiConfig.dartUserAgent,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 15));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<void> ring(String wake) async {
    final w = parseWake(wake);
    if (w == null) return;
    await post('ring', {'wake': w});
  }
}

class RingRegistration {
  RingRegistration(this._kv, this._client, {int Function()? clock, Random? rng})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _rng = rng ?? Random.secure();

  static const String ownerKey = 'nym_ring_owner';
  static const String wakeKey = 'nym_ring_wake';
  static const String tokenKey = 'nym_ring_token';
  static const String contactsKey = 'nym_ring_contacts';
  static const String targetKey = 'nym_ring_target';
  static const String legacyOffKey = 'nym_ring_legacy_off';
  static const String legacyAtKey = 'nym_ring_legacy_at';

  final KeyValueStore _kv;
  final RingClient _client;
  final int Function() _clock;
  final Random _rng;
  ContactWakes? _contacts;
  Future<void> _chain = Future<void>.value();
  Timer? _timer;
  String? _self;
  bool Function(String peer)? _blocked;

  @visibleForTesting
  static bool? debugSupportedOverride;

  bool nativeSupported = false;

  bool get supported => debugSupportedOverride ?? nativeSupported;

  static String ownerTag(String self) =>
      sha256.convert(utf8.encode('nymchat-ring-owner:$self')).toString();

  String? get _owner => _kv.getString(ownerKey);

  bool enabledFor(String self) =>
      self.isNotEmpty && _owner == ownerTag(self) && wake != null;

  bool ownedByOther(String self) {
    final o = _owner;
    return o != null && o.isNotEmpty && o != ownerTag(self);
  }

  String? get wake => parseWake(_kv.getString(wakeKey));

  String? wakeFor(String self) => enabledFor(self) ? wake : null;

  Future<bool> enable(String self) async {
    if (self.isEmpty || ownedByOther(self)) return false;
    if (!enabledFor(self)) {
      await _kv.setString(wakeKey, newWakeSecret());
      await _kv.setString(ownerKey, ownerTag(self));
    }
    return true;
  }

  bool get legacyActive => _kv.getString(legacyOffKey) != '1';

  ContactWakes? get _wakes {
    final have = _contacts;
    if (have != null) return have;
    if (wake == null) return null;
    ContactWakes? loaded;
    try {
      final raw = _kv.getString(contactsKey);
      if (raw != null && raw.isNotEmpty) {
        loaded = ContactWakes.fromJson(jsonDecode(raw), _clock());
      }
    } catch (_) {}
    return _contacts = loaded ?? ContactWakes(device: newWakeSecret(_rng));
  }

  Future<void> _save() async {
    final c = _contacts;
    if (c == null) return;
    try {
      await _kv.setString(contactsKey, jsonEncode(c.toJson()));
    } catch (_) {}
  }

  String? wakeForPeer(String self, String peer) {
    if (!enabledFor(self) || peer.isEmpty) return null;
    final c = _wakes;
    final before = c?.held.length;
    final mine = c?.tokenFor(peer, _clock(), _rng);
    if (c != null && mine != null) {
      if (c.held.length != before) unawaited(_save());
      return mine;
    }
    if (!legacyActive) return null;
    unawaited(_kv.setString(legacyAtKey, '${_clock()}').catchError((_) {}));
    return wake;
  }

  bool withdrawBlocked(String self, bool Function(String peer) blocked) {
    if (self.isNotEmpty) _self = self;
    _blocked = blocked;
    if (!enabledFor(self)) return false;
    final c = _wakes;
    if (c == null) return false;
    var changed = false;
    for (final peer in {for (final h in c.held.values) h.$1}) {
      if (blocked(peer)) changed = c.withdraw(peer) || changed;
    }
    if (changed) unawaited(_save());
    return changed;
  }

  int get nextAt => _wakes?.nextAt ?? 0;

  @visibleForTesting
  bool get armed => _timer?.isActive ?? false;

  Future<bool> tick() => sync();

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _arm(ContactWakes c) {
    _timer?.cancel();
    _timer = null;
    if (!identical(_contacts, c)) return;
    final wait = max(0, c.nextAt - _clock());
    _timer = Timer(Duration(milliseconds: wait), () => unawaited(tick()));
  }

  Future<bool> sync({
    String? self,
    bool Function(String peer)? blocked,
    bool force = false,
  }) {
    if (self != null && self.isNotEmpty) _self = self;
    if (blocked != null) _blocked = blocked;
    final run = _chain.then((_) => _sync(force));
    _chain = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<bool> _sync(bool force) async {
    final c = _wakes;
    final t = _target;
    if (c == null || t == null) return false;
    final self = _self;
    final blocked = _blocked;
    if (self != null && blocked != null) withdrawBlocked(self, blocked);
    final now = _clock();
    if (!force && !c.due(now)) {
      _arm(c);
      return true;
    }
    final b = c.plan(now, _rng);
    final ok = await _client.send('batch', {
      'device': c.device,
      'platform': t.$1,
      'token': t.$2,
      if (t.$1 == 'apns') 'env': t.$3,
      'replace': true,
      'add': b.set,
    });
    if (ok) {
      c.commit(b, now, _rng);
    } else {
      c.abort(now, _rng);
    }
    await _save();
    _arm(c);
    if (ok) await _retire(c);
    return ok;
  }

  (String, String, String)? get _target {
    try {
      final raw = _kv.getString(targetKey);
      if (raw == null || raw.isEmpty) return null;
      final j = jsonDecode(raw);
      if (j is! Map || j['p'] is! String || j['t'] is! String) return null;
      return (j['p'] as String, j['t'] as String, (j['e'] as String?) ?? 'production');
    } catch (_) {
      return null;
    }
  }

  Future<bool> _retire(ContactWakes c) async {
    final w = wake;
    if (w == null || !legacyActive || !c.registered) return false;
    final shared = int.tryParse(_kv.getString(legacyAtKey) ?? '') ?? 0;
    if (_clock() - max(c.since, shared) < kWakeHoldMs) return false;
    final ok = await _client.post('unregister', {'wake': w});
    if (ok) await _kv.setString(legacyOffKey, '1');
    return ok;
  }

  Future<void> disable() async {
    dispose();
    final w = wake;
    final c = _wakes;
    if (w != null && legacyActive) await _client.post('unregister', {'wake': w});
    if (c != null && (c.registered || _target != null)) {
      await _client.send('unregister', {'device': c.device});
    }
    _contacts = null;
    await _kv.remove(wakeKey);
    await _kv.remove(ownerKey);
    await _kv.remove(tokenKey);
    await _kv.remove(contactsKey);
    await _kv.remove(targetKey);
    await _kv.remove(legacyOffKey);
    await _kv.remove(legacyAtKey);
  }

  Future<bool> onToken({
    required String platform,
    required String token,
    String env = 'production',
  }) async {
    final w = wake;
    if (w == null || token.isEmpty) return false;
    final before = _target;
    await _kv.setString(targetKey, jsonEncode({'p': platform, 't': token, 'e': env}));
    var ok = true;
    if (legacyActive) {
      ok = await _client.post('register', <String, String>{
        'wake': w,
        'platform': platform,
        'token': token,
        if (platform == 'apns') 'env': env,
      });
      if (ok) await _kv.setString(tokenKey, '$platform:$token');
    }
    await sync(force: before != _target);
    return ok;
  }
}

final ringClientProvider = Provider<RingClient>((ref) => RingClient());

final callWakeBookProvider = Provider<CallWakeBook>(
    (ref) => CallWakeBook(ref.read(keyValueStoreProvider)));

final ringRegistrationProvider = Provider<RingRegistration>((ref) {
  final reg = RingRegistration(
      ref.read(keyValueStoreProvider), ref.read(ringClientProvider));
  ref.onDispose(reg.dispose);
  return reg;
});

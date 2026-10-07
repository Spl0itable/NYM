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

  Future<bool> post(String path, Map<String, String> body) async {
    try {
      final res = await _client
          .post(
            _endpoint.resolve(path),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': ApiConfig.dartUserAgent,
            },
            body: jsonEncode(body),
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
  RingRegistration(this._kv, this._client);

  static const String ownerKey = 'nym_ring_owner';
  static const String wakeKey = 'nym_ring_wake';
  static const String tokenKey = 'nym_ring_token';

  final KeyValueStore _kv;
  final RingClient _client;

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

  Future<void> disable() async {
    final w = wake;
    if (w != null) await _client.post('unregister', {'wake': w});
    await _kv.remove(wakeKey);
    await _kv.remove(ownerKey);
    await _kv.remove(tokenKey);
  }

  Future<bool> onToken({
    required String platform,
    required String token,
    String env = 'production',
  }) async {
    final w = wake;
    if (w == null || token.isEmpty) return false;
    final body = <String, String>{
      'wake': w,
      'platform': platform,
      'token': token,
      if (platform == 'apns') 'env': env,
    };
    final ok = await _client.post('register', body);
    if (ok) await _kv.setString(tokenKey, '$platform:$token');
    return ok;
  }
}

final ringClientProvider = Provider<RingClient>((ref) => RingClient());

final callWakeBookProvider = Provider<CallWakeBook>(
    (ref) => CallWakeBook(ref.read(keyValueStoreProvider)));

final ringRegistrationProvider = Provider<RingRegistration>((ref) =>
    RingRegistration(ref.read(keyValueStoreProvider), ref.read(ringClientProvider)));

import '../../core/constants/relays.dart';

class RelayBlockCaps {
  RelayBlockCaps._();

  static const int items = 500;
  static const int removed = 500;

  static Map<String, int> toJson() => {'items': items, 'removed': removed};
}

class RelayBlockShard {
  const RelayBlockShard({
    required this.id,
    required this.role,
    required this.relays,
    required this.dmRelays,
  });

  final String id;
  final String role;
  final List<String> relays;
  final List<String> dmRelays;

  RelayBlockShard copyWith({List<String>? relays, List<String>? dmRelays}) =>
      RelayBlockShard(
        id: id,
        role: role,
        relays: relays ?? this.relays,
        dmRelays: dmRelays ?? this.dmRelays,
      );
}

class RelayBlock {
  RelayBlock._();

  static const String appRelay = RelayConfig.appRelay;
  static const int tombstoneMs = 90 * 86400000;
  static const int _maxSafe = 9007199254740991;

  static final RegExp _rxUrl =
      RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^\/?#]*)([^?#]*)');
  static final RegExp _rxPort = RegExp(r'^\d{1,5}$');
  static final RegExp _rxScheme = RegExp(r'^wss?:\/\/', caseSensitive: false);
  static final RegExp _rxTrailing = RegExp(r'\/+$');

  static String? _parse(Object? url) {
    if (url is! String) return null;
    final m = _rxUrl.firstMatch(url.trim());
    if (m == null) return null;
    final scheme = m.group(1)!.toLowerCase();
    if (scheme != 'wss' && scheme != 'ws') return null;
    var auth = m.group(2)!;
    final at = auth.lastIndexOf('@');
    if (at >= 0) auth = auth.substring(at + 1);
    var host = auth;
    var port = '';
    final close = auth.lastIndexOf(']');
    final colon = auth.lastIndexOf(':');
    if (colon > close) {
      host = auth.substring(0, colon);
      port = auth.substring(colon + 1);
    }
    if (host.isEmpty) return null;
    if (port.isNotEmpty) {
      if (!_rxPort.hasMatch(port)) return null;
      final n = int.parse(port);
      if (n > 65535) return null;
      port = ((scheme == 'wss' && n == 443) || (scheme == 'ws' && n == 80))
          ? ''
          : '$n';
    }
    final path = m.group(3)!.replaceAll(_rxTrailing, '');
    return '$scheme://${host.toLowerCase()}${port.isEmpty ? '' : ':$port'}$path';
  }

  static String canon(String url) => _parse(url) ?? url.trim();

  static bool blockable(Object? url) {
    final c = _parse(url);
    return c != null && c.startsWith('wss://') && c != appRelay;
  }

  static String shown(Object? url) =>
      (url is String ? url : '').replaceFirst(_rxScheme, '');

  static bool searchMatch(String url, String? query) {
    final q = shown((query ?? '').trim()).toLowerCase();
    if (q.isEmpty) return true;
    return shown(url).toLowerCase().contains(q);
  }

  static int _int(Object? v) {
    if (v is! num || !v.isFinite || v.abs() > _maxSafe) return 0;
    return v.floor();
  }

  static Map _obj(Object? v) => v is Map ? v : const {};

  static int _cmp(String a, String b) => a.compareTo(b);

  static Map<String, int> _tsMap(Object? raw) {
    final src = _obj(raw);
    final out = <String, int>{};
    for (final e in src.entries) {
      final k = e.key;
      if (k is! String) continue;
      final v = _int(e.value);
      if (v <= 0 || !blockable(k)) continue;
      final c = canon(k);
      final cur = out[c];
      if (cur == null || v > cur) out[c] = v;
    }
    return out;
  }

  static Map<String, int> _capped(Map<String, int> map, int cap) {
    final rows = map.entries.toList()
      ..sort((x, y) {
        final d = y.value.compareTo(x.value);
        return d != 0 ? d : _cmp(x.key, y.key);
      });
    return {for (final e in rows.take(cap)) e.key: e.value};
  }

  static Map<String, Map<String, int>> _settle(
      Map<String, int> items, Map<String, int> removed, int now) {
    for (final k in items.keys.toList()) {
      final r = removed[k];
      if (r == null) continue;
      if (r >= items[k]!) {
        items.remove(k);
      } else {
        removed.remove(k);
      }
    }
    final floor = now - tombstoneMs;
    removed.removeWhere((_, t) => t < floor);
    return {
      'items': _capped(items, RelayBlockCaps.items),
      'removed': _capped(removed, RelayBlockCaps.removed),
    };
  }

  static Map<String, Map<String, int>> norm(Object? raw, int now) {
    final o = _obj(raw);
    return _settle(_tsMap(o['items']), _tsMap(o['removed']), _int(now));
  }

  static Map<String, int> _newest(Map<String, int> a, Map<String, int> b) {
    final out = Map<String, int>.of(a);
    b.forEach((k, v) {
      final cur = out[k];
      if (cur == null || v > cur) out[k] = v;
    });
    return out;
  }

  static Map<String, Map<String, int>> merge(Object? a, Object? b, int now) {
    final x = _obj(a);
    final y = _obj(b);
    return _settle(_newest(_tsMap(x['items']), _tsMap(y['items'])),
        _newest(_tsMap(x['removed']), _tsMap(y['removed'])), _int(now));
  }

  static Map<String, Map<String, int>> block(
      Object? state, String url, int now) {
    final s = norm(state, now);
    if (!blockable(url)) return s;
    final c = canon(url);
    s['items']![c] = _int(now);
    s['removed']!.remove(c);
    return _settle(s['items']!, s['removed']!, _int(now));
  }

  static Map<String, Map<String, int>> unblock(
      Object? state, String url, int now) {
    final s = norm(state, now);
    final c = canon(url);
    if (c.isEmpty) return s;
    s['items']!.remove(c);
    if (blockable(c)) s['removed']![c] = _int(now);
    return _settle(s['items']!, s['removed']!, _int(now));
  }

  static List<String> list(Object? state) {
    final items = _obj(_obj(state)['items']);
    final urls = <String>{
      for (final k in items.keys)
        if (k is String && blockable(k)) canon(k),
    }.toList()
      ..sort((x, y) => _cmp(shown(x), shown(y)));
    return urls;
  }

  static Set<String> toSet(Iterable<Object?>? urls) {
    final out = <String>{};
    for (final u in urls ?? const <Object?>[]) {
      if (u is! String) continue;
      final c = canon(u);
      if (c.isNotEmpty && c != appRelay) out.add(c);
    }
    return out;
  }

  static bool isBlocked(Set<String>? set, Object? url) {
    if (set == null || set.isEmpty || url is! String) return false;
    final c = canon(url);
    return c != appRelay && set.contains(c);
  }

  static List<T> filterShards<T>(
    List<T> shards,
    Iterable<Object?> blocked, {
    required List<String> Function(T) relaysOf,
    required List<String> Function(T) dmRelaysOf,
    required T Function(T, List<String>, List<String>) rebuild,
  }) {
    final set = blocked is Set<String> ? blocked : toSet(blocked);
    if (set.isEmpty) return shards;
    final out = <T>[];
    for (final s in shards) {
      final all = relaysOf(s);
      final dms = dmRelaysOf(s);
      final relays = [
        for (final u in all)
          if (!isBlocked(set, u)) u
      ];
      final dmRelays = [
        for (final u in dms)
          if (!isBlocked(set, u)) u
      ];
      if (all.isNotEmpty && relays.isEmpty) continue;
      if (relays.length == all.length && dmRelays.length == dms.length) {
        out.add(s);
        continue;
      }
      out.add(rebuild(s, relays, dmRelays));
    }
    return out;
  }

  static List<RelayBlockShard> filterBlockShards(
          List<RelayBlockShard> shards, Iterable<Object?> blocked) =>
      filterShards<RelayBlockShard>(
        shards,
        blocked,
        relaysOf: (s) => s.relays,
        dmRelaysOf: (s) => s.dmRelays,
        rebuild: (s, r, d) => s.copyWith(relays: r, dmRelays: d),
      );

  static String guard(
    String url, {
    Iterable<Object?> blocked = const [],
    Iterable<Object?> defaults = RelayConfig.defaultRelays,
    Iterable<Object?> writeOnly = RelayConfig.writeOnlyRelays,
    String? signer,
  }) {
    final target = canon(url);
    if (target == appRelay) return 'required';
    if (!blockable(url)) return 'invalid';
    final set = blocked is Set<String> ? blocked : toSet(blocked);
    if (set.contains(target)) return 'already';
    final wo = toSet(writeOnly);
    final readers = [
      for (final u in toSet(defaults))
        if (!wo.contains(u)) u
    ];
    if (readers.contains(target) &&
        readers.every((u) => u == target || set.contains(u))) {
      return 'last-default';
    }
    if (signer != null && signer.isNotEmpty && canon(signer) == target) {
      return 'signer';
    }
    return 'ok';
  }

  static Map<String, Map<String, int>> keepReader(
    Object? state,
    int now, {
    Iterable<Object?> defaults = RelayConfig.defaultRelays,
    Iterable<Object?> writeOnly = RelayConfig.writeOnlyRelays,
  }) {
    final s = norm(state, now);
    final wo = toSet(writeOnly);
    final readers = [
      for (final u in toSet(defaults))
        if (!wo.contains(u)) u
    ];
    final items = s['items']!;
    if (readers.isEmpty || readers.any((u) => !items.containsKey(u))) return s;
    readers.sort((x, y) {
      final d = items[y]!.compareTo(items[x]!);
      return d != 0 ? d : _cmp(x, y);
    });
    final top = readers.first;
    final at = _int(now);
    final blockedAt = items.remove(top)!;
    s['removed']![top] = at > blockedAt ? at : blockedAt + 1;
    return _settle(items, s['removed']!, at);
  }

  static List<String> usable(
      Iterable<Object?> urls, Iterable<Object?> blocked) {
    final set = blocked is Set<String> ? blocked : toSet(blocked);
    final list = [
      for (final u in urls)
        if (u is String && u.isNotEmpty) u
    ];
    final kept = [
      for (final u in list)
        if (!isBlocked(set, u)) u
    ];
    return kept.isNotEmpty || list.isEmpty ? kept : [list.first];
  }

  static bool geoAllBlocked(
      Iterable<Object?> nearest, Iterable<Object?> blocked) {
    final set = blocked is Set<String> ? blocked : toSet(blocked);
    final urls = [
      for (final u in nearest)
        if (u is String && u.isNotEmpty) u
    ];
    return urls.isNotEmpty && urls.every((u) => isBlocked(set, u));
  }
}

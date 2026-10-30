import 'dart:async';
import 'dart:convert';

class StorageWriteResult {
  const StorageWriteResult(this.ok, this.evicted, {this.user = false});

  final bool ok;
  final List<String> evicted;
  final bool user;
}

enum _Attempt { ok, full, error }

class StorageGuard {
  StorageGuard._();

  static const List<String> i18nPrefixes = ['nym_ui_i18n_', 'nym_cmd_i18n_'];

  static const List<Object> tiers = [
    [
      'nym_unfurl_cache',
      'nym_nostr_ref_cache',
      'nym_relay_stats',
      'nym_msg_verify_status',
      'nym_shop_active_cache',
      'nym_botpm_model_catalog',
      'nym_geo_relays',
      'nym_geohash_places',
    ],
    'i18n-other',
    ['nym_custom_emojis', 'nym_custom_emoji_packs'],
    'i18n-current',
    ['nym_zap_known'],
  ];

  static const List<String> trimKeys = [
    'nym_channel_activity',
    'nym_unread_basis',
    'nym_unread_counts',
    'nym_channel_last_read',
  ];

  static const int user = -1;

  static final List<Future<void> Function()> pruners = [];

  static String? _read(String? Function(String key)? get, String key) {
    try {
      return get?.call(key);
    } catch (_) {
      return null;
    }
  }

  static num _recency(Object? v) {
    if (v is num && v.isFinite) return v;
    if (v is Map) {
      for (final f in const ['ts', 'at', 't', 'updatedAt']) {
        final x = v[f];
        if (x is num && x.isFinite) return x;
      }
    }
    return 0;
  }

  static const List<String> rankedKeys = [
    'nym_unread_basis',
    'nym_unread_counts',
  ];

  static const List<String> rankFrom = [
    'nym_channel_activity',
    'nym_channel_last_read',
  ];

  static Map<String, num> rankOf(List<String?> raws) {
    final out = <String, num>{};
    for (final raw in raws) {
      if (raw == null) continue;
      Object? data;
      try {
        data = jsonDecode(raw);
      } catch (_) {
        continue;
      }
      if (data is! Map) continue;
      data.forEach((k, v) {
        if (v is! num || !v.isFinite) return;
        final ms = v < 1e12 ? v * 1000 : v;
        if (ms > (out['$k'] ?? 0)) out['$k'] = ms;
      });
    }
    return out;
  }

  static String? trimmed(String raw, {Map<String, num>? rank}) {
    Object? data;
    try {
      data = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (data is List) {
      if (data.length < 2) return null;
      return jsonEncode(data.sublist(data.length - data.length ~/ 2));
    }
    if (data is! Map) return null;
    final entries = data.entries.toList();
    if (entries.length < 2) return null;
    num score(MapEntry<dynamic, dynamic> e) =>
        rank == null ? _recency(e.value) : (rank['${e.key}'] ?? 0);
    entries.sort((a, b) {
      final c = score(b).compareTo(score(a));
      if (c != 0) return c;
      return '${a.key}'.compareTo('${b.key}');
    });
    return jsonEncode(
        Map.fromEntries(entries.take(entries.length ~/ 2)));
  }

  static Map<String, int> bounded(
    Map<String, int> map,
    bool Function(String key) open, {
    required int nowMs,
    int max = 1000,
    int maxAgeMs = 90 * 24 * 60 * 60 * 1000,
  }) {
    final out = <String, int>{};
    final rest = <MapEntry<String, int>>[];
    map.forEach((k, v) {
      if (v <= 0) return;
      if (open(k)) {
        out[k] = v;
      } else if (nowMs - (v < 1000000000000 ? v * 1000 : v) <= maxAgeMs) {
        rest.add(MapEntry(k, v));
      }
    });
    rest.sort((a, b) => b.value.compareTo(a.value));
    for (final e in rest.take(max)) {
      out[e.key] = e.value;
    }
    return out;
  }

  static String? i18nLang(String key) {
    for (final p in i18nPrefixes) {
      if (key.startsWith(p)) return key.substring(p.length);
    }
    return null;
  }

  static int tierOf(String key, String currentLang) {
    final lang = i18nLang(key);
    for (var i = 0; i < tiers.length; i++) {
      final t = tiers[i];
      if (t == 'i18n-other' && lang != null && lang != currentLang) return i;
      if (t == 'i18n-current' && lang != null && lang == currentLang) return i;
      if (t is List && t.contains(key)) return i;
    }
    return user;
  }

  static bool isQuota(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('quota') || s.contains('no space') || s.contains('enospc');
  }

  static Future<_Attempt> _attempt(FutureOr<bool> Function() f) async {
    try {
      return await f() ? _Attempt.ok : _Attempt.full;
    } catch (e) {
      return isQuota(e) ? _Attempt.full : _Attempt.error;
    }
  }

  static Future<StorageWriteResult> write({
    required String key,
    required String value,
    required String lang,
    required FutureOr<bool> Function(String key, String value) set,
    required FutureOr<Object?> Function(String key) remove,
    required Iterable<String> Function() keys,
    required int Function(String key) sizeOf,
    String? Function(String key)? get,
  }) async {
    final first = await _attempt(() => set(key, value));
    if (first == _Attempt.ok) return const StorageWriteResult(true, []);
    final own = tierOf(key, lang);
    if (first == _Attempt.error) {
      return StorageWriteResult(false, const [], user: own == user);
    }
    final below = own == user ? tiers.length : own;
    final victims = <(String, int, int)>[];
    for (final k in keys()) {
      if (k == key) continue;
      final t = tierOf(k, lang);
      if (t == user || t >= below) continue;
      victims.add((k, t, k.length + sizeOf(k)));
    }
    victims.sort((a, b) {
      if (a.$2 != b.$2) return a.$2 - b.$2;
      if (a.$3 != b.$3) return b.$3 - a.$3;
      return a.$1.compareTo(b.$1);
    });
    final evicted = <String>[];
    for (final v in victims) {
      try {
        await remove(v.$1);
      } catch (_) {
        continue;
      }
      evicted.add(v.$1);
      final again = await _attempt(() => set(key, value));
      if (again == _Attempt.ok) return StorageWriteResult(true, evicted);
    }
    if (own != user) return StorageWriteResult(false, evicted);
    for (var round = 0; round < 32; round++) {
      var changed = false;
      for (final t in trimKeys) {
        if (t == key || !keys().contains(t)) continue;
        String? raw;
        try {
          raw = get?.call(t);
        } catch (_) {
          raw = null;
        }
        Map<String, num>? rank;
        if (rankedKeys.contains(t)) {
          rank = rankOf([
            for (final r in rankFrom)
              if (keys().contains(r)) _read(get, r),
          ]);
        }
        final next = raw == null ? null : trimmed(raw, rank: rank);
        if (next == null) {
          try {
            await remove(t);
          } catch (_) {
            continue;
          }
        } else if (await _attempt(() => set(t, next)) != _Attempt.ok) {
          continue;
        }
        changed = true;
        if (await _attempt(() => set(key, value)) == _Attempt.ok) {
          return StorageWriteResult(true, evicted);
        }
      }
      if (!changed) break;
    }
    for (final p in List.of(pruners)) {
      try {
        await p();
      } catch (_) {
        continue;
      }
      if (await _attempt(() => set(key, value)) == _Attempt.ok) {
        return StorageWriteResult(true, evicted);
      }
    }
    return StorageWriteResult(false, evicted, user: true);
  }
}

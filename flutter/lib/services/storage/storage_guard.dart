import 'dart:async';

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
    ],
    'i18n-other',
    ['nym_custom_emojis', 'nym_custom_emoji_packs'],
    'i18n-current',
    ['nym_zap_known'],
  ];

  static const int user = -1;

  static void Function(String key)? onFull;

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
      if (again == _Attempt.error) break;
    }
    return StorageWriteResult(false, evicted, user: own == user);
  }

  static void reportFull(String key) {
    final cb = onFull;
    if (cb == null) return;
    try {
      cb(key);
    } catch (_) {}
  }
}

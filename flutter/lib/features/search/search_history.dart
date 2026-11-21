import 'dart:convert';

import '../../core/constants/storage_keys.dart';
import 'unified_search.dart' show foldSearchText;

class SearchHistoryConfig {
  const SearchHistoryConfig._();

  static const int keep = 50;
  static const int show = 10;
  static const int suggest = 3;
  static const int minChars = 2;
  static const int maxChars = 200;
  static const int version = 1;

  static Map<String, dynamic> toJson() => {
        'keep': keep,
        'show': show,
        'suggest': suggest,
        'minChars': minChars,
        'maxChars': maxChars,
        'version': version,
      };
}

const Map<String, String> kSearchHistoryStrings = {
  'recent': 'Recent',
  'recentRow': '{q}, recent search',
  'remove': 'Remove {q} from recent searches',
  'removeShort': 'Remove',
  'clearAll': 'Clear recent searches',
  'removed': 'Removed from recent searches',
  'cleared': 'Recent searches cleared',
  'settingLabel': 'Remember searches',
  'settingHint':
      'Keep a list of your recent searches on this device so they can be suggested again. The list stays on this device, is separate for each identity, and is never sent anywhere. Turning this off clears it.',
};

class SearchHistoryKeys {
  const SearchHistoryKeys._();

  static const String state = StorageKeys.searchHistoryPrefix;
  static const String setting = StorageKeys.rememberSearches;
  static const String off = 'off';

  static Map<String, dynamic> toJson() =>
      {'state': state, 'setting': setting, 'off': off};
}

class SearchHistoryEntry {
  const SearchHistoryEntry(this.q, this.at);

  final String q;
  final int at;

  Map<String, dynamic> toJson() => {'q': q, 'at': at};

  @override
  bool operator ==(Object other) =>
      other is SearchHistoryEntry && other.q == q && other.at == at;

  @override
  int get hashCode => Object.hash(q, at);

  @override
  String toString() => 'SearchHistoryEntry($q, $at)';
}

class NormalizedSearch {
  const NormalizedSearch(this.q, this.key);

  final String q;
  final String key;

  Map<String, dynamic> toJson() => {'q': q, 'key': key};
}

final RegExp _spaces = RegExp(r'\s+');

String _collapse(Object? raw) {
  final s = raw == null ? '' : (raw is String ? raw : '$raw');
  return s.replaceAll(_spaces, ' ').trim();
}

NormalizedSearch? normalizeSearchQuery(Object? raw) {
  final q = _collapse(raw);
  final n = q.runes.length;
  if (n < SearchHistoryConfig.minChars || n > SearchHistoryConfig.maxChars) {
    return null;
  }
  return NormalizedSearch(q, foldSearchText(q));
}

int searchHistoryStamp(Object? at) {
  num? n;
  if (at is num) {
    n = at;
  } else if (at is bool) {
    n = at ? 1 : 0;
  } else if (at == null) {
    n = 0;
  } else if (at is String) {
    final s = at.trim();
    n = s.isEmpty ? 0 : num.tryParse(s);
  }
  if (n == null || !n.isFinite || n <= 0) return 0;
  return n.floor();
}

List<SearchHistoryEntry> addSearch(
    List<SearchHistoryEntry> items, Object? raw, num now) {
  final n = normalizeSearchQuery(raw);
  if (n == null) return items;
  final out = <SearchHistoryEntry>[
    SearchHistoryEntry(n.q, searchHistoryStamp(now)),
  ];
  for (final e in items) {
    if (foldSearchText(e.q) == n.key) continue;
    out.add(e);
    if (out.length >= SearchHistoryConfig.keep) break;
  }
  return List.unmodifiable(out);
}

List<SearchHistoryEntry> removeSearch(
    List<SearchHistoryEntry> items, Object? raw) {
  final n = normalizeSearchQuery(raw);
  if (n == null) return items;
  final out = [
    for (final e in items)
      if (foldSearchText(e.q) != n.key) e,
  ];
  return out.length == items.length ? items : List.unmodifiable(out);
}

List<SearchHistoryEntry> clearSearches() => const [];

List<SearchHistoryEntry> recentSearches(List<SearchHistoryEntry> items) =>
    List.unmodifiable(items.take(SearchHistoryConfig.show));

List<SearchHistoryEntry> suggestSearches(
    List<SearchHistoryEntry> items, Object? typed) {
  final t = foldSearchText(_collapse(typed));
  if (t.isEmpty) return const [];
  final first = <SearchHistoryEntry>[];
  final rest = <SearchHistoryEntry>[];
  for (final e in items) {
    final k = foldSearchText(e.q);
    if (k == t) continue;
    if (k.startsWith(t)) {
      first.add(e);
    } else if (k.contains(t)) {
      rest.add(e);
    }
  }
  return List.unmodifiable(
      [...first, ...rest].take(SearchHistoryConfig.suggest));
}

List<SearchHistoryEntry> decodeSearchHistory(String? json) {
  if (json == null || json.isEmpty) return const [];
  Object? rec;
  try {
    rec = jsonDecode(json);
  } catch (_) {
    return const [];
  }
  if (rec is! Map || rec['v'] != SearchHistoryConfig.version) return const [];
  final items = rec['items'];
  if (items is! List) return const [];
  final out = <SearchHistoryEntry>[];
  final seen = <String>{};
  for (final it in items) {
    if (it is! Map) continue;
    final q = it['q'];
    if (q is! String) continue;
    final n = normalizeSearchQuery(q);
    if (n == null || !seen.add(n.key)) continue;
    out.add(SearchHistoryEntry(n.q, searchHistoryStamp(it['at'])));
    if (out.length >= SearchHistoryConfig.keep) break;
  }
  return List.unmodifiable(out);
}

String encodeSearchHistory(List<SearchHistoryEntry> items) => jsonEncode({
      'v': SearchHistoryConfig.version,
      'items': [for (final e in items) e.toJson()],
    });

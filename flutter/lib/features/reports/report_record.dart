import '../emoji/custom_emoji.dart' show kEmojiPackCoordRx;
import '../sync/sync_merge.dart';

class ReportRecord {
  const ReportRecord._();

  static const int bytes = 16384;

  static const String storeKey = 'nym_reported_targets';
  static const String syncField = 'reportedTargets';

  static const Map<String, String> refusals = {
    'e': 'You already reported this message.',
    'p': 'You already reported this user.',
    'a': 'You already reported this emoji pack.',
  };

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _key = RegExp(
      r'^(?:[ep]:[0-9a-f]{64}|a:30030:[0-9a-f]{64}:[^\u0000-\u001f\u007f]{0,1024})$');

  static int get cap => SyncMergeCaps.reportedTargets;

  static bool isKey(Object? k) => k is String && _key.hasMatch(k);

  static List<List<Object?>> _vals(Object? tags, String name) {
    final out = <List<Object?>>[];
    if (tags is! List) return out;
    for (final t in tags) {
      if (t is List && t.length > 1 && t[0] == name && t[1] is String) {
        out.add(t.cast<Object?>());
      }
    }
    return out;
  }

  static String keyOfTags(Object? tags) {
    final ps = _vals(tags, 'p');
    final es = _vals(tags, 'e');
    final packs = _vals(tags, 'a')
        .where((t) => (t[1] as String).startsWith('30030:'))
        .toList();
    if (packs.isNotEmpty) {
      final c = packs.first[1] as String;
      if (!kEmojiPackCoordRx.hasMatch(c)) return '';
      if (ps.isNotEmpty &&
          (ps.first[1] as String).toLowerCase() != c.substring(6, 70)) {
        return '';
      }
      return 'a:$c';
    }
    final e = es.isNotEmpty ? (es.first[1] as String).toLowerCase() : '';
    if (_hex64.hasMatch(e)) return 'e:$e';
    final p = ps.isNotEmpty ? (ps.first[1] as String).toLowerCase() : '';
    return _hex64.hasMatch(p) ? 'p:$p' : '';
  }

  static List<List<String>> tagsFor({
    String? pubkey,
    String? messageId,
    bool includeMessage = false,
    String? coord,
    String type = 'other',
  }) {
    final t = type.isNotEmpty ? type : 'other';
    final c = coord ?? '';
    if (c.isNotEmpty) {
      return kEmojiPackCoordRx.hasMatch(c)
          ? [
              ['p', c.substring(6, 70), t],
              ['a', c, t],
            ]
          : const [];
    }
    final pk = pubkey ?? '';
    if (pk.isEmpty) return const [];
    return [
      ['p', pk, t],
      if (includeMessage && (messageId ?? '').isNotEmpty) ['e', messageId!, t],
    ];
  }

  static String keyFor({
    String? pubkey,
    String? messageId,
    bool includeMessage = false,
    String? coord,
  }) =>
      keyOfTags(tagsFor(
          pubkey: pubkey,
          messageId: messageId,
          includeMessage: includeMessage,
          coord: coord));

  static Map<String, dynamic> clean(Object? map) {
    final out = <String, dynamic>{};
    if (map is Map) {
      map.forEach((k, v) {
        if (isKey(k)) out[k as String] = v;
      });
    }
    return out;
  }

  static int _utf8Len(String s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      final d = i + 1 < s.length ? s.codeUnitAt(i + 1) : 0;
      if (c < 0x80) {
        n += 1;
      } else if (c < 0x800) {
        n += 2;
      } else if (c >= 0xd800 && c <= 0xdbff && d >= 0xdc00 && d <= 0xdfff) {
        n += 4;
        i++;
      } else {
        n += 3;
      }
    }
    return n;
  }

  static int _entryBytes(String k, int v) {
    var esc = 0;
    for (var i = 0; i < k.length; i++) {
      final c = k.codeUnitAt(i);
      if (c == 34 || c == 92) esc++;
    }
    return _utf8Len(k) + esc + '$v'.length + 4;
  }

  static Map<String, int> _fit(Map<String, int> map) {
    final rows = map.entries.toList()
      ..sort((x, y) {
        final d = y.value.compareTo(x.value);
        return d != 0 ? d : x.key.compareTo(y.key);
      });
    final out = <String, int>{};
    var used = 2;
    for (final e in rows) {
      used += _entryBytes(e.key, e.value);
      if (used > bytes) break;
      out[e.key] = e.value;
    }
    return out;
  }

  static Map<String, int> merge(Object? a, Object? b) =>
      _fit(tsMapMerge(clean(a), clean(b), cap));

  static Map<String, int> add(Object? map, String key, int at) =>
      isKey(key) ? merge(map, {key: at}) : merge(map, null);

  static String refusal(String key) =>
      refusals[key.isEmpty ? '' : key[0]] ?? refusals['p']!;
}

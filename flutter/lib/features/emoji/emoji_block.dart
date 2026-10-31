import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/storage/key_value_store.dart';
import '../../state/app_state.dart'
    show liveCustomEmojiProvider, recentEmojisProvider;
import '../../state/settings_provider.dart' show keyValueStoreProvider;
import 'custom_emoji.dart';

class BlockedEmojiSample {
  const BlockedEmojiSample(this.shortcode, this.url);
  final String shortcode;
  final String url;

  Map<String, Object> toJson() => {'shortcode': shortcode, 'url': url};
}

class BlockedEmojiPack {
  const BlockedEmojiPack({
    required this.coord,
    required this.name,
    required this.sample,
    required this.at,
  });

  final String coord;
  final String name;
  final List<BlockedEmojiSample> sample;
  final int at;

  String get author => EmojiBlock.authorOf(coord);
  String get d => EmojiBlock.dOf(coord);

  Map<String, Object> toJson() => {
        'coord': coord,
        'name': name,
        'sample': [for (final s in sample) s.toJson()],
        'at': at,
      };
}

class EmojiBlockSt {
  EmojiBlockSt(this.coords, this.urls, this.base, this.learned);

  final Set<String> coords;
  final Set<String> urls;
  final Set<String> base;
  final LinkedHashSet<String> learned;

  static final EmojiBlockSt empty =
      EmojiBlockSt(const {}, const {}, const {}, LinkedHashSet<String>());
}

abstract final class EmojiBlock {
  static const String settingsKey = 'nym_blocked_emoji_packs';
  static const String syncField = 'blockedEmojiPacks';
  static const int maxPacks = 200;
  static const int maxSample = 4;
  static const int maxName = 64;
  static const int maxUrl = 1024;
  static const int maxLearned = 4000;

  static final RegExp _code = RegExp(r'^[a-zA-Z0-9_]{1,64}$');
  static final RegExp _url = RegExp(r'^https?://', caseSensitive: false);
  static final RegExp _token = RegExp(r':([a-zA-Z0-9_]+):');
  static final RegExp _control = RegExp(r'[\x00-\x1f\x7f]');
  static final RegExp _whole = RegExp(r'^:([a-zA-Z0-9_]+):$');

  static String _str(Object? v) => v is String ? v : '';

  static bool validCoord(Object? c) =>
      c is String && kEmojiPackCoordRx.hasMatch(c);

  static String coordOf(Object? pubkey, Object? d) {
    final c = '30030:${_str(pubkey)}:${_str(d)}';
    return validCoord(c) ? c : '';
  }

  static String authorOf(String c) => validCoord(c) ? c.substring(6, 70) : '';

  static String dOf(String c) => validCoord(c) ? c.substring(71) : '';

  static bool _jsSpace(int u) =>
      (u >= 0x09 && u <= 0x0d) ||
      u == 0x20 ||
      u == 0xa0 ||
      u == 0x1680 ||
      (u >= 0x2000 && u <= 0x200a) ||
      u == 0x2028 ||
      u == 0x2029 ||
      u == 0x202f ||
      u == 0x205f ||
      u == 0x3000 ||
      u == 0xfeff;

  static String _trim(String s) {
    var a = 0;
    var b = s.length;
    while (a < b && _jsSpace(s.codeUnitAt(a))) {
      a++;
    }
    while (b > a && _jsSpace(s.codeUnitAt(b - 1))) {
      b--;
    }
    return s.substring(a, b);
  }

  static String cleanName(Object? v) {
    var s = _trim(_str(v).replaceAll(_control, ''));
    if (s.length > maxName) {
      s = s.substring(0, maxName);
      final last = s.codeUnitAt(s.length - 1);
      if (last >= 0xD800 && last <= 0xDBFF) s = s.substring(0, s.length - 1);
      s = _trim(s);
    }
    return s;
  }

  static List<BlockedEmojiSample> _cleanPairs(
      Iterable<(String, String)> pairs) {
    final out = <BlockedEmojiSample>[];
    final seen = <String>{};
    for (final (code, url) in pairs) {
      if (out.length >= maxSample) break;
      if (!_code.hasMatch(code) ||
          !_url.hasMatch(url) ||
          url.length > maxUrl ||
          seen.contains(code)) {
        continue;
      }
      seen.add(code);
      out.add(BlockedEmojiSample(code, url));
    }
    return out;
  }

  static List<BlockedEmojiSample> cleanSample(Object? list) {
    if (list is! List) return const [];
    return _cleanPairs([
      for (final e in list)
        if (e is Map) (_str(e['shortcode']), _str(e['url'])),
    ]);
  }

  static int cleanAt(Object? v) {
    if (v is int) return v >= 0 ? v : 0;
    if (v is double && v.isFinite && v == v.truncateToDouble() && v >= 0) {
      return v.toInt();
    }
    return 0;
  }

  static List<BlockedEmojiPack> normalize(Object? list) {
    if (list is! List) return const [];
    final out = <BlockedEmojiPack>[];
    final seen = <String>{};
    for (final item in list) {
      if (item is! Map) continue;
      final coord = _str(item['coord']);
      if (!validCoord(coord) || seen.contains(coord)) continue;
      seen.add(coord);
      out.add(BlockedEmojiPack(
        coord: coord,
        name: cleanName(item['name']),
        sample: cleanSample(item['sample']),
        at: cleanAt(item['at']),
      ));
    }
    return out.length > maxPacks ? out.sublist(out.length - maxPacks) : out;
  }

  static List<BlockedEmojiPack> _renormalize(List<BlockedEmojiPack> list) =>
      normalize([for (final e in list) e.toJson()]);

  static String packCoord(CustomEmojiPack? pack) =>
      pack == null ? '' : coordOf(pack.pubkey, pack.identifier);

  static BlockedEmojiPack? entryFor(CustomEmojiPack pack, Object? at) {
    final coord = packCoord(pack);
    if (coord.isEmpty) return null;
    return BlockedEmojiPack(
      coord: coord,
      name: cleanName(pack.title.isNotEmpty ? pack.title : pack.identifier),
      sample: _cleanPairs([for (final e in pack.emojis) (e.shortcode, e.url)]),
      at: cleanAt(at),
    );
  }

  static List<BlockedEmojiPack> add(
      List<BlockedEmojiPack> list, BlockedEmojiPack entry) {
    final cur = _renormalize(list);
    final e = _renormalize([entry]);
    if (e.isEmpty) return cur;
    return _renormalize(
        [...cur.where((x) => x.coord != e.first.coord), e.first]);
  }

  static List<BlockedEmojiPack> remove(
          List<BlockedEmojiPack> list, String coord) =>
      _renormalize(list).where((x) => x.coord != coord).toList();

  static EmojiBlockSt state(
      List<BlockedEmojiPack> list, Iterable<CustomEmojiPack> packs) {
    final coords = {for (final e in list) e.coord};
    final urls = <String>{};
    for (final e in list) {
      for (final s in e.sample) {
        urls.add(s.url);
      }
    }
    for (final p in packs) {
      if (!coords.contains(packCoord(p))) continue;
      for (final em in p.emojis) {
        if (em.url.isNotEmpty) urls.add(em.url);
      }
    }
    return EmojiBlockSt(coords, urls, {...urls}, LinkedHashSet<String>());
  }

  static int learnTags(List<List<Object?>> tags, EmojiBlockSt st) {
    var added = 0;
    if (st.coords.isEmpty) return added;
    for (final t in tags) {
      if (t.length < 3 || t[0] != 'emoji') continue;
      final url = t[2];
      if (url is! String || url.isEmpty) continue;
      if (t.length < 4) continue;
      final coord = t[3];
      if (coord is! String || !st.coords.contains(coord)) continue;
      if (st.base.contains(url)) continue;
      if (st.learned.contains(url)) {
        st.learned.remove(url);
        st.learned.add(url);
        continue;
      }
      st.learned.add(url);
      st.urls.add(url);
      added++;
      if (st.learned.length > maxLearned) {
        final old = st.learned.first;
        st.learned.remove(old);
        if (!st.base.contains(old)) st.urls.remove(old);
      }
    }
    return added;
  }

  static bool hidden(EmojiBlockSt st, {String? coord, String? url}) {
    if (coord != null && coord.isNotEmpty && st.coords.contains(coord)) {
      return true;
    }
    return url != null && url.isNotEmpty && st.urls.contains(url);
  }

  static String strip(String text, bool Function(String code) isHidden) {
    if (!text.contains(':')) return text;
    return text.replaceAllMapped(
        _token, (m) => isHidden(m.group(1)!) ? '' : m.group(0)!);
  }

  static List<List<String>> reportTags(String coord, String type) {
    if (!validCoord(coord)) return const [];
    final t = type.isNotEmpty ? type : 'other';
    return [
      ['p', authorOf(coord), t],
      ['a', coord, t],
    ];
  }

  static String? tokenCode(String emoji) => _whole.firstMatch(emoji)?.group(1);
}

class HiddenEmoji {
  const HiddenEmoji(this.codes, this.urls, this.coords);

  final Set<String> codes;
  final Set<String> urls;
  final Set<String> coords;

  static const HiddenEmoji none = HiddenEmoji({}, {}, {});

  bool get isEmpty => urls.isEmpty && coords.isEmpty;

  bool code(String code) => codes.contains(code);

  bool url(String? url) => url != null && url.isNotEmpty && urls.contains(url);

  bool token(String emoji) {
    if (codes.isEmpty) return false;
    final code = EmojiBlock.tokenCode(emoji);
    return code != null && codes.contains(code);
  }

  bool pack(CustomEmojiPack p) => coords.contains(EmojiBlock.packCoord(p));

  String strip(String text) =>
      codes.isEmpty ? text : EmojiBlock.strip(text, codes.contains);

  List<String> visible(List<String> emojis) =>
      codes.isEmpty ? emojis : emojis.where((e) => !token(e)).toList();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HiddenEmoji &&
      other.codes.length == codes.length &&
      other.urls.length == urls.length &&
      other.coords.length == coords.length &&
      other.codes.containsAll(codes) &&
      other.urls.containsAll(urls) &&
      other.coords.containsAll(coords);

  @override
  int get hashCode => Object.hash(codes.length, urls.length, coords.length);
}

class BlockedEmojiPacksNotifier extends StateNotifier<List<BlockedEmojiPack>> {
  BlockedEmojiPacksNotifier(this._kv) : super(_load(_kv));

  final KeyValueStore? _kv;

  static List<BlockedEmojiPack> _load(KeyValueStore? kv) {
    if (kv == null) return const [];
    try {
      final raw = kv.getString(EmojiBlock.settingsKey);
      if (raw == null || raw.isEmpty) return const [];
      return EmojiBlock.normalize(jsonDecode(raw));
    } catch (_) {
      return const [];
    }
  }

  Set<String> get coords => {for (final e in state) e.coord};

  bool isBlocked(CustomEmojiPack p) => coords.contains(EmojiBlock.packCoord(p));

  List<Map<String, Object>> syncPayload() =>
      [for (final e in state) e.toJson()];

  void _set(List<BlockedEmojiPack> next) {
    state = List.unmodifiable(next);
    final kv = _kv;
    if (kv == null) return;
    try {
      if (next.isEmpty) {
        kv.remove(EmojiBlock.settingsKey);
      } else {
        kv.setString(EmojiBlock.settingsKey, jsonEncode(syncPayload()));
      }
    } catch (_) {}
  }

  bool block(CustomEmojiPack pack, {int? at}) {
    final entry = EmojiBlock.entryFor(
        pack, at ?? DateTime.now().millisecondsSinceEpoch ~/ 1000);
    if (entry == null) return false;
    _set(EmojiBlock.add(state, entry));
    return true;
  }

  void unblock(String coord) => _set(EmojiBlock.remove(state, coord));

  bool applySynced(Object? raw) {
    if (raw is! List) return false;
    final next = EmojiBlock.normalize(raw);
    if (jsonEncode([for (final e in next) e.toJson()]) ==
        jsonEncode(syncPayload())) {
      return false;
    }
    _set(next);
    return true;
  }

  void reload() => state = List.unmodifiable(_load(_kv));

  void clear() => _set(const []);
}

final blockedEmojiPacksProvider =
    StateNotifierProvider<BlockedEmojiPacksNotifier, List<BlockedEmojiPack>>(
        (ref) {
  KeyValueStore? kv;
  try {
    kv = ref.watch(keyValueStoreProvider);
  } catch (_) {}
  return BlockedEmojiPacksNotifier(kv);
});

class EmojiTagCoordsNotifier extends StateNotifier<int> {
  EmojiTagCoordsNotifier() : super(0);

  final LinkedHashSet<String> _pairs = LinkedHashSet<String>();

  void note(List<List<String>> tags, Set<String> blocked) {
    var changed = false;
    for (final t in tags) {
      if (t.length < 4 || t[0] != 'emoji' || t[2].isEmpty) continue;
      if (!EmojiBlock.validCoord(t[3])) continue;
      final k = '${t[2]}\n${t[3]}';
      if (_pairs.contains(k)) continue;
      if (_pairs.length >= EmojiBlock.maxLearned) _pairs.remove(_pairs.first);
      _pairs.add(k);
      if (blocked.contains(t[3])) changed = true;
    }
    if (changed && mounted) state = state + 1;
  }

  List<List<String>> asTags() => [
        for (final k in _pairs)
          ['emoji', '', k.substring(0, k.indexOf('\n')), k.substring(k.indexOf('\n') + 1)],
      ];

  void clear() {
    _pairs.clear();
    if (mounted) state = state + 1;
  }
}

final emojiTagCoordsProvider =
    StateNotifierProvider<EmojiTagCoordsNotifier, int>(
        (ref) => EmojiTagCoordsNotifier());

final emojiBlockStateProvider = Provider<EmojiBlockSt>((ref) {
  final list = ref.watch(blockedEmojiPacksProvider);
  if (list.isEmpty) return EmojiBlockSt.empty;
  final packs = ref.watch(liveCustomEmojiProvider.select((s) => s.packs));
  ref.watch(emojiTagCoordsProvider);
  final st = EmojiBlock.state(list, packs);
  EmojiBlock.learnTags(
      ref.read(emojiTagCoordsProvider.notifier).asTags(), st);
  return st;
});

final hiddenEmojiProvider = Provider<HiddenEmoji>((ref) {
  final st = ref.watch(emojiBlockStateProvider);
  if (st.coords.isEmpty && st.urls.isEmpty) return HiddenEmoji.none;
  final map = ref.watch(liveCustomEmojiProvider.select((s) => s.codeToUrl));
  final codes = <String>{
    for (final e in map.entries)
      if (st.urls.contains(e.value)) e.key,
  };
  final next = HiddenEmoji(codes, st.urls, st.coords);
  final last = _lastHidden;
  if (last != null && last == next) return last;
  _lastHidden = next;
  return next;
});

HiddenEmoji? _lastHidden;

final visibleCustomEmojiProvider = Provider<CustomEmojiState>((ref) {
  final live = ref.watch(liveCustomEmojiProvider);
  final hidden = ref.watch(hiddenEmojiProvider.select((h) => h));
  if (hidden.isEmpty) return live;
  return CustomEmojiState(
    codeToUrl: {
      for (final e in live.codeToUrl.entries)
        if (!hidden.urls.contains(e.value)) e.key: e.value,
    },
    packs: [
      for (final p in live.packs)
        if (!hidden.pack(p)) p,
    ],
    tagged: live.tagged,
  );
});

final visibleRecentEmojisProvider = Provider<List<String>>((ref) {
  final recents = ref.watch(recentEmojisProvider);
  final hidden = ref.watch(hiddenEmojiProvider.select((h) => h));
  return hidden.visible(recents);
});

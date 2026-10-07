import 'dart:math' as math;

class UnifiedSearchConfig {
  const UnifiedSearchConfig._();

  static const int debounceMs = 150;
  static const int minMessageChars = 2;
  static const SearchLimits pages =
      SearchLimits(channels: 5, nyms: 5, messages: 20);
  static const SearchLimits steps =
      SearchLimits(channels: 10, nyms: 10, messages: 50);
  static const int snippetBefore = 40;
  static const int snippetMax = 160;

  static Map<String, dynamic> toJson() => {
        'debounceMs': debounceMs,
        'minMessageChars': minMessageChars,
        'pages': pages.toJson(),
        'steps': steps.toJson(),
        'snippetBefore': snippetBefore,
        'snippetMax': snippetMax,
      };
}

const Map<String, String> kUnifiedSearchStrings = {
  'title': 'Search',
  'placeholder': 'Search messages, channels and nyms',
  'empty': 'Search messages, channels and nyms',
  'emptyHint': 'Only this device is searched. Nothing you type leaves it.',
  'noResults': 'No results for "{q}"',
  'channels': 'Channels and groups',
  'nyms': 'Nyms',
  'messages': 'Messages',
  'showMore': 'Show more',
  'joinChannel': 'Join #{name}',
  'joinGeohash': 'Join geohash #{name}',
  'group': 'Group',
  'joined': 'Joined',
  'notJoined': 'Not joined',
  'friend': 'Friend',
  'scopeAll': 'Everywhere',
  'scopeChat': 'In {chat}',
  'shortMessages': 'Type at least 2 characters to search messages',
  'close': 'Close search',
  'dm': 'PM with {name}',
  'resultCount': '{n} results',
};

class SearchLimits {
  const SearchLimits({
    required this.channels,
    required this.nyms,
    required this.messages,
  });

  final int channels;
  final int nyms;
  final int messages;

  SearchLimits copyWith({int? channels, int? nyms, int? messages}) =>
      SearchLimits(
        channels: channels ?? this.channels,
        nyms: nyms ?? this.nyms,
        messages: messages ?? this.messages,
      );

  Map<String, dynamic> toJson() =>
      {'channels': channels, 'nyms': nyms, 'messages': messages};
}

enum SearchMode { all, channel, nym }

class SearchQuery {
  const SearchQuery({
    required this.text,
    required this.bare,
    required this.mode,
    required this.tokens,
    required this.nameTokens,
  });

  final String text;
  final String bare;
  final SearchMode mode;
  final List<String> tokens;
  final List<String> nameTokens;

  bool get isEmpty => text.isEmpty;
}

class SearchChannelItem {
  const SearchChannelItem({
    required this.key,
    required this.name,
    required this.kind,
    this.joined = false,
    this.at = 0,
  });

  final String key;
  final String name;
  final String kind;
  final bool joined;
  final int at;
}

class SearchNymItem {
  const SearchNymItem({
    required this.pubkey,
    required this.nym,
    this.npub = '',
    this.friend = false,
    this.at = 0,
  });

  final String pubkey;
  final String nym;
  final String npub;
  final bool friend;
  final int at;
}

class SearchMessageItem {
  SearchMessageItem({
    required this.id,
    required this.key,
    required this.at,
    required this.text,
    this.ref,
  });

  final String id;
  final String key;
  final int at;
  final String text;
  final Object? ref;
  String? _folded;

  String get folded => _folded ??= foldSearchText(text);
}

class SearchJoin {
  const SearchJoin(this.key, {required this.geohash});

  final String key;
  final bool geohash;

  Map<String, dynamic> toJson() => {'key': key, 'geohash': geohash};
}

class SearchGroup<T> {
  const SearchGroup(this.items, this.total);

  final List<T> items;
  final int total;
}

class UnifiedSearchResult {
  const UnifiedSearchResult({
    required this.query,
    required this.channels,
    required this.join,
    required this.nyms,
    required this.messages,
  });

  final SearchQuery query;
  final SearchGroup<SearchChannelItem> channels;
  final SearchJoin? join;
  final SearchGroup<SearchNymItem> nyms;
  final SearchGroup<SearchMessageItem> messages;

  bool get isEmpty =>
      channels.total == 0 &&
      join == null &&
      nyms.total == 0 &&
      messages.total == 0;
}

class SearchSnippet {
  const SearchSnippet(this.text, this.ranges);

  final String text;
  final List<List<int>> ranges;
}

const String _kBase32 = '0123456789bcdefghjkmnpqrstuvwxyz';

const List<(String, String)> _kFoldGroups = [
  ('àáâãäåāăą', 'a'),
  ('çćĉċč', 'c'),
  ('ďđð', 'd'),
  ('èéêëēĕėęě', 'e'),
  ('ĝğġģ', 'g'),
  ('ĥħ', 'h'),
  ('ìíîïĩīĭįı', 'i'),
  ('ĵ', 'j'),
  ('ķ', 'k'),
  ('ĺļľŀł', 'l'),
  ('ñńņňŉ', 'n'),
  ('òóôõöøōŏő', 'o'),
  ('ŕŗř', 'r'),
  ('śŝşšș', 's'),
  ('ţťŧț', 't'),
  ('ùúûüũūŭůűų', 'u'),
  ('ŵ', 'w'),
  ('ýÿŷ', 'y'),
  ('źżž', 'z'),
  ('ß', 'ss'),
  ('æ', 'ae'),
  ('œ', 'oe'),
  ('þ', 'th'),
];

final Map<String, String> _kFold = () {
  final m = <String, String>{};
  for (final (chars, to) in _kFoldGroups) {
    for (final r in chars.runes) {
      m[String.fromCharCode(r)] = to;
    }
  }
  m['ς'] = 'σ';
  m['̇'] = '';
  return m;
}();

final RegExp _nonAscii = RegExp(r'[^\x00-\x7f]');
final RegExp _nameChars = RegExp(r'^[\p{L}\p{N}]+$', unicode: true);
final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
final RegExp _hexKey = RegExp(r'^[0-9a-f]{8,64}$');
final RegExp _hexSuffix = RegExp(r'^[0-9a-f]{4}$');
final RegExp _spaces = RegExp(r'\s+');

bool _isAscii(String s) {
  for (var i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) > 0x7f) return false;
  }
  return true;
}

String foldSearchText(String s) {
  final lower = s.toLowerCase();
  if (_isAscii(lower)) return lower;
  return lower.replaceAllMapped(_nonAscii, (m) {
    final c = m[0]!;
    return _kFold[c] ?? c;
  });
}

class FoldedText {
  const FoldedText(this.text, this.from, this.to);

  final String text;
  final List<int>? from;
  final List<int>? to;
}

FoldedText foldSearchMap(String s) {
  if (_isAscii(s)) return FoldedText(s.toLowerCase(), null, null);
  final b = StringBuffer();
  final from = <int>[];
  final to = <int>[];
  var i = 0;
  for (final r in s.runes) {
    final w = r > 0xffff ? 2 : 1;
    final lc = String.fromCharCode(r).toLowerCase();
    final out = StringBuffer();
    for (final c in lc.runes) {
      final ch = String.fromCharCode(c);
      out.write(_kFold[ch] ?? ch);
    }
    final o = out.toString();
    for (var k = 0; k < o.length; k++) {
      from.add(i);
      to.add(i + w);
    }
    b.write(o);
    i += w;
  }
  return FoldedText(b.toString(), from, to);
}

SearchQuery parseSearchQuery(String raw) {
  final text = foldSearchText(raw).replaceAll(_spaces, ' ').trim();
  var mode = SearchMode.all;
  var bare = text;
  if (bare.startsWith('#')) {
    mode = SearchMode.channel;
    bare = bare.replaceFirst(RegExp(r'^#+'), '');
  } else if (bare.startsWith('@')) {
    mode = SearchMode.nym;
    bare = bare.replaceFirst(RegExp(r'^@+'), '');
  }
  bare = bare.trim();
  return SearchQuery(
    text: text,
    bare: bare,
    mode: mode,
    tokens: text.isEmpty
        ? const []
        : text.split(' ').where((t) => t.isNotEmpty).toList(),
    nameTokens: bare.isEmpty
        ? const []
        : bare.split(' ').where((t) => t.isNotEmpty).toList(),
  );
}

bool isSearchGeohash(String s) {
  if (s.isEmpty || s.length > 12) return false;
  for (var i = 0; i < s.length; i++) {
    if (!_kBase32.contains(s[i])) return false;
  }
  return true;
}

int searchNameScore(String name, String bare, List<String> tokens) {
  if (bare.isEmpty) return 0;
  final n = foldSearchText(name);
  if (n.isEmpty) return 0;
  if (n == bare) return 100;
  if (n.startsWith(bare)) return 80;
  var at = n.indexOf(bare, 1);
  final inside = at >= 0;
  while (at > 0) {
    if (!_wordChar.hasMatch(n[at - 1])) return 60;
    at = n.indexOf(bare, at + 1);
  }
  if (inside) return 40;
  final parts = tokens.isNotEmpty ? tokens : [bare];
  if (parts.length > 1 && parts.every(n.contains)) return 20;
  return 0;
}

int _cmp(String a, String b) => a.compareTo(b);

List<SearchChannelItem> rankSearchChannels(
    SearchQuery q, Iterable<SearchChannelItem> items) {
  if (q.bare.isEmpty || q.mode == SearchMode.nym) return const [];
  final out = <(SearchChannelItem, int)>[];
  for (final it in items) {
    if (it.key.isEmpty) continue;
    final s = searchNameScore(
        it.name.isEmpty ? it.key : it.name, q.bare, q.nameTokens);
    if (s > 0) out.add((it, s));
  }
  out.sort((a, b) {
    var d = b.$2 - a.$2;
    if (d != 0) return d;
    d = (b.$1.joined ? 1 : 0) - (a.$1.joined ? 1 : 0);
    if (d != 0) return d;
    d = b.$1.at.compareTo(a.$1.at);
    if (d != 0) return d;
    d = _cmp(foldSearchText(a.$1.name.isEmpty ? a.$1.key : a.$1.name),
        foldSearchText(b.$1.name.isEmpty ? b.$1.key : b.$1.name));
    if (d != 0) return d;
    d = _cmp(a.$1.key, b.$1.key);
    if (d != 0) return d;
    return _cmp(a.$1.kind, b.$1.kind);
  });
  return [for (final x in out) x.$1];
}

SearchJoin? searchJoinSuggestion(
    SearchQuery q, Iterable<SearchChannelItem> items) {
  if (q.mode == SearchMode.nym || q.nameTokens.length != 1) return null;
  final name = q.bare;
  if (name.length < 2 ||
      !_nameChars.hasMatch(name) ||
      name.startsWith('npub1') ||
      _hexKey.hasMatch(name)) {
    return null;
  }
  for (final it in items) {
    if (it.kind != 'group' && it.key.toLowerCase() == name) return null;
  }
  return SearchJoin(name, geohash: isSearchGeohash(name));
}

int searchNymScore(SearchQuery q, SearchNymItem it) {
  final bare = q.bare;
  if (bare.isEmpty) return 0;
  final pk = it.pubkey.toLowerCase();
  final suffix = pk.length > 4 ? pk.substring(pk.length - 4) : pk;
  if (bare.startsWith('npub1')) {
    return it.npub.toLowerCase().startsWith(bare) ? 90 : 0;
  }
  var best = 0;
  if (_hexKey.hasMatch(bare) && pk.startsWith(bare)) best = 90;
  final hash = bare.lastIndexOf('#');
  if (hash >= 0) {
    final np = bare.substring(0, hash).trim();
    final sp = bare.substring(hash + 1).trim();
    if (sp.isNotEmpty && !suffix.startsWith(sp)) return best;
    if (np.isEmpty) return math.max(best, sp.isNotEmpty ? 60 : 0);
    final s = searchNameScore(it.nym, np, [np]);
    if (s == 0) return best;
    return math.max(best, s == 100 && sp.length == 4 ? 100 : s);
  }
  var s = searchNameScore(it.nym, bare, q.nameTokens);
  if (_hexSuffix.hasMatch(bare) && suffix == bare) s = math.max(s, 70);
  return math.max(best, s);
}

List<SearchNymItem> rankSearchNyms(
    SearchQuery q, Iterable<SearchNymItem> items) {
  if (q.bare.isEmpty || q.mode == SearchMode.channel) return const [];
  final out = <(SearchNymItem, int)>[];
  for (final it in items) {
    if (it.pubkey.isEmpty) continue;
    final s = searchNymScore(q, it);
    if (s > 0) out.add((it, s));
  }
  out.sort((a, b) {
    var d = b.$2 - a.$2;
    if (d != 0) return d;
    d = (b.$1.friend ? 1 : 0) - (a.$1.friend ? 1 : 0);
    if (d != 0) return d;
    d = b.$1.at.compareTo(a.$1.at);
    if (d != 0) return d;
    d = _cmp(foldSearchText(a.$1.nym), foldSearchText(b.$1.nym));
    if (d != 0) return d;
    return _cmp(a.$1.pubkey, b.$1.pubkey);
  });
  return [for (final x in out) x.$1];
}

int _messageOrder(SearchMessageItem a, SearchMessageItem b) {
  var d = b.at.compareTo(a.at);
  if (d != 0) return d;
  d = _cmp(a.id, b.id);
  if (d != 0) return d;
  return _cmp(a.key, b.key);
}

SearchGroup<SearchMessageItem> matchSearchMessages(
  SearchQuery q,
  Iterable<SearchMessageItem> items, {
  int limit = 20,
  String scope = '',
  bool Function(SearchMessageItem)? visible,
}) {
  final cap = math.max(0, limit);
  if (q.text.length < UnifiedSearchConfig.minMessageChars ||
      q.tokens.isEmpty) {
    return const SearchGroup([], 0);
  }
  final tokens = q.tokens;
  final keep = <SearchMessageItem>[];
  final slack = math.max(64, cap * 2);
  var total = 0;
  for (final it in items) {
    if (scope.isNotEmpty && it.key != scope) continue;
    final t = it.folded;
    if (t.isEmpty) continue;
    var ok = true;
    for (var i = 0; i < tokens.length; i++) {
      if (!t.contains(tokens[i])) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    if (visible != null && !visible(it)) continue;
    total++;
    if (cap == 0) continue;
    keep.add(it);
    if (keep.length > slack + cap) {
      keep.sort(_messageOrder);
      keep.length = cap;
    }
  }
  keep.sort(_messageOrder);
  if (keep.length > cap) keep.length = cap;
  return SearchGroup(keep, total);
}

List<List<int>> searchHighlight(String text, List<String> tokens) {
  if (text.isEmpty || tokens.isEmpty) return const [];
  final m = foldSearchMap(text);
  final ranges = <List<int>>[];
  for (final tok in tokens) {
    if (tok.isEmpty) continue;
    var at = m.text.indexOf(tok);
    while (at >= 0) {
      final end = at + tok.length;
      ranges.add(m.from != null ? [m.from![at], m.to![end - 1]] : [at, end]);
      at = m.text.indexOf(tok, end);
    }
  }
  ranges.sort((a, b) {
    final d = a[0] - b[0];
    return d != 0 ? d : a[1] - b[1];
  });
  final out = <List<int>>[];
  for (final r in ranges) {
    if (out.isNotEmpty && r[0] <= out.last[1]) {
      out.last[1] = math.max(out.last[1], r[1]);
    } else {
      out.add([r[0], r[1]]);
    }
  }
  return out;
}

bool _isHigh(int c) => c >= 0xd800 && c <= 0xdbff;
bool _isLow(int c) => c >= 0xdc00 && c <= 0xdfff;

SearchSnippet searchSnippet(String text, List<String> tokens,
    {int? before, int? max}) {
  final b = before ?? UnifiedSearchConfig.snippetBefore;
  final mx = max ?? UnifiedSearchConfig.snippetMax;
  final flat = text.replaceAll(_spaces, ' ').trim();
  final ranges = searchHighlight(flat, tokens);
  if (flat.length <= mx) return SearchSnippet(flat, ranges);
  final first = ranges.isNotEmpty ? ranges.first[0] : 0;
  var start = math.max(0, first - b);
  if (start + mx > flat.length) start = math.max(0, flat.length - mx);
  if (start > 0 && _isLow(flat.codeUnitAt(start))) start--;
  var end = math.min(flat.length, start + mx);
  if (end < flat.length && _isHigh(flat.codeUnitAt(end - 1))) end--;
  final pre = start > 0 ? '…' : '';
  final post = end < flat.length ? '…' : '';
  final shift = pre.length - start;
  final out = <List<int>>[];
  for (final r in ranges) {
    final s = math.max(r[0], start);
    final e = math.min(r[1], end);
    if (e > s) out.add([s + shift, e + shift]);
  }
  return SearchSnippet('$pre${flat.substring(start, end)}$post', out);
}

UnifiedSearchResult unifiedSearch(
  String raw, {
  Iterable<SearchChannelItem> channels = const [],
  Iterable<SearchNymItem> nyms = const [],
  Iterable<SearchMessageItem> messages = const [],
  SearchLimits limits = UnifiedSearchConfig.pages,
  String scope = '',
  bool Function(SearchMessageItem)? visible,
}) {
  final q = parseSearchQuery(raw);
  final ch = scope.isNotEmpty
      ? const <SearchChannelItem>[]
      : rankSearchChannels(q, channels);
  final ny =
      scope.isNotEmpty ? const <SearchNymItem>[] : rankSearchNyms(q, nyms);
  final join = scope.isNotEmpty ? null : searchJoinSuggestion(q, channels);
  final msgs = matchSearchMessages(q, messages,
      limit: limits.messages, scope: scope, visible: visible);
  return UnifiedSearchResult(
    query: q,
    channels: SearchGroup(ch.take(limits.channels).toList(), ch.length),
    join: join,
    nyms: SearchGroup(ny.take(limits.nyms).toList(), ny.length),
    messages: msgs,
  );
}

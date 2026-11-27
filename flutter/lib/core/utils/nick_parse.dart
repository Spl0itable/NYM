import 'dart:typed_data';

import 'package:flutter/widgets.dart' show StringCharacters;

const int kMentionNameMax = 20;
const int _runMax = 3;

final RegExp _wordy = RegExp(r'[\p{L}\p{N}\p{M}_]', unicode: true);
final RegExp _breaks = RegExp('\r\n|[\r\n\u000B\u000C\u0085\u2028\u2029]');
final RegExp _skip = RegExp(r'```[\s\S]*?```|```[\s\S]+$|`[^`]+?`|https?://\S+',
    caseSensitive: false);
final RegExp _trigger = RegExp(r'(?:^|\s)@([^\s]*)$');
final RegExp _leadWs = RegExp(r'^\s+');
final RegExp _space = RegExp(r'\s');
final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
final RegExp _tail4 = RegExp(r'[0-9a-f]{4}$');
final RegExp _splitSuffix =
    RegExp(r'^([\s\S]+)#([0-9a-f]{1,4})$', caseSensitive: false);
final RegExp _channelName = RegExp(r'^[\p{L}\p{N}]+$', unicode: true);
final RegExp _npub = RegExp(r'^npub1[0-9a-z]+$', caseSensitive: false);
final RegExp _tagWord = RegExp(r'[^#]#[0-9a-f]{4}$', caseSensitive: false);
final RegExp _zapLine = RegExp(r'^[ \t]*⚡.*$', multiLine: true);
final RegExp _ws = RegExp(r'\s+');

class NickMention {
  const NickMention(this.start, this.end, this.name, this.suffix);
  final int start;
  final int end;
  final String name;
  final String? suffix;
}

class QuoteHead {
  const QuoteHead(this.author, this.suffix, this.body);
  final String author;
  final String suffix;
  final String body;
  String get label => suffix.isEmpty ? author : '$author#$suffix';
}

class NickUser {
  const NickUser(this.pubkey, this.nym);
  final String pubkey;
  final String nym;
}

class NickHit {
  const NickHit(this.pubkey, this.nym)
      : ambiguous = const <NickUser>[],
        name = '';
  const NickHit.ambiguous(this.ambiguous, this.name)
      : pubkey = null,
        nym = '';
  const NickHit.channel(this.name)
      : pubkey = null,
        nym = '',
        ambiguous = const <NickUser>[];
  final String? pubkey;
  final String nym;
  final List<NickUser> ambiguous;
  final String name;
  bool get isAmbiguous => ambiguous.isNotEmpty;
  bool get isChannel => pubkey == null && ambiguous.isEmpty && name.isNotEmpty;
}

int _countUpTo(String s, int cap) => s.characters.take(cap).length;

bool _isWs(int c) =>
    c == 32 ||
    (c >= 9 && c <= 13) ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000 ||
    c == 0xFEFF;

bool _isHard(int c) =>
    c == 10 || c == 13 || c == 1 || (c >= 0xFDD0 && c <= 0xFDEF);

bool _isDelim(int c) => c == 42 || c == 95 || c == 124 || c == 126;

bool _isWordAscii(int c) =>
    (c >= 48 && c <= 57) ||
    (c >= 65 && c <= 90) ||
    (c >= 97 && c <= 122) ||
    c == 95;

bool _isHex(int c) =>
    (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102);

bool isNickTag(String s, int j) {
  if (j < 0 || j + 5 > s.length || s.codeUnitAt(j) != 35) return false;
  for (var k = j + 1; k < j + 5; k++) {
    if (!_isHex(s.codeUnitAt(k))) return false;
  }
  return !(j + 5 < s.length && _isWordAscii(s.codeUnitAt(j + 5)));
}

String _charBefore(String s, int at) {
  if (at <= 0) return '';
  final c = s.codeUnitAt(at - 1);
  if (c >= 0xDC00 && c <= 0xDFFF && at >= 2) {
    final h = s.codeUnitAt(at - 2);
    if (h >= 0xD800 && h <= 0xDBFF) return s.substring(at - 2, at);
  }
  return s[at - 1];
}

String _charAfter(String s, int at) {
  if (at >= s.length) return '';
  final c = s.codeUnitAt(at);
  if (c >= 0xD800 && c <= 0xDBFF && at + 1 < s.length) {
    return s.substring(at, at + 2);
  }
  return s[at];
}

bool _wordyBefore(String s, int at) {
  if (at <= 0) return false;
  final c = s.codeUnitAt(at - 1);
  if (c < 128) return _isWordAscii(c);
  return _wordy.hasMatch(_charBefore(s, at));
}

bool _wordyAt(String s, int at) {
  if (at >= s.length) return false;
  final c = s.codeUnitAt(at);
  if (c < 128) return _isWordAscii(c);
  return _wordy.hasMatch(_charAfter(s, at));
}

bool _canStart(String s, int at) {
  if (!_wordyBefore(s, at)) return true;
  if (s.codeUnitAt(at - 1) != 95) return false;
  var k = at - 1;
  while (k > 0 && _isDelim(s.codeUnitAt(k - 1))) {
    k--;
  }
  return !_wordyBefore(s, k);
}

List<List<int>> _skipRanges(String s) => [
      for (final m in _skip.allMatches(s))
        if (m.end > m.start) [m.start, m.end]
    ];

class _Scan {
  _Scan(this.s);
  final String s;
  int tag = -1;
  int tagFrom = -1;
  int hard = -1;
  int hardFrom = -1;
  int wsAt = -1;
  int wsAtFrom = -1;
  Uint32List? ascii;
  int line = 0;
  int lineTo = 0;
  int nl = -2;
  final Map<String, (int, int)> runs = {};

  int nextTag(int from) {
    if (tagFrom >= 0 && tagFrom <= from && (tag < 0 || tag >= from)) {
      return tag;
    }
    var j = s.indexOf('#', from);
    while (j >= 0 && !isNickTag(s, j)) {
      j = s.indexOf('#', j + 1);
    }
    tagFrom = from;
    tag = j;
    return j;
  }

  int nextHard(int from) {
    if (hardFrom >= 0 && hardFrom <= from && (hard < 0 || hard >= from)) {
      return hard;
    }
    var j = from;
    while (j < s.length && !_isHard(s.codeUnitAt(j))) {
      j++;
    }
    hardFrom = from;
    hard = j < s.length ? j : -1;
    return hard;
  }

  int nextWsAt(int from) {
    if (wsAtFrom >= 0 && wsAtFrom <= from && (wsAt < 0 || wsAt >= from)) {
      return wsAt;
    }
    var a = from + 1 < s.length ? s.indexOf('@', from + 1) : -1;
    while (a >= 0 && !_isWs(s.codeUnitAt(a - 1))) {
      a = a + 1 < s.length ? s.indexOf('@', a + 1) : -1;
    }
    wsAtFrom = from;
    wsAt = a >= 0 ? a - 1 : -1;
    return wsAt;
  }

  int asciiIn(int a, int j) {
    var p = ascii;
    if (p == null) {
      p = Uint32List(s.length + 1);
      for (var i = 0; i < s.length; i++) {
        p[i + 1] = p[i] + (s.codeUnitAt(i) < 0x80 ? 1 : 0);
      }
      ascii = p;
    }
    return p[j] - p[a];
  }

  int lineStart(int at) {
    if (at < lineTo) {
      return at <= 0 ? 0 : s.lastIndexOf('\n', at - 1) + 1;
    }
    for (;;) {
      if (nl == -2) nl = s.indexOf('\n', lineTo);
      if (nl < 0 || nl >= at) break;
      line = nl + 1;
      lineTo = nl + 1;
      nl = -2;
    }
    lineTo = at;
    return line;
  }

  bool opened(int at, String run) {
    if (run.length > _runMax) return false;
    final from = lineStart(at);
    final want = String.fromCharCodes(run.codeUnits.reversed);
    final hit = runs[want];
    int idx;
    if (hit != null && hit.$1 <= from && (hit.$2 < 0 || hit.$2 >= from)) {
      idx = hit.$2;
    } else {
      idx = from <= s.length ? s.indexOf(want, from) : -1;
      runs[want] = (from, idx);
    }
    return idx >= 0 && idx + want.length <= at;
  }

  bool validName(int a, int j) {
    if (j <= a || _isWs(s.codeUnitAt(a)) || _isWs(s.codeUnitAt(j - 1))) {
      return false;
    }
    final h = nextHard(a);
    if (h >= 0 && h < j) return false;
    final wa = nextWsAt(a);
    if (wa >= 0 && wa + 1 < j) return false;
    final len = j - a;
    if (len <= kMentionNameMax) return true;
    final asc = asciiIn(a, j);
    if (asc > kMentionNameMax || asc == len) return false;
    return _countUpTo(s.substring(a, j), kMentionNameMax + 1) <=
        kMentionNameMax;
  }

  NickMention? suffixedAt(int at, int stop) {
    final a = at + 1;
    if (a >= stop || _isWs(s.codeUnitAt(a))) return null;
    final j = nextTag(a);
    if (j < 0 || j + 5 > stop || !validName(a, j)) return null;
    final suffix = s.substring(j + 1, j + 5);
    var end = j + 5;
    if (end + 5 <= stop &&
        isNickTag(s, end) &&
        s.substring(end + 1, end + 5).toLowerCase() == suffix.toLowerCase()) {
      end += 5;
    }
    return NickMention(at, end, s.substring(a, j), suffix);
  }

  NickMention? bareAt(int at, int stop) {
    var j = at + 1;
    while (j < stop) {
      final c = s.codeUnitAt(j);
      if (c == 64 || _isWs(c) || _isHard(c)) break;
      j++;
    }
    if (j == at + 1) return null;
    var e = j;
    if (!_isDelim(s.codeUnitAt(at + 1))) {
      while (_isDelim(s.codeUnitAt(e - 1))) {
        e--;
      }
      if (e < j && !opened(at, s.substring(e, j))) e = j;
    }
    return NickMention(at, e, s.substring(at + 1, e), null);
  }

  bool endsBare(int at, int end) {
    if (!_wordyAt(s, end)) return true;
    var e = end;
    while (e < s.length && _isDelim(s.codeUnitAt(e))) {
      e++;
    }
    if (e == end || _wordyAt(s, e)) return false;
    return opened(at, s.substring(end, e));
  }
}

typedef NickKnown = bool Function(String name, String suffix);

List<NickMention> nickMentions(String text, {NickKnown? known}) {
  final out = <NickMention>[];
  if (!text.contains('@')) return out;
  final sc = _Scan(text);
  final skip = _skipRanges(text);
  var k = 0;
  var i = 0;
  while (i < text.length) {
    final at = text.indexOf('@', i);
    if (at < 0) break;
    while (k < skip.length && skip[k][1] <= at) {
      k++;
    }
    if (k < skip.length && skip[k][0] <= at) {
      i = skip[k][1];
      continue;
    }
    if (!_canStart(text, at)) {
      i = at + 1;
      continue;
    }
    final stop = k < skip.length ? skip[k][0] : text.length;
    var m = sc.suffixedAt(at, stop);
    if (m != null &&
        known != null &&
        _space.hasMatch(m.name) &&
        !known(m.name, m.suffix!)) {
      m = null;
    }
    m ??= sc.bareAt(at, stop);
    if (m != null) {
      out.add(m);
      i = m.end;
    } else {
      i = at + 1;
    }
  }
  return out;
}

List<String> splitNickMentions(String text) {
  final out = <String>[];
  var at = 0;
  for (final m in nickMentions(text)) {
    out
      ..add(text.substring(at, m.start))
      ..add(text.substring(m.start, m.end));
    at = m.end;
  }
  out.add(text.substring(at));
  return out;
}

String quoteHeaderName(String author) => author.replaceAll(_breaks, ' ');

String mentionName(String base) => quoteHeaderName(base).trim();

String _key(String name) => mentionName(name).toLowerCase();

QuoteHead? parseQuoteHead(String line) {
  var s = line;
  if (s.startsWith('>')) s = s.substring(1);
  s = s.replaceFirst(_leadWs, '');
  if (!s.startsWith('@')) return null;
  var lead = 1;
  while (lead < s.length && _isWs(s.codeUnitAt(lead))) {
    lead++;
  }
  QuoteHead? cand;
  var first = -1;
  for (var j = s.indexOf('#', 1); j >= 0;
      j = j + 1 < s.length ? s.indexOf('#', j + 1) : -1) {
    if (!isNickTag(s, j)) continue;
    if (first < 0) first = j;
    if (j < 2 || j <= lead) continue;
    final suffix = s.substring(j + 1, j + 5);
    var end = j + 5;
    if ((end >= s.length || s.codeUnitAt(end) != 58) &&
        isNickTag(s, end) &&
        s.substring(end + 1, end + 5).toLowerCase() == suffix.toLowerCase()) {
      end += 5;
    }
    if (end < s.length && s.codeUnitAt(end) == 58) {
      cand = QuoteHead(s.substring(1, j), suffix,
          s.substring(end + 1).replaceFirst(_leadWs, ''));
      break;
    }
  }
  final colon = s.indexOf(':');
  final fb = colon > lead && (first < 0 || first >= colon)
      ? QuoteHead(s.substring(1, colon), '',
          s.substring(colon + 1).replaceFirst(_leadWs, ''))
      : null;
  if (cand != null && fb != null) {
    final a = cand.author;
    if (_isWs(a.codeUnitAt(a.length - 1)) ||
        _countUpTo(a.trim(), kMentionNameMax + 1) > kMentionNameMax) {
      return fb;
    }
  }
  return cand ?? fb;
}

List<String> quoteHeadLabels(String text) => [
      for (final line in text.split('\n'))
        if (line.startsWith('>'))
          if (parseQuoteHead(line) case final h?) h.label
    ];

String nickTail(String pubkey) {
  final p = pubkey.toLowerCase();
  if (_hex64.hasMatch(p)) return p.substring(60);
  final m = _tail4.firstMatch(p);
  return m == null ? '' : m.group(0)!;
}

String nickBase(String nym, String pubkey) {
  final t = nickTail(pubkey);
  return t.isNotEmpty && nym.toLowerCase().endsWith('#$t')
      ? nym.substring(0, nym.length - 5)
      : nym;
}

NickHit? _pick(Map<String, NickUser> hits, String name) {
  if (hits.isEmpty) return null;
  if (hits.length == 1) {
    final u = hits.values.first;
    return NickHit(u.pubkey, u.nym);
  }
  return NickHit.ambiguous(hits.values.toList(), name);
}

NickHit? resolveMentionIn(String name, String? suffix, Iterable<NickUser> users) {
  final want = _key(name);
  if (want.isEmpty) return null;
  final sfx = (suffix ?? '').toLowerCase();
  final hits = <String, NickUser>{};
  for (final u in users) {
    final pk = u.pubkey.toLowerCase();
    if (pk.isEmpty || hits.containsKey(pk)) continue;
    if (sfx.isNotEmpty && !pk.endsWith(sfx)) continue;
    final base = nickBase(u.nym, pk);
    if (_key(base) == want) hits[pk] = NickUser(pk, base);
  }
  return _pick(hits, mentionName(name));
}

String nickNameKey(String name) => _key(name);

String nickKeyOf(String nym, String pubkey) => _key(nickBase(nym, pubkey));

List<({String key, String sfx, String name})> _targetQueries(String s) {
  final tries = <String>[s];
  if (s.startsWith('@') && s.length > 1) tries.add(s.substring(1));
  final queries = <({String key, String sfx, String name})>[];
  for (final t in tries) {
    final m = _splitSuffix.firstMatch(t);
    if (m != null) {
      queries.add((key: _key(m[1]!), sfx: m[2]!.toLowerCase(), name: m[1]!));
    }
    queries.add((key: _key(t), sfx: '', name: t));
  }
  return queries;
}

Set<String> nickTargetKeys(String input) {
  final s = input.trim();
  if (s.isEmpty || _hex64.hasMatch(s)) return const <String>{};
  return {
    for (final q in _targetQueries(s))
      if (q.key.isNotEmpty) q.key
  };
}

NickHit? resolveTargetIn(String input, Iterable<NickUser> users) {
  final s = input.trim();
  if (s.isEmpty) return null;
  if (_hex64.hasMatch(s)) return NickHit(s.toLowerCase(), '');
  final tries = <String>[s];
  if (s.startsWith('@') && s.length > 1) tries.add(s.substring(1));
  final queries = _targetQueries(s);
  final hits = <String, NickUser>{};
  var named = '';
  for (final u in users) {
    final pk = u.pubkey.toLowerCase();
    if (pk.isEmpty || hits.containsKey(pk)) continue;
    final base = nickBase(u.nym, pk);
    final k = _key(base);
    for (final q in queries) {
      if (q.key.isEmpty || k != q.key) continue;
      if (q.sfx.isNotEmpty && !pk.endsWith(q.sfx)) continue;
      hits[pk] = NickUser(pk, base);
      if (named.isEmpty) named = q.name;
      break;
    }
  }
  return _pick(hits, mentionName(named.isEmpty ? tries.last : named));
}

String channelTargetOf(String input) {
  final s = input.trim();
  if (!s.startsWith('#')) return '';
  final name = s.substring(1);
  if (!_channelName.hasMatch(name)) return '';
  final out = StringBuffer();
  for (final r in name.runes) {
    out.write(r == 0x130 ? 'i' : String.fromCharCode(r).toLowerCase());
  }
  return out.toString();
}

NickHit? blockTargetIn(String input, Iterable<NickUser> users) {
  final hit = resolveTargetIn(input, users);
  if (hit != null) return hit;
  final ch = channelTargetOf(input);
  return ch.isEmpty ? null : NickHit.channel(ch);
}

({bool mentioned, bool quoted}) selfMentionOf(
    String content, String base, String pubkey,
    {NickKnown? known}) {
  final own = mentionName(base);
  if (own.isEmpty || content.isEmpty) return (mentioned: false, quoted: false);
  final sfx = nickTail(pubkey);
  final want = own.toLowerCase();
  var quoted = false;
  final kept = <String>[];
  for (final line in content.split('\n')) {
    final t = line.replaceFirst(_leadWs, '');
    if (!t.startsWith('>')) {
      kept.add(line);
      continue;
    }
    if (quoted || sfx.isEmpty) continue;
    final inner = t.substring(1).replaceFirst(_leadWs, '');
    if (inner.startsWith('>')) continue;
    final h = parseQuoteHead(inner);
    if (h != null &&
        h.suffix.isNotEmpty &&
        h.suffix.toLowerCase() == sfx &&
        _key(h.author) == want) {
      quoted = true;
    }
  }
  final text = kept.join('\n');
  if (!text.contains('@')) return (mentioned: false, quoted: quoted);
  final ms = nickMentions(text, known: known);
  for (final m in ms) {
    final s = m.suffix;
    if (s != null &&
        sfx.isNotEmpty &&
        s.toLowerCase() == sfx &&
        _key(m.name) == want) {
      return (mentioned: true, quoted: quoted);
    }
  }
  final held = [
    for (final m in ms)
      if (m.suffix != null) [m.start, m.end]
  ];
  final skip = _skipRanges(text);
  final taken = <List<int>>[];
  for (var x = 0, y = 0; x < held.length || y < skip.length;) {
    if (y >= skip.length || (x < held.length && held[x][0] < skip[y][0])) {
      taken.add(held[x++]);
    } else {
      taken.add(skip[y++]);
    }
  }
  final sc = _Scan(text);
  var r = 0;
  var at = text.indexOf('@');
  while (at >= 0) {
    while (r < taken.length && taken[r][1] <= at) {
      r++;
    }
    if (r < taken.length && taken[r][0] <= at) {
      final next = taken[r][1];
      at = next < text.length ? text.indexOf('@', next) : -1;
      continue;
    }
    if (_canStart(text, at)) {
      final end = at + 1 + own.length;
      if (end <= text.length &&
          text.substring(at + 1, end).toLowerCase() == want &&
          sc.endsBare(at, end)) {
        return (mentioned: true, quoted: quoted);
      }
    }
    at = at + 1 < text.length ? text.indexOf('@', at + 1) : -1;
  }
  return (mentioned: false, quoted: quoted);
}

({List<String> members, String name}) groupArgsOf(String args) {
  final members = <String>[];
  final words = <String>[];
  void take(String part) {
    for (final w in part.split(_ws)) {
      if (w.isEmpty) continue;
      if (_hex64.hasMatch(w) || _npub.hasMatch(w)) {
        members.add(w);
      } else if (!w.startsWith('#') &&
          _tagWord.hasMatch(w) &&
          isNickTag(w, w.length - 5)) {
        members.add(w);
      } else {
        words.add(w);
      }
    }
  }

  var at = 0;
  for (final m in nickMentions(args)) {
    take(args.substring(at, m.start));
    members.add(args.substring(m.start, m.end));
    at = m.end;
  }
  take(args.substring(at));
  return (members: members, name: words.join(' '));
}

String stripNickEnvelope(String text) {
  var s = text;
  final ms = nickMentions(s);
  if (ms.isNotEmpty && ms.first.start == 0) {
    var e = ms.first.end;
    while (e < s.length && (s[e] == ' ' || s[e] == '\t')) {
      e++;
    }
    if (e > ms.first.end) s = s.substring(e);
  }
  return s.replaceAll(_zapLine, '');
}

List<String> shieldNickMentions(String text) =>
    [for (final m in nickMentions(text)) text.substring(m.start, m.end)];

String nickMentionText(String nym, String pubkey) {
  final t = nickTail(pubkey);
  return '@${mentionName(nickBase(nym, pubkey))}${t.isEmpty ? '' : '#$t'}';
}

({String value, int caret, int start})? insertNickMention(
    String value, int caret, String nym, String pubkey) {
  final c = caret < 0 || caret > value.length ? value.length : caret;
  final m = _trigger.firstMatch(value.substring(0, c));
  if (m == null) return null;
  final start = c - m[1]!.length - 1;
  final ins = '${nickMentionText(nym, pubkey)} ';
  return (
    value: value.substring(0, start) + ins + value.substring(c),
    caret: start + ins.length,
    start: start,
  );
}

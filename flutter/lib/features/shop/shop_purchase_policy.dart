import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// iOS doesn't sell (App Store 3.1.1): it shows a plain statement, and adding any tap target there would break compliance.
bool? debugPurchasesDisabledOverride;

bool get shopPurchasesDisabled {
  final o = debugPurchasesDisabledOverride;
  if (o != null) return o;
  if (kIsWeb) return false;
  try {
    return Platform.isIOS;
  } catch (_) {
    return false;
  }
}

/// Same answer as [shopPurchasesDisabled]; separate so each surface can change independently.
bool get botCreditPurchasesDisabled => shopPurchasesDisabled;

final RegExp _kSelling = RegExp(
    r'\?buy|\bbuy\b|\bbought\b|top up|purchas|web app|browser',
    caseSensitive: false);

const String kIosFreeDailyWording = 'The free daily replies stay free.';

const List<(String, String)> kIosBotBuyRewrites = [
  (
    '. Type ?buy and switch to Pro to top up, or ?model off for standard replies.',
    '. Type ?model off for standard replies. The free daily replies stay free.'
  ),
  (
    ', or type ?buy for credits, which also unlock the sharper models, images and web search.',
    '. Credits also unlock the sharper models, images and web search.'
  ),
  (
    'Wait for it to finish, or type ?buy for credits to run up to 3 requests at once.',
    'Wait for it to finish. With credits, up to 3 requests run at once.'
  ),
  ('Wait for it to finish, or type ?buy for more.', 'Wait for it to finish.'),
  ('Type ?buy to top up; ', ''),
  ('. Type ?buy for more.', '. The free daily replies stay free.'),
];

String iosBotBuyRewrite(String text) {
  if (!botCreditPurchasesDisabled || !_kBuyAny.hasMatch(text)) return text;
  final s = _pinnedBuyRewrite(text);
  if (!_kBuyAny.hasMatch(s)) return s;
  return _rewriteBuySentences(s);
}

String _pinnedBuyRewrite(String text) {
  var s = text;
  for (final (from, to) in kIosBotBuyRewrites) {
    s = s.replaceAll(from, to);
  }
  return s;
}

final RegExp _kBuyAny = RegExp(r'\?buy', caseSensitive: false);
final RegExp _kBuyBare =
    RegExp(r'(?<![\w/=&?#.])\?buy\b', caseSensitive: false);
final RegExp _kBuyCode =
    RegExp(r'^\s*\?buy(?:\s[\s\S]*)?$', caseSensitive: false);
final RegExp _kFence = RegExp(r'^ {0,3}(`{3,}|~{3,})');
final RegExp _kLinePrefix =
    RegExp(r'^\s*(?:>\s?)*(?:[-*+]\s+|\d{1,9}[.)]\s+)?(?:#{1,6}\s+)?');
final RegExp _kLetter = RegExp(r'\p{L}', unicode: true);
final RegExp _kLower = RegExp(r'^\p{Ll}', unicode: true);
const String _kEnds = '.!?…';
const String _kWideEnds = '。！？';
const String _kClosers = ')]"\'”’»';
const Set<String> _kNeverEnds = {
  'mr', 'mrs', 'ms', 'dr', 'st', 'prof', 'sr', 'jr', 'vs', 'e.g', 'i.e'
};
final RegExp _kWordChar = RegExp(r'[A-Za-z.]');
final RegExp _kWrapEnd = RegExp(r'[,;–—(]\s*$');
final RegExp _kBlockStart =
    RegExp(r'^\s*(?:$|>|[-*+]\s|\d{1,9}[.)]\s|#{1,6}\s|\||`{3,}|~{3,})');

bool _wraps(String line, String next) =>
    _kWrapEnd.hasMatch(line) &&
    !_kBlockStart.hasMatch(next) &&
    !RegExp(r'^\s*(?:#{1,6}\s|\|)').hasMatch(line);

String _rewriteBuySentences(String text) {
  final lines = text.split('\n');
  String? fence;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final f = _kFence.firstMatch(line)?.group(1);
    if (fence != null) {
      if (f != null &&
          f[0] == fence[0] &&
          f.length >= fence.length &&
          line.trim() == f) {
        fence = null;
      }
      continue;
    }
    if (f != null) {
      fence = f;
      continue;
    }
    var end = i;
    while (end + 1 < lines.length && _wraps(lines[end], lines[end + 1])) {
      end++;
    }
    final block = lines.sublist(i, end + 1).join('\n');
    if (_kBuyAny.hasMatch(block)) {
      lines.replaceRange(i, end + 1, [_rewriteBuyLine(block)]);
    } else {
      i = end;
    }
  }
  return lines.join('\n');
}

bool _continuesAfter(String body, int at, String run, int next) {
  if (next >= body.length) return false;
  var w = at;
  while (w > 0 && _kWordChar.hasMatch(body[w - 1])) {
    w--;
  }
  final word = body.substring(w, at).toLowerCase();
  if (run == '.' && _kNeverEnds.contains(word)) return true;
  final trailing =
      run.contains('…') || run.contains('..') || (run == '.' && word == 'etc');
  return trailing && _kLower.hasMatch(body[next]);
}

String _rewriteBuyLine(String line) {
  if (line.trimLeft().startsWith('|')) {
    return line
        .split('|')
        .map((cell) => _kBuyAny.hasMatch(cell) ? _rewriteBuyProse(cell) : cell)
        .join('|');
  }
  final prefix = _kLinePrefix.firstMatch(line)!.group(0)!;
  return prefix + _rewriteBuyProse(line.substring(prefix.length));
}

bool _isSpace(String ch) => ch.trim().isEmpty;

List<(int, int)> _codeSpans(String s) {
  final out = <(int, int)>[];
  int runAt(int i) {
    var r = 0;
    while (i + r < s.length && s[i + r] == '`') {
      r++;
    }
    return r;
  }

  var i = 0;
  while (i < s.length) {
    if (s[i] != '`') {
      i++;
      continue;
    }
    final run = runAt(i);
    var j = i + run;
    var close = -1;
    while (j < s.length) {
      if (s[j] != '`') {
        j++;
        continue;
      }
      final r = runAt(j);
      if (r == run) {
        close = j;
        break;
      }
      j += r;
    }
    if (close < 0) {
      i += run;
      continue;
    }
    out.add((i, close + run));
    i = close + run;
  }
  return out;
}

String _rewriteBuyProse(String body) {
  final spans = {for (final (a, b) in _codeSpans(body)) a: b};
  final n = body.length;
  var i = 0;
  while (i < n && _isSpace(body[i])) {
    i++;
  }
  final out = StringBuffer(body.substring(0, i));
  final sentences = <(String, String)>[];
  var start = i;
  while (i < n) {
    final end = spans[i];
    if (end != null) {
      i = end;
      continue;
    }
    final ch = body[i];
    final wide = _kWideEnds.contains(ch);
    if (!wide && !_kEnds.contains(ch)) {
      i++;
      continue;
    }
    var j = i + 1;
    while (j < n && (_kEnds.contains(body[j]) || _kWideEnds.contains(body[j]))) {
      j++;
    }
    final run = body.substring(i, j);
    while (j < n && _kClosers.contains(body[j])) {
      j++;
    }
    if (j >= n) {
      i = n;
      break;
    }
    if (!wide && !_isSpace(body[j])) {
      i = j;
      continue;
    }
    var k = j;
    while (k < n && _isSpace(body[k])) {
      k++;
    }
    if (!wide && _continuesAfter(body, i, run, k)) {
      i = k;
      continue;
    }
    sentences.add((body.substring(start, j), body.substring(j, k)));
    start = k;
    i = k;
  }
  if (start < n) {
    final rest = body.substring(start);
    final kept = rest.trimRight();
    sentences.add((kept, rest.substring(kept.length)));
  }
  String? pendingSep;
  String? prev;
  var prevReplaced = false;
  for (final (sentence, sep) in sentences) {
    final (shown, replaced) = _rewriteBuySentence(sentence);
    if (shown == kIosFreeDailyWording &&
        prev == kIosFreeDailyWording &&
        (replaced || prevReplaced)) {
      pendingSep = sep;
      continue;
    }
    if (pendingSep != null) out.write(pendingSep);
    out.write(shown);
    pendingSep = sep;
    prev = shown;
    prevReplaced = replaced;
  }
  if (pendingSep != null) out.write(pendingSep);
  return out.toString();
}

(String, bool) _rewriteBuySentence(String s) {
  final spans = _codeSpans(s);
  bool inCode(int p) => spans.any((r) => p >= r.$1 && p < r.$2);
  final mentions = <int>[
    for (final m in _kBuyBare.allMatches(s))
      if (!inCode(m.start)) m.start,
    for (final (a, b) in spans)
      if (_kBuyCode.hasMatch(s.substring(a, b).replaceAll(RegExp(r'^`+|`+$'), '')))
        a,
  ];
  if (mentions.isEmpty) return (s, false);
  final spanEnds = {for (final (a, b) in spans) a: b};
  final groups = <(int, int)>[];
  var depth = 0;
  var open = -1;
  for (var i = 0; i < s.length; i++) {
    final spanEnd = spanEnds[i];
    if (spanEnd != null) {
      i = spanEnd - 1;
      continue;
    }
    if (s[i] == '(') {
      if (depth == 0) open = i;
      depth++;
    } else if (s[i] == ')' && depth > 0) {
      depth--;
      if (depth == 0) groups.add((open, i + 1));
    }
  }
  final hit = [
    for (final g in groups)
      if (mentions.any((p) => p >= g.$1 && p < g.$2)) g
  ];
  if (mentions.every((p) => hit.any((g) => p >= g.$1 && p < g.$2))) {
    var kept = s;
    for (final (a, b) in hit.reversed) {
      var from = a;
      while (from > 0 && _isSpace(kept[from - 1])) {
        from--;
      }
      kept = kept.substring(0, from) + kept.substring(b);
    }
    if (_kLetter.hasMatch(kept)) return (kept, false);
  }
  return (kIosFreeDailyWording, true);
}

String withoutBuyHints(String text) {
  if (!botCreditPurchasesDisabled) return text;
  final rewritten = _pinnedBuyRewrite(text);
  if (!_kSelling.hasMatch(rewritten)) return rewritten;
  final s = rewritten
      .replaceAll(
          RegExp(r'Type \?buy and switch to Pro to top up, or ',
              caseSensitive: false),
          'Type ')
      .replaceAll(
          RegExp(r',? or type \?buy\b[^.!?]*', caseSensitive: false), '');
  return RegExp(r'(?:[^.!?]|[.!?](?=\w))+[.!?]*\s*')
      .allMatches(s)
      .map((m) => m.group(0)!)
      .where((p) => !_kSelling.hasMatch(p))
      .join()
      .trim();
}

import 'dart:async';
import 'dart:math' as math;

import '../i18n/i18n.dart';


class LongTextCheck {
  const LongTextCheck(this.ok, this.reason, this.cost, this.parts);
  final bool ok;
  final String reason;
  final int cost;
  final int parts;
}

class ContextCheck {
  const ContextCheck(this.ok, this.tokens, this.limit, this.context);
  final bool ok;
  final int tokens;
  final int limit;
  final int context;
}

class AssembleResult {
  const AssembleResult(this.state, {this.text, this.have = 0, this.total = 0});
  final String state;
  final String? text;
  final int have;
  final int total;
}

class AssembleExpired {
  const AssembleExpired(this.key, this.missing, this.have, this.total);
  final String key;
  final List<int> missing;
  final int have;
  final int total;
}

class _Pending {
  _Pending(this.total, this.first);
  final int total;
  final int first;
  final Map<int, String> parts = {};
  int cost = 0;
}

class LongTextAssembler {
  LongTextAssembler({int? waitMs}) : waitMs = (waitMs ?? 0) > 0 ? waitMs! : LongText.waitMs;

  final int waitMs;
  final Map<String, _Pending> _open = {};
  final Map<String, bool> _done = {};

  void _remember(String key) {
    _done[key] = true;
    while (_done.length > 500) {
      _done.remove(_done.keys.first);
    }
  }

  List<int> _missingOf(_Pending p) => [
        for (var i = 1; i <= p.total; i++)
          if (!p.parts.containsKey(i)) i
      ];

  AssembleResult add(String key, int index, int total, String text, [int? now]) {
    final at = now ?? DateTime.now().millisecondsSinceEpoch;
    if (key.isEmpty || total < 1 || total > LongText.partsMax || index < 1 || index > total) {
      return const AssembleResult('bad');
    }
    if (_done.containsKey(key)) return const AssembleResult('dup');
    final entry = _open.putIfAbsent(key, () => _Pending(total, at));
    if (entry.total != total) return const AssembleResult('bad');
    if (entry.parts.containsKey(index)) return const AssembleResult('dup');
    entry.cost += LongText.bodyCost(text);
    if (entry.cost > LongText.longMax) {
      _open.remove(key);
      _remember(key);
      return const AssembleResult('bad');
    }
    entry.parts[index] = text;
    if (entry.parts.length < entry.total) {
      return AssembleResult('wait', have: entry.parts.length, total: entry.total);
    }
    final buf = StringBuffer();
    for (var i = 1; i <= entry.total; i++) {
      buf.write(entry.parts[i]);
    }
    _open.remove(key);
    _remember(key);
    return AssembleResult('done', text: buf.toString(), total: entry.total);
  }

  List<int> missing(String key) {
    final entry = _open[key];
    return entry == null ? const [] : _missingOf(entry);
  }

  List<AssembleExpired> expired([int? now]) {
    final at = now ?? DateTime.now().millisecondsSinceEpoch;
    return [
      for (final e in _open.entries)
        if (at - e.value.first >= waitMs)
          AssembleExpired(e.key, _missingOf(e.value), e.value.parts.length, e.value.total)
    ];
  }

  void drop(String key) => _open.remove(key);

  int get pending => _open.length;
}

class LongText {
  LongText._();


  static const int bodyMax = 15000;

  static const int longMax = 4000000;

  static const int partsMax = 1000;

  static const int waitMs = 90000;

  static const int bytesPerToken = 4;

  static bool _high(int c) => c >= 0xD800 && c <= 0xDBFF;
  static bool _low(int c) => c >= 0xDC00 && c <= 0xDFFF;

  static int _unit(String s, int i, List<int> width) {
    final c = s.codeUnitAt(i);
    width[0] = 1;
    if (c == 0x22 || c == 0x5C) return 2;
    if (c == 0x08 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D) return 2;
    if (c < 0x20) return 6;
    if (c < 0x80) return 1;
    if (c < 0x800) return 2;
    if (_high(c) && i + 1 < s.length && _low(s.codeUnitAt(i + 1))) {
      width[0] = 2;
      return 4;
    }
    if (_high(c) || _low(c)) return 6;
    return 3;
  }

  static int bodyCost(String text) {
    final w = [1];
    var cost = 0;
    for (var i = 0; i < text.length;) {
      cost += _unit(text, i, w);
      i += w[0];
    }
    return cost;
  }

  static bool fits(String text) => bodyCost(text) <= bodyMax;

  static List<String> split(String text, [int? budget]) {
    final max = (budget ?? 0) > 0 ? budget! : bodyMax;
    final parts = <String>[];
    final w = [1];
    var at = 0;
    while (at < text.length) {
      var cost = 0;
      var end = at;
      while (end < text.length) {
        final u = _unit(text, end, w);
        if (cost + u > max) break;
        cost += u;
        end += w[0];
      }
      if (end >= text.length) {
        parts.add(text.substring(at));
        break;
      }
      if (end == at) {
        _unit(text, at, w);
        end = at + w[0];
      }
      final len = end - at;
      final nl = text.lastIndexOf('\n', end - 1);
      if (nl >= at && nl - at > len * 0.5) end = nl + 1;
      parts.add(text.substring(at, end));
      at = end;
    }
    return parts.isEmpty ? [''] : parts;
  }

  static LongTextCheck check(String text) {
    final cost = bodyCost(text);
    if (cost > longMax) return LongTextCheck(false, 'long', cost, 0);
    final parts = cost <= bodyMax ? 1 : split(text).length;
    if (parts > partsMax) return LongTextCheck(false, 'parts', cost, parts);
    return LongTextCheck(true, '', cost, parts);
  }

  static int tokensFor(int cost) => (math.max(0, cost) / bytesPerToken).ceil();

  static ContextCheck contextCheck(int cost, int context, int maxOut) {
    final tokens = tokensFor(cost);
    if (context <= 0) return ContextCheck(true, tokens, 0, 0);
    final out = math.max(0, maxOut);
    final limit = out > 0 && out < context ? context - out : (context * 3) ~/ 4;
    return ContextCheck(tokens <= limit, tokens, limit, context);
  }

  static List<String> chunksFor(String text, int limitTokens) {
    final budget = math.max(bodyMax, (math.max(0, limitTokens) * bytesPerToken * 0.8).floor());
    return split(text, budget);
  }

  static ({String? x, int index, int total})? partOf(List tags) {
    String? x;
    ({int index, int total})? part;
    for (final t in tags) {
      if (t is! List || t.isEmpty) continue;
      if (t[0] == 'x' && t.length > 1 && x == null) x = '${t[1]}';
      if (t[0] == 'part' && part == null) {
        part = (index: int.tryParse(t.length > 1 ? '${t[1]}' : '') ?? 0, total: int.tryParse(t.length > 2 ? '${t[2]}' : '') ?? 0);
      }
    }
    if (part == null) return null;
    return (x: x, index: part.index, total: part.total);
  }

  static final LongTextAssembler shared = LongTextAssembler();

  static const int shownMax = 6000;

  static String? collapsedHead(String text) {
    if (text.length <= shownMax) return null;
    final nl = text.lastIndexOf('\n', shownMax - 1);
    var head = text.substring(0, nl > shownMax ~/ 2 ? nl + 1 : shownMax);
    if (head.isNotEmpty && _high(head.codeUnitAt(head.length - 1))) {
      head = head.substring(0, head.length - 1);
    }
    return head;
  }

  static int Function() now = () => DateTime.now().millisecondsSinceEpoch;
  static void Function(AssembleExpired gone)? onMissing;

  static String missingText(AssembleExpired gone) => tr(
      'Part {i} of {n} of a long message did not arrive. Ask for it to be sent again.',
      {'i': gone.missing.isEmpty ? gone.have + 1 : gone.missing.first, 'n': gone.total});

  static List<AssembleExpired> sweep() {
    final gone = shared.expired(now());
    for (final g in gone) {
      shared.drop(g.key);
    }
    return gone;
  }

  static String? join(String key, int index, int total, String text) {
    final got = shared.add(key, index, total, text, now());
    if (got.state == 'done') return got.text;
    if (got.state == 'wait' && got.have == 1) {
      Timer(const Duration(milliseconds: waitMs + 1000), () {
        for (final g in sweep()) {
          onMissing?.call(g);
        }
      });
    }
    return null;
  }
}

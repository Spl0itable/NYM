import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

class DmPollLimits {
  DmPollLimits._();
  static const int questionMax = 280;
  static const int optionMax = 100;
  static const int optionsMin = 2;
  static const int optionsMax = 6;
  static const int historyMax = 8;
  static const int pollsMax = 300;
  static const int futureSkewSec = 300;

  static Map<String, int> toJson() => {
        'questionMax': questionMax,
        'optionMax': optionMax,
        'optionsMin': optionsMin,
        'optionsMax': optionsMax,
        'historyMax': historyMax,
        'pollsMax': pollsMax,
        'futureSkewSec': futureSkewSec,
      };
}

class DmPollTypes {
  DmPollTypes._();
  static const String vote = 'nym-poll-vote';
  static const String close = 'nym-poll-close';

  static Map<String, String> toJson() => {'vote': vote, 'close': close};
}

class DmPollStrings {
  DmPollStrings._();
  static const String header = 'Poll';
  static const String previewPrefix = 'Poll: ';
  static const String voteContent = 'Poll vote: {option}';
  static const String closeContent = 'Poll closed: {question}';
  static const String oneVote = '1 vote';
  static const String manyVotes = '{n} votes';
  static const String closed = 'Closed';
  static const String closePoll = 'Close poll';
  static const String closedNotice = 'This poll is closed.';
  static const String botRefused = "Polls aren't available in the Nymbot chat.";
  static const String sendFailed = "Couldn't send the poll. Try again.";

  static Map<String, String> toJson() => {
        'header': header,
        'previewPrefix': previewPrefix,
        'voteContent': voteContent,
        'closeContent': closeContent,
        'oneVote': oneVote,
        'manyVotes': manyVotes,
        'closed': closed,
        'closePoll': closePoll,
        'closedNotice': closedNotice,
        'botRefused': botRefused,
        'sendFailed': sendFailed,
      };

  static const List<String> ui = [
    header,
    oneVote,
    manyVotes,
    closed,
    closePoll,
    closedNotice,
    botRefused,
    sendFailed,
  ];
}

class DmPoll {
  const DmPoll(this.question, this.options);

  final String question;
  final List<String> options;

  Map<String, Object> toJson() => {'question': question, 'options': options};
}

class DmPollControl {
  const DmPollControl({
    required this.type,
    required this.valid,
    required this.pollId,
    required this.pubkey,
    required this.ts,
    this.option,
  });

  final String type;
  final bool valid;
  final String pollId;
  final String pubkey;
  final int ts;
  final int? option;

  Map<String, Object> toJson() => {
        'type': type,
        'valid': valid,
        'pollId': pollId,
        'pubkey': pubkey,
        'ts': ts,
        'option': ?option,
      };
}

class DmPollVote {
  const DmPollVote(this.o, this.ts);

  final int o;
  final int ts;

  Map<String, int> toJson() => {'o': o, 'ts': ts};
}

class DmPollEntry {
  DmPollEntry(this.v, this.c);

  DmPollEntry.empty()
      : v = <String, List<DmPollVote>>{},
        c = <String, int>{};

  final Map<String, List<DmPollVote>> v;
  final Map<String, int> c;

  DmPollEntry copy() => DmPollEntry(
        LinkedHashMap.of({
          for (final e in v.entries) e.key: List<DmPollVote>.of(e.value),
        }),
        LinkedHashMap.of(c),
      );

  Map<String, Object> toJson() => {
        'v': {
          for (final e in v.entries)
            e.key: [for (final r in e.value) r.toJson()],
        },
        'c': Map<String, int>.of(c),
      };

  static DmPollEntry fromJson(Object? raw) {
    final out = DmPollEntry.empty();
    if (raw is! Map) return out;
    final v = raw['v'];
    if (v is Map) {
      v.forEach((pk, list) {
        if (pk is! String || list is! List) return;
        out.v[pk] = [
          for (final r in list)
            if (r is Map && r['o'] is num && r['ts'] is num)
              DmPollVote((r['o'] as num).toInt(), (r['ts'] as num).toInt()),
        ];
      });
    }
    final c = raw['c'];
    if (c is Map) {
      c.forEach((pk, ts) {
        if (pk is String && ts is num) out.c[pk] = ts.toInt();
      });
    }
    return out;
  }
}

class DmPollApplied {
  const DmPollApplied(this.entry, this.changed);

  final DmPollEntry entry;
  final bool changed;
}

class DmPollTally {
  const DmPollTally({
    required this.counts,
    required this.total,
    required this.choices,
    required this.order,
    required this.closed,
    required this.closedAt,
  });

  final List<int> counts;
  final int total;
  final Map<String, int> choices;
  final List<String> order;
  final bool closed;
  final int closedAt;

  Map<String, Object> toJson() => {
        'counts': counts,
        'total': total,
        'choices': choices,
        'order': order,
        'closed': closed,
        'closedAt': closedAt,
      };
}

class DmPolls {
  DmPolls._();

  static const String prefix = 'nympoll:';

  static final RegExp _rxId = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _rxLine =
      RegExp(r'(?:^|\n)nympoll:([A-Za-z0-9_.~%=;-]+)[ \t]*$');
  static final RegExp _rxPct = RegExp(r'^(?:[A-Za-z0-9_.~-]|%[0-9A-Fa-f]{2})*$');
  static final RegExp _rxSafe = RegExp(r'[A-Za-z0-9_.~-]');
  static final RegExp _rxCtl = RegExp(r'[\x00-\x1F\x7F]');
  static final RegExp _rxWs = RegExp(r'\s+');
  static final RegExp _rxEdgeWs = RegExp(r'^\s+|\s+$');
  static final RegExp _rxResponse = RegExp(r'^\d{1,2}$');

  static String pctEncode(String s) {
    final out = StringBuffer();
    for (final b in utf8.encode(s)) {
      final ch = String.fromCharCode(b);
      if (b < 0x80 && _rxSafe.hasMatch(ch)) {
        out.write(ch);
      } else {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static String pctDecode(String s) {
    if (!_rxPct.hasMatch(s)) throw const FormatException('pct');
    final bytes = <int>[];
    for (var i = 0; i < s.length;) {
      if (s[i] == '%') {
        bytes.add(int.parse(s.substring(i + 1, i + 3), radix: 16));
        i += 3;
      } else {
        bytes.add(s.codeUnitAt(i));
        i++;
      }
    }
    return utf8.decode(bytes);
  }

  static String _trim(String s) => s.replaceAll(_rxEdgeWs, '');

  static String cleanText(Object? s, int max) {
    final flat = _trim(
        (s?.toString() ?? '').replaceAll(_rxCtl, ' ').replaceAll(_rxWs, ' '));
    return _trim(String.fromCharCodes(flat.runes.take(max)));
  }

  static DmPoll? cleanPoll(Object? question, List<Object?>? options) {
    final q = cleanText(question, DmPollLimits.questionMax);
    final opts = [
      for (final o in options ?? const <Object?>[])
        cleanText(o, DmPollLimits.optionMax),
    ].where((o) => o.isNotEmpty).toList();
    if (q.isEmpty ||
        opts.length < DmPollLimits.optionsMin ||
        opts.length > DmPollLimits.optionsMax) {
      return null;
    }
    return DmPoll(q, opts);
  }

  static String _fill(String tpl, Map<String, String> vars) {
    var s = tpl;
    vars.forEach((k, v) => s = s.split('{$k}').join(v));
    return s;
  }

  static String? buildPollContent(String question, List<String> options) {
    final p = cleanPoll(question, options);
    if (p == null) return null;
    final lines = ['📊 ${DmPollStrings.previewPrefix}${p.question}'];
    for (var i = 0; i < p.options.length; i++) {
      lines.add('${i + 1}. ${p.options[i]}');
    }
    lines.add('${prefix}v=1;q=${pctEncode(p.question)}'
        '${p.options.map((o) => ';o=${pctEncode(o)}').join()}');
    return lines.join('\n');
  }

  static DmPoll? parsePoll(String? content) {
    if (content == null || !content.contains(prefix)) return null;
    final m = _rxLine.firstMatch(content);
    if (m == null) return null;
    String? v;
    String? q;
    final opts = <String>[];
    for (final part in m.group(1)!.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) return null;
      final k = part.substring(0, i);
      final val = part.substring(i + 1);
      if (k == 'v') {
        if (v != null) return null;
        v = val;
      } else if (k == 'q') {
        if (q != null) return null;
        q = val;
      } else if (k == 'o') {
        opts.add(val);
      }
    }
    if (v != '1' || q == null) return null;
    String question;
    List<String> options;
    try {
      question = pctDecode(q);
      options = opts.map(pctDecode).toList();
    } catch (_) {
      return null;
    }
    if (options.length > DmPollLimits.optionsMax) return null;
    final p = cleanPoll(question, options);
    if (p == null || p.options.length != options.length) return null;
    return p;
  }

  static String previewText(String content) {
    final p = parsePoll(content);
    return p != null ? '📊 ${DmPollStrings.previewPrefix}${p.question}' : content;
  }

  static List<List<String>> voteTags(String pollId, int optionIndex) => [
        ['type', DmPollTypes.vote],
        ['e', pollId],
        ['response', '$optionIndex'],
      ];

  static String voteContent(String optionText) => _fill(DmPollStrings.voteContent,
      {'option': cleanText(optionText, DmPollLimits.optionMax)});

  static List<List<String>> closeTags(String pollId) => [
        ['type', DmPollTypes.close],
        ['e', pollId],
      ];

  static String closeContent(String question) => _fill(
      DmPollStrings.closeContent,
      {'question': cleanText(question, DmPollLimits.questionMax)});

  static int _floor(Object? x) {
    final n = x is num ? x : (x is String ? num.tryParse(x.trim()) : null);
    if (n == null || n.isNaN || n.isInfinite) return 0;
    return n.floor();
  }

  static int clampTs(Object? ts, Object? now) {
    final t = _floor(ts);
    if (t <= 0) return 0;
    final n = _floor(now);
    return n > 0 ? math.min(t, n + DmPollLimits.futureSkewSec) : t;
  }

  static String? tagValue(Object? tags, String name) {
    if (tags is! List) return null;
    for (final t in tags) {
      if (t is List && t.length > 1 && t[0] == name && t[1] is String) {
        return t[1] as String;
      }
    }
    return null;
  }

  static DmPollControl? parseControl(Map<String, dynamic>? rumor, int now) {
    if (rumor == null || rumor['kind'] != 14 || rumor['tags'] is! List) {
      return null;
    }
    final tags = rumor['tags'];
    final type = tagValue(tags, 'type');
    if (type != DmPollTypes.vote && type != DmPollTypes.close) return null;
    final pollId = tagValue(tags, 'e');
    final ts = clampTs(rumor['created_at'], now);
    final pk = rumor['pubkey'];
    final pubkey = pk == null ? '' : '$pk';
    final kind = type == DmPollTypes.vote ? 'vote' : 'close';
    DmPollControl out(bool valid, [int? option]) => DmPollControl(
          type: kind,
          valid: valid,
          pollId: pollId ?? '',
          pubkey: pubkey,
          ts: ts,
          option: option,
        );
    if (pollId == null ||
        !_rxId.hasMatch(pollId) ||
        !_rxId.hasMatch(pubkey) ||
        ts <= 0) {
      return out(false);
    }
    if (type == DmPollTypes.close) return out(true);
    final resp = tagValue(tags, 'response');
    if (resp == null || !_rxResponse.hasMatch(resp)) return out(false);
    final option = int.parse(resp);
    if (option >= DmPollLimits.optionsMax) return out(false);
    return out(true, option);
  }

  static bool _isInt(Object? x) =>
      x is int || (x is double && x.isFinite && x == x.truncateToDouble());

  static DmPollApplied applyVote(
      DmPollEntry? entry, Object? voter, Object? option, Object? ts) {
    final out = (entry ?? DmPollEntry.empty()).copy();
    final t = _floor(ts);
    final pk = voter?.toString() ?? '';
    if (!_rxId.hasMatch(pk) || t <= 0 || !_isInt(option)) {
      return DmPollApplied(out, false);
    }
    final o = (option as num).toInt();
    if (o < 0 || o >= DmPollLimits.optionsMax) return DmPollApplied(out, false);
    final list = out.v[pk] ?? <DmPollVote>[];
    if (list.any((r) => r.ts == t && r.o == o)) return DmPollApplied(out, false);
    list.add(DmPollVote(o, t));
    list.sort((a, b) => a.ts != b.ts ? a.ts - b.ts : a.o - b.o);
    final kept = list.length > DmPollLimits.historyMax
        ? list.sublist(list.length - DmPollLimits.historyMax)
        : list;
    out.v[pk] = kept;
    return DmPollApplied(out, kept.any((r) => r.ts == t && r.o == o));
  }

  static DmPollApplied applyClose(DmPollEntry? entry, Object? pubkey, Object? ts) {
    final out = (entry ?? DmPollEntry.empty()).copy();
    final t = _floor(ts);
    final pk = pubkey?.toString() ?? '';
    if (!_rxId.hasMatch(pk) || t <= 0) return DmPollApplied(out, false);
    final cur = out.c[pk];
    if (cur != null && cur != 0 && cur <= t) return DmPollApplied(out, false);
    out.c[pk] = t;
    return DmPollApplied(out, true);
  }

  static int closedAt(DmPollEntry? entry, String? author) {
    if (entry == null || author == null || author.isEmpty) return 0;
    return entry.c[author] ?? 0;
  }

  static DmPollTally tally(DmPollEntry? entry,
      {required int options, String? author, List<String>? allowed}) {
    final n = math.max(0, options);
    final closed = closedAt(entry, author);
    final counts = List<int>.filled(n, 0);
    final picks = <({String pk, int o, int ts})>[];
    final votes = entry?.v ?? const <String, List<DmPollVote>>{};
    for (final e in votes.entries) {
      if (allowed != null && !allowed.contains(e.key)) continue;
      DmPollVote? best;
      for (final r in e.value) {
        if (r.o < 0 || r.o >= n) continue;
        if (closed != 0 && r.ts > closed) continue;
        if (best == null || r.ts > best.ts || (r.ts == best.ts && r.o > best.o)) {
          best = r;
        }
      }
      if (best != null) picks.add((pk: e.key, o: best.o, ts: best.ts));
    }
    picks.sort((a, b) => a.ts != b.ts ? a.ts - b.ts : a.pk.compareTo(b.pk));
    final choices = <String, int>{};
    final order = <String>[];
    for (final p in picks) {
      counts[p.o]++;
      choices[p.pk] = p.o;
      order.add(p.pk);
    }
    return DmPollTally(
      counts: counts,
      total: picks.length,
      choices: choices,
      order: order,
      closed: closed != 0,
      closedAt: closed,
    );
  }

  static int percent(int count, int total) =>
      total > 0 ? ((count / total) * 100).round() : 0;

  static int nextVoteTs(DmPollEntry? entry, String voter, int now) {
    final list = entry?.v[voter] ?? const <DmPollVote>[];
    final last = list.fold<int>(0, (m, r) => math.max(m, r.ts));
    return math.max(now, last + 1);
  }

  static String votesLabel(int total) => total == 1
      ? DmPollStrings.oneVote
      : _fill(DmPollStrings.manyVotes, {'n': '$total'});

  static Map<String, DmPollEntry> prune(Map<String, DmPollEntry> store,
      [int keep = DmPollLimits.pollsMax]) {
    final out = LinkedHashMap<String, DmPollEntry>.of(store);
    final ids = out.keys.toList();
    if (ids.length > keep) {
      for (final id in ids.take(ids.length - keep)) {
        out.remove(id);
      }
    }
    return out;
  }
}

String dmPollPreview(String content, [String Function(String text)? tr]) {
  final p = DmPolls.parsePoll(content);
  if (p == null) return content;
  final header = tr == null ? DmPollStrings.header : tr(DmPollStrings.header);
  return '📊 $header: ${p.question}';
}

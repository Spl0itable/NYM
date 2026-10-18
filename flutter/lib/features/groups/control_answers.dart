import 'dart:convert';

import 'package:crypto/crypto.dart';

const int kAnswerResyncMaxAgeSec = 3600;

const int kAnswerJoinMaxAgeSec = 86400;

const int kAnsweredKeepSec = 86400;

const int kAnsweredMax = 64;

const int kAnswerJitterMs = 3000;

const int kAnswerSettleMs = 2500;

const int kAnswerSettleJitterMs = 1000;

const int kAnswerSettleRounds = 5;

class ControlAnswers {
  const ControlAnswers._();

  static bool fresh(String kind, int nowSec, int ts) {
    final limit = switch (kind) {
      'join' => kAnswerJoinMaxAgeSec,
      _ => kAnswerResyncMaxAgeSec,
    };
    if (ts <= 0) return false;
    return nowSec - ts <= limit;
  }

  static bool wanted(String kind, int nowSec, int ts, {bool held = false}) {
    if (kind == 'invite' && !held) return true;
    return fresh(kind, nowSec, ts);
  }

  static String pickSelf(String a, String b) => a.compareTo(b) <= 0 ? a : b;

  static String admitId(String groupId, String joiner, String requestX) =>
      sha256
          .convert(utf8.encode('nym-join-admit-v1:$groupId:$joiner:$requestX'))
          .toString();

  static Map<String, int> noteAnswered(
      Map<String, int> map, String x, int ts, int nowSec) {
    final out = <String, int>{
      for (final e in map.entries)
        if (nowSec - e.value <= kAnsweredKeepSec) e.key: e.value,
    };
    final had = out[x] ?? 0;
    out[x] = ts > had ? ts : had;
    return _capped(out);
  }

  static Map<String, int> mergeAnswered(
      Map<String, int> a, Map<String, int> b) {
    final out = Map<String, int>.of(a);
    b.forEach((x, ts) {
      final had = out[x] ?? 0;
      out[x] = ts > had ? ts : had;
    });
    return _capped(out);
  }

  static Map<String, int> _capped(Map<String, int> m) {
    final entries = m.entries.toList()
      ..sort((p, q) {
        final byTs = q.value.compareTo(p.value);
        return byTs != 0 ? byTs : p.key.compareTo(q.key);
      });
    final kept = entries.take(kAnsweredMax).toList()
      ..sort((p, q) => p.key.compareTo(q.key));
    return {for (final e in kept) e.key: e.value};
  }
}

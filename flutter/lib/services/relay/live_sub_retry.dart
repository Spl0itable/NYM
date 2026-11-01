import 'dart:async';
import 'dart:math';

import 'relay_message.dart';

class LiveSubRetry {
  LiveSubRetry(this._now);

  static const int baseMs = 1000;
  static const int slowBaseMs = 10000;
  static const int capMs = 120000;
  static const int windowMs = 120000;

  static final RegExp _skip = RegExp(
      r'^\s*(auth-required|restricted|blocked|invalid|unsupported)\b',
      caseSensitive: false);
  static final RegExp _slow = RegExp(r'rate-?limit|too many|slow down|concurrent',
      caseSensitive: false);

  static bool retries(String reason) =>
      reason.trim().isNotEmpty &&
      !isUnsupportedKindRejection(reason) &&
      !isRelayWideRejection(reason) &&
      !_skip.hasMatch(reason);

  static Duration delayFor(String reason, int attempt) {
    final base = _slow.hasMatch(reason) ? slowBaseMs : baseMs;
    return Duration(
        milliseconds: min(base * pow(2, min(attempt, 20)).toInt(), capMs));
  }

  final DateTime Function() _now;
  final Map<String, _Retry> _retries = {};

  bool note(String target, String subId, String reason,
      void Function(Set<String> subIds) resend) {
    if (!retries(reason)) return false;
    final prev = _retries[target];
    if (prev != null && prev.timer != null) {
      prev.subIds.add(subId);
      return false;
    }
    final now = _now().millisecondsSinceEpoch;
    final n = prev != null && now - prev.at < windowMs ? prev.n + 1 : 0;
    final entry = _Retry(now, n)..subIds.add(subId);
    _retries[target] = entry;
    entry.timer = Timer(delayFor(reason, n), () {
      entry.timer = null;
      entry.at = _now().millisecondsSinceEpoch;
      final ids = {...entry.subIds};
      entry.subIds.clear();
      resend(ids);
    });
    return true;
  }

  void dispose() {
    for (final r in _retries.values) {
      r.timer?.cancel();
      r.timer = null;
    }
    _retries.clear();
  }
}

class _Retry {
  _Retry(this.at, this.n);

  int at;
  final int n;
  Timer? timer;
  final Set<String> subIds = <String>{};
}

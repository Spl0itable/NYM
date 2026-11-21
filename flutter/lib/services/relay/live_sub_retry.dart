import 'dart:async';
import 'dart:math';

import '../../core/constants/event_kinds.dart';
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

  static const Set<int> _neverInD1 = {
    EventKind.geoPresence,
    EventKind.channelTyping,
    EventKind.channelReceipt,
    EventKind.p2pSignaling,
    EventKind.p2pFileStatus,
  };

  static bool opensGap(List<NostrFilter>? filters) {
    if (filters == null || filters.isEmpty) return true;
    for (final f in filters) {
      final kinds = f.kinds;
      if (kinds == null || kinds.isEmpty) return true;
      if (kinds.any((k) => !_neverInD1.contains(k))) return true;
    }
    return false;
  }

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

  DateTime? note(String target, String subId, String reason,
      void Function(Set<String> subIds, bool gap) resend,
      {bool gap = true}) {
    if (!retries(reason)) return null;
    final prev = _retries[target];
    if (prev != null && prev.timer != null) {
      prev.subIds.add(subId);
      if (!gap || prev.gap) return null;
      prev.gap = true;
      return prev.opened;
    }
    final opened = _now();
    final now = opened.millisecondsSinceEpoch;
    final n = prev != null && now - prev.at < windowMs ? prev.n + 1 : 0;
    final entry = _Retry(opened, n, gap)..subIds.add(subId);
    _retries[target] = entry;
    entry.timer = Timer(delayFor(reason, n), () {
      entry.timer = null;
      entry.at = _now().millisecondsSinceEpoch;
      final ids = {...entry.subIds};
      final hadGap = entry.gap;
      entry.subIds.clear();
      entry.gap = false;
      resend(ids, hadGap);
    });
    return gap ? opened : null;
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
  _Retry(this.opened, this.n, this.gap) : at = opened.millisecondsSinceEpoch;

  final DateTime opened;
  int at;
  final int n;
  bool gap;
  Timer? timer;
  final Set<String> subIds = <String>{};
}

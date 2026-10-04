import 'dart:async';
import 'dart:collection';

import '../../features/groups/wrap_outbox.dart';
import '../../models/nostr_event.dart';

class UnsentEvent {
  const UnsentEvent(this.event, {required this.tier, required this.dm});

  final NostrEvent event;
  final int tier;
  final bool dm;
}

class _DmEntry {
  _DmEntry(this.event, this.tier, this.seq, this.tries);

  final NostrEvent event;
  final int tier;
  final int seq;
  final int tries;
}

class DmOutbox {
  DmOutbox({
    required this.send,
    DateTime Function()? now,
    this.cap = 2000,
    this.maxTries = 8,
    this.bucket = kRelayWrapBucket,
    this.retryWait = const Duration(seconds: 2),
  }) : _now = now ?? DateTime.now;

  Future<int> Function(NostrEvent event) send;
  final DateTime Function() _now;
  final int cap;
  final int maxTries;
  final WrapBucketConfig bucket;
  final Duration retryWait;

  final List<List<_DmEntry>> _q = [[], [], []];
  final Set<String> _ids = {};
  final LinkedHashMap<String, (_DmEntry, int)> _inflight = LinkedHashMap();
  WrapBucket? _bucket;
  Timer? _timer;
  int _seq = 0;
  int _pausedUntil = 0;
  bool _disposed = false;

  int dropped = 0;
  int failed = 0;

  int get length => _q[0].length + _q[1].length + _q[2].length;

  int get unsentCount {
    _prune(_nowMs());
    final ids = {..._ids, ..._inflight.keys};
    return ids.length;
  }

  List<(NostrEvent, int)> unsent() {
    _prune(_nowMs());
    final seen = <String>{};
    final out = <(NostrEvent, int)>[];
    for (final v in _inflight.values) {
      if (seen.add(v.$1.event.id)) out.add((v.$1.event, v.$1.tier));
    }
    for (final q in _q) {
      for (final e in q) {
        if (seen.add(e.event.id)) out.add((e.event, e.tier));
      }
    }
    return out;
  }

  void confirm(String eventId) {
    _inflight.remove(eventId);
  }

  int _nowMs() => _now().millisecondsSinceEpoch;

  void push(NostrEvent event, {int tier = WrapTier.critical}) {
    if (_disposed || event.id.isEmpty) return;
    _enqueue(event, tier, 0);
    drain();
  }

  void _enqueue(NostrEvent event, int tier, int tries) {
    if (_ids.contains(event.id)) return;
    final t = tier == 0 || tier == 1 || tier == 2 ? tier : WrapTier.normal;
    final entry = _DmEntry(event, t, ++_seq, tries);
    if (tries > 0) {
      _q[t].insert(0, entry);
    } else {
      _q[t].add(entry);
    }
    _ids.add(event.id);
    if (length <= cap) return;
    final flat = [..._q[0], ..._q[1], ..._q[2]];
    final gone = wrapQueueEvict(
            [for (final e in flat) WrapQueueEntry(e.event.id, e.tier, e.seq)],
            cap)
        .evicted
        .toSet();
    for (var i = 0; i < 3; i++) {
      _q[i].removeWhere((e) => gone.contains(e.event.id));
    }
    _ids.removeAll(gone);
    dropped += gone.length;
  }

  void charge(int units) {
    _bucket = wrapBucketTake(_bucket, _nowMs(), units, bucket, force: true)
        .state;
  }

  void _arm(int ms) {
    if (_timer != null || _disposed) return;
    _timer = Timer(Duration(milliseconds: ms < 50 ? 50 : ms), () {
      _timer = null;
      drain();
    });
  }

  void drain() {
    if (_disposed) return;
    final now = _nowMs();
    if (_pausedUntil > now) {
      if (length > 0) _arm(_pausedUntil - now);
      return;
    }
    while (length > 0) {
      final r = wrapBucketTake(_bucket, _nowMs(), 1, bucket);
      _bucket = r.state;
      if (!r.ok) {
        _arm(r.waitMs);
        return;
      }
      final q = _q[0].isNotEmpty ? _q[0] : (_q[1].isNotEmpty ? _q[1] : _q[2]);
      final entry = q.removeAt(0);
      _ids.remove(entry.event.id);
      _track(entry);
      unawaited(_sendOne(entry));
    }
  }

  Future<void> _sendOne(_DmEntry entry) async {
    int n;
    try {
      n = await send(entry.event);
    } catch (_) {
      n = 0;
    }
    if (n > 0 || _disposed) return;
    _inflight.remove(entry.event.id);
    _pausedUntil = _nowMs() + retryWait.inMilliseconds;
    _enqueue(entry.event, entry.tier, entry.tries);
    _arm(retryWait.inMilliseconds);
  }

  void _track(_DmEntry entry) {
    final now = _nowMs();
    _inflight.remove(entry.event.id);
    _inflight[entry.event.id] = (entry, now);
    _prune(now);
  }

  void _prune(int now) {
    while (_inflight.isNotEmpty) {
      final first = _inflight.entries.first;
      if (now - first.value.$2 <= 120000 && _inflight.length <= 4000) break;
      _inflight.remove(first.key);
    }
  }

  bool refused(String eventId) {
    final v = _inflight.remove(eventId);
    if (v == null || _disposed) return false;
    final st = wrapBucketTake(_bucket, _nowMs(), 0, bucket).state;
    _bucket = WrapBucket(st.tokens < 0 ? st.tokens : 0, st.at);
    final entry = v.$1;
    if (entry.tries + 1 > maxTries) {
      failed++;
      return false;
    }
    _enqueue(entry.event, entry.tier, entry.tries + 1);
    drain();
    return true;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

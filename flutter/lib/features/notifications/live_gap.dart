import 'dart:async';

const int kLiveGapMarginSec = 300;

const int kLiveGapMaxLookbackMs = 86400000;

bool gapWrapIsFresh({required int rumorCreatedAtSec, required int floorSec}) =>
    rumorCreatedAtSec >= floorSec;

class LiveGap {
  int _startMs = 0;
  int _seq = 0;
  bool _inFlight = false;

  bool get pending => _startMs > 0;

  int get startMs => _startMs;

  void note({int? nowMs, int? lastLiveAtMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final live = lastLiveAtMs ?? 0;
    final at = live > 0 && live < now
        ? (live > now - kLiveGapMaxLookbackMs ? live : now - kLiveGapMaxLookbackMs)
        : now;
    if (_startMs == 0 || at < _startMs) _startMs = at;
    _seq++;
  }

  Future<void> run(Future<bool> Function(int sinceSec) catchUp) async {
    if (_startMs == 0 || _inFlight) return;
    final seqAt = _seq;
    final sinceSec = _startMs ~/ 1000 - kLiveGapMarginSec;
    _inFlight = true;
    var ok = false;
    try {
      ok = await catchUp(sinceSec);
    } catch (_) {
      ok = false;
    } finally {
      _inFlight = false;
    }
    if (ok && _seq == seqAt) {
      _startMs = 0;
      return;
    }
    if (ok && _seq != seqAt) await run(catchUp);
  }
}

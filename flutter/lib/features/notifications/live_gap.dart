import 'dart:async';

const int kLiveGapMarginSec = 300;

class LiveGap {
  int _startMs = 0;
  int _seq = 0;
  bool _inFlight = false;

  bool get pending => _startMs > 0;

  void note({int? nowMs}) {
    if (_startMs == 0) {
      _startMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    }
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

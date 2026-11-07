class NotificationTapGate {
  NotificationTapGate({int Function()? clock, this.maxWaitMs = 30000})
      : _clock = clock ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final int Function() _clock;
  final int maxWaitMs;
  bool _ready = false;
  void Function()? _pending;
  int _pendingAt = 0;

  bool get ready => _ready;

  bool get waiting => _pending != null;

  void open(void Function() run) {
    if (_ready) {
      _pending = null;
      run();
      return;
    }
    _pending = run;
    _pendingAt = _clock();
  }

  void markReady() {
    _ready = true;
    final run = _pending;
    _pending = null;
    if (run != null && _clock() - _pendingAt <= maxWaitMs) run();
  }

  void drop() {
    _pending = null;
  }

  void reset() {
    _ready = false;
    _pending = null;
  }
}

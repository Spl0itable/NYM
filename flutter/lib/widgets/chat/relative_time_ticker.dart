import 'dart:async';

import 'package:flutter/foundation.dart';

/// A single process-wide 30-second heartbeat that drives every message bubble's
/// in-bubble relative time ("2m ago").
///
/// Each visible [MessageRow] used to own its OWN `Timer.periodic(30s)` that
/// called `setState`; with a screenful of bubbles that meant N independent,
/// phase-unaligned timers all firing wasted rebuilds even while the app sat
/// idle. This coalesces them into ONE timer whose tick fans out to every
/// listening row on the SAME frame, and — because it's lazy — the timer only
/// runs while at least one row is actually mounted and listening.
class RelativeTimeTicker extends ChangeNotifier {
  RelativeTimeTicker._();

  /// Shared instance every message row subscribes to.
  static final RelativeTimeTicker instance = RelativeTimeTicker._();

  Timer? _timer;
  int _listenerCount = 0;

  /// The cadence (matches the former per-row interval / the PWA's ~30s refresh).
  static const Duration interval = Duration(seconds: 30);

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listenerCount++;
    _timer ??= Timer.periodic(interval, (_) => notifyListeners());
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listenerCount--;
    if (_listenerCount <= 0) {
      _listenerCount = 0;
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Test hook: whether the underlying timer is currently running.
  @visibleForTesting
  bool get isRunning => _timer != null;

  /// Test hook: current live listener count.
  @visibleForTesting
  int get listenerCount => _listenerCount;
}

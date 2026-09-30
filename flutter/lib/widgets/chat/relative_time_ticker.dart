import 'dart:async';

import 'package:flutter/foundation.dart';

/// One lazy process-wide 30s timer driving every message bubble's relative time; runs only while listened to.
class RelativeTimeTicker extends ChangeNotifier {
  RelativeTimeTicker._();

  static final RelativeTimeTicker instance = RelativeTimeTicker._();

  Timer? _timer;
  int _listenerCount = 0;

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

  @visibleForTesting
  bool get isRunning => _timer != null;

  @visibleForTesting
  int get listenerCount => _listenerCount;
}

import 'package:flutter/foundation.dart';

class QueuedSends extends ChangeNotifier {
  QueuedSends._();

  static final QueuedSends instance = QueuedSends._();

  static const int registryMax = 4000;

  final Map<String, String> _pending = {};
  final Map<String, String> _held = {};

  bool isUserSend(String eventId) => _pending.containsKey(eventId);

  void register(String eventId, String key) {
    if (eventId.isEmpty || key.isEmpty) return;
    _pending.remove(eventId);
    _pending[eventId] = key;
    while (_pending.length > registryMax) {
      final oldest = _pending.keys.first;
      _pending.remove(oldest);
      if (_held.remove(oldest) != null) notifyListeners();
    }
  }

  void markHeld(String eventId) {
    final key = _pending[eventId];
    if (key == null || _held[eventId] == key) return;
    _held[eventId] = key;
    notifyListeners();
  }

  void release(String eventId) {
    _pending.remove(eventId);
    if (_held.remove(eventId) != null) notifyListeners();
  }

  bool isQueued(String? key) =>
      key != null && key.isNotEmpty && _held.containsValue(key);

  bool get hasQueued => _held.isNotEmpty;

  @visibleForTesting
  void reset() {
    _pending.clear();
    if (_held.isEmpty) return;
    _held.clear();
    notifyListeners();
  }
}

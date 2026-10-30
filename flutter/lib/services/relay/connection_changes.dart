import 'package:flutter/foundation.dart';

import 'relay_connection.dart';

enum ConnectionChangeReason { proxyDown, proxyBack, chosenDirect, chosenProxy }

class ConnectionChange {
  const ConnectionChange(this.at, this.reason);

  final DateTime at;
  final ConnectionChangeReason reason;

  bool get direct =>
      reason == ConnectionChangeReason.proxyDown ||
      reason == ConnectionChangeReason.chosenDirect;
}

class ConnectionChangeLog extends ChangeNotifier {
  static const int max = 20;

  final List<ConnectionChange> _items = [];

  List<ConnectionChange> get items => List.unmodifiable(_items);

  void add(ConnectionChangeReason reason, {DateTime? at}) {
    _items.insert(0, ConnectionChange(at ?? relayClock(), reason));
    if (_items.length > max) _items.removeRange(max, _items.length);
    notifyListeners();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }
}

final ConnectionChangeLog connectionChanges = ConnectionChangeLog();

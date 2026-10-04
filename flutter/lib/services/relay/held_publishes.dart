import 'dart:async';

import '../../models/nostr_event.dart';

class HeldPublishes<T> {
  HeldPublishes({required this.max, required this.wait});

  final int max;
  final Duration wait;
  final List<_Held<T>> _items = [];

  bool get isEmpty => _items.isEmpty;

  List<NostrEvent> get events => [
        for (final item in _items)
          if (item.event != null) item.event!,
      ];

  Future<int> hold(Future<int> Function(T via) send, {NostrEvent? event}) {
    if (_items.length >= max) {
      _items.removeAt(0).settle(0);
    }
    final done = Completer<int>();
    late final _Held<T> item;
    item = _Held<T>(send, done, Timer(wait, () {
      _items.remove(item);
      item.settle(0);
    }), event);
    _items.add(item);
    return done.future;
  }

  void flush(T via) {
    if (_items.isEmpty) return;
    final list = List<_Held<T>>.of(_items);
    _items.clear();
    for (final item in list) {
      item.timer.cancel();
      item.send(via).then(item.settle, onError: (Object _) => item.settle(0));
    }
  }

  void dropAll() {
    final list = List<_Held<T>>.of(_items);
    _items.clear();
    for (final item in list) {
      item.settle(0);
    }
  }
}

class _Held<T> {
  _Held(this.send, this.done, this.timer, this.event);

  final Future<int> Function(T via) send;
  final Completer<int> done;
  final Timer timer;
  final NostrEvent? event;

  void settle(int n) {
    timer.cancel();
    if (!done.isCompleted) done.complete(n);
  }
}

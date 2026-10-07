import 'dart:async';

import '../../core/constants/event_kinds.dart';
import '../../models/nostr_event.dart';
import 'queued_sends.dart';

class HeldPublishes<T> {
  HeldPublishes({required this.max, required this.wait});

  static const int userSendMax = 200;

  final int max;
  final Duration wait;
  final List<_Held<T>> _items = [];

  bool get isEmpty => _items.isEmpty;

  List<NostrEvent> get events => [
        for (final item in _items)
          if (item.event != null) item.event!,
      ];

  static bool keeps(NostrEvent? event) =>
      event != null &&
      (event.kind == EventKind.profile ||
          QueuedSends.instance.isUserSend(event.id));

  Future<int> hold(Future<int> Function(T via) send, {NostrEvent? event}) {
    final kept = keeps(event);
    final same = [
      for (final h in _items)
        if (h.kept == kept) h
    ];
    if (same.length >= (kept ? userSendMax : max)) {
      _items.remove(same.first);
      same.first.settle(0);
    }
    final done = Completer<int>();
    late final _Held<T> item;
    item = _Held<T>(
        send,
        done,
        kept
            ? null
            : Timer(wait, () {
                _items.remove(item);
                item.settle(0);
              }),
        event);
    _items.add(item);
    if (kept) QueuedSends.instance.markHeld(event!.id);
    return done.future;
  }

  void flush(T via) {
    if (_items.isEmpty) return;
    final list = List<_Held<T>>.of(_items);
    _items.clear();
    for (final item in list) {
      item.timer?.cancel();
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
  final Timer? timer;
  final NostrEvent? event;

  bool get kept => timer == null;

  void settle(int n) {
    timer?.cancel();
    if (!done.isCompleted) done.complete(n);
  }
}

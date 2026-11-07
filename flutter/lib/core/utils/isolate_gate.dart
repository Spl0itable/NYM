import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show ComputeCallback, compute, kIsWeb;

typedef IsolateSpawner = Future<R> Function<M, R>(
    ComputeCallback<M, R> fn, M message);

Future<R> _computeSpawn<M, R>(ComputeCallback<M, R> fn, M message) =>
    compute(fn, message);

class IsolateGate {
  IsolateGate({this.limit = 2, IsolateSpawner? spawner})
      : spawn = spawner ?? _computeSpawn;

  static final IsolateGate shared = IsolateGate();

  final int limit;
  final IsolateSpawner spawn;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  int get active => _active;
  int get waiting => _waiting.length;

  Future<void> acquire() {
    if (_active < limit) {
      _active++;
      return Future<void>.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
      return;
    }
    if (_active > 0) _active--;
  }

  Future<T> hold<T>(Future<T> Function(IsolateSpawner spawn) body) async {
    await acquire();
    try {
      return await body(spawn);
    } finally {
      release();
    }
  }

  Future<R> run<M, R>(ComputeCallback<M, R> fn, M message) {
    if (kIsWeb) return spawn(fn, message);
    return hold((s) => s(fn, message));
  }
}

Future<R> gatedCompute<M, R>(ComputeCallback<M, R> fn, M message) =>
    IsolateGate.shared.run(fn, message);

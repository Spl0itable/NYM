import 'dart:async';

import '../../core/constants/relays.dart';
import '../../models/nostr_event.dart';
import '../../services/relay/relay_pool.dart';
import '../../services/relay/relay_pool_proxy.dart';

class SendAsOk {
  const SendAsOk(this.accepted, {this.message = '', this.retryable = false});

  final bool accepted;
  final String message;
  final bool retryable;
}

abstract class SendAsTransport {
  Future<SendAsOk> publish(NostrEvent event, {List<String> geoRelays});

  Future<void> publishPlain(NostrEvent event);

  Future<void> close();
}

typedef SendAsTransportFactory = SendAsTransport Function(
    bool direct, List<String> blocked);

class PoolSendAsTransport implements SendAsTransport {
  PoolSendAsTransport({
    required this.direct,
    this.relays = RelayConfig.defaultRelays,
    this.blocked = const [],
    this.okTimeout = const Duration(seconds: 20),
    PoolTransport Function(
            bool direct, List<String> relays, List<String> blocked)?
        pool,
  }) : _poolFactory = pool ?? _defaultPool;

  static PoolTransport _defaultPool(
          bool direct, List<String> relays, List<String> blocked) =>
      direct
          ? RelayPool(
              relays: relays,
              writeOnlyRelays: RelayConfig.writeOnlyRelays,
              blockedRelays: blocked,
            )
          : RelayPoolProxy(
              relays: relays,
              dmRelays: RelayConfig.defaultRelays,
              blockedRelays: blocked,
            );

  final bool direct;
  final Duration okTimeout;
  final List<String> relays;
  final List<String> blocked;
  final PoolTransport Function(
      bool direct, List<String> relays, List<String> blocked) _poolFactory;
  PoolTransport? _pool;
  bool _closed = false;
  final Map<String, _Waiter> _waiters = {};

  PoolTransport _open() {
    final existing = _pool;
    if (existing != null) return existing;
    final p = _poolFactory(direct, relays, blocked);
    if (p is RelayPoolProxy) p.onPublishResult = _onResult;
    p.connectAll();
    _pool = p;
    return p;
  }

  void _onResult(String id, bool accepted, String message, String? relayUrl) {
    final w = _waiters[id];
    if (w == null || w.done.isCompleted) return;
    if (accepted) {
      w.done.complete(SendAsOk(true, message: message));
      return;
    }
    if (relayUrl == null || relayUrl.isEmpty) {
      w.done.complete(SendAsOk(false, message: message));
      return;
    }
    w.lastReason = message;
  }

  @override
  Future<SendAsOk> publish(NostrEvent event,
      {List<String> geoRelays = const []}) async {
    if (_closed) return const SendAsOk(false, retryable: true);
    final PoolTransport pool;
    try {
      pool = _open();
    } catch (_) {
      return const SendAsOk(false, retryable: true);
    }
    if (pool is! RelayPoolProxy) {
      try {
        final n = await (geoRelays.isEmpty
                ? pool.publish(event)
                : pool.publishGeo(event, geoRelays))
            .timeout(okTimeout);
        return n > 0
            ? const SendAsOk(true)
            : const SendAsOk(false, retryable: true);
      } catch (_) {
        return const SendAsOk(false, retryable: true);
      }
    }
    final w = _waiters.putIfAbsent(event.id, _Waiter.new);
    try {
      final sent = await (geoRelays.isEmpty
          ? pool.publish(event)
          : pool.publishGeo(event, geoRelays));
      if (sent <= 0 && !w.done.isCompleted) {
        w.done.complete(const SendAsOk(false, retryable: true));
      }
    } catch (_) {
      if (!w.done.isCompleted) {
        w.done.complete(const SendAsOk(false, retryable: true));
      }
    }
    try {
      return await w.done.future.timeout(okTimeout, onTimeout: () {
        final reason = w.lastReason;
        return reason == null
            ? const SendAsOk(false, retryable: true)
            : SendAsOk(false, message: reason);
      });
    } finally {
      _waiters.remove(event.id);
    }
  }

  @override
  Future<void> publishPlain(NostrEvent event) async {
    if (_closed) return;
    try {
      await _open().publish(event);
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final w in _waiters.values) {
      if (!w.done.isCompleted) {
        w.done.complete(const SendAsOk(false, retryable: true));
      }
    }
    _waiters.clear();
    final p = _pool;
    _pool = null;
    if (p is RelayPoolProxy) p.onPublishResult = null;
    try {
      await p?.disconnectAll();
    } catch (_) {}
  }
}

class _Waiter {
  final Completer<SendAsOk> done = Completer<SendAsOk>();
  String? lastReason;
}

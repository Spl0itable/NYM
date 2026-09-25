import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/relays.dart';
import 'package:nym_bar/services/relay/relay_pool_proxy.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeChannel implements WebSocketChannel {
  _FakeChannel({this.failImmediately = false, this.hang = false});

  final bool failImmediately;
  final bool hang;
  final StreamController<dynamic> _inbound = StreamController<dynamic>();
  final List<String> sent = [];
  late final _FakeSink _sink = _FakeSink(sent, _inbound);

  void inject(String frame) => _inbound.add(frame);

  void drop() {
    if (!_inbound.isClosed) _inbound.close();
  }

  @override
  Stream<dynamic> get stream {
    if (failImmediately) {
      scheduleMicrotask(() {
        if (_inbound.isClosed) return;
        _inbound.addError(const SocketExceptionLike());
        _inbound.close();
      });
    }
    return _inbound.stream;
  }

  @override
  WebSocketSink get sink => _sink;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._sent, this._inbound);
  final List<String> _sent;
  final StreamController<dynamic> _inbound;

  @override
  void add(dynamic data) => _sent.add(data.toString());

  @override
  Future<dynamic> close([int? code, String? reason]) async {
    if (!_inbound.isClosed) await _inbound.close();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<dynamic> addStream(Stream<dynamic> stream) async {
    await for (final d in stream) {
      add(d);
    }
  }

  @override
  Future<dynamic> get done => Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _status(List<String> relays) => jsonEncode([
      'POOL:STATUS',
      {'connected': relays, 'count': relays.length, 'latency': {}}
    ]);

void main() {
  test('two failed connects before the pool ever confirmed fall back',
      () async {
    var unreachable = 0;
    var opened = 0;
    final proxy = RelayPoolProxy(
      relays: RelayConfig.defaultRelays,
      dmRelays: RelayConfig.defaultRelays,
      poolUrl: 'wss://h/api/relay-pool',
      channelFactory: (_) {
        opened++;
        return _FakeChannel(failImmediately: true);
      },
      onProxyUnreachable: () => unreachable++,
    );
    fakeAsync((async) {
      proxy.connectAll();
      async.flushMicrotasks();
      expect(unreachable, 0, reason: 'one failure is not yet a verdict');
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      expect(unreachable, 1);
      async.elapse(const Duration(seconds: 90));
      expect(unreachable, 1, reason: 'fires once');
      expect(opened, greaterThanOrEqualTo(2 * proxy.shards.length));
    });
    await proxy.disconnectAll();
  });

  test('a proxy that connected once and then cannot be reached falls back',
      () async {
    var unreachable = 0;
    final channels = <_FakeChannel>[];
    var attempt = 0;
    FakeAsync? fa;
    final epoch = DateTime(2026, 9, 21);
    final proxy = RelayPoolProxy(
      relays: RelayConfig.defaultRelays,
      dmRelays: RelayConfig.defaultRelays,
      poolUrl: 'wss://h/api/relay-pool',
      channelFactory: (_) {
        attempt++;
        final ch = _FakeChannel(failImmediately: attempt > 2);
        channels.add(ch);
        return ch;
      },
      onProxyUnreachable: () => unreachable++,
      now: () => fa?.getClock(epoch).now() ?? DateTime.now(),
    );
    expect(proxy.shards.length, lessThanOrEqualTo(2));
    fakeAsync((async) {
      fa = async;
      proxy.connectAll();
      async.flushMicrotasks();
      final first = channels.take(proxy.shards.length).toList();
      for (final ch in first) {
        ch.inject(_status(['wss://relay.example']));
      }
      async.flushMicrotasks();
      expect(proxy.connectedCount, 1);
      expect(unreachable, 0);
      for (final ch in first) {
        ch.drop();
      }
      async.flushMicrotasks();
      expect(unreachable, 0,
          reason: 'a dropped session is a normal reconnect, not a verdict');
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 7));
      async.flushMicrotasks();
      expect(unreachable, 0,
          reason: 'two quick failures right after a live session, the shape '
              'of a resume from background, are a blip and keep retrying');
      expect(proxy.connectedCount, 0);
      async.elapse(const Duration(seconds: 45));
      async.flushMicrotasks();
      expect(unreachable, 1,
          reason: 'a streak that outlasts the grace period is the verdict');
      expect(attempt, greaterThanOrEqualTo(4 * proxy.shards.length + 2),
          reason: 'the shard kept reconnecting with backoff through the grace');
    });
    await proxy.disconnectAll();
  });

  test('a session that comes back inside the grace period stays on the proxy',
      () async {
    var unreachable = 0;
    final channels = <_FakeChannel>[];
    var attempt = 0;
    FakeAsync? fa;
    final epoch = DateTime(2026, 9, 21);
    final proxy = RelayPoolProxy(
      relays: RelayConfig.defaultRelays,
      dmRelays: RelayConfig.defaultRelays,
      poolUrl: 'wss://h/api/relay-pool',
      channelFactory: (_) {
        attempt++;
        final ch = _FakeChannel(failImmediately: attempt > 2 && attempt <= 6);
        channels.add(ch);
        return ch;
      },
      onProxyUnreachable: () => unreachable++,
      now: () => fa?.getClock(epoch).now() ?? DateTime.now(),
    );
    fakeAsync((async) {
      fa = async;
      proxy.connectAll();
      async.flushMicrotasks();
      for (final ch in channels.take(proxy.shards.length)) {
        ch.inject(_status(['wss://relay.example']));
      }
      async.flushMicrotasks();
      for (final ch in channels.take(proxy.shards.length).toList()) {
        ch.drop();
      }
      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(unreachable, 0);
      for (final ch in channels.where((c) => !c.failImmediately).skip(proxy.shards.length)) {
        ch.inject(_status(['wss://relay.example']));
      }
      async.flushMicrotasks();
      expect(proxy.connectedCount, 1, reason: 'the proxy came back');
      async.elapse(const Duration(seconds: 60));
      async.flushMicrotasks();
      expect(unreachable, 0,
          reason: 'a recovered session never turns into a fallback later');
    });
    await proxy.disconnectAll();
  });

  test('a socket that opens but never answers counts as a failed connect',
      () async {
    var unreachable = 0;
    var opened = 0;
    final proxy = RelayPoolProxy(
      relays: RelayConfig.defaultRelays,
      dmRelays: RelayConfig.defaultRelays,
      poolUrl: 'wss://h/api/relay-pool',
      confirmTimeout: const Duration(seconds: 5),
      channelFactory: (_) {
        opened++;
        return _FakeChannel(hang: true);
      },
      onProxyUnreachable: () => unreachable++,
    );
    fakeAsync((async) {
      proxy.connectAll();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 4));
      expect(unreachable, 0);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(unreachable, 0, reason: 'the first hang is retried');
      async.elapse(const Duration(seconds: 12));
      async.flushMicrotasks();
      expect(unreachable, 1, reason: 'the second hang is the verdict');
      expect(opened, greaterThanOrEqualTo(2 * proxy.shards.length));
    });
    await proxy.disconnectAll();
  });

  test('a POOL:RETRACT frame reaches the retraction callback', () async {
    final retracted = <String>[];
    final channels = <_FakeChannel>[];
    final proxy = RelayPoolProxy(
      relays: RelayConfig.defaultRelays,
      dmRelays: RelayConfig.defaultRelays,
      poolUrl: 'wss://h/api/relay-pool',
      channelFactory: (_) {
        final ch = _FakeChannel();
        channels.add(ch);
        return ch;
      },
    );
    proxy.onEventRetracted = retracted.add;
    proxy.connectAll();
    final id = 'e' * 64;
    channels.first.inject(jsonEncode(['POOL:RETRACT', id, 'spam']));
    channels.first.inject(jsonEncode(['POOL:RETRACT', 'not-an-id']));
    await Future<void>.delayed(Duration.zero);
    expect(retracted, [id]);
    expect(PoolMessage.parse(jsonEncode(['POOL:RETRACT', id])), isA<PoolRetract>());
    expect(PoolMessage.parse(jsonEncode(['POOL:RETRACT', 'zz'])), isNull);
    await proxy.disconnectAll();
  });

  test('a shard that answers keeps a sibling shard from declaring the host down',
      () async {
    var unreachable = 0;
    final channels = <_FakeChannel>[];
    final proxy = RelayPoolProxy(
      relays: RelayConfig.defaultRelays,
      dmRelays: RelayConfig.defaultRelays,
      poolUrl: 'wss://h/api/relay-pool',
      channelFactory: (_) {
        final ch = _FakeChannel(failImmediately: channels.isNotEmpty);
        channels.add(ch);
        return ch;
      },
      onProxyUnreachable: () => unreachable++,
    );
    fakeAsync((async) {
      proxy.connectAll();
      async.flushMicrotasks();
      channels.first.inject(_status(['wss://relay.example']));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(unreachable, 0);
      expect(proxy.connectedCount, 1);
    });
    await proxy.disconnectAll();
  });
}

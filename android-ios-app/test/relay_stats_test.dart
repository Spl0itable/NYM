import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/core/constants/relays.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/nostr/identity_service.dart';
import 'package:nym_bar/services/nostr/nostr_service.dart';
import 'package:nym_bar/services/relay/relay_connection.dart';
import 'package:nym_bar/services/relay/relay_message.dart';
import 'package:nym_bar/services/relay/relay_pool.dart';
import 'package:nym_bar/services/relay/relay_pool_proxy.dart';
import 'package:nym_bar/services/relay/relay_stats.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  // ---------------------------------------------------------------------------
  // RelayStats: new App-data / per-kind / shard fields + serialization.
  // ---------------------------------------------------------------------------
  group('RelayStats new fields', () {
    test('recordApiData folds bytes into api + global totals and per-action', () {
      final s = RelayStats();
      expect(s.hasApiData, isFalse);
      s.recordApiData('pm-get', sent: 100, recv: 900);
      s.recordApiData('pm-get', sent: 50, recv: 50);
      s.recordApiData('settings-get', sent: 10, recv: 0);

      // API totals.
      expect(s.apiBytesSent, 160);
      expect(s.apiBytesReceived, 950);
      // Folded into the global byte totals too (shop.js:118-119).
      expect(s.bytesSent, 160);
      expect(s.bytesReceived, 950);
      expect(s.hasApiData, isTrue);

      // Per-action: count only bumps when there were sent bytes.
      final pm = s.apiActionStats['pm-get']!;
      expect(pm.count, 2);
      expect(pm.bytesSent, 150);
      expect(pm.bytesReceived, 950);
      expect(pm.bytes, 1100);
      expect(s.apiActionStats['settings-get']!.count, 1);
    });

    test('recordRelayKind tallies per-relay per-kind; non-wss → relay-pool', () {
      final s = RelayStats();
      s.recordRelayKind('wss://a.relay', 20000, 120);
      s.recordRelayKind('wss://a.relay', 20000, 80);
      s.recordRelayKind('wss://a.relay', 7, 40);
      s.recordRelayKind('relay-pool', 1, 10); // non-wss bucket

      final a = s.kindStatsPerRelay['wss://a.relay']!;
      expect(a[20000]!.count, 2);
      expect(a[20000]!.bytes, 200);
      expect(a[7]!.count, 1);
      expect(s.kindStatsPerRelay['relay-pool']![1]!.count, 1);
    });

    test('snapshot is a deep copy — mutating the source never tears it', () {
      final s = RelayStats();
      s.recordApiData('auth', sent: 10, recv: 20);
      s.recordRelayKind('wss://a', 1, 33);
      s.shardInfo.add(ShardInfo(
          id: 'geo-0', status: 'connected', connected: 2, total: 5));

      final snap = s.snapshot();
      // Mutate the live object after snapshotting.
      s.recordApiData('auth', sent: 5, recv: 5);
      s.recordRelayKind('wss://a', 1, 1);
      s.shardInfo.clear();

      // Snapshot is frozen at its values.
      expect(snap.apiActionStats['auth']!.count, 1);
      expect(snap.apiActionStats['auth']!.bytes, 30);
      expect(snap.kindStatsPerRelay['wss://a']![1]!.count, 1);
      expect(snap.kindStatsPerRelay['wss://a']![1]!.bytes, 33);
      expect(snap.shardInfo, hasLength(1));
      expect(snap.shardInfo.first.id, 'geo-0');
      expect(snap.shardInfo.first.connected, 2);
      expect(snap.shardInfo.first.total, 5);
    });
  });

  // ---------------------------------------------------------------------------
  // RelayPoolProxy: geo-relay sharding + shard-info + per-kind tracking.
  // ---------------------------------------------------------------------------
  group('RelayPoolProxy geo relays', () {
    test('updateGeoRelays opens a geo shard socket and pushes its RELAYS', () async {
      final fakes = <_FakeChannel>[];
      final proxy = RelayPoolProxy(
        relays: RelayConfig.defaultRelays,
        dmRelays: RelayConfig.defaultRelays,
        poolUrl: 'wss://h/api/relay-pool',
        channelFactory: (uri) {
          final f = _FakeChannel();
          fakes.add(f);
          return f;
        },
      );
      proxy.connectAll();
      // No geo shard before geo relays are applied.
      expect(proxy.shards.map((s) => s.id), isNot(contains('geo-0')));
      final before = fakes.length;

      proxy.updateGeoRelays(['wss://geo-a.example']);

      // A geo-0 shard now exists with the geo relay, and a new socket opened.
      expect(proxy.shards.map((s) => s.id), contains('geo-0'));
      final geo = proxy.shards.firstWhere((s) => s.id == 'geo-0');
      expect(geo.relays, ['wss://geo-a.example']);
      expect(fakes.length, before + 1);
      // The new socket got a RELAYS frame carrying the geo relay.
      final newSock = fakes.last;
      expect(
          newSock.sent.any((m) => m.contains('RELAYS') && m.contains('geo-a.example')),
          isTrue);
      expect(proxy.geoRelayUrls, ['wss://geo-a.example']);

      // Idempotent: same set → no extra socket.
      final after = fakes.length;
      proxy.updateGeoRelays(['wss://geo-a.example']);
      expect(fakes.length, after);

      await proxy.disconnectAll();
    });

    test('shrinking the geo set closes the now-empty geo shard socket', () async {
      final fakes = <_FakeChannel>[];
      final proxy = RelayPoolProxy(
        relays: RelayConfig.defaultRelays,
        dmRelays: RelayConfig.defaultRelays,
        poolUrl: 'wss://h/api/relay-pool',
        channelFactory: (uri) {
          final f = _FakeChannel();
          fakes.add(f);
          return f;
        },
      );
      proxy.connectAll();
      proxy.updateGeoRelays(['wss://geo-a.example']);
      expect(proxy.shards.map((s) => s.id), contains('geo-0'));
      // Drop all geo relays → geo-0 shard vanishes.
      proxy.updateGeoRelays(const []);
      expect(proxy.shards.map((s) => s.id), isNot(contains('geo-0')));
      await proxy.disconnectAll();
    });

    test('stats.shardInfo reflects the live shard sockets', () async {
      final fakes = <_FakeChannel>[];
      final proxy = RelayPoolProxy(
        relays: RelayConfig.defaultRelays,
        dmRelays: RelayConfig.defaultRelays,
        poolUrl: 'wss://h/api/relay-pool',
        channelFactory: (uri) {
          final f = _FakeChannel();
          fakes.add(f);
          return f;
        },
      );
      proxy.connectAll();
      final info = proxy.stats.shardInfo;
      final ids = info.map((s) => s.id).toList();
      expect(ids, contains('app-0'));
      expect(ids, contains('critical-0'));
      // Sockets are "open" (the fake treats listen as open) → status connected,
      // and the app-0 shard carries exactly 1 relay.
      final app = info.firstWhere((s) => s.id == 'app-0');
      expect(app.status, 'connected');
      expect(app.total, 1);
      await proxy.disconnectAll();
    });

    test('per-kind breakdown tracks attributed-relay events post-dedup', () async {
      final fakes = <_FakeChannel>[];
      final proxy = RelayPoolProxy(
        relays: RelayConfig.defaultRelays,
        dmRelays: RelayConfig.defaultRelays,
        poolUrl: 'wss://h/api/relay-pool',
        channelFactory: (uri) {
          final f = _FakeChannel();
          fakes.add(f);
          return f;
        },
      );
      proxy.connectAll();
      final sub = proxy.subscribe([NostrFilter(kinds: [20000])]);
      sub.events.listen((_) {});

      // EVENT with a trailing wss:// sourceRelay → attributed to that relay.
      final frame = jsonEncode([
        'EVENT',
        sub.subId,
        {
          'id': 'k1',
          'pubkey': 'pk',
          'created_at': 1,
          'kind': 20000,
          'tags': [],
          'content': 'x',
          'sig': '',
        },
        'wss://attr.relay',
      ]);
      fakes.first.inject(frame);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final s = proxy.stats;
      expect(s.eventsPerRelay['wss://attr.relay'], 1);
      final perKind = s.kindStatsPerRelay['wss://attr.relay'];
      expect(perKind, isNotNull);
      expect(perKind![20000]!.count, 1);
      expect(perKind[20000]!.bytes, greaterThan(0));
      await proxy.disconnectAll();
    });
  });

  // ---------------------------------------------------------------------------
  // RelayPool (direct mode): updateGeoRelays opens direct geo sockets.
  // ---------------------------------------------------------------------------
  group('RelayPool geo relays', () {
    test('updateGeoRelays adds a direct connection for each new geo url', () {
      final opened = <String>[];
      final pool = RelayPool(
        relays: const ['wss://a.relay'],
        connectionFactory: (url) {
          opened.add(url);
          return _StubConn(url);
        },
      );
      pool.connectAll();
      pool.updateGeoRelays(['wss://geo-1.example', 'wss://geo-2.example']);
      expect(pool.relayUrls, containsAll(
          ['wss://a.relay', 'wss://geo-1.example', 'wss://geo-2.example']));
      // Adding the same url again is a no-op.
      pool.updateGeoRelays(['wss://geo-1.example']);
      expect(pool.relayUrls.where((u) => u == 'wss://geo-1.example').length, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // NostrService: per-channel geo relay connection wires into the pool.
  // ---------------------------------------------------------------------------
  group('NostrService geo relay connection', () {
    test('connectGeoRelaysForGeohash applies the closest geo relays to the pool',
        () async {
      final rec = _GeoRecordingTransport();
      final svc = NostrService(
        identity: _identity(),
        pool: rec,
      );
      // Seed geo relays (so no fetch is needed) at distinct locations.
      svc.geoRelays.addAll(const [
        GeoRelay(url: 'wss://near.example', lat: 0, lng: 0),
        GeoRelay(url: 'wss://far.example', lat: -80, lng: 0),
      ]);

      await svc.connectGeoRelaysForGeohash('s0000'); // ~equator/prime-meridian
      expect(rec.geoUpdates, isNotEmpty);
      // The closest relay was marked current and pushed to the pool.
      expect(svc.currentGeoRelays, contains('wss://near.example'));
      expect(rec.geoUpdates.last, contains('wss://near.example'));
    });

    test('low-data mode only shards entered-channel geo relays', () async {
      final rec = _GeoRecordingTransport();
      final svc = NostrService(identity: _identity(), pool: rec)
        ..lowDataMode = true;
      // 7 relays spread out so the closest-5 (geoRelayCount) is a strict subset
      // of the full list — proving low-data shards only the entered subset.
      svc.geoRelays.addAll(const [
        GeoRelay(url: 'wss://r0.example', lat: 0, lng: 0),
        GeoRelay(url: 'wss://r1.example', lat: 1, lng: 1),
        GeoRelay(url: 'wss://r2.example', lat: 2, lng: 2),
        GeoRelay(url: 'wss://r3.example', lat: 3, lng: 3),
        GeoRelay(url: 'wss://r4.example', lat: 4, lng: 4),
        GeoRelay(url: 'wss://far1.example', lat: -80, lng: 170),
        GeoRelay(url: 'wss://far2.example', lat: -85, lng: -170),
      ]);
      // applyGeoRelays with no entered channel → empty (low-data skips the full
      // list).
      svc.applyGeoRelays();
      expect(rec.geoUpdates.last, isEmpty);

      await svc.connectGeoRelaysForGeohash('s0000'); // ~equator/prime-meridian
      // Now only the entered channel's closest 5 are sharded (NOT the 2 far
      // relays) — low-data carries the entered subset, not the full list.
      final last = rec.geoUpdates.last;
      expect(last, hasLength(RelayConfig.geoRelayCount));
      expect(last, isNot(contains('wss://far1.example')));
      expect(last, isNot(contains('wss://far2.example')));
    });
  });

  // ---------------------------------------------------------------------------
  // ApiClient: /api traffic flows into the shared stats sink.
  // ---------------------------------------------------------------------------
  group('ApiClient app-data tracking', () {
    tearDown(() => ApiClient.apiStatsSink = null);

    test('storageAction records per-action bytes into the sink', () async {
      final sink = RelayStats();
      ApiClient.apiStatsSink = sink;
      final mock = MockClient((req) async =>
          http.Response(jsonEncode({'ok': true}), 200));
      final c = ApiClient(client: mock, baseUrl: 'https://h/api/proxy');
      await c.storageAction({'action': 'settings-set', 'value': 'x'});

      expect(sink.hasApiData, isTrue);
      final a = sink.apiActionStats['settings-set'];
      expect(a, isNotNull);
      expect(a!.count, 1);
      expect(a.bytesSent, greaterThan(0));
      expect(a.bytesReceived, greaterThan(0));
      // Folded into global byte totals too.
      expect(sink.bytesSent, greaterThan(0));
      expect(sink.bytesReceived, greaterThan(0));
    });

    test('no sink set → no tracking (tests stay isolated)', () async {
      ApiClient.apiStatsSink = null;
      final mock = MockClient((req) async =>
          http.Response(jsonEncode({'relays': []}), 200));
      final c = ApiClient(client: mock, baseUrl: 'https://h/api/proxy');
      // Should not throw despite no sink.
      await c.geoRelays();
    });
  });
}

Identity _identity() => Identity(pubkey: 'a' * 64, privkey: null, nym: 'tester');

/// A PoolTransport that records every updateGeoRelays payload.
class _GeoRecordingTransport implements PoolTransport {
  final List<List<String>> geoUpdates = [];
  @override
  void updateGeoRelays(List<String> geoRelayUrls) =>
      geoUpdates.add(geoRelayUrls);
  @override
  void connectAll() {}
  @override
  Future<void> disconnectAll() async {}
  @override
  int get connectedCount => 0;
  @override
  Set<String> get connectedRelayUrls => const {};
  @override
  RelayStats get stats => RelayStats();
  @override
  Future<int> publish(NostrEvent event) async => 0;
  @override
  Future<int> publishDm(NostrEvent event) async => 0;
  @override
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls) async =>
      0;
  @override
  Subscription subscribe(List<NostrFilter> filters, {String? subId}) =>
      throw UnimplementedError();
  @override
  void closeSubscription(Subscription sub) {}
}

/// A stub RelayConnection that never opens a real socket.
class _StubConn implements RelayConnection {
  _StubConn(this.url);
  @override
  final String url;
  bool _connected = false;
  @override
  void connect() => _connected = true;
  @override
  bool get isConnected => _connected;
  @override
  RelayStats get stats => RelayStats();
  @override
  void subscribe(String subId, List<NostrFilter> filters) {}
  @override
  void unsubscribe(String subId) {}
  @override
  Stream<RelayMessage> get messages => const Stream.empty();
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory WebSocketChannel stand-in (same shape as network_test's fake).
class _FakeChannel implements WebSocketChannel {
  final StreamController<dynamic> _inbound = StreamController<dynamic>();
  final List<String> sent = [];
  late final _FakeSink _sink = _FakeSink(sent, _inbound);

  void inject(String frame) => _inbound.add(frame);

  @override
  Stream<dynamic> get stream => _inbound.stream;
  @override
  WebSocketSink get sink => _sink;
  @override
  Future<void> get ready => Future<void>.value();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => _sink.closeCode;
  @override
  String? get closeReason => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._sent, this._inbound);
  final List<String> _sent;
  final StreamController<dynamic> _inbound;
  int? closeCode;

  @override
  void add(dynamic data) => _sent.add(data.toString());
  @override
  Future<dynamic> close([int? code, String? reason]) async {
    closeCode = code;
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

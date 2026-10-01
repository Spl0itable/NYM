import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/constants/relays.dart';
import '../nostr/event_provenance.dart';
import '../../models/nostr_event.dart';
import 'held_publishes.dart';
import 'relay_connection.dart';
import 'relay_message.dart';
import 'relay_stats.dart';

/// Bounded seen-id set that surfaces cross-relay duplicates once; evicts oldest first.
class EventDeduper {
  EventDeduper({this.maxIds = 10000});

  final int maxIds;
  final Set<String> _seen = <String>{};

  /// Records [id]; true when new, false when already seen.
  bool add(String id) {
    if (_seen.contains(id)) return false;
    _seen.add(id);
    if (_seen.length > maxIds) {
      // Evict oldest; Dart Sets preserve insertion order.
      final overflow = _seen.length - maxIds;
      final toRemove = _seen.take(overflow).toList();
      _seen.removeAll(toRemove);
    }
    return true;
  }

  bool contains(String id) => _seen.contains(id);
  void forget(String id) => _seen.remove(id);
  int get length => _seen.length;
  void clear() => _seen.clear();
}

String copyKey(NostrEvent event) => '${event.id}:${event.sig}';

String generateSubId([Random? rng]) {
  final r = rng ?? Random();
  // 11 base36 chars, about 56 bits, like JS `Math.random().toString(36)`.
  const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
  final sb = StringBuffer();
  for (var i = 0; i < 11; i++) {
    sb.write(chars[r.nextInt(36)]);
  }
  return sb.toString();
}

/// Injected async signature verifier; defaults to accept-all so this layer needs no crypto.
typedef EventVerifier = Future<bool> Function(NostrEvent event);

Future<bool> _acceptAll(NostrEvent _) async => true;

/// Pool surface shared by direct [RelayPool] and `RelayPoolProxy`.
abstract interface class PoolTransport {
  void closeSubscription(Subscription sub);

  Subscription subscribe(List<NostrFilter> filters, {String? subId});

  void connectAll();

  /// Applies the geo-relay set: proxy mode re-shards, direct mode opens sockets and back-fills subs.
  void updateGeoRelays(List<String> geoRelayUrls);

  /// Broadcasts [event]; returns how many relays/shards accepted it.
  Future<int> publish(NostrEvent event);

  /// Publishes a kind-1059 DM; proxy mode sends `["DM_EVENT",e]` so default relays get priority.
  Future<int> publishDm(NostrEvent event);

  /// Publishes a geohash event; proxy mode sends `["GEO_EVENT",e,[urls]]` when [closestRelayUrls] is set.
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls);

  int get connectedCount;

  /// Connected relay URLs, used by the geo-relay keep-alive to spot drops.
  Set<String> get connectedRelayUrls;

  /// Admission check for geohash events by delivering relay; null admits all, and unjudgeable events pass.
  set geoOriginAllows(bool Function(NostrEvent event, String? relayUrl)? fn);

  /// Live traffic counters aggregated across every socket, for the Network Stats modal.
  RelayStats get stats;

  Future<void> disconnectAll();
}

/// Multi-relay subscription emitting deduped, optionally verified events; [eose] completes on quorum or timeout.
class Subscription {
  Subscription._(
    this.subId,
    this._transport,
    this._verify,
    this._relayCount, {
    required double eoseQuorum,
    required Duration eoseTimeout,
    void Function(NostrEvent event)? onRejected,
  })  : _eoseQuorum = eoseQuorum,
        _eoseTimeout = eoseTimeout,
        _onRejected = onRejected;

  /// Transport-agnostic constructor used by both pool transports.
  factory Subscription.forTransport(
    String subId,
    PoolTransport transport,
    EventVerifier verify,
    int relayCount, {
    required double eoseQuorum,
    required Duration eoseTimeout,
    void Function(NostrEvent event)? onRejected,
  }) =>
      Subscription._(
        subId,
        transport,
        verify,
        relayCount,
        eoseQuorum: eoseQuorum,
        eoseTimeout: eoseTimeout,
        onRejected: onRejected,
      );

  final String subId;
  final PoolTransport _transport;
  final EventVerifier _verify;
  final int _relayCount;
  final double _eoseQuorum;
  final Duration _eoseTimeout;
  final void Function(NostrEvent event)? _onRejected;

  final EventDeduper _deduper = EventDeduper();
  final EventDeduper _delivered = EventDeduper();
  final StreamController<NostrEvent> _events =
      StreamController<NostrEvent>.broadcast();
  final Completer<void> _eose = Completer<void>();
  final Set<String> _eosedRelays = <String>{};
  Timer? _eoseTimer;
  bool _closed = false;
  bool _answered = false;

  Stream<NostrEvent> get events => _events.stream;

  bool get answered => _answered;

  Future<void> get eose => _eose.future;

  /// True once closed; cached subscriptions must be re-created, not reused.
  bool get isClosed => _closed;

  void _start() => startEose();

  /// Arms the EOSE timeout; public so the proxy transport can drive it.
  void startEose() {
    _eoseTimer = Timer(_eoseTimeout, _completeEose);
  }

  /// Handles an EVENT from [relayUrl]; the proxy dedupes globally first, making this pass a no-op.
  Future<void> onEvent(String relayUrl, NostrEvent event) async {
    if (_closed) return;
    if (_delivered.contains(event.id)) return;
    final key = copyKey(event);
    if (!_deduper.add(key)) return;
    final ok = await _verify(event);
    if (!ok) {
      _deduper.forget(key);
      _onRejected?.call(event);
      return;
    }
    if (_closed) return;
    if (!_delivered.add(event.id)) return;
    _answered = true;
    if (!_events.isClosed) _events.add(event);
  }

  void onEose(String relayUrl, {bool closed = false}) {
    if (_closed) return;
    if (!closed) _answered = true;
    _eosedRelays.add(relayUrl);
    final needed = max(1, (_relayCount * _eoseQuorum).ceil());
    if (_eosedRelays.length >= needed) {
      _completeEose();
    }
  }

  void _completeEose() {
    _eoseTimer?.cancel();
    _eoseTimer = null;
    if (!_eose.isCompleted) _eose.complete();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _eoseTimer?.cancel();
    _eoseTimer = null;
    _transport.closeSubscription(this);
    if (!_eose.isCompleted) _eose.complete();
    await _events.close();
  }
}

/// Direct WebSocket relay pool; transport only, with verification injected.
class RelayPool implements PoolTransport {
  RelayPool({
    required List<String> relays,
    EventVerifier? verify,
    Set<String>? writeOnlyRelays,
    RelayConnection Function(String url)? connectionFactory,
    Random? random,
    this.eoseQuorum = 0.6,
    this.eoseTimeout = const Duration(seconds: 4),
    Duration heldWait = const Duration(seconds: 15),
  })  : _verify = verify ?? _acceptAll,
        _held = HeldPublishes(max: heldMax, wait: heldWait),
        _writeOnly = writeOnlyRelays ?? RelayConfig.writeOnlyRelays,
        _connectionFactory =
            connectionFactory ?? ((url) => RelayConnection(url)),
        _rng = random ?? Random() {
    for (final url in relays) {
      _addRelayInternal(url);
    }
  }

  static const int heldMax = 16;

  final EventVerifier _verify;
  final HeldPublishes<PoolTransport> _held;
  bool _disposed = false;
  final Set<String> _writeOnly;
  final RelayConnection Function(String url) _connectionFactory;
  final Random _rng;

  /// Fraction of relays that must EOSE before [Subscription.eose] completes (at least one).
  final double eoseQuorum;
  final Duration eoseTimeout;

  final Map<String, RelayConnection> _connections = {};
  final Map<String, StreamSubscription<RelayMessage>> _msgSubs = {};
  final Map<String, StreamSubscription<RelayStatus>> _statusSubs = {};

  final Map<String, Subscription> _subscriptions = {};

  /// Pool-level throughput history (last 60 per-second counts), fed by [_sampler].
  final List<int> _throughputHistory = [];

  /// 1s sampler that aggregates per-socket counts into [_throughputHistory] and resets them.
  Timer? _sampler;

  bool get _isWritable => true;
  bool _isReadable(String url) => !_writeOnly.contains(url);

  List<String> get relayUrls => _connections.keys.toList();

  @override
  int get connectedCount =>
      _connections.values.where((c) => c.isConnected).length;

  Map<String, bool> get connectionStatus =>
      {for (final e in _connections.entries) e.key: e.value.isConnected};

  @override
  Set<String> get connectedRelayUrls => {
        for (final e in _connections.entries)
          if (e.value.isConnected) e.key,
      };

  /// Fresh aggregate of every socket's counters plus the pool-owned throughput history.
  @override
  RelayStats get stats {
    final agg = RelayStats(
      throughputHistory: List<int>.from(_throughputHistory),
    );
    for (final conn in _connections.values) {
      final s = conn.stats;
      agg.bytesReceived += s.bytesReceived;
      agg.bytesSent += s.bytesSent;
      agg.totalEvents += s.totalEvents;
      agg.eventsThisSecond += s.eventsThisSecond;
      s.eventsPerRelay.forEach((url, n) {
        agg.eventsPerRelay[url] = (agg.eventsPerRelay[url] ?? 0) + n;
      });
      // One socket per url here, so latency is a straight copy.
      s.latencyPerRelay.forEach((url, ms) {
        agg.latencyPerRelay[url] = ms;
      });
      s.kindStatsPerRelay.forEach((url, perKind) {
        agg.kindStatsPerRelay[url] = {
          for (final e in perKind.entries) e.key: e.value.copy(),
        };
      });
    }
    return agg;
  }

  /// Starts the 1s throughput sampler (idempotent).
  void _startSampler() {
    if (_sampler != null) return;
    _sampler = Timer.periodic(const Duration(seconds: 1), (_) {
      var events = 0;
      for (final conn in _connections.values) {
        events += conn.stats.eventsThisSecond;
        conn.stats.eventsThisSecond = 0;
      }
      _throughputHistory.add(events);
      while (_throughputHistory.length > RelayStats.throughputCap) {
        _throughputHistory.removeAt(0);
      }
    });
  }

  void _stopSampler() {
    _sampler?.cancel();
    _sampler = null;
  }

  void _addRelayInternal(String url) {
    if (_connections.containsKey(url)) return;
    final conn = _connectionFactory(url);
    _connections[url] = conn;
    _msgSubs[url] = conn.messages.listen((msg) => _onRelayMessage(url, msg));
    _statusSubs[url] = conn.statusStream.listen((status) {
      if (status == RelayStatus.connected) _held.flush(this);
    });
  }

  final Set<String> _bannedRelays = {};

  Set<String> get bannedRelays => Set.unmodifiable(_bannedRelays);

  /// Adds a relay; when already connected it connects and back-fills active subscriptions.
  void addRelay(String url) {
    if (_bannedRelays.contains(url)) return;
    if (_connections.containsKey(url)) return;
    _addRelayInternal(url);
    final conn = _connections[url]!;
    conn.connect();
    if (_isReadable(url)) {
      for (final sub in _subscriptions.values) {
        conn.subscribe(sub.subId, _activeFilters[sub.subId] ?? const []);
      }
    }
  }

  Future<void> removeRelay(String url) async {
    final conn = _connections.remove(url);
    await _msgSubs.remove(url)?.cancel();
    await _statusSubs.remove(url)?.cancel();
    await conn?.close();
  }

  @override
  void connectAll() {
    _disposed = false;
    _startSampler();
    for (final conn in _connections.values) {
      conn.connect();
    }
    if (connectedCount > 0) _held.flush(this);
  }

  /// Direct mode: opens and back-fills a socket per new geo relay url; skips present or blocked urls.
  @override
  void updateGeoRelays(List<String> geoRelayUrls) {
    for (final url in geoRelayUrls) {
      if (!url.startsWith('wss://')) continue;
      if (_connections.containsKey(url)) continue;
      addRelay(url);
    }
  }

  @override
  Future<void> disconnectAll() async {
    _disposed = true;
    _held.dropAll();
    _stopSampler();
    final subs = _subscriptions.values.toList();
    for (final s in subs) {
      await s.close();
    }
    for (final s in _msgSubs.values) {
      await s.cancel();
    }
    for (final s in _statusSubs.values) {
      await s.cancel();
    }
    _msgSubs.clear();
    _statusSubs.clear();
    final conns = _connections.values.toList();
    _connections.clear();
    for (final c in conns) {
      await c.close();
    }
  }

  /// Active filters per subId, for back-filling newly added relays.
  final Map<String, List<NostrFilter>> _activeFilters = {};

  /// Subscribes across all readable relays.
  @override
  Subscription subscribe(List<NostrFilter> filters, {String? subId}) {
    final id = subId ?? generateSubId(_rng);
    final readable = _connections.keys.where(_isReadable).length;
    final sub = Subscription._(
      id,
      this,
      _verify,
      readable,
      eoseQuorum: eoseQuorum,
      eoseTimeout: eoseTimeout,
    );
    _subscriptions[id] = sub;
    _activeFilters[id] = filters;
    sub._start();
    for (final entry in _connections.entries) {
      if (_isReadable(entry.key)) {
        entry.value.subscribe(id, filters);
      }
    }
    return sub;
  }

  @override
  void closeSubscription(Subscription sub) {
    _subscriptions.remove(sub.subId);
    _activeFilters.remove(sub.subId);
    for (final entry in _connections.entries) {
      if (_isReadable(entry.key)) {
        entry.value.unsubscribe(sub.subId);
      }
    }
  }

  /// Live subscriptions and filters, for replay onto a replacement pool after a swap.
  Map<String, ({Subscription sub, List<NostrFilter> filters})>
      activeSubscriptions() => {
            for (final e in _subscriptions.entries)
              e.key: (
                sub: e.value,
                filters: _activeFilters[e.key] ?? const [],
              ),
          };

  /// Adopts [sub] from a previous pool and re-issues its REQ; its dedup suppresses repeats.
  void replaySubscription(Subscription sub, List<NostrFilter> filters) {
    final id = sub.subId;
    _subscriptions[id] = sub;
    _activeFilters[id] = filters;
    for (final entry in _connections.entries) {
      if (_isReadable(entry.key)) {
        entry.value.subscribe(id, filters);
      }
    }
  }

  void handOverHeld(PoolTransport next) => _held.flush(next);

  /// Closes sockets but keeps [Subscription]s alive for the direct/proxy swap.
  Future<void> disconnectSocketsOnly() async {
    _stopSampler();
    _subscriptions.clear();
    _activeFilters.clear();
    for (final s in _msgSubs.values) {
      await s.cancel();
    }
    for (final s in _statusSubs.values) {
      await s.cancel();
    }
    _msgSubs.clear();
    _statusSubs.clear();
    final conns = _connections.values.toList();
    _connections.clear();
    for (final c in conns) {
      await c.close();
    }
  }

  /// Broadcasts [event]; returns how many relays accepted it.
  @override
  Future<int> publish(NostrEvent event) async {
    if (!_disposed && connectedCount == 0) {
      return _held.hold((via) => via.publish(event));
    }
    final futures = <Future<OkMessage>>[];
    for (final entry in _connections.entries) {
      // Write-only relays still receive EVENTs.
      if (_isWritable) {
        futures.add(entry.value.publish(event));
      }
    }
    if (futures.isEmpty) return 0;
    final results = await Future.wait(futures);
    return results.where((r) => r.accepted).length;
  }

  /// Direct mode has no proxy frames: DMs publish as plain EVENTs.
  @override
  Future<int> publishDm(NostrEvent event) => publish(event);

  /// Direct mode has no proxy frames: geo events publish as plain EVENTs.
  @override
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls) =>
      publish(event);

  bool Function(NostrEvent event, String? relayUrl)? _geoOriginAllows;
  @override
  set geoOriginAllows(bool Function(NostrEvent event, String? relayUrl)? fn) =>
      _geoOriginAllows = fn;

  void _onRelayMessage(String relayUrl, RelayMessage msg) {
    switch (msg) {
      case EventMessage(:final subId, :final event):
        if (RelayConfig.isAppRelayOnly(
                event.kind, event.tagValue('g'), event.tagValue('d')) &&
            relayUrl != RelayConfig.appRelay) {
          return;
        }
        // Gate before verification and dedup, so a wrong-relay copy can't claim the id.
        final geoGate = _geoOriginAllows;
        if (geoGate != null && !geoGate(event, relayUrl)) return;
        // Record before dedup, since the discarded copies are the relay list.
        eventProvenance.record(event, relayUrl);
        final sub = _subscriptions[subId];
        if (sub != null) {
          // Fire and forget; verification is async.
          unawaited(sub.onEvent(relayUrl, event));
        }
      case EoseMessage(:final subId):
        _subscriptions[subId]?.onEose(relayUrl);
      case ClosedMessage(:final subId, :final reason):
        // Count a relay-side CLOSED as EOSE so the quorum doesn't stall.
        _subscriptions[subId]?.onEose(relayUrl, closed: true);
        _dropIfRelayWideRejection(relayUrl, reason);
      case OkMessage(:final message):
        // OKs are handled per connection via publish() futures.
        _dropIfRelayWideRejection(relayUrl, message);
      case NoticeMessage(:final message):
        _dropIfRelayWideRejection(relayUrl, message);
    }
  }

  void _dropIfRelayWideRejection(String relayUrl, String reason) {
    if (isUnsupportedKindRejection(reason)) return;
    if (!isRelayWideRejection(reason)) return;
    if (relayUrl == RelayConfig.appRelay) return;
    if (RelayConfig.defaultRelays.contains(relayUrl)) return;
    if (!_bannedRelays.add(relayUrl)) return;
    debugPrint('[RelayPool] dropping $relayUrl for the session: $reason');
    unawaited(removeRelay(relayUrl));
  }
}

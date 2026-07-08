import 'dart:async';
import 'dart:math';

import '../../core/constants/relays.dart';
import '../../models/nostr_event.dart';
import 'relay_connection.dart';
import 'relay_message.dart';
import 'relay_stats.dart';

/// Tracks seen event ids so duplicate events arriving from multiple relays are
/// only surfaced once. Pure and testable (no sockets).
///
/// Bounded: once [maxIds] is exceeded the oldest ids are evicted (insertion
/// order). Eviction can in theory let a very old id reappear, which is
/// acceptable for a transport-layer dedup cache.
class EventDeduper {
  EventDeduper({this.maxIds = 10000});

  final int maxIds;
  final Set<String> _seen = <String>{};

  /// Returns true if [id] is new (and records it); false if already seen.
  bool add(String id) {
    if (_seen.contains(id)) return false;
    _seen.add(id);
    if (_seen.length > maxIds) {
      // Evict oldest (Set preserves insertion order in Dart).
      final overflow = _seen.length - maxIds;
      final toRemove = _seen.take(overflow).toList();
      _seen.removeAll(toRemove);
    }
    return true;
  }

  bool contains(String id) => _seen.contains(id);
  int get length => _seen.length;
  void clear() => _seen.clear();
}

/// Generates a PWA-style subscription id: a random base36 string, equivalent
/// to JS `Math.random().toString(36).slice(2)`.
String generateSubId([Random? rng]) {
  final r = rng ?? Random();
  // 11 base36 chars ~= 56 bits of entropy, similar magnitude to the JS form.
  const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
  final sb = StringBuffer();
  for (var i = 0; i < 11; i++) {
    sb.write(chars[r.nextInt(36)]);
  }
  return sb.toString();
}

/// Async signature verifier injected into the pool. Defaults to accept-all so
/// this layer does not depend on the crypto module.
typedef EventVerifier = Future<bool> Function(NostrEvent event);

Future<bool> _acceptAll(NostrEvent _) async => true;

/// The common pool surface shared by the direct [RelayPool] and the proxy
/// `RelayPoolProxy`, so [NostrService] can hold either transparently and a
/// [Subscription] can route CLOSE/teardown back through its owner.
abstract interface class PoolTransport {
  /// Tear down [sub] on the transport (sends CLOSE / unsubscribe).
  void closeSubscription(Subscription sub);

  /// Open a new subscription on the transport.
  Subscription subscribe(List<NostrFilter> filters, {String? subId});

  /// Connect every relay / shard socket.
  void connectAll();

  /// Apply the latest geo-relay set so geohash-channel subscriptions reach the
  /// closest geo relays. In proxy mode this re-shards the pool and pushes the
  /// updated RELAYS config + opens geo shard sockets (mirrors
  /// `_poolSendRelayConfigNow` / `connectToGeoRelays`, relays.js:2839); in direct
  /// mode it opens a direct socket per geo url and back-fills active subs
  /// (`connectToGeoRelays` legacy branch). No-op when [geoRelayUrls] is empty.
  void updateGeoRelays(List<String> geoRelayUrls);

  /// Broadcast [event]; returns the number of relays/shards that accepted it.
  Future<int> publish(NostrEvent event);

  /// Publish a DM gift-wrap (kind 1059). In proxy mode this wraps the event in a
  /// `["DM_EVENT",e]` frame so the proxy prioritizes the default relays
  /// (relays.js `sendDMToRelays`); in direct mode it is a plain publish.
  Future<int> publishDm(NostrEvent event);

  /// Publish a geohash channel event (kind 20000 with a `g` tag). In proxy mode,
  /// when [closestRelayUrls] is non-empty this sends a
  /// `["GEO_EVENT",e,[urls]]` frame so the proxy prioritizes the closest geo
  /// relays (relays.js `broadcastEvent`); otherwise it is a plain publish. In
  /// direct mode it is always a plain publish.
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls);

  /// Relays currently reported as connected.
  int get connectedCount;

  /// The set of relay URLs currently reported as connected (proxy: the deduped
  /// per-shard connected sets; direct: the open sockets). Used by the geo-relay
  /// keep-alive to detect a dropped geo relay (`poolConnectedRelays` /
  /// per-relay ws state in the PWA's `startGeoRelayKeepAlive`, relays.js:152/161).
  Set<String> get connectedRelayUrls;

  /// Live relay-traffic counters (bytes in/out, events, throughput history,
  /// per-relay events + latency) for the Network Stats modal. Aggregated across
  /// every relay/shard socket. Mirrors the PWA's `nym.relayStats`.
  RelayStats get stats;

  /// Close every socket and subscription.
  Future<void> disconnectAll();
}

/// An active multi-relay subscription. Emits deduped, optionally-verified
/// [NostrEvent]s; [eose] completes when a quorum of relays signals EOSE (or on
/// timeout). Call [close] to tear down.
class Subscription {
  Subscription._(
    this.subId,
    this._transport,
    this._verify,
    this._relayCount, {
    required double eoseQuorum,
    required Duration eoseTimeout,
  })  : _eoseQuorum = eoseQuorum,
        _eoseTimeout = eoseTimeout;

  /// Transport-agnostic constructor used by both [RelayPool] and the proxy
  /// transport. Exposes the start/event/eose hooks under public names.
  factory Subscription.forTransport(
    String subId,
    PoolTransport transport,
    EventVerifier verify,
    int relayCount, {
    required double eoseQuorum,
    required Duration eoseTimeout,
  }) =>
      Subscription._(
        subId,
        transport,
        verify,
        relayCount,
        eoseQuorum: eoseQuorum,
        eoseTimeout: eoseTimeout,
      );

  final String subId;
  final PoolTransport _transport;
  final EventVerifier _verify;
  final int _relayCount;
  final double _eoseQuorum;
  final Duration _eoseTimeout;

  final EventDeduper _deduper = EventDeduper();
  final StreamController<NostrEvent> _events =
      StreamController<NostrEvent>.broadcast();
  final Completer<void> _eose = Completer<void>();
  final Set<String> _eosedRelays = <String>{};
  Timer? _eoseTimer;
  bool _closed = false;

  /// Deduped (and verified) events for this subscription.
  Stream<NostrEvent> get events => _events.stream;

  /// Completes when enough relays have signaled EOSE, or on timeout.
  Future<void> get eose => _eose.future;

  void _start() => startEose();

  /// Arms the EOSE timeout. Public so the proxy transport can drive it.
  void startEose() {
    _eoseTimer = Timer(_eoseTimeout, _completeEose);
  }

  /// Called by the pool when an EVENT for this sub arrives from [relayUrl].
  ///
  /// [RelayPool] dedupes per-subscription here. The proxy transport dedupes
  /// globally (cross-shard) BEFORE calling this, so its dedup is a no-op
  /// second pass — harmless.
  Future<void> onEvent(String relayUrl, NostrEvent event) async {
    if (_closed) return;
    if (!_deduper.add(event.id)) return;
    final ok = await _verify(event);
    if (_closed) return;
    if (!ok) return;
    if (!_events.isClosed) _events.add(event);
  }

  /// Called by the pool when an EOSE for this sub arrives from [relayUrl].
  void onEose(String relayUrl) {
    if (_closed) return;
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

  /// Close the subscription: sends CLOSE to all relays and releases resources.
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

/// Manages a set of relays in DIRECT WebSocket mode.
///
/// Transport-only: no app state, no UI. Verification is injected so this layer
/// has no dependency on the crypto module.
class RelayPool implements PoolTransport {
  RelayPool({
    required List<String> relays,
    EventVerifier? verify,
    Set<String>? writeOnlyRelays,
    RelayConnection Function(String url)? connectionFactory,
    Random? random,
    this.eoseQuorum = 0.6,
    this.eoseTimeout = const Duration(seconds: 4),
  })  : _verify = verify ?? _acceptAll,
        _writeOnly = writeOnlyRelays ?? RelayConfig.writeOnlyRelays,
        _connectionFactory =
            connectionFactory ?? ((url) => RelayConnection(url)),
        _rng = random ?? Random() {
    for (final url in relays) {
      _addRelayInternal(url);
    }
  }

  final EventVerifier _verify;
  final Set<String> _writeOnly;
  final RelayConnection Function(String url) _connectionFactory;
  final Random _rng;

  /// Fraction of relays that must EOSE before a subscription's [Subscription.eose]
  /// completes (clamped to at least one relay).
  final double eoseQuorum;
  final Duration eoseTimeout;

  final Map<String, RelayConnection> _connections = {};
  final Map<String, StreamSubscription<RelayMessage>> _msgSubs = {};
  final Map<String, StreamSubscription<RelayStatus>> _statusSubs = {};

  /// subId -> active subscription.
  final Map<String, Subscription> _subscriptions = {};

  /// Pool-level throughput history (last 60 per-second event counts). The
  /// per-socket counters live on each [RelayConnection]; this aggregate list is
  /// owned here and fed by [_sampler] (mirrors `startRelayStatsSampling`).
  final List<int> _throughputHistory = [];

  /// 1-second sampler: pushes the last second's aggregate event count onto
  /// [_throughputHistory] (cap 60) and resets each socket's per-second counter.
  Timer? _sampler;

  bool get _isWritable => true; // all relays are writable
  bool _isReadable(String url) => !_writeOnly.contains(url);

  List<String> get relayUrls => _connections.keys.toList();

  /// Number of relays currently in the connected state.
  @override
  int get connectedCount =>
      _connections.values.where((c) => c.isConnected).length;

  /// Per-relay connected status snapshot.
  Map<String, bool> get connectionStatus =>
      {for (final e in _connections.entries) e.key: e.value.isConnected};

  /// The set of currently-connected relay URLs (open sockets).
  @override
  Set<String> get connectedRelayUrls => {
        for (final e in _connections.entries)
          if (e.value.isConnected) e.key,
      };

  /// Aggregate live traffic counters across every relay socket (a fresh
  /// snapshot each read). Sums each [RelayConnection]'s bytes/events and merges
  /// its per-relay event + latency maps, then attaches the pool-owned
  /// throughput history. Mirrors the PWA's single `nym.relayStats`.
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
      // Last-measured REQ→EOSE latency per relay; one socket per url here, so
      // assignment is a straight copy.
      s.latencyPerRelay.forEach((url, ms) {
        agg.latencyPerRelay[url] = ms;
      });
      // Per-relay, per-kind breakdown (one socket per url → straight copy).
      s.kindStatsPerRelay.forEach((url, perKind) {
        agg.kindStatsPerRelay[url] = {
          for (final e in perKind.entries) e.key: e.value.copy(),
        };
      });
    }
    return agg;
  }

  /// Start the 1-second throughput sampler (idempotent). Sums the per-socket
  /// `eventsThisSecond`, pushes it onto [_throughputHistory] (cap 60), then
  /// resets each socket's counter. Mirrors `startRelayStatsSampling`.
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
  }

  /// Add a relay to the pool. If the pool is already connected, the new relay
  /// is connected and back-filled with active read subscriptions.
  void addRelay(String url) {
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

  /// Remove a relay from the pool and close its socket.
  Future<void> removeRelay(String url) async {
    final conn = _connections.remove(url);
    await _msgSubs.remove(url)?.cancel();
    await _statusSubs.remove(url)?.cancel();
    await conn?.close();
  }

  /// Connect every relay in the pool.
  @override
  void connectAll() {
    _startSampler();
    for (final conn in _connections.values) {
      conn.connect();
    }
  }

  /// Direct-mode geo relay delivery: open a direct socket to each geo relay url
  /// not already in the pool, so geohash-channel events reach them. Each newly
  /// added relay is connected and back-filled with the active read subscriptions
  /// (via [addRelay]), mirroring `connectToGeoRelays`'s legacy branch
  /// (relays.js:220) + `ensureGeoRelayDelivery` (the geo relays then carry the
  /// standing kind-20000 sub). No-op for urls already present or blocked.
  @override
  void updateGeoRelays(List<String> geoRelayUrls) {
    for (final url in geoRelayUrls) {
      if (!url.startsWith('wss://')) continue;
      if (_connections.containsKey(url)) continue;
      addRelay(url);
    }
  }

  /// Close every relay socket and all subscriptions.
  @override
  Future<void> disconnectAll() async {
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

  /// Active filters per subId, so newly added relays can be back-filled.
  final Map<String, List<NostrFilter>> _activeFilters = {};

  /// Subscribe across all readable relays. Returns a [Subscription] that
  /// dedupes and (optionally) verifies events and exposes an [Subscription.eose]
  /// future.
  @override
  Subscription subscribe(List<NostrFilter> filters, {String? subId}) {
    final id = subId ?? generateSubId(_rng);
    final readable =
        _connections.keys.where(_isReadable).length;
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

  /// Snapshot of the live subscriptions (subId → its `Subscription` + filters),
  /// so [NostrService] can replay them onto a replacement pool after a swap
  /// (e.g. when the proxy endpoint becomes reachable again and we swap back).
  Map<String, ({Subscription sub, List<NostrFilter> filters})>
      activeSubscriptions() => {
            for (final e in _subscriptions.entries)
              e.key: (
                sub: e.value,
                filters: _activeFilters[e.key] ?? const [],
              ),
          };

  /// Adopt an EXISTING [sub] (created on a previous pool) onto this pool and
  /// re-issue its REQ to every readable relay, so its live `events` stream keeps
  /// flowing after a swap. The sub's internal dedup suppresses any events it
  /// already delivered (seamless, no duplicates). Newly added relays back-fill
  /// it via [addRelay]/[_subscriptions].
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

  /// Tear down every relay socket WITHOUT closing the active [Subscription]
  /// objects, so they can be re-driven on another pool (the direct↔proxy swap).
  /// Mirrors [RelayPoolProxy.disconnectSocketsOnly].
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

  /// Broadcast [event] to all writable relays. Returns the number of relays
  /// that accepted it (OK with accepted=true).
  @override
  Future<int> publish(NostrEvent event) async {
    final futures = <Future<OkMessage>>[];
    for (final entry in _connections.entries) {
      // _isWritable is always true; write-only relays still receive EVENTs.
      if (_isWritable) {
        futures.add(entry.value.publish(event));
      }
    }
    if (futures.isEmpty) return 0;
    final results = await Future.wait(futures);
    return results.where((r) => r.accepted).length;
  }

  /// Direct mode has no proxy frames: DM gift-wraps publish as plain EVENTs.
  @override
  Future<int> publishDm(NostrEvent event) => publish(event);

  /// Direct mode has no proxy frames: geo channel events publish as plain
  /// EVENTs (the direct path reaches the geo relays via the live sockets;
  /// relays.js `ensureGeoRelayDelivery` legacy branch).
  @override
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls) =>
      publish(event);

  void _onRelayMessage(String relayUrl, RelayMessage msg) {
    switch (msg) {
      case EventMessage(:final subId, :final event):
        final sub = _subscriptions[subId];
        if (sub != null) {
          // Fire and forget; verification is async.
          unawaited(sub.onEvent(relayUrl, event));
        }
      case EoseMessage(:final subId):
        _subscriptions[subId]?.onEose(relayUrl);
      case ClosedMessage(:final subId):
        // Treat a relay-side CLOSED as that relay reaching EOSE for quorum
        // purposes so a closed sub doesn't stall the eose future.
        _subscriptions[subId]?.onEose(relayUrl);
      case OkMessage():
        // Handled per-connection via publish() futures.
        break;
      case NoticeMessage():
        break;
    }
  }
}

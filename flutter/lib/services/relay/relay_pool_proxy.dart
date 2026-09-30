import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/constants/relays.dart';
import '../../features/messages/spam_filter.dart';
import '../nostr/event_provenance.dart';
import '../../models/nostr_event.dart';
import '../api/api_config.dart';
import 'relay_connection.dart'
    show WebSocketChannelFactory, defaultRelayChannelFactory;
import 'relay_message.dart';
import 'relay_pool.dart';
import 'relay_stats.dart';

/// One role-keyed shard: stable id, relay set and (for critical) DM relays, as `_shardRelaysByRole`.
class RelayShard {
  RelayShard({
    required this.id,
    required this.role,
    required this.relays,
    required this.dmRelays,
  });

  final String id;
  final String role; // 'critical' | 'geo' | 'discovered'
  final List<String> relays;
  final List<String> dmRelays;
}

/// Relays the PWA hard-blocks from any shard.
const Set<String> _blockedRelays = {
  'wss://relay.nosflare.com',
  'wss://relay.nostraddress.com',
  'wss://nostr-server-production.up.railway.app',
};

/// Canonical url for discovered-bucket dedup: lowercase host, no trailing slash.
String canonicalRelayUrl(String url) {
  var u = url.trim();
  if (u.endsWith('/')) u = u.substring(0, u.length - 1);
  return u.toLowerCase();
}

/// Port of `_shardRelaysByRole`: `app-0`, `critical-N`, `geo-N`, `discovered-N`, chunked at [chunkSize].
List<RelayShard> shardRelaysByRole(
  Iterable<String> allRelays,
  Iterable<String> geoRelayUrls,
  List<String> dmRelays, {
  List<String> defaultRelays = RelayConfig.defaultRelays,
  String appRelay = RelayConfig.appRelay,
  Set<String> permanentBlacklist = const {},
  int chunkSize = RelayConfig.relaysPerWorker,
}) {
  bool isValid(String url) =>
      url.startsWith('wss://') &&
      !_blockedRelays.contains(url) &&
      !permanentBlacklist.contains(url);

  final geoSet = <String>{
    for (final u in geoRelayUrls)
      if (isValid(u)) u
  };
  final appValid = isValid(appRelay);

  // Critical = default relays plus DM relays, excluding the app relay.
  final critical = <String>[
    for (final u in {...defaultRelays, ...dmRelays})
      if (isValid(u) && u != appRelay) u
  ];

  final reservedSet = <String>{...critical};
  if (appValid) reservedSet.add(appRelay);

  // Geo = CSV relays not already reserved.
  final geo = <String>[
    for (final u in geoSet)
      if (!reservedSet.contains(u)) u
  ];

  // Discovered = remaining relays, canonically deduped.
  final geoForDiscovered = <String>{...geo};
  final claimedCanon = <String>{
    for (final u in reservedSet) canonicalRelayUrl(u),
    for (final u in geoForDiscovered) canonicalRelayUrl(u),
  };
  final seenDiscoveredCanon = <String>{};
  final discovered = <String>[];
  for (final url in {...allRelays}) {
    if (!isValid(url) ||
        reservedSet.contains(url) ||
        geoForDiscovered.contains(url)) {
      continue;
    }
    final canon = canonicalRelayUrl(url);
    if (claimedCanon.contains(canon) || seenDiscoveredCanon.contains(canon)) {
      continue;
    }
    seenDiscoveredCanon.add(canon);
    discovered.add(url);
  }

  List<List<String>> chunk(List<String> arr) {
    final out = <List<String>>[];
    for (var i = 0; i < arr.length; i += chunkSize) {
      out.add(arr.sublist(i, min(i + chunkSize, arr.length)));
    }
    return out;
  }

  final shards = <RelayShard>[];

  if (appValid) {
    shards.add(RelayShard(
        id: 'app-0',
        role: 'critical',
        relays: [appRelay],
        dmRelays: [appRelay]));
  }

  final criticalDmRelays = <String>[
    for (final u in dmRelays)
      if (isValid(u) && u != appRelay) u
  ];
  final criticalChunks = chunk(critical);
  for (var i = 0; i < criticalChunks.length; i++) {
    shards.add(RelayShard(
      id: 'critical-$i',
      role: 'critical',
      relays: criticalChunks[i],
      dmRelays: i == 0 ? criticalDmRelays : const [],
    ));
  }

  final geoChunks = chunk(geo);
  for (var i = 0; i < geoChunks.length; i++) {
    shards.add(RelayShard(
        id: 'geo-$i', role: 'geo', relays: geoChunks[i], dmRelays: const []));
  }

  final discoveredChunks = chunk(discovered);
  for (var i = 0; i < discoveredChunks.length; i++) {
    shards.add(RelayShard(
        id: 'discovered-$i',
        role: 'discovered',
        relays: discoveredChunks[i],
        dmRelays: const []));
  }

  if (shards.isEmpty) {
    shards.add(RelayShard(
        id: 'critical-0',
        role: 'critical',
        relays: const [],
        dmRelays: const []));
  }
  return shards;
}

/// Wrapped outbound frames for the `/api/relay-pool` socket.
class PoolFrame {
  PoolFrame._();

  /// `["RELAYS",{relays,dmRelays}]`
  static String relays(List<String> relays, List<String> dmRelays) =>
      jsonEncode(<dynamic>[
        'RELAYS',
        {'relays': relays, 'dmRelays': dmRelays}
      ]);

  /// `["EVENT",e]`
  static String event(NostrEvent e) =>
      jsonEncode(<dynamic>['EVENT', e.toJson()]);

  /// `["GEO_EVENT",e,[urls]]`
  static String geoEvent(NostrEvent e, List<String> urls) =>
      jsonEncode(<dynamic>['GEO_EVENT', e.toJson(), urls]);

  /// `["DM_EVENT",e]`
  static String dmEvent(NostrEvent e) =>
      jsonEncode(<dynamic>['DM_EVENT', e.toJson()]);

  /// `["REQ",subId,...filters]`
  static String req(String subId, List<NostrFilter> filters) =>
      jsonEncode(<dynamic>['REQ', subId, ...filters.map((f) => f.toJson())]);

  /// `["CLOSE",subId]`
  static String close(String subId) => jsonEncode(<dynamic>['CLOSE', subId]);

  /// `["KIND_BLACKLIST",{url:[kinds]}]` so the worker skips a relay for kinds it rejected.
  static String kindBlacklist(Map<String, Set<int>> config) =>
      jsonEncode(<dynamic>[
        'KIND_BLACKLIST',
        {for (final e in config.entries) e.key: e.value.toList()},
      ]);
}

/// Inbound wrapped pool frame; EVENT carries subId first, and OK/EOSE may carry a trailing relay url.
sealed class PoolMessage {
  const PoolMessage();

  static PoolMessage? parse(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! List || decoded.isEmpty) return null;
    return fromList(decoded);
  }

  static PoolMessage? fromList(List<dynamic> arr) {
    if (arr.isEmpty || arr[0] is! String) return null;
    final type = arr[0] as String;
    switch (type) {
      case 'EVENT':
        // ["EVENT", subId, event, sourceRelay?]
        if (arr.length < 3) return null;
        final subId = arr[1]?.toString() ?? '';
        final ev = arr[2];
        if (ev is! Map) return null;
        final sourceRelay = arr.length > 3 ? arr[3]?.toString() : null;
        return PoolEvent(
          subId,
          NostrEvent.fromJson(Map<String, dynamic>.from(ev)),
          sourceRelay,
        );
      case 'OK':
        // ["OK", id, accepted, reason, relayUrl?], the url being the proxy's attribution.
        if (arr.length < 3) return null;
        return PoolOk(
          arr[1]?.toString() ?? '',
          arr[2] == true,
          arr.length > 3 ? (arr[3]?.toString() ?? '') : '',
          arr.length > 4 ? arr[4]?.toString() : null,
        );
      case 'EOSE':
        // ["EOSE", subId]
        if (arr.length < 2) return null;
        return PoolEose(arr[1]?.toString() ?? '');
      case 'CLOSED':
        // ["CLOSED", subId, reason, relayUrl?]
        if (arr.length < 2) return null;
        return PoolClosed(
          arr[1]?.toString() ?? '',
          arr.length > 2 ? (arr[2]?.toString() ?? '') : '',
          arr.length > 3 ? arr[3]?.toString() : null,
        );
      case 'NOTICE':
        return PoolNotice(
          arr.length > 1 ? (arr[1]?.toString() ?? '') : '',
          arr.length > 2 ? arr[2]?.toString() : null,
        );
      case 'POOL:PING':
        // ["POOL:PING", ts]: keepalive; ts is ignored.
        return const PoolPing();
      case 'POOL:STATUS':
        // ["POOL:STATUS", {connected:[urls], latency:{url:ms}}]
        final status = arr.length > 1 && arr[1] is Map
            ? Map<String, dynamic>.from(arr[1] as Map)
            : const <String, dynamic>{};
        final connected = (status['connected'] is List)
            ? (status['connected'] as List).map((e) => e.toString()).toList()
            : const <String>[];
        // Per-relay latency from this worker, for the Network Stats rows in proxy mode.
        final latency = <String, int>{};
        final rawLat = status['latency'];
        if (rawLat is Map) {
          rawLat.forEach((k, v) {
            final ms = v is num ? v.round() : int.tryParse('$v');
            if (ms != null) latency[k.toString()] = ms;
          });
        }
        return PoolStatus(connected, latency);
      case 'POOL:RETRACT':
        final retractId = arr.length > 1 ? arr[1]?.toString() ?? '' : '';
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(retractId)) return null;
        return PoolRetract(retractId, arr.length > 2 ? arr[2]?.toString() : null);
      case 'POOL:RELAY_BAN':
        // ["POOL:RELAY_BAN", relayUrl, reason?]: the proxy permanently dropped this relay.
        final url = arr.length > 1 ? arr[1]?.toString() ?? '' : '';
        if (!url.startsWith('wss://')) return null;
        final reason =
            arr.length > 2 ? arr[2]?.toString() ?? 'banned' : 'banned';
        return PoolRelayBan(url, reason);
      default:
        // POOL:SHARDS / NOTICE / AUTH are unhandled here.
        return null;
    }
  }
}

class PoolEvent extends PoolMessage {
  const PoolEvent(this.subId, this.event, this.sourceRelay);
  final String subId;
  final NostrEvent event;
  final String? sourceRelay;
}

class PoolOk extends PoolMessage {
  const PoolOk(this.id, this.accepted, this.message, [this.relayUrl]);
  final String id;
  final bool accepted;
  final String message;

  /// The proxy's per-relay attribution (`wss://…`), when present.
  final String? relayUrl;
}

class PoolEose extends PoolMessage {
  const PoolEose(this.subId);
  final String subId;
}

class PoolClosed extends PoolMessage {
  const PoolClosed(this.subId, [this.reason = '', this.relayUrl]);
  final String subId;
  final String reason;

  /// The proxy's per-relay attribution (`wss://…`), when present.
  final String? relayUrl;
}

class PoolNotice extends PoolMessage {
  const PoolNotice(this.reason, [this.relayUrl]);
  final String reason;
  final String? relayUrl;
}

class PoolPing extends PoolMessage {
  const PoolPing();
}

class PoolStatus extends PoolMessage {
  const PoolStatus(this.connected, [this.latency = const {}]);
  final List<String> connected;

  /// Per-relay latency in ms from POOL:STATUS.
  final Map<String, int> latency;
}

class PoolRelayBan extends PoolMessage {
  const PoolRelayBan(this.url, this.reason);
  final String url;
  final String reason;
}

class PoolRetract extends PoolMessage {
  const PoolRetract(this.eventId, this.reason);
  final String eventId;
  final String? reason;
}

/// One shard's `/api/relay-pool` socket; reconnect backoff min(3000*1.7^n, 60000) with 0.7–1.0 jitter.
class _ShardSocket {
  _ShardSocket({
    required this.shard,
    required this.url,
    required this.channelFactory,
    required this.rng,
    required this.stats,
    required this.onMessage,
    required this.onConnected,
    required this.onClosed,
    this.confirmTimeout = const Duration(seconds: 12),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  RelayShard shard;
  final DateTime Function() _now;
  final String url;
  final WebSocketChannelFactory channelFactory;
  final Random rng;
  final Duration confirmTimeout;

  /// Shared pool counters this shard adds its frame byte lengths to.
  final RelayStats stats;
  final void Function(_ShardSocket sock, PoolMessage msg) onMessage;
  final void Function(_ShardSocket sock) onConnected;
  final void Function(_ShardSocket sock) onClosed;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  Timer? _confirmTimer;
  int _reconnectAttempt = 0;
  bool _closedByUser = false;
  bool _open = false;
  bool _settled = true;
  bool _frameSinceConnect = false;

  int failuresSinceFrame = 0;
  DateTime? failureStreakStartedAt;

  bool get hasFrameSinceConnect => _frameSinceConnect;

  /// Closes before the pool ever confirmed; drives the host-unreachable fallback. Reset on confirm.
  int failuresBeforeConfirm = 0;

  /// True once a confirming inbound frame arrived, i.e. the proxy is reachable.
  bool confirmed = false;

  /// Relays this shard's proxy reports as connected (from POOL:STATUS).
  List<String> connectedRelays = const [];

  bool get isOpen => _open;

  void connect() {
    _closedByUser = false;
    if (_open) return;
    _open = false;
    _settled = false;
    _frameSinceConnect = false;
    try {
      final ch = channelFactory(Uri.parse(url));
      _channel = ch;
      _sub = ch.stream.listen(
        _onData,
        onError: (Object _) => _onDone(),
        onDone: _onDone,
        cancelOnError: false,
      );
      // Treat listen as open and push RELAYS; backoff resets only on a real inbound frame.
      _open = true;
      _armConfirmTimer();
      send(PoolFrame.relays(shard.relays, shard.dmRelays));
      onConnected(this);
    } catch (e) {
      debugPrint('[RelayPoolProxy] Failed to open shard socket ($url): $e');
      _onDone();
    }
  }

  void _armConfirmTimer() {
    _confirmTimer?.cancel();
    _confirmTimer = Timer(confirmTimeout, () {
      _confirmTimer = null;
      if (_closedByUser || !_open || _frameSinceConnect) return;
      _sub?.cancel();
      _sub = null;
      try {
        _channel?.sink.close();
      } catch (_) {}
      _onDone();
    });
  }

  void _onData(dynamic data) {
    // Count inbound UTF-8 byte length, as the PWA's relayStats does.
    if (data is String) {
      stats.bytesReceived += utf8.encode(data).length;
    } else if (data is List<int>) {
      stats.bytesReceived += data.length;
    }
    if (data is! String) return;
    final msg = PoolMessage.parse(data);
    if (msg == null) return;
    // A real inbound frame proves the connection, so reset the backoff.
    _reconnectAttempt = 0;
    _frameSinceConnect = true;
    failuresSinceFrame = 0;
    failureStreakStartedAt = null;
    _confirmTimer?.cancel();
    _confirmTimer = null;
    // A parseable frame confirms the proxy, so later blips are normal reconnects, not a fallback.
    if (!confirmed) {
      confirmed = true;
      failuresBeforeConfirm = 0;
    }
    if (msg is PoolStatus) connectedRelays = msg.connected;
    onMessage(this, msg);
  }

  void _onDone() {
    if (_settled) return;
    _settled = true;
    _open = false;
    // A close before confirming is an outright connect failure; count the streak.
    if (!confirmed) failuresBeforeConfirm++;
    if (!_frameSinceConnect) {
      if (failuresSinceFrame == 0) failureStreakStartedAt = _now();
      failuresSinceFrame++;
    }
    connectedRelays = const [];
    _cleanup();
    onClosed(this);
    if (_closedByUser) return;
    _scheduleReconnect();
  }

  void _cleanup() {
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _sub?.cancel();
    _sub = null;
    _channel = null;
  }

  void _scheduleReconnect() {
    if (_closedByUser) return;
    _reconnectTimer?.cancel();
    // base = min(3000*1.7^n, 60000); jitter 0.7–1.0.
    final base = min(3000 * pow(1.7, _reconnectAttempt), 60000).toDouble();
    final delayMs = (base * (0.7 + rng.nextDouble() * 0.3)).floor();
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_closedByUser) return;
      connect();
    });
  }

  bool send(String frame) {
    final ch = _channel;
    if (ch == null || !_open) return false;
    try {
      ch.sink.add(frame);
      stats.bytesSent += utf8.encode(frame).length;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> close() async {
    _closedByUser = true;
    _open = false;
    _settled = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _confirmTimer?.cancel();
    _confirmTimer = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }
}

/// Relay-pool proxy transport: [RelayPool]'s surface over `wss://<host>/api/relay-pool`, one socket per shard.
class RelayPoolProxy implements PoolTransport {
  RelayPoolProxy({
    required List<String> relays,
    EventVerifier? verify,
    List<String>? geoRelayUrls,
    List<String>? dmRelays,
    Set<String>? permanentBlacklist,
    String? poolUrl,
    WebSocketChannelFactory? channelFactory,
    Random? random,
    this.onProxyUnreachable,
    this.onProxyConnected,
    this.maxPreConnectFailures = 2,
    this.confirmTimeout = const Duration(seconds: 12),
    this.postConfirmGrace = const Duration(seconds: 30),
    DateTime Function()? now,
    this.eoseQuorum = 0.6,
    this.eoseTimeout = const Duration(seconds: 4),
  })  : _verify = verify ?? ((_) async => true),
        _now = now ?? DateTime.now,
        _allRelays = {...relays},
        _geoRelayUrls = [...?geoRelayUrls],
        _dmRelays = dmRelays ?? RelayConfig.defaultRelays,
        _permanentBlacklist = {...?permanentBlacklist},
        _poolUrl = poolUrl ?? ApiConfig.relayPoolUrl(),
        _channelFactory = channelFactory ?? defaultRelayChannelFactory,
        _rng = random ?? Random();

  final EventVerifier _verify;
  final Set<String> _allRelays;
  final List<String> _geoRelayUrls;
  final List<String> _dmRelays;
  final Set<String> _permanentBlacklist;
  final String _poolUrl;
  final WebSocketChannelFactory _channelFactory;
  final Random _rng;

  final double eoseQuorum;
  final Duration eoseTimeout;

  /// Fires once after [maxPreConnectFailures] pre-confirm shard failures, so [NostrService] can swap to direct.
  void Function()? onProxyUnreachable;

  /// Fires once when a shard first confirms the proxy, for background-restore promotion.
  void Function()? onProxyConnected;

  void Function(String eventId)? onEventRetracted;

  /// Pre-confirm failures that trip [onProxyUnreachable] (PWA threshold: 2).
  final int maxPreConnectFailures;

  final Duration confirmTimeout;

  final Duration postConfirmGrace;

  final DateTime Function() _now;

  /// Latches once any shard confirms; pre-connect failure counting then stops.
  bool _proxyEverConnected = false;

  bool _unreachableFired = false;

  /// True after [disconnectAll], so a late shard callback can't fire the trigger.
  bool _disposed = false;

  final List<_ShardSocket> _sockets = [];

  /// Active subscriptions and filters by subId, re-REQ'd on a reconnected shard.
  final Map<String, Subscription> _subscriptions = {};
  final Map<String, List<NostrFilter>> _activeFilters = {};

  /// Global cross-shard event dedup (PWA cap 10k).
  final EventDeduper _deduper = EventDeduper(maxIds: 10000);

  /// Pool-owned traffic counters: bytes from shard sockets, events and latency from [_onShardMessage].
  final RelayStats _stats = RelayStats();

  /// 1s throughput sampler (history cap 60).
  Timer? _sampler;

  /// subId to REQ send time; latency is keyed by shard id and cleared once every open shard EOSEs.
  final Map<String, int> _reqSentAt = {};

  /// subId to shards that already EOSE'd, so each shard is stamped once.
  final Map<String, Set<String>> _eosedShards = {};

  /// Relay url to kinds it rejected, pushed to workers as `KIND_BLACKLIST`.
  final Map<String, Set<int>> _relayUnsupportedKinds = {};

  /// Recent event id to kind (cap 1000), mapping OK rejections back to a kind.
  final Map<String, int> _sentEventKinds = {};

  /// subId to requested kinds (cap 2000), for CLOSED rejections without an explicit kind.
  final Map<String, Set<int>> _subKinds = {};

  /// Relays reported connected across all shards, deduped.
  @override
  int get connectedCount {
    final s = <String>{};
    for (final sock in _sockets) {
      s.addAll(sock.connectedRelays);
    }
    return s.length;
  }

  /// Deduped relay URLs reported connected across all shards.
  @override
  Set<String> get connectedRelayUrls {
    final s = <String>{};
    for (final sock in _sockets) {
      s.addAll(sock.connectedRelays);
    }
    return s;
  }

  int get openShardCount => _sockets.where((s) => s.isOpen).length;

  /// Fresh aggregate counters; shard info is rebuilt from live sockets since the backend sends no `POOL:SHARDS`.
  @override
  RelayStats get stats {
    _stats.shardInfo
      ..clear()
      ..addAll([
        for (final sock in _sockets)
          ShardInfo(
            id: sock.shard.id,
            status: sock.isOpen ? 'connected' : 'connecting',
            connected: sock.connectedRelays.length,
            total: sock.shard.relays.length,
          ),
      ]);
    return _stats.snapshot();
  }

  /// Starts the 1s throughput sampler (idempotent).
  void _startSampler() {
    if (_sampler != null) return;
    _sampler = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _stats.sampleThroughput(),
    );
  }

  void _stopSampler() {
    _sampler?.cancel();
    _sampler = null;
  }

  List<RelayShard> get shards => _sockets.map((s) => s.shard).toList();

  @override
  void connectAll() {
    _startSampler();
    if (_sockets.isNotEmpty) {
      for (final s in _sockets) {
        s.connect();
      }
      return;
    }
    final layout = shardRelaysByRole(
      _allRelays,
      _geoRelayUrls,
      _dmRelays,
      permanentBlacklist: _permanentBlacklist,
    );
    for (final shard in layout) {
      final sock = _ShardSocket(
        shard: shard,
        url: _poolUrl,
        channelFactory: _channelFactory,
        rng: _rng,
        stats: _stats,
        onMessage: _onShardMessage,
        onConnected: _onShardConnected,
        onClosed: _onShardClosed,
        confirmTimeout: confirmTimeout,
        now: _now,
      );
      _sockets.add(sock);
      sock.connect();
    }
  }

  /// Sends one REQ to every open shard socket.
  @override
  Subscription subscribe(List<NostrFilter> filters, {String? subId}) {
    final id = subId ?? generateSubId(_rng);
    final sub = Subscription.forTransport(
      id,
      this,
      _verify,
      max(1, openShardCount),
      eoseQuorum: eoseQuorum,
      eoseTimeout: eoseTimeout,
      onRejected: (event) => _deduper.forget(copyKey(event)),
    );
    _subscriptions[id] = sub;
    _activeFilters[id] = filters;
    // Stamp REQ send time for per-shard REQ→EOSE latency.
    _reqSentAt[id] = DateTime.now().millisecondsSinceEpoch;
    _eosedShards[id] = <String>{};
    _trackSubKinds(id, filters);
    sub.startEose();
    final frame = PoolFrame.req(id, filters);
    for (final sock in _sockets) {
      sock.send(frame);
    }
    return sub;
  }

  @override
  void closeSubscription(Subscription sub) {
    _subscriptions.remove(sub.subId);
    _activeFilters.remove(sub.subId);
    _reqSentAt.remove(sub.subId);
    _eosedShards.remove(sub.subId);
    final frame = PoolFrame.close(sub.subId);
    for (final sock in _sockets) {
      sock.send(frame);
    }
  }

  /// Broadcasts `["EVENT",e]` to every shard; returns sockets written, since OKs arrive async.
  @override
  Future<int> publish(NostrEvent event) async {
    // Remember the kind so an attributed OK rejection can blacklist it.
    _trackSentEventKind(event);
    return _broadcast(PoolFrame.event(event));
  }

  /// Publishes a DM gift wrap via `["DM_EVENT",e]`.
  @override
  Future<int> publishDm(NostrEvent event) async {
    return _broadcast(PoolFrame.dmEvent(event));
  }

  /// `["GEO_EVENT",e,[urls]]` prioritizing the closest geo relays; plain EVENT when none are known.
  @override
  Future<int> publishGeo(
      NostrEvent event, List<String> closestRelayUrls) async {
    if (closestRelayUrls.isEmpty) {
      return _broadcast(PoolFrame.event(event));
    }
    return _broadcast(PoolFrame.geoEvent(event, closestRelayUrls));
  }

  int _broadcast(String frame) {
    var n = 0;
    for (final sock in _sockets) {
      if (sock.send(frame)) n++;
    }
    return n;
  }

  @override
  Future<void> disconnectAll() async {
    _disposed = true;
    _stopSampler();
    final subs = _subscriptions.values.toList();
    for (final s in subs) {
      await s.close();
    }
    final socks = _sockets.toList();
    _sockets.clear();
    for (final s in socks) {
      await s.close();
    }
  }

  /// Closes shard sockets but keeps [Subscription]s alive for the proxy/direct swap.
  Future<void> disconnectSocketsOnly() async {
    _disposed = true;
    _stopSampler();
    _subscriptions.clear();
    _activeFilters.clear();
    _reqSentAt.clear();
    _eosedShards.clear();
    final socks = _sockets.toList();
    _sockets.clear();
    for (final s in socks) {
      await s.close();
    }
  }

  /// Live subscriptions and filters, for replay onto a replacement pool.
  Map<String, ({Subscription sub, List<NostrFilter> filters})>
      activeSubscriptions() => {
            for (final e in _subscriptions.entries)
              e.key: (
                sub: e.value,
                filters: _activeFilters[e.key] ?? const [],
              ),
          };

  /// Adopts [sub] from a previous pool and re-broadcasts its REQ; its dedup suppresses repeats.
  void replaySubscription(Subscription sub, List<NostrFilter> filters) {
    final id = sub.subId;
    _subscriptions[id] = sub;
    _activeFilters[id] = filters;
    _reqSentAt[id] = DateTime.now().millisecondsSinceEpoch;
    _eosedShards[id] = <String>{};
    _trackSubKinds(id, filters);
    final frame = PoolFrame.req(id, filters);
    for (final sock in _sockets) {
      sock.send(frame);
    }
  }

  /// Re-shards for new [geoRelayUrls]: update, close or open sockets; no-op before [connectAll] or when unchanged.
  @override
  void updateGeoRelays(List<String> geoRelayUrls) {
    final next = [...geoRelayUrls];
    if (_geoRelayUrls.length == next.length &&
        next.toSet().containsAll(_geoRelayUrls)) {
      return;
    }
    _geoRelayUrls
      ..clear()
      ..addAll(next);
    _reconcileShards();
  }

  void _reconcileShards() {
    if (_sockets.isEmpty) return; // connectAll() will shard with these urls.

    final layout = shardRelaysByRole(
      _allRelays,
      _geoRelayUrls,
      _dmRelays,
      permanentBlacklist: _permanentBlacklist,
    );
    final byId = {for (final s in layout) s.id: s};

    bool sameRelays(List<String> a, List<String> b) {
      if (a.length != b.length) return false;
      final setA = a.toSet();
      for (final v in b) {
        if (!setA.contains(v)) return false;
      }
      return true;
    }

    final survivors = <_ShardSocket>[];
    for (final sock in _sockets) {
      final shard = byId[sock.shard.id];
      if (shard == null) {
        unawaited(sock.close());
        continue;
      }
      survivors.add(sock);
      if (!sameRelays(sock.shard.relays, shard.relays) ||
          !sameRelays(sock.shard.dmRelays, shard.dmRelays)) {
        sock.shard = shard;
        if (sock.isOpen) {
          sock.send(PoolFrame.relays(shard.relays, shard.dmRelays));
        }
      }
    }
    _sockets
      ..clear()
      ..addAll(survivors);

    final haveIds = {for (final s in _sockets) s.shard.id};
    for (final shard in layout) {
      if (haveIds.contains(shard.id)) continue;
      final sock = _ShardSocket(
        shard: shard,
        url: _poolUrl,
        channelFactory: _channelFactory,
        rng: _rng,
        stats: _stats,
        onMessage: _onShardMessage,
        onConnected: _onShardConnected,
        onClosed: _onShardClosed,
      );
      _sockets.add(sock);
      sock.connect();
    }
  }

  List<String> get geoRelayUrls => List.unmodifiable(_geoRelayUrls);

  /// Remembers a REQ's kinds so a later CLOSED rejection can blacklist them.
  void _trackSubKinds(String subId, List<NostrFilter> filters) {
    final kinds = <int>{};
    for (final f in filters) {
      final k = f.kinds;
      if (k != null) kinds.addAll(k);
    }
    if (kinds.isEmpty) return;
    _subKinds.remove(subId);
    _subKinds[subId] = kinds;
    if (_subKinds.length > 2000) {
      _subKinds.remove(_subKinds.keys.first);
    }
  }

  /// Remembers a published event's kind for mapping OK rejections.
  void _trackSentEventKind(NostrEvent event) {
    if (event.id.isEmpty) return;
    _sentEventKinds.remove(event.id);
    _sentEventKinds[event.id] = event.kind;
    if (_sentEventKinds.length > 1000) {
      _sentEventKinds.remove(_sentEventKinds.keys.first);
    }
  }

  /// True when [reason] says the relay doesn't support the kind.
  static bool _isUnsupportedKind(String reason) =>
      isUnsupportedKindRejection(reason);

  void _banRelay(String? url, String reason) {
    if (url == null || !url.startsWith('wss://')) return;
    if (url == RelayConfig.appRelay) return;
    if (RelayConfig.defaultRelays.contains(url) || _dmRelays.contains(url)) {
      return;
    }
    if (!_permanentBlacklist.add(url)) return;
    debugPrint('[RelayPoolProxy] dropping $url for the session: $reason');
    _reconcileShards();
  }

  /// The explicit kind number in [reason], if any.
  static int? _extractUnsupportedKind(String reason) {
    var m = RegExp(r'\bNIP[\s\-_:]*(\d+)\b', caseSensitive: false)
        .firstMatch(reason);
    if (m != null) return int.tryParse(m.group(1)!);
    m = RegExp(r'\bkinds?[\s\-_:]*(\d+)\b', caseSensitive: false)
        .firstMatch(reason);
    if (m != null) return int.tryParse(m.group(1)!);
    return null;
  }

  /// Blacklists the reason's kind for [relayUrl], else every kind the REQ asked for.
  void _recordUnsupportedKindRejection(
      String? relayUrl, String subId, String reason) {
    if (relayUrl == null || !relayUrl.startsWith('wss://')) return;
    final specific = _extractUnsupportedKind(reason);
    final kinds = specific != null ? {specific} : _subKinds[subId];
    if (kinds == null || kinds.isEmpty) return;
    final set = _relayUnsupportedKinds.putIfAbsent(relayUrl, () => <int>{});
    var added = false;
    for (final k in kinds) {
      if (set.add(k)) added = true;
    }
    if (added) _sendKindBlacklistToWorkers();
  }

  /// Blacklists the published event's remembered kind for [relayUrl].
  void _recordEventKindRejection(String? relayUrl, String eventId) {
    if (relayUrl == null || !relayUrl.startsWith('wss://')) return;
    if (eventId.isEmpty) return;
    final kind = _sentEventKinds[eventId];
    if (kind == null) return;
    final set = _relayUnsupportedKinds.putIfAbsent(relayUrl, () => <int>{});
    if (set.add(kind)) _sendKindBlacklistToWorkers();
  }

  /// Pushes the current blacklist to every open shard socket.
  void _sendKindBlacklistToWorkers() {
    if (_relayUnsupportedKinds.isEmpty) return;
    final frame = PoolFrame.kindBlacklist(_relayUnsupportedKinds);
    for (final sock in _sockets) {
      sock.send(frame);
    }
  }

  void _onShardConnected(_ShardSocket sock) {
    // Push the kind blacklist after RELAYS and before any REQ.
    if (_relayUnsupportedKinds.isNotEmpty) {
      sock.send(PoolFrame.kindBlacklist(_relayUnsupportedKinds));
    }
    // Re-issue every active subscription on the (re)connected shard.
    for (final entry in _activeFilters.entries) {
      sock.send(PoolFrame.req(entry.key, entry.value));
    }
  }

  void _onShardClosed(_ShardSocket sock) {
    // Only detect host-unreachable here: repeated closes before the pool ever confirmed.
    if (_unreachableFired || _disposed) return;
    final streak = _proxyEverConnected
        ? sock.failuresSinceFrame
        : sock.failuresBeforeConfirm;
    if (streak < maxPreConnectFailures) return;
    if (_proxyEverConnected) {
      final since = sock.failureStreakStartedAt;
      if (since == null || _now().difference(since) < postConfirmGrace) return;
    }
    if (_sockets.any((s) => s.isOpen && s.hasFrameSinceConnect)) return;
    _unreachableFired = true;
    final cb = onProxyUnreachable;
    if (cb != null) {
      debugPrint('[RelayPoolProxy] proxy unreachable after '
          '$streak consecutive failures on ${sock.shard.id}; '
          'falling back to direct relays');
      cb();
    }
  }

  /// Records REQ→EOSE latency once per shard, dropping the timing once every open shard has EOSE'd.
  void _stampShardLatency(String subId, String shardId) {
    final sentAt = _reqSentAt[subId];
    if (sentAt == null) return;
    final eosed = _eosedShards[subId] ??= <String>{};
    if (!eosed.add(shardId)) return; // Already stamped this shard.
    final ms = DateTime.now().millisecondsSinceEpoch - sentAt;
    if (ms >= 0) _stats.latencyPerRelay[shardId] = ms;
    if (eosed.length >= openShardCount) {
      _reqSentAt.remove(subId);
      _eosedShards.remove(subId);
    }
  }

  /// Maps worker split-child ids (`<parent>~c<n>`, for REQs over 10 filters) to the parent, or events are dropped.
  static String _parentSubId(String subId) {
    final i = subId.indexOf('~c');
    return i > 0 ? subId.substring(0, i) : subId;
  }

  bool Function(NostrEvent event, String? relayUrl)? _geoOriginAllows;
  @override
  set geoOriginAllows(bool Function(NostrEvent event, String? relayUrl)? fn) =>
      _geoOriginAllows = fn;

  void _onShardMessage(_ShardSocket sock, PoolMessage msg) {
    // A parseable frame means the proxy is reachable: latch it and fire the one-shot connected signal.
    if (!_proxyEverConnected) {
      _proxyEverConnected = true;
      final cb = onProxyConnected;
      if (cb != null && !_disposed) cb();
    }
    switch (msg) {
      case PoolEvent(:final subId, :final event, :final sourceRelay):
        // Dropped before verification: glub.chat tags every event it sends.
        if (SpamFilter.isGlubClient(event.tags)) return;
        if (RelayConfig.isAppRelayOnly(
                event.kind, event.tagValue('g'), event.tagValue('d')) &&
            sourceRelay != RelayConfig.appRelay) {
          return;
        }
        // Gate before the cross-shard dedup, for the same reason.
        final geoGate = _geoOriginAllows;
        if (geoGate != null && !geoGate(event, sourceRelay)) return;
        // Record before dedup, since the discarded copies are the relay list.
        eventProvenance.record(event, sourceRelay);
        // Cross-shard dedup: the first shard to deliver an id wins.
        if (!_deduper.add(copyKey(event))) return;
        final eventSubId = _parentSubId(subId);
        // Post-dedup event accounting.
        _stats.totalEvents++;
        _stats.eventsThisSecond++;
        // Per-relay and per-kind counts share the sourceRelay attribution; unattributed events are left out.
        if (sourceRelay != null && sourceRelay.startsWith('wss://')) {
          _stats.eventsPerRelay[sourceRelay] =
              (_stats.eventsPerRelay[sourceRelay] ?? 0) + 1;
          _stats.recordRelayKind(sourceRelay, event.kind,
              utf8.encode(jsonEncode(event.toJson())).length);
        }
        final sub = _subscriptions[eventSubId];
        if (sub != null) unawaited(sub.onEvent(sock.shard.id, event));
      case PoolEose(:final subId):
        {
          final id = _parentSubId(subId);
          _stampShardLatency(id, sock.shard.id);
          _subscriptions[id]?.onEose(sock.shard.id);
        }
      case PoolClosed(:final subId, :final reason, :final relayUrl):
        {
          // A kind-flavored CLOSED reason feeds the per-relay kind blacklist.
          final id = _parentSubId(subId);
          if (_isUnsupportedKind(reason)) {
            _recordUnsupportedKindRejection(relayUrl, id, reason);
          } else if (isRelayWideRejection(reason)) {
            _banRelay(relayUrl, reason);
          }
          _stampShardLatency(id, sock.shard.id);
          _subscriptions[id]?.onEose(sock.shard.id, closed: true);
        }
      case PoolOk(:final id, :final message, :final relayUrl):
        // Proxy publish() doesn't await OKs; a kind-flavored reason feeds the blacklist regardless of accepted.
        if (_isUnsupportedKind(message)) {
          _recordEventKindRejection(relayUrl, id);
        } else if (isRelayWideRejection(message)) {
          _banRelay(relayUrl, message);
        }
        break;
      case PoolNotice(:final reason, :final relayUrl):
        if (!_isUnsupportedKind(reason) && isRelayWideRejection(reason)) {
          _banRelay(relayUrl, reason);
        }
        break;
      case PoolStatus(:final latency):
        // Fold this worker's per-relay latency into the aggregate.
        latency.forEach((url, ms) {
          _stats.latencyPerRelay[url] = ms;
        });
        break;
      case PoolRelayBan(:final url):
        // Mirror the proxy's permanent ban so future shard layouts exclude the relay.
        _permanentBlacklist.add(url);
        break;
      case PoolRetract(:final eventId):
        onEventRetracted?.call(eventId);
        break;
      case PoolPing():
        // Keepalive; no PONG is needed.
        break;
    }
  }

  /// Relays banned this session plus any seed blacklist.
  Set<String> get permanentBlacklist => Set.unmodifiable(_permanentBlacklist);
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/constants/relays.dart';
import '../../models/nostr_event.dart';
import '../api/api_config.dart';
import 'relay_message.dart';
import 'relay_stats.dart';

/// Connection status of a single relay socket.
enum RelayStatus { disconnected, connecting, connected, failed }

/// Compute the reconnect backoff delay for [attempt] (0-based).
///
/// Mirrors the PWA direct-mode formula: `min(base * 1.5^attempt, cap)`.
/// Pure and deterministic (no jitter) so it can be unit-tested. Apply
/// [applyJitter] separately for live use.
Duration computeBackoff(
  int attempt, {
  Duration base = const Duration(milliseconds: 1000),
  Duration cap = const Duration(milliseconds: 30000),
  double factor = 1.5,
}) {
  if (attempt < 0) attempt = 0;
  final baseMs = base.inMilliseconds.toDouble();
  final capMs = cap.inMilliseconds.toDouble();
  final raw = baseMs * pow(factor, attempt);
  final ms = min(raw, capMs);
  return Duration(milliseconds: ms.round());
}

/// Apply +/- [spread] jitter (default 25%) to a duration, never below zero.
Duration applyJitter(Duration d, Random rng, {double spread = 0.25}) {
  final f = 1 - spread + rng.nextDouble() * spread * 2;
  final ms = (d.inMilliseconds * f).floor();
  return Duration(milliseconds: ms < 0 ? 0 : ms);
}

/// Factory used to open a [WebSocketChannel] for a relay URL. Overridable in
/// tests to avoid real sockets.
typedef WebSocketChannelFactory = WebSocketChannel Function(Uri url);

/// The REAL/native channel factory used by every relay socket (direct relays,
/// the relay-pool proxy shards, and the single-relay `/api/relay` path).
///
/// Routes through [IOWebSocketChannel] so we can attach a
/// `User-Agent: ApiConfig.userAgent` header — the backend `isNymchatClient`
/// gate (`_shared.js`: `/NymchatApp\//i`) recognizes the native client by it
/// (e.g. the app-relay `nymchat_proxy` perk, relay-pool.js:1124). The
/// headers-less `WebSocketChannel.connect` would send a default Dart UA.
///
/// Tests inject their own [WebSocketChannelFactory] (a fake channel), so this
/// native path — and dart:io — never runs under `flutter test`.
WebSocketChannel defaultRelayChannelFactory(Uri url) =>
    IOWebSocketChannel.connect(
      url,
      headers: {'User-Agent': ApiConfig.userAgent},
    );

/// A single relay WebSocket connection with auto-reconnect, subscription
/// re-sending, and publish acknowledgement tracking.
///
/// Transport only: it knows nothing about app state. Inbound frames are parsed
/// into [RelayMessage]s and exposed via [messages]; status changes via
/// [statusStream].
class RelayConnection {
  RelayConnection(
    this.url, {
    WebSocketChannelFactory channelFactory = defaultRelayChannelFactory,
    Random? random,
    this.publishTimeout = const Duration(seconds: 10),
    Duration? backoffBase,
    Duration? backoffCap,
  })  : _channelFactory = channelFactory,
        _rng = random ?? Random(),
        _backoffBase = backoffBase ?? const Duration(milliseconds: 1000),
        _backoffCap = backoffCap ?? const Duration(milliseconds: 30000),
        isAppRelay = url == RelayConfig.appRelay;

  final String url;
  final bool isAppRelay;
  final WebSocketChannelFactory _channelFactory;
  final Random _rng;
  final Duration publishTimeout;
  final Duration _backoffBase;
  final Duration _backoffCap;

  /// appRelay reconnects forever; others cap attempts (§4.4).
  static const int maxReconnectAttempts = 10;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSub;
  RelayStatus _status = RelayStatus.disconnected;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  bool _closedByUser = false;

  /// subId -> filters of active subscriptions, re-sent on reconnect.
  final Map<String, List<NostrFilter>> _activeSubs = {};

  /// event id -> completer awaiting a matching OK.
  final Map<String, Completer<OkMessage>> _pendingPublishes = {};

  final StreamController<RelayMessage> _messages =
      StreamController<RelayMessage>.broadcast();
  final StreamController<RelayStatus> _statusCtl =
      StreamController<RelayStatus>.broadcast();

  /// Wall-clock time of the last inbound message, or null if none yet.
  DateTime? lastMessageAt;

  /// Live traffic counters for this single socket (bytes in/out, events, and
  /// REQ→EOSE latency). The pool aggregates these into one [RelayStats] for the
  /// Network Stats modal. Mirrors the per-socket writes the PWA makes to
  /// `nym.relayStats` in relays.js (ws.onmessage / `_safeWsSend`).
  final RelayStats stats = RelayStats();

  /// subId → epoch-ms the REQ was sent, so EOSE can be stamped as
  /// `latencyPerRelay[url] = now - reqSentAt`. Cleared on EOSE / unsubscribe.
  final Map<String, int> _reqSentAt = {};

  Stream<RelayMessage> get messages => _messages.stream;
  Stream<RelayStatus> get statusStream => _statusCtl.stream;
  RelayStatus get status => _status;
  bool get isConnected => _status == RelayStatus.connected;

  void _setStatus(RelayStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  /// Open the connection. Safe to call when already connecting/connected.
  void connect() {
    _closedByUser = false;
    if (_status == RelayStatus.connecting ||
        _status == RelayStatus.connected) {
      return;
    }
    _openSocket();
  }

  void _openSocket() {
    _setStatus(RelayStatus.connecting);
    try {
      final channel = _channelFactory(Uri.parse(url));
      _channel = channel;
      _socketSub = channel.stream.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
      // web_socket_channel does not expose a discrete "open" event; the first
      // successful sink usage / inbound frame implies connectivity. Treat the
      // listen as connected and reset the backoff once data flows.
      _setStatus(RelayStatus.connected);
      _reconnectAttempt = 0;
      _resendActiveSubs();
    } catch (e) {
      _onError(e);
    }
  }

  void _onData(dynamic data) {
    lastMessageAt = DateTime.now();
    // Count every inbound frame's UTF-8 byte length (relays.js ws.onmessage:
    // `relayStats.bytesReceived += dataLen`). Binary frames count their byte
    // length directly; non-frame payloads are ignored below.
    if (data is String) {
      stats.bytesReceived += utf8.encode(data).length;
    } else if (data is List<int>) {
      stats.bytesReceived += data.length;
    }
    if (data is! String) return;
    final msg = RelayMessage.parse(data);
    if (msg == null) return;
    switch (msg) {
      case EventMessage(:final event):
        // Unique inbound EVENT: bump the total, the per-second counter, and the
        // per-relay tally (relays.js handleRelayMessage:3738-3746). Dedup is the
        // pool's job; per-connection a frame arrives once.
        stats.totalEvents++;
        stats.eventsThisSecond++;
        stats.eventsPerRelay[url] = (stats.eventsPerRelay[url] ?? 0) + 1;
        // Per-relay, per-kind breakdown for the expanded Network Stats row
        // (`_trackRelayKindData`, relays.js:3750), sized by the event's frame
        // length so the expanded view's bytes match what arrived.
        stats.recordRelayKind(url, event.kind, utf8.encode(data).length);
      case EoseMessage(:final subId):
        // Stamp REQ→EOSE latency for this relay (ms). The REQ send time was
        // recorded in [subscribe]; clear it so a later re-REQ re-measures.
        final sentAt = _reqSentAt.remove(subId);
        if (sentAt != null) {
          final ms = DateTime.now().millisecondsSinceEpoch - sentAt;
          if (ms >= 0) stats.latencyPerRelay[url] = ms;
        }
      case OkMessage():
        final completer = _pendingPublishes.remove(msg.id);
        if (completer != null && !completer.isCompleted) {
          completer.complete(msg);
        }
      case ClosedMessage():
      case NoticeMessage():
        break;
    }
    if (!_messages.isClosed) _messages.add(msg);
  }

  void _onError(Object error) {
    debugPrint('[RelayConnection] socket error for $url: $error');
    _setStatus(RelayStatus.failed);
    _cleanupSocket();
    _scheduleReconnect();
  }

  void _onDone() {
    _cleanupSocket();
    if (_closedByUser) {
      _setStatus(RelayStatus.disconnected);
      return;
    }
    _setStatus(RelayStatus.disconnected);
    _scheduleReconnect();
  }

  void _cleanupSocket() {
    _socketSub?.cancel();
    _socketSub = null;
    _channel = null;
  }

  void _scheduleReconnect() {
    if (_closedByUser) return;
    if (!isAppRelay && _reconnectAttempt >= maxReconnectAttempts) {
      _setStatus(RelayStatus.failed);
      return;
    }
    _reconnectTimer?.cancel();
    final base = computeBackoff(
      _reconnectAttempt,
      base: _backoffBase,
      cap: _backoffCap,
    );
    final delay = applyJitter(base, _rng);
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      if (_closedByUser) return;
      _openSocket();
    });
  }

  void _resendActiveSubs() {
    for (final entry in _activeSubs.entries) {
      // Re-stamp the REQ time so the next EOSE measures this fresh round-trip.
      _reqSentAt[entry.key] = DateTime.now().millisecondsSinceEpoch;
      _send(RelayFrame.req(entry.key, entry.value));
    }
  }

  bool _send(String frame) {
    final ch = _channel;
    if (ch == null || _status != RelayStatus.connected) return false;
    try {
      ch.sink.add(frame);
      // Count the outbound frame's UTF-8 byte length (relays.js `_safeWsSend`:
      // `relayStats.bytesSent += msg.length`).
      stats.bytesSent += utf8.encode(frame).length;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Subscribe with [subId] and [filters]. The subscription is tracked and
  /// re-sent automatically on reconnect.
  void subscribe(String subId, List<NostrFilter> filters) {
    _activeSubs[subId] = filters;
    // Record the REQ send time so the matching EOSE can stamp REQ→EOSE latency.
    _reqSentAt[subId] = DateTime.now().millisecondsSinceEpoch;
    _send(RelayFrame.req(subId, filters));
  }

  /// Close subscription [subId] (sends CLOSE) and stop tracking it.
  void unsubscribe(String subId) {
    _reqSentAt.remove(subId);
    if (_activeSubs.remove(subId) != null) {
      _send(RelayFrame.close(subId));
    }
  }

  /// Publish [event]; completes with the matching OK, or times out with a
  /// synthetic rejected [OkMessage] after [publishTimeout].
  Future<OkMessage> publish(NostrEvent event) {
    final existing = _pendingPublishes[event.id];
    if (existing != null) return existing.future;
    final completer = Completer<OkMessage>();
    _pendingPublishes[event.id] = completer;
    final sent = _send(RelayFrame.event(event));
    if (!sent) {
      _pendingPublishes.remove(event.id);
      return Future.value(
        OkMessage(event.id, false, 'not connected'),
      );
    }
    return completer.future.timeout(
      publishTimeout,
      onTimeout: () {
        _pendingPublishes.remove(event.id);
        return OkMessage(event.id, false, 'timeout');
      },
    );
  }

  /// Permanently close the connection and release resources.
  Future<void> close() async {
    _closedByUser = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _socketSub?.cancel();
    _socketSub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    for (final c in _pendingPublishes.values) {
      if (!c.isCompleted) c.complete(OkMessage('', false, 'closed'));
    }
    _pendingPublishes.clear();
    _setStatus(RelayStatus.disconnected);
    await _messages.close();
    await _statusCtl.close();
  }
}

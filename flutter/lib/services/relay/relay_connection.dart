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

enum RelayStatus { disconnected, connecting, connected, failed }

/// Reconnect delay `min(base * 1.5^attempt, cap)` without jitter, as in the PWA.
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

/// Applies +/- [spread] jitter to [d], never below zero.
Duration applyJitter(Duration d, Random rng, {double spread = 0.25}) {
  final f = 1 - spread + rng.nextDouble() * spread * 2;
  final ms = (d.inMilliseconds * f).floor();
  return Duration(milliseconds: ms < 0 ? 0 : ms);
}

/// Opens a [WebSocketChannel] for a relay URL; overridable in tests.
typedef WebSocketChannelFactory = WebSocketChannel Function(Uri url);

/// Native factory that sends `User-Agent: ApiConfig.userAgent` so the backend `isNymchatClient` gate passes.
WebSocketChannel defaultRelayChannelFactory(Uri url) =>
    IOWebSocketChannel.connect(
      url,
      headers: ApiConfig.socketHeadersFor(url),
      customClient: ApiConfig.socketClient(),
    );

/// One relay socket with reconnect, subscription re-send and publish OK tracking.
class RelayConnection {
  RelayConnection(
    this.url, {
    this._channelFactory = defaultRelayChannelFactory,
    Random? random,
    this.publishTimeout = const Duration(seconds: 10),
    Duration? backoffBase,
    Duration? backoffCap,
    this.via,
    this.openFrame,
    DateTime Function()? now,
  })  : _rng = random ?? Random(),
        _now = now ?? DateTime.now,
        _backoffBase = backoffBase ?? const Duration(milliseconds: 1000),
        _backoffCap = backoffCap ?? const Duration(milliseconds: 30000),
        isAppRelay = url == RelayConfig.appRelay;

  RelayConnection.viaPool(
    String url,
    String via, {
    WebSocketChannelFactory channelFactory = defaultRelayChannelFactory,
  }) : this(url,
            channelFactory: channelFactory,
            via: via,
            openFrame: jsonEncode(<dynamic>[
              'RELAYS',
              {
                'relays': [url],
                'dmRelays': [url]
              }
            ]));

  final String url;
  final String? via;
  final String? openFrame;
  final bool isAppRelay;
  final WebSocketChannelFactory _channelFactory;
  final Random _rng;
  final DateTime Function() _now;
  final Duration publishTimeout;
  final Duration _backoffBase;
  final Duration _backoffCap;

  /// appRelay reconnects forever; others cap attempts.
  static const int maxReconnectAttempts = 10;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSub;
  RelayStatus _status = RelayStatus.disconnected;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  bool _closedByUser = false;

  /// subId to filters of active subscriptions, re-sent on reconnect.
  final Map<String, List<NostrFilter>> _activeSubs = {};

  /// Event id to completer awaiting a matching OK.
  final Map<String, Completer<OkMessage>> _pendingPublishes = {};

  final StreamController<RelayMessage> _messages =
      StreamController<RelayMessage>.broadcast();
  final StreamController<RelayStatus> _statusCtl =
      StreamController<RelayStatus>.broadcast();

  DateTime? lastMessageAt;

  /// Per-socket traffic counters the pool aggregates into [RelayStats].
  final RelayStats stats = RelayStats();

  /// subId to epoch-ms of the REQ, for REQ→EOSE latency; cleared on EOSE or unsubscribe.
  final Map<String, int> _reqSentAt = {};

  Stream<RelayMessage> get messages => _messages.stream;
  Stream<RelayStatus> get statusStream => _statusCtl.stream;
  RelayStatus get status => _status;
  bool get reconnectPending => _reconnectTimer?.isActive ?? false;
  bool get isConnected => _status == RelayStatus.connected;

  void _setStatus(RelayStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  /// Opens the connection; safe when already connecting or connected.
  void connect() {
    _closedByUser = false;
    if (_status == RelayStatus.connecting || _status == RelayStatus.connected) {
      return;
    }
    _openSocket();
  }

  bool _held = false;

  void hold() {
    _held = true;
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _aliveTimer?.cancel();
    _aliveTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void reconnectNow() {
    if (_closedByUser || _held) return;
    _reconnectAttempt = 0;
    retryNow();
  }

  void retryNow() {
    if (_closedByUser ||
        _held ||
        _status == RelayStatus.connecting ||
        _status == RelayStatus.connected) {
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _openSocket();
  }

  int _frames = 0;
  Timer? _aliveTimer;

  void checkAlive(Duration limit) {
    final ch = _channel;
    if (_closedByUser ||
        _held ||
        ch == null ||
        _status != RelayStatus.connected ||
        _aliveTimer != null ||
        _openedThisWake()) {
      return;
    }
    final before = _frames;
    final hex = StringBuffer();
    for (var i = 0; i < 32; i++) {
      hex.write(_rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    final target = hex.toString();
    final id = 'nym-live-${target.substring(0, 12)}';
    _send(jsonEncode(<dynamic>[
      'REQ',
      id,
      {
        'ids': [target],
        'limit': 1,
      }
    ]));
    _aliveTimer = Timer(limit, () {
      _aliveTimer = null;
      if (_closedByUser || _held || !identical(_channel, ch)) return;
      if (_frames != before) {
        _send(jsonEncode(<dynamic>['CLOSE', id]));
        return;
      }
      _dropSocket(ch);
      _reconnectAttempt = 0;
      _openSocket();
    });
  }

  static const Duration confirmTimeout = Duration(seconds: 12);
  static const Duration confirmProbeTimeout = Duration(seconds: 3);
  Timer? _confirmTimer;

  int _framesAtOpen = 0;
  DateTime? _openedAt;

  bool _openedThisWake() {
    final at = _openedAt;
    if (_confirmTimer == null || _frames != _framesAtOpen || at == null) {
      return false;
    }
    final age = _now().difference(at);
    return !age.isNegative && age < confirmTimeout;
  }

  void _armConfirm(WebSocketChannel ch) {
    _confirmTimer?.cancel();
    final before = _frames;
    _framesAtOpen = before;
    _openedAt = _now();
    _confirmTimer = Timer(confirmTimeout, () {
      _confirmTimer = null;
      if (_closedByUser ||
          _held ||
          !identical(_channel, ch) ||
          _frames != before) {
        return;
      }
      if (_activeSubs.isEmpty) {
        checkAlive(confirmProbeTimeout);
        return;
      }
      _dropSocket(ch);
      _scheduleReconnect();
    });
  }

  void _dropSocket(WebSocketChannel ch) {
    _cleanupSocket();
    try {
      unawaited(ch.sink.close().then((_) {}, onError: (Object _) {}));
    } catch (_) {}
    _setStatus(RelayStatus.disconnected);
  }

  void _openSocket() {
    _setStatus(RelayStatus.connecting);
    try {
      final channel = _channelFactory(Uri.parse(via ?? url));
      _channel = channel;
      _socketSub = channel.stream.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
      // Treat listen as connected, but reset backoff only on the first frame: listen succeeds even for dead relays.
      _setStatus(RelayStatus.connected);
      final open = openFrame;
      if (open != null) _send(open);
      _resendActiveSubs();
      _armConfirm(channel);
    } catch (e) {
      _onError(e);
    }
  }

  void _onData(dynamic data) {
    lastMessageAt = DateTime.now();
    _frames++;
    // Only the first real frame proves the socket connected, so reset backoff here.
    _reconnectAttempt = 0;
    // Count inbound UTF-8 byte length, as the PWA's relayStats does.
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
        // Dedup is the pool's job; per connection a frame arrives once.
        stats.totalEvents++;
        stats.eventsThisSecond++;
        stats.eventsPerRelay[url] = (stats.eventsPerRelay[url] ?? 0) + 1;
        // Per-relay, per-kind breakdown sized by the frame length.
        stats.recordRelayKind(url, event.kind, utf8.encode(data).length);
      case EoseMessage(:final subId):
        // REQ→EOSE latency in ms; clearing the stamp lets a later re-REQ re-measure.
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
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _socketSub?.cancel();
    _socketSub = null;
    _channel = null;
  }

  void _scheduleReconnect() {
    if (_closedByUser || _held) return;
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
      if (_closedByUser || _held) return;
      _openSocket();
    });
  }

  void _resendActiveSubs() {
    for (final entry in _activeSubs.entries) {
      // Re-stamp so the next EOSE measures this round-trip.
      _reqSentAt[entry.key] = DateTime.now().millisecondsSinceEpoch;
      _send(RelayFrame.req(entry.key, entry.value));
    }
  }

  bool _send(String frame) {
    final ch = _channel;
    if (ch == null || _status != RelayStatus.connected) return false;
    try {
      ch.sink.add(frame);
      stats.bytesSent += utf8.encode(frame).length;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Subscribes; the subscription is re-sent automatically on reconnect.
  void subscribe(String subId, List<NostrFilter> filters) {
    _activeSubs[subId] = filters;
    _reqSentAt[subId] = DateTime.now().millisecondsSinceEpoch;
    _send(RelayFrame.req(subId, filters));
  }

  void unsubscribe(String subId) {
    _reqSentAt.remove(subId);
    if (_activeSubs.remove(subId) != null) {
      _send(RelayFrame.close(subId));
    }
  }

  /// Completes with the matching OK, or a synthetic rejection after [publishTimeout].
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

  Future<void> close() async {
    _closedByUser = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _aliveTimer?.cancel();
    _aliveTimer = null;
    _confirmTimer?.cancel();
    _confirmTimer = null;
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

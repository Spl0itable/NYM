import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/constants/relays.dart';
import '../../models/nostr_event.dart';
import '../api/api_config.dart';
import 'proxy_down_rule.dart';
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
@visibleForTesting
WebSocketChannelFactory? relayChannelFactoryOverride;

DateTime Function() relayClock = DateTime.now;

WebSocketChannel defaultRelayChannelFactory(Uri url) =>
    relayChannelFactoryOverride?.call(url) ??
    IOWebSocketChannel.connect(
      url,
      headers: ApiConfig.socketHeadersFor(url),
      customClient: ApiConfig.socketClient(),
    );

class DialGate {
  DialGate({
    this.limit = 24,
    this.pause = const Duration(seconds: 5),
    this.reserve = 24,
  });

  static Duration reachAll(int relays, Duration handshake, {int limit = 24}) =>
      handshake * ((relays + limit - 1) ~/ limit) + const Duration(seconds: 1);

  final int limit;
  final Duration pause;
  final int reserve;
  int _active = 0;
  int? _ceiling;
  bool _squeezed = false;
  Timer? _pauseTimer;
  final ListQueue<RelayConnection> _queue = ListQueue<RelayConnection>();
  final Set<RelayConnection> _open = <RelayConnection>{};
  int outOfFiles = 0;

  int get active => _active;
  int get queued => _queue.length;
  int get open => _open.length;
  int? get ceiling => _ceiling;

  int get _room {
    final c = _ceiling;
    if (c != null && _open.length + _active >= c) return 0;
    return (_squeezed ? 1 : limit) - _active;
  }

  void _enqueue(RelayConnection c) {
    if (_queue.contains(c)) return;
    _queue.add(c);
    _pump();
  }

  void _dequeue(RelayConnection c) => _queue.remove(c);

  void _pump() {
    while (_pauseTimer == null && _queue.isNotEmpty && _room > 0) {
      final c = _queue.removeFirst();
      _active++;
      c._dial();
    }
  }

  void _release({required RelayConnection conn, required bool opened}) {
    if (_active > 0) _active--;
    if (opened) {
      _open.add(conn);
      _squeezed = false;
      final c = _ceiling;
      if (c != null && _open.length > c) {
        for (final x in _open.toList().reversed.take(_open.length - c)) {
          x._shed();
        }
      }
    }
    _pump();
  }

  void _closed(RelayConnection c) {
    if (_open.remove(c)) _pump();
  }

  void _outOfFiles() {
    outOfFiles++;
    _squeezed = true;
    final cap = _open.length + _active - reserve;
    final ceiling = cap < 8 ? 8 : cap;
    _ceiling = ceiling;
    final shed = _open.length - ceiling;
    if (shed > 0) {
      for (final c in _open.toList().reversed.take(shed)) {
        c._shed();
      }
    }
    _pauseTimer ??= Timer(pause, () {
      _pauseTimer = null;
      _pump();
    });
  }
}

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
    DialGate? gate,
    this.handshakeTimeout = const Duration(seconds: 10),
  })  : _rng = random ?? Random(),
        _gate = gate ?? DialGate(),
        _now = now ?? relayClock,
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
  final DialGate _gate;
  final Duration handshakeTimeout;

  static bool backgrounded = false;

  static bool offline = false;

  static const Duration silenceTimeout = Duration(seconds: 12);

  Timer? _silenceTimer;

  static const int slowAfter = 10;
  static const Duration slowCap = Duration(minutes: 5);

  bool get _gated => via == null;
  bool _inGate = false;
  Timer? _handshakeTimer;

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
    _gate._dequeue(this);
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
        _openedRecently()) {
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

  static const Duration confirmProbeTimeout = Duration(seconds: 3);

  DateTime? _openedAt;

  bool _openedRecently() {
    final at = _openedAt;
    if (at == null) return false;
    final age = _now().difference(at);
    return !age.isNegative && age < confirmProbeTimeout;
  }

  void _dropSocket(WebSocketChannel ch) {
    _cleanupSocket();
    try {
      unawaited(ch.sink.close().then((_) {}, onError: (Object _) {}));
    } catch (_) {}
    _setStatus(RelayStatus.disconnected);
  }

  void _shed() {
    final ch = _channel;
    if (ch != null) _dropSocket(ch);
    if (_reconnectAttempt < slowAfter) _reconnectAttempt = slowAfter;
    _scheduleReconnect();
  }

  void _openSocket() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setStatus(RelayStatus.connecting);
    if (_gated) {
      _gate._enqueue(this);
    } else {
      _dial();
    }
  }

  void _dial() {
    _inGate = _gated;
    if (_closedByUser || _held) {
      _release(false);
      _setStatus(RelayStatus.disconnected);
      return;
    }
    try {
      final channel = _channelFactory(Uri.parse(via ?? url));
      _channel = channel;
      _socketSub = channel.stream.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
      _handshakeTimer = Timer(handshakeTimeout, () {
        _handshakeTimer = null;
        if (!identical(_channel, channel) ||
            _status == RelayStatus.connected) {
          return;
        }
        _dropSocket(channel);
        _scheduleReconnect();
      });
      unawaited(channel.ready.then((_) => _onOpen(channel), onError: (Object e) {
        if (identical(_channel, channel)) _onError(e);
      }));
    } catch (e) {
      _onError(e);
    }
  }

  void _release(bool opened) {
    if (!_inGate) return;
    _inGate = false;
    _gate._release(conn: this, opened: opened);
  }

  void _onOpen(WebSocketChannel ch) {
    if (!identical(_channel, ch) || _status == RelayStatus.connected) return;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _release(true);
    if (!identical(_channel, ch)) return;
    _openedAt = _now();
    _setStatus(RelayStatus.connected);
    if (_activeSubs.isNotEmpty) {
      final before = _frames;
      _silenceTimer = Timer(silenceTimeout, () {
        _silenceTimer = null;
        if (!identical(_channel, ch) || _frames != before) return;
        _dropSocket(ch);
        _scheduleReconnect();
      });
    }
    final open = openFrame;
    if (open != null) _send(open);
    _resendActiveSubs();
  }

  void _onData(dynamic data) {
    final ch = _channel;
    if (ch != null && _status != RelayStatus.connected) _onOpen(ch);
    lastMessageAt = _now();
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
          final ms = _now().millisecondsSinceEpoch - sentAt;
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
    _cleanupSocket();
    if (socketOutOfFiles(error)) {
      _gate._outOfFiles();
      if (_closedByUser || _held) {
        _setStatus(RelayStatus.disconnected);
        return;
      }
      _setStatus(RelayStatus.connecting);
      _gate._enqueue(this);
      return;
    }
    debugPrint('[RelayConnection] socket error for $url: $error');
    _setStatus(RelayStatus.failed);
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
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _release(false);
    _gate._closed(this);
    _socketSub?.cancel();
    _socketSub = null;
    _channel = null;
  }

  void _scheduleReconnect() {
    if (_closedByUser || _held) return;
    _reconnectTimer?.cancel();
    final slow = !isAppRelay && _reconnectAttempt >= slowAfter;
    final base = computeBackoff(
      _reconnectAttempt,
      base: _backoffBase,
      cap: slow ? slowCap : _backoffCap,
    );
    final delay = applyJitter(base, _rng);
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      if (_closedByUser || _held) return;
      if (!isAppRelay && (offline || (slow && backgrounded))) {
        _setStatus(RelayStatus.disconnected);
        return;
      }
      _openSocket();
    });
  }

  void _resendActiveSubs() {
    for (final entry in _activeSubs.entries) {
      // Re-stamp so the next EOSE measures this round-trip.
      _reqSentAt[entry.key] = _now().millisecondsSinceEpoch;
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
    _reqSentAt[subId] = _now().millisecondsSinceEpoch;
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

  void retire() {
    _closedByUser = true;
    _gate._dequeue(this);
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  Future<void> close() async {
    _closedByUser = true;
    _gate._dequeue(this);
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _aliveTimer?.cancel();
    _aliveTimer = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _release(false);
    _gate._closed(this);
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

import 'dart:async';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/constants/relays.dart';
import '../../models/nostr_event.dart';
import 'relay_message.dart';

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

WebSocketChannel _defaultChannelFactory(Uri url) =>
    WebSocketChannel.connect(url);

/// A single relay WebSocket connection with auto-reconnect, subscription
/// re-sending, and publish acknowledgement tracking.
///
/// Transport only: it knows nothing about app state. Inbound frames are parsed
/// into [RelayMessage]s and exposed via [messages]; status changes via
/// [statusStream].
class RelayConnection {
  RelayConnection(
    this.url, {
    WebSocketChannelFactory channelFactory = _defaultChannelFactory,
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
    if (data is! String) return;
    final msg = RelayMessage.parse(data);
    if (msg == null) return;
    if (msg is OkMessage) {
      final completer = _pendingPublishes.remove(msg.id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(msg);
      }
    }
    if (!_messages.isClosed) _messages.add(msg);
  }

  void _onError(Object error) {
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
      _send(RelayFrame.req(entry.key, entry.value));
    }
  }

  bool _send(String frame) {
    final ch = _channel;
    if (ch == null || _status != RelayStatus.connected) return false;
    try {
      ch.sink.add(frame);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Subscribe with [subId] and [filters]. The subscription is tracked and
  /// re-sent automatically on reconnect.
  void subscribe(String subId, List<NostrFilter> filters) {
    _activeSubs[subId] = filters;
    _send(RelayFrame.req(subId, filters));
  }

  /// Close subscription [subId] (sends CLOSE) and stop tracking it.
  void unsubscribe(String subId) {
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

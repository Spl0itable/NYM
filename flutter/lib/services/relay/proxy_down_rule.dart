import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';

class ProxyLinkState {
  bool foreground = true;
  bool online = true;
  DateTime? graceUntil;
  int epoch = 0;

  void paused() {
    foreground = false;
    epoch++;
  }

  void resumed(DateTime now) {
    foreground = true;
    graceUntil = now.add(ProxyDownRule.resumeGrace);
    epoch++;
  }

  void offline() {
    online = false;
    epoch++;
  }

  void onlineAgain(DateTime now) {
    online = true;
    graceUntil = now.add(ProxyDownRule.resumeGrace);
    epoch++;
  }

  bool counts(DateTime now) {
    final until = graceUntil;
    return foreground && online && (until == null || !now.isBefore(until));
  }
}

class ProxyDownRule {
  ProxyDownRule({ProxyLinkState? link}) : link = link ?? ProxyLinkState();

  static const int minFailures = 4;
  static const Duration window = Duration(seconds: 45);
  static const Duration resumeGrace = Duration(seconds: 10);
  static const Duration maxGap = Duration(seconds: 20);

  final ProxyLinkState link;
  int _failures = 0;
  final Set<String> _shards = {};
  Duration _span = Duration.zero;
  DateTime? _lastAt;
  int _epoch = -1;

  int get failures => _failures;
  Duration get span => _span;

  void success() => _reset();

  void _reset() {
    _failures = 0;
    _shards.clear();
    _span = Duration.zero;
    _lastAt = null;
  }

  bool failure(DateTime now,
      {required String shard,
      required int shardCount,
      bool rateLimited = false}) {
    if (rateLimited || !link.counts(now)) {
      _reset();
      return false;
    }
    if (_epoch != link.epoch) {
      _reset();
      _epoch = link.epoch;
    }
    final last = _lastAt;
    if (last != null) {
      final gap = now.difference(last);
      if (!gap.isNegative) _span += gap > maxGap ? maxGap : gap;
    }
    _lastAt = now;
    _failures++;
    _shards.add(shard);
    if (_failures < minFailures || _span < window) return false;
    return shardCount <= 1 || _shards.length >= 2;
  }
}

final RegExp _rateLimitText =
    RegExp(r'rate.?limit|too many (connections|requests)|\b429\b', caseSensitive: false);

bool proxyCloseNamesRateLimit(Object? error, {String? reason}) {
  if (reason != null && _rateLimitText.hasMatch(reason)) return true;
  Object? e = error;
  if (e is WebSocketChannelException) {
    final inner = e.inner;
    if (inner is WebSocketException && inner.httpStatusCode == 429) return true;
    e = inner ?? e.message;
  }
  if (e is WebSocketException) return e.httpStatusCode == 429;
  if (e == null || e is SocketException) return false;
  return _rateLimitText.hasMatch(e.toString());
}

bool socketOutOfFiles(Object? error) {
  Object? e = error;
  if (e is WebSocketChannelException) e = e.inner ?? e.message;
  if (e is SocketException && e.osError?.errorCode == 24) return true;
  final s = e?.toString() ?? '';
  return s.contains('Too many open files') || s.contains('EMFILE');
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../services/api/api_config.dart';
import '../../services/relay/relay_connection.dart'
    show WebSocketChannelFactory, defaultRelayChannelFactory;
import 'relay_add.dart';

class RelayCheckResult {
  const RelayCheckResult(this.ok, this.code,
      {this.ms, this.s, this.reason, this.via = 'pool'});

  final bool ok;
  final String code;
  final int? ms;
  final int? s;
  final String? reason;
  final String via;
}

Future<RelayCheckResult> checkRelayReachable(
  String url, {
  required bool viaPool,
  String? poolUrl,
  WebSocketChannelFactory? channelFactory,
  Duration timeout = RelayAdd.checkTimeout,
  Random? random,
}) {
  final rng = random ?? Random.secure();
  final via = viaPool ? 'pool' : 'direct';
  final target = viaPool ? (poolUrl ?? ApiConfig.relayPoolUrl()) : url;
  final probe = StringBuffer();
  for (var i = 0; i < 32; i++) {
    probe.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  final probeId = probe.toString();
  final subId = 'nym-add-${probeId.substring(0, 12)}';
  final failCode = viaPool ? 'poolDown' : 'unreachable';
  final done = Completer<RelayCheckResult>();
  final started = DateTime.now();
  DateTime? connectedAt;
  int? latency;
  Timer? timer;
  Timer? grace;
  WebSocketChannel? ch;
  StreamSubscription<dynamic>? sub;
  var opened = false;

  void finish(RelayCheckResult r) {
    if (done.isCompleted) return;
    timer?.cancel();
    grace?.cancel();
    unawaited(sub?.cancel());
    try {
      unawaited(ch?.sink.close());
    } catch (_) {}
    done.complete(r);
  }

  void ok() {
    final at = connectedAt ?? DateTime.now();
    finish(RelayCheckResult(true, 'reachable',
        ms: latency ?? at.difference(started).inMilliseconds, via: via));
  }

  timer = Timer(timeout, () {
    if (connectedAt != null) {
      ok();
    } else {
      finish(RelayCheckResult(false, 'timeout',
          s: (timeout.inMilliseconds / 1000).round(), via: via));
    }
  });

  void onFrame(dynamic data) {
    if (data is! String) return;
    final Object? m;
    try {
      m = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (m is! List || m.isEmpty) return;
    final type = m[0];
    if (viaPool && type == 'POOL:STATUS' && m.length > 1 && m[1] is Map) {
      final status = m[1] as Map;
      final connected = status['connected'];
      if (connected is List && connected.contains(url) && connectedAt == null) {
        connectedAt = DateTime.now();
        final lat = status['latency'];
        if (lat is Map && lat[url] is num) latency = (lat[url] as num).round();
        grace = Timer(const Duration(seconds: 3), ok);
      }
      return;
    }
    if (viaPool && type == 'POOL:RELAY_BAN' && m.length > 1 && m[1] == url) {
      finish(RelayCheckResult(false, 'refused',
          reason: m.length > 2 ? '${m[2]}' : 'refused', via: via));
      return;
    }
    if (type == 'EOSE' && m.length > 1 && m[1] == subId) {
      connectedAt ??= DateTime.now();
      ok();
      return;
    }
    if (type == 'CLOSED' && m.length > 1 && m[1] == subId) {
      final why = m.length > 2 ? '${m[2]}' : '';
      final from = m.length > 3 ? m[3] : null;
      if (!viaPool || from == null || from == url) {
        finish(RelayCheckResult(false, 'refused',
            reason: why.isEmpty ? 'closed' : why, via: via));
      }
    }
  }

  void onEnd() {
    if (done.isCompleted) return;
    if (opened && viaPool && connectedAt != null) {
      ok();
    } else {
      finish(RelayCheckResult(false, failCode, via: via));
    }
  }

  try {
    ch = (channelFactory ?? defaultRelayChannelFactory)(Uri.parse(target));
  } catch (_) {
    finish(RelayCheckResult(false, failCode, via: via));
    return done.future;
  }
  sub = ch.stream.listen(onFrame,
      onError: (Object _) => onEnd(), onDone: onEnd, cancelOnError: false);
  ch.ready.then((_) {
    if (done.isCompleted) return;
    opened = true;
    try {
      if (viaPool) {
        ch!.sink.add(jsonEncode([
          'RELAYS',
          {
            'relays': [url],
            'dmRelays': <String>[],
          }
        ]));
      } else {
        connectedAt = DateTime.now();
      }
      ch!.sink.add(jsonEncode([
        'REQ',
        subId,
        {
          'ids': [probeId],
          'limit': 1,
        }
      ]));
    } catch (_) {
      finish(RelayCheckResult(false, failCode, via: via));
    }
  }, onError: (Object _) {
    finish(RelayCheckResult(false, failCode, via: via));
  });
  return done.future;
}

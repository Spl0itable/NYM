import 'dart:async';

import '../../models/nostr_event.dart';
import 'send_as_transport.dart';

class AnonLane {
  AnonLane(
    this._open, {
    this.attempts = 3,
    this.budget = const Duration(seconds: 20),
  });

  final SendAsTransport Function() _open;
  final int attempts;
  final Duration budget;
  SendAsTransport? _transport;
  bool _closed = false;

  bool get closed => _closed;

  Future<SendAsOk> publish(NostrEvent event,
      {List<String> geoRelays = const []}) async {
    final started = DateTime.now();
    var result = const SendAsOk(false, retryable: true);
    for (var i = 0; i < attempts && !_closed; i++) {
      final SendAsTransport t;
      try {
        t = _transport ??= _open();
      } catch (_) {
        return result;
      }
      result = await t.publish(event, geoRelays: geoRelays);
      if (result.accepted || !result.retryable || _closed) break;
      if (DateTime.now().difference(started) >= budget) break;
      if (identical(_transport, t)) _transport = null;
      unawaited(t.close());
    }
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final t = _transport;
    _transport = null;
    if (t == null) return;
    try {
      await t.close();
    } catch (_) {}
  }
}

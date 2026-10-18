import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/constants/event_kinds.dart';
import '../../core/constants/relays.dart';
import '../../models/nostr_event.dart';
import '../../services/api/api_config.dart';
import '../../services/relay/relay_connection.dart'
    show WebSocketChannelFactory, defaultRelayChannelFactory;
import 'account_logic.dart';
import 'inactive_probe.dart';

class InactiveWatch {
  InactiveWatch({
    required this.probe,
    required this.onFresh,
    WebSocketChannelFactory? channel,
    Duration Function(bool first)? delay,
    int Function()? nowSec,
  })  : _channel = channel ?? defaultRelayChannelFactory,
        _delay = delay ?? defaultDelay,
        _nowSec = nowSec ?? _wallSec;

  static const String watchRelay = 'wss://relay.damus.io';
  static const int directSinceSec = 3 * 24 * 60 * 60;

  static final Random _rng = Random.secure();

  static Duration defaultDelay(bool first) => first
      ? Duration(milliseconds: 1000 + _rng.nextInt(11000))
      : Duration(milliseconds: 30000 + _rng.nextInt(30000));

  static int _wallSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final InactiveProbe probe;
  final Future<void> Function(AccountEntry a) onFresh;
  final WebSocketChannelFactory _channel;
  final Duration Function(bool first) _delay;
  final int Function() _nowSec;
  final Map<String, _Watch> _watches = {};

  Set<String> get watching => _watches.keys.toSet();

  String relayFor(String id) {
    final usable = probe.relaysFor(id).toSet();
    final ordered = [
      watchRelay,
      for (final u in RelayConfig.defaultRelays)
        if (u != watchRelay &&
            u != RelayConfig.appRelay &&
            !RelayConfig.writeOnlyRelays.contains(u))
          u,
    ];
    for (final u in ordered) {
      if (usable.contains(u)) return u;
    }
    return watchRelay;
  }

  void sync(Iterable<AccountEntry> want) {
    final next = <String, AccountEntry>{
      for (final a in want)
        if (a.pubkey.length == 64 && a.method != 'anonymous') a.id: a,
    };
    for (final id in _watches.keys.toList()) {
      final a = next[id];
      if (a == null || a.pubkey != _watches[id]!.account.pubkey) {
        _watches.remove(id)!.stop();
      }
    }
    for (final a in next.values) {
      if (_watches.containsKey(a.id)) continue;
      final w = _Watch(this, a);
      _watches[a.id] = w;
      w.arm(first: true);
    }
  }

  void stopAll() {
    for (final w in _watches.values) {
      w.stop();
    }
    _watches.clear();
  }
}

class _Watch {
  _Watch(this.owner, this.account);

  final InactiveWatch owner;
  final AccountEntry account;
  final Set<String> _seen = {};
  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _timer;
  bool _stopped = false;

  void arm({required bool first}) {
    if (_stopped) return;
    _timer?.cancel();
    _timer = Timer(owner._delay(first), _open);
  }

  void _open() {
    _timer = null;
    if (_stopped) return;
    final relay = owner.relayFor(account.id);
    final direct = owner.probe.directMode;
    final url = direct || ApiConfig.apiHost.isEmpty
        ? relay
        : ApiConfig.singleRelayUrl(relay);
    final WebSocketChannel ch;
    try {
      ch = owner._channel(Uri.parse(url));
    } catch (_) {
      arm(first: false);
      return;
    }
    _ch = ch;
    final subId = 'n${InactiveWatch._rng.nextInt(1 << 32).toRadixString(36)}';
    var live = false;
    _sub = ch.stream.listen(
      (raw) {
        Object? m;
        try {
          m = jsonDecode('$raw');
        } catch (_) {
          return;
        }
        if (m is! List || m.length < 2 || m[1] != subId) return;
        if (m[0] == 'EOSE') {
          live = true;
          return;
        }
        if (m[0] != 'EVENT' || m.length < 3 || m[2] is! Map) return;
        final NostrEvent ev;
        try {
          ev = NostrEvent.fromJson(Map<String, dynamic>.from(m[2] as Map));
        } catch (_) {
          return;
        }
        if (ev.kind != EventKind.giftWrap || ev.id.isEmpty) return;
        if (!ev.tags.any((t) =>
            t.length > 1 && t[0] == 'p' && t[1] == account.pubkey)) {
          return;
        }
        if (!_seen.add(ev.id) || !live) return;
        unawaited(_fresh(ev));
      },
      onDone: _closed,
      onError: (Object _) => _closed(),
      cancelOnError: true,
    );
    final filter = <String, Object>{
      'kinds': [EventKind.giftWrap],
      '#p': [account.pubkey],
      if (direct) 'since': owner._nowSec() - InactiveWatch.directSinceSec,
      if (!direct) 'limit': 1,
    };
    try {
      ch.sink.add(jsonEncode(['REQ', subId, filter]));
    } catch (_) {}
  }

  Future<void> _fresh(NostrEvent ev) async {
    if (_stopped) return;
    if (!await owner.probe.noteSeen(account.id, ev.id)) return;
    if (await owner.probe.wrapHidden(account, ev)) return;
    if (_stopped) return;
    await owner.onFresh(account);
  }

  void _closed() {
    _sub = null;
    _ch = null;
    if (!_stopped) arm(first: false);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    final ch = _ch;
    _ch = null;
    try {
      unawaited(ch?.sink.close());
    } catch (_) {}
  }
}

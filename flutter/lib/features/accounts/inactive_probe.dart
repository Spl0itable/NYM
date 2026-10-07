import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/event_kinds.dart';
import '../../core/constants/relays.dart';
import '../../services/relay/relay_message.dart';
import '../../services/relay/relay_pool.dart';
import '../../services/relay/relay_pool_proxy.dart';
import 'account_logic.dart';

typedef ProbeTransportFactory = PoolTransport Function(bool direct);

class InactiveProbe {
  InactiveProbe({
    required this.prefs,
    ProbeTransportFactory? transport,
    this.window = const Duration(seconds: 8),
    int Function()? nowSec,
    Duration Function()? stagger,
  })  : _transport = transport ?? _defaultTransport,
        _nowSec = nowSec ?? _wallSec,
        _stagger = stagger ?? defaultStagger;

  static final Random _rng = Random();

  static Duration defaultStagger() =>
      Duration(milliseconds: 1000 + _rng.nextInt(11000));

  static const String seenKey = 'nym_probe_seen';
  static const String sinceKey = 'nym_probe_since';
  static const int wrapSkewSec = 2 * 24 * 60 * 60;
  static const int seenCap = 500;

  final SharedPreferences prefs;
  final ProbeTransportFactory _transport;
  final Duration window;
  final int Function() _nowSec;
  final Duration Function() _stagger;

  static int _wallSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static PoolTransport _defaultTransport(bool direct) => direct
      ? RelayPool(
          relays: RelayConfig.defaultRelays,
          writeOnlyRelays: RelayConfig.writeOnlyRelays,
        )
      : RelayPoolProxy(
          relays: RelayConfig.defaultRelays,
          dmRelays: RelayConfig.defaultRelays,
        );

  Future<void> baseline(String id, List<String> seen) async {
    final kept =
        seen.length > seenCap ? seen.sublist(seen.length - seenCap) : seen;
    await prefs.setString(AccountLogic.nsKey(id, seenKey), jsonEncode(kept));
    await prefs.setString(AccountLogic.nsKey(id, sinceKey), '${_nowSec()}');
  }

  Future<int> probe(AccountEntry a) async {
    if (a.pubkey.length != 64 || a.method == 'anonymous') return 0;
    final sinceRaw = prefs.getString(AccountLogic.nsKey(a.id, sinceKey));
    final since = int.tryParse(sinceRaw ?? '');
    final seen = <String>[];
    try {
      final raw = prefs.getString(AccountLogic.nsKey(a.id, seenKey));
      if (raw != null) {
        for (final id in jsonDecode(raw) as List) {
          seen.add('$id');
        }
      }
    } catch (_) {}
    await Future<void>.delayed(_stagger());
    final now = _nowSec();
    final direct = prefs.getString('nym_relay_direct_mode') == 'true';
    final pool = _transport(direct);
    final found = <String>[];
    try {
      pool.connectAll();
      final sub = pool.subscribe([
        NostrFilter(
          kinds: const [EventKind.giftWrap],
          since: (since ?? now) - wrapSkewSec,
          limit: 200,
          tags: {
            'p': [a.pubkey],
          },
        ),
      ]);
      final listen = sub.events.listen((e) => found.add(e.id));
      try {
        await sub.eose.timeout(window);
      } catch (_) {}
      await listen.cancel();
      await sub.close();
    } catch (_) {
    } finally {
      try {
        await pool.disconnectAll();
      } catch (_) {}
    }
    final known = seen.toSet();
    final fresh = [
      for (final id in found)
        if (!known.contains(id)) id,
    ];
    final merged = [...seen, ...fresh];
    final kept = merged.length > seenCap
        ? merged.sublist(merged.length - seenCap)
        : merged;
    await prefs.setString(AccountLogic.nsKey(a.id, seenKey), jsonEncode(kept));
    await prefs.setString(AccountLogic.nsKey(a.id, sinceKey), '$now');
    return since == null ? 0 : fresh.length;
  }
}

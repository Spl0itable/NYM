import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final pmSupportPeersProvider = StateProvider<Set<String>>((ref) => const {});

class PmSupportTokens {
  PmSupportTokens();

  factory PmSupportTokens.decode(String? raw) {
    final out = PmSupportTokens();
    if (raw == null || raw.isEmpty) return out;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return out;
      data.forEach((peer, list) {
        if (peer is! String || !_hex64.hasMatch(peer) || list is! List) return;
        final entries = <({String token, int ts})>[];
        for (final e in list) {
          if (e is! Map) continue;
          final t = e['t'];
          final ts = e['ts'];
          if (t is! String || !_hex64.hasMatch(t) || ts is! num) continue;
          entries.add((token: t, ts: ts.toInt()));
        }
        if (entries.isNotEmpty) {
          out._byPeer[peer] = entries.take(perPeer).toList();
        }
      });
    } catch (_) {}
    return out;
  }

  static const int perPeer = 4;
  static const int maxPeers = 256;
  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

  final Map<String, List<({String token, int ts})>> _byPeer = {};

  static String? normalize(String? token) {
    if (token == null) return null;
    final t = token.toLowerCase();
    return _hex64.hasMatch(t) ? t : null;
  }

  Set<String> get peers => _byPeer.keys.toSet();

  List<String> tokensFor(String peer) =>
      [for (final e in _byPeer[peer] ?? const []) e.token];

  String? newestFor(String peer) {
    final list = _byPeer[peer];
    return (list == null || list.isEmpty) ? null : list.first.token;
  }

  bool record(String peer, String token, int ts) {
    final t = normalize(token);
    if (t == null || !_hex64.hasMatch(peer)) return false;
    final prior = _byPeer.remove(peer) ?? const <({String token, int ts})>[];
    var keepTs = ts;
    for (final e in prior) {
      if (e.token == t && e.ts > keepTs) keepTs = e.ts;
    }
    final next = <({String token, int ts})>[
      (token: t, ts: keepTs),
      for (final e in prior)
        if (e.token != t) e,
    ];
    final ordered = _newestFirst(next);
    _byPeer[peer] = ordered.take(perPeer).toList();
    while (_byPeer.length > maxPeers) {
      String? stalest;
      var stalestTs = 0;
      for (final entry in _byPeer.entries) {
        final newest = entry.value.isEmpty ? 0 : entry.value.first.ts;
        if (stalest == null || newest < stalestTs) {
          stalest = entry.key;
          stalestTs = newest;
        }
      }
      _byPeer.remove(stalest);
    }
    return true;
  }

  static List<({String token, int ts})> _newestFirst(
      List<({String token, int ts})> list) {
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      final c = b.$2.ts.compareTo(a.$2.ts);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  String encode() => jsonEncode({
        for (final entry in _byPeer.entries)
          entry.key: [
            for (final e in entry.value) {'t': e.token, 'ts': e.ts}
          ],
      });
}

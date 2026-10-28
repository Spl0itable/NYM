import 'dart:convert';

import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';

const String kStandaloneSupportTag = 'nymbot-support';

const int kStandaloneNymbotSince = 1790812800;

const int kStandaloneSweepPage = 500;

const int kStandaloneSweepPages = 10;

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

const Set<String> _phases = {'live', 'park', 'done'};

List<List<dynamic>> _named(Object? tags, String name) => [
      if (tags is List)
        for (final t in tags)
          if (t is List && t.isNotEmpty && t[0] == name) t,
    ];

bool isStandaloneNymbotRunWrap({
  required String sealPubkey,
  required int sealKind,
  required Map<String, dynamic> rumor,
  required String me,
  required String botPubkey,
}) {
  final tags = rumor['tags'];
  if (_named(tags, kStandaloneSupportTag).isNotEmpty) return false;
  final author = rumor['pubkey'];
  if (rumor['kind'] != 14 || sealKind != 13 || author is! String) {
    return false;
  }
  if (sealPubkey != author) return false;
  if (!_hex64.hasMatch(author) ||
      !_hex64.hasMatch(me) ||
      !_hex64.hasMatch(botPubkey)) {
    return false;
  }
  if (author == me || author == botPubkey) return false;
  if (!_named(tags, 'p').any((t) => t.length > 1 && t[1] == me)) return false;
  final runs = _named(tags, 'nymbot-run');
  if (runs.length != 1 || runs[0].length < 3) return false;
  final run = runs[0][1];
  if (run is! String || run.isEmpty || !_phases.contains(runs[0][2])) {
    return false;
  }
  final certs = _named(tags, 'nymbot-cert');
  if (certs.length != 1 || certs[0].length < 2 || certs[0][1] is! String) {
    return false;
  }
  Object? raw;
  try {
    raw = jsonDecode(certs[0][1] as String);
  } catch (_) {
    return false;
  }
  if (raw is! Map ||
      raw['kind'] != 25519 ||
      raw['pubkey'] != botPubkey ||
      raw['content'] != '' ||
      raw['tags'] is! List) {
    return false;
  }
  final cp = _named(raw['tags'], 'p');
  final cs = _named(raw['tags'], 's');
  if (cp.length != 1 || cp[0].length < 2 || cp[0][1] != me) return false;
  if (cs.length != 1 || cs[0].length < 2 || cs[0][1] != author) return false;
  try {
    final cert = NostrEvent.fromJson(Map<String, dynamic>.from(raw));
    if (cert.id.isEmpty) return false;
    return schnorr.verifyEvent(cert);
  } catch (_) {
    return false;
  }
}

class StandaloneSweepThread {
  const StandaloneSweepThread(this.peer, this.messages);
  final String peer;
  final List<({bool own, int createdAt})> messages;
}

List<String> standaloneSweepCandidates(
  Iterable<StandaloneSweepThread> threads, {
  required String self,
  required String botPubkey,
}) {
  final out = <String>[];
  for (final t in threads) {
    if (!_hex64.hasMatch(t.peer) || t.peer == self || t.peer == botPubkey) {
      continue;
    }
    if (t.messages.isEmpty || t.messages.any((m) => m.own)) continue;
    if (t.messages.any((m) => m.createdAt >= kStandaloneNymbotSince)) {
      out.add(t.peer);
    }
  }
  return out;
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/event_kinds.dart';
import '../../models/nostr_event.dart';

typedef PqKeyFetch = Future<Map<String, dynamic>?> Function(String pubkey);

typedef PqArchiveFetch = Future<List<Map<String, dynamic>>> Function(
    String pubkey);

final pqKeyFetchProvider = Provider<PqKeyFetch?>((ref) => null);

class PqAnnouncementSource {
  PqAnnouncementSource({
    this.pqKey,
    this.archive,
    required this.verify,
    this.pqKeyTimeout = defaultPqKeyTimeout,
    int Function()? nowSec,
  }) : _nowSec =
            nowSec ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  static const Duration defaultPqKeyTimeout = Duration(seconds: 3);

  final PqKeyFetch? pqKey;
  final PqArchiveFetch? archive;
  final Future<bool> Function(NostrEvent event) verify;
  final Duration pqKeyTimeout;
  final int Function() _nowSec;

  Future<bool> resolve(
    String pubkey, {
    required bool Function(NostrEvent event) ingest,
    required Future<bool> Function() relays,
  }) async {
    if (await fromD1(pubkey, ingest: ingest)) return true;
    return relays();
  }

  Future<bool> fromD1(
    String pubkey, {
    required bool Function(NostrEvent event) ingest,
  }) async {
    final worker = await _fromWorker(pubkey);
    final event = worker.event;
    if (event != null && ingest(event)) return true;
    if (worker.answered) return false;
    final archived = await _fromArchive(pubkey);
    if (archived == null) return false;
    return ingest(archived);
  }

  Future<({bool answered, NostrEvent? event})> _fromWorker(
      String pubkey) async {
    final fetch = pqKey;
    if (fetch == null) return (answered: false, event: null);
    Map<String, dynamic>? raw;
    try {
      raw = await fetch(pubkey).timeout(pqKeyTimeout);
    } catch (_) {
      return (answered: false, event: null);
    }
    if (raw == null) return (answered: true, event: null);
    NostrEvent ev;
    try {
      ev = NostrEvent.fromJson(raw);
    } catch (_) {
      return (answered: false, event: null);
    }
    if (!await _accepts(ev, pubkey)) return (answered: false, event: null);
    return (answered: true, event: ev);
  }

  Future<NostrEvent?> _fromArchive(String pubkey) async {
    final fetch = archive;
    if (fetch == null) return null;
    List<Map<String, dynamic>> rows;
    try {
      rows = await fetch(pubkey);
    } catch (_) {
      return null;
    }
    NostrEvent? best;
    for (final raw in rows) {
      NostrEvent ev;
      try {
        ev = NostrEvent.fromJson(raw);
      } catch (_) {
        continue;
      }
      if (!_shapeOk(ev, pubkey)) continue;
      if (best != null && best.createdAt >= ev.createdAt) continue;
      best = ev;
    }
    if (best == null) return null;
    return await _accepts(best, pubkey) ? best : null;
  }

  bool _shapeOk(NostrEvent ev, String pubkey) {
    if (ev.kind != EventKind.appData || ev.pubkey != pubkey) return false;
    final exp = int.tryParse(ev.tagValue('expiration') ?? '');
    if (exp != null && exp <= _nowSec()) return false;
    return true;
  }

  Future<bool> _accepts(NostrEvent ev, String pubkey) async {
    if (!_shapeOk(ev, pubkey)) return false;
    if (ev.id.isEmpty || ev.id != ev.computeId()) return false;
    try {
      return await verify(ev);
    } catch (_) {
      return false;
    }
  }
}

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show compute, kIsWeb;

import '../../models/nostr_event.dart';
import 'native_schnorr.dart';
import 'schnorr.dart' as schnorr;

/// Off-main BIP340 verification that batches a turn's events into one `compute`; per-event verdicts, fails closed.
class IsolateVerifier {
  IsolateVerifier({this.maxBatch = 256, this.verifiedCacheCap = 100000});

  /// Max events per `compute` payload; the buffer flushes early at this size.
  final int maxBatch;

  /// Verified-id cache size before oldest-first eviction.
  final int verifiedCacheCap;

  final List<NostrEvent> _pending = <NostrEvent>[];
  final List<String> _pendingIds = <String>[];
  final List<Completer<bool>> _waiters = <Completer<bool>>[];
  bool _flushScheduled = false;

  /// Single-flight batches, so replay bursts can't saturate every core at once.
  bool _inFlight = false;

  /// Called when a new id verifies, so the owner can persist [snapshotVerifiedIds].
  void Function()? onNewVerified;

  /// Ids whose signature already verified; an id binds its content, so a replay needs only the sha256 recheck.
  final LinkedHashSet<String> _verifiedIds = LinkedHashSet<String>();

  /// Seeds the cache with ids already verified, e.g. messages restored from the local cache.
  void markVerified(Iterable<String> ids) {
    for (final id in ids) {
      if (id.isEmpty) continue;
      _verifiedIds.remove(id);
      _verifiedIds.add(id);
    }
    _evictVerified();
  }

  void _rememberVerified(String id) {
    _verifiedIds.remove(id);
    _verifiedIds.add(id);
    _evictVerified();
  }

  /// The newest [max] verified ids (oldest first), for persisting across launches.
  List<String> snapshotVerifiedIds({int max = 20000}) {
    final n = _verifiedIds.length;
    if (n <= max) return List<String>.of(_verifiedIds);
    return List<String>.of(_verifiedIds.skip(n - max));
  }

  void _evictVerified() {
    while (_verifiedIds.length > verifiedCacheCap) {
      _verifiedIds.remove(_verifiedIds.first);
    }
  }

  /// Verifies [event] off the main thread; calls in the same synchronous burst share one isolate hop.
  Future<bool> verify(NostrEvent event) {
    // Cheap integrity gate: a malformed sig/pubkey or mismatched id fails before the cache or isolate.
    if (event.sig.length != 128 || event.pubkey.length != 64) {
      return Future<bool>.value(false);
    }
    final computedId = event.computeId();
    if (event.id.isNotEmpty && event.id != computedId) {
      return Future<bool>.value(false);
    }
    // Cache hit: this exact content already passed a full signature check.
    if (_verifiedIds.contains(computedId)) {
      _rememberVerified(computedId); // Promote (LRU).
      return Future<bool>.value(true);
    }

    // Web has no real `compute` isolate, so verify inline.
    if (kIsWeb) {
      final ok = schnorr.verifyEvent(event);
      if (ok) {
        _rememberVerified(computedId);
        onNewVerified?.call();
      }
      return Future<bool>.value(ok);
    }
    final completer = Completer<bool>();
    _pending.add(event);
    _pendingIds.add(computedId);
    _waiters.add(completer);
    if (_pending.length >= maxBatch) {
      _flush();
    } else if (!_flushScheduled) {
      _flushScheduled = true;
      // Defer so every event handed over in this turn lands in one batch.
      scheduleMicrotask(_flush);
    }
    return completer.future;
  }

  void _flush() {
    _flushScheduled = false;
    // Single-flight: later arrivals buffer and are re-flushed on completion.
    if (_inFlight || _pending.isEmpty) return;
    // Take at most [maxBatch] so a backlog crosses the isolate in bounded messages.
    final take = _pending.length <= maxBatch ? _pending.length : maxBatch;
    final batch = List<NostrEvent>.of(_pending.take(take));
    final ids = List<String>.of(_pendingIds.take(take));
    final waiters = List<Completer<bool>>.of(_waiters.take(take));
    _pending.removeRange(0, take);
    _pendingIds.removeRange(0, take);
    _waiters.removeRange(0, take);

    final payload = <Map<String, dynamic>>[
      for (final e in batch) e.toJson(),
    ];
    _inFlight = true;
    compute(verifyEventsBatch, payload).then((results) {
      // Guard positional alignment so a bad result length can never resolve to `true`.
      var anyNew = false;
      for (var i = 0; i < waiters.length; i++) {
        final ok = i < results.length && results[i] == true;
        if (ok) {
          _rememberVerified(ids[i]);
          anyNew = true;
        }
        if (!waiters[i].isCompleted) waiters[i].complete(ok);
      }
      if (anyNew) onNewVerified?.call();
    }).catchError((Object _) {
      // Fail closed: an isolate failure drops the whole batch.
      for (final w in waiters) {
        if (!w.isCompleted) w.complete(false);
      }
    }).whenComplete(() {
      _inFlight = false;
      if (_pending.isNotEmpty) _flush();
    });
  }
}

/// `compute` entry: one positional verdict per event; loads native libsecp256k1 in this isolate first.
Future<List<bool>> verifyEventsBatch(List<Map<String, dynamic>> events) async {
  await NativeSchnorr.ensureLoaded();
  final out = List<bool>.filled(events.length, false);
  for (var i = 0; i < events.length; i++) {
    try {
      out[i] = schnorr.verifyEvent(NostrEvent.fromJson(events[i]));
    } catch (_) {
      out[i] = false;
    }
  }
  return out;
}

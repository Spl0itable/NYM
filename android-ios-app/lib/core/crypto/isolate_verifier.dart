import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show compute, kIsWeb;

import '../../models/nostr_event.dart';
import 'schnorr.dart' as schnorr;

/// Off-main-thread BIP340 signature verification for inbound relay events.
///
/// The PWA pushes inbound `verifyEvent` into a dedicated `verify-worker.js`
/// (one `postMessage` per event) so a backfill/burst of relay EVENTs doesn't
/// block the render thread. This is the Flutter analog: it runs the same
/// `schnorr.verifyEvent` math inside a background isolate via `compute`.
///
/// The relay layer ([Subscription.onEvent]) verifies one event at a time and
/// awaits the result before deciding whether to keep or drop it, so the
/// `EventVerifier` contract is `Future<bool> Function(NostrEvent)`. Spawning a
/// fresh isolate per event would be far slower than verifying inline — the
/// whole point is to amortize that cost across a burst. So this verifier
/// *coalesces* every event submitted within the current event-loop turn into a
/// single batch and runs ONE `compute` over the batch, resolving each event's
/// own future with its own positional result.
///
/// Correctness guarantees (the caller's keep/drop/dedup logic is unchanged):
///   * Per-event verdicts. The batch is a pure positional map
///     `events[i] -> verifyEvent(events[i])`; event `i`'s future resolves to
///     result `i`. No event ever receives another event's verdict.
///   * No reordering / no drops here. Each `onEvent` still awaits its own
///     event and adds it to the stream exactly as before; this class never
///     reorders the events stream and never discards an event — only the
///     existing `if (!ok) return;` in [Subscription.onEvent] drops, on a
///     genuine verification failure.
///   * Fail closed. If the isolate hop throws for any reason, every event in
///     that batch resolves to `false` (treated as unverified and dropped),
///     never `true`. Mirrors the worker's `catch { ok = false }`.
class IsolateVerifier {
  IsolateVerifier({this.maxBatch = 256, this.verifiedCacheCap = 100000});

  /// Hard cap on events per `compute` payload. When the pending buffer reaches
  /// this size it is flushed immediately rather than waiting for the turn to
  /// end, bounding the size of any single cross-isolate message.
  final int maxBatch;

  /// Upper bound on the verified-id cache before oldest-first eviction.
  final int verifiedCacheCap;

  final List<NostrEvent> _pending = <NostrEvent>[];
  final List<String> _pendingIds = <String>[];
  final List<Completer<bool>> _waiters = <Completer<bool>>[];
  bool _flushScheduled = false;

  /// Ids of events whose BIP340 signature we have ALREADY verified this process.
  ///
  /// A Nostr event id is `sha256` of its serialized content, so an id uniquely
  /// binds the content: if we verified the signature for id X once, that exact
  /// content is valid forever. On boot/resume the relays REPLAY stored events
  /// matching our subscriptions, and pure-Dart BIP340 verification is ~12 ms
  /// EACH — a few hundred replayed events is multiple seconds of CPU that
  /// pegged the isolate pool and starved the main thread (the boot/resume
  /// slowness). Recomputing the id (sha256, ~20 µs) and checking this set lets a
  /// replay skip the 600×-costlier signature check while STILL proving the
  /// content binds to the id, so integrity is preserved.
  final LinkedHashSet<String> _verifiedIds = LinkedHashSet<String>();

  /// Seeds the verified-id cache with ids already known to be valid — e.g. the
  /// ids of messages restored from the local sqflite cache, which were verified
  /// when first received. Lets the cold-boot relay replay of already-cached
  /// history skip re-verification.
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

  void _evictVerified() {
    while (_verifiedIds.length > verifiedCacheCap) {
      _verifiedIds.remove(_verifiedIds.first);
    }
  }

  /// Verifies [event] off the main thread. Safe to call concurrently for many
  /// events; calls made in the same synchronous burst share one isolate hop.
  Future<bool> verify(NostrEvent event) {
    // Cheap main-isolate integrity gate (mirrors `schnorr.verifyEvent`'s own
    // preface): a malformed sig/pubkey, or content that doesn't hash to the
    // claimed id, fails immediately — never reaching the cache or the isolate.
    if (event.sig.length != 128 || event.pubkey.length != 64) {
      return Future<bool>.value(false);
    }
    final computedId = event.computeId();
    if (event.id.isNotEmpty && event.id != computedId) {
      return Future<bool>.value(false);
    }
    // Cache hit: this exact content already passed a full signature check.
    if (_verifiedIds.contains(computedId)) {
      _rememberVerified(computedId); // promote (LRU)
      return Future<bool>.value(true);
    }

    // On web there is no `compute` isolate (it runs synchronously on the main
    // thread anyway), so batching buys nothing and just adds latency — verify
    // inline. Native (where the jank lives) takes the batched isolate path.
    if (kIsWeb) {
      final ok = schnorr.verifyEvent(event);
      if (ok) _rememberVerified(computedId);
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
      // Defer to the end of the current microtask queue so every event the
      // relay layer hands us in this turn lands in one batch.
      scheduleMicrotask(_flush);
    }
    return completer.future;
  }

  void _flush() {
    _flushScheduled = false;
    if (_pending.isEmpty) return;
    // Detach the current buffer so events arriving while the isolate runs start
    // a fresh batch.
    final batch = List<NostrEvent>.of(_pending);
    final ids = List<String>.of(_pendingIds);
    final waiters = List<Completer<bool>>.of(_waiters);
    _pending.clear();
    _pendingIds.clear();
    _waiters.clear();

    final payload = <Map<String, dynamic>>[
      for (final e in batch) e.toJson(),
    ];
    compute(verifyEventsBatch, payload).then((results) {
      // Positional alignment is contractual; guard defensively so a malformed
      // result length can never resolve an event to `true` by accident.
      for (var i = 0; i < waiters.length; i++) {
        final ok = i < results.length && results[i] == true;
        // Cache a freshly-verified id so a later replay skips the isolate hop.
        if (ok) _rememberVerified(ids[i]);
        if (!waiters[i].isCompleted) waiters[i].complete(ok);
      }
    }).catchError((Object _) {
      // Fail closed: an isolate failure drops the whole batch (unverified),
      // never admits it.
      for (final w in waiters) {
        if (!w.isCompleted) w.complete(false);
      }
    });
  }
}

/// `compute` entry point: verifies a batch of events and returns one boolean
/// per event, in the SAME order as the input. Top-level + takes a single
/// sendable arg (a list of NIP-01 event maps) as `compute` requires.
///
/// Each verdict is independent and self-contained (`schnorr.verifyEvent`
/// recomputes the id from the event's own fields and checks the signature), so
/// a bad event in the batch can only fail its own slot.
List<bool> verifyEventsBatch(List<Map<String, dynamic>> events) {
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

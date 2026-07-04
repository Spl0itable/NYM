import 'dart:async';

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
  IsolateVerifier({this.maxBatch = 256});

  /// Hard cap on events per `compute` payload. When the pending buffer reaches
  /// this size it is flushed immediately rather than waiting for the turn to
  /// end, bounding the size of any single cross-isolate message.
  final int maxBatch;

  final List<NostrEvent> _pending = <NostrEvent>[];
  final List<Completer<bool>> _waiters = <Completer<bool>>[];
  bool _flushScheduled = false;

  /// Verifies [event] off the main thread. Safe to call concurrently for many
  /// events; calls made in the same synchronous burst share one isolate hop.
  Future<bool> verify(NostrEvent event) {
    // On web there is no `compute` isolate (it runs synchronously on the main
    // thread anyway), so batching buys nothing and just adds latency — verify
    // inline. Native (where the jank lives) takes the batched isolate path.
    if (kIsWeb) {
      return Future<bool>.value(schnorr.verifyEvent(event));
    }
    final completer = Completer<bool>();
    _pending.add(event);
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
    final waiters = List<Completer<bool>>.of(_waiters);
    _pending.clear();
    _waiters.clear();

    final payload = <Map<String, dynamic>>[
      for (final e in batch) e.toJson(),
    ];
    compute(verifyEventsBatch, payload).then((results) {
      // Positional alignment is contractual; guard defensively so a malformed
      // result length can never resolve an event to `true` by accident.
      for (var i = 0; i < waiters.length; i++) {
        final ok = i < results.length && results[i] == true;
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

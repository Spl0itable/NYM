import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show compute, kIsWeb, visibleForTesting;

import '../../models/nostr_event.dart';
import 'gift_wrap.dart' as giftwrap;
import 'keys.dart' as keys;

/// Off-main-thread NIP-59 gift-wrap **wrap** + **unwrap** for the local-key
/// paths. This is the Flutter analog of the PWA's `crypto-pool.js` (which pools
/// Web Workers running `nip59Wrap` / `bitchatWrap` / `unwrapGiftWrap`): the
/// secp256k1 ECDH + ChaCha20 + HMAC + JSON those ops do are CPU-bound and
/// previously ran synchronously on the main isolate, stalling the render thread
/// on PM backfill bursts (≤1000 wraps) and group send fan-out (one full wrap per
/// recipient).
///
/// ## Why `compute` (and not a persistent SendPort isolate)
/// [IsolateVerifier] — the existing template in this directory — batches inbound
/// signature verification and runs ONE `compute(verifyEventsBatch, batch)` per
/// event-loop turn, coalescing a whole burst into a single isolate hop. PoW
/// (`pow.dart`) and the globe decoders likewise use `compute`. This worker
/// follows that exact shape: a pending buffer that flushes on a microtask (or at
/// `maxBatch`), one `compute` over the batch, positional result mapping, and a
/// graceful **inline fallback** on web / on any isolate failure. `compute`
/// spawns one short-lived isolate per batch, but because a burst coalesces into
/// one batch that cost is amortized — the same trade-off `IsolateVerifier`
/// already accepts. A long-lived SendPort isolate would buy no extra throughput
/// here and is more invasive / riskier for crypto correctness, so we use the
/// simpler `compute` equivalent the plan explicitly permits.
///
/// ## Correctness contract (byte-identical to the synchronous path)
///   * The isolate entrypoints ([unwrapBatchIsolate], [wrapBatchIsolate]) call
///     the SAME pure functions the main isolate used — [giftwrap.unwrapGiftWrap]
///     for unwrap and [giftwrap.nip59Wrap] for wrap — so the produced bytes are
///     identical (modulo the per-wrap random nonce + backdated timestamp, which
///     are random on *both* paths anyway).
///   * Unwrap preserves per-candidate try/next-candidate semantics and the
///     "skip a wrap that fails to decrypt" (→ null) behavior, because that logic
///     lives inside [giftwrap.unwrapGiftWrap] which is what the isolate runs.
///   * Only the **local-key** path moves. The NIP-46 remote-signer seal/unwrap
///     stays on its existing network path (the call sites branch before reaching
///     this worker). Key BYTES are passed into the isolate as part of the
///     payload (isolates do not share memory); no secure-storage / plugin call
///     happens inside the isolate.

// ---------------------------------------------------------------------------
// Payload codec: (wrap, candidate keys) <-> a single sendable JSON-able map.
// `compute` requires the argument + result be sendable across the isolate
// boundary; we use plain maps / lists / hex strings (key bytes as hex) so the
// payload survives the default message copy on every platform.
// ---------------------------------------------------------------------------

/// One unwrap request: the kind-1059 wrap event JSON + the ordered candidate
/// identities (secret-key hex + per-key bitchat flag), exactly as
/// [giftwrap.unwrapGiftWrap] consumes them.
Map<String, dynamic> _encodeUnwrapJob(
  NostrEvent wrap,
  List<giftwrap.UnwrapCandidate> candidates,
) =>
    {
      'wrap': wrap.toJson(),
      'cands': [
        for (final c in candidates)
          {'sk': keys.bytesToHex(c.sk), 'bc': c.bitchat},
      ],
    };

List<giftwrap.UnwrapCandidate> _decodeCandidates(Object? raw) {
  final out = <giftwrap.UnwrapCandidate>[];
  for (final c in (raw as List).cast<Map<String, dynamic>>()) {
    out.add((
      sk: keys.hexToBytes(c['sk'] as String),
      bitchat: c['bc'] as bool,
    ));
  }
  return out;
}

/// One wrap request: the rumor fields + sender secret-key hex + recipient +
/// optional expiration. The ephemeral wrap key is generated INSIDE the isolate
/// by [giftwrap.nip59Wrap] (via `generatePrivateKey`), so no key/randomness for
/// the wrap layer ever crosses back to the main isolate.
Map<String, dynamic> _encodeWrapJob({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required String recipientPubkey,
  int? expiration,
}) =>
    {
      'rumor': rumor.toJson(),
      'sk': keys.bytesToHex(senderPrivkey),
      'rcpt': recipientPubkey,
      if (expiration != null) 'exp': expiration,
    };

// ---------------------------------------------------------------------------
// Isolate entrypoints (top-level + single sendable arg, as `compute` requires).
// These are also the unit-test seam: they are pure functions of their input and
// can be driven directly without an isolate.
// ---------------------------------------------------------------------------

/// `compute` entry point for a batch of unwrap jobs. Returns one result per
/// job, positionally aligned with the input: each entry is either the decoded
/// `{seal, rumor, isBitchat}` (as a JSON-able map) or `null` when no candidate
/// could decrypt that wrap (a skip — never a throw).
///
/// A failure in one job can only null *its own* slot: each job runs an
/// independent [giftwrap.unwrapGiftWrap] in its own try/catch.
Future<List<Map<String, dynamic>?>> unwrapBatchIsolate(
  List<Map<String, dynamic>> jobs,
) async {
  final out = List<Map<String, dynamic>?>.filled(jobs.length, null);
  for (var i = 0; i < jobs.length; i++) {
    try {
      final job = jobs[i];
      final wrap = NostrEvent.fromJson(job['wrap'] as Map<String, dynamic>);
      final cands = _decodeCandidates(job['cands']);
      final res = await giftwrap.unwrapGiftWrap(wrap, cands);
      if (res != null) {
        out[i] = {
          'seal': res.seal.toJson(),
          'rumor': res.rumor,
          'isBitchat': res.isBitchat,
        };
      }
    } catch (_) {
      // A malformed job nulls only its own slot (treated as undecryptable),
      // never another job's — mirrors the per-candidate skip semantics.
      out[i] = null;
    }
  }
  return out;
}

/// `compute` entry point for a batch of wrap jobs (e.g. a whole group-fanout
/// recipient list shipped in one hop). Returns one signed kind-1059 wrap JSON
/// per job, positionally aligned with the input. A job that throws yields a
/// `null` slot so the caller can skip exactly that recipient.
List<Map<String, dynamic>?> wrapBatchIsolate(
  List<Map<String, dynamic>> jobs,
) {
  final out = List<Map<String, dynamic>?>.filled(jobs.length, null);
  for (var i = 0; i < jobs.length; i++) {
    try {
      final job = jobs[i];
      final rumorMap = job['rumor'] as Map<String, dynamic>;
      final rumor = UnsignedEvent(
        pubkey: rumorMap['pubkey'] as String,
        createdAt: (rumorMap['created_at'] as num).toInt(),
        kind: (rumorMap['kind'] as num).toInt(),
        tags: ((rumorMap['tags'] as List?) ?? const [])
            .map((t) => (t as List).map((e) => e.toString()).toList())
            .toList(),
        content: (rumorMap['content'] ?? '') as String,
      );
      final wrap = giftwrap.nip59Wrap(
        rumor: rumor,
        senderPrivkey: keys.hexToBytes(job['sk'] as String),
        recipientPubkey: job['rcpt'] as String,
        expiration: job['exp'] as int?,
      );
      out[i] = wrap.toJson();
    } catch (_) {
      out[i] = null;
    }
  }
  return out;
}

/// The decoded result of one unwrap, in the same record shape
/// [giftwrap.unwrapGiftWrap] returns, so call sites are drop-in.
typedef UnwrapResult = ({
  NostrEvent seal,
  Map<String, dynamic> rumor,
  bool isBitchat,
});

UnwrapResult? _decodeUnwrapResult(Map<String, dynamic>? m) {
  if (m == null) return null;
  return (
    seal: NostrEvent.fromJson(m['seal'] as Map<String, dynamic>),
    rumor: (m['rumor'] as Map).cast<String, dynamic>(),
    isBitchat: m['isBitchat'] as bool,
  );
}

// ---------------------------------------------------------------------------
// CryptoWorker: the batched, lazily-spawned facade the service talks to.
// ---------------------------------------------------------------------------

/// Batched off-main-thread gift-wrap worker. Mirrors [IsolateVerifier]'s
/// lifecycle: lazy (nothing spawns until the first call), coalesce every request
/// submitted in a synchronous burst into one isolate hop, cap the per-hop batch
/// size, and fall back to the inline synchronous path on web (where `compute`
/// runs on the main isolate anyway) or if the isolate hop throws.
class CryptoWorker {
  CryptoWorker({this.maxBatch = 128});

  /// Process-wide instance, the direct analog of the PWA's single shared
  /// `crypto-pool.js`. Both the inbound (unwrap) and outbound (wrap) paths route
  /// through it so a burst across them coalesces.
  static final CryptoWorker instance = CryptoWorker();

  /// Hard cap on jobs per `compute` payload; reaching it flushes immediately so
  /// no single cross-isolate message grows unbounded under a large backfill.
  final int maxBatch;

  // --- unwrap (inbound) batching --------------------------------------------
  final List<Map<String, dynamic>> _unwrapPending = <Map<String, dynamic>>[];
  final List<Completer<UnwrapResult?>> _unwrapWaiters =
      <Completer<UnwrapResult?>>[];
  bool _unwrapFlushScheduled = false;

  /// Unwraps [wrap] against [candidates] off the main thread, returning the
  /// recovered `{seal, rumor, isBitchat}` or null if no candidate decrypts it
  /// (a skip — identical to the synchronous [giftwrap.unwrapGiftWrap]).
  Future<UnwrapResult?> unwrap(
    NostrEvent wrap,
    List<giftwrap.UnwrapCandidate> candidates,
  ) {
    // On web `compute` has no real isolate (it runs on the main thread), so
    // batching only adds latency — run the existing path inline.
    if (kIsWeb) {
      return giftwrap.unwrapGiftWrap(wrap, candidates);
    }
    final completer = Completer<UnwrapResult?>();
    _unwrapPending.add(_encodeUnwrapJob(wrap, candidates));
    _unwrapWaiters.add(completer);
    if (_unwrapPending.length >= maxBatch) {
      _flushUnwrap();
    } else if (!_unwrapFlushScheduled) {
      _unwrapFlushScheduled = true;
      scheduleMicrotask(_flushUnwrap);
    }
    return completer.future;
  }

  void _flushUnwrap() {
    _unwrapFlushScheduled = false;
    if (_unwrapPending.isEmpty) return;
    final batch = List<Map<String, dynamic>>.of(_unwrapPending);
    final waiters = List<Completer<UnwrapResult?>>.of(_unwrapWaiters);
    _unwrapPending.clear();
    _unwrapWaiters.clear();

    compute(unwrapBatchIsolate, batch).then((results) {
      for (var i = 0; i < waiters.length; i++) {
        final m = i < results.length ? results[i] : null;
        if (!waiters[i].isCompleted) {
          waiters[i].complete(_decodeUnwrapResult(m));
        }
      }
    }).catchError((Object _) {
      // Isolate failure: fall back to the inline synchronous unwrap so a wrap is
      // never silently dropped just because the isolate hop failed. Each job
      // re-runs the SAME pure function the isolate would have.
      _fallbackUnwrap(batch, waiters);
    });
  }

  void _fallbackUnwrap(
    List<Map<String, dynamic>> batch,
    List<Completer<UnwrapResult?>> waiters,
  ) {
    for (var i = 0; i < waiters.length; i++) {
      final w = waiters[i];
      if (w.isCompleted) continue;
      try {
        final job = batch[i];
        final wrap = NostrEvent.fromJson(job['wrap'] as Map<String, dynamic>);
        final cands = _decodeCandidates(job['cands']);
        giftwrap.unwrapGiftWrap(wrap, cands).then((res) {
          if (!w.isCompleted) w.complete(res);
        }).catchError((Object _) {
          if (!w.isCompleted) w.complete(null);
        });
      } catch (_) {
        if (!w.isCompleted) w.complete(null);
      }
    }
  }

  // --- wrap (outbound) ------------------------------------------------------
  /// Wraps [rumor] to each pubkey in [recipientPubkeys] with the local
  /// [senderPrivkey], shipping the WHOLE recipient list in one isolate hop and
  /// looping inside the isolate (the group fan-out win). Returns the signed
  /// kind-1059 wraps positionally aligned with [recipientPubkeys]; a slot is
  /// null only if that recipient's wrap failed (so the caller skips it).
  ///
  /// The ephemeral wrap key for each recipient is generated inside the isolate.
  Future<List<NostrEvent?>> wrapMany({
    required UnsignedEvent rumor,
    required Uint8List senderPrivkey,
    required List<String> recipientPubkeys,
    int? expiration,
  }) async {
    if (recipientPubkeys.isEmpty) return const <NostrEvent?>[];
    final jobs = <Map<String, dynamic>>[
      for (final pk in recipientPubkeys)
        _encodeWrapJob(
          rumor: rumor,
          senderPrivkey: senderPrivkey,
          recipientPubkey: pk,
          expiration: expiration,
        ),
    ];

    List<Map<String, dynamic>?> results;
    if (kIsWeb) {
      // No real isolate on web: run the same entrypoint inline.
      results = wrapBatchIsolate(jobs);
    } else {
      try {
        results = await compute(wrapBatchIsolate, jobs);
      } catch (_) {
        // Isolate failure: produce the wraps inline (same pure function).
        results = wrapBatchIsolate(jobs);
      }
    }
    return [
      for (final m in results)
        m == null ? null : NostrEvent.fromJson(m),
    ];
  }

  /// Single-recipient convenience over [wrapMany].
  Future<NostrEvent?> wrapOne({
    required UnsignedEvent rumor,
    required Uint8List senderPrivkey,
    required String recipientPubkey,
    int? expiration,
  }) async {
    final out = await wrapMany(
      rumor: rumor,
      senderPrivkey: senderPrivkey,
      recipientPubkeys: [recipientPubkey],
      expiration: expiration,
    );
    return out.isEmpty ? null : out.first;
  }
}

/// Exposed only so a unit test can exercise the JSON payload round-trip without
/// reaching into private helpers. Not used in production code.
@visibleForTesting
Map<String, dynamic> debugEncodeUnwrapJob(
  NostrEvent wrap,
  List<giftwrap.UnwrapCandidate> candidates,
) =>
    _encodeUnwrapJob(wrap, candidates);

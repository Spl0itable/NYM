import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show compute, kIsWeb, visibleForTesting;

import '../../models/nostr_event.dart';
import 'gift_wrap.dart' as giftwrap;
import 'native_schnorr.dart';
import 'keys.dart' as keys;

/// Batched off-main NIP-59 wrap/unwrap for local keys, running the same pure functions as the inline path.

// Payloads are plain maps with hex keys so they survive the isolate message copy.

/// One unwrap job: wrap JSON plus ordered candidates (sk hex, bitchat flag, optional ML-KEM keypair).
Map<String, dynamic> _encodeUnwrapJob(
  NostrEvent wrap,
  List<giftwrap.UnwrapCandidate> candidates,
) =>
    {
      'wrap': wrap.toJson(),
      'cands': [
        for (final c in candidates)
          {
            'sk': keys.bytesToHex(c.sk),
            'bc': c.bitchat,
            if (c.kemSk != null) 'ksk': keys.bytesToHex(c.kemSk!),
            if (c.kemPk != null) 'kpk': keys.bytesToHex(c.kemPk!),
          },
      ],
    };

List<giftwrap.UnwrapCandidate> _decodeCandidates(Object? raw) {
  final out = <giftwrap.UnwrapCandidate>[];
  for (final c in (raw as List).cast<Map<String, dynamic>>()) {
    final ksk = c['ksk'] as String?;
    final kpk = c['kpk'] as String?;
    out.add((
      sk: keys.hexToBytes(c['sk'] as String),
      bitchat: c['bc'] as bool,
      kemSk: ksk == null ? null : keys.hexToBytes(ksk),
      kemPk: kpk == null ? null : keys.hexToBytes(kpk),
    ));
  }
  return out;
}

/// One wrap job; the ephemeral wrap key is generated inside the isolate.
Map<String, dynamic> _encodeWrapJob({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required String recipientPubkey,
  int? expiration,
  Uint8List? recipientKemPk,
  bool layered = false,
}) =>
    {
      'rumor': rumor.toJson(),
      'sk': keys.bytesToHex(senderPrivkey),
      'rcpt': recipientPubkey,
      if (expiration != null) 'exp': expiration,
      // Per-recipient payload format, so one fan-out can mix both.
      if (layered) 'l2': 1,
      // Present only when the recipient announced an ML-KEM key; selects the hybrid wrap per job.
      if (recipientKemPk != null) 'rkem': keys.bytesToHex(recipientKemPk),
    };

/// `compute` entry for unwrap jobs: one positional `{seal, rumor, isBitchat, isPq}` or null per job.
Future<List<Map<String, dynamic>?>> unwrapBatchIsolate(
  List<Map<String, dynamic>> jobs,
) async {
  // Load native libsecp256k1 in this worker isolate; falls back to pure Dart.
  await NativeSchnorr.ensureLoaded();
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
          'isPq': res.isPq,
        };
      }
    } catch (_) {
      // A malformed job nulls only its own slot.
      out[i] = null;
    }
  }
  return out;
}

/// `compute` entry for wrap jobs: one positional signed wrap JSON per job, or null if that job threw.
// Async for the layered format's ChaCha20-Poly1305; still one isolate hop.
Future<List<Map<String, dynamic>?>> wrapBatchIsolate(
  List<Map<String, dynamic>> jobs,
) async {
  // Native signing for the seal/wrap layers in this worker isolate.
  await NativeSchnorr.ensureLoaded();
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
      final senderPrivkey = keys.hexToBytes(job['sk'] as String);
      final recipientPubkey = job['rcpt'] as String;
      final expiration = job['exp'] as int?;
      final rkem = job['rkem'] as String?;
      final NostrEvent wrap;
      if (rkem == null) {
        wrap = giftwrap.nip59Wrap(
          rumor: rumor,
          senderPrivkey: senderPrivkey,
          recipientPubkey: recipientPubkey,
          expiration: expiration,
        );
      } else if (job['l2'] == 1) {
        wrap = await giftwrap.pq2Nip59Wrap(
          rumor: rumor,
          senderPrivkey: senderPrivkey,
          recipientPubkey: recipientPubkey,
          recipientKemPublicKey: keys.hexToBytes(rkem),
          expiration: expiration,
        );
      } else {
        wrap = giftwrap.pqNip59Wrap(
          rumor: rumor,
          senderPrivkey: senderPrivkey,
          recipientPubkey: recipientPubkey,
          recipientKemPublicKey: keys.hexToBytes(rkem),
          expiration: expiration,
        );
      }
      out[i] = wrap.toJson();
    } catch (_) {
      out[i] = null;
    }
  }
  return out;
}

/// Same record shape as [giftwrap.unwrapGiftWrap] returns.
typedef UnwrapResult = ({
  NostrEvent seal,
  Map<String, dynamic> rumor,
  bool isBitchat,
  bool isPq,
});

UnwrapResult? _decodeUnwrapResult(Map<String, dynamic>? m) {
  if (m == null) return null;
  return (
    seal: NostrEvent.fromJson(m['seal'] as Map<String, dynamic>),
    rumor: (m['rumor'] as Map).cast<String, dynamic>(),
    isBitchat: m['isBitchat'] as bool,
    // Payloads from before the PQ flag default to false.
    isPq: m['isPq'] as bool? ?? false,
  );
}

/// Batched gift-wrap worker like [IsolateVerifier]; runs inline on web or when the isolate hop fails.
class CryptoWorker {
  CryptoWorker({this.maxBatch = 128});

  /// Process-wide instance so inbound and outbound bursts coalesce.
  static final CryptoWorker instance = CryptoWorker();

  /// Max jobs per `compute` payload; reaching it flushes immediately.
  final int maxBatch;

  final List<Map<String, dynamic>> _unwrapPending = <Map<String, dynamic>>[];
  final List<Completer<UnwrapResult?>> _unwrapWaiters =
      <Completer<UnwrapResult?>>[];
  bool _unwrapFlushScheduled = false;

  /// Unwraps [wrap] off the main thread; null when no candidate decrypts it.
  Future<UnwrapResult?> unwrap(
    NostrEvent wrap,
    List<giftwrap.UnwrapCandidate> candidates,
  ) {
    // Web has no real isolate, so run inline.
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
      // Isolate failure: fall back inline so a wrap is never silently dropped.
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

  /// Wraps [rumor] for every recipient in one isolate hop; [recipientKemPks] selects hybrid wraps; null slots failed.
  Future<List<NostrEvent?>> wrapMany({
    required UnsignedEvent rumor,
    required Uint8List senderPrivkey,
    required List<String> recipientPubkeys,
    int? expiration,
    Map<String, Uint8List>? recipientKemPks,
    Set<String>? layeredPubkeys,
  }) async {
    if (recipientPubkeys.isEmpty) return const <NostrEvent?>[];
    final jobs = <Map<String, dynamic>>[
      for (final pk in recipientPubkeys)
        _encodeWrapJob(
          rumor: rumor,
          senderPrivkey: senderPrivkey,
          recipientPubkey: pk,
          expiration: expiration,
          recipientKemPk: recipientKemPks?[pk],
          layered: layeredPubkeys?.contains(pk) ?? false,
        ),
    ];

    List<Map<String, dynamic>?> results;
    if (kIsWeb) {
      // No real isolate on web: run the same entrypoint inline.
      results = await wrapBatchIsolate(jobs);
    } else {
      try {
        results = await compute(wrapBatchIsolate, jobs);
      } catch (_) {
        // Isolate failure: produce the wraps inline.
        results = await wrapBatchIsolate(jobs);
      }
    }
    return [
      for (final m in results) m == null ? null : NostrEvent.fromJson(m),
    ];
  }

  Future<NostrEvent?> wrapOne({
    required UnsignedEvent rumor,
    required Uint8List senderPrivkey,
    required String recipientPubkey,
    int? expiration,
    Uint8List? recipientKemPk,
    bool layered = false,
  }) async {
    final out = await wrapMany(
      rumor: rumor,
      senderPrivkey: senderPrivkey,
      recipientPubkeys: [recipientPubkey],
      expiration: expiration,
      recipientKemPks:
          recipientKemPk == null ? null : {recipientPubkey: recipientKemPk},
      layeredPubkeys: layered ? {recipientPubkey} : null,
    );
    return out.isEmpty ? null : out.first;
  }
}

/// Exposes the payload round-trip for tests.
@visibleForTesting
Map<String, dynamic> debugEncodeUnwrapJob(
  NostrEvent wrap,
  List<giftwrap.UnwrapCandidate> candidates,
) =>
    _encodeUnwrapJob(wrap, candidates);

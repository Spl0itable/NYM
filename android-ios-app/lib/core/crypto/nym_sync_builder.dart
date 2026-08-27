// Off-main-isolate builders for the SELF-ADDRESSED `nym-sync` publishes —
// the settings/history sync's relay gift wrap (`publishNymSyncWrap`) and its
// D1 blob (`StorageSync._encryptToSelf`).
//
// A CPU profile of a live session put these publishes at ~13% of ALL
// main-isolate CPU during a catch-up: each one runs ML-KEM encapsulation
// (~2.7 ms of pure-Dart Keccak), ChaCha20+HMAC over up to ~28 KB, sha256
// hashing, and (pre-native) ECDH + pubkey derivation — and the 5s-debounced
// sync re-fires them for every changed category while messages stream in,
// which reads as the recurring scroll stutter. A LOCAL-key account needs
// none of that on the main isolate: these entrypoints run the exact same
// construction inside `compute`, and the service falls back to the inline
// signer path for NIP-46/extension accounts (whose signing is a remote call
// anyway) or if the isolate hop fails.
//
// The construction MIRRORS `NostrService.publishNymSyncWrap` (and
// `StorageSync._encryptToSelf`) byte-for-byte in formats and size gates; the
// unit tests in test/nym_sync_builder_test.dart round-trip both layers
// against the normal decrypt paths.

import 'dart:convert';
import 'dart:typed_data';

import '../constants/event_kinds.dart';
import 'gift_wrap.dart' as giftwrap;
import 'keys.dart' as keys;
import 'native_schnorr.dart';
import 'nip44.dart' as nip44;
import 'pq.dart' as pq;
import 'schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';

/// Job map keys (a Map crosses the isolate boundary like the other
/// crypto_worker jobs): `sk` (hex privkey), `self` (pubkey hex), `rumorJson`
/// (the ≤65535-byte rumor, already gated by the caller), `outerD` (outer
/// d-tag digest), `kemPk` (ML-KEM public key bytes, or absent for classical).
///
/// Returns the wrap event's JSON map, or null when a size gate rejected both
/// the hybrid and the classical form (same contract as the inline path).
Future<Map<String, dynamic>?> buildNymSyncWrapIsolate(
    Map<String, dynamic> job) async {
  await NativeSchnorr.ensureLoaded();
  final sk = keys.hexToBytes(job['sk'] as String);
  final self = job['self'] as String;
  final rumorJson = job['rumorJson'] as String;
  final outerD = job['outerD'] as String;
  final kemPk = job['kemPk'] as Uint8List?;

  // Both layers with whichever encryption is in play — the same `build`
  // closure as publishNymSyncWrap, with the LocalSigner inlined (seal =
  // finalizeEvent with the local key; inner NIP-44 = conversation key to
  // self).
  Future<Map<String, dynamic>?> build(
    Future<String> Function(String plaintext) seal,
    Future<String> Function(String plaintext, Uint8List ephSk) wrap,
  ) async {
    final sealed = schnorr.finalizeEvent(
      UnsignedEvent(
        pubkey: self,
        createdAt: giftwrap.randomNow(),
        kind: 13,
        tags: const [],
        content: await seal(rumorJson),
      ),
      sk,
    );
    final sealJson = jsonEncode(sealed.toJson());
    if (utf8.encode(sealJson).length > 65535) return null;
    final ephSk = keys.generatePrivateKey();
    final wrapped = schnorr.finalizeEvent(
      UnsignedEvent(
        pubkey: keys.getPublicKeyHex(ephSk),
        createdAt: giftwrap.randomNow(),
        kind: EventKind.giftWrap,
        tags: [
          ['p', self],
          ['d', outerD],
          ['k', 'nym-sync'],
        ],
        content: await wrap(sealJson, ephSk),
      ),
      ephSk,
    );
    final json = wrapped.toJson();
    if (jsonEncode(['EVENT', json]).length > 65000) return null;
    return json;
  }

  String nip44ToSelf(String pt) =>
      nip44.encrypt(pt, nip44.getConversationKey(sk, self));

  if (kemPk != null) {
    final wrapped = await build(
      (pt) async => pq.pq2Seal(nip44ToSelf(pt), self, self, kemPk),
      (pt, ephSk) => pq.pq2Encrypt(pt, ephSk, self, kemPk),
    );
    if (wrapped != null) return wrapped;
    // Oversized hybrid → classical fallback, same trade as the inline path.
  }
  return build(
    (pt) async => nip44ToSelf(pt),
    (pt, ephSk) async =>
        nip44.encrypt(pt, nip44.getConversationKey(ephSk, self)),
  );
}

/// The WRAP layer alone, for accounts whose SEAL comes from a remote signer
/// (NIP-46 / extension): the kind-1059 layer is keyed by a throwaway key we
/// generate here, so it never needs the identity key and can always run off
/// the main isolate. Job keys: `sealJson` (the signed seal event's JSON,
/// already ≤65535 — the caller gates it), `self`, `outerD`, `kemPk` (bytes,
/// or absent for the classical layer). Returns the wrap event's JSON map, or
/// null when the final frame exceeds the relay gate.
Future<Map<String, dynamic>?> wrapNymSyncSealIsolate(
    Map<String, dynamic> job) async {
  await NativeSchnorr.ensureLoaded();
  final sealJson = job['sealJson'] as String;
  final self = job['self'] as String;
  final outerD = job['outerD'] as String;
  final kemPk = job['kemPk'] as Uint8List?;
  final ephSk = keys.generatePrivateKey();
  final content = kemPk != null
      ? await pq.pq2Encrypt(sealJson, ephSk, self, kemPk)
      : nip44.encrypt(sealJson, nip44.getConversationKey(ephSk, self));
  final wrapped = schnorr.finalizeEvent(
    UnsignedEvent(
      pubkey: keys.getPublicKeyHex(ephSk),
      createdAt: giftwrap.randomNow(),
      kind: EventKind.giftWrap,
      tags: [
        ['p', self],
        ['d', outerD],
        ['k', 'nym-sync'],
      ],
      content: content,
    ),
    ephSk,
  );
  final json = wrapped.toJson();
  if (jsonEncode(['EVENT', json]).length > 65000) return null;
  return json;
}

/// The D1-blob counterpart: `_encryptToSelf` for a LOCAL key. Job keys: `sk`
/// (hex), `self`, `plaintext`, `kemPk` (bytes, present only when the hybrid
/// seal is wanted — the caller already applied the allowPq/_pqSealToSelf
/// gates). Returns the ciphertext, or null on failure (caller falls back to
/// the inline path).
Future<String?> encryptToSelfIsolate(Map<String, dynamic> job) async {
  await NativeSchnorr.ensureLoaded();
  try {
    final sk = keys.hexToBytes(job['sk'] as String);
    final self = job['self'] as String;
    final plaintext = job['plaintext'] as String;
    final kemPk = job['kemPk'] as Uint8List?;
    final inner = nip44.encrypt(
        plaintext, nip44.getConversationKey(sk, self));
    if (kemPk != null) {
      try {
        return await pq.pq2Seal(inner, self, self, kemPk);
      } catch (_) {
        // Fall through to NIP-44 rather than losing the write — mirrors
        // _encryptToSelf.
      }
    }
    return inner;
  } catch (_) {
    return null;
  }
}

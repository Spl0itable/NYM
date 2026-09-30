/// Custody of the post-quantum root secret: display form, device wraps, settings record, and adoption (docs/PQ-ROOT-SPEC.md).
library;

import 'dart:convert';
import 'dart:typed_data';


import '../../core/crypto/bech32_codec.dart';
import '../../core/crypto/pq.dart' as pq;

/// Settings category for the wraps; never sealed to the root-derived key, which would be a circular lock (spec §5.1).
const String pqRootCategory = 'nymchat-pq-root';

/// Wrap salt: 16 random bytes, stored in the clear beside the wrap.
const int pqRootSaltLength = 16;

// Mobile implements only the manual code path; passkey wraps need platform PRF and are parsed but ignored.
const String pqRootWrapPasskey = 'passkey';

/// The root's `nympq1…` display form; key material, treat it like the nsec.
String pqRootToCode(Uint8List root) => encodeNymPq(root);

const String pqRootLegacySlot = 'legacy';

final RegExp _pubkeyHex = RegExp(r'^[0-9a-f]{64}$');

class PqRootStore {
  const PqRootStore({
    this.byPubkey = const {},
    this.legacy,
    this.unreadable = false,
  });

  final Map<String, String> byPubkey;
  final String? legacy;
  final bool unreadable;

  bool get isEmpty => byPubkey.isEmpty && legacy == null;

  String? codeFor(String? pubkey) => pubkey == null ? null : byPubkey[pubkey];

  PqRootStore withCode(String pubkey, String code, {bool dropLegacy = false}) =>
      PqRootStore(
        byPubkey: {...byPubkey, pubkey: code},
        legacy: dropLegacy ? null : legacy,
        unreadable: false,
      );

  PqRootStore withoutLegacy() =>
      PqRootStore(byPubkey: byPubkey, legacy: null, unreadable: unreadable);

  String? encode() {
    if (isEmpty) return null;
    final out = <String, String>{...byPubkey};
    if (legacy != null) out[pqRootLegacySlot] = legacy!;
    return jsonEncode(out);
  }

  static PqRootStore parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const PqRootStore();
    final s = raw.trim();
    if (s.startsWith('{')) {
      try {
        final decoded = jsonDecode(s);
        if (decoded is! Map) return const PqRootStore(unreadable: true);
        final by = <String, String>{};
        String? legacy;
        for (final e in decoded.entries) {
          final k = e.key.toString();
          final v = e.value;
          if (v is! String || v.isEmpty) continue;
          if (k == pqRootLegacySlot) {
            legacy = v;
          } else if (_pubkeyHex.hasMatch(k)) {
            by[k] = v;
          }
        }
        return PqRootStore(byPubkey: by, legacy: legacy);
      } catch (_) {
        return const PqRootStore(unreadable: true);
      }
    }
    if (pqRootFromCode(s) == null) return const PqRootStore(unreadable: true);
    return PqRootStore(legacy: s);
  }
}

/// Parses a `nympq1…` code, or null on wrong HRP, checksum or length.
Uint8List? pqRootFromCode(String code) {
  try {
    final bytes = decodeNymPq(code);
    if (bytes.length != pq.pqRootLength) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}

/// Whether [root] reproduces the announced key at [epoch] or one of the three before it.
bool pqRootMatchesAnnouncedKey(
  Uint8List root,
  Uint8List announcedKemPublicKey,
  int epoch,
) {
  for (var e = epoch; e >= 0 && e > epoch - 4; e--) {
    final pk = pq.pqKeypairFromRoot(root, e).publicKey;
    if (pk.length != announcedKemPublicKey.length) continue;
    var same = true;
    for (var i = 0; i < pk.length; i++) {
      if (pk[i] != announcedKemPublicKey[i]) {
        same = false;
        break;
      }
    }
    if (same) return true;
  }
  return false;
}

/// One recovery path: AES-GCM-256 ciphertext plus public KDF parameters in the vault's `enc:v1:` envelope.
class PqRootWrap {
  const PqRootWrap({
    required this.type,
    required this.blob,
    this.salt,
    this.iterations,
    this.extra = const {},
  });

  /// [pqRootWrapPasskey], or a future type.
  final String type;

  /// `enc:v1:<b64 iv>:<b64 ciphertext||tag>`.
  final String blob;

  /// Base64 of the 16 KDF salt bytes; public (spec §5).
  final String? salt;

  /// Explicit so a future raise stays readable by an older build.
  final int? iterations;

  /// Unknown fields, kept so a rewrite can't drop another client's path.
  final Map<String, dynamic> extra;

  Map<String, dynamic> toJson() => {
        ...extra,
        'type': type,
        if (salt != null) 'salt': salt,
        if (iterations != null) 'iter': iterations,
        'blob': blob,
      };

  static PqRootWrap? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    final blob = raw['blob'];
    if (type is! String || type.isEmpty) return null;
    if (blob is! String || blob.isEmpty) return null;
    final extra = <String, dynamic>{
      for (final e in raw.entries)
        if (e.key != 'type' && e.key != 'salt' && e.key != 'iter' &&
            e.key != 'blob')
          e.key.toString(): e.value,
    };
    return PqRootWrap(
      type: type,
      blob: blob,
      salt: raw['salt'] is String ? raw['salt'] as String : null,
      iterations: raw['iter'] is int ? raw['iter'] as int : null,
      extra: extra,
    );
  }
}

/// Its existence stops a second device generating a rival root (spec §6), so empty [wraps] is still valid.
class PqRootRecord {
  const PqRootRecord({this.wraps = const [], this.version = 2, this.fp});

  /// Builds the record for [root], stamping its fingerprint.
  factory PqRootRecord.forRoot(Uint8List root,
          {List<PqRootWrap> wraps = const []}) =>
      PqRootRecord(wraps: wraps, fp: pq.pqRootFingerprint(root));

  final List<PqRootWrap> wraps;
  final int version;

  /// Root fingerprint; required, since the PWA treats a record without one as absent and would fork the root.
  final String? fp;

  /// Matches the PWA's `_pqRootValidRecord`, so both apps accept the same payloads.
  bool get isValid => version == 2 && fp != null && fp!.isNotEmpty;

  bool matches(Uint8List root) =>
      fp != null && pq.pqRootFingerprint(root) == fp;

  bool get isEmpty => wraps.isEmpty;

  PqRootWrap? wrapOfType(String type) {
    for (final w in wraps) {
      if (w.type == type) return w;
    }
    return null;
  }

  /// Replaces any wrap of the same type, keeping every other path.
  PqRootRecord withWrap(PqRootWrap wrap) => PqRootRecord(
        version: version,
        fp: fp,
        wraps: [
          for (final w in wraps)
            if (w.type != wrap.type) w,
          wrap,
        ],
      );

  Map<String, dynamic> toJson() => {
        'v': version,
        if (fp != null) 'fp': fp,
        'wraps': [for (final w in wraps) w.toJson()],
        'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };

  /// Null only when the payload isn't a record; a record with no usable wraps still parses.
  static PqRootRecord? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final rawWraps = raw['wraps'];
    if (rawWraps != null && rawWraps is! List) return null;
    if (raw['v'] == null && rawWraps == null) return null;
    final wraps = <PqRootWrap>[];
    if (rawWraps is List) {
      for (final w in rawWraps) {
        final parsed = PqRootWrap.fromJson(w);
        if (parsed != null) wraps.add(parsed);
      }
    }
    return PqRootRecord(
      wraps: wraps,
      version: raw['v'] is int ? raw['v'] as int : 2,
      fp: raw['fp'] is String && (raw['fp'] as String).isNotEmpty
          ? raw['fp'] as String
          : null,
    );
  }

  String encode() => jsonEncode(toJson());

  static PqRootRecord? decode(String json) {
    try {
      return fromJson(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }
}

/// What a booting device should do about the root (spec §6).
enum PqRootAction {
  /// Nothing, and specifically not generate.
  wait,

  /// We hold the root and the record is in place.
  ready,

  /// We hold the root but no record exists; republish it.
  publishRecord,

  /// A record exists that nothing we hold opens: stay silent (§7) and prompt.
  awaitLink,

  /// No record exists: generate, publish, adopt, announce.
  generate,
}

/// The §6 decision, where question order is the safety property; not gated on a local nsec or durable login, matching the PWA.
PqRootAction pqRootDecide({
  required bool recordLoadSucceeded,
  required bool recordPresent,
  required bool holdRoot,
  bool throwawayKeypair = false,
  bool recordMatchesHeldRoot = true,
  bool recordReadable = true,
}) {
  // A keypair regenerated every launch has nothing to carry forward.
  if (throwawayKeypair) return PqRootAction.wait;
  // A read that didn't complete proves nothing either way.
  if (!recordLoadSucceeded) return PqRootAction.wait;
  if (recordPresent) {
    if (!recordReadable) return PqRootAction.awaitLink;
    // A stale root from a reset identity opens nothing, so it is the §6.3 case like an empty device.
    if (holdRoot && recordMatchesHeldRoot) return PqRootAction.ready;
    return PqRootAction.awaitLink;
  }
  // No record: ours hasn't landed yet, or there is none.
  if (holdRoot) return PqRootAction.publishRecord;
  return PqRootAction.generate;
}

enum PqRootSeed { none, pending, generate }

PqRootSeed pqRootSeedForKey({
  required bool holdRoot,
  required bool localKey,
  required bool throwawayKeypair,
  required bool pendingForThisKey,
  required bool freshKey,
}) {
  if (holdRoot || !localKey || throwawayKeypair) return PqRootSeed.none;
  if (pendingForThisKey) return PqRootSeed.pending;
  if (freshKey) return PqRootSeed.generate;
  return PqRootSeed.none;
}

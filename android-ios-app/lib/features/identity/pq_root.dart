/// Custody of the post-quantum root secret: display form, the wraps that move
/// it between devices, the settings record they live in, and the §6 adoption
/// decision. Deriving keys FROM the root is in `lib/core/crypto/pq.dart`.
///
/// Spec: docs/PQ-ROOT-SPEC.md §1, §5, §6.
library;

import 'dart:convert';
import 'dart:typed_data';


import '../../core/crypto/bech32_codec.dart';
import '../../core/crypto/pq.dart' as pq;

/// The settings category the wraps live in. The ONE category that may never be
/// sealed to the root-derived key — spec §5.1, it would be a circular lock.
const String pqRootCategory = 'nymchat-pq-root';

/// Wrap salt: 16 random bytes, stored in the clear beside the wrap.
const int pqRootSaltLength = 16;

// Only the manual code path is implemented on mobile; a passkey wrap needs
// platform PRF APIs. Records carrying one are parsed and ignored.
const String pqRootWrapPasskey = 'passkey';

/// The root as its `nympq1…` display / clipboard / QR form (spec §1). Key
/// material: treat it exactly as the nsec is treated.
String pqRootToCode(Uint8List root) => encodeNymPq(root);

/// Parses a pasted `nympq1…` code, or null on a wrong HRP, bad checksum or
/// wrong length. Adopting a wrong root is worse than adopting none.
Uint8List? pqRootFromCode(String code) {
  try {
    final bytes = decodeNymPq(code);
    if (bytes.length != pq.pqRootLength) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}

/// Whether [root] reproduces the identity's announced key at [epoch] or one of
/// the three before it. Verifies a pasted code against signed data.
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

// -----------------------------------------------------------------------------
// Wrap format
// -----------------------------------------------------------------------------

/// One recovery path for the root: an AES-GCM-256 ciphertext plus its public
/// KDF parameters. [blob] reuses the identity vault's `enc:v1:` envelope.
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

  /// Base64 of the 16 random KDF salt bytes. Public (spec §5).
  final String? salt;

  /// Explicit so a future raise stays readable by an older build.
  final int? iterations;

  /// Unknown fields, kept so a rewrite cannot drop another client's path.
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

/// The `nymchat-pq-root` payload. Its EXISTENCE is what stops a second device
/// generating a rival root (spec §6), so an empty [wraps] is still valid.
class PqRootRecord {
  const PqRootRecord({this.wraps = const [], this.version = 2, this.fp});

  /// Builds the record for [root], stamping its fingerprint.
  factory PqRootRecord.forRoot(Uint8List root,
          {List<PqRootWrap> wraps = const []}) =>
      PqRootRecord(wraps: wraps, fp: pq.pqRootFingerprint(root));

  final List<PqRootWrap> wraps;
  final int version;

  /// Fingerprint of the root this record belongs to. The PWA REQUIRES it: a
  /// record without one reads there as no record, and a device that believes
  /// there is no record generates a second root and splits the account.
  final String? fp;

  /// Whether this record identifies a root at all. Matches the PWA's
  /// `_pqRootValidRecord`, so both apps accept and reject the same payloads.
  bool get isValid => version == 2 && fp != null && fp!.isNotEmpty;

  /// Whether [root] is the one this record belongs to.
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

  /// Null only when the payload is not a record at all — a record with no
  /// usable wraps still parses, since its existence is what matters.
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

// -----------------------------------------------------------------------------
// Generation and adoption (spec §6)
// -----------------------------------------------------------------------------

/// What a booting device should do about the root (spec §6).
enum PqRootAction {
  /// Nothing, and specifically NOT generate.
  wait,

  /// We hold the root and the record is in place.
  ready,

  /// We hold the root but no record exists — republish it.
  publishRecord,

  /// A record exists and nothing we hold opens it: stay silent (§7), prompt.
  awaitLink,

  /// No record exists: generate, publish, adopt, announce.
  generate,
}

/// The §6 decision. Pure and separate because the ORDER of these questions is
/// the whole safety property.
///
/// Deliberately not gated on holding a local nsec: for a signer login the root
/// is the thing that makes the account post-quantum at all, so requiring one
/// first is a deadlock — no key, so no root, so no key. The PWA's
/// `pqRootEnsure` gates on support rather than capability for the same reason,
/// and the two must reach the same verdict from the same inputs.
///
/// Nor on the identity being a "durable login". The standard onboarding does
/// not log anyone in: it persists a nick and boots the auto-ephemeral
/// identity, so `loginMethod` is null for the overwhelming majority of
/// accounts even though the keypair is kept across launches and the account is
/// durable in every sense the user cares about. Requiring a durable login here
/// meant those accounts NEVER generated a root and silently stayed on the
/// nsec-derived key. The PWA has no such gate — `settingsLoadFromD1` falls
/// back to `this.pubkey` and runs `pqRootEnsure` regardless — which is why
/// this worked there and not here. [throwawayKeypair] is the one identity that
/// genuinely has nothing to protect: a new keypair every launch.
PqRootAction pqRootDecide({
  required bool recordLoadSucceeded,
  required bool recordPresent,
  required bool holdRoot,
  bool throwawayKeypair = false,
  bool recordMatchesHeldRoot = true,
}) {
  // A keypair that is regenerated every launch has nothing to carry forward.
  if (throwawayKeypair) return PqRootAction.wait;
  // A read that did not complete proves nothing either way.
  if (!recordLoadSucceeded) return PqRootAction.wait;
  if (recordPresent) {
    // Holding *a* root is not holding *this account's* root. A stale one from
    // a reset identity opens nothing the record points at, so it is the §6.3
    // case exactly as an empty device is.
    if (holdRoot && recordMatchesHeldRoot) return PqRootAction.ready;
    return PqRootAction.awaitLink;
  }
  // No record. Ours has not landed yet, or there is none to land.
  if (holdRoot) return PqRootAction.publishRecord;
  return PqRootAction.generate;
}

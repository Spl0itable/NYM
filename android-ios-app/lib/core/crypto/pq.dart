// Hybrid post-quantum key agreement for Nymchat <-> Nymchat messages.
//
// Dart port of the PWA's `js/nym-crypto.js` PQ surface. The two implementations
// must agree byte-for-byte or the apps cannot read each other's messages;
// test/pq_test.dart gates that against test/pq-vectors.json, which the PWA
// emits from its own implementation.
//
// ## Why
// NIP-44 v2's symmetric layer (ChaCha20 + HMAC-SHA256 + HKDF) has adequate
// post-quantum margins, but the secp256k1 ECDH producing its 32-byte
// conversation key is solved outright by Shor's algorithm. So the NIP-44
// payload format is left completely untouched and only that one derivation is
// replaced, combining the existing ECDH with an ML-KEM-768 encapsulation.
//
// ## The combiner
// Transcript-binding, in the style of X-Wing / PQXDH: the KEM ciphertext and
// both public keys are folded into the HKDF input rather than just the two
// shared secrets, which blocks KEM re-encapsulation attacks. Security is
// max(classical, PQ) — as strong as today's NIP-44 even if ML-KEM is broken,
// and quantum-safe if secp256k1 is.
//
//     ck = HKDF-Extract-SHA256(
//            salt = "nymchat-pq-v1",
//            ikm  = ecdhX || kemSs || kemCt || recipKemPk
//                || senderSecpPk || recipSecpPk)
//
// ## Wire format
// Used identically at both the seal (kind 13) and gift wrap (kind 1059)
// layers, so one code path covers both:
//
//     pq1.<base64url-nopad(kemCiphertext)>.<standard NIP-44 v2 payload>
//
// Carrying the ciphertext in the content rather than a tag keeps the event's
// tag surface byte-identical to vanilla NIP-17, so relay filters and
// recipient matching are unaffected.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'keys.dart';
import 'ml_kem.dart';
import 'nip44.dart' as nip44;

/// Marks a payload as using the hybrid post-quantum transport.
const String pqPrefix = 'pq1.';

/// Domain separator for the KEM combiner.
const String pqCombinerSalt = 'nymchat-pq-v1';

/// Domain separator for deriving the ML-KEM seed from an nsec.
const String pqSeedSalt = 'nym-pq-v1';

/// A recipient's own key material, needed to decrypt.
class PqIdentity {
  const PqIdentity({
    required this.privkey,
    required this.kemSecretKey,
    required this.kemPublicKey,
  });

  final Uint8List privkey;
  final Uint8List kemSecretKey;
  final Uint8List kemPublicKey;
}

/// True if [content] uses the hybrid post-quantum transport.
bool isPqPayload(String? content) =>
    content != null && content.startsWith(pqPrefix);

Uint8List _concat(List<Uint8List> parts) {
  var n = 0;
  for (final p in parts) {
    n += p.length;
  }
  final out = Uint8List(n);
  var o = 0;
  for (final p in parts) {
    out.setRange(o, o + p.length, p);
    o += p.length;
  }
  return out;
}

/// base64url encode, no padding — matches the PWA's `_b64uEncode`.
String b64uEncode(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Inverse of [b64uEncode]; tolerates missing padding.
Uint8List b64uDecode(String s) {
  var t = s;
  while (t.length % 4 != 0) {
    t += '=';
  }
  return Uint8List.fromList(base64Url.decode(t));
}

/// The hybrid conversation key. Feeds straight into the UNMODIFIED
/// [nip44.encrypt] / [nip44.decrypt], which take a 32-byte conversation key.
Uint8List pqConversationKey({
  required Uint8List ecdhSharedX,
  required Uint8List kemSharedSecret,
  required Uint8List kemCipherText,
  required Uint8List recipKemPublicKey,
  required String senderSecpPubkey,
  required String recipSecpPubkey,
}) {
  final ikm = _concat([
    ecdhSharedX,
    kemSharedSecret,
    kemCipherText,
    recipKemPublicKey,
    hexToBytes(senderSecpPubkey),
    hexToBytes(recipSecpPubkey),
  ]);
  return nip44.hkdfExtract(
      Uint8List.fromList(utf8.encode(pqCombinerSalt)), ikm);
}

/// Encrypts [plaintext] to a recipient holding
/// ([recipSecpPubkey], [recipKemPublicKey]).
///
/// The KEM leg is freshly encapsulated per call, so every message gets an
/// independent post-quantum shared secret even though the recipient's ML-KEM
/// key is long-lived. [encapsulationRandomness] and [nonce] exist only to
/// reproduce known vectors — leave them null in production.
String pqEncrypt(
  String plaintext,
  Uint8List senderPrivkey,
  String recipSecpPubkey,
  Uint8List recipKemPublicKey, {
  Uint8List? encapsulationRandomness,
  Uint8List? nonce,
}) {
  if (recipKemPublicKey.length != mlKemPublicKeyLength) {
    throw ArgumentError('bad ml-kem public key');
  }
  final enc = mlKem768.encapsulate(
      recipKemPublicKey, encapsulationRandomness ?? randomBytes(32));
  final ck = pqConversationKey(
    ecdhSharedX: nip44.ecdhSharedX(senderPrivkey, recipSecpPubkey),
    kemSharedSecret: enc.sharedSecret,
    kemCipherText: enc.cipherText,
    recipKemPublicKey: recipKemPublicKey,
    senderSecpPubkey: getPublicKeyHex(senderPrivkey),
    recipSecpPubkey: recipSecpPubkey,
  );
  return '$pqPrefix${b64uEncode(enc.cipherText)}.'
      '${nip44.encrypt(plaintext, ck, nonce: nonce)}';
}

/// Inverse of [pqEncrypt]. Throws on any malformed or undecryptable input, so
/// callers can treat a throw as "not for us" exactly as they do for NIP-44.
String pqDecrypt(String content, String senderSecpPubkey, PqIdentity self) {
  if (!isPqPayload(content)) throw ArgumentError('not a pq payload');
  final dot = content.indexOf('.', pqPrefix.length);
  if (dot < 0) throw ArgumentError('malformed pq payload');
  final cipherText = b64uDecode(content.substring(pqPrefix.length, dot));
  if (cipherText.length != mlKemCipherTextLength) {
    throw ArgumentError('bad ml-kem ciphertext');
  }
  // ML-KEM decapsulation is designed never to fail: on a malformed ciphertext
  // the FO transform returns an implicit-rejection secret, so a wrong key
  // surfaces as an HMAC failure inside nip44.decrypt rather than as a
  // distinguishable error here.
  final sharedSecret = mlKem768.decapsulate(cipherText, self.kemSecretKey);
  final ck = pqConversationKey(
    ecdhSharedX: nip44.ecdhSharedX(self.privkey, senderSecpPubkey),
    kemSharedSecret: sharedSecret,
    kemCipherText: cipherText,
    recipKemPublicKey: self.kemPublicKey,
    senderSecpPubkey: senderSecpPubkey,
    recipSecpPubkey: getPublicKeyHex(self.privkey),
  );
  return nip44.decrypt(content.substring(dot + 1), ck);
}

/// Deterministic ML-KEM seed from an nsec.
///
/// ML-KEM keygen is a pure function of its 64-byte seed, so the keypair is
/// re-derivable on any device: nothing new to back up, and every device sharing
/// an nsec derives the SAME key — which is what makes a single replaceable
/// announcement per identity correct. [epoch] bumps to rotate.
Uint8List pqDeriveSeed(Uint8List privkey, int epoch) {
  final prk = nip44.hkdfExtract(
      Uint8List.fromList(utf8.encode(pqSeedSalt)), privkey);
  return nip44.hkdfExpand(
      prk, Uint8List.fromList(utf8.encode('mlkem768/epoch/$epoch')), 64);
}

/// The ML-KEM identity keypair for [privkey] at [epoch].
MlKemKeyPair pqKeypairFromPrivkey(Uint8List privkey, int epoch) =>
    mlKem768.keygen(pqDeriveSeed(privkey, epoch));

// v2: the independently-seeded root secret. See docs/PQ-ROOT-SPEC.md.
//
// v1 seeds ML-KEM from the nsec, so breaking secp256k1 also yields the
// post-quantum key. v2 seeds from 32 CSPRNG bytes instead. The v1 path stays
// forever: everything sealed under it must remain readable (spec §4).

/// Domain separator for deriving the ML-KEM seed from a root secret. Differs
/// from [pqSeedSalt] so a root and an nsec can never derive the same keypair.
const String pqRootSeedSalt = 'nym-pq-root-v2';

/// Length of the root secret, in bytes.
const int pqRootLength = 32;

/// A fresh root secret. Generated once per identity.
Uint8List pqGenerateRoot() => randomBytes(pqRootLength);

/// Deterministic ML-KEM seed from a root secret.
Uint8List pqRootDeriveSeed(Uint8List root, int epoch) {
  if (root.length != pqRootLength) {
    throw ArgumentError('pq root must be $pqRootLength bytes');
  }
  final prk = nip44.hkdfExtract(
      Uint8List.fromList(utf8.encode(pqRootSeedSalt)), root);
  return nip44.hkdfExpand(
      prk, Uint8List.fromList(utf8.encode('mlkem768/epoch/$epoch')), 64);
}

/// The ML-KEM identity keypair for [root] at [epoch].
MlKemKeyPair pqKeypairFromRoot(Uint8List root, int epoch) =>
    mlKem768.keygen(pqRootDeriveSeed(root, epoch));

/// Domain separator for the root fingerprint.
const String pqRootFpSalt = 'nym-pq-root-fp-v1';

/// Fingerprint length, in bytes.
const int pqRootFpLength = 8;

/// A short public fingerprint of [root], as lowercase hex.
///
/// Goes in the settings record so a device can tell "this is the root I hold"
/// from "this is a different one" without either side revealing the secret.
/// Must stay byte-identical to the PWA's `pqRootFingerprint` — a record
/// without a matching one reads as no record at all, and a device that
/// believes there is no record generates a second root.
String pqRootFingerprint(Uint8List root) {
  if (root.length != pqRootLength) {
    throw ArgumentError('pq root must be $pqRootLength bytes');
  }
  final prk = nip44.hkdfExtract(
      Uint8List.fromList(utf8.encode(pqRootFpSalt)), root);
  final out = nip44.hkdfExpand(
      prk, Uint8List.fromList(utf8.encode('fp')), pqRootFpLength);
  return [for (final b in out) b.toRadixString(16).padLeft(2, '0')].join();
}

// ---- pq2: layered, so a signer login can take part -------------------------
//
// pq1 mixes the ECDH secret and the KEM secret into one key, and a NIP-07 or
// NIP-46 signer never returns the raw ECDH x. Here NIP-44 is the inner layer
// (any signer does it) and the KEM keys an outer AEAD. See PQ-ROOT-SPEC A2.

const String pq2Prefix = 'pq2.';
const String _pq2Salt = 'nymchat-pq2-v1';
const String _pq2Label = 'nymchat-pq2';

bool isPq2Payload(String? content) =>
    content != null && content.startsWith(pq2Prefix);

final _pq2Aead = Chacha20.poly1305Aead();

class Pq2LayerKeys {
  const Pq2LayerKeys(this.key, this.nonce, this.aad);
  final Uint8List key;
  final Uint8List nonce;
  final Uint8List aad;
}

/// Outer-layer key, nonce and AAD. The shared secret is fresh per message, so
/// the key is never reused and a derived nonce is safe.
Pq2LayerKeys pq2LayerKeys({
  required Uint8List kemSharedSecret,
  required Uint8List kemCipherText,
  required Uint8List recipKemPublicKey,
  required String senderSecpPubkey,
  required String recipSecpPubkey,
}) {
  final info = _concat([
    Uint8List.fromList(utf8.encode(_pq2Label)),
    hexToBytes(senderSecpPubkey),
    hexToBytes(recipSecpPubkey),
    kemCipherText,
    recipKemPublicKey,
  ]);
  final prk = nip44.hkdfExtract(
      Uint8List.fromList(utf8.encode(_pq2Salt)), kemSharedSecret);
  return Pq2LayerKeys(
    nip44.hkdfExpand(
        prk, _concat([info, Uint8List.fromList(utf8.encode('key'))]), 32),
    nip44.hkdfExpand(
        prk, _concat([info, Uint8List.fromList(utf8.encode('nonce'))]), 12),
    info,
  );
}

/// Wraps an already-encrypted NIP-44 payload in the post-quantum layer. The
/// caller produced [inner] however it can — local key or signer.
Future<String> pq2Seal(
  String inner,
  String senderSecpPubkey,
  String recipSecpPubkey,
  Uint8List recipKemPublicKey, {
  Uint8List? encapsulationRandomness,
}) async {
  if (recipKemPublicKey.length != mlKemPublicKeyLength) {
    throw ArgumentError('bad ml-kem public key');
  }
  if (inner.isEmpty) throw ArgumentError('bad inner payload');
  final enc = mlKem768.encapsulate(
      recipKemPublicKey, encapsulationRandomness ?? randomBytes(32));
  final k = pq2LayerKeys(
    kemSharedSecret: enc.sharedSecret,
    kemCipherText: enc.cipherText,
    recipKemPublicKey: recipKemPublicKey,
    senderSecpPubkey: senderSecpPubkey,
    recipSecpPubkey: recipSecpPubkey,
  );
  final box = await _pq2Aead.encrypt(
    utf8.encode(inner),
    secretKey: SecretKey(k.key),
    nonce: k.nonce,
    aad: k.aad,
  );
  final outer = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  return '$pq2Prefix${b64uEncode(enc.cipherText)}.${b64uEncode(outer)}';
}

/// Strips the post-quantum layer, returning the NIP-44 payload inside. No secp
/// key is needed here, which is what lets a signer login participate.
Future<String> pq2Open(
  String content,
  String senderSecpPubkey,
  String recipSecpPubkey,
  Uint8List kemSecretKey,
  Uint8List kemPublicKey,
) async {
  if (!isPq2Payload(content)) throw ArgumentError('not a pq2 payload');
  final dot = content.indexOf('.', pq2Prefix.length);
  if (dot < 0) throw ArgumentError('malformed pq2 payload');
  final cipherText = b64uDecode(content.substring(pq2Prefix.length, dot));
  if (cipherText.length != mlKemCipherTextLength) {
    throw ArgumentError('bad ml-kem ciphertext');
  }
  final sharedSecret = mlKem768.decapsulate(cipherText, kemSecretKey);
  final k = pq2LayerKeys(
    kemSharedSecret: sharedSecret,
    kemCipherText: cipherText,
    recipKemPublicKey: kemPublicKey,
    senderSecpPubkey: senderSecpPubkey,
    recipSecpPubkey: recipSecpPubkey,
  );
  final outer = b64uDecode(content.substring(dot + 1));
  if (outer.length < 16) throw ArgumentError('malformed pq2 payload');
  final clear = await _pq2Aead.decrypt(
    SecretBox(
      outer.sublist(0, outer.length - 16),
      nonce: k.nonce,
      mac: Mac(outer.sublist(outer.length - 16)),
    ),
    secretKey: SecretKey(k.key),
    aad: k.aad,
  );
  return utf8.decode(clear);
}

/// Local-key convenience: both layers here.
Future<String> pq2Encrypt(
  String plaintext,
  Uint8List senderPrivkey,
  String recipSecpPubkey,
  Uint8List recipKemPublicKey, {
  Uint8List? encapsulationRandomness,
  Uint8List? nonce,
}) async {
  final inner = nip44.encrypt(
      plaintext, nip44.getConversationKey(senderPrivkey, recipSecpPubkey),
      nonce: nonce);
  return pq2Seal(inner, getPublicKeyHex(senderPrivkey), recipSecpPubkey,
      recipKemPublicKey,
      encapsulationRandomness: encapsulationRandomness);
}

Future<String> pq2Decrypt(
    String content, String senderSecpPubkey, PqIdentity self) async {
  final recipPk = getPublicKeyHex(self.privkey);
  final inner = await pq2Open(
      content, senderSecpPubkey, recipPk, self.kemSecretKey, self.kemPublicKey);
  return nip44.decrypt(
      inner, nip44.getConversationKey(self.privkey, senderSecpPubkey));
}

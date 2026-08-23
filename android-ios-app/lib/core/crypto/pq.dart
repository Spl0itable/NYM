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

// Hybrid PQ key agreement (ECDH + ML-KEM-768, transcript-bound HKDF) matching the PWA; `pq1.<kemCt>.<nip44>`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'keys.dart';
import 'ml_kem.dart';
import 'nip44.dart' as nip44;

const String pqPrefix = 'pq1.';

const String pqCombinerSalt = 'nymchat-pq-v1';

const String pqSeedSalt = 'nym-pq-v1';

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

/// base64url without padding, matching the PWA's `_b64uEncode`.
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

/// The hybrid 32-byte conversation key for unmodified [nip44.encrypt] / [nip44.decrypt].
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

/// Encapsulates freshly per call; [encapsulationRandomness] and [nonce] are for test vectors only.
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

/// Throws on malformed or undecryptable input, so callers treat a throw as not for us.
String pqDecrypt(String content, String senderSecpPubkey, PqIdentity self) {
  if (!isPqPayload(content)) throw ArgumentError('not a pq payload');
  final dot = content.indexOf('.', pqPrefix.length);
  if (dot < 0) throw ArgumentError('malformed pq payload');
  final cipherText = b64uDecode(content.substring(pqPrefix.length, dot));
  if (cipherText.length != mlKemCipherTextLength) {
    throw ArgumentError('bad ml-kem ciphertext');
  }
  // Decapsulation never fails; a wrong key surfaces as an HMAC failure in nip44.decrypt.
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

/// Deterministic ML-KEM seed from an nsec, so every device sharing it derives the same key; [epoch] rotates.
Uint8List pqDeriveSeed(Uint8List privkey, int epoch) {
  final prk = nip44.hkdfExtract(
      Uint8List.fromList(utf8.encode(pqSeedSalt)), privkey);
  return nip44.hkdfExpand(
      prk, Uint8List.fromList(utf8.encode('mlkem768/epoch/$epoch')), 64);
}

MlKemKeyPair pqKeypairFromPrivkey(Uint8List privkey, int epoch) =>
    mlKem768.keygen(pqDeriveSeed(privkey, epoch));

// v2 seeds ML-KEM from an independent root secret; the v1 nsec path must stay readable forever.

/// Differs from [pqSeedSalt] so a root and an nsec never derive the same keypair.
const String pqRootSeedSalt = 'nym-pq-root-v2';

const int pqRootLength = 32;

/// A fresh root secret, generated once per identity.
Uint8List pqGenerateRoot() => randomBytes(pqRootLength);

Uint8List pqRootDeriveSeed(Uint8List root, int epoch) {
  if (root.length != pqRootLength) {
    throw ArgumentError('pq root must be $pqRootLength bytes');
  }
  final prk = nip44.hkdfExtract(
      Uint8List.fromList(utf8.encode(pqRootSeedSalt)), root);
  return nip44.hkdfExpand(
      prk, Uint8List.fromList(utf8.encode('mlkem768/epoch/$epoch')), 64);
}

MlKemKeyPair pqKeypairFromRoot(Uint8List root, int epoch) =>
    mlKem768.keygen(pqRootDeriveSeed(root, epoch));

const String pqRootFpSalt = 'nym-pq-root-fp-v1';

const int pqRootFpLength = 8;

/// Public hex fingerprint of [root]; must match the PWA's `pqRootFingerprint` byte for byte.
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

// pq2: NIP-44 inner layer plus a KEM-keyed outer AEAD, so signer logins can take part.

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

/// Outer-layer key, nonce and AAD; the per-message secret makes a derived nonce safe.
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

/// Wraps an already-encrypted NIP-44 payload [inner] in the post-quantum layer.
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

/// Strips the post-quantum layer; needs no secp key, so signer logins can open it.
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

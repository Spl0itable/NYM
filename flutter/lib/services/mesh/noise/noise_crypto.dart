import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/api.dart' show KeyParameter;

/// Noise `XX_25519_ChaChaPoly_SHA256` primitives, byte-matched to bitchat's Noise-Java backend.
class NoiseCrypto {
  NoiseCrypto._();

  static const int hashLen = 32;
  static const int dhLen = 32;
  static const int keyLen = 32;
  static const int tagLen = 16;

  static final X25519 _x25519 = X25519();
  static final Chacha20 _aead = Chacha20.poly1305Aead();

  static Uint8List sha256(List<int> data) {
    final d = SHA256Digest();
    return d.process(Uint8List.fromList(data));
  }

  static Uint8List hmacSha256(Uint8List key, Uint8List data) {
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
    return mac.process(data);
  }

  /// Noise HKDF: returns [numOutputs] (2 or 3) 32-byte outputs.
  static List<Uint8List> hkdf(
      Uint8List chainingKey, Uint8List inputKeyMaterial, int numOutputs) {
    final tempKey = hmacSha256(chainingKey, inputKeyMaterial);
    final out1 = hmacSha256(tempKey, Uint8List.fromList([0x01]));
    if (numOutputs == 1) return [out1];
    final out2 = hmacSha256(tempKey, Uint8List.fromList([...out1, 0x02]));
    if (numOutputs == 2) return [out1, out2];
    final out3 = hmacSha256(tempKey, Uint8List.fromList([...out2, 0x03]));
    return [out1, out2, out3];
  }

  static Future<Uint8List> x25519PublicKey(Uint8List privateSeed) async {
    final kp = await _x25519.newKeyPairFromSeed(privateSeed);
    final pub = await kp.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  /// A fresh ephemeral X25519 keypair as `(privateSeed, publicKey)`.
  static Future<(Uint8List, Uint8List)> x25519Generate() async {
    final kp = await _x25519.newKeyPair();
    final priv = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();
    return (Uint8List.fromList(priv), Uint8List.fromList(pub.bytes));
  }

  static Future<Uint8List> dh(
      Uint8List localPrivateSeed, Uint8List remotePublic) async {
    final kp = await _x25519.newKeyPairFromSeed(localPrivateSeed);
    final shared = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: SimplePublicKey(remotePublic, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  /// 12-byte IETF nonce: four zero bytes then the little-endian 64-bit counter, as southernstorm does.
  static Uint8List nonce12(int n) {
    final out = Uint8List(12);
    var v = n;
    for (var i = 4; i < 12; i++) {
      out[i] = v & 0xFF;
      v >>= 8;
    }
    return out;
  }

  /// Noise `ENCRYPT(k, n, ad, plaintext)` returning ciphertext || 16-byte tag.
  static Future<Uint8List> aeadEncrypt(
      Uint8List key, int n, Uint8List ad, Uint8List plaintext) async {
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce12(n),
      aad: ad,
    );
    final out = Uint8List(box.cipherText.length + box.mac.bytes.length);
    out.setRange(0, box.cipherText.length, box.cipherText);
    out.setRange(box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  /// Noise `DECRYPT` of `ciphertext || tag`; throws if authentication fails.
  static Future<Uint8List> aeadDecrypt(
      Uint8List key, int n, Uint8List ad, Uint8List ciphertext) async {
    if (ciphertext.length < tagLen) {
      throw ArgumentError('ciphertext shorter than tag');
    }
    final ctLen = ciphertext.length - tagLen;
    final box = SecretBox(
      Uint8List.sublistView(ciphertext, 0, ctLen),
      nonce: nonce12(n),
      mac: Mac(Uint8List.sublistView(ciphertext, ctLen)),
    );
    final clear = await _aead.decrypt(box, secretKey: SecretKey(key), aad: ad);
    return Uint8List.fromList(clear);
  }
}

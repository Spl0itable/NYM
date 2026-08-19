import 'dart:convert';
import 'dart:typed_data';

import 'noise_crypto.dart';

/// The Noise protocol name for the suite bitchat uses. Exactly 32 bytes, so the
/// initial handshake hash is the name itself (no hashing/padding needed).
const String kNoiseProtocolName = 'Noise_XX_25519_ChaChaPoly_SHA256';

/// A Noise `CipherState`: a symmetric key [k] plus a monotonic nonce counter.
/// When [k] is null the state has no key and encrypt/decrypt are pass-through
/// (used before the first `MixKey`).
class NoiseCipherState {
  NoiseCipherState([this._k]);

  Uint8List? _k;
  int _n = 0;

  bool get hasKey => _k != null;
  int get nonce => _n;

  void initializeKey(Uint8List key) {
    _k = key;
    _n = 0;
  }

  void setNonce(int n) => _n = n;

  Future<Uint8List> encryptWithAd(Uint8List ad, Uint8List plaintext) async {
    final k = _k;
    if (k == null) return plaintext;
    final ct = await NoiseCrypto.aeadEncrypt(k, _n, ad, plaintext);
    _n++;
    return ct;
  }

  Future<Uint8List> decryptWithAd(Uint8List ad, Uint8List ciphertext) async {
    final k = _k;
    if (k == null) return ciphertext;
    final pt = await NoiseCrypto.aeadDecrypt(k, _n, ad, ciphertext);
    _n++;
    return pt;
  }
}

/// A Noise `SymmetricState`: the chaining key [_ck], handshake hash [_h] and the
/// running [CipherState]. Implements MixKey/MixHash/EncryptAndHash/Split.
class NoiseSymmetricState {
  NoiseSymmetricState._(this._ck, this._h, this._cipher);

  Uint8List _ck;
  Uint8List _h;
  final NoiseCipherState _cipher;

  Uint8List get handshakeHash => _h;
  bool get hasKey => _cipher.hasKey;

  factory NoiseSymmetricState.initialize(String protocolName) {
    final nameBytes = Uint8List.fromList(utf8.encode(protocolName));
    Uint8List h;
    if (nameBytes.length <= NoiseCrypto.hashLen) {
      h = Uint8List(NoiseCrypto.hashLen)
        ..setRange(0, nameBytes.length, nameBytes);
    } else {
      h = NoiseCrypto.sha256(nameBytes);
    }
    return NoiseSymmetricState._(Uint8List.fromList(h), h, NoiseCipherState());
  }

  void mixKey(Uint8List inputKeyMaterial) {
    final out = NoiseCrypto.hkdf(_ck, inputKeyMaterial, 2);
    _ck = out[0];
    _cipher.initializeKey(out[1]);
  }

  void mixHash(Uint8List data) {
    _h = NoiseCrypto.sha256(Uint8List.fromList([..._h, ...data]));
  }

  Future<Uint8List> encryptAndHash(Uint8List plaintext) async {
    final ct = await _cipher.encryptWithAd(_h, plaintext);
    mixHash(ct);
    return ct;
  }

  Future<Uint8List> decryptAndHash(Uint8List ciphertext) async {
    final pt = await _cipher.decryptWithAd(_h, ciphertext);
    mixHash(ciphertext);
    return pt;
  }

  /// Derives the two transport [CipherState]s at the end of the handshake.
  (NoiseCipherState, NoiseCipherState) split() {
    final out = NoiseCrypto.hkdf(_ck, Uint8List(0), 2);
    return (NoiseCipherState(out[0]), NoiseCipherState(out[1]));
  }
}

enum _Token { e, s, ee, es, se }

/// A Noise `HandshakeState` specialised to the `XX` pattern:
/// ```
/// -> e
/// <- e, ee, s, es
/// -> s, se
/// ```
/// Empty prologue and no pre-message keys, matching bitchat.
class NoiseHandshakeState {
  NoiseHandshakeState._(this.isInitiator, this._sym, this._sPriv, this._sPub);

  final bool isInitiator;
  final NoiseSymmetricState _sym;

  final Uint8List _sPriv; // local static private seed
  final Uint8List _sPub; // local static public
  Uint8List? _ePriv; // local ephemeral private seed
  Uint8List? _re; // remote ephemeral public
  Uint8List? _rs; // remote static public

  int _msgIndex = 0;

  static const List<List<_Token>> _xxPatterns = [
    [_Token.e],
    [_Token.e, _Token.ee, _Token.s, _Token.es],
    [_Token.s, _Token.se],
  ];

  Uint8List get handshakeHash => _sym.handshakeHash;
  Uint8List? get remoteStaticPublicKey => _rs;
  bool get isComplete => _msgIndex >= _xxPatterns.length;

  /// Initialises an XX handshake. [staticPrivate] is the 32-byte X25519 static
  /// private seed; [staticPublic] its public key.
  factory NoiseHandshakeState.xx({
    required bool initiator,
    required Uint8List staticPrivate,
    required Uint8List staticPublic,
  }) {
    final sym = NoiseSymmetricState.initialize(kNoiseProtocolName);
    // MixHash(prologue) with an empty prologue — mandatory even when empty.
    sym.mixHash(Uint8List(0));
    return NoiseHandshakeState._(initiator, sym, staticPrivate, staticPublic);
  }

  /// Writes the next handshake message (empty Noise payload), advancing the
  /// pattern. Returns the bytes to transmit.
  Future<Uint8List> writeMessage() async {
    final pattern = _xxPatterns[_msgIndex];
    final buf = BytesBuilder();
    for (final token in pattern) {
      switch (token) {
        case _Token.e:
          final (priv, pub) = await NoiseCrypto.x25519Generate();
          _ePriv = priv;
          buf.add(pub);
          _sym.mixHash(pub);
          break;
        case _Token.s:
          buf.add(await _sym.encryptAndHash(_sPub));
          break;
        case _Token.ee:
          _sym.mixKey(await NoiseCrypto.dh(_ePriv!, _re!));
          break;
        case _Token.es:
          _sym.mixKey(isInitiator
              ? await NoiseCrypto.dh(_ePriv!, _rs!)
              : await NoiseCrypto.dh(_sPriv, _re!));
          break;
        case _Token.se:
          _sym.mixKey(isInitiator
              ? await NoiseCrypto.dh(_sPriv, _re!)
              : await NoiseCrypto.dh(_ePriv!, _rs!));
          break;
      }
    }
    buf.add(await _sym.encryptAndHash(Uint8List(0)));
    _msgIndex++;
    return buf.toBytes();
  }

  /// Reads a received handshake message, advancing the pattern. Returns the
  /// decrypted Noise payload (empty for bitchat).
  Future<Uint8List> readMessage(Uint8List message) async {
    final pattern = _xxPatterns[_msgIndex];
    var offset = 0;
    for (final token in pattern) {
      switch (token) {
        case _Token.e:
          _re = Uint8List.fromList(Uint8List.sublistView(
              message, offset, offset + NoiseCrypto.dhLen));
          offset += NoiseCrypto.dhLen;
          _sym.mixHash(_re!);
          break;
        case _Token.s:
          final len =
              NoiseCrypto.dhLen + (_sym.hasKey ? NoiseCrypto.tagLen : 0);
          final temp = Uint8List.fromList(
              Uint8List.sublistView(message, offset, offset + len));
          offset += len;
          _rs = await _sym.decryptAndHash(temp);
          break;
        case _Token.ee:
          _sym.mixKey(await NoiseCrypto.dh(_ePriv!, _re!));
          break;
        case _Token.es:
          _sym.mixKey(isInitiator
              ? await NoiseCrypto.dh(_ePriv!, _rs!)
              : await NoiseCrypto.dh(_sPriv, _re!));
          break;
        case _Token.se:
          _sym.mixKey(isInitiator
              ? await NoiseCrypto.dh(_sPriv, _re!)
              : await NoiseCrypto.dh(_ePriv!, _rs!));
          break;
      }
    }
    final payload = Uint8List.fromList(
        Uint8List.sublistView(message, offset, message.length));
    final clear = await _sym.decryptAndHash(payload);
    _msgIndex++;
    return clear;
  }

  /// Transport ciphers, valid only once the handshake is complete.
  (NoiseCipherState, NoiseCipherState) split() => _sym.split();
}

// ML-KEM-768 (FIPS 203), pure Dart.
//
// Hand-ported to match @noble/post-quantum's ml_kem768 byte-for-byte — that
// implementation is the reference the PWA ships, and the two must interoperate
// or Nymchat clients cannot read each other's messages. test/pq_vectors_test.dart
// gates every step of this file against test/pq-vectors.json, the fixture the
// PWA emits.
//
// Only the lattice math lives here. Keccak comes from pointycastle (already a
// dependency): its SHA-3/SHAKE are backed by 32-bit register pairs rather than
// native 64-bit ints, so they behave identically on the VM and on the web,
// where Dart's `int` is a 53-bit double and bitwise ops truncate to 32 bits.
// Every intermediate below is likewise kept under 2^31 for that reason.
//
// Parameters (FIPS 203 Table 2, ML-KEM-768):
//   n=256  q=3329  k=3  eta1=eta2=2  du=10  dv=4
//   ek 1184B   dk 2400B   ct 1088B   shared secret 32B
import 'dart:typed_data';

import 'package:pointycastle/digests/sha3.dart';
import 'package:pointycastle/digests/shake.dart';

const int _n = 256;
const int _q = 3329;
const int _k = 3;
const int _eta1 = 2;
const int _eta2 = 2;
const int _du = 10;
const int _dv = 4;

/// 128^-1 mod q — the inverse-NTT normalisation factor (FIPS 203 Alg. 10 line 14).
/// Kyber uses 128, not 256, because its transform stops one layer early.
const int _f = 3303;
const int _rootOfUnity = 17;

/// Public byte lengths.
const int mlKemPublicKeyLength = 1184;
const int mlKemSecretKeyLength = 2400;
const int mlKemCipherTextLength = 1088;
const int mlKemSharedSecretLength = 32;
const int mlKemSeedLength = 64;
const int mlKemMessageLength = 32;

const int _kPkeSecretKeyLength = 384 * _k; // 1152

int _mod(int a) {
  final r = a % _q;
  return r < 0 ? r + _q : r;
}

/// zetas[i] = 17^BitRev7(i) mod q.
final Uint16List _zetas = _computeZetas();

Uint16List _computeZetas() {
  final out = Uint16List(_n);
  for (var i = 0; i < _n; i++) {
    // BitRev7 of the low 7 bits.
    var b = 0;
    for (var bit = 0; bit < 7; bit++) {
      if ((i >> bit) & 1 == 1) b |= 1 << (6 - bit);
    }
    var acc = 1;
    for (var e = 0; e < b; e++) {
      acc = (acc * _rootOfUnity) % _q;
    }
    out[i] = acc;
  }
  return out;
}

// --- Keccak bindings (FIPS 203 §4.1) ----------------------------------------

Uint8List _sha3_256(Uint8List data) => SHA3Digest(256).process(data);

Uint8List _sha3_512(Uint8List data) => SHA3Digest(512).process(data);

/// SHAKE256(data, outLen) — the spec's J, and the basis of PRF_eta.
Uint8List _shake256(Uint8List data, int outLen) {
  final d = SHAKEDigest(256);
  d.update(data, 0, data.length);
  final out = Uint8List(outLen);
  d.doFinalRange(out, 0, outLen);
  return out;
}

/// PRF_eta(s, b) = SHAKE256(s || b, 64*eta).
Uint8List _prf(int outLen, Uint8List key, int nonce) {
  final buf = Uint8List(key.length + 1)
    ..setRange(0, key.length, key)
    ..[key.length] = nonce & 0xff;
  return _shake256(buf, outLen);
}

/// A continuous SHAKE128 reader over `seed || x || y`, squeezed in 168-byte
/// blocks. `doOutput` (unlike `doFinalRange`) does not reset the sponge, so
/// successive calls continue the same stream, which is what SampleNTT's
/// rejection loop needs.
class _Xof128 {
  _Xof128(Uint8List seed, int x, int y) {
    final buf = Uint8List(seed.length + 2)
      ..setRange(0, seed.length, seed)
      ..[seed.length] = x & 0xff
      ..[seed.length + 1] = y & 0xff;
    _d.update(buf, 0, buf.length);
  }

  final SHAKEDigest _d = SHAKEDigest(128);

  /// SHAKE128 rate in bytes; divisible by 3, as SampleNTT's 12-bit unpacking
  /// requires.
  static const int blockLength = 168;

  Uint8List nextBlock() {
    final out = Uint8List(blockLength);
    _d.doOutput(out, 0, blockLength);
    return out;
  }
}

// --- Polynomial arithmetic --------------------------------------------------

Uint16List _newPoly() => Uint16List(_n);

void _polyAdd(Uint16List a, Uint16List b) {
  for (var i = 0; i < _n; i++) {
    final r = a[i] + b[i];
    a[i] = r >= _q ? r - _q : r;
  }
}

void _polySub(Uint16List a, Uint16List b) {
  for (var i = 0; i < _n; i++) {
    final r = a[i] - b[i];
    a[i] = r < 0 ? r + _q : r;
  }
}

/// Forward NTT, in place (FIPS 203 Algorithm 9).
Uint16List _nttEncode(Uint16List r) {
  var i = 1;
  for (var len = 128; len >= 2; len >>= 1) {
    for (var start = 0; start < _n; start += 2 * len) {
      final zeta = _zetas[i++];
      for (var j = start; j < start + len; j++) {
        // zeta * r[..] < 3329^2 ≈ 1.1e7 — safe on web.
        final t = (zeta * r[j + len]) % _q;
        final u = r[j];
        var lo = u - t;
        if (lo < 0) lo += _q;
        var hi = u + t;
        if (hi >= _q) hi -= _q;
        r[j + len] = lo;
        r[j] = hi;
      }
    }
  }
  return r;
}

/// Inverse NTT, in place (FIPS 203 Algorithm 10), including the 128^-1 scaling.
Uint16List _nttDecode(Uint16List r) {
  var i = 127;
  for (var len = 2; len <= 128; len <<= 1) {
    for (var start = 0; start < _n; start += 2 * len) {
      final zeta = _zetas[i--];
      for (var j = start; j < start + len; j++) {
        final t = r[j];
        var sum = t + r[j + len];
        if (sum >= _q) sum -= _q;
        var diff = r[j + len] - t;
        if (diff < 0) diff += _q;
        r[j] = sum;
        r[j + len] = (zeta * diff) % _q;
      }
    }
  }
  for (var j = 0; j < _n; j++) {
    r[j] = (r[j] * _f) % _q;
  }
  return r;
}

/// One degree-one product modulo (X^2 - zeta) (FIPS 203 Algorithm 12).
/// a1*b1 is reduced before multiplying by zeta so no intermediate exceeds 2^31.
void _baseCaseMultiply(Uint16List out, int idx, int a0, int a1, int b0, int b1, int zeta) {
  final c0 = _mod(_mod(a1 * b1) * zeta + a0 * b0);
  final c1 = _mod(a0 * b1 + a1 * b0);
  out[idx] = c0;
  out[idx + 1] = c1;
}

/// Multiplies two NTT representations into a fresh polynomial (Algorithm 11).
Uint16List _multiplyNtts(Uint16List f, Uint16List g) {
  final out = _newPoly();
  for (var i = 0; i < _n ~/ 2; i++) {
    var z = _zetas[64 + (i >> 1)];
    if (i & 1 == 1) z = _q - z; // gamma = -zeta for odd i
    _baseCaseMultiply(out, 2 * i, f[2 * i], f[2 * i + 1], g[2 * i], g[2 * i + 1], z);
  }
  return out;
}

// --- Packing / compression (FIPS 203 §4.2.1) --------------------------------

/// Compress_d: round(2^d * x / q). Written as exact integer division of the
/// doubled expression so it matches the reference's `((x<<d) + q/2) / q`
/// float form bit-for-bit (the numerator is always odd, so no tie can occur).
int _compress(int x, int d) => (2 * (x << d) + _q) ~/ (2 * _q);

/// Decompress_d: round(q * y / 2^d).
int _decompress(int y, int d) => (y * _q + (1 << (d - 1))) >> d;

/// Packs one d-bit little-endian word per coefficient.
/// d == 12 is ByteEncode12 (lossless); d < 12 also applies Compress_d.
Uint8List _polyEncode(Uint16List poly, int d) {
  final mask = (1 << d) - 1;
  final out = Uint8List(d * (_n ~/ 8));
  var buf = 0, bufLen = 0, pos = 0;
  for (var i = 0; i < _n; i++) {
    final v = (d == 12 ? poly[i] : _compress(poly[i], d)) & mask;
    buf |= v << bufLen;
    bufLen += d;
    while (bufLen >= 8) {
      out[pos++] = buf & 0xff;
      buf >>= 8;
      bufLen -= 8;
    }
  }
  return out;
}

/// Inverse of [_polyEncode]. For d == 12 this is ByteDecode12, whose single
/// conditional subtraction (not a full reduction) is what makes the
/// encapsulation-time modulus check meaningful.
Uint16List _polyDecode(Uint8List bytes, int d) {
  final mask = (1 << d) - 1;
  final out = _newPoly();
  var buf = 0, bufLen = 0, pos = 0;
  for (var i = 0; i < bytes.length && pos < _n; i++) {
    buf |= bytes[i] << bufLen;
    bufLen += 8;
    while (bufLen >= d && pos < _n) {
      final w = buf & mask;
      out[pos++] = d == 12 ? (w >= _q ? w - _q : w) : _decompress(w, d);
      buf >>= d;
      bufLen -= d;
    }
  }
  return out;
}

List<Uint16List> _vecDecode(Uint8List bytes, int d) {
  final polyLen = d * (_n ~/ 8);
  return List<Uint16List>.generate(
      _k, (i) => _polyDecode(Uint8List.sublistView(bytes, i * polyLen, (i + 1) * polyLen), d));
}

Uint8List _vecEncode(List<Uint16List> v, int d) {
  final polyLen = d * (_n ~/ 8);
  final out = Uint8List(polyLen * _k);
  for (var i = 0; i < _k; i++) {
    out.setRange(i * polyLen, (i + 1) * polyLen, _polyEncode(v[i], d));
  }
  return out;
}

// --- Sampling ---------------------------------------------------------------

/// SampleNTT (Algorithm 7): rejection-sample uniform coefficients from SHAKE128.
Uint16List _sampleNtt(_Xof128 xof) {
  final r = _newPoly();
  var j = 0;
  while (j < _n) {
    final b = xof.nextBlock();
    for (var i = 0; j < _n && i + 3 <= b.length; i += 3) {
      final d1 = (b[i] | (b[i + 1] << 8)) & 0xfff;
      final d2 = ((b[i + 1] >> 4) | (b[i + 2] << 4)) & 0xfff;
      if (d1 < _q) r[j++] = d1;
      if (j < _n && d2 < _q) r[j++] = d2;
    }
  }
  return r;
}

/// SamplePolyCBD_eta (Algorithm 8). The reference consumes the PRF stream
/// LSB-first within each byte, in byte order; doing that directly here is
/// equivalent to its 32-bit-word view and avoids any endianness dependence.
Uint16List _sampleCbd(Uint8List buf, int eta) {
  final r = _newPoly();
  var p = 0, bb = 0, len = 0, t0 = 0;
  for (var i = 0; i < buf.length; i++) {
    var b = buf[i];
    for (var j = 0; j < 8; j++) {
      bb += b & 1;
      b >>= 1;
      len++;
      if (len == eta) {
        t0 = bb;
        bb = 0;
      } else if (len == 2 * eta) {
        r[p++] = _mod(t0 - bb);
        bb = 0;
        len = 0;
      }
    }
  }
  if (len != 0) throw StateError('sampleCBD: leftover bits: $len');
  return r;
}

Uint16List _sampleCbdPrf(Uint8List seed, int nonce, int eta) =>
    _sampleCbd(_prf((eta * _n) ~/ 4, seed, nonce), eta);

// --- K-PKE ------------------------------------------------------------------

class _KPkeKeys {
  _KPkeKeys(this.publicKey, this.secretKey);
  final Uint8List publicKey;
  final Uint8List secretKey;
}

_KPkeKeys _kpkeKeygen(Uint8List seed32) {
  // FIPS 203 Algorithm 13 appends the parameter-set byte k before G(d || k),
  // so the same seed yields unrelated keys under a different parameter set.
  final seedDst = Uint8List(33)
    ..setRange(0, 32, seed32)
    ..[32] = _k;
  final seedHash = _sha3_512(seedDst);
  final rho = Uint8List.sublistView(seedHash, 0, 32);
  final sigma = Uint8List.sublistView(seedHash, 32, 64);

  final sHat = <Uint16List>[];
  for (var i = 0; i < _k; i++) {
    sHat.add(_nttEncode(_sampleCbdPrf(sigma, i, _eta1)));
  }
  final tHat = <Uint16List>[];
  for (var i = 0; i < _k; i++) {
    final e = _nttEncode(_sampleCbdPrf(sigma, _k + i, _eta1));
    for (var j = 0; j < _k; j++) {
      // A[i][j] is read as the (j, i) XOF coordinate — the in-place transpose
      // the reference uses in keygen. Encryption uses (i, j); the asymmetry is
      // load-bearing.
      _polyAdd(e, _multiplyNtts(_sampleNtt(_Xof128(rho, j, i)), sHat[j]));
    }
    tHat.add(e);
  }

  final publicKey = Uint8List(mlKemPublicKeyLength)
    ..setRange(0, _kPkeSecretKeyLength, _vecEncode(tHat, 12))
    ..setRange(_kPkeSecretKeyLength, mlKemPublicKeyLength, rho);
  return _KPkeKeys(publicKey, _vecEncode(sHat, 12));
}

Uint8List _kpkeEncrypt(Uint8List publicKey, Uint8List msg, Uint8List seed) {
  final tHat = _vecDecode(Uint8List.sublistView(publicKey, 0, _kPkeSecretKeyLength), 12);
  final rho = Uint8List.sublistView(publicKey, _kPkeSecretKeyLength, mlKemPublicKeyLength);

  final rHat = <Uint16List>[];
  for (var i = 0; i < _k; i++) {
    rHat.add(_nttEncode(_sampleCbdPrf(seed, i, _eta1)));
  }

  final tmp2 = _newPoly();
  final u = <Uint16List>[];
  for (var i = 0; i < _k; i++) {
    final e1 = _sampleCbdPrf(seed, _k + i, _eta2);
    final acc = _newPoly();
    for (var j = 0; j < _k; j++) {
      _polyAdd(acc, _multiplyNtts(_sampleNtt(_Xof128(rho, i, j)), rHat[j]));
    }
    _polyAdd(e1, _nttDecode(acc));
    u.add(e1);
    _polyAdd(tmp2, _multiplyNtts(tHat[i], rHat[i]));
  }

  final e2 = _sampleCbdPrf(seed, 2 * _k, _eta2);
  _polyAdd(e2, _nttDecode(tmp2));
  final v = _polyDecode(msg, 1); // Decompress_1: message bit -> 0 or ceil(q/2)
  _polyAdd(v, e2);

  final uBytes = _vecEncode(u, _du);
  final vBytes = _polyEncode(v, _dv);
  return Uint8List(mlKemCipherTextLength)
    ..setRange(0, uBytes.length, uBytes)
    ..setRange(uBytes.length, mlKemCipherTextLength, vBytes);
}

Uint8List _kpkeDecrypt(Uint8List cipherText, Uint8List secretKey) {
  final uLen = _du * (_n ~/ 8) * _k; // 960
  final u = _vecDecode(Uint8List.sublistView(cipherText, 0, uLen), _du);
  final v = _polyDecode(Uint8List.sublistView(cipherText, uLen, mlKemCipherTextLength), _dv);
  final sk = _vecDecode(secretKey, 12);

  final acc = _newPoly();
  for (var i = 0; i < _k; i++) {
    _polyAdd(acc, _multiplyNtts(sk[i], _nttEncode(u[i])));
  }
  _polySub(v, _nttDecode(acc));
  return _polyEncode(v, 1);
}

// --- ML-KEM -----------------------------------------------------------------

/// An ML-KEM-768 keypair.
class MlKemKeyPair {
  const MlKemKeyPair(this.publicKey, this.secretKey);
  final Uint8List publicKey;
  final Uint8List secretKey;
}

/// The output of [MlKem768.encapsulate].
class MlKemEncapsulation {
  const MlKemEncapsulation(this.cipherText, this.sharedSecret);
  final Uint8List cipherText;
  final Uint8List sharedSecret;
}

bool _constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// ML-KEM-768 (FIPS 203).
class MlKem768 {
  const MlKem768();

  /// Derives a keypair from a 64-byte seed (d || z). Deterministic: the same
  /// seed always yields the same keypair, which is what lets every device
  /// sharing an nsec derive one identity key.
  MlKemKeyPair keygen(Uint8List seed) {
    if (seed.length != mlKemSeedLength) {
      throw ArgumentError('seed must be $mlKemSeedLength bytes, got ${seed.length}');
    }
    final kpke = _kpkeKeygen(Uint8List.sublistView(seed, 0, 32));
    final publicKeyHash = _sha3_256(kpke.publicKey);
    // dk = dkPKE || ek || H(ek) || z
    final secretKey = Uint8List(mlKemSecretKeyLength)
      ..setRange(0, _kPkeSecretKeyLength, kpke.secretKey)
      ..setRange(_kPkeSecretKeyLength, _kPkeSecretKeyLength + mlKemPublicKeyLength, kpke.publicKey)
      ..setRange(2336, 2368, publicKeyHash)
      ..setRange(2368, 2400, Uint8List.sublistView(seed, 32, 64));
    return MlKemKeyPair(kpke.publicKey, secretKey);
  }

  /// FIPS 203 §7.2 modulus check: ek must survive ByteEncode12(ByteDecode12(ek))
  /// unchanged, which rejects coefficients that are not canonical mod q.
  void _validateModulus(Uint8List publicKey) {
    final eke = Uint8List.sublistView(publicKey, 0, _kPkeSecretKeyLength);
    if (!_constantTimeEquals(_vecEncode(_vecDecode(eke, 12), 12), eke)) {
      throw ArgumentError('ML-KEM.encapsulate: wrong publicKey modulus');
    }
  }

  /// Encapsulates to [publicKey]. [msg] is the 32-byte message; pass it only to
  /// reproduce a known vector — production callers must let it default to fresh
  /// CSPRNG bytes, since ML-KEM's security depends on that randomness.
  MlKemEncapsulation encapsulate(Uint8List publicKey, Uint8List msg) {
    if (publicKey.length != mlKemPublicKeyLength) {
      throw ArgumentError('publicKey must be $mlKemPublicKeyLength bytes');
    }
    if (msg.length != mlKemMessageLength) {
      throw ArgumentError('message must be $mlKemMessageLength bytes');
    }
    _validateModulus(publicKey);
    // (K, r) = G(m || H(ek))
    final g = Uint8List(mlKemMessageLength + 32)
      ..setRange(0, mlKemMessageLength, msg)
      ..setRange(mlKemMessageLength, mlKemMessageLength + 32, _sha3_256(publicKey));
    final kr = _sha3_512(g);
    final cipherText = _kpkeEncrypt(publicKey, msg, Uint8List.sublistView(kr, 32, 64));
    return MlKemEncapsulation(
        cipherText, Uint8List.fromList(Uint8List.sublistView(kr, 0, 32)));
  }

  /// Decapsulates [cipherText] with [secretKey].
  ///
  /// By design this never fails on a bad ciphertext: the Fujisaki-Okamoto
  /// transform's implicit rejection returns a pseudorandom secret derived from
  /// the secret key's z instead, so a wrong key surfaces downstream as an
  /// authentication failure rather than a distinguishable error here.
  Uint8List decapsulate(Uint8List cipherText, Uint8List secretKey) {
    if (secretKey.length != mlKemSecretKeyLength) {
      throw ArgumentError('secretKey must be $mlKemSecretKeyLength bytes');
    }
    if (cipherText.length != mlKemCipherTextLength) {
      throw ArgumentError('cipherText must be $mlKemCipherTextLength bytes');
    }
    final embeddedEk = Uint8List.sublistView(secretKey, _kPkeSecretKeyLength, 2336);
    final storedHash = Uint8List.sublistView(secretKey, 2336, 2368);
    if (!_constantTimeEquals(_sha3_256(embeddedEk), storedHash)) {
      throw ArgumentError('invalid secretKey: hash check failed');
    }
    final z = Uint8List.sublistView(secretKey, 2368, 2400);

    final msg = _kpkeDecrypt(cipherText, Uint8List.sublistView(secretKey, 0, _kPkeSecretKeyLength));
    final g = Uint8List(mlKemMessageLength + 32)
      ..setRange(0, mlKemMessageLength, msg)
      ..setRange(mlKemMessageLength, mlKemMessageLength + 32, storedHash);
    final kr = _sha3_512(g);
    final kHat = Uint8List.fromList(Uint8List.sublistView(kr, 0, 32));

    final cipherText2 = _kpkeEncrypt(embeddedEk, msg, Uint8List.sublistView(kr, 32, 64));
    if (_constantTimeEquals(cipherText, cipherText2)) return kHat;

    // Implicit rejection: Kbar = J(z || c).
    final jIn = Uint8List(32 + mlKemCipherTextLength)
      ..setRange(0, 32, z)
      ..setRange(32, 32 + mlKemCipherTextLength, cipherText);
    return _shake256(jIn, 32);
  }
}

/// The ML-KEM-768 instance used throughout the app.
const MlKem768 mlKem768 = MlKem768();

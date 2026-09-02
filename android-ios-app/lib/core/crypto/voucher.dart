import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

import 'keys.dart';

const List<int> voucherDenoms = [
  1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096
];

const int voucherMaxOutputs = 32;

const String voucherHtcDomain = 'Nymbot_Voucher_HashToCurve_v1';
const String voucherDleqDomain = 'Nymbot_Voucher_DLEQ_v1';

final ECDomainParameters _secp = ECCurve_secp256k1();

BigInt get _n => _secp.n;

Uint8List _sha256(Uint8List data) => SHA256Digest().process(data);

Uint8List _concat(List<Uint8List> parts) {
  var len = 0;
  for (final p in parts) {
    len += p.length;
  }
  final out = Uint8List(len);
  var at = 0;
  for (final p in parts) {
    out.setRange(at, at + p.length, p);
    at += p.length;
  }
  return out;
}

Uint8List _le32(int n) => Uint8List.fromList([
      n & 0xff,
      (n >> 8) & 0xff,
      (n >> 16) & 0xff,
      (n >> 24) & 0xff,
    ]);

BigInt _bytesToBigInt(Uint8List b) {
  var v = BigInt.zero;
  for (final byte in b) {
    v = (v << 8) | BigInt.from(byte);
  }
  return v;
}

BigInt voucherScalar(Uint8List bytes) => _bytesToBigInt(bytes) % _n;

String voucherScalarHex(BigInt v) => v.toRadixString(16).padLeft(64, '0');

BigInt voucherRandomScalar() {
  var v = BigInt.zero;
  while (v == BigInt.zero) {
    v = voucherScalar(randomBytes(32));
  }
  return v;
}

ECPoint voucherHashToCurve(Uint8List x) {
  final base = _sha256(_concat([
    Uint8List.fromList(voucherHtcDomain.codeUnits),
    x,
  ]));
  for (var i = 0; i < 512; i++) {
    final h = _sha256(_concat([base, _le32(i)]));
    try {
      final p = _secp.curve
          .decodePoint(Uint8List.fromList(<int>[0x02, ...h]));
      if (p != null && !p.isInfinity) return p;
    } catch (_) {}
  }
  throw StateError('hash-to-curve failed');
}

ECPoint voucherPointFromHex(String hex) {
  final p = _secp.curve.decodePoint(hexToBytes(hex));
  if (p == null || p.isInfinity) throw FormatException('bad point: $hex');
  return p;
}

String voucherPointHex(ECPoint p) => bytesToHex(p.getEncoded(true));

ECPoint voucherBlind(Uint8List x, BigInt r) =>
    (voucherHashToCurve(x) + (_secp.G * r))!;

ECPoint voucherUnblind(ECPoint blindSignature, ECPoint keysetKey, BigInt r) =>
    (blindSignature - (keysetKey * r)!)!;

bool voucherVerifyDleq({
  required String keyHex,
  required String blindedHex,
  required String signatureHex,
  required String e,
  required String s,
}) {
  try {
    final eScalar = BigInt.parse(e, radix: 16);
    final sScalar = BigInt.parse(s, radix: 16);
    if (eScalar <= BigInt.zero ||
        eScalar >= _n ||
        sScalar <= BigInt.zero ||
        sScalar >= _n) {
      return false;
    }
    final k = voucherPointFromHex(keyHex);
    final b = voucherPointFromHex(blindedHex);
    final c = voucherPointFromHex(signatureHex);
    final r1 = ((_secp.G * sScalar)! - (k * eScalar)!)!;
    final r2 = ((b * sScalar)! - (c * eScalar)!)!;
    final check = voucherScalar(_sha256(_concat([
      Uint8List.fromList(voucherDleqDomain.codeUnits),
      r1.getEncoded(true),
      r2.getEncoded(true),
      k.getEncoded(true),
      c.getEncoded(true),
    ])));
    return voucherScalarHex(check) == e.toLowerCase();
  } catch (_) {
    return false;
  }
}

List<int>? voucherSplitAmount(int amount) {
  final out = <int>[];
  var left = amount;
  for (var i = voucherDenoms.length - 1; i >= 0 && left > 0; i--) {
    final d = voucherDenoms[i];
    while (left >= d && out.length < voucherMaxOutputs) {
      out.add(d);
      left -= d;
    }
  }
  return left == 0 ? out : null;
}

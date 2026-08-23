// Validates the ML-KEM-768 port against the official NIST ACVP vectors
// (usnistgov/ACVP-Server, ML-KEM-*-FIPS203). This is independent of the PWA's
// vectors: matching noble only proves the two agree, whereas these prove both
// are right.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/ml_kem.dart';

Uint8List unhex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final v = jsonDecode(File('test/acvp-mlkem768.json').readAsStringSync())
      as Map<String, dynamic>;

  test('ACVP keyGen (${(v['keyGen'] as List).length} cases)', () {
    for (final e in v['keyGen'] as List) {
      // FIPS 203 Alg. 19: the 64-byte seed is d || z.
      final seed = Uint8List(64)
        ..setRange(0, 32, unhex(e['d'] as String))
        ..setRange(32, 64, unhex(e['z'] as String));
      final kp = mlKem768.keygen(seed);
      expect(hex(kp.publicKey), (e['ek'] as String).toLowerCase(), reason: 'ek tcId=${e['tcId']}');
      expect(hex(kp.secretKey), (e['dk'] as String).toLowerCase(), reason: 'dk tcId=${e['tcId']}');
    }
  });

  test('ACVP encapsulation (${(v['encap'] as List).length} cases)', () {
    for (final e in v['encap'] as List) {
      final r = mlKem768.encapsulate(unhex(e['ek'] as String), unhex(e['m'] as String));
      expect(hex(r.cipherText), (e['c'] as String).toLowerCase(), reason: 'c tcId=${e['tcId']}');
      expect(hex(r.sharedSecret), (e['k'] as String).toLowerCase(), reason: 'k tcId=${e['tcId']}');
    }
  });

  test('ACVP decapsulation (${(v['decap'] as List).length} cases)', () {
    for (final e in v['decap'] as List) {
      expect(hex(mlKem768.decapsulate(unhex(e['c'] as String), unhex(e['dk'] as String))),
          (e['k'] as String).toLowerCase(),
          reason: 'k tcId=${e['tcId']}');
    }
  });
}

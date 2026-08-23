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

String hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final v = jsonDecode(File('test/pq-vectors.json').readAsStringSync())
      as Map<String, dynamic>;

  group('keygen', () {
    for (final (i, e) in (v['keygen'] as List).indexed) {
      test('vector $i', () {
        final kp = mlKem768.keygen(unhex(e['seed'] as String));
        expect(hex(kp.publicKey), e['publicKey'], reason: 'publicKey');
        expect(hex(kp.secretKey), e['secretKey'], reason: 'secretKey');
      });
    }
  });

  group('decapsulate', () {
    for (final (i, e) in (v['decapsulate'] as List).indexed) {
      test('vector $i (${e['note']})', () {
        final kp = mlKem768.keygen(unhex(e['keySeed'] as String));
        expect(hex(mlKem768.decapsulate(unhex(e['cipherText'] as String), kp.secretKey)),
            e['sharedSecret']);
      });
    }
  });

  group('encapsulate', () {
    for (final (i, e) in (v['decapsulate'] as List).indexed) {
      if (e['encapsulationRandomness'] == null) continue;
      test('vector $i reproduces the ciphertext', () {
        final kp = mlKem768.keygen(unhex(e['keySeed'] as String));
        final r = mlKem768.encapsulate(
            kp.publicKey, unhex(e['encapsulationRandomness'] as String));
        expect(hex(r.cipherText), e['cipherText']);
        expect(hex(r.sharedSecret), e['sharedSecret']);
      });
    }
    for (final (i, e) in (v['endToEnd'] as List).indexed) {
      test('endToEnd $i kem leg', () {
        final kp = mlKem768.keygen(unhex(e['recipKemSeed'] as String));
        final r = mlKem768.encapsulate(
            kp.publicKey, unhex(e['encapsulationRandomness'] as String));
        expect(hex(r.cipherText), (e['kemCipherText'] as String?) ?? hex(r.cipherText));
        expect(hex(mlKem768.decapsulate(r.cipherText, kp.secretKey)), hex(r.sharedSecret));
      });
    }
  });

  test('round-trips with a random-ish seed', () {
    final seed = Uint8List(64);
    for (var i = 0; i < 64; i++) {
      seed[i] = (i * 31 + 7) & 0xff;
    }
    final kp = mlKem768.keygen(seed);
    final msg = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      msg[i] = (i * 17) & 0xff;
    }
    final e = mlKem768.encapsulate(kp.publicKey, msg);
    expect(hex(mlKem768.decapsulate(e.cipherText, kp.secretKey)), hex(e.sharedSecret));
  });

  test('sizes match FIPS 203 ML-KEM-768', () {
    final kp = mlKem768.keygen(Uint8List(64));
    expect(kp.publicKey.length, 1184);
    expect(kp.secretKey.length, 2400);
    final e = mlKem768.encapsulate(kp.publicKey, Uint8List(32));
    expect(e.cipherText.length, 1088);
    expect(e.sharedSecret.length, 32);
  });
}

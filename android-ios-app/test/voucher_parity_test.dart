import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/voucher.dart';

void main() {
  final vectors = jsonDecode(
    File('test/voucher-vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  group('blind voucher parity with the worker', () {
    test('hash-to-curve matches the worker for every vector', () {
      for (final v in (vectors['htc'] as List).cast<Map<String, dynamic>>()) {
        final y = voucherHashToCurve(hexToBytes(v['x'] as String));
        expect(voucherPointHex(y), v['Y'] as String);
      }
    });

    test('blinding reproduces the exact point the worker signed', () {
      for (final f in (vectors['flows'] as List).cast<Map<String, dynamic>>()) {
        final b = voucherBlind(
          hexToBytes(f['x'] as String),
          BigInt.parse(f['r'] as String, radix: 16),
        );
        expect(voucherPointHex(b), f['B'] as String);
      }
    });

    test('the worker DLEQ proof verifies', () {
      for (final f in (vectors['flows'] as List).cast<Map<String, dynamic>>()) {
        expect(
          voucherVerifyDleq(
            keyHex: f['K'] as String,
            blindedHex: f['B'] as String,
            signatureHex: f['Cblind'] as String,
            e: f['e'] as String,
            s: f['s'] as String,
          ),
          isTrue,
        );
      }
    });

    test('a proof against the wrong keyset key is refused', () {
      final f = (vectors['flows'] as List).first as Map<String, dynamic>;
      final otherKey =
          ((vectors['keys'] as Map)['standard'] as Map)['2'] as String;
      expect(
        voucherVerifyDleq(
          keyHex: otherKey,
          blindedHex: f['B'] as String,
          signatureHex: f['Cblind'] as String,
          e: f['e'] as String,
          s: f['s'] as String,
        ),
        isFalse,
      );
    });

    test('a tampered scalar is refused', () {
      final f = (vectors['flows'] as List).first as Map<String, dynamic>;
      expect(
        voucherVerifyDleq(
          keyHex: f['K'] as String,
          blindedHex: f['B'] as String,
          signatureHex: f['Cblind'] as String,
          e: f['e'] as String,
          s: 'ff' * 31 + 'fe',
        ),
        isFalse,
      );
    });

    test('unblinding reproduces the token the worker will accept', () {
      for (final f in (vectors['flows'] as List).cast<Map<String, dynamic>>()) {
        final c = voucherUnblind(
          voucherPointFromHex(f['Cblind'] as String),
          voucherPointFromHex(f['K'] as String),
          BigInt.parse(f['r'] as String, radix: 16),
        );
        expect(voucherPointHex(c), f['C'] as String);
      }
    });
  });

  group('denomination splitting', () {
    test('splits like the PWA, largest first', () {
      expect(voucherSplitAmount(137), [128, 8, 1]);
      expect(voucherSplitAmount(1), [1]);
      expect(voucherSplitAmount(4095)!.length, 12);
    });

    test('refuses an amount that would need more than 32 vouchers', () {
      expect(voucherSplitAmount(98303), isNull);
    });
  });

  group('scalars', () {
    test('random scalars are in range and non-zero', () {
      for (var i = 0; i < 32; i++) {
        final v = voucherRandomScalar();
        expect(v > BigInt.zero, isTrue);
        expect(voucherScalarHex(v).length, 64);
      }
    });
  });
}

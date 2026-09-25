import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/features/identity/pq_root.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_crypto.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_service.dart';

String? dec(String payload, Uint8List key) =>
    decryptBackupSecret(payload, key)?.secretHex;

void main() {
  final vector = jsonDecode(File('test/key-backup-vector.json').readAsStringSync())
      as Map<String, dynamic>;
  final secretHex = vector['secretKeyHex'] as String;
  final cases = (vector['cases'] as List).cast<Map<String, dynamic>>();

  BackupCloud cloudFor(String provider) =>
      BackupCloud.values.firstWhere((c) => c.name == provider);

  test('vector format and parameters match', () {
    expect(vector['format'], kKeyBackupFormat);
    expect(vector['pbkdf2']['iterations'], kKeyBackupIterations);
    expect(vector['pbkdf2']['keyBytes'], kKeyBackupKeyBytes);
    expect(vector['contexts']['google'], BackupCloud.google.context);
    expect(vector['contexts']['apple'], BackupCloud.apple.context);
    expect(getPublicKeyHex(hexToBytes(secretHex)), vector['pubkeyHex']);
  });

  for (final c in cases) {
    final provider = c['provider'] as String;
    group('vector $provider', () {
      final cloud = cloudFor(provider);
      late Uint8List key;

      setUpAll(() async {
        key = await deriveBackupKey(
            c['pin'] as String, backupSalt(cloud, c['accountId'] as String));
      });

      test('salt', () {
        expect(bytesToHex(backupSalt(cloud, c['accountId'] as String)),
            c['saltHex']);
      });

      test('key', () {
        expect(bytesToHex(key), c['keyHex']);
      });

      test('legacy payload with the fixed nonce', () {
        final payload = nip44.encrypt(secretHex, key,
            nonce: hexToBytes(c['nonceHex'] as String));
        expect(payload, c['payload']);
      });

      test('decrypts back to the secret key', () {
        expect(dec(c['payload'] as String, key), secretHex);
      });

      test('the other provider context cannot decrypt it', () async {
        final other = BackupCloud.values.firstWhere((x) => x != cloud);
        final wrong = deriveBackupKeySync(c['pin'] as String,
            backupSalt(other, c['accountId'] as String));
        expect(dec(c['payload'] as String, wrong), isNull);
      });
    });
  }

  test('synchronous derivation matches the isolate one', () {
    final c = cases.first;
    final salt = hexToBytes(c['saltHex'] as String);
    expect(bytesToHex(deriveBackupKeySync(c['pin'] as String, salt)),
        c['keyHex']);
  });

  test('a fresh payload uses a random nonce and still round-trips', () {
    final key = hexToBytes(cases.first['keyHex'] as String);
    final a = encryptBackupSecret(secretHex, key);
    final b = encryptBackupSecret(secretHex, key);
    expect(a, isNot(b));
    expect(dec(a, key), secretHex);
  });

  test('garbage, wrong keys and non-key plaintexts decrypt to null', () {
    final key = hexToBytes(cases.first['keyHex'] as String);
    expect(dec('not base64 at all', key), isNull);
    expect(dec(cases.first['payload'] as String, Uint8List(32)),
        isNull);
    expect(dec(cases.first['payload'] as String, key), secretHex);
  });

  test('PIN validation', () {
    expect(isValidBackupPin('1234'), isTrue);
    expect(isValidBackupPin('12345678'), isTrue);
    expect(isValidBackupPin('123'), isFalse);
    expect(isValidBackupPin('123456789'), isFalse);
    expect(isValidBackupPin('12a4'), isFalse);
    expect(isValidBackupPin('１２３４'), isFalse);
    expect(() => deriveBackupKeySync('12', Uint8List(32)), throwsArgumentError);
    expect(deriveBackupKey('abcd', Uint8List(32)), throwsArgumentError);
  });

  test('encrypt rejects anything but a 64-char hex secret', () {
    final key = Uint8List(32);
    expect(() => encryptBackupSecret('abc', key), throwsArgumentError);
    expect(() => encryptBackupSecret('zz' * 32, key), throwsArgumentError);
  });

  test('wipeBytes zeroes the buffer', () {
    final b = Uint8List.fromList([1, 2, 3]);
    wipeBytes(b);
    expect(b, [0, 0, 0]);
  });

  test('PinThrottle grows the delay after each failure and resets', () {
    var now = DateTime(2026, 1, 1);
    final t = PinThrottle(now: () => now);
    expect(t.remaining, Duration.zero);
    t.fail();
    expect(t.remaining, const Duration(seconds: 2));
    t.fail();
    expect(t.remaining, const Duration(seconds: 4));
    t.fail();
    expect(t.remaining, const Duration(seconds: 8));
    now = now.add(const Duration(seconds: 8));
    expect(t.remaining, Duration.zero);
    for (var i = 0; i < 20; i++) {
      t.fail();
    }
    expect(t.remaining, const Duration(seconds: 300));
    t.reset();
    expect(t.remaining, Duration.zero);
    expect(t.failures, 0);
  });

  test('shortNpub keeps the head and tail', () {
    final npub = BackupCandidate(
      secretHex: secretHex,
      pubkeyHex: vector['pubkeyHex'] as String,
      entries: [],
    ).npub;
    final short = shortNpub(npub);
    expect(short.startsWith(npub.substring(0, 12)), isTrue);
    expect(short.endsWith(npub.substring(npub.length - 6)), isTrue);
    expect(short.length, lessThan(npub.length));
  });
  group('bundle', () {
    final bundle = vector['bundle'] as Map<String, dynamic>;
    final pq = bundle['pqCode'] as String;
    final bundleCases = (bundle['cases'] as List).cast<Map<String, dynamic>>();

    test('plaintext has exactly the vector keys, order and spacing', () {
      expect(encodeBackupBundle(secretHex, pqCode: pq), bundle['plaintext']);
      expect(encodeBackupBundle(secretHex), '{"v":1,"sk":"$secretHex"}');
      expect(encodeBackupBundle(secretHex.toUpperCase(), pqCode: pq),
          bundle['plaintext']);
    });

    for (final c in bundleCases) {
      test('${c['provider']} payload with the fixed nonce and back', () {
        final key = hexToBytes(c['keyHex'] as String);
        final payload = encryptBackupSecret(secretHex, key,
            pqCode: pq, nonce: hexToBytes(c['nonceHex'] as String));
        expect(payload, c['payload']);
        expect(nip44.decrypt(payload, key), bundle['plaintext']);
        final back = decryptBackupSecret(c['payload'] as String, key)!;
        expect(back.secretHex, secretHex);
      });
    }

    test('the vector code is not a real nympq1 code, so it is skipped', () {
      expect(pqRootFromCode(pq), isNull);
      final back = parseBackupPlaintext(bundle['plaintext'] as String)!;
      expect(back.secretHex, secretHex);
      expect(back.pqCode, isNull);
      expect(back.pqIgnored, isTrue);
    });

    test('a real code round-trips', () {
      final code = pqRootToCode(randomBytes(32));
      final key = hexToBytes(bundleCases.first['keyHex'] as String);
      final back = decryptBackupSecret(
          encryptBackupSecret(secretHex, key, pqCode: code), key)!;
      expect(back.secretHex, secretHex);
      expect(back.pqCode, code);
      expect(back.pqIgnored, isFalse);
    });

    test('the legacy bare-hex payloads still restore, without a code', () {
      for (final c in cases) {
        final back = decryptBackupSecret(
            c['payload'] as String, hexToBytes(c['keyHex'] as String))!;
        expect(back.secretHex, secretHex);
        expect(back.pqCode, isNull);
        expect(back.pqIgnored, isFalse);
      }
    });

    test('a bad pq is ignored and flagged, never failing the key', () {
      for (final bad in [
        '"nympq1notacode"',
        '"npub1qqqqqqqq"',
        '42',
        '""',
      ]) {
        final back =
            parseBackupPlaintext('{"v":1,"sk":"$secretHex","pq":$bad}')!;
        expect(back.secretHex, secretHex, reason: bad);
        expect(back.pqCode, isNull, reason: bad);
        expect(back.pqIgnored, isTrue, reason: bad);
      }
      final flipped = pq.substring(0, pq.length - 1) +
          (pq.endsWith('q') ? 'p' : 'q');
      final back =
          parseBackupPlaintext('{"v":1,"sk":"$secretHex","pq":"$flipped"}')!;
      expect(back.pqIgnored, isTrue);
    });

    test('an absent or null pq is not a note', () {
      for (final plain in [
        '{"v":1,"sk":"$secretHex"}',
        '{"v":1,"sk":"$secretHex","pq":null}',
      ]) {
        final back = parseBackupPlaintext(plain)!;
        expect(back.pqCode, isNull);
        expect(back.pqIgnored, isFalse);
      }
    });

    test('anything without a valid sk is rejected', () {
      for (final plain in [
        '{"v":2,"sk":"$secretHex","pq":"$pq"}',
        '{"v":1,"sk":"abc","pq":"$pq"}',
        '{"v":1,"pq":"$pq"}',
        '["$secretHex"]',
        'nope',
        secretHex.substring(1),
      ]) {
        expect(parseBackupPlaintext(plain), isNull, reason: plain);
      }
    });

    test('encoding something that is not a nympq1 string throws', () {
      for (final bad in ['npub1abc', 'nympq1"x', 'NYMPQ1ABC', 'nympq1 a']) {
        expect(() => encodeBackupBundle(secretHex, pqCode: bad),
            throwsArgumentError,
            reason: bad);
      }
    });
  });
}

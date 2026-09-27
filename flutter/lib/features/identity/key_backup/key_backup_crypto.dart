import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart'
    show HMac, KeyDerivator, PBKDF2KeyDerivator, Pbkdf2Parameters, SHA256Digest;

import '../../../core/crypto/keys.dart';
import '../../../core/crypto/nip44.dart' as nip44;
import '../../../core/crypto/pq.dart' as pq;
import '../pq_root.dart';

const String kKeyBackupFormat = 'nym-key-backup-v1';
const int kKeyBackupIterations = 600000;
const int kKeyBackupKeyBytes = 32;

enum BackupCloud {
  google('nym-google-backup', 'Google'),
  apple('nym-apple-backup', 'Apple');

  const BackupCloud(this.context, this.label);

  final String context;
  final String label;
}

typedef BackupKeyDeriver = Future<Uint8List> Function(
    String pin, Uint8List salt);

final RegExp _pinPattern = RegExp(r'^[0-9]{4,8}$');
final RegExp _secretPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _pqTextPattern = RegExp(r'^nympq1[02-9ac-hj-np-z]+$');

bool isValidBackupPin(String pin) => _pinPattern.hasMatch(pin);

Uint8List backupSalt(BackupCloud cloud, String accountId) =>
    backupSaltFor(cloud.context, accountId);

Uint8List backupSaltFor(String context, String accountId) {
  final mac = crypto.Hmac(crypto.sha256, utf8.encode(context));
  return Uint8List.fromList(mac.convert(utf8.encode(accountId)).bytes);
}

Uint8List deriveBackupKeySync(String pin, Uint8List salt) {
  if (!isValidBackupPin(pin)) {
    throw ArgumentError('PIN must be 4 to 8 digits');
  }
  final KeyDerivator derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, kKeyBackupIterations, kKeyBackupKeyBytes));
  return derivator.process(Uint8List.fromList(utf8.encode(pin)));
}

Uint8List _deriveInIsolate(List<Object> args) =>
    deriveBackupKeySync(args[0] as String, args[1] as Uint8List);

Future<Uint8List> deriveBackupKey(String pin, Uint8List salt) {
  if (!isValidBackupPin(pin)) {
    return Future.error(ArgumentError('PIN must be 4 to 8 digits'));
  }
  return compute(_deriveInIsolate, <Object>[pin, Uint8List.fromList(salt)]);
}

class BackupSecret {
  const BackupSecret({
    required this.secretHex,
    this.pqCode,
    this.pqIgnored = false,
    this.created = false,
  });

  final String secretHex;
  final String? pqCode;
  final bool pqIgnored;
  final bool created;
}

bool isValidBackupPqCode(String code) => pqRootFromCode(code) != null;

String newBackupPqCode() => pqRootToCode(pq.pqGenerateRoot());

String encodeBackupBundle(String secretHex, {String? pqCode}) {
  final sk = secretHex.toLowerCase();
  if (!_secretPattern.hasMatch(sk)) {
    throw ArgumentError('secret must be 64 hex characters');
  }
  final pq = pqCode?.trim();
  if (pq == null || pq.isEmpty) return '{"v":1,"sk":"$sk"}';
  if (!_pqTextPattern.hasMatch(pq)) {
    throw ArgumentError('pq must be a nympq1 code');
  }
  return '{"v":1,"sk":"$sk","pq":"$pq"}';
}

BackupSecret? parseBackupPlaintext(String plain) {
  if (_secretPattern.hasMatch(plain)) return BackupSecret(secretHex: plain);
  final Object? decoded;
  try {
    decoded = jsonDecode(plain);
  } catch (_) {
    return null;
  }
  if (decoded is! Map || decoded['v'] != 1) return null;
  final sk = decoded['sk'];
  if (sk is! String) return null;
  final secret = sk.toLowerCase();
  if (!_secretPattern.hasMatch(secret)) return null;
  if (hexToBytes(secret).length != 32) return null;
  if (!decoded.containsKey('pq') || decoded['pq'] == null) {
    return BackupSecret(secretHex: secret);
  }
  final pq = decoded['pq'];
  if (pq is String && isValidBackupPqCode(pq.trim())) {
    return BackupSecret(secretHex: secret, pqCode: pq.trim());
  }
  return BackupSecret(secretHex: secret, pqIgnored: true);
}

String encryptBackupSecret(String secretHex, Uint8List key,
    {String? pqCode, Uint8List? nonce}) {
  return nip44.encrypt(encodeBackupBundle(secretHex, pqCode: pqCode), key,
      nonce: nonce);
}

BackupSecret? decryptBackupSecret(String payload, Uint8List key) {
  try {
    return parseBackupPlaintext(nip44.decrypt(payload.trim(), key));
  } catch (_) {
    return null;
  }
}

void wipeBytes(Uint8List? bytes) {
  if (bytes == null) return;
  bytes.fillRange(0, bytes.length, 0);
}

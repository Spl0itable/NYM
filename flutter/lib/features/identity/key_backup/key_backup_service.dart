import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/crypto/bech32_codec.dart' as bech32;
import '../../../core/crypto/keys.dart';
import 'key_backup_crypto.dart';
import 'key_backup_store.dart';

class BackupCandidate {
  BackupCandidate({
    required this.secretHex,
    required this.pubkeyHex,
    required this.entries,
    this.pqCode,
    this.pqIgnored = false,
  });

  final String secretHex;
  final String? pqCode;
  final bool pqIgnored;
  final String pubkeyHex;
  final List<BackupEntry> entries;

  String get npub => bech32.encodeNpub(pubkeyHex);

  BackupSecret get backup =>
      BackupSecret(secretHex: secretHex, pqCode: pqCode, pqIgnored: pqIgnored);
}

String shortNpub(String npub) {
  if (npub.length <= 20) return npub;
  return '${npub.substring(0, 12)}…${npub.substring(npub.length - 6)}';
}

class KeyBackupSession {
  KeyBackupSession({
    required this.store,
    required this.accountId,
    required BackupKeyDeriver deriver,
    Uint8List? Function()? nonce,
  })  : _deriver = deriver,
        _nonce = nonce;

  final KeyBackupStore store;
  final String accountId;
  final BackupKeyDeriver _deriver;
  final Uint8List? Function()? _nonce;

  static Future<KeyBackupSession> open(
    KeyBackupStore store, {
    required BackupKeyDeriver deriver,
  }) async {
    final accountId = await store.signIn();
    return KeyBackupSession(store: store, accountId: accountId, deriver: deriver);
  }

  Future<Uint8List> deriveKey(String pin) {
    if (!isValidBackupPin(pin)) {
      return Future.error(ArgumentError('PIN must be 4 to 8 digits'));
    }
    return _deriver(pin, backupSalt(store.cloud, accountId));
  }

  Future<List<BackupEntry>> list() => store.list();

  Future<List<BackupCandidate>> candidates(
      Uint8List key, List<BackupEntry> entries) async {
    final byPubkey = <String, BackupCandidate>{};
    for (final entry in entries) {
      String payload;
      try {
        payload = await store.read(entry);
      } on KeyBackupAuthExpired {
        rethrow;
      } catch (_) {
        continue;
      }
      final bundle = decryptBackupSecret(payload, key);
      if (bundle == null) continue;
      final secret = bundle.secretHex;
      final sk = hexToBytes(secret);
      final String pubkey;
      try {
        pubkey = getPublicKeyHex(sk);
      } catch (_) {
        continue;
      } finally {
        wipeBytes(sk);
      }
      final existing = byPubkey[pubkey];
      if (existing != null) {
        existing.entries.add(entry);
        if (existing.pqCode == null &&
            (bundle.pqCode != null || bundle.pqIgnored)) {
          byPubkey[pubkey] = BackupCandidate(
            secretHex: secret,
            pubkeyHex: pubkey,
            entries: existing.entries,
            pqCode: bundle.pqCode,
            pqIgnored: bundle.pqCode == null,
          );
        }
      } else {
        byPubkey[pubkey] = BackupCandidate(
          secretHex: secret,
          pubkeyHex: pubkey,
          entries: [entry],
          pqCode: bundle.pqCode,
          pqIgnored: bundle.pqIgnored,
        );
      }
    }
    return byPubkey.values.toList();
  }

  Future<List<BackupEntry>> entriesFor(
      Uint8List key, List<BackupEntry> entries, String pubkeyHex) async {
    final found = await candidates(key, entries);
    return [
      for (final c in found)
        if (c.pubkeyHex == pubkeyHex.toLowerCase()) ...c.entries,
    ];
  }

  Future<void> upload(Uint8List key, String secretHex, {String? pqCode}) async {
    final payload = encryptBackupSecret(secretHex, key,
        pqCode: pqCode, nonce: _nonce?.call());
    await store.write(payload);
  }

  Future<void> deleteEntries(List<BackupEntry> entries) async {
    for (final e in entries) {
      await store.delete(e);
    }
  }
}

class PinThrottle {
  PinThrottle({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  int _failures = 0;
  DateTime? _until;

  int get failures => _failures;

  Duration get remaining {
    final until = _until;
    if (until == null) return Duration.zero;
    final left = until.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  static Duration delayAfter(int failures) {
    if (failures <= 0) return Duration.zero;
    final seconds = math.min(300, 1 << math.min(failures, 9));
    return Duration(seconds: seconds);
  }

  void fail() {
    _failures++;
    _until = _now().add(delayAfter(_failures));
  }

  void reset() {
    _failures = 0;
    _until = null;
  }

  static final Map<BackupCloud, PinThrottle> _shared = {};

  static PinThrottle forCloud(BackupCloud cloud) =>
      _shared.putIfAbsent(cloud, PinThrottle.new);

  static void resetAll() => _shared.clear();
}

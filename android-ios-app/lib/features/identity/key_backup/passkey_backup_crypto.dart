import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../../core/constants/event_kinds.dart';
import '../../../core/crypto/keys.dart';
import '../../../core/crypto/nip44.dart' as nip44;
import '../../../core/crypto/schnorr.dart';
import '../../../models/nostr_event.dart';
import 'key_backup_crypto.dart';

const String kPasskeyBackupFormat = 'nym-passkey-backup-v1';
const String kPasskeyPrfSaltLabel = 'nym-key-backup-v1';
const String kPasskeyEncInfo = 'nym-passkey-enc';
const String kPasskeyLocatorInfo = 'nym-passkey-locator';
const String kPasskeyBackupDTag = 'nym-key-backup';
const int kPasskeyBackupKind = EventKind.appData;

const List<String> kPasskeyFixedRelays = <String>[
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://relay.nostr.band',
  'wss://nostr.mom',
];

final BigInt _secpN = BigInt.parse(
  'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
  radix: 16,
);

Uint8List passkeyPrfSalt() => Uint8List.fromList(
    crypto.sha256.convert(utf8.encode(kPasskeyPrfSaltLabel)).bytes);

Uint8List _hkdf(Uint8List ikm, String info) {
  final prk = nip44.hkdfExtract(Uint8List(0), ikm);
  return nip44.hkdfExpand(prk, Uint8List.fromList(utf8.encode(info)), 32);
}

class PasskeyBackupKeys {
  PasskeyBackupKeys._(this.encKey, this.locatorSecret, this.locatorPubkey);

  factory PasskeyBackupKeys.fromPrf(Uint8List prfOutput) {
    final enc = _hkdf(prfOutput, kPasskeyEncInfo);
    final locator = _hkdf(prfOutput, kPasskeyLocatorInfo);
    var d = BigInt.zero;
    for (final b in locator) {
      d = (d << 8) | BigInt.from(b);
    }
    if (d == BigInt.zero || d >= _secpN) {
      enc.fillRange(0, enc.length, 0);
      locator.fillRange(0, locator.length, 0);
      throw StateError('locator key out of range');
    }
    return PasskeyBackupKeys._(enc, locator, getPublicKeyHex(locator));
  }

  final Uint8List encKey;
  final Uint8List locatorSecret;
  final String locatorPubkey;

  String encrypt(String secretHex, {String? pqCode, Uint8List? nonce}) =>
      nip44.encrypt(encodeBackupBundle(secretHex, pqCode: pqCode), encKey,
          nonce: nonce);

  BackupSecret? decrypt(String payload) {
    try {
      return parseBackupPlaintext(nip44.decrypt(payload.trim(), encKey));
    } catch (_) {
      return null;
    }
  }

  NostrEvent buildEvent(String secretHex,
      {required int createdAt, String? pqCode, Uint8List? nonce}) {
    return finalizeEvent(
      UnsignedEvent(
        pubkey: locatorPubkey,
        createdAt: createdAt,
        kind: kPasskeyBackupKind,
        tags: const [
          ['d', kPasskeyBackupDTag],
        ],
        content: encrypt(secretHex, pqCode: pqCode, nonce: nonce),
      ),
      locatorSecret,
    );
  }

  Map<String, Object> get filter => {
        'kinds': [kPasskeyBackupKind],
        'authors': [locatorPubkey],
        '#d': [kPasskeyBackupDTag],
      };

  BackupSecret? secretFromEvents(Iterable<NostrEvent> events) {
    final valid = events
        .where((e) =>
            e.kind == kPasskeyBackupKind &&
            e.pubkey == locatorPubkey &&
            e.tagValue('d') == kPasskeyBackupDTag &&
            verifyEvent(e))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (valid.isEmpty) return null;
    return decrypt(valid.first.content);
  }

  void wipe() {
    encKey.fillRange(0, encKey.length, 0);
    locatorSecret.fillRange(0, locatorSecret.length, 0);
  }
}

Uint8List encodeLargeBlob(String secretHex, {String? pqCode}) =>
    Uint8List.fromList(
        utf8.encode(encodeBackupBundle(secretHex, pqCode: pqCode)));

BackupSecret? decodeLargeBlob(Uint8List? blob) {
  if (blob == null || blob.isEmpty) return null;
  try {
    return parseBackupPlaintext(utf8.decode(blob));
  } catch (_) {
    return null;
  }
}

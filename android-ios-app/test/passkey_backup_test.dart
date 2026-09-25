import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/features/identity/pq_root.dart';
import 'package:nym_bar/core/crypto/schnorr.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_config.dart';
import 'package:nym_bar/features/identity/key_backup/passkey_backup_crypto.dart';
import 'package:nym_bar/features/identity/key_backup/passkey_backup_service.dart';
import 'package:nym_bar/models/nostr_event.dart';

import 'passkey_fakes.dart';

void main() {
  final v = jsonDecode(File('test/passkey-backup-vector.json').readAsStringSync())
      as Map<String, dynamic>;
  final prf = hexToBytes(v['prfOutputHex'] as String);
  final secret = v['secretKeyHex'] as String;

  group('vector', () {
    test('format and labels', () {
      expect(v['format'], kPasskeyBackupFormat);
      expect(v['labels']['enc'], kPasskeyEncInfo);
      expect(v['labels']['locator'], kPasskeyLocatorInfo);
      expect(v['event']['kind'], kPasskeyBackupKind);
      expect(v['event']['dTag'], kPasskeyBackupDTag);
    });

    test('prf salt', () {
      expect(bytesToHex(passkeyPrfSalt()), v['prfSaltHex']);
    });

    test('enc key and locator', () {
      final keys = PasskeyBackupKeys.fromPrf(prf);
      expect(bytesToHex(keys.encKey), v['encKeyHex']);
      expect(bytesToHex(keys.locatorSecret), v['locatorSecretHex']);
      expect(keys.locatorPubkey, v['locatorPubkeyHex']);
    });

    test('legacy payload with the fixed nonce and back', () {
      final keys = PasskeyBackupKeys.fromPrf(prf);
      final payload = nip44.encrypt(secret, keys.encKey,
          nonce: hexToBytes(v['nonceHex'] as String));
      expect(payload, v['payload']);
      expect(keys.decrypt(v['payload'] as String)?.secretHex, secret);
    });

    test('wipe zeroes the derived keys', () {
      final keys = PasskeyBackupKeys.fromPrf(prf);
      keys.wipe();
      expect(keys.encKey.every((b) => b == 0), isTrue);
      expect(keys.locatorSecret.every((b) => b == 0), isTrue);
    });
  });

  group('event', () {
    test('is a signed kind 30078 by the locator with the d tag', () {
      final keys = PasskeyBackupKeys.fromPrf(prf);
      final e = keys.buildEvent(secret, createdAt: 1700000000);
      expect(e.kind, 30078);
      expect(e.pubkey, v['locatorPubkeyHex']);
      expect(e.tags, [
        ['d', 'nym-key-backup'],
      ]);
      expect(verifyEvent(e), isTrue);
      expect(keys.decrypt(e.content)?.secretHex, secret);
      expect(e.content, isNot(contains(secret)));
      expect(keys.filter, {
        'kinds': [30078],
        'authors': [v['locatorPubkeyHex']],
        '#d': ['nym-key-backup'],
      });
    });

    test('restore takes the newest valid event only', () {
      final keys = PasskeyBackupKeys.fromPrf(prf);
      final other = bytesToHex(generatePrivateKey());
      final older = keys.buildEvent(other, createdAt: 100);
      final newer = keys.buildEvent(secret, createdAt: 200);
      final forged = NostrEvent.fromJson({
        ...keys.buildEvent(other, createdAt: 300).toJson(),
        'sig': '0' * 128,
      });
      final stranger = finalizeEvent(
        UnsignedEvent(
          pubkey: '',
          createdAt: 400,
          kind: 30078,
          tags: const [
            ['d', 'nym-key-backup'],
          ],
          content: keys.encrypt(other),
        ),
        generatePrivateKey(),
      );
      expect(keys.secretFromEvents([older, forged, newer, stranger])?.secretHex,
          secret);
      expect(keys.secretFromEvents([]), isNull);
    });
  });

  group('largeBlob', () {
    test('encodes the JSON the other apps write', () {
      expect(utf8.decode(encodeLargeBlob(secret)),
          '{"v":1,"sk":"$secret"}');
      expect(decodeLargeBlob(encodeLargeBlob(secret))?.secretHex, secret);
    });

    test('rejects anything else', () {
      expect(decodeLargeBlob(null), isNull);
      expect(decodeLargeBlob(Uint8List(0)), isNull);
      expect(decodeLargeBlob(utf8.encode('{"v":2,"sk":"$secret"}')), isNull);
      expect(decodeLargeBlob(utf8.encode('{"v":1,"sk":"abc"}')), isNull);
      expect(decodeLargeBlob(utf8.encode('nope')), isNull);
    });
  });

  group('bundle', () {
    final bundle = v['bundle'] as Map<String, dynamic>;
    final plaintext = bundle['plaintext'] as String;
    final vectorPq = (jsonDecode(plaintext) as Map)['pq'] as String;
    final realPq = pqRootToCode(randomBytes(32));

    test('payload with the fixed nonce and back', () {
      final keys = PasskeyBackupKeys.fromPrf(prf);
      final payload = keys.encrypt(secret,
          pqCode: vectorPq, nonce: hexToBytes(bundle['nonceHex'] as String));
      expect(payload, bundle['payload']);
      expect(nip44.decrypt(payload, keys.encKey), plaintext);
      final back = keys.decrypt(bundle['payload'] as String)!;
      expect(back.secretHex, secret);
      expect(back.pqIgnored, isTrue);
    });

    test('the legacy payload still restores', () {
      final back =
          PasskeyBackupKeys.fromPrf(prf).decrypt(v['payload'] as String)!;
      expect(back.secretHex, secret);
      expect(back.pqCode, isNull);
      expect(back.pqIgnored, isFalse);
    });

    test('largeBlob holds the same bundle', () {
      final blob = encodeLargeBlob(secret, pqCode: vectorPq);
      expect(utf8.decode(blob), bundle['largeBlob']);
      expect(decodeLargeBlob(blob)!.secretHex, secret);
      final real = decodeLargeBlob(encodeLargeBlob(secret, pqCode: realPq))!;
      expect(real.pqCode, realPq);
    });

    test('the event carries the code for restore', () {
      final keys = PasskeyBackupKeys.fromPrf(prf);
      final e = keys.buildEvent(secret, createdAt: 1700000000, pqCode: realPq);
      expect(keys.secretFromEvents([e])?.pqCode, realPq);
    });

    test('backUp with a code publishes the bundle and restore returns it',
        () async {
      final platform = FakePasskeyPlatform(prf: prf);
      final service = fakePasskeyService(platform, FakeRelays());
      await service.backUp(
          secretHex: secret,
          pubkeyHex: getPublicKeyHex(hexToBytes(secret)),
          pqCode: realPq);
      final back = await service.restore();
      expect(back.secretHex, secret);
      expect(back.pqCode, realPq);
    });

    test('backUp through largeBlob writes the bundle', () async {
      final platform = FakePasskeyPlatform()
        ..prfEnabled = false
        ..largeBlob = true;
      final service = fakePasskeyService(platform, FakeRelays());
      await service.backUp(
          secretHex: secret,
          pubkeyHex: getPublicKeyHex(hexToBytes(secret)),
          pqCode: vectorPq);
      expect(utf8.decode(platform.storedBlob!), bundle['largeBlob']);
    });
  });

  group('Android WebAuthn JSON', () {
    test('create options carry prf, largeBlob and a resident key', () {
      final json = jsonDecode(passkeyCreateRequestJson(
        rpId: 'web.nymchat.app',
        rpName: 'Nymchat',
        userId: Uint8List.fromList(List.filled(16, 1)),
        userName: 'Nymchat key backup · npub1…',
        challenge: Uint8List.fromList(List.filled(32, 2)),
        prfSalt: passkeyPrfSalt(),
      ));
      expect(json['rp'], {'id': 'web.nymchat.app', 'name': 'Nymchat'});
      expect(json['user']['displayName'], json['user']['name']);
      expect((json['pubKeyCredParams'] as List).map((p) => p['alg']), [-7, -257]);
      expect(json['authenticatorSelection']['residentKey'], 'required');
      expect(json['authenticatorSelection']['userVerification'], 'required');
      expect(json['extensions']['largeBlob'], {'support': 'preferred'});
      final first = json['extensions']['prf']['eval']['first'] as String;
      expect(first, isNot(contains('=')));
      expect(base64Url.decode(base64Url.normalize(first)), passkeyPrfSalt());
    });

    test('get options for restore and for a largeBlob write', () {
      final restore = jsonDecode(passkeyGetRequestJson(
        rpId: 'web.nymchat.app',
        challenge: Uint8List(32),
        prfSalt: passkeyPrfSalt(),
        largeBlobRead: true,
      ));
      expect(restore['allowCredentials'], isEmpty);
      expect(restore['userVerification'], 'required');
      expect(restore['extensions']['largeBlob'], {'read': true});
      expect(restore['extensions']['prf'], isNotNull);
      final write = jsonDecode(passkeyGetRequestJson(
        rpId: 'web.nymchat.app',
        challenge: Uint8List(32),
        allowCredentials: [Uint8List.fromList([1, 2, 3])],
        largeBlobWrite: Uint8List.fromList([4, 5]),
      ));
      expect(write['allowCredentials'], [
        {'type': 'public-key', 'id': 'AQID'},
      ]);
      expect(write['extensions'], {
        'largeBlob': {'write': 'BAU'},
      });
    });

    test('responses parse into results', () {
      final created = parsePasskeyCreateResponse(jsonEncode({
        'id': 'AQID',
        'rawId': 'AQID',
        'clientExtensionResults': {
          'prf': {
            'enabled': true,
            'results': {'first': base64Url.encode(prf).replaceAll('=', '')},
          },
          'largeBlob': {'supported': true},
        },
      }));
      expect(created.credentialId, [1, 2, 3]);
      expect(created.prfFirst, prf);
      expect(created.prfEnabled, isTrue);
      expect(created.largeBlobSupported, isTrue);
      final got = parsePasskeyGetResponse(jsonEncode({
        'id': 'AQID',
        'clientExtensionResults': {
          'largeBlob': {'blob': 'BAU', 'written': false},
        },
      }));
      expect(got.prfFirst, isNull);
      expect(got.largeBlob, [4, 5]);
      expect(got.largeBlobWritten, isFalse);
      expect(parsePasskeyCreateResponse('{}').prfEnabled, isFalse);
    });

    test('platform error codes map to backup errors', () {
      expect(passkeyErrorFromCode('canceled'), PasskeyBackupError.canceled);
      expect(passkeyErrorFromCode('none'), PasskeyBackupError.noCredential);
      expect(passkeyErrorFromCode('rp'), PasskeyBackupError.rp);
      expect(passkeyErrorFromCode('exists'), PasskeyBackupError.exists);
      expect(passkeyErrorFromCode('weird'), PasskeyBackupError.other);
    });
  });

  group('service', () {
    late FakePasskeyPlatform platform;
    late FakeRelays relays;
    late PasskeyBackupService service;

    setUp(() {
      platform = FakePasskeyPlatform(prf: prf);
      relays = FakeRelays();
      service = fakePasskeyService(platform, relays);
    });

    test('PRF at create publishes the backup to every relay', () async {
      await service.backUp(
          secretHex: secret, pubkeyHex: getPublicKeyHex(hexToBytes(secret)));
      expect(platform.calls, ['create']);
      expect(relays.published, hasLength(1));
      expect(relays.publishedTo, ['wss://a', 'wss://b']);
      final e = relays.published.single;
      expect(e.pubkey, v['locatorPubkeyHex']);
      expect(PasskeyBackupKeys.fromPrf(prf).decrypt(e.content)?.secretHex, secret);
      expect(platform.lastCreate!['rpId'], 'web.nymchat.app');
      expect(platform.lastCreate!['userName'] as String,
          startsWith('Nymchat key backup · npub1'));
      expect(platform.lastCreate!['prfSalt'], passkeyPrfSalt());
      expect((platform.lastCreate!['userId'] as Uint8List).length, 16);
    });

    test('PRF enabled without output runs a get for that credential', () async {
      platform.prfAtCreate = false;
      await service.backUp(
          secretHex: secret, pubkeyHex: getPublicKeyHex(hexToBytes(secret)));
      expect(platform.calls, ['create', 'get']);
      expect(platform.lastGet!['allowCredentials'], [platform.credentialId]);
      expect(platform.lastGet!['prfSalt'], passkeyPrfSalt());
      expect(relays.published, hasLength(1));
    });

    test('falls back to largeBlob when PRF is unavailable', () async {
      platform
        ..prf = null
        ..prfEnabled = false
        ..largeBlob = true;
      await service.backUp(
          secretHex: secret, pubkeyHex: getPublicKeyHex(hexToBytes(secret)));
      expect(platform.calls, ['create', 'get']);
      expect(decodeLargeBlob(platform.storedBlob)?.secretHex, secret);
      expect(relays.published, isEmpty);
    });

    test('a largeBlob write that does not stick fails', () async {
      platform
        ..prf = null
        ..prfEnabled = false
        ..largeBlob = true
        ..blobWriteWorks = false;
      await expectLater(
          service.backUp(
              secretHex: secret,
              pubkeyHex: getPublicKeyHex(hexToBytes(secret))),
          throwsA(isA<PasskeyBackupException>().having(
              (e) => e.error, 'error', PasskeyBackupError.blobFailed)));
    });

    test('neither PRF nor largeBlob is unsupported', () async {
      platform
        ..prf = null
        ..prfEnabled = false;
      await expectLater(
          service.backUp(
              secretHex: secret,
              pubkeyHex: getPublicKeyHex(hexToBytes(secret))),
          throwsA(isA<PasskeyBackupException>().having(
              (e) => e.error, 'error', PasskeyBackupError.unsupported)));
    });

    test('no relay accepting the event fails', () async {
      relays.accept = false;
      await expectLater(
          service.backUp(
              secretHex: secret,
              pubkeyHex: getPublicKeyHex(hexToBytes(secret))),
          throwsA(isA<PasskeyBackupException>().having(
              (e) => e.error, 'error', PasskeyBackupError.publishFailed)));
    });

    test('restore finds the PRF backup on the relays', () async {
      await service.backUp(
          secretHex: secret, pubkeyHex: getPublicKeyHex(hexToBytes(secret)));
      platform.calls.clear();
      expect((await service.restore()).secretHex, secret);
      expect(platform.calls, ['get']);
      expect(platform.lastGet!['allowCredentials'], isEmpty);
      expect(platform.lastGet!['largeBlobRead'], isTrue);
      expect(relays.queriedFrom, ['wss://a']);
      expect(relays.lastFilter!['authors'], [v['locatorPubkeyHex']]);
    });

    test('restore reads the largeBlob backup', () async {
      platform
        ..prf = null
        ..prfEnabled = false
        ..largeBlob = true;
      await service.backUp(
          secretHex: secret, pubkeyHex: getPublicKeyHex(hexToBytes(secret)));
      expect((await service.restore()).secretHex, secret);
    });

    test('restore with nothing linked says not found', () async {
      platform.hasCredential = true;
      await expectLater(
          service.restore(),
          throwsA(isA<PasskeyBackupException>().having(
              (e) => e.error, 'error', PasskeyBackupError.notFound)));
    });
  });

  group('service without a passkey', () {
    test('restore reports that no credential was chosen', () async {
      final service = fakePasskeyService(FakePasskeyPlatform(prf: prf), FakeRelays());
      await expectLater(
          service.restore(),
          throwsA(isA<PasskeyBackupException>().having(
              (e) => e.error, 'error', PasskeyBackupError.noCredential)));
    });
  });

  group('config', () {
    test('passkey backup is on by default and never on the web', () {
      expect(KeyBackupConfig.environment.passkeyBackup, isTrue);
      expect(KeyBackupConfig.environment.passkeyRpId, 'web.nymchat.app');
      const on = KeyBackupConfig(passkeyBackup: true);
      expect(on.passkeyEnabledOn(TargetPlatform.iOS, web: false), isTrue);
      expect(on.passkeyEnabledOn(TargetPlatform.android, web: false), isTrue);
      expect(on.passkeyEnabledOn(TargetPlatform.macOS, web: false), isFalse);
      expect(on.passkeyEnabledOn(TargetPlatform.iOS, web: true), isFalse);
      expect(defaultPasskeyBackupService(platform: TargetPlatform.android)?.rpId, 'web.nymchat.app');
      expect(defaultPasskeyBackupService(config: const KeyBackupConfig(), platform: TargetPlatform.android), isNull);
      expect(
          defaultPasskeyBackupService(
                  config: on, platform: TargetPlatform.android)!
              .rpId,
          'web.nymchat.app');
    });

    test('relays are the app defaults plus the fixed list', () {
      final publish = passkeyPublishRelays();
      for (final r in kPasskeyFixedRelays) {
        expect(publish, contains(r));
      }
      expect(publish, contains('wss://relay.nymchat.app'));
      expect(publish.toSet().length, publish.length);
      expect(passkeyQueryRelays(), isNot(contains('wss://sendit.nosflare.com')));
    });
  });
}

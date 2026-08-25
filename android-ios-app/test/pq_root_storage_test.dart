// Where the root's wraps live and what may seal them (PQ-ROOT-SPEC §5.1,
// §5.3, §6).
//
// The circular-lock property is unrecoverable if it breaks, and the root must
// reach the FIRST settings read of a launch or every root-sealed row comes
// back unreadable — so both are asserted directly.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/features/identity/pq_root.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/api/storage_sync.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';

final Uint8List _priv = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
final String _pub = getPublicKeyHex(_priv);
final LocalSigner _signer = LocalSigner(_priv);
final Uint8List _root = Uint8List.fromList(List<int>.filled(32, 0x5a));


/// StorageSync over an in-memory D1. [fail] makes every request throw, which
/// is what an offline boot looks like.
StorageSync _syncOver(
  Map<String, String> d1, {
  Uint8List? root,
  bool sealToSelf = true,
  bool fail = false,
}) {
  final client = MockClient((req) async {
    if (fail) throw http.ClientException('offline');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    if (body['action'] == 'settings-get') {
      return http.Response(
          jsonEncode({
            'categories': {
              for (final e in d1.entries)
                e.key: {'blob': e.value, 'updatedAt': 1000}
            }
          }),
          200);
    }
    if (body['action'] == 'settings-set') {
      d1[body['category'] as String] = body['blob'] as String;
    }
    return http.Response(jsonEncode({'ok': true}), 200);
  });
  final sync = StorageSync(
    api: ApiClient(client: client),
    signer: _signer,
    pubkey: _pub,
    durableIdentity: true,
  )..setAuthBuilder((action) async => {
        'kind': 27235,
        'pubkey': _pub,
        'id': 'auth',
        'sig': 'sig',
        'created_at': 1,
        'tags': [
          ['action', action]
        ],
        'content': 'auth',
      });
  sync.setPqSealToSelf(sealToSelf);
  if (root != null) sync.setPqRootProvider(() async => root);
  return sync;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('§5.1 the root row must not be sealed to the root-derived key', () {
    test('the wraps row is written classically, never pq1.', () async {
      final d1 = <String, String>{};
      final sync = _syncOver(d1, root: _root);
      // Any wrap will do here: these assert how the ROW is sealed, not what is
      // in the wrap. Mobile has no wrap-minting path (no platform PRF).
      const wrap = PqRootWrap(type: pqRootWrapPasskey, blob: 'enc:v1:AAAA:BBBB');

      expect(await sync.pqRootRecordSet(const PqRootRecord().withWrap(wrap)),
          isTrue);

      final column = sync.d1Category(pqRootCategory);
      final blob = d1[column];
      expect(blob, isNotNull);
      expect(pq.isPqPayload(blob!), isFalse,
          reason: 'sealing the only copy of the root to a key derived from it '
              'is a lock no device could ever open');
    });

    test('and every other category still goes hybrid on the same instance',
        () async {
      final d1 = <String, String>{};
      final sync = _syncOver(d1, root: _root);
      await sync.pqRootRecordSet(const PqRootRecord());
      expect(await sync.readStateSet({'#nymchat': 1700000000}), isTrue);

      final rootBlob = d1[sync.d1Category(pqRootCategory)]!;
      final otherBlob = d1[sync.d1Category('nymchat-readstate')]!;
      expect(pq.isPqPayload(rootBlob), isFalse);
      expect(pq.isPq2Payload(rootBlob), isFalse);
      // Layered, so a signer login on this account can open its own settings.
      // The combined form needed the raw ECDH output and therefore an nsec.
      expect(pq.isPq2Payload(otherBlob), isTrue,
          reason: 'the exception is exactly one category wide');
    });

    test('a device holding NO root can still read the row', () async {
      final d1 = <String, String>{};
      // Any wrap will do here: these assert how the ROW is sealed, not what is
      // in the wrap. Mobile has no wrap-minting path (no platform PRF).
      const wrap = PqRootWrap(type: pqRootWrapPasskey, blob: 'enc:v1:AAAA:BBBB');
      await _syncOver(d1, root: _root)
          .pqRootRecordSet(const PqRootRecord().withWrap(wrap));

      // The §6.3 device: same nsec, no root. It must still see the record.
      final fresh = _syncOver(d1);
      await fresh.settingsGet();
      expect(fresh.pqRootRowPresent, isTrue);
      final record = fresh.pqRootRecord;
      expect(record, isNotNull);
      // The wrap survives the round trip intact. Its AES-GCM is what a
      // quantum adversary cannot open, so the classical outer seal costs
      // nothing.
      expect(record!.wrapOfType(pqRootWrapPasskey)?.blob, wrap.blob);
    });

    test('the row is not offered as a settings section to apply', () async {
      final d1 = <String, String>{};
      final sync = _syncOver(d1, root: _root);
      await sync.pqRootRecordSet(const PqRootRecord());
      final offers = await _syncOver(d1, root: _root).settingsTransfersSince(0);
      expect(offers.where((o) => o.id == pqRootCategory), isEmpty);
      expect(offers.where((o) => o.section.contains('pq-root')), isEmpty);
    });
  });
  group('§5.3 the root reaches the first settings read of a launch', () {
    test('a root-sealed row opens without any setPqSelfKeys hand-off',
        () async {
      final kem = pq.pqKeypairFromRoot(_root, 0);
      final blob = pq.pqEncrypt(
        jsonEncode({
          'theme': 'midnight',
          '__cat': 'nymchat-settings-appearance',
        }),
        _priv,
        _pub,
        kem.publicKey,
      );

      // Boot state: nothing has handed keys over, only the provider exists.
      final res = await _syncOver({'opaque': blob}, root: _root).settingsGet();

      expect(res, isNotNull);
      expect(res!.payload['theme'], 'midnight',
          reason: 'an empty payload means the session runs on defaults and '
              'publishes them over this row');
    });

    test('new writes are sealed to the ROOT key, not the nsec key', () async {
      final d1 = <String, String>{};
      await _syncOver(d1, root: _root).readStateSet({'#nymchat': 1700000000});
      final blob = d1[_syncOver({}).d1Category('nymchat-readstate')]!;
      expect(pq.isPq2Payload(blob), isTrue);

      // The outer layer opens with the root-derived KEM secret alone — no secp
      // key involved, which is what lets a signer login read it.
      final rootKem = pq.pqKeypairFromRoot(_root, 0);
      final inner = await pq.pq2Open(
          blob, _pub, _pub, rootKem.secretKey, rootKem.publicKey);
      expect(
        nip44.decrypt(inner, nip44.getConversationKey(_priv, _pub)),
        contains('#nymchat'),
      );
      // And NOT the nsec-derived one, which falls out of the npub.
      final nsecKem = pq.pqKeypairFromPrivkey(_priv, 0);
      expect(
        () => pq.pq2Open(
            blob, _pub, _pub, nsecKem.secretKey, nsecKem.publicKey),
        throwsA(anything),
      );
    });
  });

  // "Dropping (2) is a data-loss bug, not a cleanup."
  group('§4 v1-sealed data stays readable after the root arrives', () {
    test('an nsec-sealed settings row still opens on a root-holding device',
        () async {
      final legacyKem = pq.pqKeypairFromPrivkey(_priv, 0);
      final blob = pq.pqEncrypt(
        jsonEncode({
          'theme': 'matrix',
          '__cat': 'nymchat-settings-appearance',
        }),
        _priv,
        _pub,
        legacyKem.publicKey,
      );

      final res = await _syncOver({'opaque': blob}, root: _root).settingsGet();
      expect(res?.payload['theme'], 'matrix',
          reason: 'v1 rows stay readable for the life of the identity');
    });

    test('a plain NIP-44 row still opens too', () async {
      final plain = await _signer.nip44Encrypt(
          _pub,
          jsonEncode({
            'theme': 'paper',
            '__cat': 'nymchat-settings-appearance',
          }));
      final res = await _syncOver({'opaque': plain}, root: _root).settingsGet();
      expect(res?.payload['theme'], 'paper');
    });

    test('both generations open from the same read', () async {
      final legacyKem = pq.pqKeypairFromPrivkey(_priv, 0);
      final rootKem = pq.pqKeypairFromRoot(_root, 0);
      final d1 = {
        'a': pq.pqEncrypt(
            jsonEncode({'theme': 'matrix', '__cat': 'nymchat-settings-appearance'}),
            _priv,
            _pub,
            legacyKem.publicKey),
        'b': pq.pqEncrypt(
            jsonEncode({'sound': false, '__cat': 'nymchat-settings-privacy'}),
            _priv,
            _pub,
            rootKem.publicKey),
      };
      final res = await _syncOver(d1, root: _root).settingsGet();
      expect(res?.payload['theme'], 'matrix');
      expect(res?.payload['sound'], false);
    });
  });

  group('§6 what the storage layer reports about the record', () {
    test('a completed read with no row proves absence', () async {
      final sync = _syncOver({});
      await sync.settingsGet();
      expect(sync.pqRootLoadSucceeded, isTrue);
      expect(sync.pqRootRowPresent, isFalse);
    });

    test('a failed read proves nothing, so nothing may be generated', () async {
      final sync = _syncOver({}, fail: true);
      expect(await sync.settingsGet(), isNull);
      expect(sync.pqRootLoadSucceeded, isFalse,
          reason: 'reading this as "no record" would create a rival root');
      expect(sync.pqRootRowPresent, isFalse);
    });

    // A briefly unavailable signer must not read as a missing root.
    test('a row that does not decrypt still counts as present', () async {
      final sync = _syncOver({});
      final column = sync.d1Category(pqRootCategory);
      final blocked = _syncOver({column: 'not-a-decryptable-blob'});
      await blocked.settingsGet();
      expect(blocked.pqRootRowPresent, isTrue,
          reason: 'a record we cannot open is still a record');
      expect(blocked.pqRootRecord, isNull);
    });

    test('a row written under the bare routing name also counts', () async {
      final sync = _syncOver({pqRootCategory: 'whatever'});
      await sync.settingsGet();
      expect(sync.pqRootRowPresent, isTrue);
    });

    test('writing the record marks it present without a re-read', () async {
      final sync = _syncOver({}, root: _root);
      expect(sync.pqRootRowPresent, isFalse);
      await sync.pqRootRecordSet(const PqRootRecord());
      expect(sync.pqRootRowPresent, isTrue);
      expect(sync.pqRootRecord, isNotNull);
    });
  });
}

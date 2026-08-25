// The post-quantum settings row must be readable on the FIRST read of a launch.
//
// StorageSync used to wait to be handed its ML-KEM keypairs (setPqSelfKeys),
// and the only caller runs inside the group-sync apply — which happens AFTER
// settingsGet has returned. So the boot read of a post-quantum account opened
// nothing, the session carried on holding defaults, and the next save published
// those defaults over the very rows it had failed to read. Every device then
// read them back.
//
// It is post-quantum-only (a NIP-44 row goes through the signer, which is
// wired from the start) and native-only (the web client derives its own keys on
// demand and has no hand-off to be late).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/api/storage_sync.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';

final Uint8List _priv = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
final String _pub = getPublicKeyHex(_priv);
final LocalSigner _signer = LocalSigner(_priv);

StorageSync _syncOver(Map<String, String> d1) {
  final client = MockClient((req) async {
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
  return StorageSync(
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a post-quantum settings row opens without waiting for setPqSelfKeys',
      () async {
    final kem = pq.pqKeypairFromPrivkey(_priv, 0);
    final blob = pq.pqEncrypt(
      jsonEncode({
        'v': 2,
        'theme': 'midnight',
        '__cat': 'nymchat-settings-appearance',
      }),
      _priv,
      _pub,
      kem.publicKey,
    );

    // Exactly the boot state: nothing has handed the keys over yet.
    final res = await _syncOver({'opaque': blob}).settingsGet();

    expect(res, isNotNull);
    expect(res!.payload['theme'], 'midnight',
        reason: 'an empty payload here is the whole bug: the session would '
            'run on defaults and publish them over this row');
  });
}

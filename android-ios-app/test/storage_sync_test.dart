import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/api/storage_sync.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';

/// Deterministic test identity (non-zero 32-byte key, valid for bip340).
final Uint8List _priv = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
final String _pub = getPublicKeyHex(_priv);
final LocalSigner _signer = LocalSigner(_priv);

/// Builds a [StorageSync] over a captured-request MockClient. [onBody] receives
/// each decoded request body; [respond] returns the (status, body, headers).
StorageSync _syncWith(
  void Function(Map<String, dynamic> body) onBody, {
  required (int, String, Map<String, String>) Function(Map<String, dynamic> body)
      respond,
  bool durable = true,
  String? pubkey,
}) {
  final client = MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    onBody(body);
    final (status, payload, headers) = respond(body);
    return http.Response(payload, status, headers: headers);
  });
  final api = ApiClient(client: client);
  return StorageSync(
    api: api,
    signer: _signer,
    pubkey: pubkey ?? _pub,
    durableIdentity: durable,
  )..setAuthBuilder((action) => {
        'kind': 27235,
        'pubkey': _pub,
        'id': 'auth-$action',
        'sig': 'sig',
        'created_at': 1,
        'tags': [
          ['action', action],
        ],
        'content': 'nymbot-pm-auth',
      });
}

void main() {
  // ===========================================================================
  // 1. settings-set body shape + which keys sync vs stay local.
  // ===========================================================================
  group('settings-set', () {
    test('body carries action, pubkey, category, blob, contentHash, auth', () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (200, jsonEncode({'ok': true}), const {}),
      );
      final sent = await sync.settingsSet(const Settings());
      expect(sent, isNotEmpty);
      expect(bodies, isNotEmpty);
      for (final b in bodies) {
        expect(b['action'], 'settings-set');
        expect(b['pubkey'], _pub);
        expect(b['category'], startsWith('nymchat-settings-'));
        expect(b['blob'], isA<String>());
        expect((b['blob'] as String).isNotEmpty, true);
        expect(b['contentHash'], isA<String>());
        expect(b['auth'], isA<Map>());
        expect((b['auth'] as Map)['kind'], 27235);
      }
    });

    test('synced keys land in their PWA section; device-local keys never sync',
        () {
      final sections = StorageSync.buildSectionPayloads(const Settings());
      // Representative synced split (NYM_SETTINGS_SECTION_KEYS, settings.js:8).
      expect(sections['appearance']!.containsKey('theme'), true);
      expect(sections['appearance']!.containsKey('textSize'), true);
      expect(sections['privacy']!.containsKey('readReceiptsScope'), true);
      expect(sections['privacy']!.containsKey('acceptPMs'), true);
      expect(sections['messaging']!.containsKey('translateLanguage'), true);
      expect(sections['data']!.containsKey('cachePMs'), true);
      expect(sections['data']!.containsKey('lowDataMode'), true);
      expect(sections['channels']!.containsKey('sortByProximity'), true);
      // Each section carries the v:2 envelope.
      for (final s in sections.values) {
        expect(s['v'], 2);
      }
      // Device-local keys are NOT present in any synced section.
      final allKeys = sections.values.expand((m) => m.keys).toSet();
      for (final local in StorageSync.deviceLocalKeys) {
        expect(allKeys.contains(local), false, reason: 'leaked $local');
      }
    });

    test('unchanged section (same content hash) skips the second write',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (200, jsonEncode({'ok': true}), const {}),
      );
      await sync.settingsSet(const Settings());
      final first = bodies.length;
      bodies.clear();
      await sync.settingsSet(const Settings());
      expect(bodies, isEmpty, reason: 'identical settings should no-op');
      expect(first, greaterThan(0));
    });

    test('ephemeral identity skips PM archive but still syncs settings',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        durable: false,
        respond: (_) => (200, jsonEncode({'ok': true}), const {}),
      );
      final sent = await sync.settingsSet(const Settings());
      expect(sent, isNotEmpty); // settings still sync for ephemeral
      // But PM archive is a no-op (asserted in the PM group below).
    });
  });

  // ===========================================================================
  // 2. settings-get merge honors the newer lastSettingsSyncTs.
  // ===========================================================================
  group('settings-get', () {
    /// Encrypts a section payload to self the way [StorageSync.settingsSet]
    /// does, so the round-trip decrypt path is exercised.
    Future<String> encBlob(Map<String, dynamic> payload, String category) async {
      final withCat = {...payload, '__cat': category};
      return _signer.nip44Encrypt(_pub, jsonEncode(withCat));
    }

    test('decrypts categories, applies newest section, reports newestTs',
        () async {
      // Two appearance section versions; the newer updatedAt wins.
      final oldBlob = await encBlob(
        {'v': 2, 'theme': 'matrix'},
        'nymchat-settings-appearance',
      );
      final newBlob = await encBlob(
        {'v': 2, 'theme': 'ghost'},
        'nymchat-settings-appearance-2',
      );
      final sync = _syncWith(
        (_) {},
        respond: (_) => (
          200,
          jsonEncode({
            'categories': {
              // The D1 column is opaque; the real cat rides in __cat. The two
              // rows decode to the same section family; newest updatedAt wins.
              'opaque-old': {'blob': oldBlob, 'updatedAt': 1000},
              'opaque-new': {'blob': newBlob, 'updatedAt': 2000},
            }
          }),
          const {},
        ),
      );
      final res = await sync.settingsGet();
      expect(res, isNotNull);
      // Newest section (updatedAt 2000) wins on the conflicting key.
      expect(res!.payload['theme'], 'ghost');
      expect(res.newestTs, 2000);
    });

    test('null on empty / non-object categories', () async {
      final sync = _syncWith(
        (_) {},
        respond: (_) => (200, jsonEncode({'categories': {}}), const {}),
      );
      expect(await sync.settingsGet(), isNull);
    });

    test('settings-get body carries action, pubkey, auth', () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (200, jsonEncode({'categories': {}}), const {}),
      );
      await sync.settingsGet();
      expect(bodies.single['action'], 'settings-get');
      expect(bodies.single['pubkey'], _pub);
      expect(bodies.single['auth'], isA<Map>());
    });
  });

  // ===========================================================================
  // 3. profile-get batches pubkeys; D1 result preferred over older relay.
  // ===========================================================================
  group('profile-get', () {
    final pkA = 'a' * 64;
    final pkB = 'b' * 64;

    test('request batches the pubkey list (public, no auth)', () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (
          200,
          '${jsonEncode([
                pkA,
                {
                  'event': {
                    'id': 'id-a',
                    'pubkey': pkA,
                    'kind': 0,
                    'created_at': 100,
                    'tags': [],
                    'content': '{"name":"alice"}',
                    'sig': 's'
                  },
                  'updatedAt': 1
                }
              ])}\n',
          {'Content-Type': 'application/x-ndjson'},
        ),
      );
      final got = await sync.profileGet([pkA, pkB]);
      final body = bodies.single;
      expect(body['action'], 'profile-get');
      expect(body['pubkeys'], containsAll([pkA, pkB]));
      expect(body.containsKey('auth'), false, reason: 'profile-get is public');
      // D1 returned the kind-0 event for pkA.
      expect(got.containsKey(pkA), true);
      expect(got[pkA]!['content'], '{"name":"alice"}');
    });

    test('D1 kind-0 event maps to a higher created_at than an older relay one',
        () async {
      // The D1-first path returns the signed event; the ingest layer's kind0Ts
      // dedup keeps the newest. Here we assert the D1 event carries a newer
      // created_at so it is preferred over the (older) relay profile.
      const relayTs = 100;
      const d1Ts = 500;
      final sync = _syncWith(
        (_) {},
        respond: (_) => (
          200,
          '${jsonEncode([
                pkA,
                {
                  'event': {
                    'id': 'id-d1',
                    'pubkey': pkA,
                    'kind': 0,
                    'created_at': d1Ts,
                    'tags': [],
                    'content': '{"name":"d1-alice"}',
                    'sig': 's'
                  },
                  'updatedAt': 9
                }
              ])}\n',
          {'Content-Type': 'application/x-ndjson'},
        ),
      );
      final got = await sync.profileGet([pkA]);
      final ev = NostrEvent.fromJson(got[pkA]!);
      expect(ev.createdAt, d1Ts);
      expect(ev.createdAt, greaterThan(relayTs));
    });

    test('profile-set mirrors the signed kind-0 with auth', () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (200, jsonEncode({'ok': true}), const {}),
      );
      await sync.profileSet({
        'id': 'id-x',
        'pubkey': _pub,
        'kind': 0,
        'created_at': 1,
        'tags': [],
        'content': '{}',
        'sig': 's',
      });
      final b = bodies.single;
      expect(b['action'], 'profile-set');
      expect(b['pubkey'], _pub);
      expect((b['event'] as Map)['kind'], 0);
      expect(b['auth'], isA<Map>());
    });
  });

  // ===========================================================================
  // 4. pm-put / pm-deposit body shapes; restore parses; ephemeral skips.
  // ===========================================================================
  group('PM archive', () {
    Map<String, dynamic> wrapTo(String recipient, {String id = 'w1'}) => {
          'id': id,
          'pubkey': 'e' * 64,
          'kind': 1059,
          'created_at': 200,
          'tags': [
            ['p', recipient],
          ],
          'content': 'ciphertext',
          'sig': 's',
        };

    test('pm-put body shape (action, pubkey, events, auth) for own inbox',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (200, jsonEncode({'ok': true, 'added': 1}), const {}),
      );
      final n = await sync.pmPut([wrapTo(_pub)]);
      expect(n, 1);
      final b = bodies.single;
      expect(b['action'], 'pm-put');
      expect(b['pubkey'], _pub);
      expect(b['events'], isA<List>());
      expect((b['events'] as List).length, 1);
      expect(b['auth'], isA<Map>());
    });

    test('pm-put dedups a repeat wrap id within the session', () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (200, jsonEncode({'ok': true}), const {}),
      );
      await sync.pmPut([wrapTo(_pub, id: 'dup')]);
      bodies.clear();
      final n = await sync.pmPut([wrapTo(_pub, id: 'dup')]);
      expect(n, 0);
      expect(bodies, isEmpty);
    });

    test('pm-deposit targets a peer-addressed wrap (action, pubkey, events)',
        () async {
      final peer = 'c' * 64;
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (200, jsonEncode({'ok': true, 'added': 1}), const {}),
      );
      final n = await sync.pmDeposit([wrapTo(peer)]);
      expect(n, 1);
      final b = bodies.single;
      expect(b['action'], 'pm-deposit');
      expect(b['pubkey'], _pub);
      expect((b['events'] as List).length, 1);
    });

    test('pm-deposit skips a wrap addressed to ourselves', () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (200, jsonEncode({'ok': true}), const {}),
      );
      final n = await sync.pmDeposit([wrapTo(_pub)]);
      expect(n, 0);
      expect(bodies, isEmpty);
    });

    test('pm-get parses NDJSON events, sorts oldest-first, honors X-Has-More',
        () async {
      final older = wrapTo(_pub, id: 'old')..['created_at'] = 100;
      final newer = wrapTo(_pub, id: 'new')..['created_at'] = 300;
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (
          200,
          // Worker streams newest-first; we sort oldest-first.
          '${jsonEncode(newer)}\n${jsonEncode(older)}\n',
          {'Content-Type': 'application/x-ndjson', 'X-Has-More': '0'},
        ),
      );
      final events = await sync.pmGet(limit: 200);
      expect(events.length, 2);
      expect(events.first['id'], 'old'); // oldest-first
      expect(events.last['id'], 'new');
      final b = bodies.single;
      expect(b['action'], 'pm-get');
      expect(b['pubkey'], _pub);
      expect(b['auth'], isA<Map>());
    });

    test('ephemeral identity skips pm-put / pm-deposit / pm-get entirely',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        durable: false,
        respond: (_) => (200, jsonEncode({'ok': true}), const {}),
      );
      expect(await sync.pmPut([wrapTo(_pub)]), 0);
      expect(await sync.pmDeposit([wrapTo('c' * 64)]), 0);
      expect(await sync.pmGet(), isEmpty);
      expect(await sync.pmRestoreFromD1(), isEmpty);
      expect(bodies, isEmpty, reason: 'ephemeral makes no PM-archive calls');
    });
  });
}

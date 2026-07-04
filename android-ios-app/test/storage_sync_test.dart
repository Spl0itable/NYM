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
  )..setAuthBuilder((action) async => {
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
        // The D1 column is the opaque per-account hash
        // `nymchat-<sha256(pubkey:d1:dTag)>` (settings.js:177-190), NOT the
        // cleartext section d-tag.
        expect(b['category'], matches(RegExp(r'^nymchat-[0-9a-f]{64}$')));
        expect(b['blob'], isA<String>());
        expect((b['blob'] as String).isNotEmpty, true);
        expect(b['contentHash'], isA<String>());
        expect(b['auth'], isA<Map>());
        expect((b['auth'] as Map)['kind'], 27235);
      }
      // The appearance section rides under its hashed column, with the real
      // category recoverable from `__cat` inside the encrypted blob.
      final appearanceCat = sync.d1Category('nymchat-settings-appearance');
      final appearance =
          bodies.firstWhere((b) => b['category'] == appearanceCat);
      final plain =
          await _signer.nip44Decrypt(_pub, appearance['blob'] as String);
      expect((jsonDecode(plain) as Map)['__cat'], 'nymchat-settings-appearance');
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
      // Landing channel is threaded in by the caller; absent when not supplied.
      expect(sections['channels']!.containsKey('pinnedLandingChannel'), false);
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

    test(
        'pinnedLandingChannel rides the channels section as a {type,geohash} '
        'object when supplied (settings.js:21,116)', () {
      // Supplied JSON → emitted into channels as the same object the PWA syncs.
      final sections = StorageSync.buildSectionPayloads(
        const Settings(),
        pinnedLandingChannelJson: '{"type":"geohash","geohash":"9q8y"}',
      );
      final landing = sections['channels']!['pinnedLandingChannel'];
      expect(landing, isA<Map>());
      expect((landing as Map)['type'], 'geohash');
      expect(landing['geohash'], '9q8y');

      // Missing `type` defaults to 'geohash' (mirrors LandingChannel.tryParse).
      final defaulted = StorageSync.buildSectionPayloads(
        const Settings(),
        pinnedLandingChannelJson: '{"geohash":"dr5r"}',
      );
      expect(
        (defaulted['channels']!['pinnedLandingChannel'] as Map)['type'],
        'geohash',
      );

      // Blank / invalid JSON / missing geohash → omitted (no poisoning).
      for (final bad in ['', '   ', 'not json', '{"type":"geohash"}', '{}']) {
        final none = StorageSync.buildSectionPayloads(
          const Settings(),
          pinnedLandingChannelJson: bad,
        );
        expect(none['channels']!.containsKey('pinnedLandingChannel'), false,
            reason: 'should omit for "$bad"');
      }
    });

    test('a landing-channel change re-publishes the channels section', () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (200, jsonEncode({'ok': true}), const {}),
      );
      // First publish with a landing channel set.
      final first = await sync.settingsSet(
        const Settings(),
        pinnedLandingChannelJson: '{"type":"geohash","geohash":"9q8y"}',
      );
      expect(first, contains('channels'));
      bodies.clear();
      // Changing it re-publishes channels (content hash differs).
      final second = await sync.settingsSet(
        const Settings(),
        pinnedLandingChannelJson: '{"type":"geohash","geohash":"u4pr"}',
      );
      expect(second, contains('channels'));
      expect(
          bodies.any((b) =>
              b['category'] == sync.d1Category('nymchat-settings-channels')),
          true);
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

    test('a fresh pubkey (within the TTL) skips the second network read',
        () async {
      var calls = 0;
      final sync = _syncWith(
        (_) => calls++,
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
      // First read fetches + caches pkA.
      final first = await sync.profileGet([pkA]);
      expect(calls, 1);
      expect(first.containsKey(pkA), true);
      // Second read within the 5-min TTL is served from cache (reported as a
      // cache hit with an empty event payload) and makes NO network call.
      final second = await sync.profileGet([pkA]);
      expect(calls, 1, reason: 'cached pubkey should not refetch');
      expect(second.containsKey(pkA), true);
      expect(second[pkA], isEmpty, reason: 'cache hit carries no event');
    });

    test('markProfileCached suppresses a D1 read for that pubkey', () async {
      var calls = 0;
      final sync = _syncWith(
        (_) => calls++,
        respond: (_) => (200, '', {'Content-Type': 'application/x-ndjson'}),
      );
      // A live relay kind-0 arrived → controller marks it cached; the next
      // profile-get must not re-read it (PWA `profileFetchedAt` freshness gate).
      sync.markProfileCached(pkB);
      final got = await sync.profileGet([pkB]);
      expect(calls, 0, reason: 'pre-cached pubkey is not fetched');
      expect(got.containsKey(pkB), true); // reported as found (cache hit)
    });

    test('batches at most 100 pubkeys per request', () async {
      List<dynamic>? sentPubkeys;
      final sync = _syncWith(
        (b) => sentPubkeys = b['pubkeys'] as List<dynamic>,
        respond: (_) => (200, '', {'Content-Type': 'application/x-ndjson'}),
      );
      // 150 distinct valid hex pubkeys; only the first 100 go in the batch
      // (PWA `toFetch.slice(0, 100)`, nostr-core.js:236).
      final many = List<String>.generate(
        150,
        (i) => i.toRadixString(16).padLeft(64, '0'),
      );
      await sync.profileGet(many);
      expect(sentPubkeys, isNotNull);
      expect(sentPubkeys!.length, 100);
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

  // ===========================================================================
  // 5. channel-get archive backfill (public read, no auth) + ephemeral group
  //    inbox (pm-get keyed by `pubkeys`, also public).
  // ===========================================================================
  group('channel-get', () {
    Map<String, dynamic> chanEvent(String id, String d) => {
          'id': id,
          'pubkey': 'a' * 64,
          'kind': 23333,
          'created_at': 100,
          'tags': [
            ['d', d],
          ],
          'content': 'hi',
          'sig': 's',
        };

    test('body carries action + lowercased channels, no pubkey/auth (public)',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (
          200,
          '${jsonEncode(chanEvent('m1', 'nymchat'))}\n',
          {'Content-Type': 'application/x-ndjson'},
        ),
      );
      final events = await sync.channelGet(['NymChat']);
      expect(events.length, 1);
      expect(events.first['id'], 'm1');
      final b = bodies.single;
      expect(b['action'], 'channel-get');
      expect(b['channels'], ['nymchat']); // lowercased
      expect(b.containsKey('auth'), isFalse, reason: 'public read');
      expect(b.containsKey('pubkey'), isFalse, reason: 'public read');
    });

    test('throttles a re-fetch within 60s unless forced', () async {
      var calls = 0;
      final sync = _syncWith(
        (_) => calls++,
        respond: (_) => (200, '', {'Content-Type': 'application/x-ndjson'}),
      );
      await sync.channelGet(['9q8y']);
      expect(calls, 1);
      // Second open within the window is skipped (no request).
      await sync.channelGet(['9q8y']);
      expect(calls, 1);
      // force bypasses the window.
      await sync.channelGet(['9q8y'], force: true);
      expect(calls, 2);
    });

    test('channelGet works for ephemeral identities (public read)', () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        durable: false,
        respond: (_) => (
          200,
          '${jsonEncode(chanEvent('e1', 'nymchat'))}\n',
          {'Content-Type': 'application/x-ndjson'},
        ),
      );
      final events = await sync.channelGet(['nymchat']);
      expect(events.length, 1);
      expect(bodies.single['action'], 'channel-get');
    });

    test('pmGetByPubkeys posts a public pm-get keyed by pubkeys, oldest-first',
        () async {
      final ephA = 'b' * 64;
      final older = {
        'id': 'g-old',
        'pubkey': 'c' * 64,
        'kind': 1059,
        'created_at': 100,
        'tags': [
          ['p', ephA],
        ],
        'content': 'x',
        'sig': 's',
      };
      final newer = Map<String, dynamic>.from(older)
        ..['id'] = 'g-new'
        ..['created_at'] = 300;
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (
          200,
          '${jsonEncode(newer)}\n${jsonEncode(older)}\n',
          {'Content-Type': 'application/x-ndjson'},
        ),
      );
      final events = await sync.pmGetByPubkeys([ephA.toUpperCase()]);
      expect(events.length, 2);
      expect(events.first['id'], 'g-old'); // oldest-first
      final b = bodies.single;
      expect(b['action'], 'pm-get');
      expect(b['pubkeys'], [ephA]); // lowercased
      expect(b.containsKey('auth'), isFalse, reason: 'public read');
      expect(b.containsKey('pubkey'), isFalse);
    });
  });

  // ===========================================================================
  // 6. channel activity discovery (channel-active / channel-active-named /
  //    channel-activity) — all PUBLIC reads, no auth.
  // ===========================================================================
  group('channel activity discovery', () {
    String activityBody(Map<String, dynamic> activity, Map<String, dynamic> last) =>
        jsonEncode({'activity': activity, 'last': last});

    test('channel-active body is public (no pubkey/auth) and parses buckets/last',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (
          200,
          activityBody({
            '9q8y': List<int>.generate(24, (i) => i),
          }, {
            '9q8y': 1700000000,
          }),
          const {},
        ),
      );
      final res = await sync.channelActive();
      final b = bodies.single;
      expect(b['action'], 'channel-active');
      expect(b.containsKey('auth'), isFalse, reason: 'public read');
      expect(b.containsKey('pubkey'), isFalse, reason: 'public read');
      expect(res.activity['9q8y']!.length, 24);
      expect(res.activity['9q8y']![5], 5);
      expect(res.last['9q8y'], 1700000000);
    });

    test('channel-active-named issues the named-discovery action', () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (200, activityBody({}, {}), const {}),
      );
      await sync.channelActiveNamed();
      expect(bodies.single['action'], 'channel-active-named');
      expect(bodies.single.containsKey('auth'), isFalse);
    });

    test('channel-activity lowercases + de-dups names, public, parses result',
        () async {
      List<dynamic>? sentChannels;
      final sync = _syncWith(
        (b) => sentChannels = b['channels'] as List<dynamic>?,
        respond: (b) => (
          200,
          activityBody({
            'nymchat': List<int>.filled(24, 0)..[0] = 3,
          }, {
            'nymchat': 1700000123,
          }),
          const {},
        ),
      );
      final res = await sync.channelActivity(['NymChat', 'nymchat', 'NYMCHAT']);
      expect(sentChannels, ['nymchat']); // lowercased + de-duped
      expect(res.activity['nymchat']![0], 3);
      expect(res.last['nymchat'], 1700000123);
    });

    test('channel-activity caps the batch at 200 names', () async {
      List<dynamic>? sent;
      final sync = _syncWith(
        (b) => sent = b['channels'] as List<dynamic>?,
        respond: (_) => (200, activityBody({}, {}), const {}),
      );
      final many = List<String>.generate(250, (i) => 'chan$i');
      await sync.channelActivity(many);
      expect(sent!.length, 200);
    });

    test('channel-activity throttles a re-fetch within 30s unless forced',
        () async {
      var calls = 0;
      final sync = _syncWith(
        (_) => calls++,
        respond: (_) => (200, activityBody({}, {}), const {}),
      );
      await sync.channelActivity(['9q8y']);
      expect(calls, 1);
      await sync.channelActivity(['9q8y']); // within 30s → skipped
      expect(calls, 1);
      await sync.channelActivity(['9q8y'], force: true); // forced
      expect(calls, 2);
    });

    test('empty channel list makes no request', () async {
      var calls = 0;
      final sync = _syncWith(
        (_) => calls++,
        respond: (_) => (200, activityBody({}, {}), const {}),
      );
      final res = await sync.channelActivity(const []);
      expect(calls, 0);
      expect(res.isEmpty, isTrue);
    });
  });

  // ===========================================================================
  // 7. shop-status (other users' active cosmetics) — PUBLIC read, no auth.
  // ===========================================================================
  group('shop-status', () {
    final pkA = 'a' * 64;
    final pkB = 'b' * 64;

    test('body is public (no auth/pubkey), batches valid pubkeys, parses active',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final sync = _syncWith(
        bodies.add,
        respond: (_) => (
          200,
          jsonEncode({
            'statuses': {
              pkA: {
                'active': {
                  'style': 'style-satoshi',
                  'flair': ['flair-crown', 'flair-genesis'],
                  'cosmetics': ['cosmetic-frost'],
                  'supporter': true,
                  'editions': {'flair-genesis': 42},
                },
                'updatedAt': 1700000000,
              },
            },
          }),
          const {},
        ),
      );
      final got = await sync.shopStatus([pkA, pkB]);
      final b = bodies.single;
      expect(b['action'], 'shop-status');
      expect(b.containsKey('auth'), isFalse, reason: 'public read');
      expect(b.containsKey('pubkey'), isFalse, reason: 'public read');
      expect((b['pubkeys'] as List).length, 2);
      // Parsed active record.
      final st = got[pkA]!;
      expect(st.active.style, 'style-satoshi');
      expect(st.active.flair, ['flair-crown', 'flair-genesis']);
      expect(st.active.cosmetics, ['cosmetic-frost']);
      expect(st.active.supporter, isTrue);
      expect(st.active.editions['flair-genesis'], 42);
      expect(st.updatedAt, 1700000000);
    });

    test('drops invalid pubkeys and lowercases, caps at 100', () async {
      List<dynamic>? sent;
      final sync = _syncWith(
        (b) => sent = b['pubkeys'] as List<dynamic>?,
        respond: (_) => (200, jsonEncode({'statuses': {}}), const {}),
      );
      // 120 valid distinct hex + 1 invalid; only the first 100 valid go.
      final many = [
        'not-hex',
        ...List<String>.generate(120, (i) => i.toRadixString(16).padLeft(64, '0')),
      ];
      await sync.shopStatus(many);
      expect(sent!.length, 100);
      expect(sent!.contains('not-hex'), isFalse);
    });

    test('forwards a fresh[] cache-bust list only for requested pubkeys',
        () async {
      Map<String, dynamic>? body;
      final sync = _syncWith(
        (b) => body = b,
        respond: (_) => (200, jsonEncode({'statuses': {}}), const {}),
      );
      await sync.shopStatus([pkA, pkB], fresh: [pkA, 'c' * 64]);
      expect(body!['fresh'], [pkA]); // pkA only (c… wasn't requested)
    });

    test('empty pubkey list makes no request', () async {
      var calls = 0;
      final sync = _syncWith(
        (_) => calls++,
        respond: (_) => (200, jsonEncode({'statuses': {}}), const {}),
      );
      final got = await sync.shopStatus(const []);
      expect(calls, 0);
      expect(got, isEmpty);
    });
  });
}

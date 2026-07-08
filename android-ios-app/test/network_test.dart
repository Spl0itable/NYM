import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/core/constants/relays.dart';
import 'package:nym_bar/core/crypto/keys.dart' as keys;
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/api/api_config.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';
import 'package:nym_bar/services/nostr/identity_service.dart';
import 'package:nym_bar/services/nostr/nostr_service.dart';
import 'package:nym_bar/services/relay/relay_message.dart';
import 'package:nym_bar/services/relay/relay_pool.dart';
import 'package:nym_bar/services/relay/relay_pool_proxy.dart';
import 'package:nym_bar/services/relay/relay_stats.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

NostrEvent _ev({
  String id = 'aa',
  int kind = 20000,
  String content = 'hi',
  List<List<String>> tags = const [],
}) =>
    NostrEvent(
      id: id,
      pubkey: 'pk',
      createdAt: 1700000000,
      kind: kind,
      tags: tags,
      content: content,
      sig: 'sig',
    );

void main() {
  // ---------------------------------------------------------------------------
  // 1. Proxy frame builders / parsers round-trip (§4.6).
  // ---------------------------------------------------------------------------
  group('PoolFrame builders', () {
    test('RELAYS frame shape', () {
      final f = jsonDecode(PoolFrame.relays(['wss://a'], ['wss://b']));
      expect(f, [
        'RELAYS',
        {
          'relays': ['wss://a'],
          'dmRelays': ['wss://b'],
        }
      ]);
    });

    test('EVENT frame shape ["EVENT", e]', () {
      final f = jsonDecode(PoolFrame.event(_ev(id: 'x', content: 'yo')));
      expect(f[0], 'EVENT');
      expect((f[1] as Map)['id'], 'x');
      expect((f[1] as Map)['content'], 'yo');
      expect(f.length, 2);
    });

    test('GEO_EVENT builds ["GEO_EVENT", e, [urls]]', () {
      final f = jsonDecode(
          PoolFrame.geoEvent(_ev(id: 'g'), ['wss://geo1', 'wss://geo2']));
      expect(f[0], 'GEO_EVENT');
      expect((f[1] as Map)['id'], 'g');
      expect(f[2], ['wss://geo1', 'wss://geo2']);
    });

    test('DM_EVENT frame shape ["DM_EVENT", e]', () {
      final f = jsonDecode(PoolFrame.dmEvent(_ev(id: 'd')));
      expect(f[0], 'DM_EVENT');
      expect((f[1] as Map)['id'], 'd');
    });

    test('REQ frame ["REQ", subId, ...filters]', () {
      final f = jsonDecode(PoolFrame.req('sub1', [
        NostrFilter(kinds: [20000], since: 100),
        NostrFilter(kinds: [7]),
      ]));
      expect(f[0], 'REQ');
      expect(f[1], 'sub1');
      expect((f[2] as Map)['kinds'], [20000]);
      expect((f[2] as Map)['since'], 100);
      expect((f[3] as Map)['kinds'], [7]);
    });

    test('CLOSE frame ["CLOSE", subId]', () {
      expect(jsonDecode(PoolFrame.close('sub1')), ['CLOSE', 'sub1']);
    });
  });

  group('PoolMessage parsers', () {
    test('inbound ["EVENT", subId, e] parses to (subId, event)', () {
      final raw = jsonEncode([
        'EVENT',
        'subA',
        {
          'id': 'e1',
          'pubkey': 'pk',
          'created_at': 1700000000,
          'kind': 20000,
          'tags': [],
          'content': 'hello',
          'sig': 's',
        }
      ]);
      final msg = PoolMessage.parse(raw);
      expect(msg, isA<PoolEvent>());
      final pe = msg as PoolEvent;
      expect(pe.subId, 'subA');
      expect(pe.event.id, 'e1');
      expect(pe.event.content, 'hello');
      expect(pe.sourceRelay, isNull);
    });

    test('inbound EVENT keeps optional trailing sourceRelay attribution', () {
      final raw = jsonEncode([
        'EVENT',
        'subA',
        {
          'id': 'e2',
          'pubkey': 'pk',
          'created_at': 1,
          'kind': 1,
          'tags': [],
          'content': '',
          'sig': '',
        },
        'wss://relay.example',
      ]);
      final pe = PoolMessage.parse(raw) as PoolEvent;
      expect(pe.sourceRelay, 'wss://relay.example');
    });

    test('inbound ["OK", id, bool, msg]', () {
      final ok = PoolMessage.parse(jsonEncode(['OK', 'evid', true, 'stored']))
          as PoolOk;
      expect(ok.id, 'evid');
      expect(ok.accepted, isTrue);
      expect(ok.message, 'stored');
    });

    test('inbound ["EOSE", subId]', () {
      final eose = PoolMessage.parse(jsonEncode(['EOSE', 'subA'])) as PoolEose;
      expect(eose.subId, 'subA');
    });

    test('inbound POOL:PING parses to keepalive', () {
      expect(PoolMessage.parse(jsonEncode(['POOL:PING', 12345])),
          isA<PoolPing>());
    });

    test('inbound POOL:STATUS extracts connected relays', () {
      final raw = jsonEncode([
        'POOL:STATUS',
        {
          'connected': ['wss://a', 'wss://b'],
          'latency': {'wss://a': 12},
        }
      ]);
      final st = PoolMessage.parse(raw) as PoolStatus;
      expect(st.connected, ['wss://a', 'wss://b']);
    });

    test('malformed / unknown frames return null', () {
      expect(PoolMessage.parse('not json'), isNull);
      expect(PoolMessage.parse('{}'), isNull);
      expect(PoolMessage.parse(jsonEncode(['POOL:SHARDS', []])), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // 2. shard-by-role.
  // ---------------------------------------------------------------------------
  group('shardRelaysByRole', () {
    test('buckets relays into app-0 / critical / geo / discovered', () {
      final shards = shardRelaysByRole(
        [
          ...RelayConfig.defaultRelays,
          'wss://discovered-one.example',
          'wss://geo-a.example',
        ],
        ['wss://geo-a.example'],
        RelayConfig.defaultRelays,
      );
      final byId = {for (final s in shards) s.id: s};

      // app-0: just the app relay, with itself as a DM relay.
      expect(byId['app-0']!.relays, [RelayConfig.appRelay]);
      expect(byId['app-0']!.dmRelays, [RelayConfig.appRelay]);

      // critical-0: defaults minus app relay; carries the DM relays.
      final crit = byId['critical-0']!;
      expect(crit.relays.contains(RelayConfig.appRelay), isFalse);
      expect(crit.relays.contains('wss://relay.damus.io'), isTrue);
      expect(crit.dmRelays.isNotEmpty, isTrue);
      expect(crit.dmRelays.contains(RelayConfig.appRelay), isFalse);

      // geo-0: the geo CSV relay, not already reserved.
      expect(byId['geo-0']!.relays, ['wss://geo-a.example']);
      expect(byId['geo-0']!.dmRelays, isEmpty);

      // discovered-0: the extra relay not in defaults/geo.
      expect(byId['discovered-0']!.relays, ['wss://discovered-one.example']);
    });

    test('chunks each role at 50 relays per shard', () {
      // 120 synthetic discovered relays -> discovered-0/1/2 (50/50/20).
      final discovered = [
        for (var i = 0; i < 120; i++) 'wss://disc$i.example',
      ];
      final shards = shardRelaysByRole(
        discovered,
        const [],
        RelayConfig.defaultRelays,
      );
      final disc = shards.where((s) => s.role == 'discovered').toList();
      expect(disc.length, 3);
      expect(disc[0].relays.length, 50);
      expect(disc[1].relays.length, 50);
      expect(disc[2].relays.length, 20);
      expect(disc.map((s) => s.id),
          containsAll(['discovered-0', 'discovered-1', 'discovered-2']));
    });

    test('blocked relays are excluded from every shard', () {
      final shards = shardRelaysByRole(
        ['wss://relay.nosflare.com', 'wss://ok.example'],
        const [],
        RelayConfig.defaultRelays,
      );
      final all = shards.expand((s) => s.relays).toSet();
      expect(all.contains('wss://relay.nosflare.com'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 3. closest-geo-relay selection (Haversine).
  // ---------------------------------------------------------------------------
  group('closest geo relay selection', () {
    test('parseGeoRelaysCsv strips scheme + header', () {
      const csv = 'Relay URL,lat,lng\n'
          'wss://near.example/,40.0,-74.0\n'
          'far.example,1.0,1.0\n'
          'bad,row\n';
      final relays = parseGeoRelaysCsv(csv);
      expect(relays.length, 2);
      expect(relays[0].url, 'wss://near.example');
      expect(relays[0].lat, 40.0);
      expect(relays[1].url, 'wss://far.example');
    });

    test('picks the nearest relay to a geohash center', () async {
      // Geohash for ~NYC; near relay at NYC, far relay at the south pole-ish.
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'relays': [
              {'url': 'wss://far.example', 'lat': -80.0, 'lng': 0.0},
              {'url': 'wss://near.example', 'lat': 40.7, 'lng': -74.0},
              {'url': 'wss://mid.example', 'lat': 20.0, 'lng': -40.0},
            ]
          }),
          200,
        );
      });
      final svc = NostrService(
        identity: _identity(),
        pool: _NoopTransport(),
        apiClient: ApiClient(client: client, baseUrl: 'https://h/api/proxy'),
      );
      await svc.fetchGeoRelays();
      final closest = svc.closestGeoRelays('dr5regw', count: 1);
      expect(closest.length, 1);
      expect(closest.first.url, 'wss://near.example');
    });
  });

  // ---------------------------------------------------------------------------
  // 4. api_client URL builders + UA header.
  // ---------------------------------------------------------------------------
  group('ApiClient URL builders', () {
    final client = ApiClient(baseUrl: 'https://h/api/proxy');

    test('mediaProxyUrl encodes url; emoji flag', () {
      expect(client.mediaProxyUrl('https://x.com/a b.png'),
          'https://h/api/proxy?url=https%3A%2F%2Fx.com%2Fa%20b.png');
      expect(client.mediaProxyUrl('https://x.com/e.png', emoji: true),
          'https://h/api/proxy?emoji=1&url=https%3A%2F%2Fx.com%2Fe.png');
    });

    test('giphy search & trending include api_key', () {
      final c = ApiClient(baseUrl: 'https://h/api/proxy', giphyApiKey: 'KEY');
      expect(c.giphySearchUrl('cats'),
          'https://h/api/proxy?action=giphy&q=cats&api_key=KEY');
      expect(c.giphyTrendingUrl(),
          'https://h/api/proxy?action=giphy&trending=1&api_key=KEY');
    });

    test('geocode URL carries lat/lng/zoom/lang', () {
      expect(client.geocodeUrl(40.0, -74.0, zoom: 12, lang: 'en'),
          'https://h/api/proxy?action=geocode&lat=40.0&lng=-74.0&zoom=12&lang=en');
    });

    test('unfurl / geo-relays / blossom upload URLs', () {
      expect(client.unfurlUrl('https://x.com/p'),
          'https://h/api/proxy?action=unfurl&url=https%3A%2F%2Fx.com%2Fp');
      expect(client.geoRelaysUrl(), 'https://h/api/proxy?action=geo-relays');
      expect(client.blossomUploadUrl('https://blossom.band'),
          'https://h/api/proxy?action=upload&server=https%3A%2F%2Fblossom.band');
    });

    test('translate POST sends UA header + body shape', () async {
      late http.Request captured;
      final mock = MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({'translatedText': 'hola', 'detectedLanguage': 'en'}),
          200,
        );
      });
      final c = ApiClient(client: mock, baseUrl: 'https://h/api/proxy');
      final res = await c.translate('hello', 'es');
      expect(res.translatedText, 'hola');
      expect(res.detectedLanguage, 'en');
      // UA gate header present.
      expect(captured.headers['User-Agent'], ApiConfig.userAgent);
      expect(captured.headers['User-Agent'], startsWith('NymchatApp/'));
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['text'], 'hello');
      expect(body['target'], 'es');
      expect(body['source'], 'auto');
    });

    test('GET requests carry the isNymchatClient UA header', () async {
      Map<String, String>? hdrs;
      final mock = MockClient((req) async {
        hdrs = req.headers;
        return http.Response(jsonEncode({'relays': []}), 200);
      });
      final c = ApiClient(client: mock, baseUrl: 'https://h/api/proxy');
      await c.geoRelays();
      expect(hdrs!['User-Agent'], ApiConfig.userAgent);
    });

    // The nym worker sends charset-less `application/json` / `x-ndjson`
    // (storage.js:199/638); package:http's `res.body` then defaults to
    // LATIN-1, turning each UTF-8 byte into one char ('ð£…' mojibake for
    // '🅃…' nyms). The client must decode `bodyBytes` as UTF-8 like the
    // PWA's `response.json()`/TextDecoder.
    test('storage responses decode UTF-8 despite charset-less Content-Type',
        () async {
      const nym = '🅃🄾🄿🄶🄴🄰🅁 😀';
      final mock = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (body['action'] == 'profile-get') {
          // NDJSON stream, UTF-8 bytes, no charset in the header.
          return http.Response.bytes(
            utf8.encode('${jsonEncode({'name': nym})}\n'),
            200,
            headers: {'content-type': 'application/x-ndjson'},
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({'name': nym})),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final c = ApiClient(client: mock, baseUrl: 'https://h/api/proxy');
      final stream = await c.storageStream({'action': 'profile-get'});
      expect((stream.items.single as Map)['name'], nym);
      final data = await c.storageAction({'action': 'shop-status'});
      expect(data['name'], nym);
    });
  });

  // ---------------------------------------------------------------------------
  // ApiConfig sanity.
  // ---------------------------------------------------------------------------
  group('ApiConfig', () {
    test('relay-pool + proxy URLs target the fixed host', () {
      expect(ApiConfig.relayPoolUrl(),
          'wss://${ApiConfig.apiHost}/api/relay-pool');
      expect(ApiConfig.proxyBaseUrl(),
          'https://${ApiConfig.apiHost}/api/proxy');
      expect(ApiConfig.userAgent, matches(RegExp(r'^NymchatApp/')));
    });
  });

  // ---------------------------------------------------------------------------
  // RelayPoolProxy is a drop-in PoolTransport; sharding wires up sockets.
  // ---------------------------------------------------------------------------
  group('RelayPoolProxy transport', () {
    test('connectAll opens one socket per shard and dedupes events', () async {
      final fakes = <_FakeChannel>[];
      final proxy = RelayPoolProxy(
        relays: RelayConfig.defaultRelays,
        dmRelays: RelayConfig.defaultRelays,
        poolUrl: 'wss://h/api/relay-pool',
        channelFactory: (uri) {
          final f = _FakeChannel();
          fakes.add(f);
          return f;
        },
      );
      proxy.connectAll();
      // app-0 + critical-0 at minimum (defaults fit in one critical chunk).
      expect(proxy.shards.map((s) => s.id), contains('app-0'));
      expect(proxy.shards.map((s) => s.id), contains('critical-0'));
      expect(fakes.length, proxy.shards.length);

      // Each socket got its RELAYS config on open.
      expect(fakes.first.sent.first, contains('RELAYS'));

      final sub = proxy.subscribe([NostrFilter(kinds: [20000])]);
      // REQ went to every socket.
      for (final f in fakes) {
        expect(f.sent.any((m) => m.contains('"REQ"') || m.contains('REQ')),
            isTrue);
      }

      final got = <String>[];
      sub.events.listen((e) => got.add(e.id));

      // Same event id arrives on two shards -> delivered once (cross-shard dedup).
      final frame = jsonEncode([
        'EVENT',
        sub.subId,
        {
          'id': 'dupe',
          'pubkey': 'pk',
          'created_at': 1,
          'kind': 20000,
          'tags': [],
          'content': 'x',
          'sig': '',
        }
      ]);
      fakes[0].inject(frame);
      fakes[1].inject(frame);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(got, ['dupe']);

      await proxy.disconnectAll();
    });

    test('publishDm sends a DM_EVENT frame to every shard', () async {
      final fakes = <_FakeChannel>[];
      final proxy = RelayPoolProxy(
        relays: RelayConfig.defaultRelays,
        dmRelays: RelayConfig.defaultRelays,
        poolUrl: 'wss://h/api/relay-pool',
        channelFactory: (uri) {
          final f = _FakeChannel();
          fakes.add(f);
          return f;
        },
      );
      proxy.connectAll();
      final wrap = NostrEvent(
        id: 'wrapid',
        pubkey: 'pk',
        createdAt: 1,
        kind: 1059,
        tags: const [],
        content: 'sealed',
        sig: '',
      );
      final n = await proxy.publishDm(wrap);
      expect(n, fakes.length);
      for (final f in fakes) {
        final dm = f.sent.firstWhere((m) => m.contains('DM_EVENT'),
            orElse: () => '');
        expect(dm, isNotEmpty);
        final decoded = jsonDecode(dm) as List;
        expect(decoded[0], 'DM_EVENT');
        expect((decoded[1] as Map)['id'], 'wrapid');
      }
      await proxy.disconnectAll();
    });

    test('publishGeo sends GEO_EVENT with urls; plain EVENT when none', () async {
      final fakes = <_FakeChannel>[];
      final proxy = RelayPoolProxy(
        relays: RelayConfig.defaultRelays,
        dmRelays: RelayConfig.defaultRelays,
        poolUrl: 'wss://h/api/relay-pool',
        channelFactory: (uri) {
          final f = _FakeChannel();
          fakes.add(f);
          return f;
        },
      );
      proxy.connectAll();
      final ev = NostrEvent(
        id: 'geoid',
        pubkey: 'pk',
        createdAt: 1,
        kind: 20000,
        tags: const [
          ['g', 'u4pruyd']
        ],
        content: 'hi',
        sig: '',
      );
      await proxy.publishGeo(ev, const ['wss://geo.example.com']);
      final geo = fakes.first.sent
          .firstWhere((m) => m.contains('GEO_EVENT'), orElse: () => '');
      expect(geo, isNotEmpty);
      final decoded = jsonDecode(geo) as List;
      expect(decoded[0], 'GEO_EVENT');
      expect((decoded[1] as Map)['id'], 'geoid');
      expect(decoded[2], ['wss://geo.example.com']);

      // No closest relays -> plain EVENT fallback (PWA broadcastEvent).
      await proxy.publishGeo(ev, const []);
      final plain = fakes.first.sent.where((m) => m.contains('"EVENT"'));
      expect(plain, isNotEmpty);
      await proxy.disconnectAll();
    });

    test('POOL:RELAY_BAN adds the relay to the permanent blacklist', () async {
      final fakes = <_FakeChannel>[];
      final proxy = RelayPoolProxy(
        relays: RelayConfig.defaultRelays,
        dmRelays: RelayConfig.defaultRelays,
        poolUrl: 'wss://h/api/relay-pool',
        channelFactory: (uri) {
          final f = _FakeChannel();
          fakes.add(f);
          return f;
        },
      );
      proxy.connectAll();
      expect(proxy.permanentBlacklist, isNot(contains('wss://evil.relay')));
      fakes.first.inject(
          jsonEncode(['POOL:RELAY_BAN', 'wss://evil.relay', 'auth-required']));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(proxy.permanentBlacklist, contains('wss://evil.relay'));
      // A non-wss ban url is ignored.
      fakes.first.inject(jsonEncode(['POOL:RELAY_BAN', 'http://nope', 'x']));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(proxy.permanentBlacklist, isNot(contains('http://nope')));
      await proxy.disconnectAll();
    });
  });

  // ---------------------------------------------------------------------------
  // NostrService routes geo channel + gift-wrap publishes to the right frames.
  // ---------------------------------------------------------------------------
  group('NostrService publish routing', () {
    test('geohash channel message routes through publishGeo with closest urls',
        () async {
      final rec = _RecordingTransport();
      final sk = keys.generatePrivateKey();
      final svc = NostrService(
        identity: Identity(
          pubkey: keys.getPublicKeyHex(sk),
          privkey: sk,
          nym: 'tester',
        ),
        signer: LocalSigner(sk),
        pool: rec,
      );
      // Seed a geo relay near the geohash so closestGeoRelays returns it.
      svc.geoRelays.add(const GeoRelay(url: 'wss://geo.near', lat: 0, lng: 0));

      await svc.publishChannelMessage(
        channelKey: '',
        content: 'gm geo',
        nym: 'tester',
        geohash: 's0000',
      );
      expect(rec.geoCalls, hasLength(1));
      expect(rec.geoCalls.first.$1.kind, 20000);
      expect(rec.geoCalls.first.$2, isNotEmpty); // closest urls passed through
      expect(rec.plainCalls, isEmpty);
    });

    test('named channel message uses plain publish', () async {
      final rec = _RecordingTransport();
      final sk = keys.generatePrivateKey();
      final svc = NostrService(
        identity: Identity(
          pubkey: keys.getPublicKeyHex(sk),
          privkey: sk,
          nym: 'tester',
        ),
        signer: LocalSigner(sk),
        pool: rec,
      );
      await svc.publishChannelMessage(
        channelKey: 'bitcoin',
        content: 'gm named',
        nym: 'tester',
      );
      expect(rec.plainCalls, hasLength(1));
      expect(rec.plainCalls.first.kind, 23333);
      expect(rec.geoCalls, isEmpty);
    });

    test('gift-wrapped PM routes through publishDm', () async {
      final rec = _RecordingTransport();
      final sk = keys.generatePrivateKey();
      final me = keys.getPublicKeyHex(sk);
      final svc = NostrService(
        identity: Identity(pubkey: me, privkey: sk, nym: 'tester'),
        signer: LocalSigner(sk),
        pool: rec,
      );
      final rumor = UnsignedEvent(
        pubkey: me,
        createdAt: 1700000000,
        kind: 14,
        tags: const [],
        content: 'hello',
      );
      final peer = keys.getPublicKeyHex(keys.generatePrivateKey());
      await svc.publishPM(rumor: rumor, recipientPubkey: peer);
      // One wrap to the peer + one self-copy: both DM_EVENT, no plain EVENT.
      expect(rec.dmCalls.length, 2);
      for (final w in rec.dmCalls) {
        expect(w.kind, 1059);
      }
      expect(rec.plainCalls, isEmpty);
    });
  });
}

Identity _identity() => Identity(
      pubkey: 'a' * 64,
      privkey: null,
      nym: 'tester',
    );

/// A do-nothing PoolTransport so NostrService can be built without sockets.
class _NoopTransport implements PoolTransport {
  @override
  void connectAll() {}
  @override
  void updateGeoRelays(List<String> geoRelayUrls) {}
  @override
  Future<void> disconnectAll() async {}
  @override
  int get connectedCount => 0;
  @override
  Set<String> get connectedRelayUrls => const {};
  @override
  RelayStats get stats => RelayStats();
  @override
  Future<int> publish(NostrEvent event) async => 0;
  @override
  Future<int> publishDm(NostrEvent event) async => 0;
  @override
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls) async =>
      0;
  @override
  Subscription subscribe(List<NostrFilter> filters, {String? subId}) =>
      throw UnimplementedError();
  @override
  void closeSubscription(Subscription sub) {}
}

/// Records which publish path NostrService routes each event through so we can
/// assert GEO_EVENT / DM_EVENT routing without real sockets.
class _RecordingTransport implements PoolTransport {
  final List<NostrEvent> plainCalls = [];
  final List<NostrEvent> dmCalls = [];
  final List<(NostrEvent, List<String>)> geoCalls = [];
  final List<List<String>> geoUpdates = [];

  @override
  void connectAll() {}
  @override
  void updateGeoRelays(List<String> geoRelayUrls) =>
      geoUpdates.add(geoRelayUrls);
  @override
  Future<void> disconnectAll() async {}
  @override
  int get connectedCount => 0;
  @override
  Set<String> get connectedRelayUrls => const {};
  @override
  RelayStats get stats => RelayStats();
  @override
  Future<int> publish(NostrEvent event) async {
    plainCalls.add(event);
    return 1;
  }

  @override
  Future<int> publishDm(NostrEvent event) async {
    dmCalls.add(event);
    return 1;
  }

  @override
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls) async {
    geoCalls.add((event, closestRelayUrls));
    return 1;
  }

  @override
  Subscription subscribe(List<NostrFilter> filters, {String? subId}) =>
      throw UnimplementedError();
  @override
  void closeSubscription(Subscription sub) {}
}

/// A minimal in-memory [WebSocketChannel] stand-in. Captures everything written
/// to its sink in [sent]; [inject] pushes an inbound frame to listeners.
/// Unused members are routed through [noSuchMethod].
class _FakeChannel implements WebSocketChannel {
  final StreamController<dynamic> _inbound = StreamController<dynamic>();
  final List<String> sent = [];
  late final _FakeSink _sink = _FakeSink(sent, _inbound);

  void inject(String frame) => _inbound.add(frame);

  @override
  Stream<dynamic> get stream => _inbound.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  String? get protocol => null;
  @override
  int? get closeCode => _sink.closeCode;
  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._sent, this._inbound);
  final List<String> _sent;
  final StreamController<dynamic> _inbound;
  int? closeCode;

  @override
  void add(dynamic data) => _sent.add(data.toString());

  @override
  Future<dynamic> close([int? code, String? reason]) async {
    closeCode = code;
    if (!_inbound.isClosed) await _inbound.close();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<dynamic> addStream(Stream<dynamic> stream) async {
    await for (final d in stream) {
      add(d);
    }
  }

  @override
  Future<dynamic> get done => Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

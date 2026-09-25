import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/core/crypto/keys.dart' as keys;
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';
import 'package:nym_bar/services/nostr/identity_service.dart';
import 'package:nym_bar/services/nostr/nostr_service.dart';
import 'package:nym_bar/services/relay/relay_message.dart';
import 'package:nym_bar/services/relay/relay_pool.dart';
import 'package:nym_bar/services/relay/relay_stats.dart';

class _Transport implements PoolTransport {
  final List<NostrEvent> published = [];
  Subscription? lastSub;

  @override
  set geoOriginAllows(bool Function(NostrEvent event, String? relayUrl)? fn) {}
  @override
  void connectAll() {}
  @override
  void updateGeoRelays(List<String> geoRelayUrls) {}
  @override
  Future<void> disconnectAll() async {}
  @override
  int get connectedCount => 1;
  @override
  Set<String> get connectedRelayUrls => const {'wss://r.example'};
  @override
  RelayStats get stats => RelayStats();
  @override
  Future<int> publish(NostrEvent event) async {
    published.add(event);
    return 1;
  }

  @override
  Future<int> publishDm(NostrEvent event) => publish(event);
  @override
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls) =>
      publish(event);
  @override
  Subscription subscribe(List<NostrFilter> filters, {String? subId}) {
    final sub = Subscription.forTransport(
      subId ?? 'sub',
      this,
      (_) async => true,
      1,
      eoseQuorum: 1,
      eoseTimeout: const Duration(seconds: 5),
    );
    lastSub = sub;
    return sub;
  }

  @override
  void closeSubscription(Subscription sub) {}
}

http.Client _api(List<String> p, List<String> e) => MockClient((req) async {
      if (req.url.path.endsWith('/storage') &&
          req.body.contains('filter-get')) {
        return http.Response(jsonEncode({'p': p, 'e': e}), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{}', 404);
    });

NostrEvent _msg(String pubkey, String id) => NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: 1700000000,
      kind: 23333,
      tags: const [
        ['d', 'bitcoin'],
        ['n', 'someone']
      ],
      content: 'hi',
      sig: 'f' * 128,
    );

void main() {
  test('listed pubkeys and ids never reach the handlers', () async {
    final sk = keys.generatePrivateKey();
    final me = keys.getPublicKeyHex(sk);
    final listed = 'b' * 64;
    final tr = _Transport();
    final svc = NostrService(
      identity: Identity(pubkey: me, privkey: sk, nym: 'tester'),
      signer: LocalSigner(sk),
      pool: tr,
      apiClient:
          ApiClient(client: _api([listed], ['e' * 64]), baseUrl: 'https://h/api/proxy'),
    );
    final seen = <String>[];
    await svc.start(NostrHandlers(onEvent: (ev) => seen.add(ev.id)));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await tr.lastSub!.onEvent('wss://r.example', _msg(listed, '1' * 64));
    await tr.lastSub!.onEvent('wss://r.example', _msg('c' * 64, 'e' * 64));
    await tr.lastSub!.onEvent('wss://r.example', _msg('c' * 64, '2' * 64));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, ['2' * 64]);

    // Our own key is not listed, so publishing still reaches the transport.
    await svc.publishChannelMessage(
        channelKey: 'bitcoin', content: 'gm', nym: 'tester');
    expect(tr.published, hasLength(1));
    await svc.stop();
  });

  test('a listed identity keeps a working session but publishes nowhere',
      () async {
    final sk = keys.generatePrivateKey();
    final me = keys.getPublicKeyHex(sk);
    final tr = _Transport();
    final svc = NostrService(
      identity: Identity(pubkey: me, privkey: sk, nym: 'tester'),
      signer: LocalSigner(sk),
      pool: tr,
      apiClient: ApiClient(client: _api([me], []), baseUrl: 'https://h/api/proxy'),
    );
    final seen = <String>[];
    await svc.start(NostrHandlers(onEvent: (ev) => seen.add(ev.id)));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(svc.pool.connectedCount, 1);
    final n = await svc.pool.publish(_msg('c' * 64, '3' * 64));
    expect(n, 1);
    await svc.publishChannelMessage(
        channelKey: 'bitcoin', content: 'gm', nym: 'tester');
    expect(tr.published, isEmpty);

    // Reading is unaffected.
    await tr.lastSub!.onEvent('wss://r.example', _msg('c' * 64, '4' * 64));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, ['4' * 64]);
    await svc.stop();
  });

  test('an unreachable list leaves everything as it was', () async {
    final sk = keys.generatePrivateKey();
    final me = keys.getPublicKeyHex(sk);
    final tr = _Transport();
    final svc = NostrService(
      identity: Identity(pubkey: me, privkey: sk, nym: 'tester'),
      signer: LocalSigner(sk),
      pool: tr,
      apiClient: ApiClient(
          client: MockClient((_) async => http.Response('nope', 500)),
          baseUrl: 'https://h/api/proxy'),
    );
    final seen = <String>[];
    await svc.start(NostrHandlers(onEvent: (ev) => seen.add(ev.id)));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tr.lastSub!.onEvent('wss://r.example', _msg('c' * 64, '5' * 64));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(seen, ['5' * 64]);
    await svc.publishChannelMessage(
        channelKey: 'bitcoin', content: 'gm', nym: 'tester');
    expect(tr.published, hasLength(1));
    await svc.stop();
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/features/shop/shop_catalog.dart';
import 'package:nym_bar/features/shop/shop_controller.dart';
import 'package:nym_bar/features/nymbot/nymbot_models.dart';
import 'package:nym_bar/features/nymbot/nymbot_service.dart';
import 'package:nym_bar/features/zaps/lnurl.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A deterministic 32-byte test private key (non-zero, valid for bip340).
final Uint8List _testPriv = Uint8List.fromList(
  List<int>.generate(32, (i) => i + 1),
);
final String _testPub = getPublicKeyHex(_testPriv);

void main() {
  // ===========================================================================
  // 1. LNURL callback URL builder
  // ===========================================================================
  group('LNURL callback URL builder', () {
    LnurlPayParams params({
      int comment = 0,
      bool nostr = false,
      String? nostrPubkey,
    }) =>
        LnurlPayParams(
          callback: 'https://pay.example.com/lnurlp/callback',
          minSendable: 1000,
          maxSendable: 100000000,
          commentAllowed: comment,
          allowsNostr: nostr,
          nostrPubkey: nostrPubkey,
        );

    test('amount is encoded in millisats', () {
      final uri =
          Lnurl.buildCallbackUrl(params: params(), amountSats: 21);
      expect(uri.queryParameters['amount'], '21000'); // 21 * 1000
    });

    test('nostr= zap request param is attached when provider allows it', () {
      final zap = NostrEvent(
        pubkey: _testPub,
        createdAt: 1700000000,
        kind: 9734,
        tags: const [
          ['p', 'recipient'],
        ],
        content: 'zap',
      );
      final uri = Lnurl.buildCallbackUrl(
        params: params(nostr: true, nostrPubkey: 'abc'),
        amountSats: 100,
        zapRequest: zap,
      );
      final nostrParam = uri.queryParameters['nostr'];
      expect(nostrParam, isNotNull);
      final decoded = jsonDecode(nostrParam!) as Map<String, dynamic>;
      expect(decoded['kind'], 9734);
      expect(decoded['pubkey'], _testPub);
    });

    test('nostr= is omitted when provider does not advertise nostr', () {
      final zap = NostrEvent(
        pubkey: _testPub,
        createdAt: 1700000000,
        kind: 9734,
        content: 'zap',
      );
      final uri = Lnurl.buildCallbackUrl(
        params: params(nostr: false),
        amountSats: 100,
        zapRequest: zap,
      );
      expect(uri.queryParameters.containsKey('nostr'), isFalse);
    });

    test('comment is clamped to commentAllowed', () {
      final long = 'x' * 500;
      final uri = Lnurl.buildCallbackUrl(
        params: params(comment: 32),
        amountSats: 100,
        comment: long,
      );
      expect(uri.queryParameters['comment']!.length, 32);
    });

    test('comment is omitted when provider disallows comments', () {
      final uri = Lnurl.buildCallbackUrl(
        params: params(comment: 0),
        amountSats: 100,
        comment: 'hello',
      );
      expect(uri.queryParameters.containsKey('comment'), isFalse);
    });
  });

  // ===========================================================================
  // 2. bolt11 dedup (lowercased)
  // ===========================================================================
  group('bolt11 dedup', () {
    test('same lowercased bolt11 is counted once', () {
      const lower = 'lnbc210n1pjxyzabc';
      const upper = 'LNBC210N1PJXYZABC';
      final settled = <String>{};
      final a = LnInvoice(pr: lower, amountSats: 21);
      final b = LnInvoice(pr: upper, amountSats: 21);
      expect(a.dedupKey, b.dedupKey); // both lowercase
      expect(settled.add(a.dedupKey), isTrue); // first counts
      expect(settled.add(b.dedupKey), isFalse); // duplicate ignored
      expect(settled.length, 1);
    });
  });

  // ===========================================================================
  // 3. NIP-98 auth event builder (kind 27235)
  // ===========================================================================
  group('NIP-98 auth event builder', () {
    test('builds a valid signed kind-27235 event with the right tags', () {
      const url = 'https://web.nymchat.app/api/storage';
      const createdAt = 1700000000;
      final auth = Nip98Auth.build(
        action: 'shop-buy-invoice',
        url: url,
        privkey: _testPriv,
        pubkey: _testPub,
        createdAt: createdAt,
      );

      expect(auth['kind'], 27235);
      expect(auth['pubkey'], _testPub);
      expect(auth['created_at'], createdAt);
      expect(auth['content'], 'nymbot-pm-auth');

      final tags = (auth['tags'] as List)
          .map((t) => (t as List).map((e) => e.toString()).toList())
          .toList();
      String? tagVal(String name) {
        for (final t in tags) {
          if (t.isNotEmpty && t[0] == name && t.length > 1) return t[1];
        }
        return null;
      }

      expect(tagVal('domain'), 'nymbot-pm');
      expect(tagVal('method'), 'POST');
      expect(tagVal('u'), url);
      expect(tagVal('action'), 'shop-buy-invoice');
    });

    test('event id matches NIP-01 serialization and schnorr sig verifies', () {
      final auth = Nip98Auth.build(
        action: 'claim-credits',
        url: 'https://web.nymchat.app/api/bot',
        privkey: _testPriv,
        pubkey: _testPub,
        createdAt: 1700000001,
      );
      final event = NostrEvent.fromJson(auth);
      // id is the sha256 of [0,pubkey,created_at,kind,tags,content].
      expect(event.id, event.computeId());
      // schnorr signature verifies against the event pubkey.
      expect(schnorr.verifyEvent(event), isTrue);
    });

    test('created_at defaults to ~now (within the server ±120s window)', () {
      final auth = Nip98Auth.build(
        action: 'shop-claim',
        url: 'https://web.nymchat.app/api/storage',
        privkey: _testPriv,
        pubkey: _testPub,
      );
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final createdAt = auth['created_at'] as int;
      expect((createdAt - now).abs() <= 120, isTrue);
    });

    test('payloadHashHex drops auth + sorts keys, sha256 hex', () {
      final body = {
        'pubkey': 'p',
        'action': 'shop-claim',
        'auth': {'should': 'be dropped'},
        'invoiceId': 'abc',
      };
      final got = Nip98Auth.payloadHashHex(body);
      // Expected canonical: keys sorted ascending, auth removed.
      final canonical = {
        'action': 'shop-claim',
        'invoiceId': 'abc',
        'pubkey': 'p',
      };
      final expected =
          sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
      expect(got, expected);
      expect(got, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  // ===========================================================================
  // 4. shop request body shapes (via MockClient capture)
  // ===========================================================================
  group('shop request bodies', () {
    late List<http.Request> captured;
    late ApiClient api;

    ApiClient buildApi(Map<String, dynamic> Function(String action) reply) {
      final client = MockClient((req) async {
        captured.add(req);
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(reply(body['action'] as String)),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      return ApiClient(client: client, baseUrl: 'https://web.nymchat.app/api/proxy');
    }

    setUp(() => captured = []);

    test('shop-buy-invoice carries action/pubkey/itemId/auth', () async {
      api = buildApi((_) => {
            'pr': 'lnbc100n1pbuy',
            'verify': 'https://v.example/123',
            'invoiceId': 'a' * 64,
          });
      final auth = Nip98Auth.build(
        action: 'shop-buy-invoice',
        url: api.storageUrl,
        privkey: _testPriv,
        pubkey: _testPub,
      );
      await api.storageAction({
        'action': 'shop-buy-invoice',
        'pubkey': _testPub,
        'itemId': 'style-rainbow',
        'auth': auth,
      });
      final body = jsonDecode(captured.single.body) as Map<String, dynamic>;
      expect(captured.single.url.path, '/api/storage');
      expect(body['action'], 'shop-buy-invoice');
      expect(body['pubkey'], _testPub);
      expect(body['itemId'], 'style-rainbow');
      expect((body['auth'] as Map)['kind'], 27235);
    });

    test('shop-claim body has invoiceId (+optional receipt/gifterNym)',
        () async {
      api = buildApi((_) => {'itemId': 'style-rainbow', 'code': 'NYM-x'});
      await api.storageAction({
        'action': 'shop-claim',
        'pubkey': _testPub,
        'invoiceId': 'b' * 64,
        'gifterNym': 'alice#1234',
      });
      final body = jsonDecode(captured.single.body) as Map<String, dynamic>;
      expect(body['action'], 'shop-claim');
      expect(body['invoiceId'], 'b' * 64);
      expect(body['gifterNym'], 'alice#1234');
    });

    test('shop-redeem body has uppercased code', () async {
      api = buildApi((_) => {'itemId': 'style-rainbow', 'owned': {}, 'active': {}});
      await api.storageAction({
        'action': 'shop-redeem',
        'pubkey': _testPub,
        'code': 'NYM-${'A' * 32}',
      });
      final body = jsonDecode(captured.single.body) as Map<String, dynamic>;
      expect(body['action'], 'shop-redeem');
      expect(body['code'], 'NYM-${'A' * 32}');
    });

    test('shop-transfer uses the toPubkey field (not target)', () async {
      api = buildApi((_) => {'ok': true, 'owned': {}, 'active': {}});
      await api.storageAction({
        'action': 'shop-transfer',
        'pubkey': _testPub,
        'itemId': 'style-rainbow',
        'toPubkey': 'f' * 64,
      });
      final body = jsonDecode(captured.single.body) as Map<String, dynamic>;
      expect(body['toPubkey'], 'f' * 64);
      expect(body.containsKey('target'), isFalse);
    });

    test('storageUrl is derived as a sibling of the proxy base', () {
      final a = ApiClient(baseUrl: 'https://web.nymchat.app/api/proxy');
      expect(a.storageUrl, 'https://web.nymchat.app/api/storage');
      expect(a.botUrl, 'https://web.nymchat.app/api/bot');
    });
  });

  // ===========================================================================
  // 4b. ShopController own-record load (shop-get) + active publish (shop-set-active)
  // ===========================================================================
  group('ShopController shop-get / shop-set-active', () {
    late List<Map<String, dynamic>> bodies;

    Future<ShopController> build(
      Map<String, dynamic> Function(String action) reply,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        bodies.add(body);
        return http.Response(
          jsonEncode(reply(body['action'] as String)),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      return ShopController(
        kv,
        api: ApiClient(client: client, baseUrl: 'https://web.nymchat.app/api/proxy'),
      );
    }

    final identity = ShopIdentity(pubkey: _testPub, privkey: _testPriv);

    setUp(() => bodies = []);

    test('loadFromServer fetches shop-get (auth) and applies owned/active',
        () async {
      final ctrl = await build((_) => {
            'owned': {
              'style-rainbow': {'at': 1700000000000, 'amountSats': 500},
            },
            'active': {
              'style': 'style-rainbow',
              'flair': ['flair-crown'],
              'cosmetics': ['cosmetic-frost'],
              'supporter': false,
              'editions': {'flair-genesis': 9},
            },
            'updatedAt': 1700000000000,
          });
      await ctrl.loadFromServer(identity);
      final b = bodies.single;
      expect(b['action'], 'shop-get');
      expect(b['pubkey'], _testPub);
      expect((b['auth'] as Map)['kind'], 27235);
      // Applied locally.
      expect(ctrl.state.owns('style-rainbow'), isTrue);
      expect(ctrl.state.active.style, 'style-rainbow');
      expect(ctrl.state.active.flair, ['flair-crown']);
      expect(ctrl.state.active.cosmetics, ['cosmetic-frost']);
    });

    test('publishActiveItems pushes shop-set-active with the active payload',
        () async {
      final ctrl = await build((_) => {
            'active': {'style': 'style-rainbow', 'flair': [], 'cosmetics': []},
            'updatedAt': 1,
          });
      // Seed an owned + active style so the publish has something to send.
      await ctrl.applyOwnRecord({
        'owned': {
          'style-rainbow': {'at': 1, 'amountSats': 0},
        },
        'active': {'style': 'style-rainbow'},
      });
      bodies.clear();
      await ctrl.publishActiveItems(identity);
      final b = bodies.single;
      expect(b['action'], 'shop-set-active');
      expect(b['pubkey'], _testPub);
      expect((b['auth'] as Map)['kind'], 27235);
      final active = b['active'] as Map<String, dynamic>;
      expect(active['style'], 'style-rainbow');
      expect(active.containsKey('flair'), isTrue);
      expect(active.containsKey('cosmetics'), isTrue);
      expect(active['supporter'], isFalse); // not owned
    });
  });

  // ===========================================================================
  // 5. zap-verify response parse (paid true/false)
  // ===========================================================================
  group('zap-verify response parse', () {
    test('paid:true → true', () async {
      final client = MockClient((req) async {
        expect(req.url.queryParameters['action'], 'zap-verify');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['pr'], 'lnbc1');
        expect(body['verifyUrl'], 'https://v/1');
        return http.Response('{"paid":true}', 200,
            headers: {'content-type': 'application/json'});
      });
      final api =
          ApiClient(client: client, baseUrl: 'https://web.nymchat.app/api/proxy');
      final paid = await api.zapVerify(
        pr: 'lnbc1',
        verifyUrl: 'https://v/1',
        providerPubkey: 'abc',
      );
      expect(paid, isTrue);
    });

    test('paid:false → false', () async {
      final client = MockClient((_) async => http.Response('{"paid":false}', 200));
      final api =
          ApiClient(client: client, baseUrl: 'https://web.nymchat.app/api/proxy');
      expect(await api.zapVerify(pr: 'lnbc1'), isFalse);
    });

    test('non-200 / malformed → false (poll keeps retrying)', () async {
      final client = MockClient((_) async => http.Response('boom', 500));
      final api =
          ApiClient(client: client, baseUrl: 'https://web.nymchat.app/api/proxy');
      expect(await api.zapVerify(pr: 'lnbc1'), isFalse);
    });
  });

  // ===========================================================================
  // 6. bot credit request bodies (create-invoice / transfer-credits)
  // ===========================================================================
  group('bot credit request bodies', () {
    test('create-invoice body shape (tier pro, gift recipient)', () async {
      Map<String, dynamic>? sent;
      final client = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        expect(req.url.path, '/api/bot');
        return http.Response(
          jsonEncode({'pr': 'lnbc1', 'invoiceId': 'c' * 64, 'serverVerify': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final svc = NymbotService(client: client, baseUrl: 'https://web.nymchat.app/api/bot');
      final inv = await svc.buy(
        amountSats: 1000,
        tier: CreditTier.pro,
        pubkey: _testPub,
        recipientPubkey: 'd' * 64,
      );
      expect(sent!['action'], 'create-invoice');
      expect(sent!['amountSats'], 1000);
      expect(sent!['tier'], 'pro');
      expect(sent!['recipientPubkey'], 'd' * 64);
      expect(inv.pr, 'lnbc1');
      expect(inv.serverVerify, isTrue);
    });

    test('transfer-credits uses targetPubkey', () async {
      Map<String, dynamic>? sent;
      final client = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{"transferred":42}', 200,
            headers: {'content-type': 'application/json'});
      });
      final svc = NymbotService(client: client, baseUrl: 'https://web.nymchat.app/api/bot');
      final res = await svc.transfer(pubkey: _testPub, targetPubkey: 'e' * 64);
      expect(sent!['action'], 'transfer-credits');
      expect(sent!['targetPubkey'], 'e' * 64);
      expect(res['transferred'], 42);
    });

    test('buildAuth produces a kind-27235 event bound to the bot url', () {
      final svc = NymbotService(baseUrl: 'https://web.nymchat.app/api/bot');
      final auth = svc.buildAuth(
        action: 'create-invoice',
        pubkey: _testPub,
        privkey: _testPriv,
      );
      expect(auth, isNotNull);
      expect(auth!['kind'], 27235);
      final event = NostrEvent.fromJson(auth);
      expect(schnorr.verifyEvent(event), isTrue);
      expect(event.tagValue('u'), 'https://web.nymchat.app/api/bot');
      // No signable key → null (delegated signing).
      expect(
        svc.buildAuth(action: 'create-invoice', pubkey: _testPub),
        isNull,
      );
    });
  });

  // ===========================================================================
  // 7. CreditTier pricing constants (10 / 100 sats per credit)
  // ===========================================================================
  group('credit tier pricing', () {
    test('standard = 10, pro = 100 sats per credit', () {
      expect(CreditTier.standard.satsPerCredit, 10);
      expect(CreditTier.pro.satsPerCredit, 100);
      expect(CreditTier.standard.wire, 'standard');
      expect(CreditTier.pro.wire, 'pro');
    });
  });

  // ===========================================================================
  // 8. recovery code format validation
  // ===========================================================================
  group('recovery code', () {
    test('NYM-[0-9A-F]{32} validates (case-insensitive)', () {
      expect(ShopController.isValidRecoveryCode('NYM-${'A' * 32}'), isTrue);
      expect(ShopController.isValidRecoveryCode('nym-${'a' * 32}'), isTrue);
      expect(ShopController.isValidRecoveryCode('NYM-tooShort'), isFalse);
      expect(ShopController.isValidRecoveryCode('XXX-${'A' * 32}'), isFalse);
    });
  });

  // ===========================================================================
  // 9. shop catalog completeness (1:1 with js/app.js this.shopItems)
  // ===========================================================================
  group('shop catalog', () {
    test('catalog counts match the PWA (18/18/9/3/3 = 51 items)', () {
      expect(ShopCatalog.styles.length, 18);
      expect(ShopCatalog.flair.length, 18);
      expect(ShopCatalog.special.length, 9);
      expect(ShopCatalog.limited.length, 3);
      expect(ShopCatalog.bundles.length, 3);
      expect(ShopCatalog.all.length, 51);
    });

    test('bundle-everything resolves to every non-limited, non-bundle item', () {
      final comps = ShopCatalog.bundleComponents('bundle-everything');
      // 18 styles + 18 flair + 9 special, none of which carry maxSupply.
      expect(comps.length, 45);
      // No limited (maxSupply) items leak in.
      for (final id in comps) {
        expect(ShopCatalog.byId(id)!.maxSupply, isNull);
        expect(ShopCatalog.byId(id)!.type, isNot('bundle'));
      }
      // Spot-check a few representative ids are present.
      expect(comps, contains('style-satoshi'));
      expect(comps, contains('flair-crown'));
      expect(comps, contains('supporter-badge'));
      expect(comps, contains('cosmetic-aura-cosmic'));
      // The limited numbered editions are excluded.
      expect(comps, isNot(contains('flair-genesis')));
      expect(comps, isNot(contains('style-eclipse')));
    });

    test('static bundles return their declared component lists', () {
      expect(
        ShopCatalog.bundleComponents('bundle-starter'),
        ['flair-flame', 'style-ice', 'cosmetic-frost'],
      );
      expect(
        ShopCatalog.bundleComponents('bundle-legendary'),
        ['cosmetic-aura-phoenix', 'cosmetic-aura-rainbow', 'cosmetic-bubble-hologram'],
      );
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart' as keys;
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/features/identity/pq_registry.dart';
import 'package:nym_bar/features/identity/pq_root.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';
import 'package:nym_bar/services/nostr/identity_service.dart';
import 'package:nym_bar/services/nostr/nostr_service.dart';
import 'package:nym_bar/services/relay/relay_message.dart';
import 'package:nym_bar/services/relay/relay_pool.dart';
import 'package:nym_bar/services/relay/relay_stats.dart';

void main() {
  const peer =
      'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
  const t0 = 1800000000000;
  const sec = 1000;

  group('announcement lookups in the first minute', () {
    test('an unanswered lookup is a miss, retried after fifteen seconds', () {
      final limiter = PqLookupLimiter()
        ..record(peer, found: false, answered: false, nowMs: t0);
      expect(limiter.unanswered(peer), isTrue);
      bool due(int after) => limiter.due(peer,
          nowMs: t0 + after, announcedAtSec: 0, keyless: true);
      expect(due(5 * sec), isFalse);
      expect(due(16 * sec), isTrue);
    });

    test('an answered lookup that found nothing keeps the ten-minute window',
        () {
      final limiter = PqLookupLimiter()
        ..record(peer, found: false, answered: true, nowMs: t0);
      expect(limiter.unanswered(peer), isFalse);
      bool due(int after) => limiter.due(peer,
          nowMs: t0 + after, announcedAtSec: 0, keyless: true);
      expect(due(16 * sec), isFalse);
      expect(due(9 * 60 * sec), isFalse);
      expect(due(10 * 60 * sec), isTrue);
    });

    test('a freshly published keyless announcement is re-asked after fifteen '
        'seconds', () {
      final limiter = PqLookupLimiter()
        ..record(peer, found: false, answered: true, nowMs: t0);
      expect(
          limiter.due(peer,
              nowMs: t0 + 16 * sec,
              announcedAtSec: t0 ~/ sec,
              keyless: true),
          isTrue);
      expect(
          limiter.due(peer,
              nowMs: t0 + 5 * sec, announcedAtSec: t0 ~/ sec, keyless: true),
          isFalse);
    });

    test('an old keyless announcement keeps the ten-minute window', () {
      final limiter = PqLookupLimiter()
        ..record(peer, found: false, answered: true, nowMs: t0);
      expect(
          limiter.due(peer,
              nowMs: t0 + 16 * sec,
              announcedAtSec: t0 ~/ sec - 3600,
              keyless: true),
          isFalse);
    });

    test('a lookup that found the key clears the record', () {
      final limiter = PqLookupLimiter()
        ..record(peer, found: false, answered: false, nowMs: t0)
        ..record(peer, found: true, answered: true, nowMs: t0 + sec);
      expect(limiter.missedAt(peer), isNull);
      expect(
          limiter.due(peer, nowMs: t0 + sec, announcedAtSec: 0, keyless: true),
          isTrue);
    });
  });

  group('the relay lookup reports whether anyone answered', () {
    NostrService service(_FakeTransport transport) {
      final sk = keys.generatePrivateKey();
      return NostrService(
        identity:
            Identity(pubkey: keys.getPublicKeyHex(sk), privkey: sk, nym: 'me'),
        signer: LocalSigner(sk),
        pool: transport,
      );
    }

    test('no EOSE and no event is unanswered', () async {
      final transport = _FakeTransport();
      final answered = await service(transport).fetchPqAnnouncement(peer);
      expect(transport.subs, hasLength(1));
      expect(answered, isFalse);
    });

    test('an EOSE with nothing is an answer', () async {
      final transport = _FakeTransport();
      final pending = service(transport).fetchPqAnnouncement(peer);
      await Future<void>.delayed(Duration.zero);
      transport.subs.single.onEose('wss://relay.example');
      expect(await pending, isTrue);
    });

    test('a relay-side CLOSED is not an answer', () async {
      final transport = _FakeTransport();
      final pending = service(transport).fetchPqAnnouncement(peer);
      await Future<void>.delayed(Duration.zero);
      transport.subs.single.onEose('wss://relay.example', closed: true);
      expect(await pending, isFalse);
    });
  });

  group('a new key announces its key at once', () {
    test('a new key\'s first announcement carries a root-seeded key',
        () async {
      final seed = pqRootSeedForKey(
        holdRoot: false,
        localKey: true,
        throwawayKeypair: false,
        pendingForThisKey: true,
        freshKey: true,
      );
      expect(seed, isNot(PqRootSeed.none));

      final sk = keys.generatePrivateKey();
      final me = keys.getPublicKeyHex(sk);
      final transport = _FakeTransport();
      final svc = NostrService(
        identity: Identity(pubkey: me, privkey: sk, nym: 'me'),
        signer: LocalSigner(sk),
        pool: transport,
      );
      final root = pq.pqGenerateRoot();
      final signed = await svc.publishPqAnnouncement(
        kemPublicKey: pq.pqKeypairFromRoot(root, 0).publicKey,
        epoch: 0,
        devices: const [],
        rootSeeded: true,
      );
      expect(signed, isNotNull);
      final body = jsonDecode(signed!.content) as Map<String, dynamic>;
      expect(body['pk2'], isNotNull);
      expect(body['src'], 'root');

      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final registry = PqRegistry()
        ..ingest(me, signed.content,
            nowSec: nowSec, createdAt: signed.createdAt);
      expect(registry.keyFor(me, nowSec: nowSec, enabled: true), isNotNull);
      expect(registry.isRootSeeded(me, nowSec: nowSec, enabled: true), isTrue);
      expect(registry.acceptsLayered(me, nowSec: nowSec, enabled: true),
          isTrue);
    });

    test('an existing nsec login seeds nothing', () {
      expect(
          pqRootSeedForKey(
            holdRoot: false,
            localKey: true,
            throwawayKeypair: false,
            pendingForThisKey: false,
            freshKey: false,
          ),
          PqRootSeed.none);
    });

    final src = File('lib/state/nostr_controller.dart').readAsStringSync();
    String seedBody() {
      final start = src.indexOf('Future<void> _seedNewKeyPqRoot(');
      return src.substring(start, src.indexOf('\n  }\n', start));
    }

    test('seeding a new key settles the root before the first announcement',
        () {
      final body = seedBody();
      final persist = body.indexOf('if (!await _persistPqRoot(root)) return;');
      final settle = body.indexOf('_pqRootSettled = true;');
      expect(persist, greaterThan(-1));
      expect(settle, greaterThan(persist));
      expect(body.contains('_pqRootRecordPending = true;'), isTrue);
      expect(
          src.contains(
              'final keys = (pqEnabled && _pqRootSettled) ? _pqSelfKeys() : null;'),
          isTrue);
    });

    test('an existing nsec login leaves the root unsettled until the read',
        () {
      final body = seedBody();
      expect(body.indexOf('case PqRootSeed.none:\n        return;'),
          lessThan(body.indexOf('_pqRootSettled = true;')));
    });

    test('the settings read still records a freshly seeded root', () {
      expect(
          src.contains('if (_pqRootSettled &&\n'
              '        !_pqRootRecordPending &&\n'
              '        (_pqRoot != null || _pqRootLocked)) {'),
          isTrue);
      final decide = src.substring(src.indexOf('final action = pqRootDecide('));
      final head = decide.substring(0, decide.indexOf('switch (action)'));
      expect(head.contains('_pqRootRecordPending = false;'), isTrue);
      expect(
          pqRootDecide(
              recordLoadSucceeded: true, recordPresent: false, holdRoot: true),
          PqRootAction.publishRecord);
    });
  });
}

class _FakeTransport implements PoolTransport {
  final List<Subscription> subs = [];

  @override
  set geoOriginAllows(bool Function(NostrEvent event, String? relayUrl)? fn) {}
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
  Future<int> publish(NostrEvent event) async => 1;
  @override
  Future<int> publishDm(NostrEvent event) async => 1;
  @override
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls) async
      => 1;
  @override
  Subscription subscribe(List<NostrFilter> filters, {String? subId}) {
    final sub = Subscription.forTransport(
      subId ?? 'sub${subs.length}',
      this,
      (_) async => true,
      1,
      eoseQuorum: 0.6,
      eoseTimeout: const Duration(seconds: 4),
    );
    sub.startEose();
    subs.add(sub);
    return sub;
  }

  @override
  void closeSubscription(Subscription sub) {}
}

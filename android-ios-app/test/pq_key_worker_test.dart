import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/core/crypto/keys.dart' as keys;
import 'package:nym_bar/core/crypto/pq.dart' as pq;
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/features/identity/pq_announcement_source.dart';
import 'package:nym_bar/features/identity/pq_registry.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/api/storage_sync.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class _Party {
  _Party() : sk = keys.generatePrivateKey() {
    pubkey = keys.getPublicKeyHex(sk);
  }
  final Uint8List sk;
  late final String pubkey;

  Future<NostrEvent> announce({
    bool withKey = true,
    int? createdAt,
    int? tagExpiration,
  }) {
    final at = createdAt ?? _now();
    final exp = at + pqTtl.inSeconds;
    return LocalSigner(sk).sign(UnsignedEvent(
      pubkey: pubkey,
      createdAt: at,
      kind: EventKind.appData,
      tags: [
        ['d', AppDataTopic.postQuantum],
        ['t', AppDataTopic.postQuantum],
        ['expiration', '${tagExpiration ?? exp}'],
      ],
      content: PqAnnouncement.encode(
        publicKey: withKey
            ? pq.pqKeypairFromRoot(pq.pqGenerateRoot(), 0).publicKey
            : null,
        expiresAt: exp,
        epoch: 0,
        devices: const [],
      ),
    ));
  }
}

class _Harness {
  _Harness({
    this.worker,
    List<Map<String, dynamic>> archiveRows = const [],
    this.relaysAnswer = true,
    Duration timeout = PqAnnouncementSource.defaultPqKeyTimeout,
  }) : _archiveRows = archiveRows {
    source = PqAnnouncementSource(
      pqKey: worker == null
          ? null
          : (pk) {
              workerCalls.add(pk);
              return worker!(pk);
            },
      archive: (pk) async {
        archiveCalls.add(pk);
        return _archiveRows;
      },
      verify: (e) async => schnorr.verifyEvent(e),
      pqKeyTimeout: timeout,
    );
  }

  final PqKeyFetch? worker;
  final List<Map<String, dynamic>> _archiveRows;
  final bool relaysAnswer;
  late final PqAnnouncementSource source;
  final registry = PqRegistry();
  final workerCalls = <String>[];
  final archiveCalls = <String>[];
  var relayCalls = 0;

  bool hasKey(String pk) =>
      registry.keyFor(pk, nowSec: _now(), enabled: true) != null;

  Future<bool> resolve(String pk) => source.resolve(
        pk,
        ingest: (e) {
          registry.ingest(e.pubkey, e.content,
              nowSec: _now(), createdAt: e.createdAt);
          return hasKey(pk);
        },
        relays: () async {
          relayCalls++;
          return relaysAnswer;
        },
      );
}

void main() {
  group('pq-key worker lookup', () {
    test('a pq-key hit needs neither channel-get nor the relays', () async {
      final peer = _Party();
      final ev = await peer.announce();
      final h = _Harness(worker: (_) async => ev.toJson());
      expect(await h.resolve(peer.pubkey), isTrue);
      expect(h.workerCalls, [peer.pubkey]);
      expect(h.archiveCalls, isEmpty);
      expect(h.relayCalls, 0);
      expect(h.hasKey(peer.pubkey), isTrue);
    });

    test('a forged event is refused and the lookup falls back', () async {
      final peer = _Party();
      final attacker = _Party();
      final real = await peer.announce();
      final theirs = await attacker.announce();
      final forged = NostrEvent(
        pubkey: peer.pubkey,
        createdAt: theirs.createdAt,
        kind: theirs.kind,
        tags: theirs.tags,
        content: theirs.content,
        sig: theirs.sig,
      );
      forged.id = forged.computeId();
      final tampered = real.toJson()..['content'] = theirs.content;

      for (final bad in [forged.toJson(), tampered, theirs.toJson()]) {
        final h = _Harness(worker: (_) async => bad);
        expect(await h.resolve(peer.pubkey), isTrue);
        expect(h.hasKey(peer.pubkey), isFalse);
        expect(h.archiveCalls, [peer.pubkey]);
        expect(h.relayCalls, 1);
      }
    });

    test('an expired announcement from the worker is refused', () async {
      final peer = _Party();
      final ev = await peer.announce(tagExpiration: _now() - 60);
      final h = _Harness(worker: (_) async => ev.toJson());
      await h.resolve(peer.pubkey);
      expect(h.hasKey(peer.pubkey), isFalse);
      expect(h.relayCalls, 1);
    });

    test('pq-key down falls back to channel-get', () async {
      final peer = _Party();
      final ev = await peer.announce();
      final h = _Harness(
        worker: (_) async => throw const SocketException('down'),
        archiveRows: [ev.toJson()],
      );
      expect(await h.resolve(peer.pubkey), isTrue);
      expect(h.archiveCalls, [peer.pubkey]);
      expect(h.relayCalls, 0);
      expect(h.hasKey(peer.pubkey), isTrue);
    });

    test('a pq-key that never answers times out into channel-get', () async {
      final peer = _Party();
      final ev = await peer.announce();
      final h = _Harness(
        worker: (_) => Completer<Map<String, dynamic>?>().future,
        archiveRows: [ev.toJson()],
        timeout: const Duration(milliseconds: 20),
      );
      expect(await h.resolve(peer.pubkey), isTrue);
      expect(h.archiveCalls, [peer.pubkey]);
      expect(h.hasKey(peer.pubkey), isTrue);
    });

    test('pq-key and channel-get both down still reaches the relays', () async {
      final peer = _Party();
      final h = _Harness(
        worker: (_) async => throw const SocketException('down'),
        relaysAnswer: false,
      );
      expect(await h.resolve(peer.pubkey), isFalse);
      expect(h.archiveCalls, [peer.pubkey]);
      expect(h.relayCalls, 1);
    });

    test('a null answer for a peer goes to the relays, not channel-get',
        () async {
      final peer = _Party();
      final h = _Harness(worker: (_) async => null, relaysAnswer: false);
      expect(await h.resolve(peer.pubkey), isFalse);
      expect(h.archiveCalls, isEmpty);
      expect(h.relayCalls, 1);
    });

    test('a keyless announcement from pq-key still asks the relays', () async {
      final peer = _Party();
      final ev = await peer.announce(withKey: false);
      final h = _Harness(worker: (_) async => ev.toJson());
      expect(await h.resolve(peer.pubkey), isTrue);
      expect(h.archiveCalls, isEmpty);
      expect(h.relayCalls, 1);
      expect(h.hasKey(peer.pubkey), isFalse);
    });

    test('the bot key resolves from a freshly signed event on an empty archive',
        () async {
      final bot = _Party();
      final h = _Harness(
        worker: (pk) async =>
            pk == bot.pubkey ? (await bot.announce()).toJson() : null,
      );
      expect(await h.resolve(bot.pubkey), isTrue);
      expect(h.archiveCalls, isEmpty);
      expect(h.relayCalls, 0);
      expect(h.hasKey(bot.pubkey), isTrue);
    });

    test('without a storage session only the relays are asked', () async {
      final peer = _Party();
      var relays = 0;
      final source = PqAnnouncementSource(verify: (_) async => true);
      final answered = await source.resolve(
        peer.pubkey,
        ingest: (_) => true,
        relays: () async {
          relays++;
          return true;
        },
      );
      expect(answered, isTrue);
      expect(relays, 1);
    });
  });

  group('the pq-key request', () {
    StorageSync sync(http.Client client) => StorageSync(
          api: ApiClient(client: client),
          signer: LocalSigner(keys.generatePrivateKey()),
          pubkey: _Party().pubkey,
          durableIdentity: false,
        );

    test('posts the pubkey to the bot API and returns the event', () async {
      final peer = _Party();
      final ev = await peer.announce();
      late Uri url;
      late Map<String, dynamic> body;
      final client = MockClient((req) async {
        url = req.url;
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'event': ev.toJson()}), 200);
      });
      final got = await sync(client).pqKey(peer.pubkey);
      expect(url.path, endsWith('/api/bot'));
      expect(body, {'action': 'pq-key', 'pubkey': peer.pubkey});
      expect(got?['id'], ev.id);
    });

    test('a null event is an answer and an error status throws', () async {
      final peer = _Party();
      final none = MockClient(
          (_) async => http.Response(jsonEncode({'event': null}), 200));
      expect(await sync(none).pqKey(peer.pubkey), isNull);
      final down = MockClient((_) async => http.Response('{}', 500));
      expect(sync(down).pqKey(peer.pubkey), throwsA(isA<ApiException>()));
      final old = MockClient((_) async =>
          http.Response(jsonEncode({'error': 'Missing command'}), 200));
      expect(sync(old).pqKey(peer.pubkey), throwsA(isA<ApiException>()));
    });
  });

  test('the controller resolves through the fakeable pq-key source', () {
    final src = File('lib/state/nostr_controller.dart').readAsStringSync();
    expect(src.contains('_ref.read(pqKeyFetchProvider) ?? sync.pqKey'), isTrue);
    expect(src.contains('final f = _pqAnnouncementSource()'), isTrue);
  });
}

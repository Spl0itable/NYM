import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/features/identity/nip46_service.dart';
import 'package:nym_bar/models/nostr_event.dart';

/// In-memory [Nip46Socket]: captures frames sent by the client and lets the
/// test inject inbound frames as if they came from the relay.
class FakeSocket implements Nip46Socket {
  final _inbound = StreamController<String>.broadcast();
  final List<String> sent = [];
  bool closed = false;

  @override
  Stream<String> get messages => _inbound.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
    await _inbound.close();
  }

  /// Simulate a relay delivering an inbound frame to the client.
  void deliver(String frame) => _inbound.add(frame);
}

/// In-memory secure store.
class FakeSecure implements Nip46SecureStore {
  final Map<String, String> data = {};
  @override
  Future<String?> get(String key) async => data[key];
  @override
  Future<void> set(String key, String value) async => data[key] = value;
  @override
  Future<void> remove(String key) async => data.remove(key);
}

/// In-memory key-value store.
class FakeKv implements Nip46KeyValueStore {
  final Map<String, String> data = {};
  @override
  String? getString(String key) => data[key];
  @override
  Future<void> setString(String key, String value) async => data[key] = value;
}

void main() {
  group('nostrconnect:// URI builder', () {
    test('builds and parses back clientPubkey, relay, secret, metadata', () {
      final clientPriv = generatePrivateKey();
      final clientPub = getPublicKeyHex(clientPriv);
      const relay = 'wss://relay.primal.net';
      const secret = 'a1b2c3d4e5f60718';

      final uri = Nip46Service.buildNostrConnectUri(
        clientPubkey: clientPub,
        relay: relay,
        secret: secret,
      );

      expect(uri, startsWith('nostrconnect://$clientPub?'));

      final parsed = Nip46Service.parseConnectionUri(uri);
      expect(parsed.scheme, 'nostrconnect');
      expect(parsed.isNostrConnect, isTrue);
      expect(parsed.pubkey, clientPub);
      expect(parsed.relay, relay);
      expect(parsed.secret, secret);
      expect(parsed.metadataName, 'Nymchat');
    });
  });

  group('bunker:// URI parser', () {
    test('extracts remote pubkey + relay + secret', () {
      final remotePriv = generatePrivateKey();
      final remotePub = getPublicKeyHex(remotePriv);
      const relay = 'wss://relay.nsec.app';
      const secret = 'deadbeefcafe0011';

      final uri =
          'bunker://$remotePub?relay=${Uri.encodeQueryComponent(relay)}'
          '&secret=$secret';

      final parsed = Nip46Service.parseConnectionUri(uri);
      expect(parsed.scheme, 'bunker');
      expect(parsed.isBunker, isTrue);
      expect(parsed.pubkey, remotePub);
      expect(parsed.relay, relay);
      expect(parsed.secret, secret);
    });

    test('falls back to default relay when none given', () {
      final remotePub = getPublicKeyHex(generatePrivateKey());
      final parsed = Nip46Service.parseConnectionUri('bunker://$remotePub');
      expect(parsed.relay, 'wss://relay.primal.net');
      expect(parsed.secret, isNull);
    });

    test('rejects a non-NIP-46 scheme and a bad pubkey', () {
      expect(
        () => Nip46Service.parseConnectionUri('https://example.com'),
        throwsFormatException,
      );
      expect(
        () => Nip46Service.parseConnectionUri('bunker://tooshort'),
        throwsFormatException,
      );
    });
  });

  group('RPC request framing (real NIP-44 round-trip)', () {
    test('request encrypts to the signer; synthesized response matches id', () {
      fakeAsync((async) {
        // The signer keypair. The client (ephemeral) keypair is generated
        // inside the service; we read its pubkey back via svc.clientPubkey.
        final signerPriv = generatePrivateKey();
        final signerPub = getPublicKeyHex(signerPriv);

        final socket = FakeSocket();
        final svc = Nip46Service(
          kv: FakeKv(),
          secure: FakeSecure(),
          socketFactory: (_) => socket,
        );

        // Drive the bunker connect flow up to sending the first RPC.
        final uri = 'bunker://$signerPub?relay=wss://relay.primal.net';
        final connectFuture = svc.connectViaUri(uri);
        async.flushMicrotasks();
        final clientPub = svc.clientPubkey!;

        // The client should have REQ-subscribed then sent an EVENT (connect).
        expect(socket.sent.any((s) => s.startsWith('["REQ"')), isTrue);
        final eventFrame =
            socket.sent.firstWhere((s) => s.contains('"EVENT"'));
        final eventMsg = jsonDecode(eventFrame) as List;
        final event =
            NostrEvent.fromJson(eventMsg[1] as Map<String, dynamic>);

        // The event is a real signed kind-24133 to the signer.
        expect(event.kind, 24133);
        expect(event.pubkey, clientPub);
        expect(event.tagValue('p'), signerPub);
        expect(schnorr.verifyEvent(event), isTrue);

        // Decrypt the request as the signer would (real NIP-44).
        final signerCk = nip44.getConversationKey(signerPriv, clientPub);
        final reqJson = jsonDecode(nip44.decrypt(event.content, signerCk))
            as Map<String, dynamic>;
        expect(reqJson['method'], 'connect');
        final reqId = reqJson['id'] as String;

        // Signer replies with `ack` echoed for this id, NIP-44-encrypted back.
        _deliverResponse(
          socket: socket,
          signerPriv: signerPriv,
          signerPub: signerPub,
          clientPub: clientPub,
          subId: _subIdOf(socket),
          body: {'id': reqId, 'result': 'ack'},
        );
        async.flushMicrotasks();

        // Now the service issues get_public_key; answer with the signer pubkey.
        final getPkFrame = socket.sent.lastWhere((s) => s.contains('"EVENT"'));
        final getPkEvent = NostrEvent.fromJson(
            (jsonDecode(getPkFrame) as List)[1] as Map<String, dynamic>);
        final getPkReq = jsonDecode(nip44.decrypt(getPkEvent.content, signerCk))
            as Map<String, dynamic>;
        expect(getPkReq['method'], 'get_public_key');

        _deliverResponse(
          socket: socket,
          signerPriv: signerPriv,
          signerPub: signerPub,
          clientPub: clientPub,
          subId: _subIdOf(socket),
          body: {'id': getPkReq['id'], 'result': signerPub},
        );
        async.flushMicrotasks();

        Nip46ConnectResult? result;
        connectFuture.then((r) => result = r);
        async.flushMicrotasks();

        expect(result, isNotNull);
        expect(result!.userPubkey, signerPub);
        expect(svc.pubkey, signerPub);
      });
    });
  });

  group('pendingRequests resolution + timeout', () {
    test('resolves the right future by id and times out otherwise', () {
      fakeAsync((async) {
        final signerPriv = generatePrivateKey();
        final signerPub = getPublicKeyHex(signerPriv);

        final socket = FakeSocket();
        final svc = Nip46Service(
          kv: FakeKv(),
          secure: FakeSecure(),
          socketFactory: (_) => socket,
          requestTimeout: const Duration(seconds: 5),
        );

        // Bring the service to a connected state without the login dance:
        // open the relay via the bunker path, then settle remote pubkey.
        final connectFut = svc.connectViaUri(
          'bunker://$signerPub?relay=wss://relay.primal.net',
        );
        async.flushMicrotasks();
        final clientPub = svc.clientPubkey!;

        final signerCk = nip44.getConversationKey(signerPriv, clientPub);
        final subId = _subIdOf(socket);

        // Answer the initial connect so we reach a usable signer.
        final connectEvent = _lastEvent(socket);
        final connectId = jsonDecode(
            nip44.decrypt(connectEvent.content, signerCk))['id'] as String;
        _deliverResponse(
          socket: socket,
          signerPriv: signerPriv,
          signerPub: signerPub,
          clientPub: clientPub,
          subId: subId,
          body: {'id': connectId, 'result': 'ack'},
        );
        async.flushMicrotasks();
        // Answer get_public_key.
        final gpkEvent = _lastEvent(socket);
        final gpkId =
            jsonDecode(nip44.decrypt(gpkEvent.content, signerCk))['id']
                as String;
        _deliverResponse(
          socket: socket,
          signerPriv: signerPriv,
          signerPub: signerPub,
          clientPub: clientPub,
          subId: subId,
          body: {'id': gpkId, 'result': signerPub},
        );
        async.flushMicrotasks();
        connectFut.then((_) {});
        async.flushMicrotasks();

        // Fire two concurrent RPCs.
        Object? aResult;
        Object? bError;
        final futA = svc.nip44Encrypt(signerPub, 'hello');
        final futB = svc.nip44Decrypt(signerPub, 'world');
        futA.then((v) => aResult = v);
        futB.catchError((Object e) {
          bError = e;
          return '';
        });
        async.flushMicrotasks();

        // Find both request ids.
        final events = _allEvents(socket)
            .map((e) =>
                jsonDecode(nip44.decrypt(e.content, signerCk))
                    as Map<String, dynamic>)
            .toList();
        final encReq =
            events.firstWhere((m) => m['method'] == 'nip44_encrypt');
        // Only respond to request A; leave B to time out. Use the *current*
        // sub id (the service re-subscribed persistently after login).
        _deliverResponse(
          socket: socket,
          signerPriv: signerPriv,
          signerPub: signerPub,
          clientPub: clientPub,
          subId: _subIdOf(socket),
          body: {'id': encReq['id'], 'result': 'CIPHERTEXT_A'},
        );
        async.flushMicrotasks();

        expect(aResult, 'CIPHERTEXT_A');
        expect(bError, isNull); // not yet timed out

        // Advance past the timeout; B should reject.
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(bError, isA<TimeoutException>());
      });
    });
  });

  group('session persistence + restore', () {
    test('persists method/relay/remote pubkey + client secret, restores back',
        () {
      fakeAsync((async) {
        final signerPriv = generatePrivateKey();
        final signerPub = getPublicKeyHex(signerPriv);

        final kv = FakeKv();
        final secure = FakeSecure();
        final socket = FakeSocket();

        final svc = Nip46Service(
          kv: kv,
          secure: secure,
          socketFactory: (_) => socket,
        );
        final fut =
            svc.connectViaUri('bunker://$signerPub?relay=wss://relay.x');
        async.flushMicrotasks();
        final clientPub = svc.clientPubkey!;

        final signerCk = nip44.getConversationKey(signerPriv, clientPub);
        final subId = _subIdOf(socket);

        final connId = jsonDecode(
            nip44.decrypt(_lastEvent(socket).content, signerCk))['id']
            as String;
        _deliverResponse(
          socket: socket,
          signerPriv: signerPriv,
          signerPub: signerPub,
          clientPub: clientPub,
          subId: subId,
          body: {'id': connId, 'result': 'ack'},
        );
        async.flushMicrotasks();
        final gpkId = jsonDecode(
            nip44.decrypt(_lastEvent(socket).content, signerCk))['id']
            as String;
        _deliverResponse(
          socket: socket,
          signerPriv: signerPriv,
          signerPub: signerPub,
          clientPub: clientPub,
          subId: subId,
          body: {'id': gpkId, 'result': signerPub},
        );
        async.flushMicrotasks();
        fut.then((_) {});
        async.flushMicrotasks();

        // Persistence assertions (PWA key parity).
        expect(kv.data['nym_nostr_login_method'], 'nip46');
        expect(kv.data['nym_nostr_login_pubkey'], signerPub);
        expect(kv.data['nym_nip46_remote_pubkey'], signerPub);
        expect(kv.data['nym_nip46_relay'], 'wss://relay.x');
        // Stored client secret is the ephemeral key; it derives to clientPub.
        final storedSecretHex = secure.data['nym_nip46_client_secret']!;
        expect(getPublicKeyHex(hexToBytes(storedSecretHex)), clientPub);

        // Restore into a fresh service.
        final socket2 = FakeSocket();
        final svc2 = Nip46Service(
          kv: kv,
          secure: secure,
          socketFactory: (_) => socket2,
        );
        bool restored = false;
        svc2.restoreSession().then((v) => restored = v);
        async.flushMicrotasks();
        expect(restored, isTrue);
        expect(svc2.remotePubkey, signerPub);
        expect(svc2.pubkey, signerPub);
        expect(svc2.clientPubkey, clientPub);
        // Re-subscribed on the new socket.
        expect(socket2.sent.any((s) => s.startsWith('["REQ"')), isTrue);
      });
    });
  });
}

// --- helpers ----------------------------------------------------------------

String _subIdOf(FakeSocket socket) {
  final reqFrame = socket.sent.lastWhere((s) => s.startsWith('["REQ"'));
  return (jsonDecode(reqFrame) as List)[1] as String;
}

NostrEvent _lastEvent(FakeSocket socket) {
  final frame = socket.sent.lastWhere((s) => s.contains('"EVENT"'));
  return NostrEvent.fromJson((jsonDecode(frame) as List)[1] as Map<String, dynamic>);
}

List<NostrEvent> _allEvents(FakeSocket socket) => socket.sent
    .where((s) => s.contains('"EVENT"'))
    .map((s) => NostrEvent.fromJson((jsonDecode(s) as List)[1] as Map<String, dynamic>))
    .toList();

void _deliverResponse({
  required FakeSocket socket,
  required Uint8List signerPriv,
  required String signerPub,
  required String clientPub,
  required String subId,
  required Map<String, dynamic> body,
}) {
  final ck = nip44.getConversationKey(signerPriv, clientPub);
  final content = nip44.encrypt(jsonEncode(body), ck);
  final unsigned = UnsignedEvent(
    pubkey: signerPub,
    createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    kind: 24133,
    tags: [
      ['p', clientPub],
    ],
    content: content,
  );
  final signed = schnorr.finalizeEvent(unsigned, signerPriv);
  socket.deliver(jsonEncode(['EVENT', subId, signed.toJson()]));
}

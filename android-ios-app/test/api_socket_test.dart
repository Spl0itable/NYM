import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/nostr/event_signer.dart';
import 'package:nym_bar/services/relay/relay_stats.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A stand-in NIP-46 remote signer: `isRemote` is true and `sign` round-trips
/// asynchronously (counting calls), so a test can prove `buildSigned` signs auth
/// for remote-signer accounts and caches the result.
class _FakeRemoteSigner implements EventSigner {
  _FakeRemoteSigner(this.pubkey);

  @override
  final String pubkey;

  int signCount = 0;

  @override
  bool get isRemote => true;

  @override
  Future<NostrEvent> sign(UnsignedEvent u) async {
    signCount++;
    final e = NostrEvent(
      pubkey: pubkey,
      createdAt: u.createdAt,
      kind: u.kind,
      tags: u.tags,
      content: u.content,
    );
    e.id = e.computeId();
    e.sig = 'f' * 128; // opaque remote signature
    return e;
  }

  @override
  Future<String> nip44Encrypt(String peer, String plaintext) async => plaintext;
  @override
  Future<String> nip44Decrypt(String peer, String ciphertext) async => ciphertext;
}

/// A fake `/api` WebSocket the test drives: queued auto-replies are injected in
/// response to the frames the client sends, so we can exercise the multiplexed
/// AUTH/REQ → AUTH_OK/RES/ITEM/END protocol without a real socket.
class _FakeApiChannel implements WebSocketChannel {
  _FakeApiChannel(this._onSend);

  final StreamController<dynamic> _inbound = StreamController<dynamic>.broadcast();
  final List<String> sent = [];
  late final _FakeSink _sink = _FakeSink(sent, _inbound, _onSend);

  /// Called with (channel, decodedFrame) whenever the client sends a frame, so
  /// the test can inject the matching server reply.
  final void Function(_FakeApiChannel ch, List<dynamic> frame) _onSend;

  void inject(List<dynamic> frame) {
    if (!_inbound.isClosed) _inbound.add(jsonEncode(frame));
  }

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._sent, this._inbound, this._onSend);
  final List<String> _sent;
  final StreamController<dynamic> _inbound;
  final void Function(_FakeApiChannel ch, List<dynamic> frame) _onSend;
  _FakeApiChannel? channel;
  int? closeCode;

  @override
  void add(dynamic data) {
    _sent.add(data.toString());
    final frame = jsonDecode(data.toString());
    if (frame is List && channel != null) {
      // Reply asynchronously, like a real socket.
      scheduleMicrotask(() => _onSend(channel!, frame));
    }
  }

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Builds a fake channel whose sink replies via [onSend], wiring the back-ref.
_FakeApiChannel _makeChannel(
    void Function(_FakeApiChannel ch, List<dynamic> frame) onSend) {
  final ch = _FakeApiChannel(onSend);
  ch._sink.channel = ch;
  return ch;
}

void main() {
  group('ApiClient WS-first storage transport', () {
    test('public read rides the socket (HTTP never called); parses ITEM/END',
        () async {
      var httpCalls = 0;
      final client = MockClient((req) async {
        httpCalls++;
        return http.Response('', 200);
      });
      late _FakeApiChannel channel;
      final api = ApiClient(client: client);
      api.activateApiSocket(factory: (url) {
        channel = _makeChannel((ch, frame) {
          // profile-get is a public read → no AUTH; just a REQ.
          if (frame[0] == 'REQ') {
            final id = frame[1];
            ch.inject(['ITEM', id, ['pk', {'event': {'id': 'e1'}}]]);
            ch.inject(['END', id, {'x-has-more': '0'}]);
          }
        });
        return channel;
      });

      final stream = await api.storageStream({
        'action': 'profile-get',
        'pubkeys': ['a' * 64],
      });
      expect(httpCalls, 0, reason: 'socket served the read, HTTP not used');
      expect(stream.items.length, 1);
      expect((stream.items.first as List)[0], 'pk');
      // The framed REQ carried the action + extra (no auth/pubkey on a public read).
      final reqFrame = jsonDecode(channel.sent.last) as List;
      expect(reqFrame[0], 'REQ');
      expect(reqFrame[2], 'profile-get');
      expect((reqFrame[3] as Map).containsKey('pubkeys'), isTrue);
    });

    test('authed action does AUTH handshake; strips pubkey/auth from REQ extra',
        () async {
      final client = MockClient((req) async => http.Response('', 200));
      final api = ApiClient(client: client);
      api.setApiSocketAuthBuilder(() async => {
            'kind': 27235,
            'id': 'auth-id',
            'pubkey': 'a' * 64,
            'sig': 's',
            'created_at': 1,
            'tags': const [],
            'content': 'nymbot-pm-auth',
          });
      late _FakeApiChannel channel;
      api.activateApiSocket(factory: (url) {
        channel = _makeChannel((ch, frame) {
          if (frame[0] == 'AUTH') {
            ch.inject(['AUTH_OK']);
          } else if (frame[0] == 'REQ') {
            ch.inject(['RES', frame[1], 200, {'owned': {}, 'active': {}}]);
          }
        });
        return channel;
      });

      final data = await api.storageAction({
        'action': 'shop-get',
        'pubkey': 'a' * 64,
        'auth': {'kind': 27235},
      });
      expect(data['owned'], isA<Map>());
      // First frame is AUTH, last is the REQ with pubkey/auth stripped.
      final frames = channel.sent.map((s) => jsonDecode(s) as List).toList();
      expect(frames.first[0], 'AUTH');
      final req = frames.firstWhere((f) => f[0] == 'REQ');
      final extra = req[3] as Map;
      expect(extra.containsKey('auth'), isFalse, reason: 'socket is authed once');
      expect(extra.containsKey('pubkey'), isFalse);
      expect(extra.containsKey('action'), isFalse);
    });

    test('socket connect failure falls back to HTTP', () async {
      var httpCalls = 0;
      final client = MockClient((req) async {
        httpCalls++;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['action'], 'profile-get');
        return http.Response('${jsonEncode(['pk', null])}\n', 200,
            headers: {'Content-Type': 'application/x-ndjson'});
      });
      final api = ApiClient(client: client);
      // A factory that throws → ensureConnected fails → HTTP fallback.
      api.activateApiSocket(factory: (url) => throw StateError('no socket'));

      final stream = await api.storageStream({
        'action': 'profile-get',
        'pubkeys': ['a' * 64],
      });
      expect(httpCalls, 1, reason: 'fell back to HTTP after socket failure');
      expect(stream.items.length, 1);
    });

    test('a RES error frame falls back to HTTP (PWA reject→retry), not throw',
        () async {
      // SAFETY: a socket error frame is a fallback trigger. The PWA's non-raw
      // `_apiSocketSend` rejects on `status>=400 || data.error`, and the caller
      // retries over HTTP — HTTP's response is authoritative. So a socket 402
      // must NOT surface directly; HTTP must get a turn. Here HTTP succeeds, so
      // the caller sees the HTTP result (the socket error is swallowed).
      var httpCalls = 0;
      final client = MockClient((req) async {
        httpCalls++;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['action'], 'channel-active');
        return http.Response(jsonEncode({'activity': {}, 'last': {}}), 200);
      });
      final api = ApiClient(client: client);
      api.setApiSocketAuthBuilder(() async => {'kind': 27235, 'id': 'x'});
      api.activateApiSocket(factory: (url) {
        return _makeChannel((ch, frame) {
          // Public read → no AUTH; reply with a server error frame.
          if (frame[0] == 'REQ') {
            ch.inject(['RES', frame[1], 500, {'error': 'Internal server error'}]);
          }
        });
      });

      final data = await api.storageAction({'action': 'channel-active'});
      expect(httpCalls, 1, reason: 'socket error frame fell back to HTTP');
      expect(data['activity'], isA<Map>());
    });

    test('socket error frame + HTTP error → ApiException from HTTP', () async {
      // When BOTH transports fail, the caller still sees a thrown ApiException
      // (the HTTP error), so mutating callers can surface the server message.
      final client = MockClient((req) async =>
          http.Response(jsonEncode({'error': 'Payment not confirmed yet.'}), 402));
      final api = ApiClient(client: client);
      api.setApiSocketAuthBuilder(() async => {'kind': 27235, 'id': 'x'});
      api.activateApiSocket(factory: (url) {
        return _makeChannel((ch, frame) {
          if (frame[0] == 'AUTH') {
            ch.inject(['AUTH_OK']);
          } else if (frame[0] == 'REQ') {
            ch.inject(['RES', frame[1], 402, {'error': 'Payment not confirmed yet.'}]);
          }
        });
      });

      expect(
        () => api.storageAction({
          'action': 'shop-claim',
          'pubkey': 'a' * 64,
          'auth': {'kind': 27235},
        }),
        throwsA(isA<ApiException>()),
      );
    });

    test('socket disabled by default → HTTP path is used', () async {
      var httpCalls = 0;
      final client = MockClient((req) async {
        httpCalls++;
        return http.Response('${jsonEncode(['pk', null])}\n', 200,
            headers: {'Content-Type': 'application/x-ndjson'});
      });
      // No activateApiSocket → HTTP only (the unit-test / shop-controller default).
      final api = ApiClient(client: client);
      await api.storageStream({
        'action': 'profile-get',
        'pubkeys': ['a' * 64],
      });
      expect(httpCalls, 1);
    });

    test('WS frames are tallied into the network stats per action', () async {
      // Parity with the PWA's `_trackApiData`: every sent/received frame's JSON
      // length is folded into the stats sink, attributed to its action (AUTH
      // send + AUTH_OK recv → 'auth'; REQ send + RES recv → the action).
      final sink = RelayStats();
      ApiClient.apiStatsSink = sink;
      addTearDown(() => ApiClient.apiStatsSink = null);
      final client = MockClient((req) async => http.Response('', 200));
      final api = ApiClient(client: client);
      api.setApiSocketAuthBuilder(() async => {
            'kind': 27235,
            'id': 'auth-id',
            'pubkey': 'a' * 64,
            'sig': 's',
            'created_at': 1,
            'tags': const [],
            'content': 'nymbot-pm-auth',
          });
      api.activateApiSocket(factory: (url) {
        return _makeChannel((ch, frame) {
          if (frame[0] == 'AUTH') {
            ch.inject(['AUTH_OK']);
          } else if (frame[0] == 'REQ') {
            ch.inject(['RES', frame[1], 200, {'owned': {}, 'active': {}}]);
          }
        });
      });

      await api.storageAction({
        'action': 'shop-get',
        'pubkey': 'a' * 64,
        'auth': {'kind': 27235},
      });

      // AUTH frame sent + AUTH_OK received → 'auth'.
      final auth = sink.apiActionStats['auth'];
      expect(auth, isNotNull);
      expect(auth!.bytesSent, greaterThan(0), reason: 'AUTH frame sent');
      expect(auth.bytesReceived, greaterThan(0), reason: 'AUTH_OK received');
      // REQ sent + RES received → the action.
      final action = sink.apiActionStats['shop-get'];
      expect(action, isNotNull);
      expect(action!.bytesSent, greaterThan(0), reason: 'REQ frame sent');
      expect(action.bytesReceived, greaterThan(0), reason: 'RES received');
      // Folded into the global byte totals too.
      expect(sink.bytesSent, greaterThan(0));
      expect(sink.bytesReceived, greaterThan(0));
    });
  });

  group('Nip98Auth.buildSigned (remote-signer-capable auth)', () {
    test('signs kind-27235 auth via a NIP-46 remote signer with action/url tags',
        () async {
      Nip98Auth.clearAuthCache();
      addTearDown(Nip98Auth.clearAuthCache);
      final signer = _FakeRemoteSigner('b' * 64);
      final auth = await Nip98Auth.buildSigned(
        action: 'settings-get',
        url: 'https://h/api/storage',
        signer: signer,
      );
      expect(auth, isNotNull);
      expect(auth!['kind'], 27235);
      expect(auth['pubkey'], 'b' * 64);
      expect(auth['sig'], isNotNull);
      final tags = (auth['tags'] as List).cast<dynamic>();
      bool hasTag(String k, String v) =>
          tags.any((t) => t is List && t.length >= 2 && t[0] == k && t[1] == v);
      expect(hasTag('u', 'https://h/api/storage'), isTrue);
      expect(hasTag('action', 'settings-get'), isTrue);
      expect(signer.signCount, 1, reason: 'remote signer was invoked');
    });

    test('caches non-sensitive auth for 90s (no second remote round-trip)',
        () async {
      Nip98Auth.clearAuthCache();
      addTearDown(Nip98Auth.clearAuthCache);
      final signer = _FakeRemoteSigner('c' * 64);
      final a1 = await Nip98Auth.buildSigned(
          action: 'settings-get', url: 'https://h/api/storage', signer: signer);
      final a2 = await Nip98Auth.buildSigned(
          action: 'settings-get', url: 'https://h/api/storage', signer: signer);
      expect(signer.signCount, 1, reason: 'second call served from cache');
      expect(identical(a1, a2), isTrue);
      // A different action is signed fresh (distinct cache key).
      await Nip98Auth.buildSigned(
          action: 'pm-get', url: 'https://h/api/storage', signer: signer);
      expect(signer.signCount, 2);
    });
  });
}

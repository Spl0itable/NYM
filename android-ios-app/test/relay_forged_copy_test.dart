import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/relays.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/relay/relay_message.dart';
import 'package:nym_bar/services/relay/relay_pool.dart';
import 'package:nym_bar/services/relay/relay_pool_proxy.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<bool> _verify(NostrEvent e) async => schnorr.verifyEvent(e);

NostrEvent _signed() {
  final sk = generatePrivateKey();
  return schnorr.finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(sk),
      createdAt: 1700000000,
      kind: 20000,
      tags: const [
        ['g', 'u4pru']
      ],
      content: 'hello',
    ),
    sk,
  );
}

NostrEvent _copy(NostrEvent e, {String? sig, String? content}) => NostrEvent(
      id: e.id,
      pubkey: e.pubkey,
      createdAt: e.createdAt,
      kind: e.kind,
      tags: e.tags,
      content: content ?? e.content,
      sig: sig ?? e.sig,
    );

String _badSig(String sig) =>
    '${sig.substring(0, 127)}${sig.endsWith('0') ? '1' : '0'}';

void main() {
  group('a forged copy cannot claim an event id', () {
    late RelayPool pool;
    late Subscription sub;
    late List<NostrEvent> got;

    setUp(() {
      pool = RelayPool(relays: const []);
      sub = Subscription.forTransport('s', pool, _verify, 1,
          eoseQuorum: 1, eoseTimeout: const Duration(seconds: 1));
      got = [];
      sub.events.listen(got.add);
    });

    tearDown(() => sub.close());

    test('a bad signature first does not hide the real event', () async {
      final real = _signed();
      await sub.onEvent('wss://evil', _copy(real, sig: _badSig(real.sig)));
      await sub.onEvent('wss://good', real);
      await Future<void>.delayed(Duration.zero);
      expect(got.map((e) => e.sig), [real.sig]);
    });

    test('tampered content under the real id and signature is dropped',
        () async {
      final real = _signed();
      await sub.onEvent('wss://evil', _copy(real, content: 'forged'));
      await sub.onEvent('wss://good', real);
      await Future<void>.delayed(Duration.zero);
      expect(got, hasLength(1));
      expect(got.single.content, 'hello');
    });

    test('the real event is still delivered only once', () async {
      final real = _signed();
      await sub.onEvent('wss://a', real);
      await sub.onEvent('wss://b', real);
      await Future<void>.delayed(Duration.zero);
      expect(got, hasLength(1));
    });
  });

  test('the proxy does not let a forged copy claim the id across shards',
      () async {
    final fakes = <_FakeChannel>[];
    final proxy = RelayPoolProxy(
      relays: RelayConfig.defaultRelays,
      dmRelays: RelayConfig.defaultRelays,
      poolUrl: 'wss://h/api/relay-pool',
      verify: _verify,
      channelFactory: (uri) {
        final f = _FakeChannel();
        fakes.add(f);
        return f;
      },
    );
    proxy.connectAll();
    final sub = proxy.subscribe([
      NostrFilter(kinds: [20000])
    ]);
    final got = <NostrEvent>[];
    sub.events.listen(got.add);

    final real = _signed();
    String frame(NostrEvent e) =>
        jsonEncode(['EVENT', sub.subId, e.toJson(), 'wss://x.relay']);
    fakes.first.inject(frame(_copy(real, sig: _badSig(real.sig))));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    fakes.last.inject(frame(real));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(got.map((e) => e.sig), [real.sig]);
    await proxy.disconnectAll();
  });
}

class _FakeChannel implements WebSocketChannel {
  final StreamController<dynamic> _inbound = StreamController<dynamic>();
  late final _FakeSink _sink = _FakeSink(_inbound);

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
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._inbound);
  final StreamController<dynamic> _inbound;

  @override
  void add(dynamic data) {}
  @override
  Future<dynamic> close([int? code, String? reason]) async {
    if (!_inbound.isClosed) await _inbound.close();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<dynamic> addStream(Stream<dynamic> stream) async {}
  @override
  Future<dynamic> get done => Future<dynamic>.value();
}

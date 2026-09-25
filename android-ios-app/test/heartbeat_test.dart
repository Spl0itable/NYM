import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/services/platform/heartbeat.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';

const _codec = StandardMethodCodec();
const _channel = MethodChannel(HeartbeatService.channelName);

Future<void> _fromNative(String method, [Object? args]) {
  final done = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    HeartbeatService.channelName,
    _codec.encodeMethodCall(MethodCall(method, args)),
    (_) => done.complete(),
  );
  return done.future;
}

class _Rig {
  _Rig(this.kv, this.responses);

  final KeyValueStore kv;
  final List<http.Response Function(http.Request)> responses;
  final requests = <http.Request>[];
  final native = <String>[];
  final sleeps = <Duration>[];
  late final HeartbeatService service;

  void build({Duration relaunchBase = const Duration(milliseconds: 20)}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      native.add(call.method);
      return null;
    });
    var i = 0;
    service = HeartbeatService(
      kv: kv,
      supported: true,
      env: 'sandbox',
      client: MockClient((request) async {
        requests.add(request);
        final respond = responses[i < responses.length ? i : responses.length - 1];
        i++;
        return respond(request);
      }),
      sleep: (d) async => sleeps.add(d),
      relaunchBase: relaunchBase,
      maxRelaunchDelay: const Duration(milliseconds: 200),
      maxAttempts: 3,
    );
  }
}

http.Response Function(http.Request) _status(int code, [Map<String, String>? headers]) =>
    (_) => http.Response('', code, headers: headers ?? const {});

Future<KeyValueStore> _kv() async {
  SharedPreferences.setMockInitialValues({});
  return KeyValueStore(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('turning it on asks iOS for a token and registers only the token and env', () async {
    final rig = _Rig(await _kv(), [_status(204)])..build();
    await rig.service.setEnabled(true);
    expect(rig.native, ['register']);
    await _fromNative('token', 'ABCDEF0123');
    await rig.service.idle;
    expect(rig.requests, hasLength(1));
    final r = rig.requests.single;
    expect(r.url.toString(), 'https://web.nymchat.app/push/register');
    expect(jsonDecode(r.body), {'token': 'abcdef0123', 'env': 'sandbox'});
    expect(r.headers['user-agent'] ?? '', isNot(contains('Nymchat')));
    expect(r.headers.keys.map((k) => k.toLowerCase()), isNot(contains('cookie')));
    expect(rig.service.registered, isTrue);
    expect(rig.kv.getString(StorageKeys.heartbeatToken), 'abcdef0123');
  });

  test('a failed iOS registration keeps trying until a token arrives', () async {
    final rig = _Rig(await _kv(), [_status(204)])..build();
    await rig.service.setEnabled(true);
    await _fromNative('registrationFailed', 'no network');
    expect(rig.service.retryPending, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(rig.native.where((m) => m == 'register').length, 2);
    await _fromNative('registrationFailed', 'still no network');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(rig.native.where((m) => m == 'register').length, 3);
    await _fromNative('token', 'aa11');
    await rig.service.idle;
    expect(rig.service.registered, isTrue);
    expect(rig.service.retryPending, isFalse);
  });

  test('a server that keeps failing is retried later, then on resume', () async {
    final rig = _Rig(await _kv(), [_status(503)])..build(relaunchBase: const Duration(seconds: 30));
    await rig.service.setEnabled(true);
    await _fromNative('token', 'bb22');
    await rig.service.idle;
    expect(rig.requests, hasLength(3));
    expect(rig.service.registered, isFalse);
    expect(rig.service.retryPending, isTrue);
    await rig.service.resume();
    expect(rig.native.where((m) => m == 'register').length, 2);
  });

  test('429 waits as long as the server asks', () async {
    final rig = _Rig(await _kv(), [_status(429, {'retry-after': '7'}), _status(204)])..build();
    await rig.service.setEnabled(true);
    await _fromNative('token', 'cc33');
    await rig.service.idle;
    expect(rig.sleeps.first, const Duration(seconds: 7));
    expect(rig.service.registered, isTrue);
  });

  test('network errors never escape', () async {
    final rig = _Rig(await _kv(), [(_) => throw const SocketLikeError()])..build(relaunchBase: const Duration(seconds: 30));
    await rig.service.setEnabled(true);
    await _fromNative('token', 'dd44');
    await rig.service.idle;
    expect(rig.service.registered, isFalse);
  });

  test('a new token replaces the old one on the server', () async {
    final rig = _Rig(await _kv(), [_status(204)])..build();
    await rig.service.setEnabled(true);
    await _fromNative('token', 'ee55');
    await rig.service.idle;
    await _fromNative('token', 'ff66');
    await rig.service.idle;
    final paths = rig.requests.map((r) => r.url.path).toList();
    expect(paths, ['/push/register', '/push/unregister', '/push/register']);
    expect(jsonDecode(rig.requests[1].body), {'token': 'ee55'});
  });

  test('turning it off unregisters and stops retrying', () async {
    final rig = _Rig(await _kv(), [_status(204)])..build();
    await rig.service.setEnabled(true);
    await _fromNative('token', 'aa77');
    await rig.service.idle;
    await rig.service.setEnabled(false);
    expect(rig.requests.last.url.path, '/push/unregister');
    expect(jsonDecode(rig.requests.last.body), {'token': 'aa77'});
    expect(rig.native.last, 'unregister');
    expect(rig.kv.getString(StorageKeys.heartbeatToken), isNull);
    await _fromNative('registrationFailed', 'x');
    expect(rig.service.retryPending, isFalse);
  });

  test('without the native side nothing throws', () async {
    final service = HeartbeatService(kv: await _kv(), supported: true, env: 'sandbox');
    await service.setEnabled(true);
    await service.resume();
    await service.setEnabled(false);
    service.dispose();
  });

  test('where unsupported it does nothing at all', () async {
    final rig = _Rig(await _kv(), [_status(204)]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      rig.native.add(call.method);
      return null;
    });
    final service = HeartbeatService(kv: rig.kv, supported: false);
    await service.setEnabled(true);
    await service.resume();
    expect(rig.native, isEmpty);
  });

  test('Retry-After is read as seconds or a date', () {
    expect(HeartbeatService.retryAfter('12'), const Duration(seconds: 12));
    final now = DateTime.utc(2026, 9, 24, 12);
    expect(HeartbeatService.retryAfter('Thu, 24 Sep 2026 12:00:30 GMT', now: now),
        const Duration(seconds: 30));
    expect(HeartbeatService.retryAfter('soon'), isNull);
  });
}

class SocketLikeError implements Exception {
  const SocketLikeError();
}

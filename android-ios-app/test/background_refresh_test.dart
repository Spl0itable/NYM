import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/features/notifications/background_catch_up.dart';
import 'package:nym_bar/services/platform/background_refresh.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';

const _codec = StandardMethodCodec();
const _channelName = BackgroundRefreshService.channelName;

Future<Object?> _runRefreshFromNative() {
  final reply = Completer<Object?>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    _channelName,
    _codec.encodeMethodCall(const MethodCall('runRefresh')),
    (data) {
      try {
        reply.complete(_codec.decodeEnvelope(data!));
      } catch (e) {
        reply.completeError(e);
      }
    },
  );
  return reply.future;
}

Future<KeyValueStore> _kv(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return KeyValueStore(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
    ServicesBinding.instance.defaultBinaryMessenger
        .setMessageHandler(_channelName, null);
  });

  test('a window that fires before Dart is listening runs once it listens',
      () async {
    final reply = Completer<Object?>();
    ui.channelBuffers.push(
      _channelName,
      _codec.encodeMethodCall(const MethodCall('runRefresh')),
      (data) => reply.complete(_codec.decodeEnvelope(data!)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(reply.isCompleted, isFalse);

    var runs = 0;
    BackgroundRefreshService(supported: true).start(() async {
      runs++;
      return true;
    });

    expect(await reply.future.timeout(const Duration(seconds: 5)), isTrue);
    expect(runs, 1);
  });

  test('a catch-up that fails still ends the window', () async {
    BackgroundRefreshService(supported: true)
        .start(() async => throw StateError('relay down'));
    await expectLater(_runRefreshFromNative(), throwsA(isA<PlatformException>()));
  });

  test('a catch-up that hangs still ends the window within its budget',
      () async {
    final hang = Completer<bool>();
    BackgroundRefreshService(supported: true).start(
      () => hang.future,
      budget: const Duration(milliseconds: 50),
    );
    await expectLater(
      _runRefreshFromNative().timeout(const Duration(seconds: 5)),
      throwsA(isA<PlatformException>()),
    );
    expect(hang.isCompleted, isFalse);
  });

  test('the Dart budget ends before the native one', () {
    expect(BackgroundRefreshService.runBudget,
        lessThan(const Duration(seconds: 25)));
  });

  test('schedule and cancel reach the native side only where supported',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName),
            (call) async {
      calls.add(call);
      return null;
    });

    await BackgroundRefreshService(supported: false).schedule();
    expect(calls, isEmpty);

    final service = BackgroundRefreshService(supported: true);
    await service.schedule();
    await service.cancel();
    expect(calls.map((c) => c.method), ['schedule', 'cancel']);
    expect(calls.first.arguments, {'earliestSeconds': 15 * 60});
  });

  group('hasChosenIdentity', () {
    test('a device still at first-run setup has none', () async {
      expect(hasChosenIdentity(await _kv({})), isFalse);
    });

    test('a saved login counts', () async {
      expect(
        hasChosenIdentity(await _kv({StorageKeys.nostrLoginMethod: 'nsec'})),
        isTrue,
      );
    });

    test('an ephemeral identity the user chose counts', () async {
      expect(
        hasChosenIdentity(await _kv({StorageKeys.autoEphemeral: 'true'})),
        isTrue,
      );
    });
  });
}

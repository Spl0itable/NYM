import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const String kNfcChannel = 'app.nymchat/nfc';
const Duration kTapToShareDuration = Duration(seconds: 60);
const Duration kNfcSessionTimeout = Duration(seconds: 30);

class NfcCaps {
  const NfcCaps({
    this.nfc = false,
    this.enabled = false,
    this.hce = false,
    this.read = false,
    this.write = false,
    this.systemUi = false,
  });

  factory NfcCaps.fromMap(Object? raw) {
    if (raw is! Map) return none;
    bool b(String k) => raw[k] == true;
    return NfcCaps(
      nfc: b('nfc'),
      enabled: b('enabled'),
      hce: b('hce'),
      read: b('read'),
      write: b('write'),
      systemUi: b('systemUi'),
    );
  }

  static const NfcCaps none = NfcCaps();

  final bool nfc;
  final bool enabled;
  final bool hce;
  final bool read;
  final bool write;
  final bool systemUi;
}

enum NfcWriteStatus { ok, tooSmall, readOnly, notNdef, mismatch, failed, cancelled }

class NfcWriteResult {
  const NfcWriteResult(this.status, {this.need = 0, this.have = 0});

  factory NfcWriteResult.fromMap(Object? raw) {
    if (raw is! Map) return cancelled;
    final status = NfcWriteStatus.values
        .where((s) => s.name == raw['status'])
        .firstOrNull;
    if (status == null) return const NfcWriteResult(NfcWriteStatus.failed);
    final need = raw['need'];
    final have = raw['have'];
    return NfcWriteResult(status,
        need: need is int ? need : 0, have: have is int ? have : 0);
  }

  static const NfcWriteResult cancelled =
      NfcWriteResult(NfcWriteStatus.cancelled);

  final NfcWriteStatus status;
  final int need;
  final int have;
}

abstract class NfcPlatform {
  Future<NfcCaps> caps();
  Future<bool> arm(Uint8List cc, Uint8List file, Duration ttl);
  Future<void> disarm();
  Future<void> openSettings();
  Future<Object?> read({required String alert, required Duration timeout});
  Future<NfcWriteResult> write(
      {required Uint8List message,
      required Uint8List payload,
      required String uri,
      required String alert,
      required String done,
      required Duration timeout});
  Future<NfcWriteResult> lock(
      {required Uint8List message,
      required Uint8List payload,
      required String alert,
      required String done,
      required Duration timeout});
  Future<void> cancel();
}

class MethodChannelNfcPlatform implements NfcPlatform {
  MethodChannelNfcPlatform([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(kNfcChannel);
  final MethodChannel _channel;

  Future<Object?> _call(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<NfcCaps> caps() async => NfcCaps.fromMap(await _call('caps'));

  @override
  Future<bool> arm(Uint8List cc, Uint8List file, Duration ttl) async =>
      await _call('arm', {'cc': cc, 'file': file, 'ttlMs': ttl.inMilliseconds}) ==
      true;

  @override
  Future<void> disarm() => _call('disarm');

  @override
  Future<void> openSettings() => _call('openSettings');

  @override
  Future<Object?> read({required String alert, required Duration timeout}) =>
      _call('read', {'alert': alert, 'timeoutMs': timeout.inMilliseconds});

  @override
  Future<NfcWriteResult> write(
          {required Uint8List message,
          required Uint8List payload,
          required String uri,
          required String alert,
          required String done,
          required Duration timeout}) async =>
      NfcWriteResult.fromMap(await _call('write', {
        'message': message,
        'payload': payload,
        'uri': uri,
        'size': message.length,
        'alert': alert,
        'done': done,
        'timeoutMs': timeout.inMilliseconds,
      }));

  @override
  Future<NfcWriteResult> lock(
          {required Uint8List message,
          required Uint8List payload,
          required String alert,
          required String done,
          required Duration timeout}) async =>
      NfcWriteResult.fromMap(await _call('lock', {
        'message': message,
        'payload': payload,
        'alert': alert,
        'done': done,
        'timeoutMs': timeout.inMilliseconds,
      }));

  @override
  Future<void> cancel() => _call('cancel');
}

bool get nfcPlatformSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

final nfcPlatformSupportedProvider =
    Provider<bool>((ref) => nfcPlatformSupported);

final nfcPlatformProvider =
    Provider<NfcPlatform>((ref) => MethodChannelNfcPlatform());

final nfcCapsProvider = FutureProvider<NfcCaps>((ref) async {
  if (!ref.watch(nfcPlatformSupportedProvider)) return NfcCaps.none;
  return ref.watch(nfcPlatformProvider).caps();
});

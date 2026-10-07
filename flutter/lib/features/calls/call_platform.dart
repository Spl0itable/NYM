import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

final callPlatformProvider = Provider<CallPlatform>((ref) => CallPlatform());

final RegExp _headsetPattern = RegExp(
    r'bluetooth|headset|headphone|wired|usb|carAudio|airpods',
    caseSensitive: false);

bool isHeadsetAudioDevice(String deviceId, String group) =>
    _headsetPattern.hasMatch(deviceId) || _headsetPattern.hasMatch(group);

class CallPlatform {
  CallPlatform({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName) {
    if (_isMobile) {
      try {
        _channel.setMethodCallHandler(_onNative);
      } catch (_) {}
    }
  }

  static const String channelName = 'app.nymchat/call';

  final MethodChannel _channel;

  @visibleForTesting
  static bool? debugAndroidOverride;

  void Function()? onHangupRequest;
  void Function(String callId)? onAnswer;
  void Function(String callId)? onDecline;
  void Function(bool muted)? onMute;
  Future<Map<String, dynamic>?> Function()? onRingCheck;
  Future<void> Function(String platform, String token, String env)? onRingToken;

  static bool get _isMobile {
    final o = debugAndroidOverride;
    if (o != null) return o;
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  bool get canRouteAudio => _isMobile;

  Future<void> setSpeaker(bool on) async {
    if (!_isMobile) return;
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (e) {
      debugPrint('[CallPlatform] setSpeaker failed: $e');
    }
  }

  Future<bool> headsetConnected() async {
    if (!_isMobile) return false;
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      return devices.any((d) =>
          (d.kind == 'audiooutput' || d.kind == 'audioinput') &&
          isHeadsetAudioDevice(d.deviceId, d.groupId ?? ''));
    } catch (_) {
      return false;
    }
  }

  void watchAudioDevices(void Function()? onChange) {
    if (!_isMobile) return;
    try {
      navigator.mediaDevices.ondevicechange =
          onChange == null ? null : (_) => onChange();
    } catch (_) {}
  }

  bool _ongoing = false;
  bool _ongoingVideo = false;

  bool get ongoing => _ongoing;
  bool get ongoingVideo => _ongoingVideo;

  Future<dynamic> _onNative(MethodCall call) async {
    final args = call.arguments;
    final map = args is Map ? Map<String, dynamic>.from(args) : const <String, dynamic>{};
    switch (call.method) {
      case 'hangup':
        onHangupRequest?.call();
      case 'answer':
        final id = map['callId'];
        if (id is String) onAnswer?.call(id);
      case 'decline':
        final id = map['callId'];
        if (id is String) onDecline?.call(id);
      case 'mute':
        onMute?.call(map['muted'] == true);
      case 'ringCheck':
        final check = onRingCheck;
        return check == null ? null : await check();
      case 'ringToken':
        final platform = map['platform'];
        final token = map['token'];
        final env = map['env'];
        if (platform is String && token is String) {
          await onRingToken?.call(platform, token, env is String ? env : 'production');
        }
    }
    return null;
  }

  Future<void> showIncoming({
    required String callId,
    required String name,
    required bool video,
    required bool group,
    String body = '',
  }) async {
    if (!_isMobile) return;
    try {
      await _channel.invokeMethod<void>('showIncoming', {
        'callId': callId,
        'name': name,
        'body': body,
        'video': video,
        'group': group,
      });
    } catch (e) {
      debugPrint('[CallPlatform] showIncoming failed: $e');
    }
  }

  Future<void> endIncoming(String callId, {required bool answered}) async {
    if (!_isMobile) return;
    try {
      await _channel.invokeMethod<void>(
          'endIncoming', {'callId': callId, 'answered': answered});
    } catch (e) {
      debugPrint('[CallPlatform] endIncoming failed: $e');
    }
  }

  Future<bool> ringSupported() async {
    if (!_isMobile) return false;
    try {
      return await _channel.invokeMethod<bool>('ringSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> ringEnable([Map<String, String>? strings]) async {
    if (!_isMobile) return;
    try {
      await _channel.invokeMethod<void>('ringEnable', strings);
    } catch (e) {
      debugPrint('[CallPlatform] ringEnable failed: $e');
    }
  }

  Future<void> ringDisable() async {
    if (!_isMobile) return;
    try {
      await _channel.invokeMethod<void>('ringDisable');
    } catch (e) {
      debugPrint('[CallPlatform] ringDisable failed: $e');
    }
  }

  Future<void> startOngoing({
    required bool video,
    required String title,
    required String text,
    required String hangup,
  }) async {
    if (_ongoing && _ongoingVideo == video) return;
    _ongoing = true;
    _ongoingVideo = video;
    if (!_isMobile) return;
    try {
      await _channel.invokeMethod<bool>('startOngoing', {
        'video': video,
        'title': title,
        'text': text,
        'hangup': hangup,
      });
    } catch (e) {
      debugPrint('[CallPlatform] startOngoing failed: $e');
    }
  }

  Future<void> stopOngoing() async {
    if (!_ongoing) return;
    _ongoing = false;
    _ongoingVideo = false;
    if (!_isMobile) return;
    try {
      await _channel.invokeMethod<void>('stopOngoing');
    } catch (e) {
      debugPrint('[CallPlatform] stopOngoing failed: $e');
    }
  }
}

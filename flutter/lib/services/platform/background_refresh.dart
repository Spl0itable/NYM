import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS `BGAppRefresh` catch-up for a suspended app; no-op where the native half is missing.
class BackgroundRefreshService {
  BackgroundRefreshService({MethodChannel? channel, bool? supported})
      : _channel = channel ?? const MethodChannel(channelName),
        _supported = supported ?? isSupported;

  /// Shared with `AppDelegate.swift`.
  static const String channelName = 'app.nymchat/background_refresh';

  final MethodChannel _channel;
  final bool _supported;

  static const Duration runBudget = Duration(seconds: 23);

  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  bool _started = false;

  /// Registers [onRefresh], which must finish promptly: iOS kills overrunning tasks. Idempotent.
  void start(
    Future<bool> Function() onRefresh, {
    Duration budget = runBudget,
  }) {
    if (!_supported || _started) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'runRefresh') return null;
      try {
        return await onRefresh().timeout(budget);
      } catch (e) {
        debugPrint('[BackgroundRefresh] catch-up failed: ${e.runtimeType}');
        throw PlatformException(code: 'failed');
      }
    });
  }

  /// Requests another window; [earliest] is a lower bound, and each request is consumed by firing.
  Future<void> schedule({
    Duration earliest = const Duration(minutes: 15),
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('schedule', {
        'earliestSeconds': earliest.inSeconds,
      });
    } on MissingPluginException {
      // No native half in this build.
    } catch (e) {
      debugPrint('[BackgroundRefresh] schedule failed: $e');
    }
  }

  /// Drops any pending request, e.g. when notifications are turned off.
  Future<void> cancel() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // No native half in this build.
    } catch (e) {
      debugPrint('[BackgroundRefresh] cancel failed: $e');
    }
  }
}

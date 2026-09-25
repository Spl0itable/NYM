import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The iOS `BGAppRefresh` catch-up: the only way an app with no push provider
/// can notice, while suspended, that something arrived.
///
/// iOS suspends a backgrounded app within seconds and will not wake it for
/// network data — that is what APNs exists for, and Nymchat uses APNs only for
/// a content-free heartbeat sent to every device alike, because a push per
/// message would tell the provider who is messaging whom. `BGTaskScheduler` is the alternative the system does offer: it grants
/// the app a short run at a time of ITS choosing, typically minutes to hours
/// after the fact and influenced by how often the user opens the app. That is
/// not real-time and cannot be made so; it turns "nothing until you next open
/// the app" into "a notification some minutes later".
///
/// Android has no counterpart here and needs none: the foreground service from
/// "Stay Connected in Background" keeps the socket open, so events arrive live.
///
/// The native half registers the task and calls back into [onRefresh]; this
/// side does the catch-up and returns, which is what tells iOS the window is
/// finished. Every call self-guards, so a platform without the native half
/// (Android, tests, desktop) simply does nothing.
class BackgroundRefreshService {
  BackgroundRefreshService({MethodChannel? channel, bool? supported})
      : _channel = channel ?? const MethodChannel(channelName),
        _supported = supported ?? isSupported;

  /// Shared with `AppDelegate.swift`.
  static const String channelName = 'app.nymchat/background_refresh';

  final MethodChannel _channel;
  final bool _supported;

  static const Duration runBudget = Duration(seconds: 23);

  /// Only iOS schedules background refreshes.
  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  bool _started = false;

  /// Registers [onRefresh] as the work a granted window runs. Idempotent.
  ///
  /// The returned future of [onRefresh] is what the native side waits on before
  /// reporting the task complete, so it must finish promptly — iOS kills the
  /// app if a task overruns its budget, and repeatedly overrunning teaches the
  /// scheduler to grant fewer windows.
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

  /// Asks iOS to grant another window. iOS decides if and when — [earliest] is
  /// the soonest it may fire, not a promise that it will.
  ///
  /// Called when the app goes to the background (the next window is the one
  /// that matters) and again after each window runs, since a task request is
  /// consumed by firing.
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

  /// Drops any pending request — used when notifications are turned off, so the
  /// app stops asking for windows it has no use for.
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

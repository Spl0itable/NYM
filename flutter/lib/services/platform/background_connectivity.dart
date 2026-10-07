import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final backgroundConnectivityServiceProvider =
    Provider<BackgroundConnectivityService>(
        (ref) => BackgroundConnectivityService());

/// Background keep-alive: an Android foreground service or an iOS background task; best-effort, never throws.
class BackgroundConnectivityService {
  BackgroundConnectivityService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Method-channel name shared with `MainActivity.kt` / `AppDelegate.swift`.
  static const String channelName = 'app.nymchat/background_connectivity';

  final MethodChannel _channel;

  /// Whether this platform can honor the setting; the UI hides it otherwise.
  @visibleForTesting
  static bool? debugSupportedOverride;

  static bool get isSupported {
    final override = debugSupportedOverride;
    if (override != null) return override;
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  bool _running = false;

  bool get isRunning => _running;

  /// Starts the keep-alive; [mesh] adds Android's `connectedDevice` service type. Returns whether it runs.
  Future<bool> start({bool mesh = false}) async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('start', {'mesh': mesh});
      _running = ok ?? false;
    } on MissingPluginException {
      _running = false;
    } on PlatformException catch (e) {
      debugPrint('[BackgroundConnectivity] start failed: ${e.message}');
      _running = false;
    } catch (e) {
      debugPrint('[BackgroundConnectivity] start failed: $e');
      _running = false;
    }
    return _running;
  }

  /// Stops the keep-alive; safe when never started.
  Future<void> stop() async {
    _running = false;
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No native half in this build.
    } on PlatformException catch (e) {
      debugPrint('[BackgroundConnectivity] stop failed: ${e.message}');
    } catch (e) {
      debugPrint('[BackgroundConnectivity] stop failed: $e');
    }
  }
}

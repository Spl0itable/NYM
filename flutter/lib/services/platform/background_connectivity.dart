import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Asks the OS to keep the app's network + Bluetooth work running while it is
/// backgrounded ("Stay Connected in Background", `nym_background_connectivity`).
///
/// Without it, leaving the app tears everything down: Android freezes the
/// process once it has no visible component (and Doze finishes off whatever
/// survives), and iOS suspends it within seconds, so every relay socket and
/// every mesh link dies and has to be rebuilt on the next resume.
///
/// What "keep running" can mean is platform-dictated:
///
///  * **Android** — a foreground service (`NymBackgroundService`) with a
///    persistent low-importance notification and a partial wake lock. That is
///    the only supported way to hold sockets and the BLE radio open
///    indefinitely, and the notification is not optional: the OS posts it
///    whether or not we want it, which is why this is opt-in.
///  * **iOS** — the app cannot simply keep running. The BLE mesh continues
///    under the `bluetooth-central` / `bluetooth-peripheral` background modes
///    already declared in Info.plist (CoreBluetooth wakes the app for its own
///    events), and a `beginBackgroundTask` window keeps the rest of the app —
///    the relay sockets included — alive for the extra time the OS is willing
///    to grant, rather than being suspended at once.
///
/// Every call is best-effort and self-guarding: an unsupported platform, a
/// missing method channel (widget tests, desktop, web) or a platform exception
/// resolves to "not running" instead of throwing into the caller's lifecycle
/// handler.
class BackgroundConnectivityService {
  BackgroundConnectivityService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Method-channel name shared with `MainActivity.kt` / `AppDelegate.swift`.
  static const String channelName = 'app.nymchat/background_connectivity';

  final MethodChannel _channel;

  /// Whether this platform has any way to honor the setting at all. Used by the
  /// settings UI to keep the control off the screen where it would be a lie.
  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  bool _running = false;

  /// True while the platform keep-alive is believed to be active.
  bool get isRunning => _running;

  /// Starts the keep-alive. [mesh] tells Android whether to declare the
  /// `connectedDevice` foreground-service type alongside `dataSync`, so the
  /// service's declared purpose matches what the app is actually doing.
  ///
  /// Returns whether the platform reports it running.
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

  /// Stops the keep-alive (foreground service / background task). Safe to call
  /// when it was never started — the platform side is idempotent.
  Future<void> stop() async {
    _running = false;
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No native half in this build (tests / desktop) — nothing to stop.
    } on PlatformException catch (e) {
      debugPrint('[BackgroundConnectivity] stop failed: ${e.message}');
    } catch (e) {
      debugPrint('[BackgroundConnectivity] stop failed: $e');
    }
  }
}

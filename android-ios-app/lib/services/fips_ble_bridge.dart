/// fips_ble_bridge.dart
///
/// Stub for FIPS BLE bridge - placeholder for future BLE implementation.
///
/// This file provides the interface that the WebView JS expects, but does not
/// implement actual BLE functionality.

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Attach the FIPS BLE bridge to a WebView controller (stub).
Future<void> attachFIPSBLE(
  WebViewController webViewController,
  String localPubkey,
) async {
  debugPrint('[FIPS BLE] Stub bridge attached - BLE not implemented');
}

/// Dispose the current FIPS BLE bridge instance (stub).
Future<void> disposeFIPSBLE() async {
  debugPrint('[FIPS BLE] Stub bridge disposed');
}

/// Forward a message from JS to the active bridge (stub).
Future<void> handleFIPSBLEJSMessage(String message) async {
  debugPrint('[FIPS BLE] Stub received message - BLE not implemented');
}

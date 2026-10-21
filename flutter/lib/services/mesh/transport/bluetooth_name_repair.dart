import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BluetoothNameRepair {
  BluetoothNameRepair({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'app.nymchat/bluetooth_name';

  static final RegExp _meshName = RegExp(r'^[0-9a-f]{16}$');

  final MethodChannel _channel;

  static bool isMeshName(String? name) =>
      name != null && _meshName.hasMatch(name);

  static String? restoreTarget({
    required String? current,
    required String? saved,
    required String? deviceName,
    required String? model,
  }) {
    if (!isMeshName(current)) return null;
    for (final candidate in [saved, deviceName, model]) {
      if (candidate != null &&
          candidate.trim().isNotEmpty &&
          !isMeshName(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  Future<void> run() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('read');
      if (info == null) return;
      final current = info['name'] as String?;
      final saved = info['saved'] as String?;
      if (current == null || current.trim().isEmpty) return;
      if (!isMeshName(current)) {
        if (saved == null) {
          await _channel.invokeMethod<bool>('save', {'name': current});
        }
        return;
      }
      final target = restoreTarget(
        current: current,
        saved: saved,
        deviceName: info['deviceName'] as String?,
        model: info['model'] as String?,
      );
      if (target != null) {
        await _channel.invokeMethod<bool>('restore', {'name': target});
      }
    } catch (_) {}
  }
}

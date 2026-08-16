import 'package:flutter/foundation.dart';

/// A tiny in-app ring buffer of mesh receive-pipeline events, surfaced on the
/// Mesh screen so a device with no adb/log access can still show exactly what
/// happens when a message arrives — did the bridge handler run, what
/// conversation key was resolved, what view was open, and did the message
/// actually land in the store the chat reads.
///
/// Purely a debugging aid; carries no protocol weight and can be deleted once
/// the receive path is confirmed working end to end on a real device.
class MeshDiagnostics {
  MeshDiagnostics._();
  static final MeshDiagnostics instance = MeshDiagnostics._();

  static const int _cap = 60;
  final ValueNotifier<List<String>> entries = ValueNotifier<List<String>>([]);

  void log(String line) {
    final stamp = DateTime.now();
    final hh = stamp.hour.toString().padLeft(2, '0');
    final mm = stamp.minute.toString().padLeft(2, '0');
    final ss = stamp.second.toString().padLeft(2, '0');
    final entry = '$hh:$mm:$ss  $line';
    if (kDebugMode) debugPrint('[mesh-rx] $entry');
    final next = [entry, ...entries.value];
    if (next.length > _cap) next.removeRange(_cap, next.length);
    entries.value = next;
  }

  void clear() => entries.value = [];
}

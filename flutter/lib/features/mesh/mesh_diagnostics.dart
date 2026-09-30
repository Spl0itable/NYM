import 'package:flutter/foundation.dart';

/// In-app ring buffer of mesh receive-pipeline events, shown on the Mesh screen for devices without adb.
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

import 'package:flutter/foundation.dart';

/// Mesh avatar bytes keyed by seed; stored under a Nostr pubkey only when the NostrLink binding verified.
class MeshAvatarRegistry {
  MeshAvatarRegistry._();
  static final MeshAvatarRegistry instance = MeshAvatarRegistry._();

  final Map<String, Uint8List> _bytes = {};

  /// Bumped on every change so listening avatars rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Uint8List? bytesFor(String seed) => _bytes[seed];

  /// Registers [bytes] under each of [seeds]; bumps the revision only on change.
  void register(Iterable<String> seeds, Uint8List bytes) {
    var changed = false;
    for (final seed in seeds) {
      if (seed.isEmpty) continue;
      final existing = _bytes[seed];
      if (existing == null || !_sameBytes(existing, bytes)) {
        _bytes[seed] = bytes;
        changed = true;
      }
    }
    if (changed) revision.value++;
  }

  void clear() {
    if (_bytes.isEmpty) return;
    _bytes.clear();
    revision.value++;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

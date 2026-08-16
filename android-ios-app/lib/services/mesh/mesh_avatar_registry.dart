import 'package:flutter/foundation.dart';

/// A process-wide registry of avatar image bytes keyed by the same *seed*
/// [NymAvatar] uses (a pubkey or mesh peerID). It lets avatars transferred over
/// the Bluetooth mesh appear in the app's canonical message rows and anywhere
/// else an avatar is drawn — without threading a file path through every widget.
///
/// Bytes (not a file path) are stored so [NymAvatar] can render with
/// `Image.memory` and stay cross-platform (no `dart:io`, so web builds are
/// unaffected). Entries are small, capped avatar thumbnails.
///
/// Security: the mesh only registers bytes under a Nostr pubkey when the peer's
/// pubkey↔mesh-key binding is cryptographically verified (see NostrLink);
/// unverified peers are keyed by their mesh peerID only, so a peer can never
/// override another Nostr identity's avatar.
class MeshAvatarRegistry {
  MeshAvatarRegistry._();
  static final MeshAvatarRegistry instance = MeshAvatarRegistry._();

  final Map<String, Uint8List> _bytes = {};

  /// Bumped on every change so listening avatars rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Uint8List? bytesFor(String seed) => _bytes[seed];

  /// Registers [bytes] under each of [seeds] (e.g. a peerID and, when verified,
  /// a Nostr pubkey). Only bumps the revision when something actually changed.
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

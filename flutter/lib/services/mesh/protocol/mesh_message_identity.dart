import 'dart:convert';
import 'dart:typed_data';

import '../noise/noise_crypto.dart';

/// Content-derived identity for public mesh messages — a 1:1 port of bitchat's
/// `MeshMessageIdentity.stableID` (iOS `Protocols/MeshMessageIdentity.swift`).
///
/// The BLE wire carries NO message id for a public broadcast: the payload is
/// just the raw UTF-8 content. Every device recomputes the same stable id from
/// the signed wire fields (sender id, millisecond timestamp, trimmed content),
/// so a relayed copy dedups against the original and read/delivery bookkeeping
/// has a stable handle. bitchat-iOS and bitchat-android each derive their own
/// local id differently, so this value is a within-client identity only (which
/// is all it needs to be).
class MeshMessageIdentity {
  const MeshMessageIdentity._();

  /// `hex(SHA256("<senderHexLower>|<timestampMs>|<content.trim()>")).prefix(32)`.
  static String stableId({
    required String senderIdHex,
    required int timestampMs,
    required String content,
  }) {
    final input = '${senderIdHex.toLowerCase()}|$timestampMs|${content.trim()}';
    final digest = NoiseCrypto.sha256(Uint8List.fromList(utf8.encode(input)));
    final hex = StringBuffer();
    for (final b in digest) {
      hex.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString().substring(0, 32);
  }
}

import 'dart:convert';
import 'dart:typed_data';

import '../noise/noise_crypto.dart';

/// Stable id for public mesh messages, derived from signed fields since the BLE wire carries none (bitchat port).
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

import 'dart:convert';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;

import '../../../core/crypto/keys.dart' show bytesToHex, hexToBytes;
import 'noise_crypto.dart';

/// Nostr key's BIP340 signature over `SHA-256("nymmesh-link-v1:" ‖ noiseStaticKey)`; wire `pubkey(32) ‖ sig(64)`.
class NostrLink {
  const NostrLink._();

  static const String _domain = 'nymmesh-link-v1:';
  static const int length = 96;

  static String messageHex(Uint8List noiseStaticPublicKey) {
    final msg = <int>[...utf8.encode(_domain), ...noiseStaticPublicKey];
    return bytesToHex(NoiseCrypto.sha256(msg));
  }

  static Uint8List build(String nostrPubkeyHex, String signatureHex) {
    final out = Uint8List(length);
    out.setRange(0, 32, hexToBytes(nostrPubkeyHex.padLeft(64, '0')));
    out.setRange(32, 96, hexToBytes(signatureHex.padLeft(128, '0')));
    return out;
  }

  /// Returns the linked Nostr pubkey when the signature verifies against [noiseStaticPublicKey], else null.
  static String? verify(Uint8List value, Uint8List noiseStaticPublicKey) {
    if (value.length != length) return null;
    try {
      final pubkeyHex = bytesToHex(Uint8List.sublistView(value, 0, 32));
      final sigHex = bytesToHex(Uint8List.sublistView(value, 32, 96));
      final msgHex = messageHex(noiseStaticPublicKey);
      return bip340.verify(pubkeyHex, msgHex, sigHex) ? pubkeyHex : null;
    } catch (_) {
      return null;
    }
  }
}

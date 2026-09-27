import 'dart:convert';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;

import '../../../core/crypto/keys.dart' show bytesToHex, hexToBytes;
import 'noise_crypto.dart';

/// A cryptographic binding between a device's **mesh** identity (its Noise
/// static key) and its **Nostr** identity (a secp256k1 pubkey). Advertised in a
/// Nymchat-specific announcement TLV so a mesh peer can be matched to its real
/// Nostr profile — reusing the same avatar, banner and cosmetics offline.
///
/// The binding is a BIP340 schnorr signature by the Nostr key over
/// `SHA-256("nymmesh-link-v1:" ‖ noiseStaticPublicKey)`. Only the holder of the
/// Nostr private key can produce it, so a peer cannot spoof someone else's
/// Nostr identity on the mesh. bitchat ignores this TLV (unknown type).
///
/// Wire value: `nostrPubkey(32) ‖ signature(64)` = 96 bytes.
class NostrLink {
  const NostrLink._();

  static const String _domain = 'nymmesh-link-v1:';
  static const int length = 96;

  /// The 32-byte-hex message a Nostr key signs to bind [noiseStaticPublicKey].
  static String messageHex(Uint8List noiseStaticPublicKey) {
    final msg = <int>[...utf8.encode(_domain), ...noiseStaticPublicKey];
    return bytesToHex(NoiseCrypto.sha256(msg));
  }

  /// Builds the 96-byte TLV value from a 64-hex Nostr pubkey and 128-hex sig.
  static Uint8List build(String nostrPubkeyHex, String signatureHex) {
    final out = Uint8List(length);
    out.setRange(0, 32, hexToBytes(nostrPubkeyHex.padLeft(64, '0')));
    out.setRange(32, 96, hexToBytes(signatureHex.padLeft(128, '0')));
    return out;
  }

  /// Verifies a link [value] against the announcing peer's Noise static key.
  /// Returns the linked Nostr pubkey (64-hex) when the signature checks out,
  /// otherwise null.
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

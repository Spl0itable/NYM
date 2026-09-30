import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/crypto/keys.dart'
    show bytesToHex, hexToBytes, randomBytes;
import '../../storage/secure_store.dart';
import 'noise_crypto.dart';

/// Persistent mesh identity (X25519 Noise key + Ed25519 signing key); peerID/fingerprint derived as bitchat does.
class NoiseIdentity {
  NoiseIdentity._({
    required this.staticPrivate,
    required this.staticPublic,
    required this.signingSeed,
    required this.signingPublic,
    required this.peerID,
    required this.fingerprint,
  });

  final Uint8List staticPrivate; // X25519 private seed (32).
  final Uint8List staticPublic;
  final Uint8List signingSeed; // Ed25519 seed (32).
  final Uint8List signingPublic;
  final String peerID; // 16 hex chars.
  final String fingerprint; // 64 hex chars.

  static const _kStaticPriv = 'nym_mesh_noise_static_priv';
  static const _kSigningSeed = 'nym_mesh_ed25519_seed';

  static final Ed25519 _ed25519 = Ed25519();

  /// Loads the stored identity, creating and persisting one on first run.
  static Future<NoiseIdentity> loadOrCreate({
    FlutterSecureStorage storage = SecureStore.platform,
  }) async {
    var staticPrivHex = await storage.read(key: _kStaticPriv);
    var signingSeedHex = await storage.read(key: _kSigningSeed);

    Uint8List staticPriv;
    Uint8List signingSeed;
    if (staticPrivHex == null || signingSeedHex == null) {
      staticPriv = randomBytes(32);
      signingSeed = randomBytes(32);
      await storage.write(key: _kStaticPriv, value: bytesToHex(staticPriv));
      await storage.write(key: _kSigningSeed, value: bytesToHex(signingSeed));
    } else {
      staticPriv = hexToBytes(staticPrivHex);
      signingSeed = hexToBytes(signingSeedHex);
    }
    return fromSeeds(staticPrivate: staticPriv, signingSeed: signingSeed);
  }

  /// In-memory only, so Ghost Mode's per-epoch peerID can't be tied to the durable identity.
  static Future<NoiseIdentity> ephemeral() => fromSeeds(
        staticPrivate: randomBytes(32),
        signingSeed: randomBytes(32),
      );

  static Future<NoiseIdentity> fromSeeds({
    required Uint8List staticPrivate,
    required Uint8List signingSeed,
  }) async {
    final staticPublic = await NoiseCrypto.x25519PublicKey(staticPrivate);
    final signingKeyPair = await _ed25519.newKeyPairFromSeed(signingSeed);
    final signingPub = await signingKeyPair.extractPublicKey();
    final signingPublic = Uint8List.fromList(signingPub.bytes);
    final fingerprint = bytesToHex(NoiseCrypto.sha256(staticPublic));
    return NoiseIdentity._(
      staticPrivate: staticPrivate,
      staticPublic: staticPublic,
      signingSeed: signingSeed,
      signingPublic: signingPublic,
      peerID: fingerprint.substring(0, 16),
      fingerprint: fingerprint,
    );
  }

  Uint8List get peerIdBytes => hexToBytes(peerID);

  Future<Uint8List> sign(Uint8List message) async {
    final kp = await _ed25519.newKeyPairFromSeed(signingSeed);
    final sig = await _ed25519.sign(message, keyPair: kp);
    return Uint8List.fromList(sig.bytes);
  }

  static Future<bool> verify(
    Uint8List message,
    Uint8List signature,
    Uint8List signingPublicKey,
  ) async {
    try {
      return await _ed25519.verify(
        message,
        signature: Signature(
          signature,
          publicKey:
              SimplePublicKey(signingPublicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Mesh peerID: first 16 hex chars of SHA-256(noiseStaticPublicKey).
  static String derivePeerID(Uint8List noiseStaticPublicKey) =>
      bytesToHex(NoiseCrypto.sha256(noiseStaticPublicKey)).substring(0, 16);

  static bool matchesClaimedPeerID(String claimedPeerID, Uint8List noiseKey) =>
      claimedPeerID.toLowerCase() == derivePeerID(noiseKey).toLowerCase();
}

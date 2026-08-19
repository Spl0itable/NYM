import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/crypto/keys.dart'
    show bytesToHex, hexToBytes, randomBytes;
import 'noise_crypto.dart';

/// The device's long-term mesh identity — a persistent X25519 static key (used
/// as the Noise static key) plus an Ed25519 signing key (used to authenticate
/// announcements and any signed packet). Both are generated once and stored in
/// the platform secure enclave / keystore via [FlutterSecureStorage].
///
/// The mesh [peerID] and [fingerprint] are derived from the Noise static public
/// key exactly as bitchat derives them, so a Nymchat peer presents a stable,
/// verifiable identity to bitchat peers:
/// * `fingerprint` = hex(SHA-256(noiseStaticPublicKey))  (64 chars)
/// * `peerID`      = first 16 hex chars of the fingerprint (8 bytes)
class NoiseIdentity {
  NoiseIdentity._({
    required this.staticPrivate,
    required this.staticPublic,
    required this.signingSeed,
    required this.signingPublic,
    required this.peerID,
    required this.fingerprint,
  });

  final Uint8List staticPrivate; // X25519 private seed (32)
  final Uint8List staticPublic; // X25519 public (32)
  final Uint8List signingSeed; // Ed25519 seed (32)
  final Uint8List signingPublic; // Ed25519 public (32)
  final String peerID; // 16 hex chars
  final String fingerprint; // 64 hex chars

  static const _kStaticPriv = 'nym_mesh_noise_static_priv';
  static const _kSigningSeed = 'nym_mesh_ed25519_seed';

  static final Ed25519 _ed25519 = Ed25519();

  /// Loads the stored identity, generating and persisting a new one on first
  /// run. [storage] is injectable for tests.
  static Future<NoiseIdentity> loadOrCreate({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
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

  /// Builds an identity from raw 32-byte seeds (used by [loadOrCreate] and
  /// tests). Derives all public keys and the peerID/fingerprint.
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

  /// The 8-byte peerID for use as a packet sender/recipient id.
  Uint8List get peerIdBytes => hexToBytes(peerID);

  /// Ed25519-signs [message] with our signing key (64-byte signature).
  Future<Uint8List> sign(Uint8List message) async {
    final kp = await _ed25519.newKeyPairFromSeed(signingSeed);
    final sig = await _ed25519.sign(message, keyPair: kp);
    return Uint8List.fromList(sig.bytes);
  }

  /// Verifies an Ed25519 [signature] over [message] against [signingPublicKey].
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

  /// Derives the mesh peerID (16 hex chars) from a Noise static public key.
  static String derivePeerID(Uint8List noiseStaticPublicKey) =>
      bytesToHex(NoiseCrypto.sha256(noiseStaticPublicKey)).substring(0, 16);

  /// True when [claimedPeerID] matches the peerID derived from [noiseKey].
  static bool matchesClaimedPeerID(String claimedPeerID, Uint8List noiseKey) =>
      claimedPeerID.toLowerCase() == derivePeerID(noiseKey).toLowerCase();
}

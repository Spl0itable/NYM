import 'dart:typed_data';

/// A mesh peer; [isVerified] once its peerID is bound to the announced Noise static key.
class MeshPeer {
  MeshPeer({
    required this.peerID,
    this.nickname,
    this.noisePublicKey,
    this.signingPublicKey,
    this.rssi = 0,
    this.isDirectLink = false,
    this.isVerified = false,
    this.nostrPubkey,
    this.nostrLinkVerified = false,
    this.avatarUrl,
    this.bannerUrl,
    this.avatarFilePath,
    this.supportsPrivateMedia = false,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  /// 16-hex mesh id: first 8 bytes of SHA-256(noise pubkey).
  final String peerID;

  String? nickname;

  /// Curve25519 static key (Noise identity) from the announcement.
  Uint8List? noisePublicKey;

  /// Ed25519 signing key from the announcement.
  Uint8List? signingPublicKey;

  int rssi;

  /// True for a direct BLE link, false when reached via relay.
  bool isDirectLink;

  /// True once the announcement signature verified and the peerID matched the Noise key.
  bool isVerified;

  /// Linked Nostr pubkey (64-hex) from the peer's signed npub-link TLV.
  String? nostrPubkey;

  /// True when the schnorr signature binding [nostrPubkey] to this Noise key verified.
  bool nostrLinkVerified;

  /// Avatar URL from the linked Nostr profile, served from the image cache when offline.
  String? avatarUrl;
  String? bannerUrl;

  /// Local path of an avatar transferred over the mesh, used when no Nostr avatar is cached.
  String? avatarFilePath;

  /// True once an authenticated peer-state advertised the `privateMedia` bit.
  bool supportsPrivateMedia;

  DateTime lastSeen;

  /// Announced nickname, or a short peerID fallback.
  String get displayName =>
      (nickname != null && nickname!.isNotEmpty) ? nickname! : peerID;

  void touch() => lastSeen = DateTime.now();
}

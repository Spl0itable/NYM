import 'dart:typed_data';

/// A peer discovered on the Bluetooth mesh. Identity is established from a
/// signed announcement; [isVerified] is true once the peerID has been
/// cryptographically bound to the announced Noise static key (and, after a Noise
/// handshake, to a live session).
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

  /// 16-hex-char mesh identifier (first 8 bytes of SHA-256(noise pubkey)).
  final String peerID;

  String? nickname;

  /// Curve25519 static key from the peer's announcement (Noise identity).
  Uint8List? noisePublicKey;

  /// Ed25519 signing key from the peer's announcement.
  Uint8List? signingPublicKey;

  int rssi;

  /// True when we hold a direct BLE link to this peer (vs. reached via relay).
  bool isDirectLink;

  /// True once the announcement signature verified and the peerID matched the
  /// announced Noise key.
  bool isVerified;

  /// The peer's linked Nostr pubkey (64-hex), when they advertised a signed
  /// npub-link TLV in their announcement. Lets the UI reuse the peer's real
  /// Nostr profile (avatar/banner/cosmetics) offline.
  String? nostrPubkey;

  /// True when the schnorr signature binding [nostrPubkey] to this peer's mesh
  /// Noise key verified — i.e. the Nostr identity really vouches for this peer.
  bool nostrLinkVerified;

  /// Remote avatar/banner URL resolved from the linked Nostr profile (served
  /// from the app's image cache when offline).
  String? avatarUrl;
  String? bannerUrl;

  /// Local file path of an avatar transferred directly over the mesh (used when
  /// no cached Nostr avatar is available — see the mesh profile transfer).
  String? avatarFilePath;

  /// True once this peer sent us a session-authenticated peer-state
  /// ([AuthenticatedPeerStatePacket]) advertising the `privateMedia` bit — i.e.
  /// it can receive encrypted private media over the Noise session.
  bool supportsPrivateMedia;

  DateTime lastSeen;

  /// Display label — the announced nickname, or a short peerID fallback.
  String get displayName =>
      (nickname != null && nickname!.isNotEmpty) ? nickname! : peerID;

  void touch() => lastSeen = DateTime.now();
}

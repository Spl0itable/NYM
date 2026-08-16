/// Bitchat mesh packet types — byte-for-byte compatible with the reference
/// bitchat iOS/Android clients (`BinaryProtocol.MessageType`).
///
/// These are the `type` byte of a [BitchatPacket]. Interop with the real
/// bitchat app depends on these exact values, so they are frozen here and must
/// not be renumbered.
class MeshMessageType {
  const MeshMessageType._();

  /// Signed identity announcement (TLV [IdentityAnnouncement] payload).
  static const int announce = 0x01;

  /// User message — public/broadcast chat (TLV [BitchatMessage] payload).
  static const int message = 0x02;

  /// Peer is leaving the mesh (payload = sender peerID string).
  static const int leave = 0x03;

  /// Noise XX handshake message (payloads are the 32/96/48-byte XX messages).
  static const int noiseHandshake = 0x10;

  /// Noise-encrypted transport message (payload = Noise ciphertext).
  static const int noiseEncrypted = 0x11;

  /// A single fragment of a larger packet (payload = [FragmentPayload]).
  static const int fragment = 0x20;

  /// GCS-based gossip sync request.
  static const int requestSync = 0x21;

  /// File transfer packet (BLE media / voice notes).
  static const int fileTransfer = 0x22;

  /// Ephemeral live push-to-talk audio frame (never gossip-synced).
  static const int voiceFrame = 0x29;

  // --- Nymchat extensions (unknown to bitchat, which ignores them) ----------

  /// Request a peer's rich profile (avatar/banner) over the mesh.
  static const int nymProfileRequest = 0x50;

  /// Deliver a rich profile in response to [nymProfileRequest].
  static const int nymProfileResponse = 0x51;

  /// Ephemeral typing indicator (Nymchat-only; bitchat ignores it). Broadcast
  /// for a channel, directed for a 1:1 DM.
  static const int nymTyping = 0x52;

  /// A public/channel emoji reaction (Nymchat-only; bitchat ignores it). A 1:1
  /// reaction rides an encrypted [NoisePayloadType.reaction] instead.
  static const int nymReaction = 0x53;

  /// An AES-encrypted mesh GROUP-channel broadcast (Nymchat password channels;
  /// bitchat ignores it). Carries the legacy [BitchatMessage] TLV with the
  /// isEncrypted flag. Kept OFF the plain [message] type so that type can be
  /// decoded byte-for-byte like bitchat's public mesh chat: raw UTF-8, no TLV.
  static const int nymChannelMessage = 0x54;

  /// True when [type] is a value this client knows how to handle.
  static bool isKnown(int type) => const {
        announce,
        message,
        leave,
        noiseHandshake,
        noiseEncrypted,
        fragment,
        requestSync,
        fileTransfer,
        voiceFrame,
      }.contains(type);

  static String name(int type) {
    switch (type) {
      case announce:
        return 'ANNOUNCE';
      case message:
        return 'MESSAGE';
      case leave:
        return 'LEAVE';
      case noiseHandshake:
        return 'NOISE_HANDSHAKE';
      case noiseEncrypted:
        return 'NOISE_ENCRYPTED';
      case fragment:
        return 'FRAGMENT';
      case requestSync:
        return 'REQUEST_SYNC';
      case fileTransfer:
        return 'FILE_TRANSFER';
      case voiceFrame:
        return 'VOICE_FRAME';
      default:
        return 'UNKNOWN(0x${type.toRadixString(16)})';
    }
  }
}

/// The inner Noise-plaintext payload discriminator carried by a
/// [MeshMessageType.noiseEncrypted] packet after the session is established.
///
/// Mirrors bitchat's `NoisePayloadType`: the first byte of the decrypted
/// plaintext selects how the remainder is parsed.
class NoisePayloadType {
  const NoisePayloadType._();

  /// A private text message (TLV: MESSAGE_ID + CONTENT).
  static const int privateMessage = 0x01;

  /// A read receipt (payload identifies the original message id).
  static const int readReceipt = 0x02;

  /// A delivery acknowledgement (payload identifies the original message id).
  static const int delivered = 0x03;

  /// A file/media transfer (payload is a [BitchatFilePacket]). Matches bitchat's
  /// `privateFile = 0x20`.
  static const int fileTransfer = 0x20;

  /// Session-authenticated capability proof (payload is an
  /// [AuthenticatedPeerStatePacket]). Matches bitchat's
  /// `authenticatedPeerState = 0x21`, emitted after every completed/rekeyed
  /// Noise handshake. Advertising the `privateMedia` bit here — not just in the
  /// public announce — is what lets bitchat accept our encrypted private media
  /// and stop warning that our client can't receive it.
  static const int authenticatedPeerState = 0x21;

  /// An emoji reaction to a 1:1 message (Nymchat-only).
  ///
  /// MUST stay out of bitchat's assigned range: bitchat uses `0x21` for
  /// `authenticatedPeerState`, which it sends routinely over the Noise session
  /// right after a handshake. Sharing `0x21` made us decode that peer-state
  /// frame as a reaction and stamp a spurious emoji (the phantom ❤️ on a
  /// just-sent message). `0x70` is well clear of every bitchat NoisePayloadType
  /// (all ≤ 0x21), so their frames now fall through to our default-ignore.
  static const int reaction = 0x70;
}

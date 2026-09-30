/// bitchat packet `type` bytes; interop depends on these exact values, so never renumber them.
class MeshMessageType {
  const MeshMessageType._();

  static const int announce = 0x01;

  static const int message = 0x02;

  /// Peer is leaving the mesh; payload is the sender peerID string.
  static const int leave = 0x03;

  /// Store-and-forward [CourierEnvelope], opaque to whoever carries it.
  static const int courierEnvelope = 0x04;

  static const int noiseHandshake = 0x10;

  static const int noiseEncrypted = 0x11;

  static const int fragment = 0x20;

  static const int requestSync = 0x21;

  static const int fileTransfer = 0x22;

  /// Signed one-time prekeys, gossiped so courier mail gets forward secrecy.
  static const int prekeyBundle = 0x24;

  static const int ping = 0x26;

  static const int pong = 0x27;

  /// Gateway mode: a signed Nostr event ferried between a mesh-only peer and one with internet.
  static const int nostrCarrier = 0x28;

  /// Live push-to-talk audio frame, never gossip-synced.
  static const int voiceFrame = 0x29;

  // Nymchat extensions, ignored by bitchat.

  static const int nymProfileRequest = 0x50;

  static const int nymProfileResponse = 0x51;

  /// Typing indicator: broadcast for a channel, directed for a DM.
  static const int nymTyping = 0x52;

  /// Public/channel emoji reaction; a 1:1 reaction rides an encrypted [NoisePayloadType.reaction].
  static const int nymReaction = 0x53;

  /// AES-encrypted group-channel broadcast, kept off [message] so that stays raw UTF-8 like bitchat's.
  static const int nymChannelMessage = 0x54;

  static bool isKnown(int type) => const {
        announce,
        message,
        leave,
        noiseHandshake,
        noiseEncrypted,
        fragment,
        courierEnvelope,
        requestSync,
        fileTransfer,
        prekeyBundle,
        ping,
        pong,
        nostrCarrier,
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
      case courierEnvelope:
        return 'COURIER_ENVELOPE';
      case prekeyBundle:
        return 'PREKEY_BUNDLE';
      case ping:
        return 'PING';
      case pong:
        return 'PONG';
      case nostrCarrier:
        return 'NOSTR_CARRIER';
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

/// First byte of a decrypted Noise payload, as bitchat's `NoisePayloadType`.
class NoisePayloadType {
  const NoisePayloadType._();

  /// Private text message (TLV: MESSAGE_ID + CONTENT).
  static const int privateMessage = 0x01;

  static const int readReceipt = 0x02;

  static const int delivered = 0x03;

  /// File/media transfer ([BitchatFilePacket]), bitchat's `privateFile`.
  static const int fileTransfer = 0x20;

  /// bitchat's `authenticatedPeerState`, sent after every handshake; its privateMedia bit unlocks private media.
  static const int authenticatedPeerState = 0x21;

  /// Nymchat 1:1 reaction, kept above bitchat's range (all ≤ 0x21) to avoid misparsing its frames.
  static const int reaction = 0x70;
}

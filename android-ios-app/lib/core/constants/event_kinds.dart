/// Nostr event kinds used by Nymchat, ported verbatim from the PWA.
/// See docs/specs/01-core-state-nostr.md §3.1.
class EventKind {
  EventKind._();

  /// Profile metadata (NIP-01): name/display_name/about/picture/banner/lud16.
  static const int profile = 0;

  /// Deletion (NIP-09).
  static const int deletion = 5;

  /// Reaction (NIP-25).
  static const int reaction = 7;

  /// Seal (NIP-59) — inner sealed layer inside a gift wrap.
  static const int seal = 13;

  /// DM rumor (NIP-17). Also used as the bitchat receipt rumor kind.
  static const int dmRumor = 14;

  /// File-message DM rumor (NIP-17). Accepted alongside kind 14 when
  /// unwrapping gift-wrapped DMs (pms.js rumor accept list).
  static const int fileMessage = 15;

  /// Gift wrap (NIP-59) — outer wrapper for DMs / group messages.
  static const int giftWrap = 1059;

  /// Report (NIP-56) — user/content report event.
  static const int report = 1984;

  /// Mute list (NIP-51).
  static const int muteList = 10000;

  /// User emoji list (NIP-30).
  static const int userEmojiList = 10030;

  /// Ephemeral geohash channel message (bitchat-compatible). channel in ['g'].
  static const int geoChannel = 20000;

  /// Ephemeral named channel message (Nymchat). channel in ['d'].
  static const int namedChannel = 23333;

  /// NIP-46 remote-signer transport (client <-> signer).
  static const int nip46 = 24133;

  /// Channel typing indicator (ephemeral, Nymchat).
  static const int channelTyping = 24420;

  /// Channel read receipt (ephemeral, Nymchat).
  static const int channelReceipt = 24421;

  /// Blossom HTTP auth (BUD-01) — signed upload/mirror authorization event.
  static const int blossomAuth = 24242;

  /// P2P WebRTC signaling (SDP/ICE).
  static const int p2pSignaling = 25051;

  /// P2P file status (unseeded notifications).
  static const int p2pFileStatus = 25052;

  /// Call signaling.
  static const int callSignaling = 25053;

  /// Friend presence (private, gift-wrapped) rumor kind.
  static const int friendPresence = 25054;

  /// NIP-98 HTTP auth event.
  static const int httpAuth = 27235;

  /// Custom emoji pack (NIP-30, parameterized replaceable).
  static const int emojiPack = 30030;

  /// App data (NIP-78). Multiplexed by ['t', ...]: presence / poll / vouches.
  static const int appData = 30078;

  /// Zap request (NIP-57).
  static const int zapRequest = 9734;

  /// Zap receipt (NIP-57).
  static const int zapReceipt = 9735;

  /// Nymchat rumor kind for typing indicators & receipts inside gift wraps.
  /// Kept off kind 14 so blank receipts don't render as DMs in other clients.
  static const int nymReceiptRumor = 69420;

  // Aliases matching the PWA instance constants.
  static const int presenceKind = appData;
  static const int pollKind = appData;
  static const int pollVoteKind = appData;
}

/// 30078 `['t', ...]` topic discriminators.
class AppDataTopic {
  AppDataTopic._();
  static const String presence = 'nym-presence';
  static const String poll = 'nym-poll';
  static const String pollVote = 'nym-poll-vote';
  static const String vouches = 'nym-vouches';
  static const String settingsTransferPrefix = 'nym-settings-transfer-';
}

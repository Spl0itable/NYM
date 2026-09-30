/// Nostr event kinds used by Nymchat, ported verbatim from the PWA.
class EventKind {
  EventKind._();

  static const int profile = 0;

  static const int deletion = 5;

  static const int reaction = 7;

  static const int seal = 13;

  /// DM rumor (NIP-17); also the bitchat receipt rumor kind.
  static const int dmRumor = 14;

  /// File-message DM rumor (NIP-17), accepted alongside kind 14.
  static const int fileMessage = 15;

  static const int giftWrap = 1059;

  static const int report = 1984;

  static const int muteList = 10000;

  static const int userEmojiList = 10030;

  /// Ephemeral geohash channel message (bitchat-compatible), channel in ['g'].
  static const int geoChannel = 20000;

  /// Ephemeral named channel message, channel in ['d'].
  static const int namedChannel = 23333;

  static const int nip46 = 24133;

  static const int channelTyping = 24420;

  static const int channelReceipt = 24421;

  static const int blossomAuth = 24242;

  static const int p2pSignaling = 25051;

  /// P2P file status (unseeded notifications).
  static const int p2pFileStatus = 25052;

  static const int callSignaling = 25053;

  /// Friend presence rumor kind (gift-wrapped).
  static const int friendPresence = 25054;

  static const int httpAuth = 27235;

  static const int emojiPack = 30030;

  /// App data (NIP-78), multiplexed by ['t', ...].
  static const int appData = 30078;

  static const int zapRequest = 9734;

  static const int zapReceipt = 9735;

  /// Gift-wrapped typing and receipt rumors, kept off kind 14 so other clients don't show blank DMs.
  static const int nymReceiptRumor = 69420;

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

  static const String postQuantum = 'nym-pq';
}

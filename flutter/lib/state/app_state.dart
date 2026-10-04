import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/event_kinds.dart';
import '../core/constants/history_window.dart';
import '../core/utils/nym_utils.dart';
import '../features/channels/channel_manager.dart';
import '../features/chat_tools/chat_tools.dart'
    show ChatToolsLimits, EditCandidate, editVerdict;
import '../features/chat_tools/chat_tools_service.dart' show chatToolsHidden;
import '../features/emoji/custom_emoji.dart'
    show
        CustomEmojiPack,
        CustomEmojiState,
        emojiPrefsProvider,
        kCustomEmojiMapKey,
        kCustomEmojiPacksKey,
        loadCustomEmojiState;
import '../features/emoji/emoji_data.dart';
import '../features/emoji/emoji_prefetch.dart' show scheduleCustomEmojiPrefetch;
import '../features/groups/group_logic.dart';
import '../features/i18n/i18n.dart';
import '../features/messages/server_quiet.dart';
import '../features/messages/spam_filter.dart';
import '../features/nymbot/bot_runs.dart' show anchorBotReply;
import '../features/messages/trust_graph.dart';
import '../features/pms/pm_logic.dart';
import '../features/polls/poll_logic.dart';
import '../features/toasts/toast_center.dart';
import '../features/zaps/zap_logic.dart';
import '../models/channel.dart';
import '../models/group.dart';
import '../models/message.dart';
import '../models/nostr_event.dart';
import '../models/pm_conversation.dart';
import '../core/crypto/pow.dart' show validatedPowBits;
import '../features/messages/cross_content_flood.dart';
import '../models/poll.dart';
import '../models/user.dart';
import '../services/filter/filter_packs.dart';
import '../services/attest/attest_service.dart';
import '../services/nostr/event_mapper.dart';
import 'settings_provider.dart';

/// The verified Nymchat developer pubkey: a web-of-trust root, exempt from spam-gating.
const String kVerifiedDeveloperPubkey =
    'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';

/// The verified Nymbot pubkey: the second trust root, exempt from spam-gating.
const String kNymbotPubkey =
    'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2';

/// Kept as a set to match the PWA's `verifiedBotPubkeys` shape.
const Set<String> kVerifiedBotPubkeys = {kNymbotPubkey};

const String kNymbotAvatarAsset = 'assets/images/nymbot-icon.png';
const String kNymbotBannerAsset = 'assets/images/nymbot-banner.png';

UserProfile pinVerifiedBotMedia(String pubkey, UserProfile p) {
  if (!kVerifiedBotPubkeys.contains(pubkey)) return p;
  p.picture = kNymbotAvatarAsset;
  p.banner = kNymbotBannerAsset;
  return p;
}

/// Seeded bot user that always reports online, so every `effectiveStatus()` read agrees with the PWA.
class VerifiedBotUser extends User {
  VerifiedBotUser({
    required super.pubkey,
    super.nym,
    super.lastSeen,
    super.status,
    super.profile,
  });

  @override
  UserStatus effectiveStatus({int? nowMs, bool isVerifiedBot = false}) =>
      super.effectiveStatus(nowMs: nowMs, isVerifiedBot: true);
}

/// Web-of-trust roots seeded on go-live; every vouch chain is anchored here.
const Set<String> kTrustRootPubkeys = {
  kVerifiedDeveloperPubkey,
  kNymbotPubkey,
};

/// Master switch for the web-of-trust message-hiding gate; off everywhere, vouches are still tracked.
bool nymVouchSpamGateEnabled = false;

/// Module-global mirrors of the content spam filter flags so pure code can read them; seeded at boot.
bool appSpamFilterEnabled = true;
bool appSpamFilterAggressive = true;

/// Module-global mirror of the threads setting so [visibleMessagesFor] can read it; seeded at boot.
bool appThreadsEnabled = true;

/// Inbound PoW exclusion threshold for public-channel messages, in leading zero bits; 0 disables it.
int appPowFilterBits = 0;

/// Inbound verified-app filter: 'off', 'verified' (platform-attested) or 'any' (also web tier).
String appVerifiedFilter = 'off';

AttestRegistry appAttestRegistry = AttestRegistry();
String appAttestAuthority = '';

/// Whether [pubkey] clears [appVerifiedFilter]; self, friends and Nymbot always pass.
bool passesVerifiedFilter(
  String pubkey, {
  required String selfPubkey,
  required Set<String> friends,
}) {
  if (appVerifiedFilter == 'off') return true;
  if (pubkey == selfPubkey) return true;
  if (kVerifiedBotPubkeys.contains(pubkey)) return true;
  if (friends.contains(pubkey)) return true;
  return appAttestRegistry.tierOf(pubkey) != null;
}

/// Mirrors the PWA's mutually exclusive current channel / PM / group state.
enum ViewKind { channel, pm, group }

final RegExp _hex64AnyCaseRe = RegExp(r'^[0-9a-fA-F]{64}$');

/// The active conversation; [storageKey] is `#<key>`, `pm-<pubkey>` or `group-<id>`.
class ChatView {
  const ChatView.channel(this.id)
      : kind = ViewKind.channel,
        storageKey = '#$id';
  const ChatView.pm(this.id)
      : kind = ViewKind.pm,
        storageKey = 'pm-$id';
  const ChatView.group(this.id)
      : kind = ViewKind.group,
        storageKey = 'group-$id';

  final ViewKind kind;

  /// Channel key (geohash or name), PM peer pubkey, or group id.
  final String id;

  final String storageKey;

  bool get inPMMode => kind != ViewKind.channel;

  @override
  bool operator ==(Object other) =>
      other is ChatView && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

class MessageReaction {
  const MessageReaction({
    required this.emoji,
    required this.count,
    this.userReacted = false,
  });
  final String emoji;
  final int count;
  final bool userReacted;
}

/// [receipts] dedups verify-URL and NIP-57 confirmations; [unverified] maps receipt key to sats.
class MessageZaps {
  MessageZaps({
    int? totalSats,
    Set<String>? zappers,
    Set<String>? receipts,
    Map<String, int>? unverified,
  })  : totalSats = totalSats ?? 0,
        zappers = zappers ?? <String>{},
        receipts = receipts ?? <String>{},
        unverified = unverified ?? <String, int>{};

  int totalSats;
  final Set<String> zappers;
  final Set<String> receipts;

  final Map<String, int> unverified;

  int get zapperCount => zappers.length;

  int get unverifiedSats {
    var sum = 0;
    for (final s in unverified.values) {
      sum += s;
    }
    return sum;
  }
}

/// [AppState.seed] builds a sample store for tests and demos only; production starts from [AppState.empty].
class AppState {
  AppState({
    required this.selfPubkey,
    required this.selfNym,
    required this.channels,
    required this.pmConversations,
    required this.groups,
    required this.users,
    required this.messages,
    required this.reactions,
    required this.unreadCounts,
    required this.view,
    this.connectedRelays = 0,
    this.proxyMode = true,
    this.displayRev = 0,
    Map<String, int>? typing,
    Map<String, Poll>? polls,
    Map<String, MessageZaps>? zaps,
    Set<String>? pinnedChannels,
    Set<String>? hiddenChannels,
    Set<String>? blockedChannels,
    Map<String, int>? channelLastActivity,
    Map<String, List<int>>? geohashD1Activity,
    Set<String>? friends,
    Set<String>? blockedUsers,
    Map<String, int>? autoMutedUsers,
    Set<String>? blockedKeywords,
    Set<String>? nymchatPubkeys,
    Set<String>? nymchatVouches,
    Set<String>? trustedPubkeys,
  })  : typing = typing ?? <String, int>{},
        polls = polls ?? <String, Poll>{},
        zaps = zaps ?? <String, MessageZaps>{},
        pinnedChannels = pinnedChannels ?? <String>{},
        hiddenChannels = hiddenChannels ?? <String>{},
        blockedChannels = blockedChannels ?? <String>{},
        channelLastActivity = channelLastActivity ?? <String, int>{},
        geohashD1Activity = geohashD1Activity ?? <String, List<int>>{},
        friends = friends ?? <String>{},
        blockedUsers = blockedUsers ?? <String>{},
        autoMutedUsers = autoMutedUsers ?? <String, int>{},
        blockedKeywords = blockedKeywords ?? <String>{},
        nymchatPubkeys = nymchatPubkeys ?? <String>{},
        nymchatVouches = nymchatVouches ?? <String>{},
        trustedPubkeys = trustedPubkeys ?? <String>{};

  final String selfPubkey;
  final String selfNym;

  final int connectedRelays;

  final bool proxyMode;

  /// Client-side automatic spam heuristics only run in direct mode; explicit user filters apply in both.
  bool get clientGatesActive => !proxyMode;

  /// Bumped when rendered list content changes; ambient churn skips it to avoid list rebuilds.
  final int displayRev;

  final List<ChannelEntry> channels;
  final List<PMConversation> pmConversations;
  final List<Group> groups;

  final Map<String, User> users;

  /// view storageKey → ordered messages (oldest first).
  final Map<String, List<Message>> messages;

  final Map<String, List<MessageReaction>> reactions;

  final Map<String, int> unreadCounts;

  /// `<storageKey>|<pubkey>` → typing-stop expiry (ms since epoch).
  final Map<String, int> typing;

  /// pollId → Poll (kind 30078 `nym-poll`); channel-only.
  final Map<String, Poll> polls;

  final Map<String, MessageZaps> zaps;

  final Set<String> pinnedChannels;

  final Set<String> hiddenChannels;

  final Set<String> blockedChannels;

  /// channel storage key (`#<key>`) → last-activity ms.
  final Map<String, int> channelLastActivity;

  /// bare geohash → 24 hourly D1 activity counts (`buckets[0]` is this hour) for the globe heatmap.
  final Map<String, List<int>> geohashD1Activity;

  final Set<String> friends;

  final Set<String> blockedUsers;

  final Map<String, int> autoMutedUsers;

  bool isAutoMuted(String pubkey) {
    final until = autoMutedUsers[pubkey];
    if (until == null) return false;
    return DateTime.now().millisecondsSinceEpoch < until;
  }

  /// Blocked keywords, all lowercased; matched against content or author nym.
  final Set<String> blockedKeywords;

  /// Web-of-trust graph of pubkeys believed to run Nymchat; members are never spam-gated.
  final Set<String> nymchatPubkeys;

  /// Our own vouch list, published as kind-30078 `nym-vouches`.
  final Set<String> nymchatVouches;

  /// Pubkeys trusted by sending at least two messages this session.
  final Set<String> trustedPubkeys;

  final ChatView view;

  bool isFriend(String pubkey) => friends.contains(pubkey);

  bool isUserBlocked(String pubkey) => blockedUsers.contains(pubkey);

  /// Case-insensitive match on [text] or the base nym of [nickname] (suffix/flair stripped).
  bool hasBlockedKeyword(String text, [String? nickname, String? pubkey]) {
    final lowerText = text.toLowerCase();
    final nick = (nickname != null && nickname.isNotEmpty)
        ? stripPubkeySuffix(nickname)
        : '';
    final lowerNick = nick.toLowerCase();
    for (final keyword in blockedKeywords) {
      if (lowerText.contains(keyword) ||
          (lowerNick.isNotEmpty && lowerNick.contains(keyword))) {
        return true;
      }
    }
    // Filter packs are checked here so every existing filter caller picks them up.
    if (FilterPacks.active.isEmpty) return false;
    if (pubkey != null && pubkey.isNotEmpty) {
      if (pubkey == selfPubkey) return false;
      if (friends.contains(pubkey)) return false;
      if (kVerifiedBotPubkeys.contains(pubkey)) return false;
    }
    return FilterPacks.matches(text, nym: nick.isEmpty ? null : nick);
  }

  /// True when the web-of-trust spam gate hides a message from a low-trust sender.
  bool isSpamGated(
    Message m, {
    String? verifiedDeveloper,
    Set<String> verifiedBots = const {},
  }) {
    if (m.isOwn) return false;
    if (isFriend(m.pubkey)) return false;
    if (nymchatPubkeys.contains(m.pubkey)) return false;
    if (verifiedDeveloper != null && m.pubkey == verifiedDeveloper) {
      return false;
    }
    if (verifiedBots.contains(m.pubkey)) return false;
    if (trustedPubkeys.contains(m.pubkey)) return false;
    return true;
  }

  /// True when [m] should be hidden: blocked author, keyword match, non-own heuristic spam, or spam-gated.
  bool isMessageFiltered(Message m) {
    // System pills carry no sender and must always show.
    if (m.isSystemRow) return false;
    if (blockedUsers.contains(m.pubkey)) return true;
    if (!m.isOwn && clientGatesActive && isAutoMuted(m.pubkey)) return true;
    // Keyword hits hide our own messages too, though they are still sent.
    if (hasBlockedKeyword(m.content, m.author, m.pubkey)) return true;
    // Mesh peers are deliberately paired, so automatic spam gates don't apply; explicit blocks still do.
    if (m.viaMesh) return false;
    if (!m.isOwn && ServerQuiet.hides(m.pubkey, m.id)) return true;
    // Own heuristic spam is surfaced as a self-only notice instead.
    if (clientGatesActive &&
        !m.isOwn &&
        SpamFilter.isSpamMessage(m.content,
            enabled: appSpamFilterEnabled,
            aggressive: appSpamFilterAggressive)) {
      return true;
    }
    if (clientGatesActive &&
        nymVouchSpamGateEnabled &&
        isSpamGated(m,
            verifiedDeveloper: kVerifiedDeveloperPubkey,
            verifiedBots: kVerifiedBotPubkeys)) {
      return true;
    }
    return false;
  }

  /// Deliberately narrower than [isMessageFiltered]: keyword and heuristic-spam hits still count toward unread.
  bool countsTowardUnread(Message m) {
    if (m.isSystemRow) return false;
    if (m.isOwn) return false;
    if (blockedUsers.contains(m.pubkey)) return false;
    if (clientGatesActive && isAutoMuted(m.pubkey)) return false;
    if (clientGatesActive &&
        nymVouchSpamGateEnabled &&
        isSpamGated(m,
            verifiedDeveloper: kVerifiedDeveloperPubkey,
            verifiedBots: kVerifiedBotPubkeys)) {
      return false;
    }
    return true;
  }

  AppState copyWith({
    String? selfPubkey,
    String? selfNym,
    ChatView? view,
    int? connectedRelays,
    bool? proxyMode,
    int? displayRev,
  }) =>
      AppState(
        selfPubkey: selfPubkey ?? this.selfPubkey,
        selfNym: selfNym ?? this.selfNym,
        channels: channels,
        pmConversations: pmConversations,
        groups: groups,
        users: users,
        messages: messages,
        reactions: reactions,
        unreadCounts: unreadCounts,
        view: view ?? this.view,
        connectedRelays: connectedRelays ?? this.connectedRelays,
        proxyMode: proxyMode ?? this.proxyMode,
        displayRev: displayRev ?? this.displayRev,
        typing: typing,
        polls: polls,
        zaps: zaps,
        pinnedChannels: pinnedChannels,
        hiddenChannels: hiddenChannels,
        blockedChannels: blockedChannels,
        channelLastActivity: channelLastActivity,
        geohashD1Activity: geohashD1Activity,
        friends: friends,
        blockedUsers: blockedUsers,
        autoMutedUsers: autoMutedUsers,
        blockedKeywords: blockedKeywords,
        nymchatPubkeys: nymchatPubkeys,
        nymchatVouches: nymchatVouches,
        trustedPubkeys: trustedPubkeys,
      );

  /// Test/demo only; production uses [AppState.empty] / [AppState.live].
  factory AppState.seed() => _seedAppState();

  /// The production logged-out initial state: an empty shell with only #nymchat.
  factory AppState.empty() => AppState.live('', '');

  factory AppState.live(String pubkey, String nym) => AppState(
        selfPubkey: pubkey,
        selfNym: nym,
        channels: [ChannelEntry(channel: kDefaultChannel)],
        pmConversations: [],
        groups: [],
        users: {},
        messages: {},
        reactions: {},
        unreadCounts: {},
        view: const ChatView.channel(kDefaultChannel),
      );
}

// Sample data (test/demo only).

// The last 4 hex chars form the display suffix.
const String _selfPubkey =
    '0000000000000000000000000000000000000000000000000000000000001a2b';
const String _pkSatoshi =
    '11111111111111111111111111111111111111111111111111111111deadbeef';
const String _pkNeo =
    '2222222222222222222222222222222222222222222222222222222222223c4d';
const String _pkTrinity =
    '33333333333333333333333333333333333333333333333333333333000099ff';
const String _pkOracle =
    '4444444444444444444444444444444444444444444444444444444444445e6f';
const String _pkBot =
    '5555555555555555555555555555555555555555555555555555555555550b07';

const String _selfNym = 'you#1a2b';

AppState _seedAppState() {
  final now = DateTime.now();
  int secAgo(int s) =>
      now.subtract(Duration(seconds: s)).millisecondsSinceEpoch ~/ 1000;

  final channels = <ChannelEntry>[
    ChannelEntry(channel: 'nymchat'),
    ChannelEntry(channel: 'bitcoin'),
    ChannelEntry(channel: 'dev'),
    ChannelEntry(channel: '9q8y', geohash: '9q8y'),
  ];

  final users = <String, User>{
    _selfPubkey: User(
      pubkey: _selfPubkey,
      nym: _selfNym,
      status: UserStatus.online,
      lastSeen: now.millisecondsSinceEpoch,
    ),
    _pkSatoshi: User(
      pubkey: _pkSatoshi,
      nym: 'satoshi#beef',
      status: UserStatus.online,
      lastSeen: now.millisecondsSinceEpoch,
    ),
    _pkNeo: User(
      pubkey: _pkNeo,
      nym: 'neo#3c4d',
      status: UserStatus.online,
      lastSeen: now.millisecondsSinceEpoch,
    ),
    _pkTrinity: User(
      pubkey: _pkTrinity,
      nym: 'trinity#99ff',
      status: UserStatus.away,
      lastSeen:
          now.subtract(const Duration(minutes: 12)).millisecondsSinceEpoch,
      awayMessage: 'afk',
    ),
    _pkOracle: User(
      pubkey: _pkOracle,
      nym: 'oracle#5e6f',
      status: UserStatus.offline,
      lastSeen: now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch,
    ),
    _pkBot: User(
      pubkey: _pkBot,
      nym: 'nymbot#0b07',
      status: UserStatus.online,
      lastSeen: now.millisecondsSinceEpoch,
    ),
  };

  final pms = <PMConversation>[
    PMConversation(
      pubkey: _pkSatoshi,
      nym: 'satoshi#beef',
      lastMessageTime:
          now.subtract(const Duration(minutes: 4)).millisecondsSinceEpoch,
    ),
    PMConversation(
      pubkey: _pkNeo,
      nym: 'neo#3c4d',
      lastMessageTime:
          now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
    ),
  ];

  final groups = <Group>[
    Group(
      id: 'aaaa0000000000000000000000000000000000000000000000000000group01',
      name: 'flutter-rewrite',
      members: [_selfPubkey, _pkNeo, _pkTrinity],
      createdBy: _selfPubkey,
      lastMessageTime:
          now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch,
    ),
  ];

  int seq = 0;
  Message msg({
    required String id,
    required String pubkey,
    required String author,
    required String content,
    required int createdAt,
    bool isOwn = false,
    bool isPM = false,
    bool isGroup = false,
    bool isBot = false,
    String? channel,
    String? geohash,
    String? conversationKey,
    String? conversationPubkey,
    DeliveryStatus deliveryStatus = DeliveryStatus.sent,
    bool isEdited = false,
  }) {
    return Message(
      id: id,
      pubkey: pubkey,
      author: author,
      content: content,
      createdAt: createdAt,
      seq: seq++,
      isOwn: isOwn,
      isPM: isPM,
      isGroup: isGroup,
      isBot: isBot,
      channel: channel,
      geohash: geohash,
      conversationKey: conversationKey,
      conversationPubkey: conversationPubkey,
      deliveryStatus: deliveryStatus,
      isEdited: isEdited,
      senderVerified: true,
    );
  }

  final nymchatMsgs = <Message>[
    msg(
      id: 'm01',
      pubkey: _pkSatoshi,
      author: 'satoshi#beef',
      channel: 'nymchat',
      content: 'gm everyone — the native Flutter shell is looking sharp today',
      createdAt: secAgo(60 * 18),
    ),
    msg(
      id: 'm02',
      pubkey: _pkNeo,
      author: 'neo#3c4d',
      channel: 'nymchat',
      content: 'wake up… the messenger has you 🐇',
      createdAt: secAgo(60 * 16),
    ),
    msg(
      id: 'm03',
      pubkey: _selfPubkey,
      author: _selfNym,
      channel: 'nymchat',
      content: 'pixel-matching the IRC layout to the PWA right now',
      createdAt: secAgo(60 * 15),
      isOwn: true,
    ),
    msg(
      id: 'm04',
      pubkey: _pkTrinity,
      author: 'trinity#99ff',
      channel: 'nymchat',
      content:
          '> pixel-matching the IRC layout to the PWA right now\nboth bubble and IRC modes? nice.',
      createdAt: secAgo(60 * 14),
    ),
    msg(
      id: 'm05',
      pubkey: _pkSatoshi,
      author: 'satoshi#beef',
      channel: 'nymchat',
      content:
          'here is the wire shape:\n```dart\nfinal wire = channelWire(key);\nevent.kind = wire.kind; // 20000 | 23333\n```',
      createdAt: secAgo(60 * 12),
    ),
    msg(
      id: 'm06',
      pubkey: _pkNeo,
      author: 'neo#3c4d',
      channel: 'nymchat',
      content: '🔥🔥🔥',
      createdAt: secAgo(60 * 11),
    ),
    msg(
      id: 'm07',
      pubkey: _selfPubkey,
      author: _selfNym,
      channel: 'nymchat',
      content: 'shipping the shell, relay layer plugs in next',
      createdAt: secAgo(60 * 3),
      isOwn: true,
    ),
    msg(
      id: 'm08',
      pubkey: _selfPubkey,
      author: _selfNym,
      channel: 'nymchat',
      content: 'then PMs and groups over NIP-17',
      createdAt: secAgo(60 * 3 - 20),
      isOwn: true,
    ),
  ];

  final geoMsgs = <Message>[
    msg(
      id: 'g01',
      pubkey: _pkOracle,
      author: 'oracle#5e6f',
      geohash: '9q8y',
      content: 'anyone around the bay? 37.77°N, 122.41°W',
      createdAt: secAgo(60 * 40),
    ),
    msg(
      id: 'g02',
      pubkey: _pkNeo,
      author: 'neo#3c4d',
      geohash: '9q8y',
      content: 'right here. geohash channels are wild',
      createdAt: secAgo(60 * 22),
    ),
    msg(
      id: 'g03',
      pubkey: _selfPubkey,
      author: _selfNym,
      geohash: '9q8y',
      content: 'local-first social. love it 🌉',
      createdAt: secAgo(60 * 5),
      isOwn: true,
    ),
  ];

  final bitcoinMsgs = <Message>[
    msg(
      id: 'b01',
      pubkey: _pkSatoshi,
      author: 'satoshi#beef',
      channel: 'bitcoin',
      content: 'running bitcoin',
      createdAt: secAgo(60 * 90),
    ),
    msg(
      id: 'b02',
      pubkey: _pkBot,
      author: 'nymbot#0b07',
      channel: 'bitcoin',
      content: 'block height looks healthy ⚡',
      createdAt: secAgo(60 * 50),
      isBot: true,
    ),
  ];

  final devMsgs = <Message>[
    msg(
      id: 'd01',
      pubkey: _pkNeo,
      author: 'neo#3c4d',
      channel: 'dev',
      content: 'who owns the messages_list widget?',
      createdAt: secAgo(60 * 33),
    ),
    msg(
      id: 'd02',
      pubkey: _selfPubkey,
      author: _selfNym,
      channel: 'dev',
      content: 'me — IRC + bubble in one row builder',
      createdAt: secAgo(60 * 31),
      isOwn: true,
    ),
  ];

  final pmKeySat = 'pm-$_pkSatoshi';
  final pmSat = <Message>[
    msg(
      id: 'pm01',
      pubkey: _pkSatoshi,
      author: 'satoshi#beef',
      content: 'hey, can you review the gift-wrap envelope?',
      createdAt: secAgo(60 * 30),
      isPM: true,
      conversationKey: pmKeySat,
      conversationPubkey: _pkSatoshi,
    ),
    msg(
      id: 'pm02',
      pubkey: _selfPubkey,
      author: _selfNym,
      content: 'on it — NIP-17 rumor → seal → wrap, right?',
      createdAt: secAgo(60 * 28),
      isOwn: true,
      isPM: true,
      conversationKey: pmKeySat,
      conversationPubkey: _pkSatoshi,
      deliveryStatus: DeliveryStatus.read,
    ),
    msg(
      id: 'pm03',
      pubkey: _pkSatoshi,
      author: 'satoshi#beef',
      content: 'exactly. fresh ephemeral key per wrap.',
      createdAt: secAgo(60 * 5),
      isPM: true,
      conversationKey: pmKeySat,
      conversationPubkey: _pkSatoshi,
    ),
    msg(
      id: 'pm04',
      pubkey: _selfPubkey,
      author: _selfNym,
      content: 'shipping the delivery ticks too ✓✓',
      createdAt: secAgo(60 * 4),
      isOwn: true,
      isPM: true,
      conversationKey: pmKeySat,
      conversationPubkey: _pkSatoshi,
      deliveryStatus: DeliveryStatus.delivered,
    ),
  ];

  final pmKeyNeo = 'pm-$_pkNeo';
  final pmNeo = <Message>[
    msg(
      id: 'pn01',
      pubkey: _pkNeo,
      author: 'neo#3c4d',
      content: 'follow the white rabbit',
      createdAt: secAgo(60 * 60),
      isPM: true,
      conversationKey: pmKeyNeo,
      conversationPubkey: _pkNeo,
    ),
  ];

  final groupId = groups.first.id;
  final groupKey = 'group-$groupId';
  final groupMsgs = <Message>[
    msg(
      id: 'gr01',
      pubkey: _pkTrinity,
      author: 'trinity#99ff',
      content: 'sidebar sections collapsing cleanly now',
      createdAt: secAgo(60 * 35),
      isGroup: true,
      conversationKey: groupKey,
    ),
    msg(
      id: 'gr02',
      pubkey: _selfPubkey,
      author: _selfNym,
      content: 'nice. composer SEND wired for local echo',
      createdAt: secAgo(60 * 30),
      isOwn: true,
      isGroup: true,
      conversationKey: groupKey,
      deliveryStatus: DeliveryStatus.delivered,
    ),
  ];

  final messages = <String, List<Message>>{
    '#nymchat': nymchatMsgs,
    '#9q8y': geoMsgs,
    '#bitcoin': bitcoinMsgs,
    '#dev': devMsgs,
    pmKeySat: pmSat,
    pmKeyNeo: pmNeo,
    groupKey: groupMsgs,
  };

  final reactions = <String, List<MessageReaction>>{
    'm02': const [MessageReaction(emoji: '🐇', count: 3)],
    'm05': const [
      MessageReaction(emoji: '👍', count: 5, userReacted: true),
      MessageReaction(emoji: '🤯', count: 2),
    ],
    'm06': const [MessageReaction(emoji: '🔥', count: 7, userReacted: true)],
    'g02': const [MessageReaction(emoji: '🌍', count: 2)],
  };

  final unread = <String, int>{
    'bitcoin': 3,
    'dev': 1,
    _pkNeo: 2,
  };

  return AppState(
    selfPubkey: _selfPubkey,
    selfNym: _selfNym,
    channels: channels,
    pmConversations: pms,
    groups: groups,
    users: users,
    messages: messages,
    reactions: reactions,
    unreadCounts: unread,
    view: const ChatView.channel('nymchat'),
    // Demo authors are seeded into the trust graph so the spam gate doesn't hide the sample messages.
    nymchatPubkeys: {
      ...kTrustRootPubkeys,
      _pkSatoshi,
      _pkNeo,
      _pkTrinity,
      _pkOracle,
      _pkBot,
    },
  );
}

class AppStateNotifier extends StateNotifier<AppState> {
  // Starts as the empty logged-out shell, not the demo seed; the controller swaps to live on boot.
  AppStateNotifier() : super(AppState.empty());

  /// Fired when a conversation opens so the controller can backfill its D1 history.
  void Function(ChatView view)? onViewOpened;

  /// Fired after a PM/group message is inserted so the controller can flush its cache.
  void Function(String storageKey)? onPmMessageIngested;

  bool Function(Message m, List<Message> list)? absorbLiveHook;

  void Function(String groupId, List<Message> list, String sender)?
      slowmodeHook;

  void Function(Message m, String newContent, int editAt)? onBeforeEdit;

  void Function(Message m, String text, int editAt)? onStaleEdit;

  /// Fired when a new PM row is created so the critical REQ starts watching the contact's profile.
  void Function(String peerPubkey)? onPMConversationAdded;

  /// Fired when the closed-PM set changes so deleted PMs stay deleted across relaunches.
  void Function()? onClosedPmsChanged;

  /// Fired when the read watermark changes so it is persisted and backfill isn't re-counted as unread.
  void Function()? onChannelReadChanged;

  /// Fired on any group store mutation to drive the debounced cross-device group sync.
  void Function()? onGroupStoreChanged;

  void Function(String groupId, List<String> evicted)? onGroupMembersEvicted;

  void _reportEvicted(String groupId, List<String> evicted) {
    if (evicted.isNotEmpty) onGroupMembersEvicted?.call(groupId, evicted);
  }

  /// Storage key → last-read created_at (sec); only newer messages bump the unread badge.
  final Map<String, int> _channelLastRead = <String, int>{};

  Map<String, int> get channelLastRead => Map.unmodifiable(_channelLastRead);

  /// Fired when a watermark advances so matching notifications are marked seen.
  void Function(String key, int tsSec)? onChannelReadMarked;

  /// Records that [key] was read up to [tsSec], keeping the max.
  void markChannelRead(String key, int tsSec) {
    if (key.isEmpty || tsSec <= 0) return;
    final cur = _channelLastRead[key] ?? 0;
    if (tsSec <= cur) return;
    _channelLastRead[key] = tsSec;
    _dropReadUnread(key, tsSec);
    onChannelReadChanged?.call();
    onChannelReadMarked?.call(key, tsSec);
    onNavReadMarked?.call(key, tsSec);
  }

  void Function(String key, int tsSec)? onNavReadMarked;

  void Function(String fromKey, String toKey, bool columns)? onViewEntering;

  bool Function(ChatView from, ChatView to)? viewGate;

  void _dropReadUnread(String key, int tsSec) {
    final cur = state.unreadCounts[key] ?? 0;
    if (cur <= 0) return;
    final msgs = state.messages[key] ?? const <Message>[];
    final covered = msgs.any((x) => x.createdAt <= tsSec);
    if (!covered) return;
    final left = msgs
        .where((x) =>
            x.createdAt > tsSec && !x.isOwn && state.countsTowardUnread(x))
        .length;
    if (left >= cur) return;
    if (left > 0) {
      state.unreadCounts[key] = left;
    } else {
      state.unreadCounts.remove(key);
    }
    _scheduleEmit();
  }

  void hydrateChannelLastRead(Map<String, int> m) {
    m.forEach((k, v) {
      if (v > (_channelLastRead[k] ?? 0)) _channelLastRead[k] = v;
    });
  }

  /// True when [m] is newer than its conversation's read watermark.
  bool _isUnreadByWatermark(String key, Message m) =>
      m.createdAt > (_channelLastRead[key] ?? 0);

  /// Columns-mode read gate: true only when the key's column is focused, at the bottom, and the app is visible.
  bool Function(String storageKey)? columnsReadGate;

  /// The open thread, wired by the UI; unwired reads as no thread open.
  ActiveThread? Function()? openThreadGate;

  /// True when a new message for [storageKey] is already seen (active view, or columns gate passes).
  bool _isConversationSeen(String storageKey) {
    final gate = columnsReadGate;
    if (gate != null) return gate(storageKey);
    return appVisible && storageKey == state.view.storageKey;
  }

  bool appVisible = true;

  void setAppVisible(bool visible) {
    appVisible = visible;
  }

  bool isConversationSeen(String storageKey) => _isConversationSeen(storageKey);

  /// Replies collapsed behind a hidden thread must not advance the read watermark, or their mentions land pre-viewed.
  bool _hiddenThreadReply(String storageKey, Message m) => threadReplyHidden(
        state: state,
        openThread: openThreadGate?.call(),
        storageKey: storageKey,
        threadRoot: m.threadRoot,
      );

  /// Clears [key]'s unread badge and stamps its read watermark to max(now, newest message).
  void clearUnread(String key) {
    if (key.isEmpty) return;
    var lastTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final msgs = state.messages[key];
    if (msgs != null) {
      for (final m in msgs) {
        if (m.createdAt > lastTs) lastTs = m.createdAt;
      }
    }
    // Badges may be bucketed under the storage key or the bare id, so clear both.
    String? alt;
    if (key.startsWith('pm-')) {
      alt = key.substring(3);
    } else if (key.startsWith('group-')) {
      alt = key.substring(6);
    } else if (key.startsWith('#')) {
      alt = key.substring(1);
    }
    var removed = state.unreadCounts.remove(key) != null;
    if (alt != null && state.unreadCounts.remove(alt) != null) removed = true;
    markChannelRead(key, lastTs);
    if (alt != null) markChannelRead(alt, lastTs);
    // Ambient: unread badges render only in the sidebar, so clearing must not rebuild the conversation.
    if (removed) runAmbient(_scheduleEmit);
  }

  /// Clears unread for every column the [columnsReadGate] passes, when the app returns to the foreground.
  void markVisibleColumnsRead() {
    final gate = columnsReadGate;
    if (gate == null) {
      final key = state.view.storageKey;
      if (!appVisible || key.isEmpty) return;
      if ((state.unreadCounts[key] ?? 0) > 0 ||
          (state.unreadCounts[state.view.id] ?? 0) > 0) {
        clearUnread(_unreadStorageKey(key));
      }
      return;
    }
    // Snapshot because `clearUnread` mutates; bare ids are resolved to storage keys so both buckets clear.
    for (final key in state.unreadCounts.keys.toList()) {
      if (gate(key)) clearUnread(_unreadStorageKey(key));
    }
  }

  /// Resolves a storage key or bare id to the storage key [clearUnread] derives its buckets from.
  String _unreadStorageKey(String key) {
    if (key.startsWith('#') ||
        key.startsWith('pm-') ||
        key.startsWith('group-')) {
      return key;
    }
    if (state.messages.containsKey('pm-$key') || state.users.containsKey(key)) {
      return 'pm-$key';
    }
    if (state.messages.containsKey('group-$key') ||
        state.groups.any((g) => g.id == key)) {
      return 'group-$key';
    }
    return '#$key';
  }

  /// Clears the session dedup sets so a restore after a cache wipe isn't dropped as duplicates.
  void clearSessionDedup() {
    _seenIds.clear();
    _seenNymMessageIds.clear();
    _deletedEventIds.clear();
    _pendingDeletions.clear();
    // Dropped in lockstep with the caller's `messages` wipe.
    _msgByAnyId.clear();
    _convKeyByAnyId.clear();
  }

  int _localSeq = 1000000;
  int _ingestSeq = 1;
  final Set<String> _seenIds = <String>{};

  /// nymMessageIds already ingested; wrap ids differ per recipient copy.
  final Set<String> _seenNymMessageIds = <String>{};

  /// Edits that arrived before their original: originalId → editor pubkey → new content (capped).
  final Map<String, Map<String, String>> _pendingEdits =
      <String, Map<String, String>>{};

  final Map<String, int> _pendingEditAt = <String, int>{};

  final Map<String, EditCandidate> _editHeads = <String, EditCandidate>{};

  final Map<String, List<EditCandidate>> _staleEdits =
      <String, List<EditCandidate>>{};

  /// PM peers the user closed; their older backlog is ignored.
  final Set<String> _closedPMs = <String>{};

  /// peer → close time (sec); only a strictly newer message re-opens the thread.
  final Map<String, int> _closedPMTimes = <String, int>{};

  final Set<String> _leftGroups = <String>{};

  /// group id → leave time (sec); only a strictly newer re-invite/add/unban resurrects the group.
  final Map<String, int> _leftGroupTimes = <String, int>{};

  /// Per-session nonce so optimistic ids are never reused across launches and stale keys can't re-attach.
  final String _sessionNonce = () {
    final r = Random.secure();
    return List.generate(
        4, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }();

  int _nextLocalSeq() => _localSeq++;
  int _nextIngestSeq() => _ingestSeq++;

  Set<String> get closedPMs => _closedPMs;

  /// The leave time (sec) for [groupId], or 0 if never left.
  int leftGroupTime(String groupId) => _leftGroupTimes[groupId] ?? 0;

  bool isLeftGroup(String groupId) => _leftGroups.contains(groupId);

  /// Clears the left mark so a re-invite can resurrect the group; with [createdAtSec], only if newer than the leave.
  bool clearLeftGroup(String groupId, {int? createdAtSec}) {
    if (!_leftGroups.contains(groupId)) return true;
    if (createdAtSec != null &&
        createdAtSec <= (_leftGroupTimes[groupId] ?? 0)) {
      return false;
    }
    _leftGroups.remove(groupId);
    _leftGroupTimes.remove(groupId);
    return true;
  }

  /// Switches to a live, identity-backed empty state once an identity boots.
  void goLive(String pubkey, String nym) {
    _seenIds.clear();
    _seenNymMessageIds.clear();
    _pendingEdits.clear();
    _editHeads.clear();
    _staleEdits.clear();
    _closedPMs.clear();
    _closedPMTimes.clear();
    _leftGroups.clear();
    _leftGroupTimes.clear();
    _reactors.clear();
    _reactionLastAction.clear();
    _channelMessageReaders.clear();
    _pendingPmReceipts.clear();
    _processedPollVoteIds.clear();
    _pendingPollVotes.clear();
    _pendingDeletions.clear();
    _msgByAnyId.clear();
    _convKeyByAnyId.clear();
    state = AppState.live(pubkey, nym);
    state.nymchatPubkeys.addAll(kTrustRootPubkeys);
    // Seeds Nymbot with its brand avatar and an always-online status so every surface renders it consistently.
    state.users[kNymbotPubkey] = VerifiedBotUser(
      pubkey: kNymbotPubkey,
      nym: 'Nymbot',
      status: UserStatus.online,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
      profile: UserProfile(
        picture: kNymbotAvatarAsset,
        banner: kNymbotBannerAsset,
      ),
    );
  }

  /// Resets to the empty logged-out shell, clearing all session-scoped dedup and private maps.
  void reset() {
    _seenIds.clear();
    _seenNymMessageIds.clear();
    _pendingEdits.clear();
    _editHeads.clear();
    _staleEdits.clear();
    _closedPMs.clear();
    _closedPMTimes.clear();
    _leftGroups.clear();
    _leftGroupTimes.clear();
    _reactors.clear();
    _reactionLastAction.clear();
    _channelMessageReaders.clear();
    _pendingPmReceipts.clear();
    _processedPollVoteIds.clear();
    _pendingPollVotes.clear();
    _pendingDeletions.clear();
    // NIP-09 memory goes too: the on-disk copy was wiped or belongs to the departing identity.
    _deletedEventIds.clear();
    _msgByAnyId.clear();
    _convKeyByAnyId.clear();
    state = AppState.empty();
  }

  void setIdentity(String pubkey, String nym) {
    state = state.copyWith(selfPubkey: pubkey, selfNym: nym);
  }

  void setConnectedRelays(int count) {
    if (count == state.connectedRelays) return;
    state = state.copyWith(connectedRelays: count);
  }

  void setProxyMode(bool proxy) {
    if (proxy == state.proxyMode) return;
    state = state.copyWith(proxyMode: proxy);
  }

  // Web of trust ("nym-vouch").

  /// Adds [pubkey] to the trust graph; returns true when newly added.
  bool markNymchatPubkey(String pubkey) {
    final added = TrustGraph.add(
      state.nymchatPubkeys,
      pubkey,
      selfPubkey: state.selfPubkey,
    );
    if (added) _scheduleEmit();
    return added;
  }

  /// Records [pubkey] in our own vouch list; returns true when newly added; doesn't notify listeners.
  bool observeNymchatPubkey(String pubkey) {
    return TrustGraph.add(
      state.nymchatVouches,
      pubkey,
      selfPubkey: state.selfPubkey,
    );
  }

  /// Ingests a peer's vouch list, honored only if [authorPubkey] is already trusted; true when something new was added.
  bool ingestVouchList({
    required String authorPubkey,
    required List<String> vouchedPubkeys,
  }) {
    if (authorPubkey.isEmpty || authorPubkey == state.selfPubkey) return false;
    // Rooted trust: a stranger can't inject vouches.
    if (!state.nymchatPubkeys.contains(authorPubkey)) return false;
    var added = false;
    for (final pk in vouchedPubkeys) {
      if (pk == state.selfPubkey) continue;
      if (TrustGraph.add(state.nymchatPubkeys, pk,
          selfPubkey: state.selfPubkey)) {
        added = true;
      }
    }
    if (added) _scheduleEmit();
    return added;
  }

  /// Counts a message toward earned trust (two distinct messages); true when [pubkey] just became trusted.
  bool trackPubkeyMessage(String pubkey, String eventId) {
    if (pubkey.isEmpty || eventId.isEmpty) return false;
    if (state.trustedPubkeys.contains(pubkey)) return false;
    final ids = _pubkeyMsgIds.putIfAbsent(pubkey, () => <String>{});
    if (_pubkeyMsgIds.length > 20000) {
      _pubkeyMsgIds.remove(_pubkeyMsgIds.keys.first);
    }
    ids.add(eventId);
    if (ids.length >= 2) {
      _pubkeyMsgIds.remove(pubkey);
      state.trustedPubkeys.add(pubkey);
      if (state.trustedPubkeys.length > 50000) {
        state.trustedPubkeys.remove(state.trustedPubkeys.first);
      }
      _scheduleEmit();
      return true;
    }
    return false;
  }

  /// Loads persisted web-of-trust sets on boot, additive over the seeded roots.
  void hydrateTrustSets(
    Set<String> pubkeys,
    Set<String> vouches,
    Set<String> trusted,
  ) {
    if (pubkeys.isEmpty && vouches.isEmpty && trusted.isEmpty) return;
    state.nymchatPubkeys.addAll(pubkeys);
    state.nymchatVouches.addAll(vouches);
    state.trustedPubkeys.addAll(trusted);
    _scheduleEmit();
  }

  /// pubkey → distinct message ids seen this session until trust is earned (capped at 20000 senders).
  final Map<String, Set<String>> _pubkeyMsgIds = {};

  /// messageId → emoji → reactor pubkey → nym; [AppState.reactions] is derived from this.
  final Map<String, Map<String, Map<String, String>>> _reactors = {};

  /// `messageId:emoji:pubkey` → last action ts (sec); latest action wins on out-of-order delivery.
  final Map<String, int> _reactionLastAction = {};

  /// Channel read receipts: message id → reader pubkey → nym, kept separately so early receipts can replay.
  final Map<String, Map<String, String>> _channelMessageReaders = {};

  /// Live-only PM/group receipts that beat their own message's restore, keyed by nymMessageId, replayed on index.
  final Map<String, DeliveryStatus> _pendingPmReceipts = {};

  /// Dedup set for poll-vote events (capped at 3000).
  final Set<String> _processedPollVoteIds = {};

  /// Votes that arrived before their poll.
  final Map<String, List<PollVote>> _pendingPollVotes = {};

  Set<String> get processedPollVoteIds => _processedPollVoteIds;

  // Coalesced emission.

  /// Depth of the current [runBatched] scope; nested batches flush with the outermost.
  int _batchDepth = 0;
  bool _pendingEmit = false;

  /// Lists that need one sort at batch flush; only populated while batching.
  final Set<String> _dirtySortKeys = <String>{};

  /// Bumped by every [_scheduleEmit]; ambient emits leave it alone.
  int _displayRev = 0;

  /// When > 0 the current emit is ambient and must not advance [_displayRev].
  int _ambientDepth = 0;

  /// Notifies listeners now, or at the end of the enclosing [runBatched].
  void _scheduleEmit() {
    if (_ambientDepth == 0) _displayRev++;
    if (_batchDepth > 0) {
      _pendingEmit = true;
      return;
    }
    _emitNow();
  }

  void _emitNow() {
    final next = state.copyWith(displayRev: _displayRev);
    state = next;
  }

  /// Emits without advancing [AppState.displayRev]; use only for changes the message list never renders.
  T runAmbient<T>(T Function() body) {
    _ambientDepth++;
    try {
      return body();
    } finally {
      _ambientDepth--;
    }
  }

  /// Coalesces notifies and sorts in [body] into one emit; [body] must be synchronous.
  T runBatched<T>(T Function() body) {
    _batchDepth++;
    try {
      return body();
    } finally {
      _batchDepth--;
      if (_batchDepth == 0) {
        _flushDirtySorts();
        if (_pendingEmit) {
          _pendingEmit = false;
          _emitNow();
        }
      }
    }
  }

  void ingestEvents(Iterable<NostrEvent> events) {
    runBatched(() {
      for (final e in events) {
        try {
          ingestEvent(e);
        } catch (_) {
          // Skip a malformed event; never abort the batch.
        }
      }
    });
  }

  /// Keeps [list] sorted: binary insertion live, one deferred sort inside a batch.
  void _insertMessageSorted(String key, List<Message> list, Message m) {
    _indexMessage(key, m);
    if (_batchDepth > 0) {
      list.add(m);
      _dirtySortKeys.add(key);
      return;
    }
    var lo = 0;
    var hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (compareMessages(list[mid], m) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    list.insert(lo, m);
  }

  /// Channel keys to re-cap once the batch's deferred sort restores order.
  final Set<String> _channelCapPending = <String>{};

  /// Channel history is a rolling 24-hour window; set by [NostrController], null in tests.
  void Function()? onAgedChannelMessage;

  void Function(String pubkey, int untilMs)? onAutoMuted;

  Set<String> pruneChannelHistoryWindow() {
    final floor = channelWindowFloorSec();
    final dropped = <String>{};
    for (final entry in state.messages.entries) {
      final key = entry.key;
      if (key.startsWith('pm-') || key.startsWith('group-')) continue;
      final list = entry.value;
      if (list.isEmpty || !list.any((m) => m.createdAt < floor)) continue;

      // Keep thread roots so in-window replies don't reflow inline.
      final keep = <Message>[];
      final wanted = <String>{};
      for (final m in list) {
        if (m.createdAt < floor) continue;
        keep.add(m);
        final root = m.threadRoot;
        if (root != null && root.isNotEmpty) wanted.add(root);
      }
      for (final m in keep) {
        wanted.remove(threadKeyForMessage(m));
      }
      final pinned = <Message>[];
      for (final m in list) {
        if (m.createdAt >= floor) continue;
        if (wanted.isNotEmpty && wanted.remove(threadKeyForMessage(m))) {
          pinned.add(m);
        } else {
          dropped.add(m.id);
          final shared = m.nymMessageId;
          if (shared != null && shared.isNotEmpty) dropped.add(shared);
          _unindexMessage(m);
          state.reactions.remove(m.id);
        }
      }
      list
        ..clear()
        ..addAll(pinned)
        ..addAll(keep);
    }
    if (dropped.isNotEmpty) _scheduleEmit();
    return dropped;
  }

  /// Trims a channel to the newest [_kChannelHistoryCap] messages; [list] must be oldest-first.
  void _capChannelHistory(List<Message> list) {
    if (list.length <= _kChannelHistoryCap) return;
    final drop = list.length - _kChannelHistoryCap;
    // Keep thread roots the window still references, or their replies reflow inline with a dead-end thread.
    final wanted = <String>{};
    for (var i = drop; i < list.length; i++) {
      final root = list[i].threadRoot;
      if (root != null && root.isNotEmpty) wanted.add(root);
    }
    for (var i = drop; i < list.length && wanted.isNotEmpty; i++) {
      wanted.remove(threadKeyForMessage(list[i]));
    }
    final pinned = <Message>[];
    for (var i = 0; i < drop; i++) {
      final m = list[i];
      if (wanted.isNotEmpty && wanted.remove(threadKeyForMessage(m))) {
        pinned.add(m);
      } else {
        _unindexMessage(m);
      }
    }
    list.replaceRange(0, drop, pinned);
  }

  // Message id index: event id and nymMessageId → message; stale entries only cost memory, never a wrong match.
  final Map<String, Message> _msgByAnyId = <String, Message>{};
  final Map<String, String> _convKeyByAnyId = <String, String>{};

  /// Indexes [m]'s event id and nymMessageId against [convKey]; idempotent.
  void _indexMessage(String convKey, Message m) {
    if (m.id.isNotEmpty) {
      _msgByAnyId[m.id] = m;
      _convKeyByAnyId[m.id] = convKey;
    }
    final nid = m.nymMessageId;
    if (nid != null && nid.isNotEmpty) {
      _msgByAnyId[nid] = m;
      _convKeyByAnyId[nid] = convKey;
      // Replay receipts that arrived before this own message was indexed.
      if (m.isOwn && _pendingPmReceipts.isNotEmpty) {
        final pending = _pendingPmReceipts.remove(nid.toLowerCase());
        if (pending != null &&
            PmLogic.statusOrder(pending) >
                PmLogic.statusOrder(m.deliveryStatus)) {
          m.deliveryStatus = pending;
        }
      }
    }
  }

  /// The stored message for its event/wrap id or shared nymMessageId, or null.
  Message? messageById(String id) => id.isEmpty ? null : _msgByAnyId[id];

  /// Drops [m]'s index entries only while they still point at [m].
  void _unindexMessage(Message m) {
    if (m.id.isNotEmpty && identical(_msgByAnyId[m.id], m)) {
      _msgByAnyId.remove(m.id);
      _convKeyByAnyId.remove(m.id);
    }
    final nid = m.nymMessageId;
    if (nid != null && nid.isNotEmpty && identical(_msgByAnyId[nid], m)) {
      _msgByAnyId.remove(nid);
      _convKeyByAnyId.remove(nid);
    }
  }

  /// Drops lingering failed optimistic twins of [content] once a copy is reconciled as sent; returns true if any removed.
  bool _dropFailedOptimisticTwins(
      List<Message> list, String content, Message keep) {
    var removed = false;
    for (var i = list.length - 1; i >= 0; i--) {
      final ex = list[i];
      if (identical(ex, keep)) continue;
      if (ex.id.startsWith('_optim_') &&
          ex.deliveryStatus == DeliveryStatus.failed &&
          ex.content == content) {
        _unindexMessage(ex);
        list.removeAt(i);
        removed = true;
      }
    }
    return removed;
  }

  /// Sorts lists touched out of order during a batch, then re-caps overgrown channels.
  void _flushDirtySorts() {
    if (_dirtySortKeys.isNotEmpty) {
      for (final key in _dirtySortKeys) {
        state.messages[key]?.sort(compareMessages);
      }
      _dirtySortKeys.clear();
    }
    if (_channelCapPending.isNotEmpty) {
      for (final key in _channelCapPending) {
        final list = state.messages[key];
        if (list != null) _capChannelHistory(list);
      }
      _channelCapPending.clear();
    }
  }

  /// Routes a verified inbound event into the store; [historical] marks a replayed backlog restore by provenance.
  void ingestEvent(NostrEvent e, {bool historical = false}) {
    switch (e.kind) {
      case EventKind.geoChannel:
      case EventKind.namedChannel:
        _ingestChannelMessage(e, historical: historical);
      case EventKind.profile:
        _ingestProfile(e);
      case EventKind.reaction:
        _ingestReaction(e);
      case EventKind.zapReceipt:
        ingestZapReceipt(e);
      case EventKind.deletion:
        ingestDeletionEvent(e);
      case EventKind.appData:
        if (PollLogic.isPollEvent(e)) {
          ingestPoll(e);
        } else if (PollLogic.isPollVoteEvent(e)) {
          ingestPollVote(e);
        }
    }
  }

  void _ingestChannelMessage(NostrEvent e, {bool historical = false}) {
    if (e.id.isNotEmpty && !_seenIds.add(e.id)) return;
    appAttestRegistry.ingest(e, appAttestAuthority);
    if (!passesVerifiedFilter(e.pubkey,
        selfPubkey: state.selfPubkey, friends: state.friends)) {
      return;
    }
    // NIP-13 inbound exclusion for public channel messages; Nymbot is exempt because it doesn't mine.
    if (appPowFilterBits > 0 &&
        !kVerifiedBotPubkeys.contains(e.pubkey) &&
        validatedPowBits(e.tags, e.id) < appPowFilterBits) {
      return;
    }
    if (state.clientGatesActive &&
        e.pubkey != state.selfPubkey &&
        state.isAutoMuted(e.pubkey)) {
      return;
    }
    if (state.clientGatesActive &&
        e.pubkey != state.selfPubkey &&
        !state.friends.contains(e.pubkey) &&
        !kVerifiedBotPubkeys.contains(e.pubkey)) {
      final verdict = crossContentFlood.check(e.content, e.pubkey,
          createdAtMs: e.createdAt * 1000);
      if (verdict.mute) {
        autoMuteUser(e.pubkey);
      }
      if (verdict.flood || verdict.mute) return;
    }
    // Incoming edits rewrite the original in place; out-of-order edits are buffered.
    final editId = e.tagValue('edit');
    if (editId != null && editId.isNotEmpty) {
      applyEditOrDefer(editId, e.content,
          editorPubkey: e.pubkey, editAt: e.createdAt, editId: e.id);
      return;
    }
    // `nymmesh` tag marks a relay replay of a mesh message; registering its id drops whichever copy arrives second.
    final meshReplayId = e.tagValue('nymmesh');
    if (meshReplayId != null &&
        meshReplayId.isNotEmpty &&
        !_seenIds.add(meshReplayId)) {
      return;
    }
    final m = EventMapper.channelMessage(e, selfPubkey: state.selfPubkey);
    if (m == null) return;
    // Stripped on the render model only; the signed event keeps what was published.
    m.content = SpamFilter.stripMaliciousDomains(m.content);
    // Already outside the 24-hour window, so request the sweep now.
    if (m.createdAt < channelWindowFloorSec()) onAgedChannelMessage?.call();
    // A backlog restore is historical by provenance, even if its timestamp reads as now.
    if (historical) m.isHistorical = true;
    // NIP-09: drop messages already deleted or matched by a parked deletion.
    if (suppressDeletedMessage(m)) return;
    final key = EventMapper.channelKeyOf(e);
    if (key == null) return;
    m.seq = _ingestSeq++;

    final list = state.messages.putIfAbsent(key, () => <Message>[]);

    // Reconcile our own optimistic placeholder with its relay echo in place, preferring a live row over a failed one.
    var matchIdx = -1;
    for (var i = 0; i < list.length; i++) {
      final ex = list[i];
      if ((ex.optimistic || ex.id.startsWith('_optim_')) &&
          ex.pubkey == m.pubkey &&
          ex.content == m.content &&
          (ex.createdAt - m.createdAt).abs() < 60) {
        if (ex.deliveryStatus != DeliveryStatus.failed) {
          matchIdx = i;
          break;
        }
        if (matchIdx < 0) {
          matchIdx = i;
        }
      }
    }
    if (matchIdx >= 0) {
      final ex = list[matchIdx];
      _unindexMessage(ex);
      final placeholderId = ex.id;
      ex.id = m.id;
      ex.optimistic = false;
      ex.deliveryStatus = DeliveryStatus.sent;
      final shifted = ex.createdAt != m.createdAt;
      if (m.createdAt > 0) {
        ex.createdAt = m.createdAt;
        ex.timestamp = m.timestamp;
      }
      if (m.ms > 0) ex.ms = m.ms;
      _indexMessage(key, ex);
      // Carry over reactions filed under the placeholder id.
      _migrateReactionKey(placeholderId, ex.id);
      // Replay read receipts that arrived while the row still had its placeholder id.
      final reconciledReaders = _channelMessageReaders[ex.id];
      if (reconciledReaders != null) {
        _remirrorForReaders(reconciledReaders.keys.toList());
      }
      // A copy landed as sent, so collapse stale failed placeholders of the same content.
      _dropFailedOptimisticTwins(list, ex.content, ex);
      // PoW can shift created_at; re-sort, deferring to the batch sort mid-backfill.
      if (shifted) {
        if (_batchDepth > 0) {
          _dirtySortKeys.add(key);
        } else {
          list.sort(compareMessages);
        }
      }
      // The early return below skips the normal activity bookkeeping; own messages never count toward unread.
      if (m.timestamp > (state.channelLastActivity[key] ?? 0)) {
        state.channelLastActivity[key] = m.timestamp;
      }
      _scheduleEmit();
      return;
    }

    _insertMessageSorted(key, list, m);
    // Mid-batch the list isn't sorted yet, so defer the trim to [_flushDirtySorts].
    if (_batchDepth > 0) {
      _channelCapPending.add(key);
    } else {
      _capChannelHistory(list);
    }

    final u = state.users.putIfAbsent(
      e.pubkey,
      () => User(pubkey: e.pubkey, nym: m.author),
    );
    if (!isPlaceholderNym(m.author)) {
      u.nym = m.author;
    } else {
      _seedAuthorFromStore(m);
    }
    u.lastSeen = m.timestamp;
    // Membership uses the bare lowercase key: geohash when present, else the channel name.
    final memberKey =
        ((m.geohash?.isNotEmpty ?? false) ? m.geohash! : m.channel)
            ?.toLowerCase();
    if (memberKey != null && memberKey.isNotEmpty) u.channels.add(memberKey);

    // Only ever raise last activity, so backfilled history can't sink busy channels.
    final hidden = state.isMessageFiltered(m);
    if (!hidden && m.timestamp > (state.channelLastActivity[key] ?? 0)) {
      state.channelLastActivity[key] = m.timestamp;
    }

    // Surface any channel we receive a message for, unless blocked or hidden.
    final isGeo = (m.geohash ?? '').isNotEmpty;
    final regKey = (isGeo ? m.geohash! : (m.channel ?? '')).toLowerCase();
    if (!hidden &&
        regKey.isNotEmpty &&
        !state.blockedChannels.contains(regKey) &&
        !state.hiddenChannels.contains(regKey) &&
        !state.channels.any((c) => c.key == regKey)) {
      state.channels.add(ChannelEntry(
        channel: m.channel ?? (isGeo ? m.geohash! : regKey),
        geohash: isGeo ? m.geohash! : '',
      ));
    }

    // Bump unread only for unseen messages that count and are newer than the read watermark.
    final seen = _isConversationSeen(key);
    if (!seen && state.countsTowardUnread(m) && _isUnreadByWatermark(key, m)) {
      state.unreadCounts[key] = (state.unreadCounts[key] ?? 0) + 1;
    } else if (seen && columnsReadGate != null && !_hiddenThreadReply(key, m)) {
      // A seen column stays clear, except for replies collapsed inside a thread.
      state.unreadCounts.remove(key);
      markChannelRead(key, m.createdAt);
    }

    // Replay channel read receipts that raced ahead of this message.
    final landedReaders = m.isOwn ? _channelMessageReaders[m.id] : null;
    if (landedReaders != null) {
      // Move readers' avatars onto this newer own message.
      _remirrorForReaders(landedReaders.keys.toList());
    }

    _consumePendingEdit(id: m.id);

    _scheduleEmit();
  }

  /// Kind-0 name fallback chain name → username → display_name, capped at 20 chars.
  static String? _kind0DisplayName(UserProfile p) {
    for (final v in [p.name, p.username, p.displayName]) {
      if (v != null && v.isNotEmpty) {
        return v.length > 20 ? v.substring(0, 20) : v;
      }
    }
    return null;
  }

  final Set<String> _placeholderAuthors = <String>{};

  void _seedAuthorFromStore(Message m) {
    if (!isPlaceholderNym(m.author)) return;
    final known = state.users[m.pubkey]?.nym;
    if (!isPlaceholderNym(known)) {
      m.author = getNymFromPubkey(stripPubkeySuffix(known!), m.pubkey);
      return;
    }
    if (m.pubkey.isEmpty) return;
    _placeholderAuthors.add(m.pubkey);
    if (_placeholderAuthors.length > 5000) {
      _placeholderAuthors.remove(_placeholderAuthors.first);
    }
  }

  bool _rewriteStoredAuthors(String pubkey) {
    if (!_placeholderAuthors.contains(pubkey)) return false;
    final known = state.users[pubkey]?.nym;
    if (isPlaceholderNym(known)) return false;
    final display = getNymFromPubkey(stripPubkeySuffix(known!), pubkey);
    var changed = false;
    for (final list in state.messages.values) {
      for (final m in list) {
        if (m.pubkey != pubkey || !isPlaceholderNym(m.author)) continue;
        m.author = display;
        changed = true;
      }
    }
    _placeholderAuthors.remove(pubkey);
    return changed;
  }

  void _ingestProfile(NostrEvent e) {
    final mapped = EventMapper.profile(e);
    if (mapped == null) return;
    final p = pinVerifiedBotMedia(e.pubkey, mapped);
    final resolvedName = _kind0DisplayName(p);
    final existing = state.users[e.pubkey];
    var changed = false;
    if (existing != null) {
      final prev = existing.profile;
      if (prev == null || p.kind0Ts >= prev.kind0Ts) {
        // Skip no-op refreshes so periodic re-fetches don't rebuild every user-watching widget.
        if (prev == null ||
            prev.kind0Ts != p.kind0Ts ||
            prev.picture != p.picture ||
            prev.name != p.name ||
            prev.username != p.username ||
            prev.displayName != p.displayName ||
            prev.about != p.about ||
            prev.banner != p.banner ||
            prev.nip05 != p.nip05 ||
            prev.lud16 != p.lud16 ||
            prev.lud06 != p.lud06) {
          existing.profile = p;
          if (resolvedName != null) {
            existing.nym = getNymFromPubkey(resolvedName, e.pubkey);
          }
          changed = true;
        }
      }
    } else {
      // The PWA never renders 'anon'.
      state.users[e.pubkey] = User(
        pubkey: e.pubkey,
        nym: getNymFromPubkey(resolvedName ?? 'nym', e.pubkey),
        profile: p,
      );
      changed = true;
    }
    // Keep the PM row's nym in sync with the kind-0 name.
    if (e.pubkey != state.selfPubkey && resolvedName != null) {
      if (_syncPmConversationNym(e.pubkey)) changed = true;
    }
    if (resolvedName != null && _rewriteStoredAuthors(e.pubkey)) changed = true;
    // Outside the no-op guard: boot hydration may pre-seed the profile while the header still shows the ephemeral nym.
    String? selfNym;
    if (e.pubkey == state.selfPubkey) {
      final stored = state.users[e.pubkey]?.profile;
      final name = stored == null ? null : _kind0DisplayName(stored);
      if (name != null) {
        final resolved = getNymFromPubkey(name, e.pubkey);
        if (resolved != state.selfNym) selfNym = resolved;
      }
    }
    if (selfNym != null) {
      state = state.copyWith(selfNym: selfNym);
    }
    // Row-visible avatar/nym changes must bump `displayRev` so already-painted rows repaint.
    if (changed || selfNym != null) {
      _scheduleEmit();
    }
  }

  void _ingestReaction(NostrEvent e) {
    if (state.blockedUsers.contains(e.pubkey)) return;

    // A present `k` tag must name a supported kind, or the reaction belongs to another app.
    final kTag = e.tagValue('k');
    if (kTag != null &&
        kTag != '20000' &&
        kTag != '23333' &&
        kTag != '1059' &&
        kTag != '14') {
      return;
    }

    final r = EventMapper.reaction(e);
    if (r == null || r.emoji.isEmpty) return;

    // Without a `k` tag, accept only reactions to known messages.
    if (kTag == null && !isKnownMessageId(r.messageId)) return;

    // PM/group reactions reference the shared id; store the tally under the rendered `Message.id`.
    final canonicalId = _msgByAnyId[r.messageId]?.id ?? r.messageId;

    // Latest-by-timestamp wins on out-of-order delivery.
    final actionKey = '$canonicalId:${r.emoji}:${r.reactor}';
    final last = _reactionLastAction[actionKey];
    if (last != null && last > r.ts) return;
    _reactionLastAction[actionKey] = r.ts;
    if (_reactionLastAction.length > 5000) {
      final entries = _reactionLastAction.entries.toList();
      _reactionLastAction
        ..clear()
        ..addEntries(entries.sublist(entries.length - 4000));
    }

    applyReaction(
      messageId: canonicalId,
      emoji: r.emoji,
      reactor: r.reactor,
      removed: r.removed,
      reactorNym: _nymForPubkey(r.reactor),
    );
  }

  /// True when [messageId] matches any stored message by event id or nymMessageId.
  bool isKnownMessageId(String messageId) {
    if (messageId.isEmpty) return false;
    return _msgByAnyId.containsKey(messageId);
  }

  /// Applies one reaction add/remove and recomputes the tally; idempotent per (messageId, emoji, reactor).
  void applyReaction({
    required String messageId,
    required String emoji,
    required String reactor,
    required bool removed,
    String? reactorNym,
  }) {
    final byEmoji = _reactors.putIfAbsent(messageId, () => {});
    if (removed) {
      final reactors = byEmoji[emoji];
      if (reactors != null) {
        reactors.remove(reactor);
        if (reactors.isEmpty) byEmoji.remove(emoji);
        if (byEmoji.isEmpty) _reactors.remove(messageId);
      }
    } else {
      byEmoji.putIfAbsent(emoji, () => {})[reactor] =
          reactorNym ?? _nymForPubkey(reactor);
    }
    _recomputeReactionTally(messageId);
    _scheduleEmit();
  }

  /// Moves reaction state from [oldId] to [newId] when an optimistic row adopts its real id.
  void _migrateReactionKey(String oldId, String newId) {
    if (oldId.isEmpty || newId.isEmpty || oldId == newId) return;
    final from = _reactors.remove(oldId);
    if (from == null || from.isEmpty) return;
    final into = _reactors.putIfAbsent(newId, () => {});
    from.forEach((emoji, reactors) {
      into.putIfAbsent(emoji, () => {}).addAll(reactors);
    });
    // Dedup keys embed the message id, so re-file them too.
    final stale =
        _reactionLastAction.keys.where((k) => k.startsWith('$oldId:')).toList();
    for (final k in stale) {
      final ts = _reactionLastAction.remove(k);
      if (ts != null) {
        _reactionLastAction['$newId:${k.substring(oldId.length + 1)}'] = ts;
      }
    }
    _recomputeReactionTally(oldId);
    _recomputeReactionTally(newId);
  }

  void _recomputeReactionTally(String messageId) {
    final byEmoji = _reactors[messageId];
    if (byEmoji == null || byEmoji.isEmpty) {
      state.reactions.remove(messageId);
      return;
    }
    final tally = <MessageReaction>[];
    byEmoji.forEach((emoji, reactors) {
      tally.add(MessageReaction(
        emoji: emoji,
        count: reactors.length,
        userReacted: reactors.containsKey(state.selfPubkey),
      ));
    });
    state.reactions[messageId] = tally;
  }

  String _nymForPubkey(String pubkey) {
    final u = state.users[pubkey];
    if (u != null && u.nym.isNotEmpty) return u.nym;
    // The PWA never shows 'anon'.
    return getNymFromPubkey('nym', pubkey);
  }

  /// Refreshes a PM row's nym from the users map; returns true if changed; doesn't emit.
  bool _syncPmConversationNym(String pubkey) {
    final known = state.users[pubkey]?.nym;
    if (known == null || known.isEmpty) return false;
    final base = stripPubkeySuffix(known);
    final clean = base.length > 20 ? base.substring(0, 20) : base;
    if (clean.isEmpty) return false;
    for (final c in state.pmConversations) {
      if (c.pubkey == pubkey) {
        final next = getNymFromPubkey(clean, pubkey);
        if (c.nym == next) return false;
        c.nym = next;
        return true;
      }
    }
    return false;
  }

  // Polls (kind 30078), channel-only.

  /// Ingests a poll-create event (dedup, expiration, question + at least 2 options) and replays buffered votes.
  void ingestPoll(NostrEvent e) {
    if (!PollLogic.isPollEvent(e)) return;
    if (PollLogic.isExpired(e)) return;
    if (state.polls.containsKey(e.id)) return;
    final poll = PollLogic.parsePoll(e);
    if (poll == null) return;
    state.polls[e.id] = poll;

    final buffered = _pendingPollVotes.remove(e.id);
    if (buffered != null) {
      for (final v in buffered) {
        poll.votes.putIfAbsent(v.voter, () => v.optionIndex);
      }
    }
    _scheduleEmit();
  }

  /// Ingests a poll vote: deduped, expiring, buffered until the poll is known, first vote per pubkey wins.
  void ingestPollVote(NostrEvent e) {
    if (!PollLogic.isPollVoteEvent(e)) return;
    if (e.id.isNotEmpty && !_processedPollVoteIds.add(e.id)) return;
    if (PollLogic.isExpired(e)) return;
    if (_processedPollVoteIds.length > 3000) {
      final arr = _processedPollVoteIds.toList();
      _processedPollVoteIds
        ..clear()
        ..addAll(arr.sublist(arr.length - 2000));
    }
    final vote = PollLogic.parseVote(e);
    if (vote == null) return;

    final poll = state.polls[vote.pollId];
    if (poll == null) {
      _pendingPollVotes.putIfAbsent(vote.pollId, () => []).add(vote);
      return;
    }
    if (poll.votes.containsKey(vote.voter)) return;
    poll.votes[vote.voter] = vote.optionIndex;
    _scheduleEmit();
  }

  /// Registers a local poll so the UI updates immediately.
  void upsertPoll(Poll poll) {
    state.polls[poll.id] = poll;
    _scheduleEmit();
  }

  /// Applies our own vote optimistically; no-op if the poll is unknown or already voted.
  bool applyLocalVote(String pollId, int optionIndex) {
    final poll = state.polls[pollId];
    if (poll == null) return false;
    if (poll.votes.containsKey(state.selfPubkey)) return false;
    poll.votes[state.selfPubkey] = optionIndex;
    _scheduleEmit();
    return true;
  }

  // Zaps (kind 9735 receipts).

  /// Ingests a zap receipt for a message (`e` tag), deduped by lowercased bolt11.
  void ingestZapReceipt(NostrEvent e) {
    final info = ZapLogic.parseReceipt(e);
    if (info == null) return;
    recordMessageZap(
      messageId: info.messageId,
      zapperPubkey: info.zapperPubkey,
      amountSats: info.amountSats,
      dedupKey: info.dedupKey,
    );
  }

  /// Records a zap once per [dedupKey]; a later verified receipt clears the unverified mark without double-counting.
  bool recordMessageZap({
    required String messageId,
    required String zapperPubkey,
    required int amountSats,
    required String dedupKey,
    bool verified = true,
  }) {
    if (messageId.isEmpty || amountSats <= 0) return false;
    final mz = state.zaps.putIfAbsent(messageId, MessageZaps.new);
    if (mz.receipts.contains(dedupKey)) {
      // Already counted; a verified receipt only flips the unverified flag.
      if (verified && mz.unverified.remove(dedupKey) != null) {
        _scheduleEmit();
        return true;
      }
      return false;
    }
    mz.receipts.add(dedupKey);
    if (!verified) mz.unverified[dedupKey] = amountSats;
    mz.totalSats += amountSats;
    mz.zappers.add(zapperPubkey);
    _scheduleEmit();
    return true;
  }

  // PM / group / presence ingest, called by the controller after unwrap.

  bool isKnownEventId(String id) => id.isNotEmpty && _seenIds.contains(id);

  bool ingestPMMessage(Message m, {bool countUnread = true}) {
    final rawPeer = m.conversationPubkey;
    if (rawPeer == null) return false;
    // Canonical lowercase hex: the peer id is matched exactly against lowercase constants.
    final peer =
        _hex64AnyCaseRe.hasMatch(rawPeer) ? rawPeer.toLowerCase() : rawPeer;
    // A closed conversation re-opens only for a message strictly newer than the close time.
    if (_closedPMs.contains(peer)) {
      final closedAt = _closedPMTimes[peer] ?? 0;
      if (m.createdAt > closedAt) {
        _closedPMs.remove(peer);
        _closedPMTimes.remove(peer);
        // Persist the re-open so it survives relaunch.
        onClosedPmsChanged?.call();
      } else {
        return false;
      }
    }
    if (m.id.isNotEmpty && !_seenIds.add(m.id)) return false;
    // NIP-09: drop deleted PM/group copies.
    if (suppressDeletedMessage(m)) return false;

    final key =
        _canonicalPmStorageKey(m.conversationKey ?? PmLogic.pmStorageKey(peer));
    final list = state.messages.putIfAbsent(key, () => <Message>[]);

    // Dual-wrap merge: match the Bitchat and Nymchat copies by nymMessageId (or content within 5s) and upgrade in place.
    final nymId = m.nymMessageId;
    Message? dup;
    if (nymId != null && nymId.isNotEmpty) {
      for (final e in list) {
        if (e.pubkey == m.pubkey && e.nymMessageId == nymId) {
          dup = e;
          break;
        }
      }
    }
    if (dup == null) {
      for (final e in list) {
        if (e.pubkey == m.pubkey &&
            e.content == m.content &&
            (e.createdAt - m.createdAt).abs() < 5 &&
            (m.replyTo == null || e.replyTo == m.replyTo)) {
          dup = e;
          break;
        }
      }
    }
    if (dup != null) {
      var changed = false;
      final mayRewrite =
          m.senderVerified == true || dup.senderVerified != true;
      if (mayRewrite &&
          (dup.nymMessageId == null || dup.nymMessageId!.isEmpty) &&
          nymId != null &&
          nymId.isNotEmpty) {
        dup.nymMessageId = nymId;
        _seenNymMessageIds.add(nymId);
        // Index the adopted nymMessageId so receipts can find it.
        _indexMessage(key, dup);
        changed = true;
      }
      if (mayRewrite && m.content.length > dup.content.length) {
        dup.content = m.content;
        changed = true;
      }
      if (m.senderVerified == true && dup.senderVerified != true) {
        dup.senderVerified = true;
        if (!dup.isEdited) dup.content = m.content;
        changed = true;
      }
      // Upgrade-only PQ flag, never for our own message: its self-copy says nothing about the recipient's copy.
      if (m.pqEncrypted && !dup.pqEncrypted && !dup.isOwn) {
        dup.pqEncrypted = true;
        // Carried along, or a legacy key would jump straight to the full shield.
        dup.pqRoot = m.pqRoot;
        changed = true;
      }
      if (m.pqCoverage != null && dup.pqCoverage == null) {
        dup.pqCoverage = m.pqCoverage;
        changed = true;
      }
      if (changed) _scheduleEmit();
      return false;
    }
    if (m.nymMessageId != null && !_seenNymMessageIds.add(m.nymMessageId!)) {
      return false;
    }
    if (botThreadForeign(m, list)) {
      _holdBotThreadOrphan(m);
      return false;
    }
    if (m.replyTo != null && m.anchorAt == null && peer == kNymbotPubkey) {
      anchorBotReply(list, m);
    }
    if (absorbLiveHook?.call(m, list) == true) {
      _scheduleEmit();
      return false;
    }
    m.seq = _nextIngestSeq();

    _insertMessageSorted(key, list, m);
    _adoptBotThreadOrphans(key, list, m);

    // Prefer the users-map nym on every message so a late kind-0 still corrects the row.
    final convo = state.pmConversations.firstWhere(
      (c) => c.pubkey == peer,
      orElse: () {
        // Never an empty nym, which would render as a bare '#xxxx' title.
        final c = PMConversation(
          pubkey: peer,
          nym: m.isOwn ? getNymFromPubkey('nym', peer) : m.author,
        );
        state.pmConversations.add(c);
        onPMConversationAdded?.call(peer);
        return c;
      },
    );
    if (!_syncPmConversationNym(peer)) {
      if (!m.isOwn && convo.nym.isEmpty) convo.nym = m.author;
    }
    if (m.timestamp > convo.lastMessageTime) {
      convo.lastMessageTime = m.timestamp;
    }

    if (!m.isOwn) {
      final u = state.users.putIfAbsent(
        m.pubkey,
        () => User(pubkey: m.pubkey, nym: m.author),
      );
      _seedAuthorFromStore(m);
      u.lastSeen = m.timestamp;
    }

    // Seen means the active PM, or a focused, at-bottom, visible column.
    final seenPm = _isConversationSeen(key);
    if (!seenPm &&
        countUnread &&
        state.countsTowardUnread(m) &&
        _isUnreadByWatermark(peer, m)) {
      state.unreadCounts[peer] = (state.unreadCounts[peer] ?? 0) + 1;
    } else if (seenPm &&
        columnsReadGate != null &&
        !_hiddenThreadReply(key, m)) {
      state.unreadCounts.remove(peer);
      state.unreadCounts.remove(key);
      markChannelRead(peer, m.createdAt);
      markChannelRead(key, m.createdAt);
    }
    // Apply a buffered out-of-order edit, matching on id or nymMessageId.
    _consumePendingEdit(id: m.id, nymMessageId: m.nymMessageId);
    _scheduleEmit();
    onPmMessageIngested?.call(key);
    return true;
  }

  /// Inserts a decrypted group message; returns false on dedup or left group so metadata merges are skipped.
  bool ingestGroupMessage(Message m, {bool countUnread = true}) {
    final gid = m.groupId;
    if (gid == null) return false;
    if (_leftGroups.contains(gid)) return false;
    if (m.id.isNotEmpty && !_seenIds.add(m.id)) return false;
    if (m.nymMessageId != null && !_seenNymMessageIds.add(m.nymMessageId!)) {
      return false;
    }
    // NIP-09: drop deleted group messages.
    if (suppressDeletedMessage(m)) return false;
    m.seq = _nextIngestSeq();

    final key = m.conversationKey ?? GroupLogic.groupStorageKey(gid);
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    if (absorbLiveHook?.call(m, list) == true) {
      _scheduleEmit();
      return false;
    }
    _insertMessageSorted(key, list, m);
    slowmodeHook?.call(gid, list, m.pubkey);

    final idx = state.groups.indexWhere((g) => g.id == gid);
    if (idx >= 0 && m.timestamp > state.groups[idx].lastMessageTime) {
      state.groups[idx].lastMessageTime = m.timestamp;
    }
    if (!m.isOwn) {
      final u = state.users.putIfAbsent(
        m.pubkey,
        () => User(pubkey: m.pubkey, nym: m.author),
      );
      _seedAuthorFromStore(m);
      u.lastSeen = m.timestamp;
    }
    final seenGroup = _isConversationSeen(key);
    if (!seenGroup &&
        countUnread &&
        !m.slowHeld &&
        state.countsTowardUnread(m) &&
        _isUnreadByWatermark(key, m)) {
      // Keyed by the group's storage key, which the sidebar row reads.
      state.unreadCounts[key] = (state.unreadCounts[key] ?? 0) + 1;
    } else if (seenGroup &&
        columnsReadGate != null &&
        !_hiddenThreadReply(key, m)) {
      state.unreadCounts.remove(key);
      markChannelRead(key, m.createdAt);
    }
    _consumePendingEdit(id: m.id, nymMessageId: m.nymMessageId);
    _scheduleEmit();
    onPmMessageIngested?.call(key);
    onGroupStoreChanged?.call();
    return true;
  }

  /// Ingests a mesh channel message (no NostrEvent); returns false on dedup.
  bool ingestMeshChannelMessage(Message m, {required String channelKey}) {
    if (m.id.isNotEmpty && !_seenIds.add(m.id)) return false;
    if (suppressDeletedMessage(m)) return false;
    m.seq = _ingestSeq++;
    final list = state.messages.putIfAbsent(channelKey, () => <Message>[]);

    // Reconcile our own optimistic echo so a round-tripped self-send isn't shown twice.
    if (!m.isOwn) {
      for (var i = 0; i < list.length; i++) {
        final ex = list[i];
        if ((ex.optimistic || ex.id.startsWith('_optim_')) &&
            ex.pubkey == m.pubkey &&
            ex.content == m.content &&
            (ex.createdAt - m.createdAt).abs() < 60) {
          return false;
        }
      }
    }

    _insertMessageSorted(channelKey, list, m);
    _capChannelHistory(list);

    if (!m.isOwn) {
      final u = state.users.putIfAbsent(
        m.pubkey,
        () => User(pubkey: m.pubkey, nym: m.author),
      );
      if (!isPlaceholderNym(m.author)) {
        u.nym = m.author;
      } else {
        _seedAuthorFromStore(m);
      }
      u.lastSeen = m.timestamp;
      final memberKey = (m.channel ?? '').toLowerCase();
      if (memberKey.isNotEmpty) u.channels.add(memberKey);
    }

    final hidden = state.isMessageFiltered(m);
    if (!hidden && m.timestamp > (state.channelLastActivity[channelKey] ?? 0)) {
      state.channelLastActivity[channelKey] = m.timestamp;
    }

    final regKey = (m.channel ?? '').toLowerCase();
    if (!hidden &&
        regKey.isNotEmpty &&
        !state.channels.any((c) => c.key == regKey)) {
      state.channels.add(ChannelEntry(channel: m.channel!));
    }

    final seen = _isConversationSeen(channelKey);
    if (!seen &&
        state.countsTowardUnread(m) &&
        _isUnreadByWatermark(channelKey, m)) {
      state.unreadCounts[channelKey] =
          (state.unreadCounts[channelKey] ?? 0) + 1;
    }
    _scheduleEmit();
    return true;
  }

  void upsertGroup(Group group) {
    if (_leftGroups.contains(group.id)) return;
    final idx = state.groups.indexWhere((g) => g.id == group.id);
    if (idx >= 0) {
      state.groups[idx] = group;
    } else {
      state.groups.add(group);
    }
    _scheduleEmit();
    onGroupStoreChanged?.call();
  }

  /// Fills missing avatar/owner onto an existing shell group without clobbering real metadata; returns whether it changed.
  bool enrichGroupIdentity(
    String groupId, {
    String? createdBy,
    String? name,
    String? avatar,
    String? banner,
    String? description,
    List<String>? members,
    List<String>? mods,
    int membersAt = 0,
  }) {
    final g = groupById(groupId);
    if (g == null) return false;
    bool has(String? v) => v != null && v.isNotEmpty;
    var changed = false;
    if (!has(g.createdBy) && has(createdBy)) {
      g.createdBy = createdBy;
      changed = true;
    }
    if (g.name.isEmpty && has(name)) {
      g.name = name!;
      changed = true;
    }
    if (!has(g.avatar) && has(avatar)) {
      g.avatar = avatar;
      changed = true;
    }
    if (!has(g.banner) && has(banner)) {
      g.banner = banner;
      changed = true;
    }
    if (!has(g.description) && has(description)) {
      g.description = description;
      changed = true;
    }
    var evicted = const <String>[];
    if (members != null) {
      final admit = GroupLogic.admitMembers(
          g, {for (final pk in members) pk: membersAt});
      if (admit.changed) changed = true;
      evicted = admit.evicted;
    }
    if (mods != null && g.mods.isEmpty) {
      for (final pk in mods) {
        if (pk.isNotEmpty && !g.mods.contains(pk)) {
          g.mods.add(pk);
          changed = true;
        }
      }
    }
    if (changed) {
      _scheduleEmit();
      onGroupStoreChanged?.call();
    }
    _reportEvicted(groupId, evicted);
    return changed;
  }

  /// Merges a group message's metadata into its entry: members, owner-only subject, last time; creates unknown groups.
  void notifyGroupsChanged() {
    _scheduleEmit();
    onGroupStoreChanged?.call();
  }

  void mergeGroupFromMessage({
    required String groupId,
    required String name,
    required List<String> memberPubkeys,
    required int timestampMs,
    String senderPubkey = '',
  }) {
    final existing = groupById(groupId);
    final seenAt = timestampMs ~/ 1000;
    if (existing == null) {
      if (_leftGroups.contains(groupId)) return;
      final created = Group(
        id: groupId,
        name: name,
        lastMessageTime: timestampMs,
      );
      GroupLogic.admitMembers(
          created, {for (final pk in memberPubkeys) pk: seenAt});
      state.groups.add(created);
      _scheduleEmit();
      // A group learned from a message (missed invite) is synced immediately.
      onGroupStoreChanged?.call();
      return;
    }
    var changed = false;
    final admit = GroupLogic.admitMembers(
        existing, {for (final pk in memberPubkeys) pk: seenAt});
    if (admit.changed) changed = true;
    final nameAuthoritative =
        senderPubkey.isNotEmpty && existing.createdBy == senderPubkey;
    if (nameAuthoritative && name.isNotEmpty && name != existing.name) {
      existing.name = name;
      changed = true;
    }
    if (timestampMs > existing.lastMessageTime) {
      existing.lastMessageTime = timestampMs;
      changed = true;
    }
    if (changed) {
      _scheduleEmit();
      onGroupStoreChanged?.call();
    }
    _reportEvicted(groupId, admit.evicted);
  }

  Group? groupById(String id) {
    for (final g in state.groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// Per-group history cap applied after merging a restored backlog.
  static const int _kGroupHistoryCap = 1000;

  /// In-memory cap per public channel; older history stays in the sqflite cache.
  static const int _kChannelHistoryCap = 1000;

  /// Applies one synced group entry, creating or monotonically merging it; returns whether changed.
  bool applyGroupConversationSync(String groupId, Map<String, dynamic> data) {
    if (_leftGroups.contains(groupId)) return false;
    List<String> strList(Object? v) =>
        (v is List) ? v.map((e) => e.toString()).toList() : <String>[];
    String? nz(Object? v) => (v is String && v.isNotEmpty) ? v : null;
    List<ModLogEntry> parseLog(Object? v) {
      final out = <ModLogEntry>[];
      if (v is List) {
        for (final e in v) {
          if (e is Map) {
            try {
              out.add(ModLogEntry.fromJson(e.cast<String, dynamic>()));
            } catch (_) {
              // Skip a malformed log entry.
            }
          }
        }
      }
      return out;
    }

    // Seed unknown member nyms from synced snapshots; never clobbers a live user.
    final memberProfiles = data['memberProfiles'];
    if (memberProfiles is Map) {
      memberProfiles.forEach((pkRaw, prof) {
        final pk = pkRaw.toString();
        if (prof is! Map || state.users.containsKey(pk)) return;
        final name = prof['name'];
        if (name is! String || name.isEmpty) return;
        final pic = prof['picture'];
        state.users[pk] = User(
          pubkey: pk,
          nym: name,
          profile: (pic is String && pic.isNotEmpty)
              ? UserProfile(picture: pic)
              : null,
        );
      });
    }

    final syncedAt = Group.parseTimeMap(data['memberAt']) ?? <String, int>{};
    final syncedRemovedAt =
        Group.parseTimeMap(data['memberRemovedAt']) ?? <String, int>{};
    Map<String, int> syncedMembers(int unknownAt, Map<String, int> removed) => {
          for (final pk in strList(data['members']))
            if ((removed[pk] ?? -1) <= (syncedAt[pk] ?? 0))
              pk: syncedAt[pk] ?? unknownAt,
        };
    final existing = groupById(groupId);
    if (existing == null) {
      final created = Group(
        id: groupId,
        name: (data['name'] ?? '') as String,
        memberRemovedAt: syncedRemovedAt,
        joinedVia: nz(data['joinedVia']),
        lastMessageTime: (data['lastMessageTime'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
        createdBy: nz(data['createdBy']),
        mods: strList(data['mods']),
        banned: strList(data['banned']),
        avatar: nz(data['avatar']),
        banner: nz(data['banner']),
        description: nz(data['description']),
        allowMemberInvites: data['allowMemberInvites'] != false,
        inviteEnabled: data['inviteEnabled'] == true,
        inviteEpoch: (data['inviteEpoch'] as num?)?.toInt() ?? 0,
        metaUpdatedAt: (data['metaUpdatedAt'] as num?)?.toInt() ?? 0,
        lastModTs: (data['lastModTs'] as num?)?.toInt() ?? 0,
        lastModEventId: nz(data['lastModEventId']),
        shareHistory: data['shareHistory'] == true,
        historyReceived: data['historyReceived'] == true,
        modTsByTarget: data['modTsByTarget'] is Map
            ? (data['modTsByTarget'] as Map).map(
                (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0))
            : null,
        modSeenIds: data['modSeenIds'] is List
            ? (data['modSeenIds'] as List).map((e) => e.toString()).toList()
            : null,
        modLog: parseLog(data['modLog']),
      );
      GroupLogic.admitMembers(created, syncedMembers(0, syncedRemovedAt));
      state.groups.add(created);
      _scheduleEmit();
      return true;
    }

    final g = existing;
    var changed = false;
    syncedRemovedAt.forEach((pk, at) {
      if (at > (g.memberRemovedAt[pk] ?? -1)) {
        g.memberRemovedAt[pk] = at;
        changed = true;
      }
      if (pk != state.selfPubkey &&
          g.members.contains(pk) &&
          at > (g.memberAt[pk] ?? 0)) {
        g.members.remove(pk);
        g.mods.remove(pk);
        g.admins.remove(pk);
        g.memberAt.remove(pk);
        changed = true;
      }
    });
    final syncAdmit = GroupLogic.admitMembers(
        g,
        syncedMembers(DateTime.now().millisecondsSinceEpoch ~/ 1000,
            g.memberRemovedAt));
    if (syncAdmit.changed) changed = true;
    if ((g.createdBy == null || g.createdBy!.isEmpty)) {
      final owner = nz(data['createdBy']);
      if (owner != null) {
        g.createdBy = owner;
        changed = true;
      }
    }
    final incomingMetaTs = (data['metaUpdatedAt'] as num?)?.toInt() ?? 0;
    if (incomingMetaTs > g.metaUpdatedAt) {
      final name = data['name'];
      if (name is String && name.isNotEmpty) g.name = name;
      g.banner = nz(data['banner']);
      g.avatar = nz(data['avatar']);
      g.description = nz(data['description']);
      // Absence-safe: synced blobs may lack this key, and absence must not flip a disabled policy.
      if (data.containsKey('allowMemberInvites')) {
        g.allowMemberInvites = data['allowMemberInvites'] != false;
      }
      g.inviteEnabled = data['inviteEnabled'] == true;
      g.inviteEpoch = (data['inviteEpoch'] as num?)?.toInt() ?? 0;
      // Absence-safe, like allowMemberInvites.
      if (data.containsKey('shareHistory')) {
        g.shareHistory = data['shareHistory'] == true;
      }
      g.metaUpdatedAt = incomingMetaTs;
      changed = true;
    } else {
      if (g.banner == null && nz(data['banner']) != null) {
        g.banner = nz(data['banner']);
        changed = true;
      }
      if (g.avatar == null && nz(data['avatar']) != null) {
        g.avatar = nz(data['avatar']);
        changed = true;
      }
      if (g.description == null && nz(data['description']) != null) {
        g.description = nz(data['description']);
        changed = true;
      }
    }
    for (final pk in strList(data['mods'])) {
      if (!g.mods.contains(pk)) {
        g.mods.add(pk);
        changed = true;
      }
    }
    for (final pk in strList(data['banned'])) {
      if (!g.banned.contains(pk)) {
        g.banned.add(pk);
        changed = true;
      }
    }
    final incomingLog = parseLog(data['modLog']);
    if (incomingLog.isNotEmpty) {
      String key(ModLogEntry e) => '${e.type}:${e.actor}:${e.target}:${e.ts}';
      final seen = g.modLog.map(key).toSet();
      for (final e in incomingLog) {
        if (seen.add(key(e))) {
          g.modLog.add(e);
          changed = true;
        }
      }
      g.modLog.sort((a, b) => a.ts - b.ts);
      if (g.modLog.length > 50) {
        g.modLog.removeRange(0, g.modLog.length - 50);
      }
    }
    // The moderation watermark merges monotonically regardless of the metaUpdatedAt gate.
    final incomingModTs = (data['lastModTs'] as num?)?.toInt() ?? 0;
    if (incomingModTs > g.lastModTs) {
      g.lastModTs = incomingModTs;
      g.lastModEventId = nz(data['lastModEventId']);
      changed = true;
    }
    // Per-target moderation clocks and seen ids merge monotonically too.
    final incomingTargets = data['modTsByTarget'];
    if (incomingTargets is Map) {
      incomingTargets.forEach((k, v) {
        final ts = (v as num?)?.toInt() ?? 0;
        final pk = k.toString();
        if (ts > (g.modTsByTarget[pk] ?? 0)) {
          g.modTsByTarget[pk] = ts;
          changed = true;
        }
      });
    }
    final incomingSeen = data['modSeenIds'];
    if (incomingSeen is List) {
      for (final e in incomingSeen) {
        final id = e.toString();
        if (id.isNotEmpty && !g.modSeenIds.contains(id)) {
          g.modSeenIds.add(id);
          changed = true;
        }
      }
      if (g.modSeenIds.length > 100) {
        g.modSeenIds.removeRange(0, g.modSeenIds.length - 100);
      }
    }
    if (data['historyReceived'] == true && !g.historyReceived) {
      g.historyReceived = true;
      changed = true;
    }
    if (changed) _scheduleEmit();
    _reportEvicted(groupId, syncAdmit.evicted);
    return changed;
  }

  /// Merges synced group history: dedup, sort and cap to [_kGroupHistoryCap]; skips left groups; returns changed keys.
  Set<String> applyGroupHistorySync(Map<String, List<dynamic>> byConvKey) {
    final changed = <String>{};
    byConvKey.forEach((convKey, backup) {
      if (backup.isEmpty || !convKey.startsWith('group-')) return;
      final gid = convKey.substring(6);
      if (_leftGroups.contains(gid)) return;
      final existing = state.messages[convKey] ?? <Message>[];
      final existingIds = existing.map((m) => m.id).toSet();
      final newMsgs = <Message>[];
      for (final raw in backup) {
        if (raw is! Map) continue;
        final id = raw['id'];
        if (id is! String || id.isEmpty || existingIds.contains(id)) continue;
        // Register globally so a later live copy is deduped.
        if (!_seenIds.add(id)) continue;
        final pubkey = (raw['pubkey'] ?? '') as String;
        final nymMessageId = raw['nymMessageId'] as String?;
        if (nymMessageId != null) _seenNymMessageIds.add(nymMessageId);
        newMsgs.add(Message(
          id: id,
          pubkey: pubkey,
          author: _nymForPubkey(pubkey),
          content: (raw['content'] ?? '') as String,
          createdAt: (raw['created_at'] as num?)?.toInt() ?? 0,
          isOwn: raw['isOwn'] == true,
          isPM: true,
          isGroup: true,
          groupId: (raw['groupId'] as String?) ?? gid,
          conversationKey: convKey,
          isHistorical: true,
          nymMessageId: nymMessageId,
          seq: _nextIngestSeq(),
          deliveryStatus: DeliveryStatus.sent,
        ));
        existingIds.add(id);
      }
      if (newMsgs.isEmpty) return;
      for (final m in newMsgs) {
        _indexMessage(convKey, m);
      }
      final merged = [...existing, ...newMsgs]..sort(compareMessages);
      final capped = merged.length > _kGroupHistoryCap
          ? merged.sublist(merged.length - _kGroupHistoryCap)
          : merged;
      if (capped.length < merged.length) {
        for (final m in merged.sublist(0, merged.length - capped.length)) {
          _unindexMessage(m);
        }
      }
      state.messages[convKey] = capped;
      changed.add(convKey);
    });
    if (changed.isNotEmpty) _scheduleEmit();
    return changed;
  }

  /// Applies a verified group control rumor in place and returns the outcome.
  GroupControlResult applyGroupControl({
    required String groupId,
    required String type,
    required List<List<String>> tags,
    required String senderPubkey,
    required int ts,
    String? eventId,
  }) {
    final g = groupById(groupId);
    if (g == null) return GroupControlResult.ignored;
    var controlTags = tags;
    if (type == GroupControlType.deleteMessage) {
      final targetId = GroupLogic.tagValue(tags, 'e');
      final claimed = GroupLogic.tagValue(tags, 'target_pubkey');
      final stored = targetId == null
          ? null
          : _groupMessageAuthor(GroupLogic.groupStorageKey(groupId), targetId,
              claimed: claimed);
      if (stored == null) {
        if (claimed == null || claimed.isEmpty) {
          return GroupControlResult.invalid;
        }
      } else if (claimed != null && claimed.isNotEmpty && claimed != stored) {
        return GroupControlResult.unauthorized;
      } else if (claimed == null || claimed.isEmpty) {
        controlTags = [
          for (final t in tags)
            if (t.isEmpty || t[0] != 'target_pubkey') t,
          ['target_pubkey', stored],
        ];
      }
    }
    final before = List<String>.of(g.members);
    final result = GroupLogic.applyControlEvent(
      group: g,
      type: type,
      tags: controlTags,
      senderPubkey: senderPubkey,
      ts: ts,
      eventId: eventId,
      selfPubkey: state.selfPubkey,
    );
    if (result == GroupControlResult.applied) {
      // When removed, stamp the leave time so only a newer event can resurrect the group.
      if (type == 'group-remove-member' &&
          !g.members.contains(state.selfPubkey)) {
        _leftGroups.add(groupId);
        _leftGroupTimes[groupId] = ts;
        state.groups.removeWhere((x) => x.id == groupId);
        state.messages.remove(GroupLogic.groupStorageKey(groupId));
      }
      // [GroupLogic.applyControlEvent] only role-checks; the message removal happens here.
      if (type == GroupControlType.deleteMessage) {
        final targetId = GroupLogic.tagValue(controlTags, 'e');
        final targetAuthor =
            GroupLogic.tagValue(controlTags, 'target_pubkey');
        if (targetId != null && targetId.isNotEmpty && targetAuthor != null) {
          removeMessage(targetId,
              author: targetAuthor,
              storageKey: GroupLogic.groupStorageKey(groupId));
        }
      }
      _scheduleEmit();
      onGroupStoreChanged?.call();
      if (type == GroupControlType.addMember) {
        _reportEvicted(groupId,
            [for (final pk in before) if (!g.members.contains(pk)) pk]);
      }
    }
    return result;
  }

  String? _groupMessageAuthor(String storageKey, String messageId,
      {String? claimed}) {
    final list = state.messages[storageKey];
    if (list == null || messageId.isEmpty) return null;
    String? first;
    for (final m in list) {
      if (m.id != messageId && m.nymMessageId != messageId) continue;
      if (m.pubkey.isEmpty) continue;
      if (claimed != null && m.pubkey == claimed) return claimed;
      first ??= m.pubkey;
    }
    return first;
  }

  /// Applies a receipt to our own message by nymMessageId: PMs advance ticks, groups record the reader.
  void applyReceipt(ReceiptInfo receipt) {
    if (receipt.messageIds.length > 1) {
      for (final id in receipt.messageIds) {
        applyReceipt(ReceiptInfo(
          messageId: id,
          receiptType: receipt.receiptType,
          readerPubkey: receipt.readerPubkey,
        ));
      }
      return;
    }
    final target = receipt.messageId.toLowerCase();
    final next = PmLogic.deliveryFromReceipt(receipt.receiptType);
    final m = _msgByAnyId[receipt.messageId] ?? _msgByAnyId[target];

    // Own group messages are indexed on send, so a read receipt always resolves.
    final readerPk = receipt.readerPubkey;
    if (m != null &&
        m.isOwn &&
        m.isGroup &&
        receipt.receiptType == 'read' &&
        readerPk != null &&
        readerPk.isNotEmpty) {
      final nid = m.nymMessageId;
      final gid = m.groupId;
      final group = gid == null ? null : groupById(gid);
      if (group == null || !GroupLogic.isMember(group, readerPk)) return;
      if (nid != null && nid.toLowerCase() == target) {
        final nym =
            state.users[readerPk]?.nym ?? getNymFromPubkey('nym', readerPk);
        applyChannelReader(
            messageId: nid, readerPubkey: readerPk, readerNym: nym);
      }
      return;
    }

    if (m == null) {
      // Buffer receipts that beat the restore; they are never archived, so dropping one loses it.
      final cur = _pendingPmReceipts[target];
      if (cur == null || PmLogic.statusOrder(next) > PmLogic.statusOrder(cur)) {
        _pendingPmReceipts[target] = next;
      }
      return;
    }
    if (!m.isOwn) return;
    final nid = m.nymMessageId;
    if (nid == null || nid.toLowerCase() != target) return;
    if (PmLogic.statusOrder(next) > PmLogic.statusOrder(m.deliveryStatus)) {
      m.deliveryStatus = next;
      _scheduleEmit();
    }
  }

  /// Records a channel read receipt and mirrors it onto the matching own message's readers.
  void applyChannelReader({
    required String messageId,
    required String readerPubkey,
    required String readerNym,
  }) {
    if (messageId.isEmpty || readerPubkey.isEmpty) return;
    if (readerPubkey == state.selfPubkey) return;
    if (state.blockedUsers.contains(readerPubkey)) return;
    final readers =
        _channelMessageReaders.putIfAbsent(messageId, () => <String, String>{});
    // The store keeps every message a reader saw; the waterfall decides where the avatar shows.
    readers[readerPubkey] = readerNym;
    // Re-mirror so the reader's avatar moves to their newest-seen own message.
    if (_remirrorForReaders([readerPubkey])) _scheduleEmit();
  }

  /// Re-mirrors waterfalled readers for every own message [pubkeys] read; true if any visible set changed.
  bool _remirrorForReaders(Iterable<String> pubkeys) {
    final set = pubkeys.toSet();
    if (set.isEmpty) return false;
    var changed = false;
    // Iterate a copy defensively.
    for (final id in _channelMessageReaders.keys.toList()) {
      final readers = _channelMessageReaders[id];
      if (readers == null || !readers.keys.any(set.contains)) continue;
      if (_mirrorChannelReaders(id)) changed = true;
    }
    return changed;
  }

  /// Mirrors the waterfalled reader set for [messageId] onto its own message; true if changed.
  bool _mirrorChannelReaders(String messageId) {
    final stored = _channelMessageReaders[messageId];
    if (stored == null) return false;
    final m = _msgByAnyId[messageId];
    if (m == null || !m.isOwn) return false;
    // Channel receipts reference the event id, group receipts the nymMessageId.
    if (m.id != messageId && m.nymMessageId != messageId) return false;
    final conv = _conversationIdOf(m);
    final display = <String, String>{};
    stored.forEach((pk, nym) {
      if (_waterfallTargetId(pk, conv) == messageId) display[pk] = nym;
    });
    if (_readersEqual(m.readers, display)) return false;
    m.readers
      ..clear()
      ..addAll(display);
    return true;
  }

  /// Receipt key of [readerPubkey]'s newest-seen landed own message in [conv], or null.
  String? _waterfallTargetId(String readerPubkey, String? conv) {
    String? bestId;
    Message? best;
    _channelMessageReaders.forEach((id, readers) {
      if (!readers.containsKey(readerPubkey)) return;
      final m = _msgByAnyId[id];
      if (m == null || !m.isOwn) return;
      if (m.id != id && m.nymMessageId != id) return;
      if (_conversationIdOf(m) != conv) return;
      if (best == null || compareMessages(m, best!) > 0) {
        best = m;
        bestId = id;
      }
    });
    return bestId;
  }

  /// Per-conversation identity so avatars never move between conversations.
  String? _conversationIdOf(Message m) {
    final ck = m.conversationKey;
    if (ck != null && ck.isNotEmpty) return ck;
    final g = m.geohash;
    if (g != null && g.isNotEmpty) return '#$g';
    final ch = m.channel;
    if (ch != null && ch.isNotEmpty) return '#$ch';
    return m.groupId;
  }

  static bool _readersEqual(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  /// Marks [pubkey] as typing in [storageKey]; [expiresAtMs] defaults to now + 5s.
  void setTyping({
    required String storageKey,
    required String pubkey,
    required bool typing,
    int? expiresAtMs,
    String? nym,
  }) {
    // Seed an unknown typer's nym from the `n` tag so the row isn't "Someone".
    if (typing &&
        nym != null &&
        nym.isNotEmpty &&
        !state.users.containsKey(pubkey)) {
      state.users[pubkey] =
          User(pubkey: pubkey, nym: getNymFromPubkey(nym, pubkey));
    }
    final k = '$storageKey|$pubkey';
    if (typing) {
      state.typing[k] =
          expiresAtMs ?? DateTime.now().millisecondsSinceEpoch + 5000;
    } else {
      state.typing.remove(k);
    }
    // Ambient: the typing indicator is its own widget.
    runAmbient(_scheduleEmit);
  }

  /// Applies a presence event to the user; `hidden` updates lastSeen/away but leaves [User.status] alone.
  void setUserPresence({
    required String pubkey,
    required UserStatus status,
    String? nym,
    String? awayMessage,
    int? lastSeenMs,
    bool stampLastSeen = true,
    String? avatarUrl,
    bool hasAvatarTag = false,
  }) {
    // Snapshot row-visible fields to tell a row repaint from an ambient presence change.
    final existingUser = state.users[pubkey];
    final beforeNym = existingUser?.nym;
    final beforePic = existingUser?.profile?.picture;
    final u = state.users.putIfAbsent(
      pubkey,
      () => User(pubkey: pubkey, nym: nym ?? getNymFromPubkey('nym', pubkey)),
    );
    u.status = status;
    if (nym != null && nym.isNotEmpty) {
      u.nym = getNymFromPubkey(nym, pubkey);
      _rewriteStoredAuthors(pubkey);
      _syncPmConversationNym(pubkey);
    }
    u.awayMessage = (awayMessage != null && awayMessage.isNotEmpty)
        ? awayMessage
        : (status == UserStatus.away ? u.awayMessage : null);
    // Presence isn't activity; only message, friend-presence and own-activity paths stamp lastSeen.
    if (stampLastSeen && lastSeenMs != null) u.lastSeen = lastSeenMs;

    // An `avatar-update` tag sets, or clears when empty, the picture.
    if (hasAvatarTag && !kVerifiedBotPubkeys.contains(pubkey)) {
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        (u.profile ??= UserProfile()).picture = avatarUrl;
      } else {
        u.profile?.picture = null;
      }
    }

    // Only a nym/avatar change is drawn in message rows; otherwise the emit is ambient.
    final rowVisibleChanged = existingUser == null ||
        u.nym != beforeNym ||
        u.profile?.picture != beforePic;
    if (rowVisibleChanged) {
      _scheduleEmit();
    } else {
      runAmbient(_scheduleEmit);
    }
  }

  /// Closes a PM, stamping the close time so only a strictly newer message re-opens it.
  void closePM(String peerPubkey, {int? nowSec}) {
    final ts = nowSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    _closedPMs.add(peerPubkey);
    _closedPMTimes[peerPubkey] = ts;
    state.pmConversations.removeWhere((c) => c.pubkey == peerPubkey);
    state.messages.remove(PmLogic.pmStorageKey(peerPubkey));
    // Stamp the watermark and drop the badge so a re-open can't resurrect a stale count.
    markChannelRead(peerPubkey, ts);
    markChannelRead(PmLogic.pmStorageKey(peerPubkey), ts);
    state.unreadCounts.remove(peerPubkey);
    state.unreadCounts.remove(PmLogic.pmStorageKey(peerPubkey));
    onClosedPmsChanged?.call();
    _scheduleEmit();
  }

  /// Seeds or updates a user's nym (mesh announcements) and refreshes the PM row.
  void upsertUserNym(String pubkey, String nym) {
    if (pubkey.isEmpty || nym.isEmpty) return;
    var changed = false;
    final u = state.users[pubkey];
    if (u == null) {
      state.users[pubkey] = User(pubkey: pubkey, nym: nym);
      changed = true;
    } else if (u.nym != nym) {
      u.nym = nym;
      changed = true;
    }
    for (final c in state.pmConversations) {
      if (c.pubkey == pubkey && c.nym != nym) {
        c.nym = nym;
        changed = true;
      }
    }
    if (changed) _scheduleEmit();
  }

  /// Opens or creates a PM conversation without a message.
  void ensurePMConversation(String peerPubkey, {String? nym}) {
    final wasClosed = _closedPMs.remove(peerPubkey);
    _closedPMTimes.remove(peerPubkey);
    if (wasClosed) onClosedPmsChanged?.call();
    final exists = state.pmConversations.any((c) => c.pubkey == peerPubkey);
    if (!exists) {
      // Prefer the users-map nym, then [nym], then the `nym#xxxx` default.
      final known = state.users[peerPubkey]?.nym;
      state.pmConversations.add(PMConversation(
        pubkey: peerPubkey,
        nym: (known != null && known.isNotEmpty)
            ? known
            : (nym ?? getNymFromPubkey('nym', peerPubkey)),
        lastMessageTime: DateTime.now().millisecondsSinceEpoch,
      ));
      onPMConversationAdded?.call(peerPubkey);
      _scheduleEmit();
    } else {
      if (_syncPmConversationNym(peerPubkey)) _scheduleEmit();
    }
  }

  /// Restores the closed-PM set and close times at boot.
  void hydrateClosedPMs(Set<String> closed, Map<String, int> closedTimes) {
    if (closed.isEmpty && closedTimes.isEmpty) return;
    _closedPMs.addAll(closed);
    _closedPMTimes.addAll(closedTimes);
  }

  /// Merges synced closed PMs: set union, and per-key max of close times.
  void mergeClosedPmSync(Iterable<String> closed, Map<String, int> times) {
    var changed = false;
    for (final pk in closed) {
      if (pk.isNotEmpty && _closedPMs.add(pk)) changed = true;
    }
    times.forEach((pk, ts) {
      if (ts <= 0) return;
      if (ts > (_closedPMTimes[pk] ?? 0)) {
        _closedPMTimes[pk] = ts;
        changed = true;
      }
    });
    if (changed) onClosedPmsChanged?.call();
  }

  /// Merges left groups (union, newest leave time) and drops newly-left groups from the live store; idempotent.
  void mergeLeftGroups(Set<String> ids, Map<String, int> times) {
    if (ids.isEmpty && times.isEmpty) return;
    _leftGroups.addAll(ids);
    times.forEach((gid, ts) {
      if (ts > (_leftGroupTimes[gid] ?? 0)) _leftGroupTimes[gid] = ts;
    });
    var changed = false;
    for (final gid in _leftGroups) {
      final idx = state.groups.indexWhere((g) => g.id == gid);
      if (idx < 0) continue;
      state.groups.removeAt(idx);
      state.messages.remove(GroupLogic.groupStorageKey(gid));
      changed = true;
    }
    if (changed) _scheduleEmit();
  }

  Set<String> get leftGroups => Set.unmodifiable(_leftGroups);
  Map<String, int> get leftGroupTimes => Map.unmodifiable(_leftGroupTimes);

  Map<String, int> get closedPmTimes => Map.unmodifiable(_closedPMTimes);

  /// One-shot hint for the columns deck to spawn a new column instead of repurposing the primary.
  bool _forceNewColumnHint = false;

  int _viewSwitchCount = 0;

  int get viewSwitchCount => _viewSwitchCount;

  ChatView get currentView => state.view;

  AppState get currentState => state;

  bool consumeForceNewColumnHint() {
    final v = _forceNewColumnHint;
    _forceNewColumnHint = false;
    return v;
  }

  void switchView(ChatView view, {bool forceNewColumn = false}) {
    // Canonicalize PM ids to lowercase hex here, since every downstream match is exact.
    if (view.kind == ViewKind.pm &&
        _hex64AnyCaseRe.hasMatch(view.id) &&
        view.id != view.id.toLowerCase()) {
      view = ChatView.pm(view.id.toLowerCase());
    }
    final viewGateFn = viewGate;
    if (viewGateFn != null && !viewGateFn(state.view, view)) return;
    _forceNewColumnHint = forceNewColumn;
    _viewSwitchCount++;
    final entering = onViewEntering;
    if (entering != null) {
      try {
        entering(state.view.storageKey, view.storageKey, columnsReadGate != null);
      } catch (_) {}
    }
    // Clear unread and stamp the watermark on entry; in columns view only when the column read gate passes.
    final gate = columnsReadGate;
    if (gate == null || gate(view.storageKey)) {
      state.unreadCounts.remove(view.id);
      state.unreadCounts.remove(view.storageKey);
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      markChannelRead(view.id, nowSec);
      markChannelRead(view.storageKey, nowSec);
    }
    state = state.copyWith(view: view);
    // Best-effort D1 history backfill on open.
    final cb = onViewOpened;
    if (cb != null) {
      try {
        cb(view);
      } catch (_) {}
    }
  }

  // Social / moderation.

  /// Toggles [pubkey] as a friend; returns true when now a friend.
  bool toggleFriend(String pubkey) {
    if (pubkey.isEmpty) return state.friends.contains(pubkey);
    final bool nowFriend;
    if (state.friends.contains(pubkey)) {
      state.friends.remove(pubkey);
      nowFriend = false;
    } else {
      state.friends.add(pubkey);
      nowFriend = true;
    }
    _scheduleEmit();
    return nowFriend;
  }

  void addFriend(String pubkey) {
    if (pubkey.isEmpty) return;
    if (state.friends.add(pubkey)) _scheduleEmit();
  }

  void removeFriend(String pubkey) {
    if (state.friends.remove(pubkey)) _scheduleEmit();
  }

  /// Blocks [pubkey] and hides their messages; returns true if newly blocked.
  bool blockUser(String pubkey) {
    if (pubkey.isEmpty) return false;
    final added = state.blockedUsers.add(pubkey);
    if (added) {
      _dropSenderInfluence(pubkey);
      _scheduleEmit();
    }
    return added;
  }

  void _dropSenderInfluence(String pubkey) {
    state.messages.forEach((key, list) {
      var counted = 0;
      var senderNewest = 0;
      var visibleNewest = 0;
      final unreadKey = key.startsWith('pm-') ? key.substring(3) : key;
      for (final m in list) {
        if (m.pubkey == pubkey && !m.isOwn && !m.isSystemRow) {
          if (m.timestamp > senderNewest) senderNewest = m.timestamp;
          if (_isUnreadByWatermark(unreadKey, m)) counted++;
        } else if (m.timestamp > visibleNewest && !state.isMessageFiltered(m)) {
          visibleNewest = m.timestamp;
        }
      }
      if (senderNewest == 0) return;
      final unread = state.unreadCounts[unreadKey];
      if (unread != null && counted > 0) {
        if (unread > counted) {
          state.unreadCounts[unreadKey] = unread - counted;
        } else {
          state.unreadCounts.remove(unreadKey);
        }
      }
      final activity = state.channelLastActivity[key];
      if (activity != null && activity <= senderNewest) {
        if (visibleNewest > 0) {
          state.channelLastActivity[key] = visibleNewest;
        } else {
          state.channelLastActivity.remove(key);
        }
      }
    });
  }

  bool unblockUser(String pubkey) {
    final removed = state.blockedUsers.remove(pubkey);
    if (removed) _scheduleEmit();
    return removed;
  }

  static const Duration autoMuteDuration = Duration(hours: 24);

  bool autoMuteUser(String pubkey, {DateTime? now}) {
    if (pubkey.isEmpty || pubkey == state.selfPubkey) return false;
    if (state.friends.contains(pubkey) ||
        kVerifiedBotPubkeys.contains(pubkey)) {
      return false;
    }
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final fresh = !state.isAutoMuted(pubkey);
    final until = t + autoMuteDuration.inMilliseconds;
    state.autoMutedUsers[pubkey] = until;
    if (!fresh) return false;
    _dropSenderInfluence(pubkey);
    _scheduleEmit();
    onAutoMuted?.call(pubkey, until);
    return true;
  }

  bool clearAutoMute(String pubkey) {
    final removed = state.autoMutedUsers.remove(pubkey) != null;
    if (removed) _scheduleEmit();
    return removed;
  }

  void hydrateAutoMuted(Map<String, int> entries, {DateTime? now}) {
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    entries.forEach((pk, until) {
      if (pk.isNotEmpty && until > t) state.autoMutedUsers[pk] = until;
    });
  }

  void removeBlockedUser(String pubkey) => unblockUser(pubkey);

  void removeHiddenChannel(String key) => unhideChannel(key);

  void removeBlockedChannel(String key) => unblockChannel(key);

  /// Toggles [pubkey]'s blocked state; returns true when now blocked.
  bool toggleBlockUser(String pubkey) {
    if (state.blockedUsers.contains(pubkey)) {
      unblockUser(pubkey);
      return false;
    }
    blockUser(pubkey);
    return true;
  }

  /// Adds a lowercased, trimmed keyword; returns it, or null when empty or duplicate.
  String? addBlockedKeyword(String keyword) {
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty) return null;
    if (!state.blockedKeywords.add(kw)) return null;
    _scheduleEmit();
    return kw;
  }

  bool removeBlockedKeyword(String keyword) {
    final removed = state.blockedKeywords.remove(keyword.toLowerCase());
    if (removed) _scheduleEmit();
    return removed;
  }

  /// Hydrates the social sets from KV at boot; keywords are lowercased.
  void hydrateSocialState({
    Set<String>? friends,
    Set<String>? blockedUsers,
    Set<String>? blockedKeywords,
    Set<String>? pinnedChannels,
    Set<String>? hiddenChannels,
    Set<String>? blockedChannels,
  }) {
    if (friends != null) state.friends.addAll(friends);
    if (blockedUsers != null) state.blockedUsers.addAll(blockedUsers);
    if (blockedKeywords != null) {
      state.blockedKeywords.addAll(blockedKeywords.map((k) => k.toLowerCase()));
    }
    // Fold channel keys to lowercase rather than trust an older build's casing.
    if (pinnedChannels != null) {
      state.pinnedChannels.addAll(pinnedChannels.map((k) => k.toLowerCase()));
    }
    if (hiddenChannels != null) {
      state.hiddenChannels.addAll(hiddenChannels.map((k) => k.toLowerCase()));
    }
    if (blockedChannels != null) {
      state.blockedChannels.addAll(blockedChannels.map((k) => k.toLowerCase()));
    }
    _scheduleEmit();
  }

  /// Replaces a stored message's content and flags it edited; no-op if not found.
  bool applyLocalEdit(String messageId, String newContent,
      {String? authorPubkey, int editAt = 0}) {
    var changed = false;
    for (final list in state.messages.values) {
      for (final m in list) {
        if ((m.id == messageId || m.nymMessageId == messageId) &&
            (authorPubkey == null || m.pubkey == authorPubkey)) {
          if (m.content != newContent) {
            onBeforeEdit?.call(m, newContent, editAt);
          }
          if (authorPubkey == null) {
            final head = EditCandidate(
                newContent,
                editAt > 0
                    ? editAt
                    : DateTime.now().millisecondsSinceEpoch ~/ 1000);
            _setEditHead('${m.id}|${m.pubkey}', head);
            final nid = m.nymMessageId;
            if (nid != null && nid.isNotEmpty) {
              _setEditHead('$nid|${m.pubkey}', head);
            }
          }
          m.content = newContent;
          m.isEdited = true;
          changed = true;
        }
      }
    }
    if (changed) _scheduleEmit();
    return changed;
  }

  /// Applies an incoming edit in place, or buffers it until the original arrives; never append it as a new message.
  void applyEditOrDefer(String originalId, String newContent,
      {required String editorPubkey,
      bool verified = true,
      int editAt = 0,
      String editId = ''}) {
    if (!verified || originalId.isEmpty || editorPubkey.isEmpty) return;
    final cand = EditCandidate(newContent,
        editAt > 0 ? editAt : DateTime.now().millisecondsSinceEpoch ~/ 1000,
        editId);
    final headKey = '$originalId|$editorPubkey';
    final target = _findEditTarget(originalId, editorPubkey);
    if (target != null) {
      final verdict = editVerdict(_editHeads[headKey], cand, target.createdAt);
      if (verdict == 'stale') {
        onStaleEdit?.call(target, cand.text, cand.at);
        return;
      }
      if (verdict == 'invalid') return;
      _setEditHead(headKey, cand);
      applyLocalEdit(originalId, newContent,
          authorPubkey: editorPubkey, editAt: cand.at);
    } else if (!_hasMessageWithId(originalId)) {
      final prior = _editHeads[headKey];
      final verdict = editVerdict(prior, cand, 0);
      if (verdict == 'stale') {
        _parkStaleEdit(headKey, cand);
        return;
      }
      if (verdict != 'apply') return;
      if (prior != null) _parkStaleEdit(headKey, prior);
      _setEditHead(headKey, cand);
      final byEditor =
          _pendingEdits.putIfAbsent(originalId, () => <String, String>{});
      byEditor.remove(editorPubkey);
      byEditor[editorPubkey] = newContent;
      _pendingEditAt[headKey] = cand.at;
      if (_pendingEditAt.length > 4000) {
        _pendingEditAt.remove(_pendingEditAt.keys.first);
      }
      if (byEditor.length > 8) byEditor.remove(byEditor.keys.first);
      // Bound the buffer for originals that never land.
      if (_pendingEdits.length > 2000) {
        _pendingEdits.remove(_pendingEdits.keys.first);
      }
    }
  }

  /// Applies and clears any buffered edit for a just-ingested message; returns true if applied.
  bool _consumePendingEdit({String? id, String? nymMessageId}) {
    if (_pendingEdits.isEmpty) return false;
    String? hitKey;
    if (id != null && id.isNotEmpty && _pendingEdits.containsKey(id)) {
      hitKey = id;
    } else if (nymMessageId != null &&
        nymMessageId.isNotEmpty &&
        _pendingEdits.containsKey(nymMessageId)) {
      hitKey = nymMessageId;
    }
    if (hitKey == null) return false;
    final pending = _pendingEdits.remove(hitKey);
    if (pending == null) return false;
    var applied = false;
    for (final entry in pending.entries) {
      final headKey = '$hitKey|${entry.key}';
      final at = _pendingEditAt.remove(headKey) ?? 0;
      final stale = _staleEdits.remove(headKey) ?? const <EditCandidate>[];
      final target = _findEditTarget(hitKey, entry.key);
      if (target == null) continue;
      if (editVerdict(null, EditCandidate(entry.value, at), target.createdAt) ==
          'invalid') {
        continue;
      }
      if (applyLocalEdit(hitKey, entry.value,
          authorPubkey: entry.key, editAt: at)) {
        applied = true;
      }
      for (final s in stale) {
        if (editVerdict(null, s, target.createdAt) == 'invalid') continue;
        onStaleEdit?.call(target, s.text, s.at);
      }
    }
    return applied;
  }

  Message? _findEditTarget(String originalId, String authorPubkey) {
    for (final list in state.messages.values) {
      for (final m in list) {
        if ((m.id == originalId || m.nymMessageId == originalId) &&
            m.pubkey == authorPubkey) {
          return m;
        }
      }
    }
    return null;
  }

  void _setEditHead(String key, EditCandidate head) {
    _editHeads.remove(key);
    _editHeads[key] = head;
    if (_editHeads.length > 4000) _editHeads.remove(_editHeads.keys.first);
  }

  void _parkStaleEdit(String key, EditCandidate edit) {
    final list = _staleEdits.remove(key) ?? <EditCandidate>[];
    list.add(edit);
    if (list.length > ChatToolsLimits.editVersionsMax) list.removeAt(0);
    _staleEdits[key] = list;
    if (_staleEdits.length > 2000) _staleEdits.remove(_staleEdits.keys.first);
  }

  bool _hasMessageWithId(String messageId) {
    for (final list in state.messages.values) {
      for (final m in list) {
        if (m.id == messageId || m.nymMessageId == messageId) return true;
      }
    }
    return false;
  }

  // Inbound NIP-09 deletions.

  /// Ids verified as NIP-09 deleted so replays can't resurrect them; capped at 5000, pruned to the newest 4000.
  final Set<String> _deletedEventIds = <String>{};

  Set<String> get deletedEventIds => Set.unmodifiable(_deletedEventIds);

  /// Deletions awaiting their original: deleted id → claimant pubkeys.
  final Map<String, Set<String>> _pendingDeletions = <String, Set<String>>{};

  /// Fired when [_deletedEventIds] grows so the controller can persist it.
  void Function()? onDeletedIdsChanged;

  void hydrateDeletedIds(Set<String> ids) {
    _deletedEventIds.addAll(ids);
  }

  /// Applies a NIP-09 deletion; only the original author may delete, and unknown originals are parked.
  void ingestDeletionEvent(NostrEvent e) {
    final requester = e.pubkey;
    if (requester.isEmpty) return;
    var deleted = false;
    for (final t in e.tagsNamed('e')) {
      if (t.length < 2 || t[1].isEmpty) continue;
      final deletedId = t[1];
      final originalAuthor = findMessageAuthor(deletedId, author: requester);
      if (originalAuthor != null && originalAuthor != requester) continue;
      if (originalAuthor == null) {
        (_pendingDeletions[deletedId] ??= <String>{}).add(requester);
        if (_pendingDeletions.length > 5000) {
          final entries = _pendingDeletions.entries.toList();
          _pendingDeletions
            ..clear()
            ..addEntries(entries.sublist(entries.length - 4000));
        }
        continue;
      }
      _applyVerifiedDeletion(deletedId, author: requester);
      deleted = true;
    }
    if (deleted) onDeletedIdsChanged?.call();
  }

  void retractMessage(String eventId) {
    if (eventId.isEmpty) return;
    _applyVerifiedDeletion(eventId);
    onDeletedIdsChanged?.call();
  }

  /// The stored author of the message with [id] (event id or nymMessageId), or null.
  String? findMessageAuthor(String id, {String? author}) {
    if (id.isEmpty) return null;
    if (author != null && author.isNotEmpty && _hasMessageBy(id, author)) {
      return author;
    }
    final m = _msgByAnyId[id];
    if (m == null) return null;
    return m.pubkey.isEmpty ? null : m.pubkey;
  }

  bool _hasMessageBy(String id, String author) {
    final indexed = _msgByAnyId[id];
    if (indexed != null && indexed.pubkey == author) return true;
    for (final list in state.messages.values) {
      for (final m in list) {
        if ((m.id == id || m.nymMessageId == id) && m.pubkey == author) {
          return true;
        }
      }
    }
    return false;
  }

  /// Records [deletedId] and its paired id as deleted and removes the message everywhere.
  void _applyVerifiedDeletion(String deletedId, {String? author}) {
    if (author == null) {
      _deletedEventIds.add(deletedId);
    } else {
      _deletedEventIds.add(_scopedDeletedId(author, deletedId));
    }
    // Pair with the message's other id so a delivery keyed on either form is suppressed.
    final m = _msgByAnyId[deletedId];
    if (m != null && (author == null || m.pubkey == author)) {
      final nid = m.nymMessageId;
      if (author == null) {
        if (m.id.isNotEmpty) _deletedEventIds.add(m.id);
        if (nid != null && nid.isNotEmpty) _deletedEventIds.add(nid);
      } else {
        if (m.id.isNotEmpty) {
          _deletedEventIds.add(_scopedDeletedId(author, m.id));
        }
        if (nid != null && nid.isNotEmpty) {
          _deletedEventIds.add(_scopedDeletedId(author, nid));
        }
      }
    }
    if (_deletedEventIds.length > 5000) {
      final arr = _deletedEventIds.toList();
      _deletedEventIds
        ..clear()
        ..addAll(arr.sublist(arr.length - 4000));
    }
    removeMessage(deletedId, author: author);
  }

  static String _scopedDeletedId(String author, String id) => '$author:$id';

  /// True when [m] was already deleted, or a parked deletion from the same author matches it.
  bool suppressDeletedMessage(Message m) {
    final nid = m.nymMessageId;
    if (_deletedEventIds.contains(m.id) ||
        (nid != null && _deletedEventIds.contains(nid))) {
      return true;
    }
    if (m.pubkey.isEmpty) return false;
    if ((m.id.isNotEmpty &&
            _deletedEventIds.contains(_scopedDeletedId(m.pubkey, m.id))) ||
        (nid != null &&
            nid.isNotEmpty &&
            _deletedEventIds.contains(_scopedDeletedId(m.pubkey, nid)))) {
      return true;
    }
    for (final id in <String>[m.id, if (nid != null && nid.isNotEmpty) nid]) {
      if (id.isEmpty) continue;
      final claimants = _pendingDeletions[id];
      if (claimants != null && claimants.contains(m.pubkey)) {
        _pendingDeletions.remove(id);
        if (m.id.isNotEmpty) {
          _deletedEventIds.add(_scopedDeletedId(m.pubkey, m.id));
        }
        if (nid != null && nid.isNotEmpty) {
          _deletedEventIds.add(_scopedDeletedId(m.pubkey, nid));
        }
        onDeletedIdsChanged?.call();
        return true;
      }
    }
    return false;
  }

  /// Removes a message locally, matching event id or nymMessageId.
  List<String> sweepExpiredMessages(bool Function(Message m) hidden) {
    final touched = <String>[];
    state.messages.forEach((key, list) {
      if (!list.any((m) => m.expiresAt != null)) return;
      final before = list.length;
      list.removeWhere((m) {
        final hit = hidden(m);
        if (hit) _unindexMessage(m);
        return hit;
      });
      if (list.length != before) touched.add(key);
    });
    if (touched.isNotEmpty) {
      for (final k in touched) {
        onPmMessageIngested?.call(k);
      }
      _scheduleEmit();
    }
    return touched;
  }

  void touch() => _scheduleEmit();

  bool removeMessage(String messageId, {String? author, String? storageKey}) {
    var changed = false;
    bool matches(Message m) =>
        (m.id == messageId || m.nymMessageId == messageId) &&
        (author == null || m.pubkey == author);
    bool sweep(List<Message> list) {
      final before = list.length;
      list.removeWhere((m) {
        final hit = matches(m);
        if (hit) _unindexMessage(m);
        return hit;
      });
      return list.length != before;
    }

    if (storageKey != null) {
      final list = state.messages[storageKey];
      if (list != null && sweep(list)) changed = true;
      if (changed) _scheduleEmit();
      return changed;
    }
    final convKey = _convKeyByAnyId[messageId];
    if (convKey != null) {
      final list = state.messages[convKey];
      if (list != null && sweep(list)) changed = true;
    }
    if (convKey == null || (!changed && author != null)) {
      // Fall back to a full scan so a deletion is never skipped.
      for (final list in state.messages.values) {
        if (sweep(list)) changed = true;
      }
    }
    if (changed) _scheduleEmit();
    return changed;
  }

  /// Real reactor nyms for [messageId] / [emoji].
  List<String> reactorNyms(String messageId, String emoji) {
    final byEmoji = _reactors[messageId];
    if (byEmoji == null) return const [];
    final reactors = byEmoji[emoji];
    if (reactors == null) return const [];
    return reactors.values.where((n) => n.isNotEmpty).toList();
  }

  Map<String, String>? reactorsFor(String messageId, String emoji) =>
      _reactors[messageId]?[emoji];

  // Channel management; the controller persists via change callbacks.

  /// Adds a channel if not present; a non-empty [geohash] marks a geohash channel.
  ChannelEntry addChannel(String channel, {String geohash = ''}) {
    final key = (geohash.isNotEmpty ? geohash : channel).toLowerCase();
    final existing = state.channels.where((c) => c.key == key);
    if (existing.isNotEmpty) return existing.first;
    final entry = ChannelEntry(channel: channel, geohash: geohash);
    state.channels.add(entry);
    _scheduleEmit();
    return entry;
  }

  /// Switches to a channel, adding it first if unknown.
  void switchChannel(String channel, {String geohash = ''}) {
    final key = (geohash.isNotEmpty ? geohash : channel).toLowerCase();
    if (!state.channels.any((c) => c.key == key)) {
      addChannel(channel, geohash: geohash);
    }
    switchView(ChatView.channel(geohash.isNotEmpty ? geohash : channel));
  }

  /// Removes a channel (never `#nymchat`), switching to `#nymchat` if it was active; true if removed.
  bool removeChannel(String key) {
    final k = key.toLowerCase();
    if (k == kDefaultChannel) return false;
    final before = state.channels.length;
    state.channels.removeWhere((c) => c.key == k);
    state.pinnedChannels.remove(k);
    if (state.view.kind == ViewKind.channel &&
        state.view.id.toLowerCase() == k) {
      switchView(const ChatView.channel(kDefaultChannel));
    } else {
      _scheduleEmit();
    }
    return state.channels.length != before;
  }

  /// Toggles a channel's pinned state (no-op for `#nymchat`); returns the new state.
  bool togglePin(String key) {
    final k = key.toLowerCase();
    // #nymchat is always at the top; the PWA neither pins nor unpins it.
    if (k == kDefaultChannel) return state.pinnedChannels.contains(k);
    if (state.pinnedChannels.contains(k)) {
      state.pinnedChannels.remove(k);
      _scheduleEmit();
      return false;
    }
    state.pinnedChannels.add(k);
    _scheduleEmit();
    return true;
  }

  /// Hides a channel from the sidebar (never `#nymchat`); returns the new state.
  bool hideChannel(String key) {
    final k = key.toLowerCase();
    if (k == kDefaultChannel) return false;
    final added = state.hiddenChannels.add(k);
    if (added) _scheduleEmit();
    return added;
  }

  void unhideChannel(String key) {
    if (state.hiddenChannels.remove(key.toLowerCase())) {
      _scheduleEmit();
    }
  }

  /// Blocks a channel from discovery and the sidebar (never `#nymchat`), switching away if active.
  bool blockChannel(String key) {
    final k = key.toLowerCase();
    if (k == kDefaultChannel) return false;
    state.blockedChannels.add(k);
    state.channels.removeWhere((c) => c.key == k);
    // A block deliberately leaves the channel's favorite intact.
    if (state.view.kind == ViewKind.channel &&
        state.view.id.toLowerCase() == k) {
      switchView(const ChatView.channel(kDefaultChannel));
    } else {
      _scheduleEmit();
    }
    return true;
  }

  void unblockChannel(String key, {String geohash = ''}) {
    final k = key.toLowerCase();
    if (state.blockedChannels.remove(k)) {
      addChannel(geohash.isNotEmpty ? geohash : key, geohash: geohash);
    }
  }

  /// Hydrates channel sets from KV; [replace] replaces rather than unions them so remote unpins propagate.
  void hydrateChannelState({
    Set<String>? pinned,
    Set<String>? hidden,
    Set<String>? blocked,
    Map<String, int>? unreadCounts,
    Map<String, int>? lastActivity,
    List<ChannelEntry>? joinedChannels,
    bool replace = false,
  }) {
    if (replace) {
      if (pinned != null) {
        state.pinnedChannels
          ..clear()
          ..addAll(pinned);
      }
      if (hidden != null) {
        state.hiddenChannels
          ..clear()
          ..addAll(hidden);
      }
      if (blocked != null) {
        state.blockedChannels
          ..clear()
          ..addAll(blocked);
      }
    } else {
      if (pinned != null) state.pinnedChannels.addAll(pinned);
      if (hidden != null) state.hiddenChannels.addAll(hidden);
      if (blocked != null) state.blockedChannels.addAll(blocked);
    }
    if (unreadCounts != null) state.unreadCounts.addAll(unreadCounts);
    if (lastActivity != null) state.channelLastActivity.addAll(lastActivity);
    if (joinedChannels != null) {
      for (final c in joinedChannels) {
        if (state.blockedChannels.contains(c.key)) continue;
        if (!state.channels.any((x) => x.key == c.key)) {
          state.channels.add(c);
        }
      }
    }
    _scheduleEmit();
  }

  void hydrateMessages(String key, List<Message> msgs) {
    if (msgs.isEmpty) return;
    _hydrateMessagesInto(key, msgs);
    _scheduleEmit();
  }

  /// Boot hydration of all cached histories, seeding dedup ids and channel activity, with one emit at the end.
  void hydrateAllMessages(Map<String, List<Message>> byKey) {
    var changed = false;
    byKey.forEach((key, msgs) {
      if (key.isEmpty || msgs.isEmpty) return;
      // Re-key legacy-cased PM threads onto the canonical key so restored and live history share one thread.
      if (_hydrateMessagesInto(_canonicalPmStorageKey(key), msgs)) {
        changed = true;
      }
    });
    // Rebuild PM sidebar rows from hydrated threads; groups are skipped and closed PMs stay closed.
    for (final entry in state.messages.entries) {
      final msgs = entry.value;
      if (!entry.key.startsWith('pm-') || msgs.isEmpty) continue;
      if (msgs.any((m) => m.isGroup)) continue;
      String? peer;
      for (final m in msgs) {
        final p = m.conversationPubkey;
        if (p != null && p.isNotEmpty) {
          peer = p;
          break;
        }
      }
      if (peer == null) continue;
      // Canonical lowercase hex so the row matches exact routing and unread keys.
      if (_hex64AnyCaseRe.hasMatch(peer)) peer = peer.toLowerCase();
      if (_closedPMs.contains(peer)) continue;
      if (state.pmConversations.any((c) => c.pubkey == peer)) continue;
      final ts = msgs.last.timestamp;
      final known = state.users[peer]?.nym;
      state.pmConversations.add(PMConversation(
        pubkey: peer,
        nym: (known != null && known.isNotEmpty)
            ? known
            : getNymFromPubkey('nym', peer),
        lastMessageTime: ts > 0 ? ts : DateTime.now().millisecondsSinceEpoch,
      ));
      onPMConversationAdded?.call(peer);
      changed = true;
    }
    if (changed) _scheduleEmit();
  }

  /// Lowercases the peer id of a `pm-<pubkey>` key; other keys pass through.
  String _canonicalPmStorageKey(String key) {
    if (!key.startsWith('pm-')) return key;
    final id = key.substring(3);
    if (_hex64AnyCaseRe.hasMatch(id) && id != id.toLowerCase()) {
      return 'pm-${id.toLowerCase()}';
    }
    return key;
  }

  /// Dedup-seeds, appends and re-sorts one key's cached messages; returns true if any landed; doesn't emit.
  bool _hydrateMessagesInto(String key, List<Message> msgs) {
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    var added = false;
    var lastTs = 0;
    final isChannelKey = !key.startsWith('pm-') && !key.startsWith('group-');
    for (final m in msgs) {
      if (m.id.isNotEmpty && !_seenIds.add(m.id)) continue;
      _seedAuthorFromStore(m);
      m.seq = _nextIngestSeq();
      list.add(m);
      _indexMessage(key, m);
      added = true;
      if (m.timestamp > lastTs && !state.isMessageFiltered(m)) {
        lastTs = m.timestamp;
      }
    }
    if (added) list.sort(compareMessages);
    if (added && key.startsWith('pm-')) pruneForeignBotThreads(key);
    // Apply the live retention cap to hydrated channels too.
    if (isChannelKey) _capChannelHistory(list);
    // Only channel keys feed the sidebar recency sort.
    if (lastTs > 0 && isChannelKey) {
      if (lastTs > (state.channelLastActivity[key] ?? 0)) {
        state.channelLastActivity[key] = lastTs;
      }
    }
    return added;
  }

  final Map<String, List<Message>> _botThreadOrphans = <String, List<Message>>{};

  bool holdForeignBotThread(Message m) {
    final peer = m.conversationPubkey;
    if (peer == null) return false;
    final key =
        _canonicalPmStorageKey(m.conversationKey ?? PmLogic.pmStorageKey(peer));
    final list = state.messages[key] ?? const <Message>[];
    if (!botThreadForeign(m, list)) return false;
    _holdBotThreadOrphan(m);
    return true;
  }

  void _holdBotThreadOrphan(Message m) {
    final root = m.threadRoot;
    if (root == null || root.isEmpty) return;
    final held = _botThreadOrphans.putIfAbsent(root, () => <Message>[]);
    final nymId = m.nymMessageId;
    if (held.any((e) =>
        e.id == m.id ||
        (nymId != null && nymId.isNotEmpty && e.nymMessageId == nymId))) {
      return;
    }
    held.add(m);
    if (held.length > 50) held.removeRange(0, held.length - 50);
    if (_botThreadOrphans.length > 500) {
      _botThreadOrphans.remove(_botThreadOrphans.keys.first);
    }
  }

  int _adoptBotThreadOrphans(String key, List<Message> list, Message root) {
    if (root.threadRoot != null || _botThreadOrphans.isEmpty) return 0;
    final held = _botThreadOrphans.remove(threadKeyForMessage(root));
    if (held == null || held.isEmpty) return 0;
    var added = 0;
    for (final m in held) {
      final peer = m.conversationPubkey;
      if (peer == null) continue;
      final mine = _canonicalPmStorageKey(
          m.conversationKey ?? PmLogic.pmStorageKey(peer));
      if (mine != key) continue;
      if (list.any((e) => e.id == m.id)) continue;
      m.seq = _nextIngestSeq();
      _insertMessageSorted(key, list, m);
      added++;
    }
    if (added > 0) _scheduleEmit();
    return added;
  }

  int pruneForeignBotThreads(String key) {
    final list = state.messages[key];
    if (list == null || list.isEmpty) return 0;
    final drop = Set<Message>.identity();
    for (final m in list) {
      if (botThreadForeign(m, list)) drop.add(m);
    }
    if (drop.isEmpty) return 0;
    list.removeWhere(drop.contains);
    return drop.length;
  }

  void hydrateProfiles(Map<String, UserProfile> profiles) {
    final touched = <String>[];
    profiles.forEach((pubkey, hydrated) {
      final p = pinVerifiedBotMedia(pubkey, hydrated);
      touched.add(pubkey);
      final existing = state.users[pubkey];
      // Same name chain and cap as live kind-0 ingest.
      final resolvedName = _kind0DisplayName(p);
      if (existing != null) {
        if (existing.profile == null ||
            p.kind0Ts >= existing.profile!.kind0Ts) {
          existing.profile = p;
          if (resolvedName != null) {
            existing.nym = getNymFromPubkey(resolvedName, pubkey);
          }
        }
      } else {
        // The PWA never shows 'anon'.
        state.users[pubkey] = User(
          pubkey: pubkey,
          nym: getNymFromPubkey(resolvedName ?? 'nym', pubkey),
          profile: p,
        );
      }
    });
    for (final pubkey in touched) {
      _rewriteStoredAuthors(pubkey);
      _syncPmConversationNym(pubkey);
    }
    // Restore the header nym from the cached self profile before a live kind-0 (which the no-op guard may skip).
    String? selfNym;
    if (state.selfPubkey.isNotEmpty) {
      final stored = state.users[state.selfPubkey]?.profile;
      final name = stored == null ? null : _kind0DisplayName(stored);
      if (name != null) {
        final resolved = getNymFromPubkey(name, state.selfPubkey);
        if (resolved != state.selfNym) selfNym = resolved;
      }
    }
    state = state.copyWith(selfNym: selfNym);
  }

  /// Hydrates cached reactions (`[[emoji,[[reactor,nym]]]]`) and recomputes tallies.
  void hydrateReactions(Map<String, List<dynamic>> entriesByMessage) {
    entriesByMessage.forEach((messageId, entries) {
      // Placeholder ids are session-local; restoring one would graft a reaction onto an unrelated message.
      if (messageId.startsWith('_optim_')) return;
      final byEmoji = _reactors.putIfAbsent(messageId, () => {});
      for (final e in entries) {
        if (e is! List || e.length < 2) continue;
        final emoji = e[0].toString();
        final reactors = e[1];
        if (reactors is! List) continue;
        final map = byEmoji.putIfAbsent(emoji, () => {});
        for (final r in reactors) {
          if (r is List && r.isNotEmpty) {
            map[r[0].toString()] = r.length > 1 ? r[1].toString() : '';
          }
        }
      }
      _recomputeReactionTally(messageId);
    });
    _scheduleEmit();
  }

  /// Snapshot of reactions in the CacheStore `entries` shape.
  Map<String, List<dynamic>> reactionEntriesSnapshot() {
    final out = <String, List<dynamic>>{};
    _reactors.forEach((messageId, byEmoji) {
      // Never persist placeholder-keyed reactions.
      if (messageId.startsWith('_optim_')) return;
      final entries = <dynamic>[];
      byEmoji.forEach((emoji, reactors) {
        entries.add([
          emoji,
          reactors.entries.map((e) => [e.key, e.value]).toList(),
        ]);
      });
      if (entries.isNotEmpty) out[messageId] = entries;
    });
    return out;
  }

  /// Records channel activity so the sort floats it up.
  void touchChannelActivity(String storageKey, {int? ms}) {
    state.channelLastActivity[storageKey] =
        ms ?? DateTime.now().millisecondsSinceEpoch;
    _scheduleEmit();
  }

  /// Seeds sidebar discovery, last activity and (with [seedUnread]) unread floors from a D1 activity probe.
  void applyChannelActivity(
    Map<String, List<int>> activity,
    Map<String, int> last, {
    bool geohash = false,
    bool seedUnread = false,
  }) {
    if (activity.isEmpty && last.isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var changed = false;

    // Stash geohash buckets for the globe heatmap, pruning blank or all-zero entries.
    if (geohash) {
      activity.forEach((rawKey, buckets) {
        final key = rawKey.toLowerCase();
        if (key.isEmpty || state.blockedChannels.contains(key)) return;
        final hasActivity = buckets.any((b) => b > 0);
        if (hasActivity) {
          state.geohashD1Activity[key] = List<int>.of(buckets);
        } else {
          state.geohashD1Activity.remove(key);
        }
      });
    }

    // Raise last activity to the newest D1 ts.
    last.forEach((rawKey, tsSec) {
      final key = rawKey.toLowerCase();
      if (key.isEmpty || tsSec <= 0) return;
      if (state.blockedChannels.contains(key)) return;
      final storageKey = '#$key';
      final tsMs = tsSec * 1000;
      if (tsMs > (state.channelLastActivity[storageKey] ?? 0)) {
        state.channelLastActivity[storageKey] = tsMs;
        changed = true;
      }
    });

    // Add the most recently active unlisted channels, up to the discovery limit.
    final candidates = <({String key, int ts})>[];
    activity.forEach((rawKey, buckets) {
      final key = rawKey.toLowerCase();
      if (key.isEmpty || key == kDefaultChannel) return;
      if (state.blockedChannels.contains(key) ||
          state.hiddenChannels.contains(key)) {
        return;
      }
      if (!_isSimpleChannelName(key)) return;
      if (state.channels.any((c) => c.key == key)) return;
      final tsMs = state.channelLastActivity['#$key'] ??
          _approxLastFromBuckets(buckets, nowMs);
      if (tsMs <= 0) return;
      candidates.add((key: key, ts: tsMs));
    });
    if (candidates.isNotEmpty) {
      candidates.sort((a, b) => b.ts.compareTo(a.ts));
      for (final c in candidates.take(_kDiscoverSidebarLimit)) {
        // Geohash discovery registers geohash channels; named discovery plain names.
        addChannel(c.key, geohash: geohash ? c.key : '');
        if ((state.channelLastActivity['#${c.key}'] ?? 0) < c.ts) {
          state.channelLastActivity['#${c.key}'] = c.ts;
        }
        changed = true;
      }
    }

    // Unread floors only for listed, non-active channels on spam-aware passes.
    if (seedUnread) {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      activity.forEach((rawKey, buckets) {
        final key = rawKey.toLowerCase();
        if (key.isEmpty) return;
        final storageKey = '#$key';
        // Never seed the open view or a blocked channel.
        if (state.view.kind == ViewKind.channel &&
            state.view.storageKey == storageKey) {
          return;
        }
        if (state.blockedChannels.contains(key)) return;
        if (!state.channels.any((c) => c.key == key)) return;
        // Sum only buckets after the newest of the '#key' and bare-key watermarks.
        final byStorage = _channelLastRead[storageKey] ?? 0;
        final byBare = _channelLastRead[key] ?? 0;
        final lastRead = byStorage > byBare ? byStorage : byBare;
        // Prorate the boundary bucket so read messages don't count; nothing is unread if D1's newest predates the watermark.
        final newest = last[key] ?? last[rawKey] ?? 0;
        if (lastRead > 0 && newest > 0 && newest <= lastRead) return;
        final windowSec =
            lastRead > 0 ? (nowSec - lastRead).clamp(0, 24 * 3600) : 24 * 3600;
        final whole = (windowSec ~/ 3600).clamp(0, 24);
        var count = 0;
        for (var h = 0; h < whole && h < buckets.length; h++) {
          if (buckets[h] > 0) count += buckets[h];
        }
        if (whole < 24 && whole < buckets.length && buckets[whole] > 0) {
          final fraction = (windowSec - whole * 3600) / 3600;
          if (fraction > 0) count += (buckets[whole] * fraction).floor();
        }
        if (count <= 0 && lastRead > 0 && newest > lastRead) count = 1;
        if (count <= 0) return;
        // D1 is a floor: only raise the badge.
        if (count > (state.unreadCounts[storageKey] ?? 0)) {
          state.unreadCounts[storageKey] = count;
          changed = true;
        }
      });
    }

    if (changed) _scheduleEmit();
  }

  /// Max never-opened channels one discovery pass adds to the sidebar.
  static const int _kDiscoverSidebarLimit = 30;

  /// True when [name] is a single run of letters/digits.
  static bool _isSimpleChannelName(String name) =>
      name.isNotEmpty &&
      RegExp(r'^[\p{L}\p{N}]+$', unicode: true).hasMatch(name);

  /// Approximates last activity from each bucket's older edge so it never outranks a known value; 0 if empty.
  static int _approxLastFromBuckets(List<int> buckets, int nowMs) {
    for (var h = 0; h < buckets.length; h++) {
      if (buckets[h] > 0) return nowMs - (h + 1) * 3600 * 1000;
    }
    return 0;
  }

  /// Appends a local echo of our message to the current view; PM/group sends pass [nymMessageId] for receipts.
  Message? sendLocal(String text,
      {String? nymMessageId,
      String? pubkeyOverride,
      String? authorOverride,
      Map<String, dynamic>? fileOffer,
      String? threadRoot,
      ChatView? viewOverride}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final view = viewOverride ?? state.view;
    final list = state.messages.putIfAbsent(view.storageKey, () => <Message>[]);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nowSec = nowMs ~/ 1000;
    // Pseudonymous sends echo under the per-message ephemeral pubkey and anon nym.
    final pubkey = pubkeyOverride ?? state.selfPubkey;
    final author = authorOverride ?? state.selfNym;

    final m = Message(
      id: '_optim_${_sessionNonce}_${_nextLocalSeq().toRadixString(36)}',
      pubkey: pubkey,
      author: author,
      content: trimmed,
      createdAt: nowSec,
      ms: nowMs,
      seq: _localSeq,
      isOwn: true,
      isPM: view.kind == ViewKind.pm,
      isGroup: view.kind == ViewKind.group,
      groupId: view.kind == ViewKind.group ? view.id : null,
      channel: view.kind == ViewKind.channel ? view.id : null,
      conversationKey: view.kind != ViewKind.channel ? view.storageKey : null,
      conversationPubkey: view.kind == ViewKind.pm ? view.id : null,
      nymMessageId: nymMessageId,
      threadRoot: threadRoot,
      deliveryStatus: DeliveryStatus.sent,
      senderVerified: true,
      isFileOffer: fileOffer != null,
      fileOffer: fileOffer,
    );
    if (view.kind != ViewKind.channel && absorbLiveHook?.call(m, list) == true) {
      if (nymMessageId != null) _seenNymMessageIds.add(nymMessageId);
      _scheduleEmit();
      return m;
    }
    list.add(m);
    m.optimistic = true;
    // Index PM/group echoes by nymMessageId so ephemeral receipts can find them; channels index via [replaceOptimistic].
    if (view.kind != ViewKind.channel) _indexMessage(view.storageKey, m);
    if (nymMessageId != null) _seenNymMessageIds.add(nymMessageId);

    // Own-message local-hide notices; the message is still sent, and file offers are exempt.
    if (fileOffer == null) {
      final keywordHit = state.hasBlockedKeyword(trimmed, author);
      if (keywordHit || state.blockedUsers.contains(pubkey)) {
        // Keyword/block hit: hidden locally, with a line explaining it was still sent.
        final reason = keywordHit
            ? tr('matched one of your blocked keywords')
            : tr('matched a block rule');
        showToast(tr(
            'Your message {reason} and was hidden locally. It was still sent.',
            {'reason': reason}));
      } else if (state.clientGatesActive &&
          SpamFilter.isSpamMessage(trimmed,
              enabled: appSpamFilterEnabled,
              aggressive: appSpamFilterAggressive)) {
        // Own heuristic spam isn't hidden from us; a self-only line offers "Report false positive".
        addSystemMessageWithAction(
          tr('Your message was flagged by the spam filter and not shown to '
              'anyone but yourself.'),
          SystemAction(
            kind: SystemActionKind.reportSpamFalsePositive,
            label: tr('Report false positive'),
            payload: trimmed,
          ),
        );
      }
    }

    // Bump the conversation's sort key on send so it jumps to the top immediately.
    if (view.kind == ViewKind.pm) {
      for (final conv in state.pmConversations) {
        if (conv.pubkey == view.id) {
          if (m.timestamp > conv.lastMessageTime) {
            conv.lastMessageTime = m.timestamp;
          }
          break;
        }
      }
    } else if (view.kind == ViewKind.group) {
      final g = groupById(view.id);
      if (g != null && m.timestamp > g.lastMessageTime) {
        g.lastMessageTime = m.timestamp;
      }
    }

    _scheduleEmit();
    return m;
  }

  /// Rewrites an optimistic channel echo to its signed event and registers [realId] so the relay echo dedups.
  void replaceOptimistic(
    String optimisticId,
    String realId, {
    int? realCreatedAt,
    int? realMs,
    int? powTarget,
  }) {
    if (realId.isEmpty) return;
    // Register the real id first so a racing relay echo can't slip a second copy through.
    final alreadySeen = !_seenIds.add(realId);
    for (final entry in state.messages.entries) {
      final key = entry.key;
      final list = entry.value;
      final idx = list.indexWhere((m) => m.id == optimisticId);
      if (idx < 0) continue;
      final m = list[idx];
      // A relay echo already landed, so drop the placeholder.
      final landed = list.where((x) => x.id == realId && !identical(x, m));
      if (alreadySeen && landed.isNotEmpty) {
        _unindexMessage(m);
        list.removeAt(idx);
        // Also collapse any stale failed twin, keeping the row that landed.
        _dropFailedOptimisticTwins(list, m.content, landed.first);
        _scheduleEmit();
        return;
      }
      final oldCreated = m.createdAt;
      // The placeholder was never indexed, so re-index under the real id.
      _unindexMessage(m);
      final placeholderId = m.id;
      m.id = realId;
      if (realCreatedAt != null && realCreatedAt > 0) {
        m.createdAt = realCreatedAt;
        m.timestamp = realCreatedAt * 1000;
      }
      if (realMs != null && realMs > 0) m.ms = realMs;
      if (powTarget != null) m.powTarget = powTarget;
      m.optimistic = false;
      _indexMessage(key, m);
      // Carry over reactions filed under the placeholder id.
      _migrateReactionKey(placeholderId, m.id);
      // Collapse stale failed placeholders of the same content (the common ordering).
      _dropFailedOptimisticTwins(list, m.content, m);
      if (oldCreated != m.createdAt) list.sort(compareMessages);
      _scheduleEmit();
      return;
    }
    // Placeholder gone; the registered real id still prevents a duplicate echo.
    _scheduleEmit();
  }

  /// Flips an optimistic channel echo to failed after the publish threw; no-op if gone.
  void markOptimisticFailed(String optimisticId) {
    for (final list in state.messages.values) {
      final idx = list.indexWhere((m) => m.id == optimisticId);
      if (idx < 0) continue;
      list[idx].deliveryStatus = DeliveryStatus.failed;
      _scheduleEmit();
      return;
    }
  }

  /// Upgrades the on-screen echo's PQ root verdict once known; never downgrades a definite legacy verdict.
  void markMessagePqRoot(String nymMessageId) {
    for (final list in state.messages.values) {
      final idx = list.indexWhere((m) => m.nymMessageId == nymMessageId);
      if (idx < 0) continue;
      if (list[idx].pqRoot) return;
      list[idx].pqRoot = true;
      _scheduleEmit();
      return;
    }
  }

  void markOwnMessagePq(String nymMessageId,
      {bool? pqEncrypted, bool? pqRoot, ({int pq, int total})? coverage}) {
    for (final list in state.messages.values) {
      final idx =
          list.indexWhere((m) => m.isOwn && m.nymMessageId == nymMessageId);
      if (idx < 0) continue;
      if (pqEncrypted != null) list[idx].pqEncrypted = pqEncrypted;
      if (pqRoot != null) list[idx].pqRoot = pqRoot;
      if (coverage != null) list[idx].pqCoverage = coverage;
      _scheduleEmit();
      return;
    }
  }

  /// Injects a system/action pill into [storageKey] or the active view.
  void addSystemMessage(String content,
      {bool action = false, String? storageKey}) {
    if (content.isEmpty) return;
    final key = storageKey ?? state.view.storageKey;
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    list.add(Message.system(content, action: action, createdAtMs: nowMs)
      ..seq = _nextLocalSeq());
    _scheduleEmit();
  }

  /// Like [addSystemMessage] but with an inline [SystemAction] button.
  void addSystemMessageWithAction(String content, SystemAction action,
      {String? storageKey}) {
    if (content.isEmpty) return;
    final key = storageKey ?? state.view.storageKey;
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    list.add(Message.systemWithAction(content, action, createdAtMs: nowMs)
      ..seq = _nextLocalSeq());
    _scheduleEmit();
  }
}

final appStateProvider =
    StateNotifierProvider<AppStateNotifier, AppState>((ref) {
  return AppStateNotifier();
});

final currentViewProvider = Provider<ChatView>((ref) {
  return ref.watch(appStateProvider).view;
});

final channelsProvider = Provider<List<ChannelEntry>>((ref) {
  return ref.watch(appStateProvider).channels;
});

final pmListProvider = Provider<List<PMConversation>>((ref) {
  final pms = [...ref.watch(appStateProvider).pmConversations];
  pms.sort((a, b) => b.lastMessageTime - a.lastMessageTime);
  return pms;
});

/// Returns a fresh view each emit because groups mutate in place and identity-only watchers must still rebuild.
final groupsProvider = Provider<List<Group>>((ref) {
  return UnmodifiableListView(ref.watch(appStateProvider).groups);
});

/// Users by pubkey, minus blocked users and keyword-matched nyms.
final usersProvider = Provider<Map<String, User>>((ref) {
  final s = ref.watch(appStateProvider);
  // Gibberish-nym filtering runs even with empty block sets, so the fast path is valid only when it can't fire.
  final gibberishActive =
      s.clientGatesActive && appSpamFilterEnabled && appSpamFilterAggressive;
  if (s.blockedUsers.isEmpty && s.blockedKeywords.isEmpty && !gibberishActive) {
    // Return a fresh view each emit because profiles mutate in place.
    return UnmodifiableMapView(s.users);
  }
  final out = <String, User>{};
  s.users.forEach((pubkey, user) {
    if (pubkey == s.selfPubkey) {
      out[pubkey] = user;
      return;
    }
    if (s.blockedUsers.contains(pubkey)) return;
    if (s.blockedKeywords.isNotEmpty && s.hasBlockedKeyword('', user.nym)) {
      return;
    }
    // Drop gibberish nyms for non-self non-friends, testing the base nym with its suffix stripped.
    if (gibberishActive &&
        !s.isFriend(pubkey) &&
        SpamFilter.isGibberishNym(stripPubkeySuffix(user.nym),
            enabled: appSpamFilterEnabled,
            aggressive: appSpamFilterAggressive)) {
      return;
    }
    out[pubkey] = user;
  });
  return out;
});

/// Filtered, ordered messages for [storageKey], shared by the single view and every column.
List<Message> visibleMessagesFor(AppState s, String storageKey) {
  final list = s.messages[storageKey] ?? const <Message>[];
  // Fast path only when nothing can filter; the spam filter is on by default.
  final canFilter = s.blockedUsers.isNotEmpty ||
      s.blockedKeywords.isNotEmpty ||
      appSpamFilterEnabled;
  var visible = canFilter
      ? list.where((m) => !s.isMessageFiltered(m)).toList()
      : [...list];
  if (visible.any((m) => m.expiresAt != null)) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    visible = visible.where((m) => !chatToolsHidden(m, nowSec)).toList();
  }
  // Thread replies are hidden from the flat view only when their root is present locally.
  if (appThreadsEnabled && visible.any((m) => m.threadRoot != null)) {
    final rootIds = <String>{
      for (final m in list)
        if (m.threadRoot == null) threadKeyForMessage(m),
    }..remove('');
    visible = visible
        .where((m) => m.threadRoot == null || !rootIds.contains(m.threadRoot))
        .toList();
  }
  if (visible.any((m) => m.threadRoot != null)) {
    visible = visible.where((m) => !botThreadForeign(m, list)).toList();
  }
  visible.sort(compareMessages);
  return visible;
}

bool plainlyVisible(AppState s, Message m) {
  if (m.expiresAt != null || m.threadRoot != null) return false;
  final canFilter = s.blockedUsers.isNotEmpty ||
      s.blockedKeywords.isNotEmpty ||
      appSpamFilterEnabled;
  return !canFilter || !s.isMessageFiltered(m);
}

/// The id a thread reply points at: nymMessageId for PM/group, event id for channels.
String threadKeyForMessage(Message m) =>
    (m.isPM || m.isGroup) ? (m.nymMessageId ?? m.id) : m.id;

bool botThreadForeign(Message m, List<Message> list) {
  if (!m.isPM || m.isGroup) return false;
  final root = m.threadRoot;
  if (root == null || root.isEmpty) return false;
  final peer = m.conversationPubkey;
  if (peer == null || peer.toLowerCase() != kNymbotPubkey) return false;
  for (final e in list) {
    if (identical(e, m)) continue;
    if (e.threadRoot == null && threadKeyForMessage(e) == root) return false;
  }
  return true;
}

/// Raw reply counts per thread root for one conversation.
Map<String, int> threadReplyCounts(AppState s, String storageKey) {
  if (!appThreadsEnabled) return const {};
  final list = s.messages[storageKey];
  if (list == null || list.isEmpty) return const {};
  final counts = <String, int>{};
  for (final m in list) {
    final root = m.threadRoot;
    if (root == null || root.isEmpty) continue;
    if (s.isMessageFiltered(m)) continue;
    counts[root] = (counts[root] ?? 0) + 1;
  }
  return counts;
}

List<Message> threadRepliesFor(AppState s, String storageKey, String rootId) {
  final list = s.messages[storageKey] ?? const <Message>[];
  final replies = list
      .where((m) => m.threadRoot == rootId && !s.isMessageFiltered(m))
      .toList()
    ..sort(compareMessages);
  return replies;
}

/// The open thread, identified by its conversation [view] and root thread key [rootId].
class ActiveThread {
  const ActiveThread({required this.view, required this.rootId});
  final ChatView view;
  final String rootId;

  @override
  bool operator ==(Object other) =>
      other is ActiveThread && other.view == view && other.rootId == rootId;

  @override
  int get hashCode => Object.hash(view, rootId);
}

final activeThreadProvider = StateProvider<ActiveThread?>((ref) => null);

/// A thread root needs a real shared id and must not itself be a reply.
bool threadEligibleRoot(Message m) {
  if (m.threadRoot != null || m.isSystemRow || m.isMeAction) return false;
  if (m.isPM || m.isGroup) return (m.nymMessageId ?? '').isNotEmpty;
  return m.id.length == 64 && !m.id.startsWith('_optim_');
}

/// Recomputed once per display revision and shared by every row.
final threadCountsProvider =
    Provider.family<Map<String, int>, String>((ref, storageKey) {
  ref.watch(appStateProvider.select((s) => s.displayRev));
  return threadReplyCounts(ref.read(appStateProvider), storageKey);
});

Message? threadRootMessage(AppState s, String storageKey, String rootId) {
  final list = s.messages[storageKey] ?? const <Message>[];
  for (final m in list) {
    if (m.threadRoot == null && threadKeyForMessage(m) == rootId) return m;
  }
  return null;
}

/// True when [threadRoot]'s reply is collapsed behind a thread that isn't open, so it was never on screen.
bool threadReplyHidden({
  required AppState state,
  required ActiveThread? openThread,
  required String storageKey,
  required String? threadRoot,
}) {
  if (!appThreadsEnabled) return false;
  if (threadRoot == null || threadRoot.isEmpty || storageKey.isEmpty) {
    return false;
  }
  if (threadRootMessage(state, storageKey, threadRoot) == null) return false;
  return openThread == null ||
      openThread.rootId != threadRoot ||
      openThread.view.storageKey != storageKey;
}

/// True when the thread's root is the user's own message, so replies notify like a mention.
bool threadRootIsOwn({
  required AppState state,
  required String storageKey,
  required String? threadRoot,
}) {
  if (!appThreadsEnabled) return false;
  if (threadRoot == null || threadRoot.isEmpty || storageKey.isEmpty) {
    return false;
  }
  return threadRootMessage(state, storageKey, threadRoot)?.isOwn ?? false;
}

/// Whether [threadRoot] marks a thread reply, handing its notification to the thread rules.
bool isThreadReplyMarker(String? threadRoot) =>
    appThreadsEnabled && threadRoot != null && threadRoot.isNotEmpty;

/// Ordered messages for the active view, via [visibleMessagesFor].
final messagesForCurrentViewProvider = Provider<List<Message>>((ref) {
  // Re-run only on view or display revision changes, not ambient emits.
  ref.watch(appStateProvider.select((s) => (s.view.storageKey, s.displayRev)));
  final s = ref.read(appStateProvider);
  return visibleMessagesFor(s, s.view.storageKey);
});

/// Id of the message showing its scroll-flash highlight, or null.
class FlashedMessageNotifier extends StateNotifier<String?> {
  FlashedMessageNotifier() : super(null);

  /// The PWA clears the class after 1.6s.
  static const Duration _flashDuration = Duration(milliseconds: 1600);

  Timer? _timer;

  /// Flashes [messageId], restarting the timer, and auto-clears after [_flashDuration].
  void flash(String messageId) {
    if (messageId.isEmpty) return;
    _timer?.cancel();
    // Clear then set on the next microtask so re-flashing the same id re-triggers the pulse.
    if (state == messageId) state = null;
    state = messageId;
    _timer = Timer(_flashDuration, () {
      if (mounted) state = null;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final flashedMessageProvider =
    StateNotifierProvider<FlashedMessageNotifier, String?>((ref) {
  return FlashedMessageNotifier();
});

final reactionsProvider = Provider<Map<String, List<MessageReaction>>>((ref) {
  // Reactions render in the list, so refresh on the display revision.
  ref.watch(appStateProvider.select((s) => s.displayRev));
  return ref.read(appStateProvider).reactions;
});

/// Unread counts (channel key / pm pubkey / group id → count).
final unreadCountsProvider = Provider<Map<String, int>>((ref) {
  return ref.watch(appStateProvider).unreadCounts;
});

final typingForCurrentViewProvider = Provider<List<String>>((ref) {
  final s = ref.watch(appStateProvider);
  final prefix = '${s.view.storageKey}|';
  final now = DateTime.now().millisecondsSinceEpoch;
  final out = <String>[];
  s.typing.forEach((k, expiry) {
    if (k.startsWith(prefix) && expiry > now) {
      out.add(k.substring(prefix.length));
    }
  });
  return out;
});

/// Polls in the active channel view, time-ordered; empty for PM/group views.
final pollsForCurrentViewProvider = Provider<List<Poll>>((ref) {
  // Poll cards render in the list, so refresh on view and display revision.
  ref.watch(appStateProvider.select((s) => (s.view.storageKey, s.displayRev)));
  final s = ref.read(appStateProvider);
  if (s.view.kind != ViewKind.channel) return const [];
  final geohash = s.view.id;
  final out = s.polls.values.where((p) => p.geohash == geohash).toList()
    ..sort((a, b) => a.createdAt - b.createdAt);
  return out;
});

final zapsProvider = Provider<Map<String, MessageZaps>>((ref) {
  return ref.watch(appStateProvider).zaps;
});

final friendsProvider = Provider<Set<String>>((ref) {
  return ref.watch(appStateProvider).friends;
});

final blockedUsersProvider = Provider<Set<String>>((ref) {
  return ref.watch(appStateProvider).blockedUsers;
});

final blockedKeywordsProvider = Provider<Set<String>>((ref) {
  return ref.watch(appStateProvider).blockedKeywords;
});

/// The user's geolocation for proximity sorting, or null when unavailable.
final userLocationProvider = StateProvider<UserLocation?>((ref) => null);

final sortedChannelsProvider = Provider<List<ChannelEntry>>((ref) {
  final s = ref.watch(appStateProvider);
  final sortByProximity = ref
      .watch(settingsProvider.select((settings) => settings.sortByProximity));
  // When on, only pinned channels (plus the default) are shown.
  final hideNonPinned =
      ref.watch(settingsProvider.select((settings) => settings.hideNonPinned));
  final location = ref.watch(userLocationProvider);
  final activeKey =
      s.view.kind == ViewKind.channel ? s.view.id.toLowerCase() : '';
  final visible = s.channels
      .where((c) => !s.blockedChannels.contains(c.key))
      .where((c) =>
          c.key == kDefaultChannel ||
          c.key == activeKey ||
          (!s.hiddenChannels.contains(c.key) &&
              !(hideNonPinned && !s.pinnedChannels.contains(c.key))))
      .toList();
  final sorted = ChannelManager.sortChannels(
    visible,
    ChannelSortContext(
      activeKey: activeKey,
      pinned: s.pinnedChannels,
      lastActivity: s.channelLastActivity,
      unreadCounts: s.unreadCounts,
      sortByProximity: sortByProximity,
      userLocation: location,
    ),
  );
  // Stable within each band, like flex `order` ties.
  int orderBand(ChannelEntry ch) {
    if (ch.key == kDefaultChannel) return -4;
    if (s.pinnedChannels.contains(ch.key)) return -3;
    if (ch.key == activeKey) return -2;
    if ((s.unreadCounts[ch.storageKey] ?? 0) > 0) return -1;
    return 0;
  }

  return [
    for (var band = -4; band <= 0; band++)
      ...sorted.where((ch) => orderBand(ch) == band),
  ];
});

// Recent emojis.

class RecentEmojisNotifier extends StateNotifier<List<String>> {
  RecentEmojisNotifier(this._ref) : super(const []) {
    _hydrate();
  }

  final Ref _ref;
  EmojiRecentsStore? _store;

  Future<void> _hydrate() async {
    try {
      final prefs = await _ref.read(emojiPrefsProvider.future);
      _store = EmojiRecentsStore(prefs);
      final loaded = _store!.load();
      if (mounted && loaded.isNotEmpty) state = loaded;
    } catch (_) {
      // Best-effort; an unavailable store yields empty recents.
    }
  }

  /// Records [emoji] as most recent and persists in the background.
  void record(String emoji) {
    if (emoji.isEmpty) return;
    state = addRecentEmoji(state, emoji);
    final store = _store;
    if (store != null) {
      store.add(emoji);
    } else {
      // Store not hydrated yet: hydrate, then persist this pick.
      _persistWhenReady(emoji);
    }
  }

  Future<void> _persistWhenReady(String emoji) async {
    try {
      final prefs = await _ref.read(emojiPrefsProvider.future);
      _store = EmojiRecentsStore(prefs);
      await _store!.add(emoji);
    } catch (_) {}
  }
}

final recentEmojisProvider =
    StateNotifierProvider<RecentEmojisNotifier, List<String>>(
  (ref) => RecentEmojisNotifier(ref),
);

// Notification history (24h-trimmed).

class NotificationEntry {
  NotificationEntry({
    required this.type,
    required this.title,
    required this.body,
    required this.ts,
    int? receivedAt,
    this.route,
    this.eventId,
    this.senderPubkey,
    this.contextLabel,
    this.threadRoot,
    this.viewed = false,
  }) : receivedAt = (receivedAt != null && receivedAt > 0) ? receivedAt : ts;

  /// `'message' | 'mention' | 'reaction' | 'call' | 'pm' | 'group' | …`.
  final String type;
  final String title;
  final String body;

  /// Milliseconds since epoch.
  final int ts;

  /// When this client first observed it (ms); viewed checks use this, falling back to [ts].
  final int receivedAt;

  /// Navigation target for taps (PM pubkey, channel key or group id), or null.
  final String? route;

  /// Source event id for dedup; mutable because sync merges adopt a synced copy's id.
  String? eventId;

  /// Sender pubkey for the no-eventId dedup fallback.
  final String? senderPubkey;

  /// Footer context label (`in #geohash` or `in <GroupName>`); null for PM/mention sources.
  final String? contextLabel;

  /// Source thread, so tapping opens it instead of the flat conversation.
  final String? threadRoot;
  bool viewed;

  /// Copy with [ts] clamped to [receivedAt], never to `now`, so re-running is idempotent.
  NotificationEntry clampedToObserved() => NotificationEntry(
        type: type,
        title: title,
        body: body,
        ts: ts > receivedAt ? receivedAt : ts,
        receivedAt: receivedAt,
        route: route,
        eventId: eventId,
        senderPubkey: senderPubkey,
        contextLabel: contextLabel,
        threadRoot: threadRoot,
        viewed: viewed,
      );

  /// `timestamp` is the PWA field name so either client's blob round-trips; nulls are omitted.
  Map<String, dynamic> toJson() => {
        'type': type,
        'title': title,
        'body': body,
        'timestamp': ts,
        if (receivedAt > 0) 'receivedAt': receivedAt,
        if (route != null) 'route': route,
        if (eventId != null) 'eventId': eventId,
        if (senderPubkey != null) 'senderPubkey': senderPubkey,
        if (contextLabel != null) 'contextLabel': contextLabel,
        if (threadRoot != null) 'threadRoot': threadRoot,
        if (viewed) 'viewed': true,
      };

  /// Rebuilds an entry from native JSON or a PWA `channelInfo` record; null when required fields are missing.
  static NotificationEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = raw['title'];
    final body = raw['body'];
    final ts = raw['timestamp'];
    if (title is! String || body is! String || ts is! num) return null;
    String? ciType;
    String? ciRoute;
    String? ciEventId;
    String? ciPubkey;
    String? ciThreadRoot;
    final ci = raw['channelInfo'];
    if (ci is Map) {
      if (ci['eventId'] is String) ciEventId = ci['eventId'] as String;
      if (ci['pubkey'] is String) ciPubkey = ci['pubkey'] as String;
      // The PWA files the thread on `channelInfo`, so synced entries still open their thread.
      if (ci['threadRoot'] is String) ciThreadRoot = ci['threadRoot'] as String;
      String? str(String k) => ci[k] is String ? ci[k] as String : null;
      switch (ci['type']) {
        case 'pm':
          ciType = 'pm';
          ciRoute = ciPubkey;
        case 'group':
          ciType = 'group';
          ciRoute = str('groupId');
        case 'geohash':
          ciType = 'mention';
          ciRoute = str('channel') ?? str('geohash');
        case 'reaction':
          ciType = 'reaction';
          ciRoute = switch (ci['sourceType']) {
            'pm' => str('sourcePubkey'),
            'group' => str('sourceGroupId'),
            'geohash' => str('sourceChannel') ?? str('sourceGeohash'),
            _ => null,
          };
      }
    }
    final receivedAt = raw['receivedAt'];
    return NotificationEntry(
      type:
          raw['type'] is String ? raw['type'] as String : (ciType ?? 'message'),
      title: title,
      body: body,
      ts: ts.toInt(),
      receivedAt: receivedAt is num ? receivedAt.toInt() : null,
      route: raw['route'] is String ? raw['route'] as String : ciRoute,
      eventId: raw['eventId'] is String ? raw['eventId'] as String : ciEventId,
      senderPubkey: raw['senderPubkey'] is String
          ? raw['senderPubkey'] as String
          : ciPubkey,
      contextLabel:
          raw['contextLabel'] is String ? raw['contextLabel'] as String : null,
      threadRoot: raw['threadRoot'] is String
          ? raw['threadRoot'] as String
          : ciThreadRoot,
      viewed: raw['viewed'] == true,
    );
  }
}

class NotificationHistoryState {
  const NotificationHistoryState({this.entries = const [], this.unread = 0});

  final List<NotificationEntry> entries;
  final int unread;

  NotificationHistoryState copyWith({
    List<NotificationEntry>? entries,
    int? unread,
  }) =>
      NotificationHistoryState(
        entries: entries ?? this.entries,
        unread: unread ?? this.unread,
      );
}

class NotificationHistoryNotifier
    extends StateNotifier<NotificationHistoryState> {
  /// [ref] is optional so tests can skip persistence and hydration.
  NotificationHistoryNotifier([this._ref])
      : super(const NotificationHistoryState()) {
    if (_ref != null) {
      _hydrating = true;
      _hydrate();
    }
  }

  final Ref? _ref;
  SharedPreferences? _prefs;

  /// Debounced history write, flushed on dispose.
  Timer? _historyPersistTimer;

  Timer? _seenKeysPersistTimer;

  /// True while hydrating; records arriving now are buffered and replayed so they dedup against the real history.
  bool _hydrating = false;
  final List<void Function()> _pendingRecords = [];

  /// Records buffered during hydration, exposed so the alert path can dedup against them.
  final List<NotificationEntry> _pendingEntries = [];

  /// Kept literal so the synced key matches the PWA byte-for-byte.
  static const String _historyKey = 'nym_notification_history';

  static const int _maxAgeMs = 24 * 60 * 60 * 1000; // 24h
  static const int _cap = 100;

  /// Seen keys (key → first-seen ms) synced so a notification read on one device is silenced on others.
  Map<String, int> _seenKeys = <String, int>{};

  /// Kept literal so the synced key matches the PWA byte-for-byte.
  static const String _seenKeysStoreKey = 'nym_notification_seen';
  static const int _seenKeysTtlMs = 48 * 60 * 60 * 1000; // 48h
  static const int _maxSeenKeys = 500;

  /// Synced "read before this" watermark (ms), only adopted from other devices; entries under it land pre-viewed.
  int _lastReadTimeMs = 0;
  static const String _lastReadStoreKey = 'nym_notification_last_read';

  int get notificationLastReadTime => _lastReadTimeMs;

  /// Fired when the seen map grows locally so the controller republishes; never by inbound merges.
  void Function()? onSeenChanged;

  /// Hydrates the 24h bell history at boot; best-effort.
  Future<void> _hydrate() async {
    final ref = _ref;
    if (ref == null) return;
    try {
      final prefs = await ref.read(emojiPrefsProvider.future);
      _prefs = prefs;
      // Merge rather than overwrite, since keys can arrive during the async window; re-persist if so.
      final seenRaw = prefs.getString(_seenKeysStoreKey);
      if (seenRaw != null && seenRaw.isNotEmpty) {
        final loaded = _decodeSeenKeys(seenRaw);
        if (_seenKeys.isEmpty) {
          _seenKeys = loaded;
        } else {
          loaded.forEach((k, v) => _seenKeys.putIfAbsent(k, () => v));
          _persistSeenKeys();
        }
      } else if (_seenKeys.isNotEmpty) {
        _persistSeenKeys();
      }
      // A sync adopt that raced hydration wins (monotonic max).
      final lastReadRaw = prefs.getString(_lastReadStoreKey);
      final lastRead = int.tryParse(lastReadRaw ?? '') ?? 0;
      if (lastRead > _lastReadTimeMs) _lastReadTimeMs = lastRead;
      final raw = prefs.getString(_historyKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final entries = <NotificationEntry>[];
      for (final item in decoded) {
        final e = NotificationEntry.fromJson(item);
        if (e == null) continue;
        if (now - e.ts >= _maxAgeMs) continue; // 24h window
        // Repair future-dated entries against their own observation time, not this launch's clock.
        entries.add(e.ts > e.receivedAt ? e.clampedToObserved() : e);
      }
      if (entries.isEmpty || !mounted) return;
      entries.sort((a, b) => b.ts.compareTo(a.ts)); // newest first
      if (entries.length > _cap) entries.removeRange(_cap, entries.length);
      state = NotificationHistoryState(
        entries: entries,
        unread: _countUnread(entries),
      );
    } catch (_) {
      // Best-effort; an unavailable or corrupt store yields an empty history.
    } finally {
      // Replay buffered records after the state overwrite so ingest never precedes hydration.
      _hydrating = false;
      _pendingEntries.clear();
      if (_pendingRecords.isNotEmpty && mounted) {
        final pending = List.of(_pendingRecords);
        _pendingRecords.clear();
        for (final replay in pending) {
          replay();
        }
      } else {
        _pendingRecords.clear();
      }
    }
  }

  /// Schedules a debounced write of the entries still within 24h; no-op in tests.
  void _persist() {
    if (_prefs == null) return;
    _historyPersistTimer?.cancel();
    _historyPersistTimer = Timer(const Duration(seconds: 2), () {
      _historyPersistTimer = null;
      _persistNow();
    });
  }

  void _persistNow() {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final recent = state.entries
          .where((e) => now - e.ts < _maxAgeMs)
          .map((e) => e.toJson())
          .toList();
      prefs.setString(_historyKey, jsonEncode(recent));
    } catch (_) {
      // Quota/serialization failures are non-fatal.
    }
  }

  @override
  void dispose() {
    // Flush pending writes so teardown never loses recent history.
    if (_historyPersistTimer != null) {
      _historyPersistTimer!.cancel();
      _historyPersistTimer = null;
      _persistNow();
    }
    if (_seenKeysPersistTimer != null) {
      _seenKeysPersistTimer!.cancel();
      _seenKeysPersistTimer = null;
      _persistSeenKeysNow();
    }
    super.dispose();
  }

  /// Blocked senders, excluded from the badge count.
  Set<String> _blocked = const {};

  /// Updates the blocked set and re-derives the unread count.
  void setBlocked(Set<String> blocked) {
    _blocked = blocked;
    final unread = _countUnread(state.entries);
    if (unread != state.unread) {
      state = state.copyWith(unread: unread);
    }
  }

  /// Unread count: within 24h, not viewed, sender not blocked, observed after the last-read watermark.
  static bool Function(NotificationEntry e)? lockedEntry;

  void recountUnread() {
    final unread = _countUnread(state.entries);
    if (unread != state.unread) state = state.copyWith(unread: unread);
  }

  void redactWhere(
      bool Function(NotificationEntry e) test, String title, String body) {
    var changed = false;
    final entries = [
      for (final e in state.entries)
        if (test(e) && (e.title != title || e.body != body || e.contextLabel != null))
          (() {
            changed = true;
            return NotificationEntry(
              type: e.type,
              title: title,
              body: body,
              ts: e.ts,
              receivedAt: e.receivedAt,
              route: e.route,
              eventId: e.eventId,
              senderPubkey: e.senderPubkey,
              threadRoot: e.threadRoot,
              viewed: e.viewed,
            );
          })()
        else
          e,
    ];
    if (!changed) return;
    state = state.copyWith(entries: entries, unread: _countUnread(entries));
    _persist();
  }

  int _countUnread(List<NotificationEntry> entries) {
    final cutoff = DateTime.now().millisecondsSinceEpoch - _maxAgeMs;
    final lastRead = _channelLastReadSnapshot();
    final locked = lockedEntry;
    return entries
        .where((e) =>
            !e.viewed &&
            !(locked != null && locked(e)) &&
            e.ts > cutoff &&
            // Observed at or under the synced watermark means read elsewhere.
            e.receivedAt > _lastReadTimeMs &&
            (_blocked.isEmpty || !_blocked.contains(e.senderPubkey)) &&
            !_alreadySeenByWatermark(e, lastRead))
        .length;
  }

  Map<String, int> _channelLastReadSnapshot() {
    final ref = _ref;
    if (ref == null) return const {};
    try {
      return ref.read(appStateProvider.notifier).channelLastRead;
    } catch (_) {
      return const {};
    }
  }

  /// True when the source conversation's read watermark is at or after this notification.
  bool _alreadySeenByWatermark(NotificationEntry n, Map<String, int> lastRead) {
    final route = n.route;
    if (lastRead.isEmpty || route == null || route.isEmpty || n.ts <= 0) {
      return false;
    }
    final keys = switch (n.type) {
      'pm' => [route, 'pm-$route'],
      'group' => [route, 'group-$route'],
      'channel' || 'mention' => [route, '#$route'],
      _ => [route],
    };
    var seen = 0;
    for (final k in keys) {
      final v = lastRead[k] ?? 0;
      if (v > seen) seen = v;
    }
    if (seen == 0) return false;
    return n.ts ~/ 1000 <= seen;
  }

  /// Records a notification, trimming to 24h and deduping by [eventId] or title+body+sender within 60s.
  void record({
    required String type,
    required String title,
    required String body,
    String? route,
    int? ts,
    String? eventId,
    String? senderPubkey,
    String? contextLabel,
    String? threadRoot,
    int? receivedAtMs,
    bool exactOnly = false,
  }) {
    // Channel digests never enter the bell history, on any path.
    if (body.contains('10 recent messages:')) return;
    // Boot race: buffer until hydration finishes.
    if (_hydrating) {
      // Freeze receivedAt at buffer time so the replay doesn't shift it.
      final observedAt = receivedAtMs ?? DateTime.now().millisecondsSinceEpoch;
      _pendingEntries.add(NotificationEntry(
        type: type,
        title: title,
        body: body,
        ts: ts ?? observedAt,
        receivedAt: observedAt,
        route: route,
        eventId: eventId,
        senderPubkey: senderPubkey,
        contextLabel: contextLabel,
        threadRoot: threadRoot,
      ));
      _pendingRecords.add(() => record(
            type: type,
            title: title,
            body: body,
            route: route,
            ts: ts,
            eventId: eventId,
            senderPubkey: senderPubkey,
            contextLabel: contextLabel,
            threadRoot: threadRoot,
            receivedAtMs: observedAt,
            exactOnly: exactOnly,
          ));
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    // Clamp future-dated times to the stored observation time so the entry doesn't pin to the top.
    final observedAt = receivedAtMs ?? now;
    final raw = ts ?? observedAt;
    final stamp = raw > observedAt ? observedAt : raw;
    // Events older than the 24h window never land.
    if (now - stamp >= _maxAgeMs) return;

    // Dedup against existing history (live and replay can both fire).
    final isDupe = state.entries.any((e) {
      if (eventId != null &&
          eventId.isNotEmpty &&
          e.eventId != null &&
          e.eventId == eventId) {
        return true;
      }
      if (exactOnly && eventId != null && eventId.isNotEmpty) return false;
      return e.title == title &&
          e.body == body &&
          (e.senderPubkey ?? '') == (senderPubkey ?? '') &&
          (e.ts - stamp).abs() < 60000;
    });
    if (isDupe) return;

    final entry = NotificationEntry(
      type: type,
      title: title,
      body: body,
      ts: stamp,
      receivedAt: observedAt,
      route: route,
      eventId: eventId,
      senderPubkey: senderPubkey,
      contextLabel: contextLabel,
      threadRoot: threadRoot,
    );
    // Land pre-viewed when seen on another device or under a read watermark; remember newly viewed keys.
    if (_isSeen(entry) ||
        entry.receivedAt <= _lastReadTimeMs ||
        _alreadySeenByWatermark(entry, _channelLastReadSnapshot())) {
      entry.viewed = true;
      if (_rememberSeen(entry)) _persistSeenKeys();
    }
    // Insert in newest-first order; the cap and sync read the list positionally.
    final kept = [
      entry,
      ...state.entries.where((e) => now - e.ts < _maxAgeMs),
    ]..sort((a, b) => b.ts.compareTo(a.ts));
    if (kept.length > _cap) kept.removeRange(_cap, kept.length);
    final unread = _countUnread(kept);
    state = NotificationHistoryState(entries: kept, unread: unread);
    _persist();
  }

  /// Marks entries for [route] viewed (optionally up to [tsSec]) and re-derives the badge.
  void markConversationSeen(String route, {int? tsSec}) {
    if (route.isEmpty) return;
    // Boot race: operate on the hydrated history.
    if (_hydrating) {
      _pendingRecords.add(() => markConversationSeen(route, tsSec: tsSec));
      return;
    }
    var changed = false;
    var seenGrew = false;
    final cutoffMs = tsSec != null ? tsSec * 1000 : null;
    for (final e in state.entries) {
      if (e.viewed) continue;
      if (e.route != route) continue;
      if (cutoffMs != null && e.ts > cutoffMs) continue;
      e.viewed = true;
      changed = true;
      if (_rememberSeen(e)) seenGrew = true;
    }
    if (!changed) return;
    final entries = List.of(state.entries);
    state = state.copyWith(entries: entries, unread: _countUnread(entries));
    _persist();
    if (seenGrew) {
      _persistSeenKeys();
      onSeenChanged?.call();
    }
  }

  /// Marks every entry viewed, zeroes unread, and remembers seen keys for other devices.
  void markAllViewed() {
    // Boot race: defer until the persisted history has loaded.
    if (_hydrating) {
      _pendingRecords.add(markAllViewed);
      return;
    }
    var seenGrew = false;
    for (final e in state.entries) {
      if (!e.viewed) {
        e.viewed = true;
        if (_rememberSeen(e)) seenGrew = true;
      }
    }
    state = state.copyWith(entries: List.of(state.entries), unread: 0);
    _persist();
    if (seenGrew) {
      _persistSeenKeys();
      onSeenChanged?.call();
    }
  }

  /// Marks [entries] viewed (scroll-into-view reads) and remembers their seen keys.
  void markEntriesViewed(Iterable<NotificationEntry> entries) {
    if (_hydrating) {
      final captured = List.of(entries);
      _pendingRecords.add(() => markEntriesViewed(captured));
      return;
    }
    var changed = false;
    var seenGrew = false;
    for (final e in entries) {
      if (e.viewed || !state.entries.contains(e)) continue;
      e.viewed = true;
      changed = true;
      if (_rememberSeen(e)) seenGrew = true;
    }
    if (!changed) return;
    final list = List.of(state.entries);
    state = state.copyWith(entries: list, unread: _countUnread(list));
    _persist();
    if (seenGrew) {
      _persistSeenKeys();
      onSeenChanged?.call();
    }
  }

  /// Seen key: `e:<id>` when known, else sender+minute+40-char body prefix, matching truncated synced copies.
  String? _seenKey(NotificationEntry n) {
    final evId = n.eventId ?? '';
    if (evId.isNotEmpty) return 'e:$evId';
    final pk = n.senderPubkey ?? '';
    if (pk.isEmpty && n.ts == 0) return null;
    final body = n.body;
    final prefix = body.length > 40 ? body.substring(0, 40) : body;
    return 'f:$pk:${n.ts ~/ 60000}:$prefix';
  }

  bool _isSeen(NotificationEntry n) {
    final k = _seenKey(n);
    return k != null && _seenKeys.containsKey(k);
  }

  /// Records [n]'s key as seen; true only when newly added.
  bool _rememberSeen(NotificationEntry n) {
    final k = _seenKey(n);
    if (k == null || _seenKeys.containsKey(k)) return false;
    _seenKeys[k] = n.ts != 0 ? n.ts : DateTime.now().millisecondsSinceEpoch;
    return true;
  }

  /// Prunes the seen map by 48h TTL, then caps it at the newest 500.
  void _pruneSeenKeys() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - _seenKeysTtlMs;
    _seenKeys.removeWhere((_, ts) => ts <= cutoff);
    if (_seenKeys.length > _maxSeenKeys) {
      final ordered = _seenKeys.entries.toList()
        ..sort((a, b) => b.value - a.value);
      _seenKeys = {
        for (final e in ordered.take(_maxSeenKeys)) e.key: e.value,
      };
    }
  }

  void _persistSeenKeys() {
    if (_prefs == null) return;
    _seenKeysPersistTimer?.cancel();
    _seenKeysPersistTimer = Timer(const Duration(seconds: 2), () {
      _seenKeysPersistTimer = null;
      _persistSeenKeysNow();
    });
  }

  void _persistSeenKeysNow() {
    final prefs = _prefs;
    if (prefs == null) return;
    _pruneSeenKeys();
    try {
      prefs.setString(_seenKeysStoreKey, jsonEncode(_seenKeys));
    } catch (_) {}
  }

  Map<String, int> _decodeSeenKeys(String raw) {
    final out = <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final cutoff = DateTime.now().millisecondsSinceEpoch - _seenKeysTtlMs;
        decoded.forEach((k, v) {
          if (k is String && v is num && v.toInt() > cutoff) {
            out[k] = v.toInt();
          }
        });
      }
    } catch (_) {}
    return out;
  }

  /// The pruned seen map for the outbound sync wrap.
  Map<String, dynamic> seenNotificationsForSync() {
    _pruneSeenKeys();
    return Map<String, dynamic>.from(_seenKeys);
  }

  /// Merges another device's seen keys and retro-marks matching entries viewed; idempotent, true if changed.
  bool mergeSeenNotifications(dynamic incoming) {
    if (incoming is! Map) return false;
    // Boot race: merge after hydration; the caller ignores the result.
    if (_hydrating) {
      _pendingRecords.add(() => mergeSeenNotifications(incoming));
      return false;
    }
    final cutoff = DateTime.now().millisecondsSinceEpoch - _seenKeysTtlMs;
    var added = false;
    incoming.forEach((k, v) {
      if (k is! String || v is! num) return;
      final ts = v.toInt();
      if (ts <= cutoff) return;
      if (!_seenKeys.containsKey(k)) {
        _seenKeys[k] = ts;
        added = true;
      }
    });
    if (!added) return false;
    _persistSeenKeys();
    var retro = false;
    for (final e in state.entries) {
      if (e.viewed) continue;
      final key = _seenKey(e);
      if (key != null && _seenKeys.containsKey(key)) {
        e.viewed = true;
        retro = true;
      }
    }
    if (retro) {
      final entries = List.of(state.entries);
      state = state.copyWith(entries: entries, unread: _countUnread(entries));
      _persist();
    }
    return true;
  }

  /// Adopts a newer synced last-read watermark and retro-marks entries under it viewed; idempotent.
  void adoptNotificationLastReadTime(int tsMs) {
    if (tsMs <= 0 || tsMs <= _lastReadTimeMs) return;
    if (_hydrating) {
      _pendingRecords.add(() => adoptNotificationLastReadTime(tsMs));
      return;
    }
    _lastReadTimeMs = tsMs;
    try {
      _prefs?.setString(_lastReadStoreKey, '$tsMs');
    } catch (_) {}
    var retro = false;
    var seenGrew = false;
    for (final e in state.entries) {
      if (e.viewed) continue;
      if (e.receivedAt > _lastReadTimeMs) continue;
      e.viewed = true;
      retro = true;
      // Inbound merges remember without republishing.
      if (_rememberSeen(e)) seenGrew = true;
    }
    if (seenGrew) _persistSeenKeys();
    if (retro) {
      final entries = List.of(state.entries);
      state = state.copyWith(entries: entries, unread: _countUnread(entries));
      _persist();
    } else {
      // The watermark alone can change the badge.
      final unread = _countUnread(state.entries);
      if (unread != state.unread) state = state.copyWith(unread: unread);
    }
  }

  /// Merges another device's history, matching by eventId or sender+body+minute; idempotent, true if changed.
  bool mergeHistory(
    List<dynamic> incoming, {
    bool Function(String callId)? isCallAnswered,
  }) {
    if (incoming.isEmpty) return false;
    if (_hydrating) {
      _pendingRecords
          .add(() => mergeHistory(incoming, isCallAnswered: isCallAnswered));
      return false;
    }
    final cutoff = DateTime.now().millisecondsSinceEpoch - _maxAgeMs;
    final entries = List.of(state.entries);
    NotificationEntry? findLocalMatch(NotificationEntry n) {
      final evId = n.eventId ?? '';
      if (evId.isNotEmpty) {
        for (final m in entries) {
          final mid = m.eventId ?? '';
          if (mid.isNotEmpty && mid == evId) return m;
        }
      }
      for (final m in entries) {
        if (m.body != n.body) continue;
        if ((m.senderPubkey ?? '') != (n.senderPubkey ?? '')) continue;
        if ((m.ts - n.ts).abs() > 60000) continue;
        return m;
      }
      return null;
    }

    var changed = false;
    var seenAdded = false;
    for (final raw in incoming) {
      var n = NotificationEntry.fromJson(raw);
      if (n == null || n.ts <= cutoff) continue;
      // Clamp future-dated synced entries to the origin's observation time, not our clock.
      if (n.ts > n.receivedAt) n = n.clampedToObserved();
      final existing = findLocalMatch(n);
      if (existing != null) {
        if (n.viewed && !existing.viewed) {
          existing.viewed = true;
          changed = true;
        }
        final evId = n.eventId ?? '';
        if ((existing.eventId ?? '').isEmpty && evId.isNotEmpty) {
          existing.eventId = evId;
          changed = true;
        }
        if (existing.viewed && _rememberSeen(existing)) seenAdded = true;
        continue;
      }
      final pk = n.senderPubkey ?? '';
      if (pk.isNotEmpty && _blocked.contains(pk)) continue;
      // Skip missed-call entries for calls answered anywhere.
      final evId = n.eventId ?? '';
      if (evId.startsWith('missed-call-') &&
          (isCallAnswered?.call(evId.substring(12)) ?? false)) {
        continue;
      }
      // `receivedAt` already falls back to `timestamp` for legacy entries.
      if (!n.viewed && (n.receivedAt <= _lastReadTimeMs || _isSeen(n))) {
        n.viewed = true;
      }
      if (n.viewed && _rememberSeen(n)) seenAdded = true;
      entries.add(n);
      changed = true;
    }
    if (seenAdded) _persistSeenKeys();
    if (!changed) return false;
    final kept = entries.where((e) => e.ts > cutoff).toList()
      ..sort((a, b) => b.ts.compareTo(a.ts)); // newest-first (store order)
    if (kept.length > _cap) kept.removeRange(_cap, kept.length);
    state = NotificationHistoryState(entries: kept, unread: _countUnread(kept));
    _persist();
    return true;
  }

  /// History for the sync wrap: 24h window, newest 100, oldest-first, bodies clipped to 240 chars.
  List<Map<String, dynamic>> historyForSync() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - _maxAgeMs;
    final recent = state.entries.where((e) => e.ts > cutoff).take(100).toList();
    return [
      for (final e in recent.reversed)
        {
          ...e.toJson(),
          'body': e.body.length > 240 ? e.body.substring(0, 240) : e.body,
          'viewed': e.viewed,
        },
    ];
  }

  /// Live history plus hydration-buffered entries, so boot duplicates don't double-popup.
  List<NotificationEntry> get entriesForAlertDedup =>
      _hydrating ? [...state.entries, ..._pendingEntries] : state.entries;

  /// Removes the entry with [eventId] (a missed call answered elsewhere) and re-derives the badge.
  void removeByEventId(String eventId) {
    if (eventId.isEmpty) return;
    // Boot race: defer past the load or the persisted blob restores the entry.
    if (_hydrating) {
      _pendingRecords.add(() => removeByEventId(eventId));
      return;
    }
    final kept = state.entries.where((e) => e.eventId != eventId).toList();
    if (kept.length == state.entries.length) return;
    state = NotificationHistoryState(
      entries: kept,
      unread: _countUnread(kept),
    );
    _persist();
  }

  /// Clears the history and the seen map so panic/clear-data leaves no read state.
  void clear() {
    _pendingRecords.clear();
    _pendingEntries.clear();
    _seenKeys = <String, int>{};
    _prefs?.remove(_seenKeysStoreKey);
    // The last-read watermark is identity-scoped read state too.
    _lastReadTimeMs = 0;
    _prefs?.remove(_lastReadStoreKey);
    state = const NotificationHistoryState();
    _persist();
  }
}

/// The shell reads `.unread` for the bell; the modal reads `.entries`.
final notificationHistoryProvider = StateNotifierProvider<
    NotificationHistoryNotifier, NotificationHistoryState>(
  (ref) => NotificationHistoryNotifier(ref),
);

// Live custom emoji (NIP-30), persisted under the PWA's cache keys.

final RegExp _kEmojiShortcodeRx = RegExp(r'^[a-zA-Z0-9_]+$');
final RegExp _kEmojiUrlRx = RegExp(r'^https?://', caseSensitive: false);

class LiveCustomEmojiNotifier extends StateNotifier<CustomEmojiState> {
  LiveCustomEmojiNotifier(this._ref) : super(CustomEmojiState.empty) {
    _hydrate();
  }

  final Ref _ref;
  SharedPreferences? _prefs;

  /// Loose shortcode → url; [state] is rebuilt from this and [_packsByKey].
  final Map<String, String> _codeToUrl = {};

  /// Pack key (`pubkey:identifier`) → pack.
  final Map<String, CustomEmojiPack> _packsByKey = {};

  /// Subscribed `30030:<pubkey>:<identifier>` refs; newest list wins.
  final Set<String> _userPackRefs = {};
  int _userListTs = 0;

  /// Hydrates the persisted cache so seen emoji render at launch.
  Future<void> _hydrate() async {
    try {
      final prefs = await _ref.read(emojiPrefsProvider.future);
      _prefs = prefs;
      final cached = loadCustomEmojiState(prefs);
      _codeToUrl.addAll(cached.codeToUrl);
      for (final p in cached.packs) {
        _packsByKey[p.key] = p;
      }
      if (mounted && (_codeToUrl.isNotEmpty || _packsByKey.isNotEmpty)) {
        _publish();
        _schedulePrefetch();
      }
    } catch (_) {
      // Best-effort; an unavailable store yields live-only emoji.
    }
  }

  /// Schedules the debounced image prefetch; best-effort.
  void _schedulePrefetch() {
    try {
      scheduleCustomEmojiPrefetch(_ref.container);
    } catch (_) {
      // Prefetch is a warm-up only; never let it break registration.
    }
  }

  /// Registers a loose emoji (valid shortcode, http(s) url, no built-in shadowing); true if added or changed.
  bool registerEmoji(String? shortcode, String? url) {
    if (shortcode == null || url == null) return false;
    if (!_kEmojiShortcodeRx.hasMatch(shortcode) ||
        !_kEmojiUrlRx.hasMatch(url)) {
      return false;
    }
    if (kEmojiShortcodeMap.containsKey(shortcode.toLowerCase())) return false;
    if (_codeToUrl[shortcode] == url) return false;
    _codeToUrl[shortcode] = url;
    // Cap the loose map at 5000, like the PWA.
    if (_codeToUrl.length > 5000) {
      final keys = _codeToUrl.keys.toList();
      for (final k in keys.sublist(0, _codeToUrl.length - 5000)) {
        _codeToUrl.remove(k);
      }
    }
    _publish();
    _persist();
    _schedulePrefetch();
    return true;
  }

  /// Ingests `['emoji', shortcode, url]` tags from any inbound event.
  void ingestEmojiTags(List<List<String>> tags) {
    var changed = false;
    for (final t in tags) {
      if (t.length >= 3 && t[0] == 'emoji') {
        if (registerEmojiQuiet(t[1], t[2])) changed = true;
      }
    }
    if (changed) {
      _publish();
      _persist();
      _schedulePrefetch();
    }
  }

  /// Like [registerEmoji] but defers publish/persist for batch ingest.
  bool registerEmojiQuiet(String? shortcode, String? url) {
    if (shortcode == null || url == null) return false;
    if (!_kEmojiShortcodeRx.hasMatch(shortcode) ||
        !_kEmojiUrlRx.hasMatch(url)) {
      return false;
    }
    if (kEmojiShortcodeMap.containsKey(shortcode.toLowerCase())) return false;
    if (_codeToUrl[shortcode] == url) return false;
    _codeToUrl[shortcode] = url;
    return true;
  }

  /// Stores a kind-30030 pack (newest per key wins) and registers its emoji.
  void storePack(CustomEmojiPack pack) {
    if (pack.pubkey.isEmpty || pack.emojis.isEmpty) return;
    final existing = _packsByKey[pack.key];
    if (existing != null && existing.createdAt >= pack.createdAt) return;
    _packsByKey[pack.key] = pack;
    for (final e in pack.emojis) {
      registerEmojiQuiet(e.shortcode, e.url);
    }
    _publish();
    _persist();
    _schedulePrefetch();
  }

  /// Records the user's kind-10030 pack list (newest wins); [refs] are `30030:<pubkey>:<identifier>` values.
  void setUserPackRefs(List<String> refs, int createdAt,
      {List<List<String>> inlineEmojiTags = const []}) {
    if (createdAt < _userListTs) return;
    _userListTs = createdAt;
    _userPackRefs
      ..clear()
      ..addAll(refs);
    var changed = false;
    for (final t in inlineEmojiTags) {
      if (t.length >= 3 && t[0] == 'emoji') {
        if (registerEmojiQuiet(t[1], t[2])) changed = true;
      }
    }
    if (changed) {
      _publish();
      _persist();
    }
  }

  bool isPackSubscribed(CustomEmojiPack pack) =>
      _userPackRefs.contains('30030:${pack.pubkey}:${pack.identifier}');

  /// NIP-30 emoji tags for known custom shortcodes in [content].
  List<List<String>> emojiTagsForContent(String content) {
    if (content.isEmpty || _codeToUrl.isEmpty) return const [];
    final out = <List<String>>[];
    final added = <String>{};
    for (final m in RegExp(r':([a-zA-Z0-9_]+):').allMatches(content)) {
      final code = m.group(1)!;
      if (added.contains(code)) continue;
      final url = _codeToUrl[code];
      if (url != null) {
        added.add(code);
        out.add(['emoji', code, url]);
      }
    }
    return out;
  }

  void clearAll() {
    // Cancel a pending write so it can't re-persist what we wipe.
    _persistTimer?.cancel();
    _persistTimer = null;
    _codeToUrl.clear();
    _packsByKey.clear();
    _userPackRefs.clear();
    _userListTs = 0;
    if (mounted) state = CustomEmojiState.empty;
    final prefs = _prefs;
    if (prefs != null) {
      prefs.remove(kCustomEmojiMapKey);
      prefs.remove(kCustomEmojiPacksKey);
    }
  }

  /// Rebuilds the immutable snapshot, newest packs first.
  void _publish() {
    if (!mounted) return;
    final packs = _packsByKey.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    state = CustomEmojiState(
      codeToUrl: Map.unmodifiable(_codeToUrl),
      packs: List.unmodifiable(packs),
    );
  }

  Timer? _persistTimer;

  /// Schedules a throttled persist so bursts write once.
  void _persist() {
    // Throttle, not debounce, so a steady trickle still gets written.
    if (_persistTimer != null) return;
    _persistTimer = Timer(const Duration(seconds: 2), () {
      _persistTimer = null;
      _persistNow();
    });
  }

  @override
  void dispose() {
    // Flush a pending write so teardown never loses registrations.
    if (_persistTimer != null) {
      _persistTimer!.cancel();
      _persistTimer = null;
      _persistNow();
    }
    super.dispose();
  }

  /// Persists both caches in the PWA shape: loose map ≤5000, packs newest-first ≤200.
  void _persistNow() {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final mapEntries =
          _codeToUrl.entries.map((e) => [e.key, e.value]).toList();
      prefs.setString(kCustomEmojiMapKey, jsonEncode(mapEntries));
      final packs = _packsByKey.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final capped = packs.length > 200 ? packs.sublist(0, 200) : packs;
      final packJson = capped
          .map((p) => {
                'pubkey': p.pubkey,
                'identifier': p.identifier,
                'title': p.title,
                'created_at': p.createdAt,
                'emojis': p.emojis
                    .map((e) => {'shortcode': e.shortcode, 'url': e.url})
                    .toList(),
              })
          .toList();
      prefs.setString(kCustomEmojiPacksKey, jsonEncode(packJson));
    } catch (_) {
      // Quota or serialization failures are non-fatal.
    }
  }
}

/// The live custom-emoji store fed by the controller's NIP-30 subscription.
final liveCustomEmojiProvider =
    StateNotifierProvider<LiveCustomEmojiNotifier, CustomEmojiState>(
  (ref) => LiveCustomEmojiNotifier(ref),
);

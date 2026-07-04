import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/event_kinds.dart';
import '../core/utils/nym_utils.dart';
import '../features/channels/channel_manager.dart';
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
import '../features/messages/spam_filter.dart';
import '../features/messages/trust_graph.dart';
import '../features/pms/pm_logic.dart';
import '../features/polls/poll_logic.dart';
import '../features/zaps/zap_logic.dart';
import '../models/channel.dart';
import '../models/group.dart';
import '../models/message.dart';
import '../models/nostr_event.dart';
import '../models/pm_conversation.dart';
import '../models/poll.dart';
import '../models/user.dart';
import '../services/nostr/event_mapper.dart';
import 'settings_provider.dart';

/// The verified Nymchat developer pubkey (`verifiedDeveloper.pubkey`,
/// app.js:1092) — a root of the web-of-trust graph (app.js:1100) and exempt
/// from spam-gating. Mirrored by `NostrController.verifiedDeveloperPubkey`.
const String kVerifiedDeveloperPubkey =
    'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';

/// The verified Nymbot pubkey (`verifiedBot.pubkey`, app.js:1096) — the second
/// trust-graph root (app.js:1101) and exempt from spam-gating. Mirrored by
/// `NostrController.nymbotPubkey`.
const String kNymbotPubkey =
    'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2';

/// The verified-bot set (`this.verifiedBotPubkeys`, app.js:1099). Currently the
/// single Nymbot; kept as a set to match the PWA shape and `_isPubkeyGated`.
const Set<String> kVerifiedBotPubkeys = {kNymbotPubkey};

/// The seeded verified-bot [User]. The PWA's `getEffectiveUserStatus` is ONE
/// central function whose bot override (`verifiedBotPubkeys.has(pubkey) →
/// 'online'`, users.js:1112) every status render inherits automatically; the
/// Flutter port spread the check across call sites via
/// `effectiveStatus(isVerifiedBot:)`, and any site that forgot the flag showed
/// the bot offline once its seeded `lastSeen` aged past the 5-minute recency
/// window. This subclass restores the PWA's at-the-source semantics: the seeded
/// bot user forces the override itself, so EVERY `effectiveStatus()` read
/// (sidebar rows, chat-header dot, profile popover status row, autocomplete
/// ordering) reports `online` — while delegating to [User.effectiveStatus]
/// keeps the `hidden` short-circuit ordering identical to users.js:1111-1112.
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

/// The web-of-trust roots seeded into `nymchatPubkeys` on go-live
/// (app.js:1100-1101): the verified developer + Nymbot. Every transitive vouch
/// chain is anchored here.
const Set<String> kTrustRootPubkeys = {
  kVerifiedDeveloperPubkey,
  kNymbotPubkey,
};

/// Master switch for the web-of-trust SPAM GATE (the [AppState.isMessageFiltered]
/// → [AppState.isSpamGated] visibility cut). HELD OFF until two prerequisites
/// land, or it would hide legitimate messages:
///   1. Flutter must mine the NIP-13 PoW floor on channel SENDS (it currently
///      does not — `minePow` is never called), so Flutter-origin messages count
///      as a Nymchat-client self-attestation the way every PWA message does;
///      otherwise the gate hides them. (Off-thread PoW mining is part of the
///      isolate-offload work.)
///   2. The trust graph must persist + rebuild from D1, so a fresh session isn't
///      gating off an almost-empty graph.
/// The trust graph still OBSERVES / PUBLISHES / INGESTS vouches live regardless;
/// only the message-hiding is gated behind this flag (default off).
bool nymVouchSpamGateEnabled = false;

/// Live mirror of the heuristic CONTENT spam filter flags (PWA
/// `spamFilterEnabled` / `spamFilterAggressive`, app.js:559-560 — both default
/// **true**). Kept as module globals (like [nymVouchSpamGateEnabled]) so the
/// pure [AppState.isMessageFiltered] / [AppState] paths can consult them without
/// a Riverpod dependency. [NostrController.init] seeds them from the persisted
/// settings at boot. Distinct from the web-of-trust spam GATE above: this is the
/// `isSpamMessage` text heuristic ([SpamFilter]).
bool appSpamFilterEnabled = true;
bool appSpamFilterAggressive = true;

/// Identifies what the chat pane is currently showing. Mirrors the PWA's
/// mutually-exclusive `currentChannel` / `currentPM` / `currentGroup` +
/// `inPMMode` state (docs/specs/03 §3.5).
enum ViewKind { channel, pm, group }

/// Case-insensitive 64-hex pubkey check (used to canonicalize PM view ids —
/// see [AppStateNotifier.switchView]).
final RegExp _hex64AnyCaseRe = RegExp(r'^[0-9a-fA-F]{64}$');

/// The active conversation selector. [storageKey] matches the keying used by
/// the in-memory [AppState.messages] map (channel = `#<key>`, PM = `pm-<pubkey>`,
/// group = `group-<id>`).
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

  /// Key into [AppState.messages].
  final String storageKey;

  bool get inPMMode => kind != ViewKind.channel;

  @override
  bool operator ==(Object other) =>
      other is ChatView && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// A single emoji reaction tally on a message (UI-only aggregate).
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

/// Per-message zap aggregate (zaps.js `this.zaps` entry, UI-facing form):
/// total sats + the set of zappers. [receipts] holds the dedup keys (lowercased
/// `b:<bolt11>` or receipt id) so the verify-URL confirmation and a later
/// NIP-57 receipt for the same payment don't double-count. [unverified] maps a
/// receipt's dedup key → its sats when the zap couldn't be cryptographically
/// verified against the recipient's LNURL provider pubkey (a gift-wrapped,
/// zapper-signed announcement) — mirrors the PWA's `messageZaps.unverified`
/// (zaps.js:1613/1750); the badge tooltip surfaces the unverified sub-total.
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

  /// receiptId (dedup key) → sats for zaps that are NOT verified against the
  /// recipient's LNURL provider pubkey (zaps.js `messageZaps.unverified`).
  final Map<String, int> unverified;

  int get zapperCount => zappers.length;

  /// Sum of all unverified zap sats on this message (zaps.js:1750 — the
  /// `(N unverified)` tooltip suffix).
  int get unverifiedSats {
    var sum = 0;
    for (final s in unverified.values) {
      sum += s;
    }
    return sum;
  }
}

/// In-memory UI state for the shell. The production initial state is an EMPTY
/// shell ([AppState.empty] — only #nymchat, no identity), matching the PWA's
/// first paint; the controller swaps to a live, relay-backed store once an
/// identity boots ([AppStateNotifier.goLive] → [AppState.live]).
///
/// [AppState.seed] / [_seedAppState] below build a hard-coded SAMPLE store
/// (channels, users, PMs, groups, messages, reactions) — TEST/DEMO ONLY; no
/// production code path uses them as the initial or reset state.
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
        blockedKeywords = blockedKeywords ?? <String>{},
        nymchatPubkeys = nymchatPubkeys ?? <String>{},
        nymchatVouches = nymchatVouches ?? <String>{},
        trustedPubkeys = trustedPubkeys ?? <String>{};

  /// The current user's identity.
  final String selfPubkey;
  final String selfNym;

  /// Number of relays currently connected (0 = offline).
  final int connectedRelays;

  final List<ChannelEntry> channels;
  final List<PMConversation> pmConversations;
  final List<Group> groups;

  /// pubkey → User.
  final Map<String, User> users;

  /// view storageKey → ordered messages (oldest first).
  final Map<String, List<Message>> messages;

  /// message id → reaction tallies.
  final Map<String, List<MessageReaction>> reactions;

  /// channel/pm/group key → unread count (sidebar pill).
  final Map<String, int> unreadCounts;

  /// `<storageKey>|<pubkey>` → typing-stop expiry (ms since epoch). A peer is
  /// "typing" in a view while now < expiry. Cleared on stop / timeout.
  final Map<String, int> typing;

  /// pollId → Poll (kind 30078 `nym-poll`); channel-only (docs/specs/03 §6).
  final Map<String, Poll> polls;

  /// message id → per-message zap aggregate (kind 9735 receipts).
  final Map<String, MessageZaps> zaps;

  /// Favorited channel keys (`nym_pinned_channels`).
  final Set<String> pinnedChannels;

  /// Hidden-from-sidebar channel keys (`nym_hidden_channels`).
  final Set<String> hiddenChannels;

  /// Blocked-from-discovery channel keys (`nym_blocked_channels`).
  final Set<String> blockedChannels;

  /// channel storage key (`#<key>`) → last-activity ms (`nym_channel_activity`).
  final Map<String, int> channelLastActivity;

  /// geohash channel key (bare, lowercased) → 24 hourly D1 activity buckets
  /// (`buckets[0]` = this hour … `buckets[23]` = 23h ago). The faithful native
  /// equivalent of the PWA's `_geohashD1Activity` (channels.js:128-174): the
  /// per-hour message counts D1 reports for a geohash, kept so the globe heatmap
  /// can climb the palette by the true `Σ max(local[i], d1[i])` per bucket
  /// instead of a flat presence floor (C05-3). Populated by [applyChannelActivity]
  /// for geohash discovery passes; read by `buildGeohashChannels`.
  final Map<String, List<int>> geohashD1Activity;

  /// Friended pubkeys (`nym_friends`). users.js `this.friends` (isFriend).
  final Set<String> friends;

  /// Blocked-user pubkeys (`nym_blocked`). users.js `this.blockedUsers`
  /// (toggleBlockUserByPubkey / hideMessagesFromBlockedUser).
  final Set<String> blockedUsers;

  /// Blocked keywords, all lowercased (`nym_blocked_keywords`). users.js
  /// `this.blockedKeywords` (hasBlockedKeyword — matches content OR author nym).
  final Set<String> blockedKeywords;

  /// Web-of-trust GRAPH: pubkeys believed to be running a Nymchat client
  /// (`this.nymchatPubkeys`, app.js:697). Seeded with the verified developer +
  /// Nymbot roots (app.js:1100-1101), grown by observing PoW-valid channel
  /// activity (`_markNymchatPubkey`) and by ingesting trusted peers' kind-30078
  /// `nym-vouches` lists (`handleVouchEvent`). A sender in this set is never
  /// spam-gated. Capped at [TrustGraph.maxEntries].
  final Set<String> nymchatPubkeys;

  /// OUR OWN vouch list: pubkeys we've personally observed running Nymchat
  /// (`this.nymchatVouches`, app.js:557). Published as our kind-30078
  /// `nym-vouches` event so other clients can expand their graph through us.
  /// Capped at [TrustGraph.maxEntries].
  final Set<String> nymchatVouches;

  /// Pubkeys earned into trust by sending ≥2 messages this session
  /// (`this.trustedPubkeys`, app.js:699; `_trackPubkeyMessage`, messages.js:324).
  /// Exempts a sender from spam-gating even when not yet in [nymchatPubkeys].
  final Set<String> trustedPubkeys;

  final ChatView view;

  /// True when [pubkey] is a friend (users.js `isFriend`).
  bool isFriend(String pubkey) => friends.contains(pubkey);

  /// True when [pubkey] is blocked (users.js `blockedUsers.has`).
  bool isUserBlocked(String pubkey) => blockedUsers.contains(pubkey);

  /// True when [text] OR [nickname] contains any blocked keyword,
  /// case-insensitive. Mirrors messages.js `hasBlockedKeyword(text, nickname)`:
  /// the nickname is reduced to its base nym (suffix/flair stripped) first.
  bool hasBlockedKeyword(String text, [String? nickname]) {
    if (blockedKeywords.isEmpty) return false;
    final lowerText = text.toLowerCase();
    final lowerNick =
        (nickname != null && nickname.isNotEmpty)
            ? stripPubkeySuffix(nickname).toLowerCase()
            : '';
    for (final keyword in blockedKeywords) {
      if (lowerText.contains(keyword) ||
          (lowerNick.isNotEmpty && lowerNick.contains(keyword))) {
        return true;
      }
    }
    return false;
  }

  /// True when the kind-30078 spam gate (`nym-vouch` web-of-trust) hides a
  /// channel/PM message from a low-trust sender. Mirrors messages.js:481-483:
  ///
  /// ```js
  /// const isGated = !message.isOwn && !this.isFriend(message.pubkey) &&
  ///   !this.nymchatPubkeys.has(message.pubkey) &&
  ///   this._isPubkeyGated(message.pubkey);
  /// ```
  ///
  /// where `_isPubkeyGated(pubkey)` (messages.js:347) returns false for the
  /// verified developer, any verified bot, or a sender already earned into
  /// [trustedPubkeys] (≥2 messages this session). The dev + bot roots are also
  /// seeded into [nymchatPubkeys] on go-live, so the `nymchatPubkeys.has` check
  /// alone already exempts them; [verifiedDeveloper]/[verifiedBots] keep the
  /// predicate faithful to the PWA even if the roots haven't been seeded.
  ///
  /// A gated sender's messages are stored but kept out of the visible list,
  /// unread counts, notifications, and presence (the PWA's `_spamGated` flag) —
  /// they "reveal" retroactively once the sender becomes trusted
  /// (`_revealGatedPubkey`).
  bool isSpamGated(
    Message m, {
    String? verifiedDeveloper,
    Set<String> verifiedBots = const {},
  }) {
    if (m.isOwn) return false;
    if (isFriend(m.pubkey)) return false;
    if (nymchatPubkeys.contains(m.pubkey)) return false;
    // _isPubkeyGated: trusted via dev/bot identity or earned trust.
    if (verifiedDeveloper != null && m.pubkey == verifiedDeveloper) return false;
    if (verifiedBots.contains(m.pubkey)) return false;
    if (trustedPubkeys.contains(m.pubkey)) return false;
    return true;
  }

  /// True when [m] should be hidden from message lists: blocked author, a
  /// keyword match on its content / author, a heuristic-spam hit on a NON-own
  /// message ([SpamFilter.isSpamMessage]), or spam-gated by the web-of-trust
  /// ([isSpamGated]).
  ///
  /// The PWA's `displayMessage` hides a message when blocked-user/keyword on
  /// EITHER side (the own-message branch `return`s on keyword/block too,
  /// messages.js:638-642) and additionally hides a NON-own message on a spam
  /// hit (messages.js:648); it folds the `_spamGated` flag into every
  /// visibility/unread filter (messages.js:2942, persistence.js:443). Own
  /// heuristic-spam is deliberately NOT filtered here — the PWA still shows the
  /// sender their own flagged message (with a self-only notice, see [sendLocal]).
  bool isMessageFiltered(Message m) {
    // Injected system/action pills (notices, command feedback) are never subject
    // to content filtering — they carry no sender and must always show.
    if (m.isSystemRow) return false;
    if (blockedUsers.contains(m.pubkey)) return true;
    // Keyword hits hide on BOTH sides: a non-own match, and our OWN message that
    // tripped a blocked keyword (hidden locally though still sent — the PWA's
    // own-message `return`, messages.js:640-641).
    if (hasBlockedKeyword(m.content, m.author)) return true;
    // Heuristic content spam — incoming-only (own-message spam is surfaced as a
    // self-only system notice instead, see [sendLocal]). Mirrors the `spamHit`
    // term of the PWA's non-own hide branch (messages.js:636,648).
    if (!m.isOwn &&
        SpamFilter.isSpamMessage(m.content,
            enabled: appSpamFilterEnabled,
            aggressive: appSpamFilterAggressive)) {
      return true;
    }
    // Web-of-trust spam gate — only applied when explicitly enabled (see
    // [nymVouchSpamGateEnabled]); held off until PoW-on-send + graph persistence
    // exist so it can't hide legitimate messages on a fresh session.
    if (nymVouchSpamGateEnabled &&
        isSpamGated(m,
            verifiedDeveloper: kVerifiedDeveloperPubkey,
            verifiedBots: kVerifiedBotPubkeys)) {
      return true;
    }
    return false;
  }

  /// True when [m] should increment a conversation's unread badge — the PWA's
  /// `_recomputeUnreadCount` per-message filter (channels.js:1709-1728):
  /// `!isOwn && !_spamGated && created_at > lastRead && !blockedUsers.has(pk)`.
  ///
  /// This is DELIBERATELY narrower than [isMessageFiltered]: the unread count
  /// excludes ONLY own / blocked-user / web-of-trust-gated messages. It does
  /// NOT exclude blocked-keyword or heuristic-spam hits — the PWA still counts
  /// those toward unread (it hides them from the list but keeps the badge),
  /// whereas [isMessageFiltered] (the list-visibility filter) drops them. Using
  /// [isMessageFiltered] for unread therefore UNDER-counts vs the PWA whenever a
  /// keyword or the heuristic filter is configured. (The `created_at > lastRead`
  /// term has no native analogue yet — there is no per-channel `channelLastRead`
  /// read-state — so the incremental model approximates it via the open-view
  /// reset; see C02-5/C02-6.)
  bool countsTowardUnread(Message m) {
    if (m.isSystemRow) return false;
    if (m.isOwn) return false;
    if (blockedUsers.contains(m.pubkey)) return false;
    if (nymVouchSpamGateEnabled &&
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
        blockedKeywords: blockedKeywords,
        nymchatPubkeys: nymchatPubkeys,
        nymchatVouches: nymchatVouches,
        trustedPubkeys: trustedPubkeys,
      );

  /// Builds the seeded demo store. TEST/DEMO ONLY — never used as the
  /// production initial or reset state (the PWA shows an empty shell, not fake
  /// channels/users/PMs). Production uses [AppState.empty] / [AppState.live].
  factory AppState.seed() => _seedAppState();

  /// The production logged-out initial state: an empty live shell (only
  /// #nymchat, no identity). The PWA's first paint before/without a login is an
  /// empty shell, never demo data; the controller swaps to [AppState.live] once
  /// an identity boots ([AppStateNotifier.goLive]).
  factory AppState.empty() => AppState.live('', '');

  /// An empty live store for a freshly-booted identity (only #nymchat).
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

// ---------------------------------------------------------------------------
// SAMPLE / SEED DATA  — TEST/DEMO ONLY (see [AppState.seed]); NOT used by any
// production initial/reset/runtime state.
// ---------------------------------------------------------------------------

// Sample pubkeys (64-hex). The last 4 hex chars form the display suffix
// (docs/specs/03 §2.3: `getPubkeySuffix(pubkey) = pubkey.slice(-4)`).
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
  int secAgo(int s) => now.subtract(Duration(seconds: s)).millisecondsSinceEpoch ~/ 1000;

  // --- channels (named + geohash) ---
  final channels = <ChannelEntry>[
    ChannelEntry(channel: 'nymchat'),
    ChannelEntry(channel: 'bitcoin'),
    ChannelEntry(channel: 'dev'),
    // Geohash channel near San Francisco (#9q8y).
    ChannelEntry(channel: '9q8y', geohash: '9q8y'),
  ];

  // --- users + presence ---
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
      lastSeen: now.subtract(const Duration(minutes: 12)).millisecondsSinceEpoch,
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

  // --- PM conversations ---
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

  // --- groups ---
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

  // --- #nymchat messages (IRC-worthy variety) ---
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
      // reply / quote line (formatter renders leading `>` as a quote).
      content:
          '> pixel-matching the IRC layout to the PWA right now\nboth bubble and IRC modes? nice.',
      createdAt: secAgo(60 * 14),
    ),
    msg(
      id: 'm05',
      pubkey: _pkSatoshi,
      author: 'satoshi#beef',
      channel: 'nymchat',
      // code block sample.
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
    // consecutive same-author within 5 min (tests bubble grouping).
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

  // --- geohash channel #9q8y messages ---
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

  // --- #bitcoin / #dev light seeds ---
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

  // --- PM thread with satoshi (delivery ticks) ---
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

  // --- group messages ---
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

  // --- sample reactions keyed by message id ---
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
    _pkNeo: 2, // PM unread
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
    // The demo authors represent established, trusted conversations, so seed
    // them into the web-of-trust graph — otherwise the spam gate ([isSpamGated],
    // folded into [isMessageFiltered]) would hide all sample messages in the
    // pre-login demo store.
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

// ---------------------------------------------------------------------------
// Riverpod store
// ---------------------------------------------------------------------------

/// Holds the in-memory [AppState]. Supports switching views and a local-echo
/// send (append a self [Message] to the current view).
class AppStateNotifier extends StateNotifier<AppState> {
  // Production initial state is the empty logged-out shell (PWA parity), NOT the
  // demo seed — the controller swaps to the live store on boot ([goLive]).
  AppStateNotifier() : super(AppState.empty());

  /// Fired whenever a conversation is opened via [switchView] (channel, PM, or
  /// group). The controller wires this to its D1 history backfill so opening a
  /// channel/group fetches the archive (mirrors the PWA's per-open
  /// `channelRestoreFromD1` in `switchChannel`). Best-effort and may be null
  /// (e.g. before the controller boots, or in pure UI/state tests).
  void Function(ChatView view)? onViewOpened;

  /// Fired after a PM/group message is inserted via [ingestPMMessage] /
  /// [ingestGroupMessage], with the conversation storage key. The controller
  /// wires this to its dirty-key cache flush so inbound (and engine-injected,
  /// e.g. Nymbot) messages persist like the PWA's per-insert
  /// `persistPMMessages` (pms.js:1307). Best-effort; may be null in pure state
  /// tests.
  void Function(String storageKey)? onPmMessageIngested;

  /// Fired when a NEW PM conversation row is created (any path: inbound/own
  /// message, UI thread-start, or hydration). The controller wires this to the
  /// debounced critical resubscribe so the main REQ's direct-mode kind-0
  /// filter starts watching the new contact's profile (the PWA's
  /// `addPMConversation` new-branch → `_scheduleCriticalResubscribe`,
  /// pms.js:2795-2805). Best-effort; may be null in pure state tests.
  void Function(String peerPubkey)? onPMConversationAdded;

  /// Fired whenever the closed-PM set ([_closedPMs] / [_closedPMTimes]) mutates
  /// (close, re-open, or a strictly-newer inbound that re-opens a thread). The
  /// controller wires this to KV persistence (`nym_closed_pms` /
  /// `nym_closed_pm_times`) so a deleted PM stays deleted across a relaunch
  /// instead of resurrecting from the D1 backlog (F02). Best-effort; may be null
  /// before the controller boots, or in pure state tests.
  void Function()? onClosedPmsChanged;

  /// Fired when [_channelLastRead] mutates (a view opened / marked read). The
  /// controller wires this to KV persistence (`nym_channel_last_read`) so the
  /// read watermark survives a relaunch — without it, every boot's D1 backfill
  /// re-counts already-read history as unread (the PWA persists `channelLastRead`
  /// and counts only `created_at > lastRead`, channels.js:1709). Best-effort.
  void Function()? onChannelReadChanged;

  /// Fired whenever the group store mutates — a group is upserted/merged, a
  /// group message is ingested, or a group control is applied. The controller
  /// wires this to the debounced cross-device group sync (`nymchat-groups` /
  /// `nymchat-keys-<gid>` / `nymchat-history-<gid>`), mirroring the PWA's
  /// `_debouncedNostrSettingsSave()` peppered through every `groups.js` mutation
  /// (groups.js:690/772/803/…). Best-effort; may be null before boot / in tests.
  void Function()? onGroupStoreChanged;

  /// Per-conversation read watermark: storage key → last-read created_at (sec).
  /// A message bumps the unread badge only when `created_at > lastRead` — the
  /// PWA's `_recomputeUnreadCount` / `channelLastRead` (channels.js:1709-1735),
  /// so backfilled OR re-delivered OLD messages never inflate the badge.
  final Map<String, int> _channelLastRead = <String, int>{};

  /// Read-only view of the per-conversation read watermark (for persistence).
  Map<String, int> get channelLastRead => Map.unmodifiable(_channelLastRead);

  /// Fired when [markChannelRead] ADVANCES a conversation's watermark, with
  /// the key + new ts. The controller wires this to
  /// [NotificationHistoryNotifier.markConversationSeen] — the PWA's
  /// `_markChannelRead` → `_markConversationNotificationsSeen`
  /// (channels.js:1735-1741), so reading a conversation (locally OR via a
  /// synced watermark from another device) retro-marks its bell entries
  /// viewed without opening the notifications modal. Best-effort.
  void Function(String key, int tsSec)? onChannelReadMarked;

  /// Records that [key] was read up to [tsSec] (keeps the max). Fires
  /// [onChannelReadChanged] so the controller persists it.
  void markChannelRead(String key, int tsSec) {
    if (key.isEmpty || tsSec <= 0) return;
    final cur = _channelLastRead[key] ?? 0;
    if (tsSec <= cur) return;
    _channelLastRead[key] = tsSec;
    onChannelReadChanged?.call();
    onChannelReadMarked?.call(key, tsSec);
  }

  /// Restores the read watermark from KV at boot (paired with [channelLastRead]).
  void hydrateChannelLastRead(Map<String, int> m) {
    m.forEach((k, v) {
      if (v > (_channelLastRead[k] ?? 0)) _channelLastRead[k] = v;
    });
  }

  /// True when [m] is NEW relative to its conversation's read watermark — i.e.
  /// it should bump the unread badge (`created_at > lastRead`). [key] is the
  /// conversation storage key the badge is bucketed under.
  bool _isUnreadByWatermark(String key, Message m) =>
      m.createdAt > (_channelLastRead[key] ?? 0);

  /// Columns-mode read gate (PWA `_cvMarkColumnRead`, columns.js:26-42).
  /// Registered by the columns deck while it is mounted; null in single view.
  /// Given a conversation storage key, returns true ONLY when that
  /// conversation's column is the focused one, pinned to the newest message
  /// (at-bottom), and the app is visible (document not hidden) — the only case
  /// the PWA clears/keeps-clear its unread badge. A focused-but-scrolled-up
  /// column keeps accruing unread until it scrolls back to the bottom.
  bool Function(String storageKey)? columnsReadGate;

  /// True when a NEW message for [storageKey] should be treated as SEEN (no
  /// unread bump, watermark advanced): single view → it is the active
  /// conversation; columns view → the deck's [columnsReadGate] says the
  /// column is focused + at-bottom + visible (messages.js:546 /
  /// pms.js:1378 / groups.js:1333 all route through `_cvMarkColumnRead`).
  bool _isConversationSeen(String storageKey) {
    final gate = columnsReadGate;
    if (gate != null) return gate(storageKey);
    return storageKey == state.view.storageKey;
  }

  /// Public form of the seen check for the controller's read-receipt gate
  /// (messages.js:546 sends `sendChannelReadReceipt` only when
  /// `_cvMarkColumnRead` says the message was seen).
  bool isConversationSeen(String storageKey) => _isConversationSeen(storageKey);

  /// Clears [key]'s unread badge and stamps its read watermark to
  /// max(now, newest message) — the PWA's `clearUnreadCount`
  /// (channels.js:1892-1911). Public so the columns deck can clear a focused
  /// column's badge when it scrolls back to the bottom (`_cvAttachColumnScroll`
  /// at-bottom transition, columns.js:636) or the app becomes visible again
  /// (`_cvMarkVisibleColumnsRead`, relays.js:532/584).
  void clearUnread(String key) {
    if (key.isEmpty) return;
    var lastTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final msgs = state.messages[key];
    if (msgs != null) {
      for (final m in msgs) {
        if (m.createdAt > lastTs) lastTs = m.createdAt;
      }
    }
    // Badges are bucketed under both the storage key and the bare id (peer
    // pubkey / group id / channel name) depending on the ingest path — clear
    // both, like [switchView] does.
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
    if (removed) state = state.copyWith();
  }

  /// Clears the unread badge of every column the [columnsReadGate] passes —
  /// the PWA's `_cvMarkVisibleColumnsRead` (columns.js:44-47), fired when the
  /// app returns to the foreground (relays.js:532/584 on `visibilitychange`).
  /// Messages that arrived while the app was hidden accrued unread even for
  /// the focused column (the gate returns false while hidden); becoming
  /// visible again clears the focused + at-bottom column's count. No-op in
  /// single view (no gate registered) — there the active conversation never
  /// accrues unread in the first place.
  void markVisibleColumnsRead() {
    final gate = columnsReadGate;
    if (gate == null) return;
    // Iterate a snapshot: `clearUnread` mutates `unreadCounts`. Keys may be
    // stored under the storage key OR the bare id depending on the ingest
    // path, so the deck-registered gate must accept either form — and
    // `clearUnread` derives its dual buckets from the STORAGE key, so a bare
    // id is resolved to storage form first (otherwise only the bare bucket
    // would clear, leaving the storage-key badge + watermark stale).
    for (final key in state.unreadCounts.keys.toList()) {
      if (gate(key)) clearUnread(_unreadStorageKey(key));
    }
  }

  /// Resolves a raw unread-counts key — either a storage key or a bare id
  /// (peer pubkey / group id / channel name), the same dual-key model the
  /// columns deck's `_descMatchesKey` gate accepts — to the storage-style key
  /// [clearUnread] derives both of its buckets from. Bare ids are classified
  /// against the live stores (PM ingest buckets under the bare peer pubkey,
  /// app_state PM path); anything unrecognized falls back to the channel form,
  /// whose bare alt is the original key again.
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

  /// Clears the session's processed-event dedup sets — the in-memory
  /// `processedPMEventIds` / `deletedEventIds` analogues the PWA wipes inside
  /// `clearLocalStorageCache` (app.js:4021-4022) — so relay backlog / archive
  /// restore can repopulate the just-cleared cache instead of being dropped
  /// as already-seen duplicates. Called by [NostrController.clearCache] after
  /// the store wipe.
  void clearSessionDedup() {
    _seenIds.clear();
    _seenNymMessageIds.clear();
    _deletedEventIds.clear();
    _pendingDeletions.clear();
  }

  int _localSeq = 1000000;
  int _ingestSeq = 1;
  final Set<String> _seenIds = <String>{};

  /// nymMessageIds already ingested (PM/group dedup, since wrap ids differ per
  /// recipient copy but share the `['x', …]` id).
  final Set<String> _seenNymMessageIds = <String>{};

  /// Edits whose original message hasn't landed yet (out-of-order relay
  /// delivery): originalId → new content. Mirrors the PWA's `editedMessages`
  /// map (messages.js:447,1932-1962). When an edit-tagged event arrives before
  /// the message it rewrites, [applyEditOrDefer] stores it here keyed by the
  /// original id; [_consumePendingEdit] applies + clears it the moment a normal
  /// message with a matching `id`/`nymMessageId` is ingested, so an edit can
  /// never leak through as a brand-new bubble. Capped to avoid unbounded growth
  /// when an original never arrives.
  final Map<String, String> _pendingEdits = <String, String>{};

  /// PM peer pubkeys the user explicitly closed; older backlog for them is
  /// ignored (docs/specs/03 §3.3 `closedPMs`).
  final Set<String> _closedPMs = <String>{};

  /// peer pubkey → close timestamp (sec). A closed conversation re-opens only
  /// when a message strictly newer than this arrives (pms.js `closedPMTimes`),
  /// so stale relay backlog can't resurrect a thread the user just deleted.
  final Map<String, int> _closedPMTimes = <String, int>{};

  /// Group ids the user left; their messages/controls are ignored.
  final Set<String> _leftGroups = <String>{};

  /// group id → leave timestamp (UNIX seconds). A left group is only resurrected
  /// by a re-invite/add-member/unban whose `created_at` is STRICTLY NEWER than
  /// this (F04-H4); stale relay backlog older than the leave can't undo it.
  /// Mirrors the PWA's `leftGroupTimes` (`nym_left_group_times`, groups.js:544,
  /// 719, 1815).
  final Map<String, int> _leftGroupTimes = <String, int>{};

  int _nextLocalSeq() => _localSeq++;
  int _nextIngestSeq() => _ingestSeq++;

  Set<String> get closedPMs => _closedPMs;

  /// The recorded leave timestamp (UNIX seconds) for [groupId], or 0 if the user
  /// hasn't left it. Exposed so the controller's inbound group-control path can
  /// gate a re-invite/add-member/unban on `created_at > leaveTime` (F04-H4,
  /// groups.js:719-722). Read-only view of [_leftGroupTimes].
  int leftGroupTime(String groupId) => _leftGroupTimes[groupId] ?? 0;

  /// Whether [groupId] is currently marked as left (its messages/controls are
  /// dropped). Lets the controller decide whether a `group-add-member` must
  /// re-create a fully-removed group (F04-H3 trustBootstrap).
  bool isLeftGroup(String groupId) => _leftGroups.contains(groupId);

  /// Clears the "left" mark for [groupId] so a fresh invite / add-member can
  /// resurrect a group the user previously left (F04-H3). Mirrors the PWA's
  /// `leftGroups.delete(groupId)` + `leftGroupTimes.delete(groupId)` in the
  /// `group-invite` / `group-add-member` handlers (groups.js:798-804, 879-884):
  /// without this, `upsertGroup` / `ingestGroupMessage` permanently drop
  /// everything for a left group, so an invited-back user can never rejoin.
  ///
  /// [createdAtSec] gates the clear on the resurrecting event's `created_at`
  /// (F04-H4): when provided, the mark is only cleared if the event is STRICTLY
  /// NEWER than the recorded leave time (the PWA's `msgTs <= leftAt` drop guard,
  /// groups.js:722) — so stale backlog older than the leave can't resurrect the
  /// group. Returns true when the group was cleared (or was never left), so the
  /// caller knows the resurrection may proceed; false when the gate rejected it.
  ///
  /// Pure map mutation (no `state` rebuild — the caller's `upsertGroup`/ingest
  /// publishes the new state).
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

  /// Switches this store to a live, identity-backed empty state. Called by the
  /// NostrController once an identity boots.
  void goLive(String pubkey, String nym) {
    _seenIds.clear();
    _seenNymMessageIds.clear();
    _pendingEdits.clear();
    _closedPMs.clear();
    _closedPMTimes.clear();
    _leftGroups.clear();
    _leftGroupTimes.clear();
    _reactors.clear();
    _reactionLastAction.clear();
    _channelMessageReaders.clear();
    _processedPollVoteIds.clear();
    _pendingPollVotes.clear();
    _pendingDeletions.clear();
    state = AppState.live(pubkey, nym);
    // Seed the web-of-trust roots (app.js:1100-1101): the verified developer +
    // Nymbot anchor every transitive vouch chain.
    state.nymchatPubkeys.addAll(kTrustRootPubkeys);
    // Seed the NORMAL Nymbot user + its official brand avatar (app.js:1103-1111:
    // `this.users.set(verifiedBot.pubkey, {nym:'Nymbot', status:'online', …})` +
    // `userAvatars.set(verifiedBot.pubkey, 'https://nymchat.app/images/nymbot-icon.png')`).
    // `getAvatarUrl` then serves the PNG on EVERY Nymbot surface (sidebar PM row,
    // channel bubble, premium PM bubble, header/welcome) — without this seed
    // `users[kNymbotPubkey]` is null and each surface falls back to a different
    // generated identicon / emoji (F10-1). One seed repairs them all at once.
    // [VerifiedBotUser] forces the always-online override at the source
    // (users.js:1112) so no render site can show the bot offline once the
    // seeded `lastSeen` ages out of the 5-minute recency window.
    state.users[kNymbotPubkey] = VerifiedBotUser(
      pubkey: kNymbotPubkey,
      nym: 'Nymbot',
      status: UserStatus.online,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
      profile: UserProfile(picture: 'https://nymchat.app/images/nymbot-icon.png'),
    );
  }

  /// Resets the store to its pre-login state on sign-out / panic (app.js
  /// `signOut` → reload). Clears every session-scoped dedup/private map (so a new
  /// identity can't inherit the old one's seen ids / closed PMs / reactor state)
  /// and returns the visible store to the EMPTY logged-out shell (PWA parity —
  /// never the demo seed). Mirrors [goLive] but without a live identity; the boot
  /// gate then shows the setup modal.
  void reset() {
    _seenIds.clear();
    _seenNymMessageIds.clear();
    _pendingEdits.clear();
    _closedPMs.clear();
    _closedPMTimes.clear();
    _leftGroups.clear();
    _leftGroupTimes.clear();
    _reactors.clear();
    _reactionLastAction.clear();
    _channelMessageReaders.clear();
    _processedPollVoteIds.clear();
    _pendingPollVotes.clear();
    _pendingDeletions.clear();
    // NIP-09 memory goes too: the on-disk copy was wiped (panic) or belongs
    // to the departing identity's cache (sign-out re-hydrates on next boot).
    _deletedEventIds.clear();
    state = AppState.empty();
  }

  void setIdentity(String pubkey, String nym) {
    state = state.copyWith(selfPubkey: pubkey, selfNym: nym);
  }

  void setConnectedRelays(int count) {
    if (count == state.connectedRelays) return;
    state = state.copyWith(connectedRelays: count);
  }

  // ---------------------------------------------------------------------------
  // Web of trust ("nym-vouch") — spam gating store + ingest (messages.js /
  // nostr-core.js). The trust graph ([AppState.nymchatPubkeys]) gates channel/PM
  // spam; growing it reveals previously-gated senders' messages. Unlike the PWA
  // (which flips a per-message `_spamGated` flag and calls `_revealGatedPubkey`),
  // the native gate is computed live by [AppState.isSpamGated] inside
  // [AppState.isMessageFiltered], so a single `copyWith()` after a trust mutation
  // re-runs every visibility/unread filter and reveals the newly-trusted sender.
  // ---------------------------------------------------------------------------

  /// Adds [pubkey] to the trust GRAPH ([AppState.nymchatPubkeys]). Mirrors
  /// messages.js `_markNymchatPubkey` (line 353): once a sender is known to run
  /// Nymchat, their channel messages are no longer spam-gated. Returns true when
  /// newly added (so callers can decide whether to expand the graph). Notifies
  /// listeners so any of the sender's gated messages reveal.
  bool markNymchatPubkey(String pubkey) {
    final added = TrustGraph.add(
      state.nymchatPubkeys,
      pubkey,
      selfPubkey: state.selfPubkey,
    );
    if (added) state = state.copyWith();
    return added;
  }

  /// Records an observation that [pubkey] is running Nymchat into OUR OWN vouch
  /// list ([AppState.nymchatVouches]) — the list we later publish. Mirrors
  /// nostr-core.js `_observeNymchatPubkey` (line 2623). Returns true when newly
  /// added (the controller then schedules a debounced vouch publish). Does NOT
  /// notify listeners (our vouch list isn't UI state).
  bool observeNymchatPubkey(String pubkey) {
    return TrustGraph.add(
      state.nymchatVouches,
      pubkey,
      selfPubkey: state.selfPubkey,
    );
  }

  /// Ingests a peer's kind-30078 `nym-vouches` list into the trust graph,
  /// mirroring nostr-core.js `handleVouchEvent` (line 2663). The vouch is only
  /// honored when [authorPubkey] is ALREADY in [AppState.nymchatPubkeys] — this
  /// keeps the graph rooted in the seeded dev/bot pubkeys so a stranger can't
  /// inject trust. Every valid (hex64, non-self) pubkey in [vouchedPubkeys] is
  /// marked. Returns true when at least one NEW pubkey was added (the controller
  /// then schedules a one-hop expansion / resubscribe). Skips our own vouches.
  bool ingestVouchList({
    required String authorPubkey,
    required List<String> vouchedPubkeys,
  }) {
    if (authorPubkey.isEmpty || authorPubkey == state.selfPubkey) return false;
    // Rooted-trust gate: only accept vouches from peers we already trust.
    if (!state.nymchatPubkeys.contains(authorPubkey)) return false;
    var added = false;
    for (final pk in vouchedPubkeys) {
      if (pk == state.selfPubkey) continue;
      if (TrustGraph.add(state.nymchatPubkeys, pk, selfPubkey: state.selfPubkey)) {
        added = true;
      }
    }
    if (added) state = state.copyWith();
    return added;
  }

  /// Tracks a message from [pubkey] toward earned trust ([AppState.trustedPubkeys]).
  /// Mirrors messages.js `_trackPubkeyMessage` (line 324): after a sender posts
  /// ≥2 distinct messages this session they're trusted (exempt from spam-gating
  /// via `_isPubkeyGated`). Already-trusted senders are a no-op. Returns true
  /// when [pubkey] crossed into trust on this call (so their gated messages
  /// reveal).
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
      state = state.copyWith();
      return true;
    }
    return false;
  }

  /// Loads persisted web-of-trust sets (CacheStore meta) into the live graph on
  /// boot — additive over the roots already seeded in `goLive`. Mirrors the PWA
  /// restoring nymchatPubkeys / nymchatVouches / trustedPubkeys from its meta
  /// store so the spam gate isn't cold on every launch (persistence.js:301-343).
  void hydrateTrustSets(
    Set<String> pubkeys,
    Set<String> vouches,
    Set<String> trusted,
  ) {
    if (pubkeys.isEmpty && vouches.isEmpty && trusted.isEmpty) return;
    state.nymchatPubkeys.addAll(pubkeys);
    state.nymchatVouches.addAll(vouches);
    state.trustedPubkeys.addAll(trusted);
    state = state.copyWith();
  }

  /// pubkey → distinct message ids seen this session, until the sender crosses
  /// the ≥2 trust threshold (messages.js `pubkeyMsgIds`, line 326). Pruned once
  /// trust is earned. Capped at 20000 senders (oldest dropped).
  final Map<String, Set<String>> _pubkeyMsgIds = {};

  /// Per-message reactor map: messageId → emoji → reactor pubkey → nym.
  /// Mirrors the PWA's `reactions: Map<msgId, Map<emoji, Map<pubkey,nym>>>`
  /// (docs/specs/03 §5.3). The UI-facing [AppState.reactions] tallies are
  /// derived from this on each mutation.
  final Map<String, Map<String, Map<String, String>>> _reactors = {};

  /// `messageId:emoji:pubkey` → last action ts (sec). Latest action wins on
  /// out-of-order relay delivery (`reactionLastAction`, reactions.js).
  final Map<String, int> _reactionLastAction = {};

  /// Public channel read receipts (kind 24421): channel-message id → reader
  /// pubkey → display nym. Mirrors the PWA's `channelMessageReaders`
  /// (nostr-core.js `handleChannelReadReceipt`). Kept off the [Message] so a
  /// receipt that arrives before its message can be replayed once the message
  /// lands; [applyChannelReader] copies the live set onto `message.readers`
  /// (the avatar-row consumer) whenever either side updates.
  final Map<String, Map<String, String>> _channelMessageReaders = {};

  /// Dedup set for poll-vote events (`processedPollVoteIds`, cap 3000).
  final Set<String> _processedPollVoteIds = {};

  /// Votes that arrived before their poll (`pendingPollVotes`).
  final Map<String, List<PollVote>> _pendingPollVotes = {};

  Set<String> get processedPollVoteIds => _processedPollVoteIds;

  /// Routes a verified inbound Nostr event into the store (channel messages,
  /// profiles, reactions, polls, zaps). Deduplicates by event id.
  void ingestEvent(NostrEvent e) {
    switch (e.kind) {
      case EventKind.geoChannel:
      case EventKind.namedChannel:
        _ingestChannelMessage(e);
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

  void _ingestChannelMessage(NostrEvent e) {
    if (e.id.isNotEmpty && !_seenIds.add(e.id)) return;
    // An incoming edit (the published/echoed edit event carries
    // `['edit', originalId]`, buildChannelEditTags) rewrites the original in
    // place — it must NOT be appended as a new message (the user-reported
    // duplicate). The original channel message is keyed by its event id, which
    // `applyLocalEdit` matches. Out-of-order arrival is buffered (PWA
    // `editedMessages`, messages.js:447,1932-1962).
    final editId = e.tagValue('edit');
    if (editId != null && editId.isNotEmpty) {
      applyEditOrDefer(editId, e.content);
      return;
    }
    final m = EventMapper.channelMessage(e, selfPubkey: state.selfPubkey);
    if (m == null) return;
    // NIP-09: drop messages already deleted (or matched by a parked
    // out-of-order deletion from the same author) — messages.js:437-443.
    if (suppressDeletedMessage(m)) return;
    final key = EventMapper.channelKeyOf(e);
    if (key == null) return;
    m.seq = _ingestSeq++;

    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    list.add(m);
    list.sort(compareMessages);

    // Track the author as a seen user.
    final u = state.users.putIfAbsent(
      e.pubkey,
      () => User(pubkey: e.pubkey, nym: m.author),
    );
    u.nym = m.author;
    u.lastSeen = m.timestamp;
    // Channel membership for the header "N online nyms" count, /who, and
    // @-mention bucketing. The PWA stores the BARE key `channelKey =
    // geohash || channel`, lowercased (users.js:1262,1287,1298). `m.channel`
    // is NULL for geohash channels (event_mapper.dart:37-38), so adding only
    // `m.channel` left membership empty for every geo channel — breaking all
    // three consumers, which look up the bare-lowercase key
    // (`view.id.toLowerCase()`). Use geohash when present, else the named `d`.
    final memberKey = ((m.geohash?.isNotEmpty ?? false) ? m.geohash! : m.channel)
        ?.toLowerCase();
    if (memberKey != null && memberKey.isNotEmpty) u.channels.add(memberKey);

    // Track last activity for the channel sort (`channelLastActivity`).
    state.channelLastActivity[key] = m.timestamp;

    // Surface the channel in the sidebar on first activity. The PWA lists
    // discovered/active channels (channels.js `addChannelToList`), so any channel
    // we actually receive a message for — live from relays OR from the D1 archive
    // backfill — must appear, unless the user blocked or hid it. Mirrors
    // `addChannel`'s entry/key shape (registry key is the bare lowercase value).
    final isGeo = (m.geohash ?? '').isNotEmpty;
    final regKey = (isGeo ? m.geohash! : (m.channel ?? '')).toLowerCase();
    if (regKey.isNotEmpty &&
        !state.blockedChannels.contains(regKey) &&
        !state.hiddenChannels.contains(regKey) &&
        !state.channels.any((c) => c.key == regKey)) {
      state.channels.add(ChannelEntry(
        channel: m.channel ?? (isGeo ? m.geohash! : regKey),
        geohash: isGeo ? m.geohash! : '',
      ));
    }

    // Bump unread when the message isn't SEEN (single view: active view;
    // columns view: focused + at-bottom + visible column, messages.js:546) and
    // counts toward the badge — the PWA's `_recomputeUnreadCount` predicate
    // (own / blocked / WoT-gated excluded, but keyword + heuristic-spam STILL
    // counted; see [AppState.countsTowardUnread]).
    // `_isUnreadByWatermark` gates on `created_at > lastRead`, so a D1 backfill
    // of older history never re-inflates the badge for an already-read channel.
    final seen = _isConversationSeen(key);
    if (!seen &&
        state.countsTowardUnread(m) &&
        _isUnreadByWatermark(key, m)) {
      state.unreadCounts[key] = (state.unreadCounts[key] ?? 0) + 1;
    } else if (seen && columnsReadGate != null) {
      // A seen column keeps its badge clear and its watermark pinned to the
      // newest message (`_cvMarkColumnRead` → `_markChannelRead`).
      state.unreadCounts.remove(key);
      markChannelRead(key, m.createdAt);
    }

    // Replay any channel read receipts (kind 24421) that arrived before this
    // message landed (the receipt and its message race across relays). Mirrors
    // the PWA keeping `channelMessageReaders` keyed independently of the message.
    if (m.isOwn && _channelMessageReaders.containsKey(m.id)) {
      _mirrorChannelReaders(m.id);
    }

    // Apply a buffered out-of-order edit whose original is this message.
    _consumePendingEdit(id: m.id);

    state = state.copyWith();
  }

  /// Resolves a kind-0 display name with the PWA's fallback chain
  /// `profile.name || profile.username || profile.display_name`
  /// (nostr-core.js:697-698, same chain in the profile-batch handler at
  /// 2272-2274), capped at 20 chars (`truncatedName = profileName.substring(0,
  /// 20)`, nostr-core.js:699). Null when no candidate is present.
  static String? _kind0DisplayName(UserProfile p) {
    for (final v in [p.name, p.username, p.displayName]) {
      if (v != null && v.isNotEmpty) {
        return v.length > 20 ? v.substring(0, 20) : v;
      }
    }
    return null;
  }

  void _ingestProfile(NostrEvent e) {
    final p = EventMapper.profile(e);
    if (p == null) return;
    final resolvedName = _kind0DisplayName(p);
    final existing = state.users[e.pubkey];
    var changed = false;
    if (existing != null) {
      final prev = existing.profile;
      if (prev == null || p.kind0Ts >= prev.kind0Ts) {
        // Skip a NO-OP refresh (same ts + same picture/name). A periodic D1
        // re-fetch of an unchanged profile must not churn `state`: every
        // copyWith rebuilds every user-watching widget (message rows, reaction
        // badges, sidebar), which is what made the UI "constantly reload".
        if (prev == null ||
            prev.kind0Ts != p.kind0Ts ||
            prev.picture != p.picture ||
            prev.name != p.name ||
            prev.username != p.username ||
            prev.displayName != p.displayName) {
          existing.profile = p;
          if (resolvedName != null) {
            existing.nym = getNymFromPubkey(resolvedName, e.pubkey);
          }
          changed = true;
        }
      }
    } else {
      // Missing-name fallback is 'nym' (the PWA never renders 'anon' — its
      // `getNymFromPubkey` default is `nym#xxxx`, users.js:1085).
      state.users[e.pubkey] = User(
        pubkey: e.pubkey,
        nym: getNymFromPubkey(resolvedName ?? 'nym', e.pubkey),
        profile: p,
      );
      changed = true;
    }
    // Sync the PM sidebar row's displayed nym with the kind-0 name — the PWA's
    // `updatePMNicknameFromProfile(event.pubkey, profileName)` run on every
    // stored kind-0 (nostr-core.js:2308-2329, name capped at 20 chars). Without
    // it a conversation created before the profile arrived keeps its fallback
    // name forever.
    if (e.pubkey != state.selfPubkey && resolvedName != null) {
      if (_syncPmConversationNym(e.pubkey)) changed = true;
    }
    // Self kind-0: also overwrite the sidebar HEADER nym, not just the avatar
    // (the PWA's `updateSidebarFromProfile` → `nym.nym = user.nym`,
    // app.js:5510). Without this, restoring our own profile on login fixes the
    // avatar but leaves the header text as the ephemeral derived nym. Checked
    // OUTSIDE the no-op guard above: boot hydration ([hydrateProfiles]) can
    // seed this same profile into `users` before the login's D1/relay re-fetch
    // lands, making that re-fetch a "no-op" while `selfNym` still holds the
    // boot identity's ephemeral nick — the header must still be repaired.
    // Reads the STORED (newest-wins) profile, not the event payload, so a
    // stale kind-0 can never regress the name.
    String? selfNym;
    if (e.pubkey == state.selfPubkey) {
      final stored = state.users[e.pubkey]?.profile;
      final name = stored == null ? null : _kind0DisplayName(stored);
      if (name != null) {
        final resolved = getNymFromPubkey(name, e.pubkey);
        if (resolved != state.selfNym) selfNym = resolved;
      }
    }
    if (changed || selfNym != null) {
      state = state.copyWith(selfNym: selfNym);
    }
  }

  void _ingestReaction(NostrEvent e) {
    // Reactions from blocked users are dropped (reactions.js `handleReaction`:
    // `if (this.blockedUsers.has(event.pubkey)) return;`).
    if (state.blockedUsers.contains(e.pubkey)) return;

    // Only process reactions targeting our supported message kinds. When a `k`
    // tag is present it must be one of 20000 (geohash channel) / 23333 (named
    // channel) / 1059 (NIP-17 gift wrap) / 14 (group rumor); otherwise the
    // reaction belongs to another Nostr app and is ignored. A missing `k` tag
    // is allowed (reactions.js then verifies the target is a known message).
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

    // When no `k` tag is present, only accept the reaction if it targets a
    // KNOWN message (reactions.js:226-242) — otherwise it's a reaction from
    // another Nostr app to a non-Nymchat note that merely shares an id space.
    if (kTag == null && !isKnownMessageId(r.messageId)) return;

    // Latest-by-timestamp wins on out-of-order delivery (reactions.js).
    final actionKey = '${r.messageId}:${r.emoji}:${r.reactor}';
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
      messageId: r.messageId,
      emoji: r.emoji,
      reactor: r.reactor,
      removed: r.removed,
      reactorNym: _nymForPubkey(r.reactor),
    );
  }

  /// True when [messageId] identifies a message already in ANY conversation
  /// (channels, PMs, groups), matched by event id or the PM/group
  /// `nymMessageId` — the PWA's no-`k`-tag reaction guard (reactions.js:
  /// 226-242), which keeps reactions from other Nostr apps to non-Nymchat
  /// notes out of the store and out of notifications.
  bool isKnownMessageId(String messageId) {
    if (messageId.isEmpty) return false;
    for (final msgs in state.messages.values) {
      for (final m in msgs) {
        if (m.id == messageId || m.nymMessageId == messageId) return true;
      }
    }
    return false;
  }

  /// Applies a single reaction add/remove to the reactor map and recomputes the
  /// message's UI tally. Used by both inbound (`_ingestReaction`) and optimistic
  /// local toggles. Idempotent per (messageId, emoji, reactor).
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
    state = state.copyWith();
  }

  /// Rebuilds [AppState.reactions] for [messageId] from the reactor map, marking
  /// `userReacted` when self is among the reactors.
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
    // Unknown-user fallback is 'nym' (`getNymFromPubkey` → `nym#xxxx`,
    // users.js:1085 — the PWA never shows 'anon').
    return getNymFromPubkey('nym', pubkey);
  }

  /// Refreshes a PM conversation row's nym from the users map — the PWA's
  /// `updatePMNicknameFromProfile` (pms.js:2618-2625, name capped at 20 chars)
  /// + the exists-branch sync in `addPMConversation` (pms.js:2806-2812).
  /// Returns true when the stored nym changed. Does NOT emit state — callers
  /// own the repaint.
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

  // -------------------------------------------------------------------------
  // Polls (kind 30078 nym-poll / nym-poll-vote) — channel-only.
  // -------------------------------------------------------------------------

  /// Ingests a poll-create event (dedup by id, honor expiration, require a
  /// question + ≥ 2 options). Replays any buffered votes (polls.js
  /// `handlePollEvent`).
  void ingestPoll(NostrEvent e) {
    if (!PollLogic.isPollEvent(e)) return;
    if (PollLogic.isExpired(e)) return;
    if (state.polls.containsKey(e.id)) return;
    final poll = PollLogic.parsePoll(e);
    if (poll == null) return;
    state.polls[e.id] = poll;

    // Replay buffered votes that arrived before this poll (one per pubkey).
    final buffered = _pendingPollVotes.remove(e.id);
    if (buffered != null) {
      for (final v in buffered) {
        poll.votes.putIfAbsent(v.voter, () => v.optionIndex);
      }
    }
    state = state.copyWith();
  }

  /// Ingests a poll-vote event (dedup `processedPollVoteIds` cap 3000, honor
  /// expiration, buffer when the poll is unknown, one vote/pubkey — first wins).
  /// (polls.js `handlePollVoteEvent`)
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
    if (poll.votes.containsKey(vote.voter)) return; // no double-voting
    poll.votes[vote.voter] = vote.optionIndex;
    state = state.copyWith();
  }

  /// Registers a locally-created/voted poll/vote so the UI updates immediately
  /// (publishPoll / votePoll optimistic paths). Returns the [Poll].
  void upsertPoll(Poll poll) {
    state.polls[poll.id] = poll;
    state = state.copyWith();
  }

  /// Applies the local user's own vote optimistically (votePoll). No-op if the
  /// poll is unknown or the user already voted.
  bool applyLocalVote(String pollId, int optionIndex) {
    final poll = state.polls[pollId];
    if (poll == null) return false;
    if (poll.votes.containsKey(state.selfPubkey)) return false;
    poll.votes[state.selfPubkey] = optionIndex;
    state = state.copyWith();
    return true;
  }

  // -------------------------------------------------------------------------
  // Zaps (kind 9735 receipts) — per-message total + zappers.
  // -------------------------------------------------------------------------

  /// Ingests a kind-9735 zap receipt, accruing sats + the zapper to the zapped
  /// message's aggregate. Deduped by lowercased bolt11 (zaps.js
  /// `_recordMessageZap`). Only message zaps (with an `['e', …]` tag) accrue.
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

  /// Records a zap against [messageId], deduped by [dedupKey]. Returns true when
  /// the zap was newly counted (or upgraded from unverified → verified).
  ///
  /// [verified] mirrors zaps.js `_recordMessageZap`'s trailing flag (line 1609):
  /// a receipt is VERIFIED when its event pubkey is the recipient's LNURL
  /// provider pubkey (or it's our own verify-URL-confirmed self-zap); a
  /// gift-wrapped, zapper-signed announcement is UNVERIFIED. Defaults to true so
  /// existing callers (the receipt-parse ingest, the self-zap record) are
  /// unaffected. When a verified receipt later arrives for a dedup key already
  /// counted as unverified, it is removed from [MessageZaps.unverified] without
  /// double-counting the sats (zaps.js:1617-1624).
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
      // Already counted. A verified receipt for a previously-unverified payment
      // clears the unverified mark (the sats stay, only the flag flips).
      if (verified && mz.unverified.remove(dedupKey) != null) {
        state = state.copyWith();
        return true;
      }
      return false;
    }
    mz.receipts.add(dedupKey);
    if (!verified) mz.unverified[dedupKey] = amountSats;
    mz.totalSats += amountSats;
    mz.zappers.add(zapperPubkey);
    state = state.copyWith();
    return true;
  }

  // -------------------------------------------------------------------------
  // PM / group / presence ingest (called by the controller after gift-wrap
  // unwrap; decryption needs the privkey so it stays in the service/controller).
  // -------------------------------------------------------------------------

  /// Inserts a decrypted PM [m] (kind-14 rumor mapped via [PmLogic.mapPmRumor])
  /// into the `pm-<peer>` store, creating/refreshing the conversation. Dedups
  /// on event id and nymMessageId. Honors [closedPMs] for backlog.
  void ingestPMMessage(Message m) {
    final rawPeer = m.conversationPubkey;
    if (rawPeer == null) return;
    // Canonical lowercase hex (mirrors [switchView]): the peer id keys the
    // conversation row, the unread counts, and — for the Nymbot — the
    // `view.id == kNymbotPubkey` BotChatScreen routing, all exact string
    // matches against lowercase-hex constants. An archived/legacy wrap must
    // never mint a parallel non-canonical row.
    final peer =
        _hex64AnyCaseRe.hasMatch(rawPeer) ? rawPeer.toLowerCase() : rawPeer;
    // A closed conversation only re-opens when a message strictly newer than
    // the close time arrives; older relay backlog is ignored (pms.js).
    if (_closedPMs.contains(peer)) {
      final closedAt = _closedPMTimes[peer] ?? 0;
      if (m.createdAt > closedAt) {
        _closedPMs.remove(peer);
        _closedPMTimes.remove(peer);
        // Persist the re-open so it isn't undone on relaunch (F02).
        onClosedPmsChanged?.call();
      } else {
        return;
      }
    }
    if (m.id.isNotEmpty && !_seenIds.add(m.id)) return;
    // NIP-09: drop deleted PM/group-rumor copies (pms.js:3722-3724).
    if (suppressDeletedMessage(m)) return;

    final key = _canonicalPmStorageKey(
        m.conversationKey ?? PmLogic.pmStorageKey(peer));
    final list = state.messages.putIfAbsent(key, () => <Message>[]);

    // Dual-wrap merge (pms.js:1184-1233): nymchat sends BOTH a bitchat-format
    // and a nymchat-format wrap to unknown peers, so the recipient may decrypt
    // both copies of one logical message. Correlate first on sender + the
    // shared `x`-tag nymMessageId (set on both wraps; content equality would
    // miss older senders' >255-byte bitchat truncation), falling back to
    // sender + identical content + <5s timestamps for legacy events without
    // the tag. On a match the EXISTING row is upgraded in place — adopt the
    // nymMessageId, prefer the longer content (bitchat truncation), and flip
    // `senderVerified` so the padlock upgrades when the verified nymchat copy
    // lands after the unverified bitchat one — never a second row.
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
            (e.createdAt - m.createdAt).abs() < 5) {
          dup = e;
          break;
        }
      }
    }
    if (dup != null) {
      var changed = false;
      if ((dup.nymMessageId == null || dup.nymMessageId!.isEmpty) &&
          nymId != null &&
          nymId.isNotEmpty) {
        dup.nymMessageId = nymId;
        _seenNymMessageIds.add(nymId);
        changed = true;
      }
      if (m.content.length > dup.content.length) {
        dup.content = m.content;
        changed = true;
      }
      if (m.senderVerified == true && dup.senderVerified != true) {
        dup.senderVerified = true;
        changed = true;
      }
      if (changed) state = state.copyWith();
      return;
    }
    if (m.nymMessageId != null && !_seenNymMessageIds.add(m.nymMessageId!)) {
      return;
    }
    m.seq = _nextIngestSeq();

    list.add(m);
    list.sort(compareMessages);

    // Maintain the conversation meta entry. The PWA's `addPMConversation`
    // prefers the users-map nym over the message author on EVERY message
    // (pms.js:2716-2718, plus the exists-branch re-sync at :2806-2812), so a
    // kind-0 that landed after the thread was created still corrects the row.
    final convo = state.pmConversations.firstWhere(
      (c) => c.pubkey == peer,
      orElse: () {
        // Own self-copy to an unknown peer: fall back to the PWA's
        // `getNymFromPubkey(peerPubkey)` default `nym#xxxx` (pms.js:1321-1322 →
        // users.js:1085) — never an empty nym, which would render as a bare
        // '#xxxx' row title until a profile lands.
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

    // Track the sender as a seen user.
    if (!m.isOwn) {
      final u = state.users.putIfAbsent(
        m.pubkey,
        () => User(pubkey: m.pubkey, nym: m.author),
      );
      u.lastSeen = m.timestamp;
    }

    // Seen = active PM (single view) or focused + at-bottom + visible column
    // (columns view, pms.js:1378 `_cvMarkColumnRead`).
    final seenPm = _isConversationSeen(key);
    if (!seenPm &&
        state.countsTowardUnread(m) &&
        _isUnreadByWatermark(peer, m)) {
      state.unreadCounts[peer] = (state.unreadCounts[peer] ?? 0) + 1;
    } else if (seenPm && columnsReadGate != null) {
      state.unreadCounts.remove(peer);
      state.unreadCounts.remove(key);
      markChannelRead(peer, m.createdAt);
      markChannelRead(key, m.createdAt);
    }
    // Apply a buffered out-of-order edit whose original is this PM (matches on
    // id or the shared nymMessageId).
    _consumePendingEdit(id: m.id, nymMessageId: m.nymMessageId);
    state = state.copyWith();
    onPmMessageIngested?.call(key);
  }

  /// Inserts a decrypted group message [m] into the `group-<id>` store.
  /// Returns true when the message landed (false on dedup / left group), so
  /// the controller can skip the per-message metadata merge for replayed
  /// copies exactly like the PWA's dup-check `return` runs before
  /// `addGroupConversation` (groups.js:1230-1292).
  bool ingestGroupMessage(Message m) {
    final gid = m.groupId;
    if (gid == null) return false;
    if (_leftGroups.contains(gid)) return false;
    if (m.id.isNotEmpty && !_seenIds.add(m.id)) return false;
    if (m.nymMessageId != null && !_seenNymMessageIds.add(m.nymMessageId!)) {
      return false;
    }
    // NIP-09: drop deleted group messages (pms.js:3722-3724).
    if (suppressDeletedMessage(m)) return false;
    m.seq = _nextIngestSeq();

    final key = m.conversationKey ?? GroupLogic.groupStorageKey(gid);
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    list.add(m);
    list.sort(compareMessages);

    final idx = state.groups.indexWhere((g) => g.id == gid);
    if (idx >= 0 && m.timestamp > state.groups[idx].lastMessageTime) {
      state.groups[idx].lastMessageTime = m.timestamp;
    }
    if (!m.isOwn) {
      final u = state.users.putIfAbsent(
        m.pubkey,
        () => User(pubkey: m.pubkey, nym: m.author),
      );
      u.lastSeen = m.timestamp;
    }
    // Seen = active group (single view) or focused + at-bottom + visible column
    // (columns view, groups.js:1333 `_cvMarkColumnRead`).
    final seenGroup = _isConversationSeen(key);
    if (!seenGroup &&
        state.countsTowardUnread(m) &&
        _isUnreadByWatermark(key, m)) {
      // Key the unread count by the group's storage key (== `key`), NOT the bare
      // gid — the sidebar group row reads `unread[groupStorageKey(id)]`, so a
      // bare-gid write never surfaced as a badge. Predicate mirrors the PWA's
      // `_recomputeUnreadCount` (keyword/heuristic-spam still count; see
      // [AppState.countsTowardUnread]) + the `created_at > lastRead` watermark.
      state.unreadCounts[key] = (state.unreadCounts[key] ?? 0) + 1;
    } else if (seenGroup && columnsReadGate != null) {
      state.unreadCounts.remove(key);
      markChannelRead(key, m.createdAt);
    }
    // Apply a buffered out-of-order edit whose original is this group message.
    _consumePendingEdit(id: m.id, nymMessageId: m.nymMessageId);
    state = state.copyWith();
    onPmMessageIngested?.call(key);
    onGroupStoreChanged?.call();
    return true;
  }

  /// Registers/updates a [Group] in the store (on create or on receiving a
  /// `group-invite`). Replaces any existing entry with the same id.
  void upsertGroup(Group group) {
    if (_leftGroups.contains(group.id)) return;
    final idx = state.groups.indexWhere((g) => g.id == group.id);
    if (idx >= 0) {
      state.groups[idx] = group;
    } else {
      state.groups.add(group);
    }
    state = state.copyWith();
    onGroupStoreChanged?.call();
  }

  /// Merges an inbound group MESSAGE's carried metadata into the group entry —
  /// the PWA's `addGroupConversation(groupId, groupName, memberPubkeys, ts)`
  /// call on every group message (groups.js:1292 → :2454). Existing group:
  /// merge the members, adopt the message's `subject` as the name
  /// (`name: name || existing.name`, :2506) and raise `lastMessageTime`.
  /// Unknown group: create the entry (unless left, :2460) so a rename carried
  /// on regular traffic reaches members who missed the `group-metadata`
  /// control event — this is how the PWA keeps sidebar/header titles current
  /// even when the owner's rename broadcast never arrived.
  void mergeGroupFromMessage({
    required String groupId,
    required String name,
    required List<String> memberPubkeys,
    required int timestampMs,
  }) {
    final existing = groupById(groupId);
    if (existing == null) {
      if (_leftGroups.contains(groupId)) return;
      state.groups.add(Group(
        id: groupId,
        name: name,
        members: memberPubkeys.toSet().toList(),
        lastMessageTime: timestampMs,
      ));
      state = state.copyWith();
      // A group first learned about via a regular message (missed invite) is
      // persisted/synced immediately — the PWA runs `_saveGroupConversations()`
      // + `_debouncedNostrSettingsSave(15000)` right after the
      // `addGroupConversation` create (groups.js:1296-1297).
      onGroupStoreChanged?.call();
      return;
    }
    var changed = false;
    // Merge members (new invitees may arrive with an updated list).
    for (final pk in memberPubkeys) {
      if (!existing.members.contains(pk)) {
        existing.members.add(pk);
        changed = true;
      }
    }
    if (name.isNotEmpty && name != existing.name) {
      existing.name = name;
      changed = true;
    }
    if (timestampMs > existing.lastMessageTime) {
      existing.lastMessageTime = timestampMs;
      changed = true;
    }
    if (changed) {
      state = state.copyWith();
      onGroupStoreChanged?.call();
    }
  }

  /// Looks up a group by id (null if unknown).
  Group? groupById(String id) {
    for (final g in state.groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// Cross-device history cap per group conversation (PWA `pmStorageLimit`,
  /// app.js:650) applied after merging a restored backlog.
  static const int _kGroupHistoryCap = 1000;

  /// Applies one decoded `nymchat-groups` entry (`groupId → serialized group`)
  /// from cross-device sync, mirroring the PWA's `applyGroupData` additive branch
  /// (app.js:5938-6000). A group unknown to this device is created — so a FRESH
  /// device restores its membership from D1; a known group has its owner / roles /
  /// metadata merged monotonically (newer `metaUpdatedAt` wins; mods / banned /
  /// modLog union, modLog deduped + capped at 50). A left group is skipped.
  /// Returns true when the store changed. Does NOT fire [onGroupStoreChanged] —
  /// this IS the inbound apply, so re-publishing the just-restored state would be
  /// a redundant (content-hash-deduped) echo.
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

    // Pre-populate the users map from the synced kind-0 snapshots so nyms /
    // avatars display immediately on restore instead of "nym" while relay
    // profiles load (PWA `_loadGroupConversations` memberProfiles seeding,
    // groups.js:566-580). Only seeds an UNKNOWN pubkey with a name — never
    // clobbers a live user; a real profile fetch still supersedes it.
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
          profile:
              (pic is String && pic.isNotEmpty) ? UserProfile(picture: pic) : null,
        );
      });
    }

    final existing = groupById(groupId);
    if (existing == null) {
      state.groups.add(Group(
        id: groupId,
        name: (data['name'] ?? '') as String,
        members: strList(data['members']),
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
        modLog: parseLog(data['modLog']),
      ));
      state = state.copyWith();
      return true;
    }

    final g = existing;
    var changed = false;
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
      // ABSENCE-SAFE: the PWA's synced `nymchat-groups` blob never carries
      // `allowMemberInvites` (it is localStorage-only, groups.js:317-355) and
      // its apply never touches the field (app.js:5963-5972) — only the LOCAL
      // `nym_groups_<pubkey>` blob (hydrated through this same method) has it.
      // Without the key guard a newer-metaUpdatedAt blob from a PWA device
      // would silently flip a disabled member-invite policy back to true.
      if (data.containsKey('allowMemberInvites')) {
        g.allowMemberInvites = data['allowMemberInvites'] != false;
      }
      g.inviteEnabled = data['inviteEnabled'] == true;
      g.inviteEpoch = (data['inviteEpoch'] as num?)?.toInt() ?? 0;
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
    // Moderation-dedup watermark advances on its own timeline (a mod event can
    // land without a metadata edit), so merge monotonically regardless of the
    // metaUpdatedAt gate — keep the newest lastModTs and its event id.
    final incomingModTs = (data['lastModTs'] as num?)?.toInt() ?? 0;
    if (incomingModTs > g.lastModTs) {
      g.lastModTs = incomingModTs;
      g.lastModEventId = nz(data['lastModEventId']);
      changed = true;
    }
    if (changed) state = state.copyWith();
    return changed;
  }

  /// Merges decoded group message history (`group-<gid>` → stripped message
  /// maps) from cross-device sync into the message store, mirroring the PWA's
  /// `groupMessageHistory` apply (app.js:6028-6076): each backup message is
  /// inflated (isGroup / isPM / isHistorical / conversationKey / author / seq),
  /// deduped by id (against both the existing thread AND the global seen-id set,
  /// so a later live delivery of the same wrap can't duplicate it), merged,
  /// re-sorted, and capped to the most recent [_kGroupHistoryCap]. Skips left
  /// groups. Returns the conversation keys that changed. Does NOT fire
  /// [onGroupStoreChanged] (inbound apply — see [applyGroupConversationSync]).
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
        // Register globally so a subsequent live/backfilled wrap for this same
        // message is deduped by [ingestGroupMessage] (`!_seenIds.add`).
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
      final merged = [...existing, ...newMsgs]..sort(compareMessages);
      final capped = merged.length > _kGroupHistoryCap
          ? merged.sublist(merged.length - _kGroupHistoryCap)
          : merged;
      state.messages[convKey] = capped;
      changed.add(convKey);
    });
    if (changed.isNotEmpty) state = state.copyWith();
    return changed;
  }

  /// Applies a verified group control rumor to the named group, returning the
  /// outcome. Mutations (membership/roles/metadata) happen in place via
  /// [GroupLogic.applyControlEvent].
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
    final result = GroupLogic.applyControlEvent(
      group: g,
      type: type,
      tags: tags,
      senderPubkey: senderPubkey,
      ts: ts,
      eventId: eventId,
      selfPubkey: state.selfPubkey,
    );
    if (result == GroupControlResult.applied) {
      // If we were removed, drop the group locally + stamp the leave time so a
      // re-invite/add-member must be NEWER than this to resurrect it (F04-H4;
      // PWA `leftGroupTimes.set(groupId, …)`, groups.js:1815). `ts` is the
      // control event's `created_at` (seconds) — the explicit `leaveGroup` path
      // passes `now`, an inbound kick passes the kicker's send-time.
      if (type == 'group-remove-member' && !g.members.contains(state.selfPubkey)) {
        _leftGroups.add(groupId);
        _leftGroupTimes[groupId] = ts;
        state.groups.removeWhere((x) => x.id == groupId);
        state.messages.remove(GroupLogic.groupStorageKey(groupId));
      }
      // Mod/owner delete-message: `applyControlEvent` only role-checks + mod-logs
      // (it owns no message store); the actual removal happens here. The target
      // message id is the `e` tag (groups.js:1172-1197 `_applyGroupMessageDeletion`).
      // Mirrors the `removeMember` self-removal special-case above.
      if (type == GroupControlType.deleteMessage) {
        final targetId = GroupLogic.tagValue(tags, 'e');
        if (targetId != null && targetId.isNotEmpty) {
          removeMessage(targetId);
        }
      }
      state = state.copyWith();
      onGroupStoreChanged?.call();
    }
    return result;
  }

  /// Applies a parsed delivery/read [receipt] to our own outgoing message that
  /// shares its `nymMessageId`. Only advances delivery status, never regresses.
  void applyReceipt(ReceiptInfo receipt) {
    final target = receipt.messageId.toLowerCase();
    final next = PmLogic.deliveryFromReceipt(receipt.receiptType);
    var changed = false;
    for (final list in state.messages.values) {
      for (final m in list) {
        if (m.isOwn &&
            m.nymMessageId != null &&
            m.nymMessageId!.toLowerCase() == target) {
          if (PmLogic.statusOrder(next) > PmLogic.statusOrder(m.deliveryStatus)) {
            m.deliveryStatus = next;
            changed = true;
          }
        }
      }
    }
    if (changed) state = state.copyWith();
  }

  /// Records a public channel read receipt (kind 24421): [readerPubkey] (shown
  /// as [readerNym]) has seen the channel message [messageId]. Mirrors the PWA's
  /// `handleChannelReadReceipt` (nostr-core.js): the reader is stored in
  /// [_channelMessageReaders] and mirrored onto the matching OWN channel
  /// message's `readers` map so the stacked reader avatars render
  /// (`message_row.dart` `_readerAvatars`). The store survives a receipt that
  /// arrives before its message — [_ingestChannelMessage] replays it on landing.
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
    // newest receipt wins for the display name; no-op if nothing changes.
    if (readers[readerPubkey] == readerNym) return;
    readers[readerPubkey] = readerNym;
    if (_mirrorChannelReaders(messageId)) state = state.copyWith();
  }

  /// Copies the stored reader set for [messageId] onto the matching own channel
  /// message's `readers` map (the avatar-row consumer). Returns true when a
  /// message was found and updated. Only OWN messages carry reader avatars in
  /// the UI, so non-own matches are skipped.
  bool _mirrorChannelReaders(String messageId) {
    final readers = _channelMessageReaders[messageId];
    if (readers == null) return false;
    for (final list in state.messages.values) {
      for (final m in list) {
        if (m.id == messageId && m.isOwn) {
          m.readers
            ..clear()
            ..addAll(readers);
          return true;
        }
      }
    }
    return false;
  }

  /// Marks [pubkey] as typing (or not) within [storageKey]. [expiresAtMs] is
  /// when the indicator auto-clears. Defaults to now + 5s to match the PWA's
  /// `_typingExpireMs = 5000` (app.js:742) — the received-typing TTL (C03-D5).
  void setTyping({
    required String storageKey,
    required String pubkey,
    required bool typing,
    int? expiresAtMs,
  }) {
    final k = '$storageKey|$pubkey';
    if (typing) {
      state.typing[k] =
          expiresAtMs ?? DateTime.now().millisecondsSinceEpoch + 5000;
    } else {
      state.typing.remove(k);
    }
    state = state.copyWith();
  }

  /// Updates a user's presence from a kind-30078 nym-presence event (or a
  /// gift-wrapped friend-presence rumor).
  /// Applies a parsed nym-presence event to the user's store entry. Mirrors
  /// users.js `handlePresenceEvent`: updates status/away/nym, and — when the
  /// presence carries an `avatar-update` — the avatar (`profile.picture`).
  /// A `shop-update` tag is handled by the controller (D1 shop-status cache
  /// invalidation), never here.
  ///
  /// `hidden` status updates `lastSeen`/away tracking but leaves the
  /// activity-derived [User.status] alone (the PWA tracks visibility separately,
  /// so a hidden user still appears in lists without a status dot — here
  /// [User.effectiveStatus] returns `hidden` directly when status is hidden).
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
    final u = state.users.putIfAbsent(
      pubkey,
      () => User(pubkey: pubkey, nym: nym ?? getNymFromPubkey('nym', pubkey)),
    );
    u.status = status;
    if (nym != null && nym.isNotEmpty) u.nym = getNymFromPubkey(nym, pubkey);
    u.awayMessage = (awayMessage != null && awayMessage.isNotEmpty)
        ? awayMessage
        : (status == UserStatus.away ? u.awayMessage : null);
    // Presence (a bare nym-presence broadcast) is NOT activity: the PWA's
    // `handlePresenceEvent` updates status/away/avatar but never touches
    // `user.lastSeen` (users.js:1246-1255), so a replayed/older-but-<5min
    // presence must NOT mark a user online. Only message ingestion and
    // friend-presence / own-activity stamp `lastSeen`. Callers on the public
    // nym-presence path pass `stampLastSeen: false`; the friend-presence and
    // own-activity callers leave the default `true` (they DO mark activity in
    // the PWA — users.js:1149,1155 friend; recordOwnActivity).
    if (stampLastSeen && lastSeenMs != null) u.lastSeen = lastSeenMs;

    // Avatar: an `avatar-update` tag sets (or clears, when empty) the picture
    // (users.js avatar branch). profile.picture is the canonical avatar source.
    if (hasAvatarTag) {
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        (u.profile ??= UserProfile()).picture = avatarUrl;
      } else {
        u.profile?.picture = null;
      }
    }

    // Shop cosmetics deliberately NOT handled here: a presence `shop-update`
    // tag is a pure cache-bust flag (users.js:1221-1223) — the controller
    // reacts by invalidating the D1-backed `shop-status` cache
    // (OtherUsersShopController.invalidate), which is the authoritative
    // per-user cosmetics source. Presence never carries item data.

    state = state.copyWith();
  }

  /// Records a closed PM conversation so its older backlog is ignored. Stamps
  /// the close time so a strictly-newer inbound message can re-open it (pms.js
  /// `closedPMTimes`). [nowSec] is injectable for tests.
  void closePM(String peerPubkey, {int? nowSec}) {
    final ts = nowSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    _closedPMs.add(peerPubkey);
    _closedPMTimes[peerPubkey] = ts;
    state.pmConversations.removeWhere((c) => c.pubkey == peerPubkey);
    state.messages.remove(PmLogic.pmStorageKey(peerPubkey));
    // `deletePM` side effects (pms.js:2996-2999): stamp the conversation's
    // read watermark to the close time and drop its unread badge, so a later
    // re-open / backlog replay never resurrects a stale count. Applied here so
    // EVERY caller gets them, not just the sidebar context menu.
    markChannelRead(peerPubkey, ts);
    markChannelRead(PmLogic.pmStorageKey(peerPubkey), ts);
    state.unreadCounts.remove(peerPubkey);
    state.unreadCounts.remove(PmLogic.pmStorageKey(peerPubkey));
    onClosedPmsChanged?.call();
    state = state.copyWith();
  }

  /// Opens (or creates) a PM conversation entry for [peerPubkey] without a
  /// message — used when starting a fresh thread from the UI.
  void ensurePMConversation(String peerPubkey, {String? nym}) {
    final wasClosed = _closedPMs.remove(peerPubkey);
    _closedPMTimes.remove(peerPubkey);
    if (wasClosed) onClosedPmsChanged?.call();
    final exists = state.pmConversations.any((c) => c.pubkey == peerPubkey);
    if (!exists) {
      // Nym resolution mirrors `addPMConversation` (pms.js:2716-2718): prefer
      // the users-map nym, then the caller-supplied one, then the PWA's
      // `getNymFromPubkey` default `nym#xxxx` (users.js:1085) — never 'anon'.
      final known = state.users[peerPubkey]?.nym;
      state.pmConversations.add(PMConversation(
        pubkey: peerPubkey,
        nym: (known != null && known.isNotEmpty)
            ? known
            : (nym ?? getNymFromPubkey('nym', peerPubkey)),
        lastMessageTime: DateTime.now().millisecondsSinceEpoch,
      ));
      onPMConversationAdded?.call(peerPubkey);
      state = state.copyWith();
    } else {
      // Existing thread → re-sync the row nym from the users map (the PWA's
      // exists-branch, pms.js:2806-2812).
      if (_syncPmConversationNym(peerPubkey)) state = state.copyWith();
    }
  }

  /// Restores the closed-PM set from persisted KV at boot (F02). [closed] is the
  /// set of peer pubkeys the user deleted; [closedTimes] maps each to its close
  /// timestamp (sec) so only a strictly-newer inbound re-opens it. Mirrors the
  /// PWA constructor parsing `nym_closed_pms` / `nym_closed_pm_times`.
  void hydrateClosedPMs(Set<String> closed, Map<String, int> closedTimes) {
    if (closed.isEmpty && closedTimes.isEmpty) return;
    _closedPMs.addAll(closed);
    _closedPMTimes.addAll(closedTimes);
  }

  /// Merges synced closed-PM state, byte-matching the PWA's two INDEPENDENT
  /// additive branches (app.js:6528-6538): `closedPMs` is a pure set union —
  /// an entry arriving WITHOUT a close time gets NO time stamped (so any
  /// archived message can still re-open the thread, `closedAt = 0`), and
  /// `closedPMTimes` is a per-key monotonic-max merge applied regardless of
  /// set membership (orphaned time entries from legacy/raced payloads are
  /// kept). Fires [onClosedPmsChanged] when anything changed so the controller
  /// persists the KV mirror.
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

  /// Additively merges synced/boot-restored left-group state (PWA
  /// `applyNostrSettings` leftGroups block + retroactive removal,
  /// app.js:6549-6561 / 6692-6712): union the ids, keep the newest leave time
  /// per group, and retroactively drop any group now marked left from the live
  /// store (a group left on another device disappears here too — a later
  /// membership event newer than the leave time can still resurrect it via the
  /// normal ingest gate). Idempotent.
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
    if (changed) state = state.copyWith();
  }

  /// Snapshot of the left-group ids → leave timestamp (sec), for the
  /// controller's KV persistence and outbound settings sync.
  Set<String> get leftGroups => Set.unmodifiable(_leftGroups);
  Map<String, int> get leftGroupTimes => Map.unmodifiable(_leftGroupTimes);

  /// Snapshot of the closed-PM peer pubkeys → close timestamp (sec), for the
  /// controller's KV persistence (paired with [closedPMs]).
  Map<String, int> get closedPmTimes => Map.unmodifiable(_closedPMTimes);

  /// One-shot "always spawn a new column" hint set by [switchView]'s
  /// `forceNewColumn:` (the globe's `openColumnForGeohash` passes
  /// `{forceNew: true}`, geohash-globe.js:1200 → columns.js:282). Consumed by
  /// the columns deck's view sink so a globe open never repurposes the primary
  /// column; sidebar taps leave it false.
  bool _forceNewColumnHint = false;

  /// Reads-and-clears the one-shot force-new-column hint (columns deck only).
  bool consumeForceNewColumnHint() {
    final v = _forceNewColumnHint;
    _forceNewColumnHint = false;
    return v;
  }

  void switchView(ChatView view, {bool forceNewColumn = false}) {
    // Canonicalize a PM peer id to lowercase hex at the single choke point
    // every entry path funnels through (sidebar tap, startPM, new-PM modal,
    // notification tap, columns focus). Every downstream comparison is an
    // exact string match against lowercase-hex constants/keys — the
    // Nymbot-routing check (`view.id == kNymbotPubkey`, chat_pane), the
    // `pm-<pubkey>` storage key, unread/read watermarks — so an uppercase-hex
    // id from any source would silently open a parallel "generic" thread.
    if (view.kind == ViewKind.pm &&
        _hex64AnyCaseRe.hasMatch(view.id) &&
        view.id != view.id.toLowerCase()) {
      view = ChatView.pm(view.id.toLowerCase());
    }
    _forceNewColumnHint = forceNewColumn;
    // Clear unread for the target on entry (mirrors marking-as-read), and stamp
    // the read watermark to NOW so a later D1 backfill of this conversation's
    // older history doesn't re-inflate the badge (PWA `_markChannelRead`).
    //
    // In columns view the clear is GATED (PWA `_cvMarkColumnRead`,
    // columns.js:26-42 via `_cvFocusColumn`:565): only when the target's column
    // is focused, pinned to the newest message, and the app is visible — a
    // focused-but-scrolled-up column keeps its unread badge until it scrolls
    // back to the bottom ([clearUnread] handles that transition).
    final gate = columnsReadGate;
    if (gate == null || gate(view.storageKey)) {
      state.unreadCounts.remove(view.id);
      state.unreadCounts.remove(view.storageKey);
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      markChannelRead(view.id, nowSec);
      markChannelRead(view.storageKey, nowSec);
    }
    state = state.copyWith(view: view);
    // Best-effort D1 history backfill on open (channel-get / group archive).
    // Wrapped so a backfill failure can't break the view switch.
    final cb = onViewOpened;
    if (cb != null) {
      try {
        cb(view);
      } catch (_) {}
    }
  }

  // -------------------------------------------------------------------------
  // Social / moderation (docs/specs/03 §11) — friends, blocked users, blocked
  // keywords. The controller owns KV persistence (nym_friends / nym_blocked /
  // nym_blocked_keywords); this layer owns the in-memory Sets + filtering.
  // -------------------------------------------------------------------------

  /// Toggles [pubkey] in the friend set, returning the new state (true = now a
  /// friend). Mirrors users.js `toggleFriend`.
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
    state = state.copyWith();
    return nowFriend;
  }

  /// Adds [pubkey] to the friend set (idempotent).
  void addFriend(String pubkey) {
    if (pubkey.isEmpty) return;
    if (state.friends.add(pubkey)) state = state.copyWith();
  }

  /// Removes [pubkey] from the friend set.
  void removeFriend(String pubkey) {
    if (state.friends.remove(pubkey)) state = state.copyWith();
  }

  /// Blocks [pubkey] (users.js `toggleBlockUserByPubkey` add branch →
  /// `hideMessagesFromBlockedUser`). Returns true if newly blocked.
  bool blockUser(String pubkey) {
    if (pubkey.isEmpty) return false;
    final added = state.blockedUsers.add(pubkey);
    if (added) state = state.copyWith();
    return added;
  }

  /// Unblocks [pubkey] (users.js `unblockByPubkey`).
  bool unblockUser(String pubkey) {
    final removed = state.blockedUsers.remove(pubkey);
    if (removed) state = state.copyWith();
    return removed;
  }

  /// Idempotent blocked-user remover (settings "Blocked" list × button). Alias
  /// of [unblockUser] under the shared API contract name.
  void removeBlockedUser(String pubkey) => unblockUser(pubkey);

  /// Idempotent hidden-channel remover (settings "Hidden" list). Alias of
  /// [unhideChannel] under the shared API contract name.
  void removeHiddenChannel(String key) => unhideChannel(key);

  /// Idempotent blocked-channel remover (settings "Blocked Channels" list).
  /// Alias of [unblockChannel] under the shared API contract name.
  void removeBlockedChannel(String key) => unblockChannel(key);

  /// Toggles [pubkey]'s blocked state, returning the new state (true = blocked).
  bool toggleBlockUser(String pubkey) {
    if (state.blockedUsers.contains(pubkey)) {
      unblockUser(pubkey);
      return false;
    }
    blockUser(pubkey);
    return true;
  }

  /// Adds a blocked keyword (lowercased + trimmed; users.js `addBlockedKeyword`).
  /// Returns the normalized keyword if added, else null (empty / duplicate).
  String? addBlockedKeyword(String keyword) {
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty) return null;
    if (!state.blockedKeywords.add(kw)) return null;
    state = state.copyWith();
    return kw;
  }

  /// Removes a blocked keyword (users.js `removeBlockedKeyword`).
  bool removeBlockedKeyword(String keyword) {
    final removed = state.blockedKeywords.remove(keyword.toLowerCase());
    if (removed) state = state.copyWith();
    return removed;
  }

  /// Hydrates the social Sets from persisted KV state (boot). Keywords are
  /// lowercased to match the add-path normalization.
  void hydrateSocialState({
    Set<String>? friends,
    Set<String>? blockedUsers,
    Set<String>? blockedKeywords,
  }) {
    if (friends != null) state.friends.addAll(friends);
    if (blockedUsers != null) state.blockedUsers.addAll(blockedUsers);
    if (blockedKeywords != null) {
      state.blockedKeywords.addAll(blockedKeywords.map((k) => k.toLowerCase()));
    }
    state = state.copyWith();
  }

  /// Applies an edit to a stored message (channel/PM/group): replaces its
  /// content + flags it edited. Mirrors `publishEditedChannelMessage`'s local
  /// rewrite + the PM/group `editedMessages` apply. No-op if not found.
  bool applyLocalEdit(String messageId, String newContent) {
    var changed = false;
    for (final list in state.messages.values) {
      for (final m in list) {
        if (m.id == messageId || m.nymMessageId == messageId) {
          m.content = newContent;
          m.isEdited = true;
          changed = true;
        }
      }
    }
    if (changed) state = state.copyWith();
    return changed;
  }

  /// Applies an incoming edit (an event carrying `['edit', originalId]`) to the
  /// original message in place via [applyLocalEdit]. When the original hasn't
  /// been ingested yet (out-of-order relay delivery), the edit is buffered in
  /// [_pendingEdits] keyed by [originalId] and replayed the moment a normal
  /// message with a matching `id`/`nymMessageId` lands (see [_consumePendingEdit]).
  /// The caller must NOT also append the edit event as a new message — this is
  /// what fixes the user-reported "edit shows as a duplicate" bug, mirroring the
  /// PWA's `editedMessages` map (messages.js:447,1932-1962).
  void applyEditOrDefer(String originalId, String newContent) {
    if (originalId.isEmpty) return;
    if (!applyLocalEdit(originalId, newContent)) {
      // Original not seen yet — remember the edit until its message arrives.
      _pendingEdits[originalId] = newContent;
      // Bound the buffer; an original that never lands shouldn't grow it forever.
      if (_pendingEdits.length > 2000) {
        _pendingEdits.remove(_pendingEdits.keys.first);
      }
    }
  }

  /// If a buffered out-of-order edit exists for a just-ingested message
  /// (matching on either [id] or [nymMessageId]), applies it in place and clears
  /// the pending entry. Called from every message-ingest site after the message
  /// is inserted. Returns true when an edit was applied.
  bool _consumePendingEdit({String? id, String? nymMessageId}) {
    if (_pendingEdits.isEmpty) return false;
    String? hitKey;
    String? content;
    if (id != null && id.isNotEmpty && _pendingEdits.containsKey(id)) {
      hitKey = id;
    } else if (nymMessageId != null &&
        nymMessageId.isNotEmpty &&
        _pendingEdits.containsKey(nymMessageId)) {
      hitKey = nymMessageId;
    }
    if (hitKey == null) return false;
    content = _pendingEdits.remove(hitKey);
    if (content == null) return false;
    return applyLocalEdit(hitKey, content);
  }

  // -------------------------------------------------------------------------
  // Inbound NIP-09 deletions (nostr-core.js `handleDeletionEvent` /
  // `_findMessageAuthor` / `_applyVerifiedDeletion` / `_consumePendingDeletion`).
  // -------------------------------------------------------------------------

  /// Event ids (and paired PM/group `nymMessageId`s) verified as NIP-09
  /// deleted. Gates ingest so relay backlog / D1 replay can't resurrect a
  /// deleted message (`this.deletedEventIds`, checked at messages.js:437 /
  /// pms.js:3722). Capped at 5000 → pruned to the newest 4000, like the PWA.
  final Set<String> _deletedEventIds = <String>{};

  /// Read-only snapshot for persistence (the PWA's `persistDedupSets`).
  Set<String> get deletedEventIds => Set.unmodifiable(_deletedEventIds);

  /// Deletions whose ORIGINAL message hasn't arrived yet: deleted id →
  /// claimant pubkeys. Consumed on ingest when a matching message from the
  /// same author lands (out-of-order relay delivery, nostr-core.js:2000-2013).
  final Map<String, Set<String>> _pendingDeletions = <String, Set<String>>{};

  /// Fired whenever [_deletedEventIds] grows, so the controller can persist
  /// the set (PWA `persistDedupSets`). Best-effort; may be null in tests.
  void Function()? onDeletedIdsChanged;

  /// Seeds [_deletedEventIds] from the on-disk cache at boot.
  void hydrateDeletedIds(Set<String> ids) {
    _deletedEventIds.addAll(ids);
  }

  /// Applies an inbound public kind-5 (NIP-09) deletion — nostr-core.js
  /// `handleDeletionEvent` (line 1985). Only the original author may delete:
  /// a mismatched requester is ignored, and an unknown original is parked in
  /// [_pendingDeletions] until (if) it arrives from the claimed author.
  void ingestDeletionEvent(NostrEvent e) {
    final requester = e.pubkey;
    if (requester.isEmpty) return;
    var deleted = false;
    for (final t in e.tagsNamed('e')) {
      if (t.length < 2 || t[1].isEmpty) continue;
      final deletedId = t[1];
      final originalAuthor = findMessageAuthor(deletedId);
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
      _applyVerifiedDeletion(deletedId);
      deleted = true;
    }
    if (deleted) onDeletedIdsChanged?.call();
  }

  /// The stored author of the message with [id] (event id or PM/group
  /// `nymMessageId`), or null when we don't hold it
  /// (`_findMessageAuthor`, nostr-core.js:2019).
  String? findMessageAuthor(String id) {
    if (id.isEmpty) return null;
    for (final msgs in state.messages.values) {
      for (final m in msgs) {
        if (m.id == id || m.nymMessageId == id) {
          return m.pubkey.isEmpty ? null : m.pubkey;
        }
      }
    }
    return null;
  }

  /// Records [deletedId] (plus any paired id of the same message) as deleted
  /// and removes the message from every conversation
  /// (`_applyVerifiedDeletion`, nostr-core.js:2038).
  void _applyVerifiedDeletion(String deletedId) {
    _deletedEventIds.add(deletedId);
    for (final msgs in state.messages.values) {
      for (final m in msgs) {
        if (m.id == deletedId || m.nymMessageId == deletedId) {
          if (m.id.isNotEmpty) _deletedEventIds.add(m.id);
          final nid = m.nymMessageId;
          if (nid != null && nid.isNotEmpty) _deletedEventIds.add(nid);
        }
      }
    }
    if (_deletedEventIds.length > 5000) {
      final arr = _deletedEventIds.toList();
      _deletedEventIds
        ..clear()
        ..addAll(arr.sublist(arr.length - 4000));
    }
    removeMessage(deletedId);
  }

  /// Ingest gate: true when [m] was already NIP-09 deleted, or a parked
  /// out-of-order deletion from the SAME author matches it (which then
  /// upgrades to a verified deletion). Mirrors the display gate at
  /// messages.js:437-443 + `_consumePendingDeletion` (nostr-core.js:2093).
  bool suppressDeletedMessage(Message m) {
    final nid = m.nymMessageId;
    if (_deletedEventIds.contains(m.id) ||
        (nid != null && _deletedEventIds.contains(nid))) {
      return true;
    }
    if (m.pubkey.isEmpty) return false;
    for (final id in <String>[m.id, if (nid != null && nid.isNotEmpty) nid]) {
      if (id.isEmpty) continue;
      final claimants = _pendingDeletions[id];
      if (claimants != null && claimants.contains(m.pubkey)) {
        _pendingDeletions.remove(id);
        if (m.id.isNotEmpty) _deletedEventIds.add(m.id);
        if (nid != null && nid.isNotEmpty) _deletedEventIds.add(nid);
        onDeletedIdsChanged?.call();
        return true;
      }
    }
    return false;
  }

  /// Removes a message locally (deletion request / mod delete). Mirrors
  /// `publishDeletionEvent`'s DOM + stored-message removal. Matches on both the
  /// event id and the nymMessageId (PM/group bubbles key on nymMessageId).
  bool removeMessage(String messageId) {
    var changed = false;
    for (final list in state.messages.values) {
      final before = list.length;
      list.removeWhere(
          (m) => m.id == messageId || m.nymMessageId == messageId);
      if (list.length != before) changed = true;
    }
    if (changed) state = state.copyWith();
    return changed;
  }

  /// Real reactor nyms for [messageId] / [emoji] (users.js reactor map). Exposes
  /// the private `_reactors` map so the reactors modal can show real names.
  List<String> reactorNyms(String messageId, String emoji) {
    final byEmoji = _reactors[messageId];
    if (byEmoji == null) return const [];
    final reactors = byEmoji[emoji];
    if (reactors == null) return const [];
    return reactors.values.where((n) => n.isNotEmpty).toList();
  }

  /// Reactor pubkey→nym map for [messageId] / [emoji] (null if none).
  Map<String, String>? reactorsFor(String messageId, String emoji) =>
      _reactors[messageId]?[emoji];

  // -------------------------------------------------------------------------
  // Channel management (docs/specs/03 §1.3–§1.6). Persistence to the KV list
  // sets is handled by the controller via the change callbacks; this layer owns
  // the in-memory `channels` registry + companion sets.
  // -------------------------------------------------------------------------

  /// Adds a channel to the registry if not present (`addChannel`). [geohash]
  /// non-empty marks a geohash channel. Returns the registered [ChannelEntry].
  ChannelEntry addChannel(String channel, {String geohash = ''}) {
    final key = (geohash.isNotEmpty ? geohash : channel).toLowerCase();
    final existing = state.channels.where((c) => c.key == key);
    if (existing.isNotEmpty) return existing.first;
    final entry = ChannelEntry(channel: channel, geohash: geohash);
    state.channels.add(entry);
    state = state.copyWith();
    return entry;
  }

  /// Switches the active view to a channel, adding it first if unknown
  /// (`switchChannel`). [geohash] non-empty selects a geohash channel.
  void switchChannel(String channel, {String geohash = ''}) {
    final key = (geohash.isNotEmpty ? geohash : channel).toLowerCase();
    if (!state.channels.any((c) => c.key == key)) {
      addChannel(channel, geohash: geohash);
    }
    switchView(ChatView.channel(geohash.isNotEmpty ? geohash : channel));
  }

  /// Removes a channel from the registry (`removeChannel`). `#nymchat` cannot be
  /// removed. If the removed channel is active, switches to `#nymchat`. Returns
  /// true if a channel was removed.
  bool removeChannel(String key) {
    final k = key.toLowerCase();
    if (k == kDefaultChannel) return false;
    final before = state.channels.length;
    state.channels.removeWhere((c) => c.key == k);
    state.pinnedChannels.remove(k);
    if (state.view.kind == ViewKind.channel && state.view.id.toLowerCase() == k) {
      switchView(const ChatView.channel(kDefaultChannel));
    } else {
      state = state.copyWith();
    }
    return state.channels.length != before;
  }

  /// Toggles a channel's pinned (favorite) status (`togglePin`). `#nymchat` can
  /// neither be pinned nor unpinned — it is always treated as the top channel,
  /// so the toggle is a no-op for it (channels.js `togglePin`: early return for
  /// `'nymchat'`). Returns the new pinned state.
  bool togglePin(String key) {
    final k = key.toLowerCase();
    // #nymchat is always at the top; the PWA neither pins nor unpins it.
    if (k == kDefaultChannel) return state.pinnedChannels.contains(k);
    if (state.pinnedChannels.contains(k)) {
      state.pinnedChannels.remove(k);
      state = state.copyWith();
      return false;
    }
    state.pinnedChannels.add(k);
    state = state.copyWith();
    return true;
  }

  /// Hides a channel from the sidebar (`hiddenChannels`). `#nymchat` cannot be
  /// hidden (channels.js `toggleHideChannel`: early return for `'nymchat'`).
  /// Returns the new state.
  bool hideChannel(String key) {
    final k = key.toLowerCase();
    if (k == kDefaultChannel) return false; // #nymchat cannot be hidden
    final added = state.hiddenChannels.add(k);
    if (added) state = state.copyWith();
    return added;
  }

  /// Unhides a channel.
  void unhideChannel(String key) {
    if (state.hiddenChannels.remove(key.toLowerCase())) {
      state = state.copyWith();
    }
  }

  /// Blocks a channel from discovery and removes it from the sidebar
  /// (`blockChannel`). `#nymchat` cannot be blocked. If the blocked channel is
  /// active, switches to `#nymchat`.
  bool blockChannel(String key) {
    final k = key.toLowerCase();
    if (k == kDefaultChannel) return false;
    state.blockedChannels.add(k);
    state.channels.removeWhere((c) => c.key == k);
    // NOTE: the PWA's `blockChannel` (channels.js:862-888) never touches
    // `pinnedChannels` — a favorited channel keeps its favorite through a
    // block/unblock round-trip.
    if (state.view.kind == ViewKind.channel && state.view.id.toLowerCase() == k) {
      switchView(const ChatView.channel(kDefaultChannel));
    } else {
      state = state.copyWith();
    }
    return true;
  }

  /// Unblocks a channel and re-adds it to the registry.
  void unblockChannel(String key, {String geohash = ''}) {
    final k = key.toLowerCase();
    if (state.blockedChannels.remove(k)) {
      addChannel(geohash.isNotEmpty ? geohash : key, geohash: geohash);
    }
  }

  /// Hydrates the channel companion sets/maps from persisted KV state (boot).
  ///
  /// [replace] switches the pinned/hidden/blocked sets from an additive union
  /// (boot hydration of an empty store) to a FULL REPLACE — the PWA's synced
  /// apply does `nym.pinnedChannels = new Set(s.pinnedChannels)` (and the same
  /// for blocked/hidden, app.js:6350-6389), so an unpin/unhide/unblock on one
  /// device propagates instead of resurrecting from the local union.
  /// joinedChannels stays additive in both modes (the PWA's userJoinedChannels
  /// apply only ever adds, app.js:6362-6376).
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
    state = state.copyWith();
  }

  /// Hydrates cached messages for a channel/PM/group key (boot from CacheStore).
  void hydrateMessages(String key, List<Message> msgs) {
    if (msgs.isEmpty) return;
    _hydrateMessagesInto(key, msgs);
    state = state.copyWith();
  }

  /// Bulk boot hydration of ALL cached channel + PM/group histories — the
  /// native `hydrateFromCache` message pass (persistence.js:427-475). Every
  /// message id is seeded into [_seenIds] so the D1 replay ([ingestEvent] /
  /// the PM archive restore) dedups against the cached copies, channel keys
  /// raise `channelLastActivity` for the sidebar sort (persistence.js:438-453),
  /// and ONE `copyWith` at the end repaints the (possibly already-open) view.
  void hydrateAllMessages(Map<String, List<Message>> byKey) {
    var changed = false;
    byKey.forEach((key, msgs) {
      if (key.isEmpty || msgs.isEmpty) return;
      // Re-key a legacy-encoded PM thread onto the canonical lowercase-hex
      // storage key ([switchView]'s canonicalization) so restored history and
      // the live view always share ONE thread — a `pm-<PUBKEY>` cache row
      // must not open as an empty parallel conversation.
      if (_hydrateMessagesInto(_canonicalPmStorageKey(key), msgs)) {
        changed = true;
      }
    });
    // Rebuild the PM sidebar rows from the hydrated threads — the PWA's
    // `_populateSidebarFromHydration` (persistence.js:533-549): every cached
    // 1:1 thread gets its conversation entry back at boot, named from the
    // (already-hydrated) users map with the `nym` fallback. Without this the
    // rows only reappear if the D1 replay delivers a NOT-yet-cached message
    // (the cached copies dedup out before `ingestPMMessage` touches
    // `pmConversations`). Groups are skipped like the PWA (their entries come
    // from the group metadata store); closed PMs stay closed (the PWA's cache
    // has no thread for a deleted PM — `deletePM` purges it — so hydration
    // never resurrects one there either).
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
      // Canonical lowercase hex, matching [switchView]'s PM-id
      // canonicalization: the row's pubkey feeds `ChatView.pm(...)` on tap and
      // the exact-match routing/unread keys downstream (the Nymbot
      // `view.id == kNymbotPubkey` screen swap), so a legacy-encoded restored
      // id must never produce a row that misses them.
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
        lastMessageTime:
            ts > 0 ? ts : DateTime.now().millisecondsSinceEpoch,
      ));
      onPMConversationAdded?.call(peer);
      changed = true;
    }
    if (changed) state = state.copyWith();
  }

  /// Canonicalizes a `pm-<pubkey>` storage key's peer id to lowercase 64-hex,
  /// mirroring [switchView]'s PM-id canonicalization. Non-PM keys and already
  /// canonical (or non-hex) ids pass through unchanged. Keeps every restored
  /// thread on the SAME key the live view/unread/routing paths use.
  String _canonicalPmStorageKey(String key) {
    if (!key.startsWith('pm-')) return key;
    final id = key.substring(3);
    if (_hex64AnyCaseRe.hasMatch(id) && id != id.toLowerCase()) {
      return 'pm-${id.toLowerCase()}';
    }
    return key;
  }

  /// Shared hydration insert: dedup-seed + append + resort one key's cached
  /// messages, tracking channel last-activity. Returns true if anything landed.
  /// Does NOT emit state — callers own the repaint.
  bool _hydrateMessagesInto(String key, List<Message> msgs) {
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    var added = false;
    var lastTs = 0;
    for (final m in msgs) {
      if (m.id.isNotEmpty && !_seenIds.add(m.id)) continue;
      m.seq = _nextIngestSeq();
      list.add(m);
      added = true;
      if (m.timestamp > lastTs) lastTs = m.timestamp;
    }
    if (added) list.sort(compareMessages);
    // Channel keys feed the sidebar recency sort (persistence.js sets
    // `channelLastActivity` from the hydrated history); PM/group keys don't.
    if (lastTs > 0 && !key.startsWith('pm-') && !key.startsWith('group-')) {
      if (lastTs > (state.channelLastActivity[key] ?? 0)) {
        state.channelLastActivity[key] = lastTs;
      }
    }
    return added;
  }

  /// Hydrates cached profiles into the user store (boot from CacheStore).
  void hydrateProfiles(Map<String, UserProfile> profiles) {
    profiles.forEach((pubkey, p) {
      final existing = state.users[pubkey];
      // PWA name chain `name || username || display_name`, 20-char cap
      // (nostr-core.js:697-700) — [UserProfile] parses `username`, so the
      // cached path resolves the same nym as live kind-0 ingest.
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
        // Missing-name fallback is 'nym' (`getNymFromPubkey` → `nym#xxxx`,
        // users.js:1085 — the PWA never shows 'anon').
        state.users[pubkey] = User(
          pubkey: pubkey,
          nym: getNymFromPubkey(resolvedName ?? 'nym', pubkey),
          profile: p,
        );
      }
    });
    // Cached SELF profile → restore the header nym immediately, the native
    // analogue of the PWA applying the cached login profile name before
    // relays connect (`nym_nostr_login_profile`, app.js:4514-4522). Without
    // this the boot identity's ephemeral/derived nick stays in `selfNym`
    // until a live kind-0 lands — which `_ingestProfile`'s no-op guard may
    // then skip because this hydration already stored the same profile.
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

  /// Hydrates cached reactions (entries shape `[[emoji,[[reactor,nym]]]]`) into
  /// the reactor map and recomputes tallies (boot from CacheStore).
  void hydrateReactions(Map<String, List<dynamic>> entriesByMessage) {
    entriesByMessage.forEach((messageId, entries) {
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
    state = state.copyWith();
  }

  /// Snapshot of reactions in the CacheStore `entries` shape, for flushing.
  Map<String, List<dynamic>> reactionEntriesSnapshot() {
    final out = <String, List<dynamic>>{};
    _reactors.forEach((messageId, byEmoji) {
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

  /// Records channel activity (used by send paths) so the sort floats it up.
  void touchChannelActivity(String storageKey, {int? ms}) {
    state.channelLastActivity[storageKey] =
        ms ?? DateTime.now().millisecondsSinceEpoch;
    state = state.copyWith();
  }

  /// Seeds the sidebar + activity/unread maps from a D1 channel-activity probe
  /// (the controller's `_discoverChannelActivity`, ported from channels.js
  /// `_populateSidebarFromD1Activity` + `_mergeD1Last` + `_seedUnreadFromD1Activity`,
  /// channels.js:215-284). Applied for BOTH the geohash discovery
  /// (`channel-active`) and the named discovery (`channel-active-named`) — the
  /// caller passes [geohash]=true for the former so a discovered key registers as
  /// a geohash channel.
  ///
  /// [activity] maps a channel/geohash key (bare, no `#`) → 24 hourly message
  /// buckets (index 0 = current hour); [last] maps the same key → last-activity
  /// unix-SECONDS. Effects, all idempotent:
  ///   1. **Discovery → sidebar**: a key with recent activity that the user hasn't
  ///      blocked/hidden and isn't already listed is added via [addChannel] (cap
  ///      [_kDiscoverSidebarLimit], most-recent first — `SIDEBAR_DISCOVER_LIMIT`).
  ///   2. **Last-activity**: `channelLastActivity[#key]` is raised to the D1
  ///      last-seen (ms) so the channel sorts by real recency (PWA keeps the max).
  ///   3. **Unread floor** ([seedUnread] passes only): for an already-listed
  ///      (joined) channel that ISN'T the active view, the buckets NEWER than
  ///      the channel's read watermark seed `unreadCounts[#key]` as a FLOOR
  ///      (only ever raised — D1 is the archive of record, channels.js:268-269).
  ///
  /// Mirrors the PWA's discovery vs. known split: only the spam-aware
  /// `channel-activity` probe for KNOWN channels feeds unread floors
  /// (`_mergeUnreadBuckets(known)` → `_seedUnreadFromD1Activity`,
  /// channels.js:164-166/320-323 — "Spam-aware activity feeds unread floors
  /// only"); the raw `channel-active`/`channel-active-named` discovery buckets
  /// drive sidebar/globe recency only, so callers pass [seedUnread] false for
  /// them. The bucket span is bounded by the per-channel `channelLastRead`
  /// watermark exactly like `_seedUnreadFromD1Activity` (channels.js:258-266):
  /// a channel read N hours ago seeds at most the newest N hourly buckets.
  void applyChannelActivity(
    Map<String, List<int>> activity,
    Map<String, int> last, {
    bool geohash = false,
    bool seedUnread = false,
  }) {
    if (activity.isEmpty && last.isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var changed = false;

    // 0) Faithful D1 heat (C05-3): for a geohash pass, stash the per-hour buckets
    //    D1 reported (the native `_geohashD1Activity`, channels.js:128-174) so the
    //    globe can climb the palette by the true `Σ max(local[i], d1[i])` instead
    //    of a flat floor. Keyed by the bare lowercased geohash (the same key
    //    `buildGeohashChannels` reads). Skipped for NAMED-channel passes (the
    //    globe only heats geohashes). A blank/blocked key is dropped; an
    //    all-zero bucket array is pruned so stale empties don't linger.
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

    // 2) Last-activity: raise channelLastActivity[#key] to the newest D1 ts.
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

    // 1) Discovery → sidebar. Rank candidates (not yet listed) by last-activity
    //    (falling back to the newest non-empty bucket's hour) and add the top N.
    final candidates = <({String key, int ts})>[];
    activity.forEach((rawKey, buckets) {
      final key = rawKey.toLowerCase();
      if (key.isEmpty || key == kDefaultChannel) return;
      if (state.blockedChannels.contains(key) ||
          state.hiddenChannels.contains(key)) {
        return;
      }
      // A bare word/geohash only (the PWA's `/^[\p{L}\p{N}]+$/u` guard).
      if (!_isSimpleChannelName(key)) return;
      if (state.channels.any((c) => c.key == key)) return; // already listed
      final tsMs = state.channelLastActivity['#$key'] ??
          _approxLastFromBuckets(buckets, nowMs);
      if (tsMs <= 0) return; // no recent activity → don't surface
      candidates.add((key: key, ts: tsMs));
    });
    if (candidates.isNotEmpty) {
      candidates.sort((a, b) => b.ts.compareTo(a.ts));
      for (final c in candidates.take(_kDiscoverSidebarLimit)) {
        // Geohash discovery registers the key as a geohash channel so the globe
        // + proximity sort treat it correctly; named discovery as a plain name.
        addChannel(c.key, geohash: geohash ? c.key : '');
        if ((state.channelLastActivity['#${c.key}'] ?? 0) < c.ts) {
          state.channelLastActivity['#${c.key}'] = c.ts;
        }
        changed = true;
      }
    }

    // 3) Unread floor for already-listed, non-active channels — spam-aware
    //    known-channel passes only (`_seedUnreadFromD1Activity`).
    if (seedUnread) {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      activity.forEach((rawKey, buckets) {
        final key = rawKey.toLowerCase();
        if (key.isEmpty) return;
        final storageKey = '#$key';
        // Never seed the open view (it's being read) or a blocked channel.
        if (state.view.kind == ViewKind.channel &&
            state.view.storageKey == storageKey) {
          return;
        }
        if (state.blockedChannels.contains(key)) return;
        if (!state.channels.any((c) => c.key == key)) return; // joined only
        // Bound the bucket span by the read watermark (channels.js:258-266):
        // hourly buckets, index 0 = current hour; sum only the hours after
        // lastRead (whole 24h window when never read). Watermarks are stamped
        // under both the '#key' storage form and the bare key (clearUnread) —
        // honor whichever is newest.
        final byStorage = _channelLastRead[storageKey] ?? 0;
        final byBare = _channelLastRead[key] ?? 0;
        final lastRead = byStorage > byBare ? byStorage : byBare;
        final span = lastRead > 0
            ? ((nowSec - lastRead) / 3600).ceil().clamp(0, 24)
            : 24;
        var count = 0;
        for (var h = 0; h < span && h < buckets.length; h++) {
          if (buckets[h] > 0) count += buckets[h];
        }
        if (count <= 0) return;
        // D1 is a FLOOR: only ever raise the badge, never lower it.
        if (count > (state.unreadCounts[storageKey] ?? 0)) {
          state.unreadCounts[storageKey] = count;
          changed = true;
        }
      });
    }

    if (changed) state = state.copyWith();
  }

  /// Cap on how many never-opened channels a single D1 discovery pass surfaces
  /// into the sidebar (`SIDEBAR_DISCOVER_LIMIT`, channels.js:219).
  static const int _kDiscoverSidebarLimit = 30;

  /// True when [name] is a single run of letters/digits — the PWA's
  /// `/^[\p{L}\p{N}]+$/u` gate before adding a discovered channel to the sidebar
  /// (channels.js:234), so a malformed/compound key can't create a junk row.
  static bool _isSimpleChannelName(String name) =>
      name.isNotEmpty && RegExp(r'^[\p{L}\p{N}]+$', unicode: true).hasMatch(name);

  /// Approximates a channel's last-activity ms from its hourly buckets when the
  /// `last` map omitted it: the first non-zero bucket (index = hours ago) →
  /// `(now - h*3600s)` (PWA `_d1ChannelLastActivityMs`, channels.js:204-207).
  /// Returns 0 when every bucket is empty.
  static int _approxLastFromBuckets(List<int> buckets, int nowMs) {
    for (var h = 0; h < buckets.length; h++) {
      if (buckets[h] > 0) return nowMs - h * 3600 * 1000;
    }
    return 0;
  }

  /// Appends a locally-echoed self message to the current view (composer SEND).
  /// For PM/group sends, pass [nymMessageId] so inbound receipts can match it
  /// and advance the delivery ticks. Returns the appended [Message].
  Message? sendLocal(String text,
      {String? nymMessageId,
      String? pubkeyOverride,
      String? authorOverride,
      Map<String, dynamic>? fileOffer}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final view = state.view;
    final list = state.messages.putIfAbsent(view.storageKey, () => <Message>[]);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nowSec = nowMs ~/ 1000;
    // [pubkeyOverride]/[authorOverride] are the pseudonymous-send path: the
    // optimistic echo carries the per-message ephemeral pubkey + random anon
    // nym instead of the durable identity (publishMessagePseudonymous).
    final pubkey = pubkeyOverride ?? state.selfPubkey;
    final author = authorOverride ?? state.selfNym;

    final m = Message(
      id: '_optim_${_nextLocalSeq().toRadixString(36)}',
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
      deliveryStatus: DeliveryStatus.sent,
      senderVerified: true,
      // A P2P share echoes as a file-offer card (p2p.js:171 sets
      // isFileOffer:true + fileOffer on the local displayMessage).
      isFileOffer: fileOffer != null,
      fileOffer: fileOffer,
    );
    list.add(m);
    m.optimistic = true;
    if (nymMessageId != null) _seenNymMessageIds.add(nymMessageId);

    // Own-message local-hide notices (messages.js:637-650). The message is still
    // sent to relays regardless; these only govern the LOCAL view. A file-offer
    // echo carries no user-typed body, so it is exempt. The message stays in the
    // data model either way (render-time hiding via [isMessageFiltered], the
    // native analogue of the PWA's `displayMessage` early-return).
    if (fileOffer == null) {
      final keywordHit = state.hasBlockedKeyword(trimmed, author);
      if (keywordHit || state.blockedUsers.contains(pubkey)) {
        // Blocked keyword / block rule → the body is hidden locally (filtered by
        // [isMessageFiltered]); a system line explains it was still sent.
        final reason = keywordHit
            ? 'matched one of your blocked keywords'
            : 'matched a block rule';
        addSystemMessage(
            'Your message $reason and was hidden locally. It was still sent.');
      } else if (SpamFilter.isSpamMessage(trimmed,
          enabled: appSpamFilterEnabled,
          aggressive: appSpamFilterAggressive)) {
        // Heuristic spam → the message is NOT hidden from us (own spam is not
        // filtered), but a self-only line explains it was filtered for everyone
        // else, with a "Report false positive" action (messages.js:643-647).
        addSystemMessageWithAction(
          'Your message was flagged by the spam filter and not shown to anyone '
          'but yourself.',
          SystemAction(
            kind: SystemActionKind.reportSpamFalsePositive,
            label: 'Report false positive',
            payload: trimmed,
          ),
        );
      }
    }

    // New list identity so listeners rebuild.
    state = state.copyWith();
    return m;
  }

  /// Reconciles an optimistic channel echo with its real signed event, mirroring
  /// the PWA's `_replaceOptimisticMessage` (messages.js:148). Finds the locally
  /// echoed message by its temp id [optimisticId], rewrites its id (and
  /// created_at / ms) to the signed event's values IN PLACE, clears the
  /// `optimistic` flag, and — crucially — registers [realId] in [_seenIds] so the
  /// relay echo that arrives later (carrying the same real id) is deduped instead
  /// of appended as a duplicate. Re-sorts the list when the timestamp shifted
  /// (PoW mining can move created_at). No-op if the optimistic message is gone
  /// (e.g. the user already switched/cleared the view).
  ///
  /// Channel messages have no shared `nymMessageId`, so without this the
  /// `_optim_*` echo and the relay-echoed real-id event would both render — the
  /// double-send the user reported. PM/group sends already dedupe via
  /// [_seenNymMessageIds]; this is the channel analogue.
  void replaceOptimistic(
    String optimisticId,
    String realId, {
    int? realCreatedAt,
    int? realMs,
  }) {
    if (realId.isEmpty) return;
    // Register the real id first so even a relay echo that races ahead of this
    // call (already appended) can't slip a second copy through afterwards.
    final alreadySeen = !_seenIds.add(realId);
    for (final list in state.messages.values) {
      final idx = list.indexWhere((m) => m.id == optimisticId);
      if (idx < 0) continue;
      final m = list[idx];
      // If a relay echo with the real id already landed (rare race), drop the
      // optimistic placeholder rather than keep a duplicate.
      if (alreadySeen && list.any((x) => x.id == realId && !identical(x, m))) {
        list.removeAt(idx);
        state = state.copyWith();
        return;
      }
      final oldCreated = m.createdAt;
      m.id = realId;
      if (realCreatedAt != null && realCreatedAt > 0) {
        m.createdAt = realCreatedAt;
        m.timestamp = realCreatedAt * 1000;
      }
      if (realMs != null && realMs > 0) m.ms = realMs;
      m.optimistic = false;
      if (oldCreated != m.createdAt) list.sort(compareMessages);
      state = state.copyWith();
      return;
    }
    // Optimistic message no longer present; the real id is registered so the
    // relay echo still won't double up.
    state = state.copyWith();
  }

  /// Marks an optimistic channel echo as failed (PWA `_markOptimisticFailed`,
  /// messages.js:208): the publish threw, so the placeholder stays but flips to
  /// the failed delivery state. No-op if the message is gone.
  void markOptimisticFailed(String optimisticId) {
    for (final list in state.messages.values) {
      final idx = list.indexWhere((m) => m.id == optimisticId);
      if (idx < 0) continue;
      list[idx].deliveryStatus = DeliveryStatus.failed;
      state = state.copyWith();
      return;
    }
  }

  /// Injects a centered system/action pill into a conversation's message flow,
  /// mirroring `displaySystemMessage(content, type)` (`messages.js:1511`). Routes
  /// to [storageKey] when given, else the active view. Pass [action] for the
  /// purple-italic `.action-message` variant. This is the in-list sink for
  /// command feedback, P2P/call status, flood notices, etc.
  void addSystemMessage(String content, {bool action = false, String? storageKey}) {
    if (content.isEmpty) return;
    final key = storageKey ?? state.view.storageKey;
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    list.add(Message.system(content, action: action, createdAtMs: nowMs)
      ..seq = _nextLocalSeq());
    state = state.copyWith();
  }

  /// Like [addSystemMessage] but the injected pill carries an inline
  /// [SystemAction] button (the spam false-positive "Report false positive"
  /// affordance, messages.js:645). Routes to [storageKey] when given, else the
  /// active view.
  void addSystemMessageWithAction(String content, SystemAction action,
      {String? storageKey}) {
    if (content.isEmpty) return;
    final key = storageKey ?? state.view.storageKey;
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    list.add(Message.systemWithAction(content, action, createdAtMs: nowMs)
      ..seq = _nextLocalSeq());
    state = state.copyWith();
  }
}

final appStateProvider =
    StateNotifierProvider<AppStateNotifier, AppState>((ref) {
  return AppStateNotifier();
});

/// The active [ChatView].
final currentViewProvider = Provider<ChatView>((ref) {
  return ref.watch(appStateProvider).view;
});

/// Registered channels (sidebar PUBLIC CHANNELS).
final channelsProvider = Provider<List<ChannelEntry>>((ref) {
  return ref.watch(appStateProvider).channels;
});

/// PM conversations, most-recent first (sidebar PRIVATE MESSAGES).
final pmListProvider = Provider<List<PMConversation>>((ref) {
  final pms = [...ref.watch(appStateProvider).pmConversations];
  pms.sort((a, b) => b.lastMessageTime - a.lastMessageTime);
  return pms;
});

/// Groups (also surfaced under PRIVATE MESSAGES).
final groupsProvider = Provider<List<Group>>((ref) {
  return ref.watch(appStateProvider).groups;
});

/// Users keyed by pubkey (sidebar ONLINE NYMS source). Blocked users and
/// keyword-matched nyms are filtered out (users.js `updateUserList`:
/// `if (blockedUsers.has(pubkey)) return;` and the nym keyword guard).
final usersProvider = Provider<Map<String, User>>((ref) {
  final s = ref.watch(appStateProvider);
  // Gibberish-nym filtering is active whenever the spam filter's aggressive mode
  // is on (the PWA's `isGibberishNym` short-circuits false unless BOTH
  // spamFilterEnabled && spamFilterAggressive — nostr-core.js:944-945). It runs
  // even with empty block sets, so the no-block fast-path is only valid when it
  // cannot fire.
  final gibberishActive = appSpamFilterEnabled && appSpamFilterAggressive;
  if (s.blockedUsers.isEmpty && s.blockedKeywords.isEmpty && !gibberishActive) {
    return s.users;
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
    // Drop randomized spam-bot nicknames from the Nyms source — the PWA excludes
    // `isGibberishNym(user.nym)` for non-self non-friend users in
    // `_doUpdateUserList` (users.js:1375-1377). The PWA's stored `user.nym` is
    // the BARE base nym (presence strips the suffix, users.js:1153; messages use
    // the raw `n` tag), so `_looksLikeRandomToken` sees an alphanumeric handle.
    // Flutter always stores the suffixed `base#suffix` form (getNymFromPubkey),
    // and the `#` makes `_looksLikeRandomToken` reject it outright — so we strip
    // the suffix first to recover the same base the PWA tests.
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

/// The filtered, ordered messages for one conversation [storageKey] (oldest
/// first). Messages from blocked users, keyword matches (content OR author
/// nym), and heuristic spam are dropped — mirrors the PWA's
/// `getFilteredMessages`/`getFilteredPMMessages` (messages.js:2934-2949), the
/// single pipeline `renderMessagesWithVirtualScroll` renders through, which
/// makes it shared by the single view AND every columns-deck column
/// (columns.js:510).
List<Message> visibleMessagesFor(AppState s, String storageKey) {
  final list = s.messages[storageKey] ?? const <Message>[];
  // Fast-path only when nothing can filter: no blocks AND the content spam
  // filter is off. With the filter on (its default) every non-own message is
  // tested, so the empty-block-sets shortcut must NOT skip it.
  final canFilter = s.blockedUsers.isNotEmpty ||
      s.blockedKeywords.isNotEmpty ||
      appSpamFilterEnabled;
  final visible = canFilter
      ? list.where((m) => !s.isMessageFiltered(m)).toList()
      : [...list];
  visible.sort(compareMessages);
  return visible;
}

/// Ordered messages for the active view (oldest first), via
/// [visibleMessagesFor] — mirrors the PWA's `.message.blocked` hiding
/// (messages.js §11) plus the `spamHit` term of the non-own hide branch
/// (messages.js:648).
final messagesForCurrentViewProvider = Provider<List<Message>>((ref) {
  final s = ref.watch(appStateProvider);
  return visibleMessagesFor(s, s.view.storageKey);
});

/// Transient "scroll-flash" signal: the id of the message currently flashing its
/// highlight halo, or null. Mirrors the PWA's `.message-scroll-flash` class that
/// `_scrollToQuotedMessage` adds to a jumped-to message for ~1.6s
/// (messages.js:2775-2776 `setTimeout(() => target.classList.remove(...), 1600)`).
/// [MessageRow] watches this and pulses the matching message; calling
/// `ref.read(flashedMessageProvider.notifier).flash(id)` (re)arms it.
class FlashedMessageNotifier extends StateNotifier<String?> {
  FlashedMessageNotifier() : super(null);

  /// The PWA clears the class 1.6s after adding it.
  static const Duration _flashDuration = Duration(milliseconds: 1600);

  Timer? _timer;

  /// Flashes [messageId], replacing any in-flight flash, and auto-clears after
  /// [_flashDuration] (re-flashing the same id restarts the timer, matching the
  /// PWA where a repeated jump re-adds the class).
  void flash(String messageId) {
    if (messageId.isEmpty) return;
    _timer?.cancel();
    // Force a state change even when re-flashing the same id (so the row
    // re-triggers its pulse): clear, then set on the next microtask.
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

/// Reactions for the active view's messages (message id → tallies).
final reactionsProvider = Provider<Map<String, List<MessageReaction>>>((ref) {
  return ref.watch(appStateProvider).reactions;
});

/// Unread counts (channel key / pm pubkey / group id → count).
final unreadCountsProvider = Provider<Map<String, int>>((ref) {
  return ref.watch(appStateProvider).unreadCounts;
});

/// Pubkeys currently typing in the active view (non-expired indicators).
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

/// Polls visible in the active channel view (geohash match), time-ordered.
/// Polls are channel-only (docs/specs/03 §6) — returns empty in PM/group views.
final pollsForCurrentViewProvider = Provider<List<Poll>>((ref) {
  final s = ref.watch(appStateProvider);
  if (s.view.kind != ViewKind.channel) return const [];
  final geohash = s.view.id;
  final out = s.polls.values.where((p) => p.geohash == geohash).toList()
    ..sort((a, b) => a.createdAt - b.createdAt);
  return out;
});

/// Per-message zap aggregates (message id → total sats + zappers).
final zapsProvider = Provider<Map<String, MessageZaps>>((ref) {
  return ref.watch(appStateProvider).zaps;
});

/// Friended pubkeys (`nym_friends`) — settings FRIENDS list + friend badges.
final friendsProvider = Provider<Set<String>>((ref) {
  return ref.watch(appStateProvider).friends;
});

/// Blocked-user pubkeys (`nym_blocked`) — settings BLOCKED list.
final blockedUsersProvider = Provider<Set<String>>((ref) {
  return ref.watch(appStateProvider).blockedUsers;
});

/// Blocked keywords (`nym_blocked_keywords`, lowercased) — settings list.
final blockedKeywordsProvider = Provider<Set<String>>((ref) {
  return ref.watch(appStateProvider).blockedKeywords;
});

/// The user's resolved geolocation for proximity sorting (set by the location
/// service / UI). Null when unavailable or permission denied.
final userLocationProvider = StateProvider<UserLocation?>((ref) => null);

/// Registered channels in the exact sidebar order: visibility per the PWA's
/// `applyHiddenChannels` (channels.js:820-833 — `#nymchat` and the ACTIVE row
/// are NEVER hidden, neither via the hidden set nor via hide-non-pinned), then
/// `sortChannelsByActivity`, then the CSS `order` bands (styles-shell.css:
/// 344-390): nymchat (-4) > active (-3) > pinned (-2) > has-unread (-1) > rest.
final sortedChannelsProvider = Provider<List<ChannelEntry>>((ref) {
  final s = ref.watch(appStateProvider);
  final sortByProximity = ref.watch(
      settingsProvider.select((settings) => settings.sortByProximity));
  // `hideNonPinned` (settings.js `hideNonPinnedChannels`): when on, the sidebar
  // shows only pinned channels (the default channel always stays visible).
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
  // CSS `order` band partition — stable within each band, exactly like flex
  // `order` ties breaking on DOM order.
  int orderBand(ChannelEntry ch) {
    if (ch.key == kDefaultChannel) return -4;
    if (ch.key == activeKey) return -3;
    if (s.pinnedChannels.contains(ch.key)) return -2;
    if ((s.unreadCounts[ch.storageKey] ?? 0) > 0) return -1;
    return 0;
  }

  return [
    for (var band = -4; band <= 0; band++)
      ...sorted.where((ch) => orderBand(ch) == band),
  ];
});

// =============================================================================
// Recent emojis (shared API contract). The current recents `List<String>` plus
// `record(emoji)`, backed by the persisted [EmojiRecentsStore]. Consumed by the
// quick-react popup, the emoji/reactions pickers, and the call reactions bar.
// Mirrors reactions.js `addToRecentEmojis`/`loadRecentEmojis`.
// =============================================================================

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
      // Recents are best-effort; an unavailable store just yields empty recents.
    }
  }

  /// Records [emoji] as the most-recent (dedupe + prepend + cap), updating the
  /// in-memory list immediately and persisting in the background.
  void record(String emoji) {
    if (emoji.isEmpty) return;
    state = addRecentEmoji(state, emoji);
    final store = _store;
    if (store != null) {
      // Persist (the store re-derives from its own load, so just fire it).
      store.add(emoji);
    } else {
      // Store not hydrated yet — hydrate, then persist this pick.
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

/// The user's recent emojis (most-recent-first). Read the list directly;
/// `ref.read(recentEmojisProvider.notifier).record(emoji)` to bump one.
final recentEmojisProvider =
    StateNotifierProvider<RecentEmojisNotifier, List<String>>(
  (ref) => RecentEmojisNotifier(ref),
);

// =============================================================================
// Notification history (shared API contract). A 24h-trimmed list of recent
// notification entries with an unread count, mirroring the PWA's
// `notificationHistory` (`notifications.js:5-114`). Fed by message notifications
// and missed/declined calls; read by the shell bell badge + notifications modal.
// =============================================================================

/// One entry in the notification history.
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
    this.viewed = false,
  }) : receivedAt = (receivedAt != null && receivedAt > 0) ? receivedAt : ts;

  /// `'message' | 'mention' | 'reaction' | 'call' | 'pm' | 'group' | …`.
  final String type;
  final String title;
  final String body;

  /// Milliseconds since epoch.
  final int ts;

  /// When THIS client (or the syncing device) observed the notification, ms —
  /// the PWA's `receivedAt` (notifications.js:39-42). The viewed/last-read
  /// comparisons use this, not the event's `created_at`, so a delayed event
  /// with an older `created_at` isn't auto-marked viewed. Falls back to [ts]
  /// for legacy entries (`n.receivedAt || n.timestamp`).
  final int receivedAt;

  /// An opaque route/target the UI can use to navigate on tap (e.g. a PM pubkey,
  /// a channel key, or a group id). Null when not actionable.
  final String? route;

  /// The source event id (channel event id / PM nymMessageId / reaction id),
  /// used to dedup live + replayed copies (notifications.js `eventId`).
  /// Mutable: the cross-device history merge adopts a synced copy's id onto a
  /// fuzzily-matched local entry (app.js:5847-5850).
  String? eventId;

  /// The sender's pubkey (notifications.js `senderPubkey`), used in the
  /// no-eventId dedup fallback.
  final String? senderPubkey;

  /// The PWA footer context label derived from `channelInfo` — `in #<geohash>`
  /// for a channel/geohash source or `in <GroupName>` for a group (notifications
  /// .js:519-533). Null for PM/mention sources, which the panel labels from the
  /// type. Preferred by the panel over the type-derived label when present.
  final String? contextLabel;
  bool viewed;

  /// Serializes for the persisted history (N3). Mirrors the PWA's stored
  /// notification objects (`nym_notification_history`, notifications.js:228) —
  /// `timestamp` is the PWA field name so a value written by either client
  /// round-trips. Null fields are omitted to keep the blob compact.
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
        if (viewed) 'viewed': true,
      };

  /// Rebuilds an entry from persisted JSON (N3) OR a PWA-shaped synced record.
  /// Returns null when the record lacks the minimal fields
  /// (title/body/timestamp), so a corrupt row is skipped rather than throwing.
  ///
  /// A PWA record carries `channelInfo` instead of the native `type`/`route`
  /// fields (notifications.js entry shape); when the native fields are absent,
  /// type/route/eventId/senderPubkey are derived from it so cross-device
  /// merges of PWA-written history land actionable entries.
  static NotificationEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = raw['title'];
    final body = raw['body'];
    final ts = raw['timestamp'];
    if (title is! String || body is! String || ts is! num) return null;
    // PWA channelInfo fallbacks (type-specific route derivation mirrors the
    // notification onclick dispatch, notifications.js:92-108).
    String? ciType;
    String? ciRoute;
    String? ciEventId;
    String? ciPubkey;
    final ci = raw['channelInfo'];
    if (ci is Map) {
      if (ci['eventId'] is String) ciEventId = ci['eventId'] as String;
      if (ci['pubkey'] is String) ciPubkey = ci['pubkey'] as String;
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
      type: raw['type'] is String ? raw['type'] as String : (ciType ?? 'message'),
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
  /// [ref] is optional so unit tests can construct the notifier without a
  /// provider container; when null, persistence/hydration are skipped (the
  /// store stays in-memory, matching the pre-N3 behavior the tests assert).
  NotificationHistoryNotifier([this._ref])
      : super(const NotificationHistoryState()) {
    if (_ref != null) {
      _hydrating = true;
      _hydrate();
    }
  }

  final Ref? _ref;
  SharedPreferences? _prefs;

  /// True while [_hydrate] is loading the persisted history + seen-map. A
  /// [record] landing in this window would be deduped against an EMPTY
  /// history/seen-map and then thrown away when `_hydrate` overwrites the
  /// state (the boot race: the D1 backfill can fire in the same frame the
  /// provider is first read). Such calls are buffered in [_pendingRecords]
  /// and replayed once hydration completes, so they ingest against the real
  /// history exactly as if they had arrived after boot.
  bool _hydrating = false;
  final List<void Function()> _pendingRecords = [];

  /// Lightweight mirror of the entries buffered in [_pendingRecords] during
  /// hydration, exposed via [entriesForAlertDedup] so the LOUD alert path can
  /// dedup a multi-relay duplicate against a record that hasn't landed yet
  /// (the boot race the buffering itself was added for). Cleared with the
  /// buffer once hydration settles.
  final List<NotificationEntry> _pendingEntries = [];

  /// PWA localStorage key for the persisted bell history
  /// (`_loadNotificationHistory`/`_saveNotificationHistory`,
  /// notifications.js:218/231). Kept as a literal here (not a typed Settings
  /// field) so the cross-device sync key matches the PWA byte-for-byte.
  static const String _historyKey = 'nym_notification_history';

  static const int _maxAgeMs = 24 * 60 * 60 * 1000; // 24h
  static const int _cap = 100;

  // --- Cross-device notification read-state (N26, notifications.js:236-301) ---
  /// Stable "seen" keys (key → first-seen ms) so a notification dismissed/read
  /// on one device is silenced on another. Synced via the `nymchat-notifications`
  /// wrap (settings.js:537). The PWA's `seenNotificationKeys`.
  Map<String, int> _seenKeys = <String, int>{};

  /// PWA localStorage key for the persisted seen-keys map — kept literal so the
  /// cross-device key matches byte-for-byte (`nym_notification_seen`).
  static const String _seenKeysStoreKey = 'nym_notification_seen';
  static const int _seenKeysTtlMs = 48 * 60 * 60 * 1000; // 48h
  static const int _maxSeenKeys = 500;

  /// The cross-device "everything observed before this is read" watermark, ms —
  /// the PWA's `notificationLastReadTime` (`nym_notification_last_read`,
  /// app.js:746). Only ever adopted from another device via
  /// [adoptNotificationLastReadTime] (the PWA never advances it locally); an
  /// entry whose [NotificationEntry.receivedAt] is at/under it lands pre-viewed
  /// (notifications.js:55) and is excluded from the badge (notifications.js:
  /// 416-420).
  int _lastReadTimeMs = 0;
  static const String _lastReadStoreKey = 'nym_notification_last_read';

  /// The synced last-read watermark for the outbound `nymchat-notifications`
  /// wrap (settings.js:535).
  int get notificationLastReadTime => _lastReadTimeMs;

  /// Fired when the seen-keys map actually GROWS (a notification was viewed/
  /// dismissed here), so the controller can republish the read-state wrap — the
  /// native equivalent of the PWA's `_debouncedNostrSettingsSave` on
  /// `_rememberNotificationSeen`. Never fired by an inbound merge (idempotent).
  void Function()? onSeenChanged;

  /// Hydrates the bell history from SharedPreferences at boot so it survives a
  /// restart (N3). Mirrors the PWA's `_loadNotificationHistory`: JSON-decode the
  /// stored array, drop anything older than 24h, and adopt it (newest-first,
  /// capped). Best-effort — a missing/corrupt blob just yields an empty history.
  /// Re-derives the unread badge from the hydrated entries.
  Future<void> _hydrate() async {
    final ref = _ref;
    if (ref == null) return;
    try {
      final prefs = await ref.read(emojiPrefsProvider.future);
      _prefs = prefs;
      // N26: hydrate the cross-device seen-keys map (independent of the bell
      // history, so it loads even when the history blob is empty). MERGE into
      // (never overwrite) the live map: keys added during the async window by
      // an early settings-get merge or a view-open would otherwise be
      // clobbered (their `_persistSeenKeys` was a no-op while `_prefs` was
      // still null), so re-persist when pre-hydration keys existed.
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
      // Restore the last-read watermark (PWA boot read of
      // `nym_notification_last_read`, app.js:746). An inbound sync adopt that
      // raced hydration wins (monotonic max).
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
        entries.add(e);
      }
      if (entries.isEmpty || !mounted) return;
      entries.sort((a, b) => b.ts.compareTo(a.ts)); // newest first
      if (entries.length > _cap) entries.removeRange(_cap, entries.length);
      state = NotificationHistoryState(
        entries: entries,
        unread: _countUnread(entries),
      );
    } catch (_) {
      // Best-effort; an unavailable/corrupt store just yields an empty history.
    } finally {
      // Hydration is settled (loaded, empty, or failed) — replay any records
      // buffered during the window so they merge into the hydrated history
      // instead of being clobbered by it. Replaying AFTER the state overwrite
      // keeps the invariant: ingest never precedes hydration.
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

  /// Persists the current 24h history slice to SharedPreferences (N3). Mirrors
  /// the PWA's `_saveNotificationHistory` (notifications.js:231): re-encode the
  /// entries that are still within the 24h window. No-op in tests (no prefs).
  void _persist() {
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
      // Quota/serialization failures are non-fatal; live state still works.
    }
  }

  /// Blocked-sender pubkeys, excluded from the badge count. The PWA's
  /// `_doUpdateNotificationBadge` drops `blockedUsers.has(pubkey)` entries at
  /// count time (notifications.js:404-426). Defaults to empty (no change to the
  /// count) until the controller feeds the live block list via [setBlocked].
  Set<String> _blocked = const {};

  /// Updates the blocked-sender set used by the badge recompute and re-derives
  /// the unread count. Call when the block list changes (CROSS-FILE: wire from
  /// the controller's block/unblock path so a blocked sender's notifications
  /// stop counting immediately, mirroring the PWA's count-time exclusion).
  void setBlocked(Set<String> blocked) {
    _blocked = blocked;
    final unread = _countUnread(state.entries);
    if (unread != state.unread) {
      state = state.copyWith(unread: unread);
    }
  }

  /// Unread badge count over [entries] — the PWA's `_doUpdateNotificationBadge`
  /// predicate restricted to the terms the native store can evaluate: within
  /// the 24h window (`n.timestamp <= cutoff24h → false`, notifications.js:415)
  /// AND `!viewed` AND sender not blocked (notifications.js:404-426). The
  /// count-time 24h term matters because entries only get TRIMMED when the
  /// next [record] lands — a quiet bell would otherwise keep counting an
  /// aged-out entry until something new arrived. The `lastRead` /
  /// per-conversation `_notificationAlreadySeen` gates are handled by flipping
  /// `viewed` on read (see [markConversationSeen]).
  int _countUnread(List<NotificationEntry> entries) {
    final cutoff = DateTime.now().millisecondsSinceEpoch - _maxAgeMs;
    final lastRead = _channelLastReadSnapshot();
    return entries
        .where((e) =>
            !e.viewed &&
            e.ts > cutoff &&
            // Observed at/under the synced last-read watermark → read
            // elsewhere (`observedAt <= lastRead`, notifications.js:416-420).
            e.receivedAt > _lastReadTimeMs &&
            (_blocked.isEmpty || !_blocked.contains(e.senderPubkey)) &&
            !_alreadySeenByWatermark(e, lastRead))
        .length;
  }

  /// Snapshot of the per-conversation read watermarks for the badge predicate.
  /// Empty when the store is detached (tests) or the app state is unavailable.
  Map<String, int> _channelLastReadSnapshot() {
    final ref = _ref;
    if (ref == null) return const {};
    try {
      return ref.read(appStateProvider.notifier).channelLastRead;
    } catch (_) {
      return const {};
    }
  }

  /// PWA `_notificationAlreadySeen` (notifications.js:321-327): true when the
  /// source conversation's read watermark is at/after this notification's
  /// timestamp — a message already read (here, or on another device via the
  /// synced `nymchat-readstate` watermark) lands pre-viewed at record time
  /// (notifications.js:56/158) and is excluded from the badge count
  /// (notifications.js:422). Candidate keys mirror `_notificationConvKey`,
  /// covering both the bare route and the storage-key form the watermarks are
  /// stamped under.
  bool _alreadySeenByWatermark(
      NotificationEntry n, Map<String, int> lastRead) {
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

  /// Records a notification, trimming entries older than 24h and capping the
  /// list. Increments the unread count. Mirrors `showNotification`'s history
  /// push + `_updateNotificationBadge` (`notifications.js:5-114`).
  ///
  /// Deduped like the PWA (notifications.js:27-36): a matching [eventId], or the
  /// same title+body+sender within 60s, is dropped — so a live notification and
  /// its archive/replay copy don't both land.
  void record({
    required String type,
    required String title,
    required String body,
    String? route,
    int? ts,
    String? eventId,
    String? senderPubkey,
    String? contextLabel,
    int? receivedAtMs,
  }) {
    // The PWA's digest gate (`body.includes('10 recent messages:')`,
    // notifications.js:13/125): a channel-digest body never enters the bell
    // history or the badge count, on ANY path. Sits above the hydration
    // buffer so a digest is never buffered either.
    if (body.contains('10 recent messages:')) return;
    // Boot race: hydration hasn't resolved yet — buffer and replay after it,
    // so this record is deduped/seen-checked against the REAL history instead
    // of an empty one (and isn't clobbered by `_hydrate`'s state overwrite).
    if (_hydrating) {
      // Freeze receivedAt at buffer time (the PWA stamps `Date.now()` when the
      // notification is observed, notifications.js:42) so the replay doesn't
      // shift it to the hydration-complete instant.
      final observedAt =
          receivedAtMs ?? DateTime.now().millisecondsSinceEpoch;
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
            receivedAtMs: observedAt,
          ));
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final stamp = ts ?? now;
    // The PWA's `_addNotificationToHistory` age gate (notifications.js:135):
    // an event older than the 24h bell window never lands, no matter which
    // path delivered it — the caller-side silent gate isn't the only defense.
    if (now - stamp >= _maxAgeMs) return;

    // Dedup against existing history (live + replay can both fire).
    final isDupe = state.entries.any((e) {
      if (eventId != null &&
          eventId.isNotEmpty &&
          e.eventId != null &&
          e.eventId == eventId) {
        return true;
      }
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
      receivedAt: receivedAtMs ?? now,
      route: route,
      eventId: eventId,
      senderPubkey: senderPubkey,
      contextLabel: contextLabel,
    );
    // N26: silence a notification already seen/dismissed on another device (its
    // key is in the synced seen-map), observed before the synced last-read
    // watermark (`receivedAt <= notificationLastReadTime`, notifications.js:55),
    // OR at/under the source conversation's read watermark
    // (`_notificationAlreadySeen`, notifications.js:56/158) by landing it
    // pre-viewed — it stays in the bell history but doesn't bump the unread
    // badge (PWA showNotification, notifications.js:53-57). A newly-viewed
    // entry's key is remembered like the PWA so it silences on our other
    // devices too.
    if (_isSeen(entry) ||
        entry.receivedAt <= _lastReadTimeMs ||
        _alreadySeenByWatermark(entry, _channelLastReadSnapshot())) {
      entry.viewed = true;
      if (_rememberSeen(entry)) _persistSeenKeys();
    }
    final kept = [
      entry,
      ...state.entries.where((e) => now - e.ts < _maxAgeMs),
    ];
    if (kept.length > _cap) kept.removeRange(_cap, kept.length);
    final unread = _countUnread(kept);
    state = NotificationHistoryState(entries: kept, unread: unread);
    _persist(); // N3: survive a restart.
  }

  /// Marks the notifications for a single conversation viewed and re-derives the
  /// badge — the PWA's `_markConversationNotificationsSeen` (notifications.js:
  /// 345-355), invoked from `_markChannelRead` so that READING the source
  /// conversation clears its bell badge WITHOUT opening the bell modal
  /// (channels.js:1738-1739). [route] is the conversation key the notification
  /// was recorded with (a channel key, PM pubkey, or group id — the same value
  /// passed as `record(route: …)`); entries whose [NotificationEntry.route]
  /// matches are flipped to `viewed`. [tsSec] optionally bounds the flip to
  /// entries at/under that timestamp (mirroring the PWA's per-conversation
  /// `_notificationAlreadySeen` high-water mark); when null, all matching
  /// entries are marked seen.
  ///
  /// CROSS-FILE: call this from the controller's view-open handler
  /// (`_onViewOpened`) for each `ViewKind`, the way the PWA calls
  /// `_markConversationNotificationsSeen` on channel/PM/group read.
  void markConversationSeen(String route, {int? tsSec}) {
    if (route.isEmpty) return;
    // Boot race: operate on the hydrated history, not the empty pre-hydrate
    // state (which `_hydrate`'s overwrite would discard) — same buffering as
    // [record].
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
      if (_rememberSeen(e)) seenGrew = true; // N26: silence on other devices.
    }
    if (!changed) return;
    final entries = List.of(state.entries);
    state = state.copyWith(entries: entries, unread: _countUnread(entries));
    _persist(); // N3: persist the viewed flags.
    if (seenGrew) {
      _persistSeenKeys();
      onSeenChanged?.call();
    }
  }

  /// Marks every entry viewed and zeroes the unread count (modal opened). Each
  /// newly-viewed entry's key is remembered (N26) so reading the bell here
  /// silences the same notifications on our other devices.
  void markAllViewed() {
    // Boot race: defer until the persisted history has loaded so the flip
    // covers the real entries (and its seen-keys aren't clobbered).
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
    _persist(); // N3: persist the viewed flags.
    if (seenGrew) {
      _persistSeenKeys();
      onSeenChanged?.call();
    }
  }

  /// Marks the given [entries] viewed — the per-item half of the PWA's
  /// scroll-into-view read semantics (`_setupNotificationSeenObserver`,
  /// notifications.js:596-642: an item ≥60% visible in the modal body flips
  /// `viewed` + remembers its seen-key, deducting the badge per item). Each
  /// newly-viewed entry's key is remembered (N26) so it silences on our other
  /// devices; the badge is re-derived from the remaining unviewed entries.
  /// No-op for entries already viewed / not in the store.
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
    _persist(); // N3: persist the viewed flags.
    if (seenGrew) {
      _persistSeenKeys();
      onSeenChanged?.call();
    }
  }

  // --- Cross-device notification read-state (N26) -------------------------

  /// Stable per-notification key for the cross-device seen map (PWA
  /// `_notificationSeenKey`, notifications.js:238-248): the event id when known
  /// (`e:<id>`), else a sender+minute+body-prefix fallback. The body is clipped
  /// to 40 chars so the key matches across the full local copy and the
  /// 240-char-truncated synced copy. Null when nothing identifying.
  String? _seenKey(NotificationEntry n) {
    final evId = n.eventId ?? '';
    if (evId.isNotEmpty) return 'e:$evId';
    final pk = n.senderPubkey ?? '';
    if (pk.isEmpty && n.ts == 0) return null;
    final body = n.body;
    final prefix = body.length > 40 ? body.substring(0, 40) : body;
    return 'f:$pk:${n.ts ~/ 60000}:$prefix';
  }

  /// Has [n] already been seen (here or synced from another device)? PWA
  /// `_isNotificationSeen` (notifications.js:287).
  bool _isSeen(NotificationEntry n) {
    final k = _seenKey(n);
    return k != null && _seenKeys.containsKey(k);
  }

  /// Records [n]'s key as seen (PWA `_rememberNotificationSeen`,
  /// notifications.js:293). Returns true only when a NEW key was added so the
  /// caller can decide whether to persist + republish.
  bool _rememberSeen(NotificationEntry n) {
    final k = _seenKey(n);
    if (k == null || _seenKeys.containsKey(k)) return false;
    _seenKeys[k] = n.ts != 0 ? n.ts : DateTime.now().millisecondsSinceEpoch;
    return true;
  }

  /// TTL-prune (48h) then cap (500 newest) the seen-keys map (PWA
  /// `_pruneSeenNotificationKeys`, notifications.js:264).
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

  /// The pruned seen-keys map for the outbound `nymchat-notifications` wrap (PWA
  /// `seenNotifications`, settings.js:537). N26 outbound surface.
  Map<String, dynamic> seenNotificationsForSync() {
    _pruneSeenKeys();
    return Map<String, dynamic>.from(_seenKeys);
  }

  /// Merges a seen-keys map synced from another device (PWA, app.js:5760-5786):
  /// adopt each not-yet-expired key we don't already hold, then retroactively
  /// mark any matching local entry viewed so the badge clears. Idempotent — a
  /// re-merge of the same keys is a no-op and never republishes. Returns true if
  /// anything changed.
  bool mergeSeenNotifications(dynamic incoming) {
    if (incoming is! Map) return false;
    // Boot race: merge after hydration so the retro-mark runs against the
    // real entries and the merged keys persist (pre-hydration `_prefs` is
    // null). Returns false — the deferred merge reports nothing to buffer's
    // caller, which ignores the result.
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
    // Retroactively mark matching local entries viewed (app.js:5772-5786).
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

  /// Adopts a NEWER synced `notificationLastReadTime` (app.js:5791-5811):
  /// persist the watermark, then retro-mark every unviewed entry observed
  /// at/under it viewed (remembering its seen-key so the read state
  /// propagates onward). Idempotent — an older/equal value is a no-op and
  /// never republishes.
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
      // The PWA remembers WITHOUT republishing (`_rememberNotificationSeen(n,
      // false)`, app.js:5801) — inbound merges never fire onSeenChanged.
      if (_rememberSeen(e)) seenGrew = true;
    }
    if (seenGrew) _persistSeenKeys();
    if (retro) {
      final entries = List.of(state.entries);
      state = state.copyWith(entries: entries, unread: _countUnread(entries));
      _persist();
    } else {
      // The watermark alone can change the badge (`observedAt <= lastRead`
      // is a count-time exclusion, notifications.js:419).
      final unread = _countUnread(state.entries);
      if (unread != state.unread) state = state.copyWith(unread: unread);
    }
  }

  /// Merges a `notificationHistory` array synced from another device — the
  /// PWA's cross-device notification sync (app.js:5814-5894). Matching is by
  /// eventId when available, else (senderPubkey, body, ~minute timestamp), so
  /// duplicates across devices collapse into one entry:
  ///
  ///  * a match adopts the synced `viewed` flag (never un-views) + a missing
  ///    eventId, and remembers the seen-key of a viewed entry;
  ///  * a new entry is skipped for blocked senders and for a `missed-call-…`
  ///    id whose call [isCallAnswered] reports answered (the answered status
  ///    is the tombstone); otherwise it lands with its original `receivedAt`
  ///    and computes `viewed` from the synced flag, the last-read watermark,
  ///    and the seen-map — so synced notifications keep their unread status.
  ///
  /// Idempotent; returns true when anything changed. Inbound merges never
  /// fire [onSeenChanged].
  bool mergeHistory(
    List<dynamic> incoming, {
    bool Function(String callId)? isCallAnswered,
  }) {
    if (incoming.isEmpty) return false;
    if (_hydrating) {
      _pendingRecords.add(() =>
          mergeHistory(incoming, isCallAnswered: isCallAnswered));
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
      final n = NotificationEntry.fromJson(raw);
      if (n == null || n.ts <= cutoff) continue;
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
      // Don't re-add a missed-call entry for a call answered here or elsewhere
      // (app.js:5860-5862).
      final evId = n.eventId ?? '';
      if (evId.startsWith('missed-call-') &&
          (isCallAnswered?.call(evId.substring(12)) ?? false)) {
        continue;
      }
      // `receivedAt` already fell back to `timestamp` in fromJson (the PWA's
      // `observedAt` for legacy entries, app.js:5866).
      if (!n.viewed &&
          (n.receivedAt <= _lastReadTimeMs || _isSeen(n))) {
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

  /// Serializes the bell history for the outbound `nymchat-notifications`
  /// wrap — the PWA's `_serialiseNotificationsForSync` (settings.js:69-88):
  /// entries within the 24h window, newest 100, oldest-first (the PWA's array
  /// order), bodies clipped to 240 chars, `viewed` always present.
  List<Map<String, dynamic>> historyForSync() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - _maxAgeMs;
    final recent =
        state.entries.where((e) => e.ts > cutoff).take(100).toList();
    return [
      for (final e in recent.reversed)
        {
          ...e.toJson(),
          'body': e.body.length > 240 ? e.body.substring(0, 240) : e.body,
          'viewed': e.viewed,
        },
    ];
  }

  /// The entries the loud alert path's replay/dedup guard should scan: the
  /// live history PLUS anything buffered during the async hydration window —
  /// without the buffered half, multi-relay duplicates of one live event
  /// landing at boot each see an "empty" history and double-popup.
  List<NotificationEntry> get entriesForAlertDedup => _hydrating
      ? [...state.entries, ..._pendingEntries]
      : state.entries;

  /// Removes the history entry carrying [eventId] and re-derives the badge — the
  /// PWA's `_retractMissedCallNotification` (calls.js:282, removes the entry
  /// whose `eventId === 'missed-call-'+callId`). Used by the cross-device
  /// seen-call merge (F06-A3): a call answered on another device retracts the
  /// phantom "Missed call" surfaced here. No-op when no entry matches.
  void removeByEventId(String eventId) {
    if (eventId.isEmpty) return;
    // Boot race: a retraction landing before hydration would no-op against
    // the empty state and the phantom entry would then be restored from the
    // persisted blob — defer it past the load.
    if (_hydrating) {
      _pendingRecords.add(() => removeByEventId(eventId));
      return;
    }
    final kept =
        state.entries.where((e) => e.eventId != eventId).toList();
    if (kept.length == state.entries.length) return;
    state = NotificationHistoryState(
      entries: kept,
      unread: _countUnread(kept),
    );
    _persist();
  }

  /// Clears the history entirely. Also wipes the cross-device seen-keys map
  /// (N26) so a panic / clear-data leaves no read-state behind, matching the PWA
  /// (`nym_notification_seen` is in the clear-data list, settings_helpers.dart).
  void clear() {
    _pendingRecords.clear(); // Drop boot-buffered records too (signOut/panic).
    _pendingEntries.clear();
    _seenKeys = <String, int>{};
    _prefs?.remove(_seenKeysStoreKey);
    // The last-read watermark is identity-scoped read state — drop it too
    // (`nym_notification_last_read` is in the PWA clear-data list, app.js:4071).
    _lastReadTimeMs = 0;
    _prefs?.remove(_lastReadStoreKey);
    state = const NotificationHistoryState();
    _persist(); // N3: clear the stored blob too.
  }
}

/// The notification history store. The shell reads `.unread` for the bell badge;
/// the notifications modal reads `.entries`. Feed it via
/// `ref.read(notificationHistoryProvider.notifier).record(...)`.
final notificationHistoryProvider = StateNotifierProvider<
    NotificationHistoryNotifier, NotificationHistoryState>(
  (ref) => NotificationHistoryNotifier(ref),
);

// =============================================================================
// Live custom emoji (NIP-30). The PWA discovers custom emoji from three sources
// (emoji.js): kind-30030 emoji packs, the user's kind-10030 emoji-pack list, and
// loose `['emoji', shortcode, url]` tags on any incoming event. This notifier is
// the live, mutable store the [NostrController] feeds as those events arrive; it
// hydrates from + persists to the same `nym_custom_emojis` / `nym_custom_emoji_packs`
// SharedPreferences keys the PWA uses, so the cache survives reloads.
//
// The picker reads [customEmojiStateProvider] (a default-empty `Provider`). This
// notifier exposes the SAME [CustomEmojiState] shape via [liveCustomEmojiProvider]
// so the emoji UI can read live updates (CROSS-FILE: the picker/composer should
// watch this provider, or override `customEmojiStateProvider` from it, to surface
// relay-sourced packs/codes — they currently load only the static cache).
// =============================================================================

final RegExp _kEmojiShortcodeRx = RegExp(r'^[a-zA-Z0-9_]+$');
final RegExp _kEmojiUrlRx = RegExp(r'^https?://', caseSensitive: false);

class LiveCustomEmojiNotifier extends StateNotifier<CustomEmojiState> {
  LiveCustomEmojiNotifier(this._ref) : super(CustomEmojiState.empty) {
    _hydrate();
  }

  final Ref _ref;
  SharedPreferences? _prefs;

  /// Loose shortcode → url (mirrors `customEmojis`). Mutable working copy; the
  /// published [state] is rebuilt from this + [_packsByKey] on each change.
  final Map<String, String> _codeToUrl = {};

  /// Pack key (`pubkey:identifier`) → pack (mirrors `customEmojiPacks`).
  final Map<String, CustomEmojiPack> _packsByKey = {};

  /// `30030:<pubkey>:<identifier>` refs the user subscribes to (kind-10030
  /// `userEmojiPackRefs`). Newest list wins (guarded by [_userListTs]).
  final Set<String> _userPackRefs = {};
  int _userListTs = 0;

  /// Hydrates from the persisted PWA cache so previously-seen emoji render
  /// immediately on launch (emoji.js `_loadCustomEmojiCache`).
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
        // Warm the images the user is likely to see first (the PWA's cache
        // load routes through `_storeEmojiPack`, which schedules
        // `_prefetchCustomEmojiImages`).
        _schedulePrefetch();
      }
    } catch (_) {
      // Cache is best-effort; an unavailable store just yields live-only emoji.
    }
  }

  /// Schedules the debounced custom-emoji image prefetch (emoji.js
  /// `_prefetchCustomEmojiImages`: 3s + idle, skipped in low-data mode, 60-URL
  /// budget — all implemented in `emoji_prefetch.dart`). Best-effort.
  void _schedulePrefetch() {
    try {
      scheduleCustomEmojiPrefetch(_ref.container);
    } catch (_) {
      // Prefetch is a warm-up only; never let it break registration.
    }
  }

  /// Registers a loose custom emoji (emoji.js `registerCustomEmoji`): valid
  /// shortcode + http(s) url, never shadowing a built-in unicode shortcode.
  /// Returns true if it was newly added or changed.
  bool registerEmoji(String? shortcode, String? url) {
    if (shortcode == null || url == null) return false;
    if (!_kEmojiShortcodeRx.hasMatch(shortcode) || !_kEmojiUrlRx.hasMatch(url)) {
      return false;
    }
    if (kEmojiShortcodeMap.containsKey(shortcode.toLowerCase())) return false;
    if (_codeToUrl[shortcode] == url) return false;
    _codeToUrl[shortcode] = url;
    // Cap the loose map like the PWA (`_saveCustomEmojiMap` keeps the last 5000).
    if (_codeToUrl.length > 5000) {
      final keys = _codeToUrl.keys.toList();
      for (final k in keys.sublist(0, _codeToUrl.length - 5000)) {
        _codeToUrl.remove(k);
      }
    }
    _publish();
    _persist();
    // The PWA's `registerCustomEmoji` schedules the image warm-up
    // (emoji.js:128 `_prefetchCustomEmojiImages`).
    _schedulePrefetch();
    return true;
  }

  /// Ingests `['emoji', shortcode, url]` tags from any inbound event
  /// (emoji.js `ingestEmojiTags`).
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
      // The PWA's `ingestEmojiTags` routes through `registerCustomEmoji`,
      // which schedules the warm-up (emoji.js:128).
      _schedulePrefetch();
    }
  }

  /// Like [registerEmoji] but defers the publish/persist (used by batch ingest).
  bool registerEmojiQuiet(String? shortcode, String? url) {
    if (shortcode == null || url == null) return false;
    if (!_kEmojiShortcodeRx.hasMatch(shortcode) || !_kEmojiUrlRx.hasMatch(url)) {
      return false;
    }
    if (kEmojiShortcodeMap.containsKey(shortcode.toLowerCase())) return false;
    if (_codeToUrl[shortcode] == url) return false;
    _codeToUrl[shortcode] = url;
    return true;
  }

  /// Stores a kind-30030 emoji pack (emoji.js `_storeEmojiPack` /
  /// `handleEmojiPackEvent`): newest `created_at` wins per `pubkey:identifier`
  /// key, each pack emoji is registered into the loose map. Persists.
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
    // `_storeEmojiPack` schedules the image warm-up (emoji.js:243).
    _schedulePrefetch();
  }

  /// Records the user's kind-10030 emoji-pack subscription list (emoji.js
  /// `handleUserEmojiListEvent`): newest event wins; any inline `emoji` tags are
  /// also registered. [refs] are the `30030:<pubkey>:<identifier>` `a`-tag values.
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

  /// Whether [pack] is one the user subscribed to via their kind-10030 list.
  bool isPackSubscribed(CustomEmojiPack pack) =>
      _userPackRefs.contains('30030:${pack.pubkey}:${pack.identifier}');

  /// NIP-30 `['emoji', shortcode, url]` tags for every known custom shortcode
  /// used in [content] (emoji.js `customEmojiTagsForContent`). Lets an outgoing
  /// message declare its custom emoji so other clients render them. Empty when no
  /// known shortcodes appear.
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

  /// Clears all live + persisted custom emoji (sign-out).
  void clearAll() {
    // Cancel a pending debounced write so it can't re-persist what we wipe.
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

  /// Rebuilds the published immutable snapshot (newest packs first).
  void _publish() {
    if (!mounted) return;
    final packs = _packsByKey.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    state = CustomEmojiState(
      codeToUrl: Map.unmodifiable(_codeToUrl),
      packs: List.unmodifiable(packs),
    );
  }

  /// Pending debounced-persist timer (the PWA's `_emojiCacheSaveTimer` /
  /// `_emojiMapSaveTimer`).
  Timer? _persistTimer;

  /// Schedules a debounced persist (emoji.js `_saveCustomEmojiCache` /
  /// `_saveCustomEmojiMap`: a 2s timer + idle callback), so a burst of pack
  /// events / the D1 emoji-get replay re-encodes the full ≤5000-entry map +
  /// ≤200-pack JSON ONCE instead of per registration. (SharedPreferences has
  /// no localStorage quota, so the PWA's QuotaExceeded trim fallback has no
  /// native counterpart.)
  void _persist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 2), () {
      _persistTimer = null;
      _persistNow();
    });
  }

  @override
  void dispose() {
    // Flush a pending debounced write so a teardown never loses registrations.
    if (_persistTimer != null) {
      _persistTimer!.cancel();
      _persistTimer = null;
      _persistNow();
    }
    super.dispose();
  }

  /// Persists both caches in the PWA's localStorage shape (`_saveCustomEmojiMap`
  /// + `_saveCustomEmojiCache`): the loose map as `[[shortcode,url],…]` (≤5000)
  /// and packs as objects sorted newest-first (≤200). Best-effort.
  void _persistNow() {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final mapEntries = _codeToUrl.entries
          .map((e) => [e.key, e.value])
          .toList();
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
      // Quota or serialization failures are non-fatal; live state still works.
    }
  }
}

/// The live custom-emoji store, fed by the [NostrController]'s NIP-30
/// subscription (kinds 10030 + 30030) and inbound `emoji` tags. Read the
/// [CustomEmojiState] directly for the shortcode→url map + loaded packs.
final liveCustomEmojiProvider =
    StateNotifierProvider<LiveCustomEmojiNotifier, CustomEmojiState>(
  (ref) => LiveCustomEmojiNotifier(ref),
);

import 'event_kinds.dart';

/// Relay configuration ported from the PWA (docs/specs/01 §4).
class RelayConfig {
  RelayConfig._();

  /// The Nymchat app relay (always reconnected, never blacklisted).
  static const String appRelay = 'wss://relay.nymchat.app';

  /// Default relays, always connected first.
  static const List<String> defaultRelays = [
    'wss://sendit.nosflare.com', // also the write-only publish relay
    'wss://relay.nymchat.app',
    'wss://relay.damus.io',
    'wss://offchain.pub',
    'wss://relay.primal.net',
    'wss://nos.lol',
    'wss://nostr21.com',
    'wss://relay.coinos.io',
    'wss://relay.snort.social',
    'wss://relay.nostr.net',
    'wss://nostr-pub.wellorder.net',
    'wss://relay1.nostrchat.io',
    'wss://nostr-01.yakihonne.com',
    'wss://nostr-02.yakihonne.com',
    'wss://relay.0xchat.com',
    'wss://relay.satlantis.io',
    'wss://relay.fountain.fm',
    'wss://nostr.mom',
  ];

  static const String appRelayOnlyChannel = 'nymchat';

  /// Every kind that names a channel and surfaces inside it: the message
  /// itself, plus the reactions, polls, typing strips and read receipts that
  /// hang off it. Gating only the messages would leave four other ways to put
  /// a nym and a payload in front of everyone in the default channel.
  static const Set<int> appRelayOnlyKinds = {
    EventKind.namedChannel,
    EventKind.reaction,
    EventKind.appData,
    EventKind.channelTyping,
    EventKind.channelReceipt,
  };

  /// Whether an event naming [gTag]/[dTag] is one only the app relay may
  /// deliver. Channel derivation matches the worker's `channelFromTags`: a
  /// named-channel message carries 'd', and the hangers-on may carry either.
  static bool isAppRelayOnly(int kind, String? gTag, String? dTag) {
    if (!appRelayOnlyKinds.contains(kind)) return false;
    final name = kind == EventKind.namedChannel ? dTag : (gTag ?? dTag);
    return name != null && name.toLowerCase() == appRelayOnlyChannel;
  }

  /// Relays we only publish to (never REQ from).
  static const Set<String> writeOnlyRelays = {'wss://sendit.nosflare.com'};

  /// NIP-46 default signer relay.
  static const String nip46Relay = 'wss://relay.primal.net';

  /// Tuning.
  static const int relaysPerWorker = 50;
  static const int maxRelaysForReq = 1000;
  static const int relayTimeoutMs = 2000;
  static const int blacklistDurationMs = 120000;
  static const int relayRetryDelayMs = 120000;
  static const int geoRelayCount = 5;
}

/// STUN/TURN servers used for WebRTC (calls + P2P). docs/specs/01 §3.3.
class IceServers {
  IceServers._();

  static const List<Map<String, dynamic>> servers = [
    {'urls': 'stun:rtc.0xchat.com:5349'},
    {
      'urls': 'turn:rtc.0xchat.com:5349',
      'username': '0xchat',
      'credential': 'Prettyvs511',
    },
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {'urls': 'stun:stun2.l.google.com:19302'},
    {'urls': 'stun:stun.cloudflare.com:3478'},
  ];
}

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/event_kinds.dart';
import '../../core/constants/relays.dart';
import '../../core/crypto/bitchat.dart' as bitchat;
import '../../core/crypto/crypto_worker.dart';
import '../../core/crypto/gift_wrap.dart' as giftwrap;
import '../../core/crypto/isolate_verifier.dart';
import '../../core/crypto/keys.dart' as keys;
import '../../core/crypto/nym_sync_builder.dart';
import '../../core/crypto/pow.dart';
import '../../core/crypto/pq.dart' as pq;
import '../../features/calls/call_signaling.dart';
import '../../features/groups/wrap_outbox.dart';
import '../../features/identity/pq_registry.dart';
import '../../features/messages/server_quiet.dart';
import '../../features/messages/trust_graph.dart';
import '../../features/pms/upload_activity.dart';
import '../../features/relays/relay_block.dart';
import '../../models/channel.dart' as ch;
import '../../models/nostr_event.dart';
import '../api/api_client.dart';
import '../api/api_config.dart';
import '../relay/dm_outbox.dart';
import '../relay/queued_sends.dart';
import '../relay/relay_message.dart';
import 'event_provenance.dart';
import '../relay/relay_pool.dart';
import '../relay/relay_pool_proxy.dart';
import '../relay/relay_stats.dart';
import 'event_mapper.dart';
import 'event_signer.dart';
import 'identity_service.dart';

/// Parses the bitchat geo-relay CSV (`host,lat,lng`), stripping scheme and slashes and skipping bad rows.
List<GeoRelay> parseGeoRelaysCsv(String csv) {
  final out = <GeoRelay>[];
  final lines = csv.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    if (i == 0 && line.toLowerCase().contains('relay url')) continue;
    final parts = line.split(',');
    if (parts.length < 3) continue;
    var host = parts[0].trim();
    host = host
        .replaceFirst('https://', '')
        .replaceFirst('http://', '')
        .replaceFirst('wss://', '')
        .replaceFirst('ws://', '')
        .replaceAll(RegExp(r'/+$'), '');
    final lat = double.tryParse(parts[1].trim());
    final lng = double.tryParse(parts[2].trim());
    if (host.isEmpty || lat == null || lng == null) continue;
    out.add(GeoRelay(url: 'wss://$host', lat: lat, lng: lng));
  }
  return out;
}

/// A decrypted gift wrap handed to the controller for routing.
class GiftWrapUnwrapped {
  GiftWrapUnwrapped({
    required this.wrapId,
    required this.wrapCreatedAt,
    required this.rumor,
    required this.senderVerified,
    required this.isBitchat,
    this.isPq = false,
    this.rawWrap,
    this.fromArchive = false,
  });

  /// Arrived over the hybrid PQ transport; confidentiality, orthogonal to [senderVerified].
  final bool isPq;

  /// Replayed from the D1 archive rather than live, so it is never re-uploaded.
  final bool fromArchive;

  /// The kind-1059 wrap id, used as the message id.
  final String wrapId;
  final int wrapCreatedAt;

  /// The untouched signed wrap, needed for the D1 archive; null on the remote-signer path.
  final Map<String, dynamic>? rawWrap;

  /// The decrypted inner rumor (kind 14 / 69420 / 7 …).
  final Map<String, dynamic> rumor;

  /// True when the NIP-59 seal authenticated the rumor author; bitchat wraps are unverified.
  final bool senderVerified;
  final bool isBitchat;

  int? get rumorKind => (rumor['kind'] as num?)?.toInt();

  String? get recipient {
    final tags = rawWrap?['tags'];
    if (tags is! List) return null;
    for (final t in tags) {
      if (t is List && t.length > 1 && t[0] == 'p' && t[1] is String) {
        return t[1] as String;
      }
    }
    return null;
  }

  int? get expiration {
    final tags = rawWrap?['tags'];
    if (tags is! List) return null;
    for (final t in tags) {
      if (t is List &&
          t.length > 1 &&
          t[0] == 'expiration' &&
          RegExp(r'^\d{1,12}$').hasMatch('${t[1]}')) {
        return int.parse('${t[1]}');
      }
    }
    return null;
  }
}

/// Messaging settings passed in so the service never imports the settings provider.
class MessagingSettings {
  const MessagingSettings({
    this.dmForwardSecrecyEnabled = false,
    this.dmTtlSeconds = 0,
  });

  final bool dmForwardSecrecyEnabled;
  final int dmTtlSeconds;

  /// Gift-wrap `expiration` (now + ttl) when forward secrecy is on, else null.
  int? expirationFor(int nowSec) =>
      (dmForwardSecrecyEnabled && dmTtlSeconds > 0)
          ? nowSec + dmTtlSeconds
          : null;
}

/// Status visibility derived from `nym_show_status`, as the PWA's `_statusMode`.
enum PresenceStatusMode {
  /// Broadcast the real status publicly.
  enabled,

  /// Broadcast `hidden` publicly and share the real status privately with friends.
  friends,

  /// Never assert presence; broadcasts `hidden`.
  disabled,
}

PresenceStatusMode presenceStatusModeFrom(String showStatus) {
  if (showStatus == 'false') return PresenceStatusMode.disabled;
  if (showStatus == 'friends') return PresenceStatusMode.friends;
  return PresenceStatusMode.enabled;
}

/// Pure builder for kind-30078 nym-presence tags, sharing the PWA's replaceable `d`/`t` identity.
class PresencePayload {
  const PresencePayload({
    required this.nym,
    required this.status,
    this.awayMessage = '',
    this.mode = PresenceStatusMode.enabled,
    this.avatarUrl,
    this.shopUpdate = false,
  });

  final String nym;
  final String status; // The real status: 'online' | 'away' | 'hidden'.
  final String awayMessage;
  final PresenceStatusMode mode;
  final String? avatarUrl;

  /// Emits only the `['shop-update','1']` cache-bust flag; cosmetics never ride presence.
  final bool shopUpdate;

  /// Real status only in `enabled` mode, otherwise `hidden`.
  String get publicStatus =>
      mode == PresenceStatusMode.enabled ? status : 'hidden';

  List<List<String>> tags() {
    final out = <List<String>>[
      ['d', AppDataTopic.presence],
      ['t', AppDataTopic.presence],
      ['n', nym],
      ['status', publicStatus],
    ];
    // Away message only when fully enabled and actually away.
    if (mode == PresenceStatusMode.enabled &&
        status == 'away' &&
        awayMessage.isNotEmpty) {
      out.add(['away', awayMessage]);
    }
    if (avatarUrl != null) {
      out.add(['avatar-update', avatarUrl!]);
    }
    if (shopUpdate) {
      out.add(['shop-update', '1']);
    }
    return out;
  }
}

class NostrHandlers {
  NostrHandlers({
    this.onEvent,
    this.onConnectionChanged,
    this.onGiftWrap,
    this.onEventRetracted,
    this.onShardLost,
    this.onShardReconnected,
  });

  /// Every inbound event, already signature-checked by the pool.
  final void Function(NostrEvent event)? onEvent;
  final void Function(int connectedCount)? onConnectionChanged;

  final void Function(GiftWrapUnwrapped unwrapped)? onGiftWrap;

  final void Function(String eventId)? onEventRetracted;

  final void Function(int lastLiveAtMs)? onShardLost;

  final void Function()? onShardReconnected;
}

/// Owns the relay pool and wires it to the crypto and identity layers.
class NostrService {
  /// Process-wide verifier shared by every transport, so bursts coalesce into one isolate hop.
  static final IsolateVerifier _verifier = IsolateVerifier();

  /// Process-wide gift-wrap worker shared so unwrap and wrap bursts coalesce.
  static final CryptoWorker _cryptoWorker = CryptoWorker.instance;

  /// Our ML-KEM keypair from the controller, to strip the layered outer layer before a signer; null without a root.
  ({Uint8List kemSk, Uint8List kemPk})? Function()? selfKemForUnwrap;

  /// A peer's ML-KEM key, only when they accept the layered format.
  Uint8List? Function(String realPubkey)? pqPeerKey;

  /// Our own ML-KEM key for self-addressed copies.
  Uint8List? Function()? pqSelfKey;

  /// Whether self-addressed copies may use the layered format.
  bool Function()? pqSelfLayered;

  ({Uint8List? kem, bool layered}) _pqTarget(String realPubkey) {
    if (realPubkey == identity.pubkey) {
      final kem = pqSelfKey?.call();
      return (kem: kem, layered: kem != null && (pqSelfLayered?.call() ?? false));
    }
    final kem = pqPeerKey?.call(realPubkey);
    return (kem: kem, layered: kem != null);
  }

  /// Wrap ids already unwrapped this process, so D1 replays skip the costly unwrap; bounded, oldest-first.
  static final LinkedHashSet<String> _processedWrapIds =
      LinkedHashSet<String>();
  static const int _processedWrapCap = 100000;

  /// Caps concurrent NIP-46 decrypt round-trips so backfill doesn't flood the single signer socket.
  final _AsyncSemaphore _remoteUnwrapGate = _AsyncSemaphore(3);

  /// Seeds already-verified ids, e.g. from the local cache, so replays skip re-verification.
  static void seedVerifiedIds(Iterable<String> ids) =>
      _verifier.markVerified(ids);

  /// Newest verified ids for persisting across launches.
  static List<String> snapshotVerifiedIds({int max = 20000}) =>
      _verifier.snapshotVerifiedIds(max: max);

  /// Called when a signature newly verifies, for a debounced persist.
  static set onVerifiedIdsChanged(void Function()? cb) =>
      _verifier.onNewVerified = cb;

  /// Seeds wrap ids already unwrapped (cached PM ids are wrap ids) so restores skip them.
  static void seedProcessedWraps(Iterable<String> wrapIds) {
    for (final id in wrapIds) {
      if (id.isEmpty) continue;
      _processedWrapIds.remove(id);
      _processedWrapIds.add(id);
    }
    _evictProcessedWraps();
  }

  static List<String> recentProcessedWraps(int max) {
    final all = _processedWrapIds.toList();
    return all.length > max ? all.sublist(all.length - max) : all;
  }

  static void forgetProcessedWraps() => _processedWrapIds.clear();

  static void _rememberProcessedWrap(String id) {
    if (id.isEmpty) return;
    _processedWrapIds.remove(id);
    _processedWrapIds.add(id);
    _evictProcessedWraps();
  }

  static void _evictProcessedWraps() {
    while (_processedWrapIds.length > _processedWrapCap) {
      _processedWrapIds.remove(_processedWrapIds.first);
    }
  }

  /// Pool [EventVerifier]: batched off-main verification with per-event verdicts.
  static Future<bool> _verifyOffThread(NostrEvent event) =>
      _verifier.verify(event);

  /// Batched off-main verification for D1 archive replays; fails closed.
  Future<bool> verifyEvent(NostrEvent event) => _verifier.verify(event);

  /// [useProxy] picks the relay-pool proxy (default) or direct [RelayPool]; an explicit [pool] overrides.
  NostrService({
    required this.identity,
    EventSigner? signer,
    List<String>? relays,
    PoolTransport? pool,
    bool useProxy = true,
    bool userDirect = false,
    ApiClient? apiClient,
    RelayPool Function()? directPoolFactory,
    RelayPoolProxy Function()? proxyPoolFactory,
  })  : _apiClient = apiClient ?? ApiClient(),
        _relays = relays,
        _autoFallback = (pool == null && useProxy) ||
            (directPoolFactory != null && proxyPoolFactory != null),
        _userDirect = userDirect,
        _directPoolFactory = directPoolFactory,
        _proxyPoolFactory = proxyPoolFactory,
        signer = signer ??
            (identity.privkey != null ? LocalSigner(identity.privkey!) : null),
        _pool = pool ??
            (useProxy && !userDirect
                ? RelayPoolProxy(
                    relays: relays ?? RelayConfig.defaultRelays,
                    dmRelays: RelayConfig.defaultRelays,
                    verify: _verifyOffThread,
                  )
                : RelayPool(
                    relays: relays ?? RelayConfig.defaultRelays,
                    writeOnlyRelays: RelayConfig.writeOnlyRelays,
                    verify: _verifyOffThread,
                  )) {
    // Route process-wide /api traffic into our stats in production only, keeping tests isolated.
    if (pool == null && useProxy) {
      ApiClient.apiStatsSink = _apiStats;
    }
    // Set here so a pool swapped in by fallback carries the geo gate too.
    _pool.geoOriginAllows = geoOriginAllowsEvent;
  }

  /// Persistent /api counters kept on the service so they survive a pool swap.
  final RelayStats _apiStats = RelayStats();

  /// Forces the direct-WebSocket transport, used when the relay pool fails.
  factory NostrService.direct({
    required Identity identity,
    EventSigner? signer,
    List<String>? relays,
    ApiClient? apiClient,
  }) =>
      NostrService(
        identity: identity,
        signer: signer,
        relays: relays,
        useProxy: false,
        apiClient: apiClient,
      );

  /// Mutable so hardcore mode can swap the key in place; publishes read it at call time.
  Identity identity;

  /// Active signer (local, NIP-46 or null) that every publish and wrap path routes through; mutable for rotation.
  EventSigner? signer;

  /// Attestation badge for outgoing channel messages; null until enrolled, and messages still send without it.
  String? attestBadge;

  /// Swaps the signing identity in place for hardcore mode without reconnecting or re-subscribing, as the PWA does.
  void rotateIdentity(Identity newIdentity, EventSigner? newSigner) {
    _candidateGen++;
    identity = newIdentity;
    signer = newSigner;
  }

  /// The active transport, swapped to direct if the proxy is unreachable and back on recovery.
  PoolTransport _pool;

  /// Relay set from construction (null = defaults), reused for fallback and restore pools.
  final List<String>? _relays;

  /// True only on the production proxy path: enables auto-fallback and background restore.
  final bool _autoFallback;

  final RelayPool Function()? _directPoolFactory;

  final RelayPoolProxy Function()? _proxyPoolFactory;

  bool _userDirect;

  bool _stopped = false;

  bool get isUserDirect => _userDirect;

  bool get canSwitchTransport => _autoFallback;

  bool get isProxyRetryInFlight => _bgRestoreInFlight;

  RelayPool _newDirectPool() => (_directPoolFactory?.call() ??
      RelayPool(
        relays: _relays ?? RelayConfig.defaultRelays,
        writeOnlyRelays: RelayConfig.writeOnlyRelays,
        verify: _verifyOffThread,
      ))
    ..setBlockedRelays(_blockedRelays);

  RelayPoolProxy _newProxyPool() => (_proxyPoolFactory?.call() ??
      RelayPoolProxy(
        relays: _relays ?? RelayConfig.defaultRelays,
        dmRelays: RelayConfig.defaultRelays,
        verify: _verifyOffThread,
      ))
    ..setBlockedRelays(_blockedRelays);

  Set<String> _blockedRelays = const {};

  Set<String> get blockedRelays => _blockedRelays;

  void setBlockedRelays(Iterable<String> urls) {
    _blockedRelays = Set.unmodifiable(urls.toSet());
    final p = _pool;
    if (p is RelayPoolProxy) {
      p.setBlockedRelays(_blockedRelays);
    } else if (p is RelayPool) {
      p.setBlockedRelays(_blockedRelays);
    }
  }

  final ApiClient _apiClient;

  /// The current pool after any swap.
  PoolTransport get pool => _quietHeld ? _QuietPool(_pool) : _pool;

  late final DmOutbox _dmOutbox = DmOutbox(send: _sendDm);

  Future<int> _sendDm(NostrEvent e) async {
    final via = pool;
    final n = await via.publishDm(e);
    if (n > 0) QueuedSends.instance.release(e.id);
    if (n > 0 && _pool is! RelayPoolProxy) _dmOutbox.confirm(e.id);
    return n;
  }

  final LinkedHashMap<String, int> _sentTiers = LinkedHashMap();

  int get pendingDmCount => _dmOutbox.length;

  int get unsentDmCount => _dmOutbox.unsentCount;

  List<UnsentEvent> unsentEvents() {
    final out = <UnsentEvent>[];
    final seen = <String>{};
    for (final (e, tier) in _dmOutbox.unsent()) {
      if (seen.add(e.id)) out.add(UnsentEvent(e, tier: tier, dm: true));
    }
    final p = _pool;
    final held = p is RelayPoolProxy
        ? p.heldEvents
        : (p is RelayPool ? p.heldEvents : const <NostrEvent>[]);
    for (final e in held) {
      if (seen.add(e.id)) {
        out.add(UnsentEvent(e, tier: WrapTier.critical, dm: e.kind == 1059));
      }
    }
    return out;
  }

  int sentWrapTier(String wrapId) => _sentTiers[wrapId] ?? WrapTier.critical;

  void publishDmQueued(NostrEvent event, {int tier = WrapTier.critical}) {
    _sentTiers.remove(event.id);
    _sentTiers[event.id] = tier;
    while (_sentTiers.length > 4000) {
      _sentTiers.remove(_sentTiers.keys.first);
    }
    _dmOutbox.push(event, tier: tier);
  }

  static int rumorTier(UnsignedEvent rumor, int fanout, {bool toNew = false}) {
    String? type;
    var resyncReq = false;
    for (final t in rumor.tags) {
      if (t.length < 2) continue;
      if (t[0] == 'type' && type == null) type = t[1];
      if (t[0] == 'resync_req' && t[1] == '1') resyncReq = true;
    }
    return wrapTier(
        kind: rumor.kind,
        type: type,
        resyncReq: resyncReq,
        fanout: fanout,
        toNew: toNew);
  }

  void _wireOutbox(PoolTransport p) {
    if (p is RelayPoolProxy) {
      p.onPublishCharge = _dmOutbox.charge;
      p.onPublishRateLimited = (id) => _dmOutbox.refused(id);
      p.onPublishAccepted = _dmOutbox.confirm;
    }
  }

  Set<String> _quiet = const <String>{};
  bool _quietHeld = false;
  Timer? _quietTimer;

  void _loadQuietList() {
    Future<void> load() async {
      try {
        final d = await _apiClient.storageAction({'action': 'filter-get'});
        final next = <String>{};
        for (final k in const ['p', 'e']) {
          final v = d[k];
          if (v is List) next.addAll(v.whereType<String>());
        }
        _quiet = next;
        ServerQuiet.keys = next;
        _quietHeld = next.contains(identity.pubkey);
      } catch (_) {}
    }

    unawaited(load());
    _quietTimer ??= Timer.periodic(const Duration(minutes: 10), (_) => load());
  }

  /// Fresh relay stats with the persistent /api counters folded in.
  RelayStats get relayStats {
    final s = _pool.stats; // Already a snapshot.
    final api = _apiStats;
    if (!api.hasApiData) return s;
    // Pool byte totals exclude API traffic, so add it.
    s.bytesReceived += api.apiBytesReceived;
    s.bytesSent += api.apiBytesSent;
    s.apiBytesReceived += api.apiBytesReceived;
    s.apiBytesSent += api.apiBytesSent;
    api.apiActionStats.forEach((action, st) {
      s.apiActionStats[action] = st.copy();
    });
    return s;
  }

  /// True when the current transport is the proxy pool.
  bool get isProxyMode => _pool is RelayPoolProxy;

  /// True while running on the direct fallback.
  bool _poolFallbackActive = false;
  bool get isFallbackActive => _poolFallbackActive;

  /// Timer and attempt counter for restoring proxy mode after a fallback.
  Timer? _bgRestoreTimer;
  int _bgRestoreAttempts = 0;
  bool _bgRestoreInFlight = false;

  /// Guards [_swapPool] against overlapping swaps.
  bool _swapping = false;

  Subscription? _mainSub;
  StreamSubscription<NostrEvent>? _eventSub;
  Timer? _statusTimer;
  NostrHandlers? _handlers;

  /// Connects and issues the main critical REQ; [channelMode] false omits public-channel filters.
  Future<void> start(
    NostrHandlers handlers, {
    bool channelMode = true,
    Iterable<String> vouchAuthors = const [],
    Iterable<String> profileAuthors = const [],
    Iterable<String> pqAuthors = const [],
  }) async {
    _handlers = handlers;
    _channelMode = channelMode;
    _vouchAuthors = _sanitizeVouchAuthors(vouchAuthors);
    _profileAuthors = List<String>.unmodifiable(profileAuthors);
    _pqAuthors = _sanitizeVouchAuthors(pqAuthors);
    _wireProxyFallback();
    _wireRetract(_pool);
    _wireLiveness(_pool);
    _wireOutbox(_pool);
    _loadQuietList();
    pool.connectAll();

    _mainSub = pool.subscribe(_buildCriticalFilters());
    _eventSub = _mainSub!.events.listen(_routeMain);

    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      handlers.onConnectionChanged?.call(pool.connectedCount);
    });
    handlers.onConnectionChanged?.call(pool.connectedCount);

    // Load and shard geo relays in the background, or geohash subscriptions are never delivered.
    unawaited(loadAndApplyGeoRelays().catchError((_) {}));
  }

  // Critical REQ filter set

  /// Gates every public-channel filter out of the critical set.
  bool _channelMode = true;

  /// PQ key announcement authors, scoped to peers we actually message plus ourselves.
  List<String> _pqAuthors = const [];

  /// Direct-mode vouch authors, hex-filtered and capped at [_vouchAuthorCap].
  List<String> _vouchAuthors = const [];

  /// Direct-mode kind-0 authors (PM contacts; self is appended).
  List<String> _profileAuthors = const [];

  /// Whether D1 backs history: natively, when the relay-pool proxy is the active transport.
  bool get _d1Available => ApiConfig.apiHost.isNotEmpty && isProxyMode;

  /// Port of the PWA's `_buildCriticalFilters`: live-only windows under D1, full 24h windows in direct mode.
  List<NostrFilter> _buildCriticalFilters() {
    final filters = <NostrFilter>[];
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final since24h = nowSec - 86400;
    final channelMode = _channelMode;
    final d1Available = _d1Available;
    final chSince = d1Available ? nowSec : since24h;
    int lim(int n) => d1Available ? 1 : n;
    final self = identity.pubkey;
    const channelKindTags = ['20000', '23333'];

    // Gift wraps to us: NIP-59 backdates created_at, so no `since`; limit 1 under D1.
    filters.add(NostrFilter(
      kinds: [EventKind.giftWrap],
      limit: d1Available ? 1 : 500,
      tags: {
        'p': [self],
      },
    ));
    // Channels: real-time `since`, two filters as in the PWA.
    if (channelMode) {
      filters.add(NostrFilter(kinds: [EventKind.geoChannel], since: chSince));
      filters.add(NostrFilter(kinds: [EventKind.namedChannel], since: chSince));
    }
    // Reactions on our channel messages; `#k` keeps out foreign kind-7s that merely p-tag us.
    filters.add(NostrFilter(
      kinds: [EventKind.reaction],
      since: d1Available ? nowSec : null,
      limit: lim(100),
      tags: {
        'p': [self],
        'k': channelKindTags,
      },
    ));
    // All channel reactions, for badge counts.
    if (channelMode) {
      filters.add(NostrFilter(
        kinds: [EventKind.reaction],
        since: chSince,
        limit: lim(100),
        tags: {
          'k': channelKindTags,
        },
      ));
    }
    // Public reactions to gift-wrapped messages.
    filters.add(NostrFilter(
      kinds: [EventKind.reaction],
      since: d1Available ? nowSec : null,
      limit: lim(100),
      tags: {
        'k': ['1059'],
      },
    ));
    // NIP-09 deletions of channel messages and gift wraps.
    if (channelMode) {
      filters.add(NostrFilter(
        kinds: [EventKind.deletion],
        since: d1Available ? nowSec : since24h,
        limit: lim(100),
        tags: {
          'k': ['20000', '23333', '1059'],
        },
      ));
    }
    // NIP-57 zap receipts to us (`#k:[20000,23333,1059,0]`).
    filters.add(NostrFilter(
      kinds: [EventKind.zapReceipt],
      since: chSince,
      limit: lim(200),
      tags: {
        'p': [self],
        'k': ['20000', '23333', '1059', '0'],
      },
    ));
    // Zap receipts on everyone's channel messages.
    if (channelMode) {
      filters.add(NostrFilter(
        kinds: [EventKind.zapReceipt],
        since: chSince,
        limit: lim(100),
        tags: {
          'k': channelKindTags,
        },
      ));
    }
    // Zap receipts on gift-wrapped messages.
    filters.add(NostrFilter(
      kinds: [EventKind.zapReceipt],
      since: chSince,
      limit: lim(100),
      tags: {
        'k': ['1059'],
      },
    ));
    // P2P file-transfer signaling to us, 2-minute window.
    filters.add(NostrFilter(
      kinds: [EventKind.p2pSignaling],
      since: nowSec - 120,
      limit: lim(50),
      tags: {
        'p': [self],
      },
    ));
    // Presence: real-time only under D1.
    filters.add(NostrFilter(
      kinds: [EventKind.appData],
      since: d1Available ? nowSec : null,
      limit: lim(100),
      tags: {
        't': [AppDataTopic.presence],
      },
    ));
    // Channel polls and votes.
    if (channelMode) {
      filters.add(NostrFilter(
        kinds: [EventKind.appData],
        since: chSince,
        limit: lim(100),
        tags: {
          't': [AppDataTopic.poll, AppDataTopic.pollVote],
        },
      ));
    }
    // Web of trust: live-only under D1; direct mode REQs trusted authors' lists.
    if (d1Available) {
      filters.add(NostrFilter(
        kinds: [EventKind.appData],
        since: nowSec,
        limit: 1,
        tags: {
          't': [AppDataTopic.vouches],
        },
      ));
    } else if (_vouchAuthors.isNotEmpty) {
      filters.add(NostrFilter(
        kinds: [EventKind.appData],
        authors: _vouchAuthors,
        limit: _vouchAuthors.length,
        tags: {
          't': [AppDataTopic.vouches],
        },
      ));
    }
    // PQ key announcements: a live tail under D1, since history comes from the archive.
    if (d1Available) {
      filters.add(NostrFilter(
        kinds: [EventKind.appData],
        since: nowSec,
        limit: 1,
        tags: {
          't': [AppDataTopic.postQuantum],
        },
      ));
    } else if (_pqAuthors.isNotEmpty) {
      filters.add(NostrFilter(
        kinds: [EventKind.appData],
        authors: _pqAuthors,
        limit: _pqAuthors.length,
        tags: {
          't': [AppDataTopic.postQuantum],
        },
      ));
    }
    // NIP-30 emoji packs: real-time under D1, else discover up to 300.
    filters.add(NostrFilter(
      kinds: [EventKind.emojiPack],
      since: d1Available ? nowSec : null,
      limit: d1Available ? 1 : 300,
    ));
    // Global P2P seeding status (no `#p`, as the PWA) plus our kind-10030 list.
    filters.add(NostrFilter(
      kinds: [EventKind.p2pFileStatus],
      since: d1Available ? nowSec : since24h,
      limit: lim(100),
    ));
    filters.add(NostrFilter(
      kinds: [EventKind.userEmojiList],
      authors: [self],
      limit: 1,
    ));
    // Kind-0: self only under D1; direct mode watches every PM contact and self.
    if (d1Available) {
      filters.add(NostrFilter(
        kinds: [EventKind.profile],
        authors: [self],
        since: nowSec,
        limit: 1,
      ));
    } else {
      final authors = <String>[
        ..._profileAuthors.where((pk) => pk.length == 64 && pk != self),
        self,
      ];
      filters.add(NostrFilter(kinds: [EventKind.profile], authors: authors));
    }
    return filters;
  }

  /// Updates critical-REQ inputs and debounces [resubscribeMain] when anything changed.
  void updateCriticalInputs({
    bool? channelMode,
    Iterable<String>? vouchAuthors,
    Iterable<String>? profileAuthors,
    Iterable<String>? pqAuthors,
  }) {
    var changed = false;
    if (channelMode != null && channelMode != _channelMode) {
      _channelMode = channelMode;
      changed = true;
    }
    if (vouchAuthors != null) {
      final next = _sanitizeVouchAuthors(vouchAuthors);
      if (!listEquals(next, _vouchAuthors)) {
        _vouchAuthors = next;
        changed = true;
      }
    }
    if (profileAuthors != null) {
      final next = List<String>.unmodifiable(profileAuthors);
      if (!listEquals(next, _profileAuthors)) {
        _profileAuthors = next;
        changed = true;
      }
    }
    if (pqAuthors != null) {
      final next = _sanitizeVouchAuthors(pqAuthors);
      if (!listEquals(next, _pqAuthors)) {
        _pqAuthors = next;
        changed = true;
      }
    }
    if (changed) scheduleCriticalResubscribe();
  }

  /// Author cap on the direct-mode vouch filter.
  static const int _vouchAuthorCap = 500;

  List<String> _sanitizeVouchAuthors(Iterable<String> authors) =>
      List<String>.unmodifiable(
          authors.where(TrustGraph.isHex64).take(_vouchAuthorCap));

  /// 750ms debounce for [resubscribeMain] against bursts.
  Timer? _criticalResubTimer;

  void scheduleCriticalResubscribe() {
    _criticalResubTimer?.cancel();
    _criticalResubTimer = Timer(const Duration(milliseconds: 750), () {
      _criticalResubTimer = null;
      resubscribeMain();
    });
  }

  /// Closes and re-issues the main critical REQ; no-op before [start].
  void resubscribeMain() {
    if (_handlers == null) return;
    final old = _mainSub;
    final oldListener = _eventSub;
    final next = pool.subscribe(_buildCriticalFilters());
    _mainSub = next;
    _eventSub = next.events.listen(_routeMain);
    if (old == null || old.isClosed) {
      unawaited(oldListener?.cancel());
      return;
    }
    _mainOverlaps++;
    _retireMain[old] = retireAfterAnswer(old, next, onRetired: () {
      _retireMain.remove(old);
      unawaited(oldListener?.cancel());
      _mainOverlaps--;
      if (_mainOverlaps <= 0) {
        _mainOverlaps = 0;
        _mainOverlapIds.clear();
      }
    });
  }

  int _mainOverlaps = 0;

  final Set<String> _mainOverlapIds = <String>{};

  final Map<Subscription, void Function()> _retireMain = {};

  bool _isRetiringMain(Subscription sub) => _retireMain.containsKey(sub);

  void _retireAllMain() {
    for (final retire in _retireMain.values.toList()) {
      retire();
    }
  }

  void _routeMain(NostrEvent event) {
    if (_mainOverlaps > 0 && !_mainOverlapIds.add(event.id)) return;
    _routeInbound(event);
  }

  // Proxy to direct fallback and background restore

  /// Wires the proxy's unreachable signal to the direct fallback; re-run for each new proxy.
  void _wireProxyFallback() {
    if (!_autoFallback) return;
    final p = _pool;
    if (p is RelayPoolProxy) {
      p.onProxyUnreachable = _onProxyUnreachable;
    }
  }

  void _wireRetract(PoolTransport p) {
    if (p is RelayPoolProxy) {
      p.onEventRetracted = (id) => _handlers?.onEventRetracted?.call(id);
    }
  }

  void _wireLiveness(PoolTransport p) {
    if (p is RelayPoolProxy) {
      p.onShardLost = (at) =>
          _handlers?.onShardLost?.call(at?.millisecondsSinceEpoch ?? 0);
      p.onShardReconnected = () => _handlers?.onShardReconnected?.call();
    }
  }

  void probePool() {
    final p = _pool;
    if (p is RelayPoolProxy) p.probeNow();
  }

  static const int giftWrapBackdateSec = 172800;
  static const int giftWrapCatchUpLimit = 500;
  static const Duration giftWrapCatchUpWindow = Duration(seconds: 10);

  static NostrFilter giftWrapCatchUpFilter(
          Iterable<String> pubkeys, int floorSec) =>
      NostrFilter(
        kinds: [EventKind.giftWrap],
        since: floorSec - giftWrapBackdateSec,
        limit: giftWrapCatchUpLimit,
        tags: {
          'p': [
            ...{
              for (final pk in pubkeys)
                if (pk.isNotEmpty) pk,
            },
          ],
        },
      );

  final Set<Subscription> _wrapCatchUpSubs = {};

  Subscription? catchUpGiftWraps(
    Iterable<String> pubkeys, {
    required int floorSec,
    void Function(NostrEvent wrap)? onWrap,
    Duration window = giftWrapCatchUpWindow,
  }) {
    final filter =
        giftWrapCatchUpFilter([identity.pubkey, ...pubkeys], floorSec);
    if ((filter.tags['p'] ?? const []).isEmpty) return null;
    final sub = pool.subscribe([filter]);
    _wrapCatchUpSubs.add(sub);
    sub.events.listen((wrap) {
      if (wrap.kind != EventKind.giftWrap) return;
      onWrap?.call(wrap);
      unwrapLiveWrap(wrap);
    }, onError: (_) {});
    Timer(window, () {
      _wrapCatchUpSubs.remove(sub);
      unawaited(sub.close());
    });
    return sub;
  }

  /// Proxy unreachable: swap to direct and start the background restore.
  void Function()? onAutoFallback;

  void _onProxyUnreachable() {
    if (!_autoFallback || _poolFallbackActive || _userDirect || _stopped) {
      return;
    }
    _poolFallbackActive = true;
    onAutoFallback?.call();
    unawaited(_swapToDirect(_newDirectPool()));
  }

  /// Replaces the proxy with [direct], replaying live subscriptions onto it, then arms the restore loop.
  Future<void> _swapToDirect(RelayPool direct) async {
    if (_swapping) return;
    _swapping = true;
    try {
      final old = _pool;

      // Snapshot every sub registered on the old pool and reuse the same objects so listeners keep receiving.
      final live = _activeSubsOf(old);

      // Detach the old pool's sockets without closing the subscriptions.
      await _detachSockets(old);

      // Replay live subs on the direct pool, but rebuild the main REQ since its filters are mode-shaped.
      _pool = direct;
      direct.geoOriginAllows = geoOriginAllowsEvent;
      direct.connectAll();
      _handOverHeld(old, direct);
      for (final entry in live.values) {
        if (identical(entry.sub, _mainSub)) continue;
        if (_isRetiringMain(entry.sub)) continue;
        direct.replaySubscription(entry.sub, entry.filters);
      }
      _retireAllMain();
      resubscribeMain();

      // Re-establish geo-relay coverage on the new transport.
      applyGeoRelays();

      // The mainSub object is unchanged, so _eventSub keeps routing inbound.
      debugPrint('[NostrService] '
          '${_userDirect ? 'direct chosen' : 'proxy unreachable'}; '
          'swapped proxy → direct (${live.length} subs replayed)');

      _scheduleBgRestore();
      _handlers?.onConnectionChanged?.call(_pool.connectedCount);
    } finally {
      _swapping = false;
    }
  }

  Map<String, ({Subscription sub, List<NostrFilter> filters})> _activeSubsOf(
      PoolTransport p) {
    if (p is RelayPoolProxy) return p.activeSubscriptions();
    if (p is RelayPool) return p.activeSubscriptions();
    return const {};
  }

  void _handOverHeld(PoolTransport from, PoolTransport to) {
    if (from is RelayPoolProxy) from.handOverHeld(to);
    if (from is RelayPool) from.handOverHeld(to);
  }

  Future<void> _detachSockets(PoolTransport p) async {
    if (p is RelayPoolProxy) {
      p.onProxyUnreachable =
          null; // Don't let a teardown close fire the trigger.
      await p.disconnectSocketsOnly();
    } else if (p is RelayPool) {
      await p.disconnectSocketsOnly();
    } else {
      await p.disconnectAll();
    }
  }

  /// Background restore: first retry after 15s, then `min(15000 * 2^min(n-1,4), 120000)` with 50–100% jitter.
  void _scheduleBgRestore() {
    if (!_autoFallback || !_poolFallbackActive || _userDirect) return;
    if (_bgRestoreInFlight || _stopped) return;
    _bgRestoreTimer?.cancel();
    final delay = _bgRestoreAttempts == 0
        ? const Duration(seconds: 15)
        : _bgRestoreBackoff(_bgRestoreAttempts);
    _bgRestoreTimer = Timer(delay, _tryRestoreProxy);
  }

  Duration _bgRestoreBackoff(int attempts) {
    final expIdx = min(attempts - 1, 4);
    final base = min(15000 * pow(2, expIdx).toInt(), 120000);
    // 50–100% jitter.
    final jittered = (base * (0.5 + _bgRng.nextDouble() * 0.5)).floor();
    return Duration(milliseconds: jittered);
  }

  final Random _bgRng = Random();

  /// Probes a fresh proxy; swaps back when it confirms, else its unreachable trigger reschedules.
  void _tryRestoreProxy() {
    _bgRestoreTimer = null;
    if (!_poolFallbackActive || _userDirect || _stopped) return;
    _bgRestoreAttempts++;
    _bgRestoreInFlight = true;

    // Short-lived probe: adopted if it confirms, discarded with backoff if not.
    final probe = _newProxyPool();
    probe.onProxyUnreachable = () {
      _bgRestoreInFlight = false;
      unawaited(probe.disconnectAll());
      _scheduleBgRestore();
    };
    probe.onProxyConnected = () {
      // Probe reached the host: promote it to the live transport.
      if (!_poolFallbackActive) {
        // A concurrent restore already happened; discard this probe.
        unawaited(probe.disconnectAll());
        return;
      }
      _bgRestoreInFlight = false;
      _bgRestoreAttempts = 0;
      // The probe is already connected; adopt it without re-running connectAll.
      unawaited(_adoptRestoredProxy(probe));
    };
    probe.connectAll();
  }

  /// Promotes a confirmed probe proxy: replay live subs onto it and tear down the direct sockets.
  Future<void> _adoptRestoredProxy(RelayPoolProxy restored) async {
    if (_swapping || !_poolFallbackActive) {
      unawaited(restored.disconnectAll());
      return;
    }
    _swapping = true;
    try {
      final old = _pool;
      final live = _activeSubsOf(old);
      await _detachSockets(old);
      _pool = restored;
      restored.geoOriginAllows = geoOriginAllowsEvent;
      restored.onProxyUnreachable = _onProxyUnreachable; // Future blips.
      _wireRetract(restored);
      _wireLiveness(restored);
      _wireOutbox(restored);
      _handOverHeld(old, restored);
      for (final entry in live.values) {
        if (identical(entry.sub, _mainSub)) continue;
        if (_isRetiringMain(entry.sub)) continue;
        restored.replaySubscription(entry.sub, entry.filters);
      }
      _retireAllMain();
      // Back on the proxy: rebuild the main REQ into its D1 shape.
      resubscribeMain();
      _poolFallbackActive = false;
      _stopBgRestore();
      // Re-shard the geo relays onto the restored proxy.
      applyGeoRelays();
      debugPrint('[NostrService] proxy restored; swapped direct → proxy '
          '(${live.length} subs replayed)');
      _handlers?.onConnectionChanged?.call(_pool.connectedCount);
    } finally {
      _swapping = false;
    }
  }

  @visibleForTesting
  Future<void> swapToDirectForTest(RelayPool direct) {
    _poolFallbackActive = true;
    return _swapToDirect(direct);
  }

  @visibleForTesting
  Future<void> adoptRestoredProxyForTest(RelayPoolProxy restored) {
    _poolFallbackActive = true;
    return _adoptRestoredProxy(restored);
  }

  void _stopBgRestore() {
    _bgRestoreTimer?.cancel();
    _bgRestoreTimer = null;
    _bgRestoreInFlight = false;
    _bgRestoreAttempts = 0;
  }

  static Duration userDirectConnectWait = const Duration(seconds: 4);

  bool get isBgRestoreArmed => _bgRestoreTimer != null || _bgRestoreInFlight;

  Future<void> setUserDirect(bool direct) async {
    if (!_autoFallback || _stopped) return;
    if (direct) {
      _userDirect = true;
      _poolFallbackActive = false;
      _stopBgRestore();
      if (_pool is! RelayPoolProxy) {
        _handlers?.onConnectionChanged?.call(_pool.connectedCount);
        return;
      }
      final next = _newDirectPool();
      next.connectAll();
      await _awaitConnected(next, userDirectConnectWait);
      if (_stopped || !_userDirect || _pool is! RelayPoolProxy) {
        unawaited(next.disconnectAll());
        return;
      }
      await _swapToDirect(next);
      return;
    }
    _userDirect = false;
    if (_pool is RelayPoolProxy) {
      _handlers?.onConnectionChanged?.call(_pool.connectedCount);
      return;
    }
    _poolFallbackActive = true;
    retryProxyNow();
  }

  void retryProxyNow() {
    if (!_autoFallback || _userDirect || _stopped) return;
    if (!_poolFallbackActive || _bgRestoreInFlight || _swapping) return;
    _bgRestoreTimer?.cancel();
    _bgRestoreTimer = null;
    _tryRestoreProxy();
  }

  Future<void> _awaitConnected(PoolTransport p, Duration limit) async {
    final until = DateTime.now().add(limit);
    while (p.connectedCount == 0 &&
        !_stopped &&
        DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// The active channel's typing/read-receipt subscription (kinds 24420/24421).
  Subscription? _channelTypingSub;
  String? _channelTypingKey;
  Subscription subscribeChannelTyping(String channelKey,
      {bool isGeohash = true}) {
    // Key by tag kind and channel, and reuse the cached sub only while it is still open.
    final id = '${isGeohash ? 'g' : 'd'}:$channelKey';
    final cached = _channelTypingSub;
    if (_channelTypingKey == id && cached != null && !cached.isClosed) {
      return cached;
    }
    _channelTypingSub?.close();
    // 1h `since` margin so clock-skewed live events aren't dropped by relays.
    final since = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;
    final sub = pool.subscribe([
      NostrFilter(
        kinds: [EventKind.channelTyping, EventKind.channelReceipt],
        since: since,
        tags: {
          if (isGeohash) 'g': [channelKey] else 'd': [channelKey],
        },
      ),
    ]);
    final s = sub.events.listen((e) => _handlers?.onEvent?.call(e));
    sub.eose.then((_) => null);
    _channelTypingSub = sub;
    _channelTypingKey = id;
    // Typing events route through onEvent; cancellation is handled on close.
    s.onError((_) {});
    return sub;
  }

  /// Max wait for a one-shot PQ announcement lookup before sending classically.
  static const Duration pqLookupTimeout = Duration(milliseconds: 2500);

  /// Extra listening after EOSE, since the quorum may be reached by relays that lack the key.
  static const Duration pqEoseGrace = Duration(milliseconds: 600);

  Future<bool> fetchPqAnnouncement(String pubkey, {bool Function()? found}) async {
    if (!TrustGraph.isHex64(pubkey)) return true;
    final sub = pool.subscribe([
      NostrFilter(
        kinds: [EventKind.appData],
        authors: [pubkey],
        limit: 1,
        tags: {
          't': [AppDataTopic.postQuantum],
        },
      ),
    ]);
    final s = sub.events.listen((e) => _handlers?.onEvent?.call(e));
    try {
      await sub.eose.timeout(pqLookupTimeout, onTimeout: () => null);
      // The event may be delivered a microtask after EOSE; give it one turn.
      await Future<void>.delayed(Duration.zero);
      // Wait briefly for a slower relay, unless the key already arrived.
      if (found != null && !found()) {
        final deadline = DateTime.now().add(pqEoseGrace);
        while (!found() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
    } catch (_) {
      // A relay that never answers is a normal outcome here.
    } finally {
      await s.cancel();
      sub.close();
    }
    return sub.answered;
  }

  /// Adds ephemeral group pubkeys as `#p` gift-wrap subs; [limit]/[since] choose live-only or 7-day backfill.
  Subscription subscribeEphemeral(
    List<String> ephemeralPubkeys, {
    int? limit,
    int? since,
  }) {
    return pool.subscribe([
      NostrFilter(
        kinds: [EventKind.giftWrap],
        since: since,
        limit: limit,
        tags: {'p': ephemeralPubkeys},
      ),
    ]);
  }

  /// Routes a verified event: gift wraps are unwrapped to [NostrHandlers.onGiftWrap], all else to [onEvent].
  void _routeInbound(NostrEvent event) {
    if (_quiet.isNotEmpty &&
        (_quiet.contains(event.pubkey) || _quiet.contains(event.id))) {
      return;
    }
    if (event.kind == EventKind.giftWrap) {
      unawaited(_handleGiftWrap(event));
      return;
    }
    // Advance the self kind-0 watermark so the next [publishProfile] outranks it.
    if (event.kind == EventKind.profile &&
        event.pubkey == identity.pubkey &&
        event.createdAt > _lastKind0Ts) {
      _lastKind0Ts = event.createdAt;
    }
    _handlers?.onEvent?.call(event);
  }

  /// Ephemeral keys paired with our ML-KEM epochs; the p-tag match comes first, the spare covers a stale tag.
  static const int _ephPqPairingLimit = 2;

  /// Our ephemeral group secret keys, the one [wrap] is addressed to first.
  List<Uint8List> _orderedEphemeralSks(NostrEvent? wrap) {
    if (wrap == null || _ephemeralSks.length < 2) return _ephemeralSks;
    String? target;
    for (final t in wrap.tags) {
      if (t.length > 1 && t[0] == 'p') {
        target = t[1];
        break;
      }
    }
    if (target == null) return _ephemeralSks;
    for (var i = 0; i < _ephemeralSks.length; i++) {
      if (keys.getPublicKeyHex(_ephemeralSks[i]) != target) continue;
      if (i == 0) return _ephemeralSks;
      return [
        _ephemeralSks[i],
        for (var j = 0; j < _ephemeralSks.length; j++)
          if (j != i) _ephemeralSks[j],
      ];
    }
    return _ephemeralSks;
  }

  /// The candidate list [_handleGiftWrap] builds, exposed for tests.
  @visibleForTesting
  List<giftwrap.UnwrapCandidate> unwrapCandidatesForTest(NostrEvent? wrap) =>
      _candidates(wrap);

  List<giftwrap.UnwrapCandidate> _candidates([NostrEvent? wrap]) {
    final out = <giftwrap.UnwrapCandidate>[];
    final sk = identity.privkey;
    if (sk != null) {
      // Identity key paired with each ML-KEM epoch, newest first; classical wraps fall through to the classical candidate.
      for (final k in _pqSelfKeys) {
        out.add((sk: sk, bitchat: false, kemSk: k.kemSk, kemPk: k.kemPk));
      }
      out.add(giftwrap.classicalCandidate(sk, bitchat: true));
    }
    // Group PQ wraps need the ephemeral secp key and identity ML-KEM key paired in one candidate.
    if (_pqSelfKeys.isNotEmpty) {
      for (final esk in _orderedEphemeralSks(wrap).take(_ephPqPairingLimit)) {
        for (final k in _pqSelfKeys) {
          out.add((sk: esk, bitchat: false, kemSk: k.kemSk, kemPk: k.kemPk));
        }
      }
    }
    for (final esk in _ephemeralSks) {
      out.add(giftwrap.classicalCandidate(esk));
    }
    for (final k in _anonBotKeys) {
      out.add((sk: k.sk, bitchat: false, kemSk: k.kemSk, kemPk: k.kemPk));
      out.add(giftwrap.classicalCandidate(k.sk));
    }
    return out;
  }

  /// Our ML-KEM keypairs (current plus recent epochs), so rotated-key PQ wraps decrypt.
  List<({Uint8List kemSk, Uint8List kemPk})> _pqSelfKeys = const [];

  void setPqSelfKeys(List<({Uint8List kemSk, Uint8List kemPk})> keys) {
    _candidateGen++;
    _pqSelfKeys = List.unmodifiable(keys);
  }

  /// Current and previous ephemeral group keys, so rotated-key wraps decrypt.
  final List<Uint8List> _ephemeralSks = [];

  void setEphemeralKeys(List<Uint8List> sks) {
    _candidateGen++;
    _ephemeralSks
      ..clear()
      ..addAll(sks);
  }

  List<({Uint8List sk, Uint8List kemSk, Uint8List kemPk})> _anonBotKeys =
      const [];

  void setAnonBotKeys(
      List<({Uint8List sk, Uint8List kemSk, Uint8List kemPk})> keys) {
    _candidateGen++;
    _anonBotKeys = List.unmodifiable(keys);
  }

  /// Unwraps a D1-archived wrap through the normal gift-wrap path, flagged as archive.
  void unwrapArchivedWrap(NostrEvent wrap) {
    if (wrap.kind != EventKind.giftWrap) return;
    unawaited(_handleGiftWrap(wrap, fromArchive: true));
  }

  Future<bool> replayArchivedWrap(NostrEvent wrap) async {
    if (wrap.kind != EventKind.giftWrap) return true;
    await _handleGiftWrap(wrap, fromArchive: true);
    return wrap.id.isNotEmpty && _processedWrapIds.contains(wrap.id);
  }

  Future<GiftWrapUnwrapped?> probeArchivedWrap(NostrEvent wrap) async {
    if (wrap.kind != EventKind.giftWrap) return null;
    GiftWrapUnwrapped? out;
    await _unwrapAndEmit(null, wrap, fromArchive: true, sink: (u) => out = u);
    return out;
  }

  /// Unwraps a live wrap from an auxiliary sub as live, so it is archived and notified (unlike [unwrapArchivedWrap]).
  void unwrapLiveWrap(NostrEvent wrap) {
    if (wrap.kind != EventKind.giftWrap) return;
    unawaited(_handleGiftWrap(wrap));
  }

  Future<void> _handleGiftWrap(NostrEvent wrap,
      {bool fromArchive = false}) async {
    final handlers = _handlers;
    if (handlers?.onGiftWrap == null) return;
    // Already unwrapped this process: skip the costly unwrap.
    if (wrap.id.isNotEmpty && _processedWrapIds.contains(wrap.id)) return;
    if (wrap.id.isNotEmpty && !_unwrapsInFlight.add(wrap.id)) return;
    try {
      await _unwrapAndEmit(handlers!, wrap, fromArchive: fromArchive);
    } finally {
      _unwrapsInFlight.remove(wrap.id);
    }
  }

  static final Set<String> _unwrapsInFlight = <String>{};

  @visibleForTesting
  static int debugUnwrapAttempts = 0;

  int _candidateGen = 0;

  final LinkedHashMap<String, int> _failedWraps = LinkedHashMap<String, int>();

  Future<void> _unwrapAndEmit(NostrHandlers? handlers, NostrEvent wrap,
      {required bool fromArchive,
      void Function(GiftWrapUnwrapped u)? sink}) async {
    final candidates = _candidates(wrap);

    // NIP-46: no local identity key, so self-addressed wraps unwrap via the remote `nip44_decrypt`.
    final sig = signer;
    if (sig != null && sig.isRemote && _isAddressedToSelf(wrap)) {
      // Cap concurrent remote decrypts; gate only the RPC round-trips.
      await _remoteUnwrapGate.acquire();
      ({NostrEvent seal, Map<String, dynamic> rumor, bool isPq})? res;
      try {
        res = await _unwrapRemote(wrap, sig, selfKem: selfKemForUnwrap?.call());
      } finally {
        _remoteUnwrapGate.release();
      }
      if (res != null) {
        await _emitUnwrapped(handlers, wrap, res.seal, res.rumor,
            isBitchat: false,
            isPq: res.isPq,
            fromArchive: fromArchive,
            sink: sink);
        return;
      }
    }

    if (candidates.isEmpty) return;
    final remoteTried = sig != null && sig.isRemote && _isAddressedToSelf(wrap);
    final gen = _candidateGen;
    if (sink == null &&
        !remoteTried &&
        wrap.id.isNotEmpty &&
        _failedWraps[wrap.id] == gen) {
      return;
    }
    debugUnwrapAttempts++;
    // Local-key unwrap runs in the crypto worker, falling back inline on web or failure.
    final res = await _cryptoWorker.unwrap(wrap, candidates);
    if (res == null) {
      if (sink == null && !remoteTried && wrap.id.isNotEmpty) {
        _failedWraps.remove(wrap.id);
        _failedWraps[wrap.id] = gen;
        while (_failedWraps.length > 5000) {
          _failedWraps.remove(_failedWraps.keys.first);
        }
      }
      return;
    }

    await _emitUnwrapped(handlers, wrap, res.seal, res.rumor,
        fromArchive: fromArchive,
        isBitchat: res.isBitchat,
        isPq: res.isPq,
        sink: sink);
  }

  /// True when [wrap] is p-tagged to our identity pubkey rather than an ephemeral group key.
  bool _isAddressedToSelf(NostrEvent wrap) {
    final self = identity.pubkey;
    for (final t in wrap.tags) {
      if (t.length > 1 && t[0] == 'p' && t[1] == self) return true;
    }
    return false;
  }

  /// Unwraps a self-addressed wrap via the signer; layered PQ needs [selfKem] from the root; null on failure.
  Future<({NostrEvent seal, Map<String, dynamic> rumor, bool isPq})?>
      _unwrapRemote(
    NostrEvent wrap,
    EventSigner sig, {
    ({Uint8List kemSk, Uint8List kemPk})? selfKem,
  }) async {
    try {
      // Both layers were sealed to our identity key on this path.
      final recipPk = identity.pubkey;
      var usedPq = false;
      Future<String> strip(String content, String senderPk) async {
        if (!pq.isPq2Payload(content)) return content;
        if (selfKem == null) throw StateError('no post-quantum key on this device');
        usedPq = true;
        return pq.pq2Open(
            content, senderPk, recipPk, selfKem.kemSk, selfKem.kemPk);
      }

      final sealJson = await sig.nip44Decrypt(
          wrap.pubkey, await strip(wrap.content, wrap.pubkey));
      final seal =
          NostrEvent.fromJson(jsonDecode(sealJson) as Map<String, dynamic>);
      final rumorJson = await sig.nip44Decrypt(
          seal.pubkey, await strip(seal.content, seal.pubkey));
      final rumor = jsonDecode(rumorJson) as Map<String, dynamic>;
      return (seal: seal, rumor: rumor, isPq: usedPq);
    } catch (_) {
      return null;
    }
  }

  /// Verifies NIP-59 seal authorship and emits the rumor; shared by local and remote paths.
  Future<void> _emitUnwrapped(
    NostrHandlers? handlers,
    NostrEvent wrap,
    NostrEvent seal,
    Map<String, dynamic> rumor, {
    required bool isBitchat,
    bool isPq = false,
    bool fromArchive = false,
    void Function(GiftWrapUnwrapped u)? sink,
  }) async {
    // Record the id once decrypted, even if the seal is forged, so replays skip it.
    if (sink == null) _rememberProcessedWrap(wrap.id);
    final rumorPubkey = rumor['pubkey'] as String?;
    if (rumorPubkey == null || rumorPubkey.isEmpty) return;

    // NIP-59 sender auth: native seals must be signed by the claimed author.
    var senderVerified = true;
    var emitRumor = rumor;
    if (isBitchat) {
      senderVerified = false;
      // Decode `bitchat1:` rumor content to text as the PWA does; drop receipt payloads.
      final decoded = _decodeBitchatRumor(rumor);
      if (decoded == null) return;
      emitRumor = decoded;
    } else {
      // Batched off-main seal verification; the cheap pubkey check short-circuits first.
      if (seal.pubkey != rumorPubkey || !(await _verifier.verify(seal))) {
        return; // Forged.
      }
    }

    final out = GiftWrapUnwrapped(
      wrapId: wrap.id,
      wrapCreatedAt: wrap.createdAt,
      rumor: emitRumor,
      senderVerified: senderVerified,
      isBitchat: isBitchat,
      isPq: isPq,
      rawWrap: wrap.toJson(),
      fromArchive: fromArchive,
    );
    if (sink != null) {
      sink(out);
    } else {
      handlers?.onGiftWrap?.call(out);
    }
  }

  /// Decodes `bitchat1:` content to text (adding an `x` id tag if missing); null for receipts; other content unchanged.
  Map<String, dynamic>? _decodeBitchatRumor(Map<String, dynamic> rumor) {
    final content = rumor['content'];
    if (content is! String || !bitchat.isBitchatPacket(content)) return rumor;
    final packet = bitchat.decodeBitchatPacket(content);
    if (packet == null || !packet.isPrivateMessage) return null;

    final next = Map<String, dynamic>.of(rumor);
    next['content'] = packet.content ?? '';
    final id = packet.messageId;
    if (id != null && id.isNotEmpty) {
      final tags = (rumor['tags'] as List?)
              ?.whereType<List>()
              .map((t) => t.map((e) => e.toString()).toList())
              .toList() ??
          <List<String>>[];
      final hasX = tags.any((t) => t.isNotEmpty && t[0] == 'x');
      if (!hasX) {
        next['tags'] = [
          ...tags,
          ['x', id],
        ];
      }
    }
    return next;
  }

  /// Requests recent kind-0s for [pubkeys]; best-effort, auto-closing.
  void fetchProfiles(List<String> pubkeys) {
    if (pubkeys.isEmpty) return;
    final sub = pool.subscribe([
      NostrFilter(
          kinds: [EventKind.profile], authors: pubkeys, limit: pubkeys.length),
    ]);
    // Route through [_routeInbound] so a fetched self kind-0 advances the watermark.
    final s = sub.events.listen(_routeInbound);
    sub.eose.then((_) {
      s.cancel();
      sub.close();
    });
  }

  /// Publishes a kind 20000/23333 channel message; returns the signed event, or null if we can't sign.
  Future<NostrEvent?> publishChannelMessage({
    required String channelKey,
    required String content,
    required String nym,
    String? geohash,
    List<List<String>> emojiTags = const [],
    int powDifficulty = 0,
    EventSigner? signerOverride,
    // Thread reply root id, emitted as a NIP-10 `['e', rootId, '', 'root']` tag.
    String? threadRoot,
    // Original send time for mesh outbox replays, keeping order and optimistic reconciliation; null = now.
    int? createdAtSec,
    // Extra tags merged verbatim, e.g. the outbox's `['nymmesh', <id>]` for mesh dedup.
    List<List<String>> extraTags = const [],
    // Return the signed event without publishing, byte-identical, for gateway mode.
    bool buildOnly = false,
    String? queuedKey,
  }) async {
    // [signerOverride] is the pseudonymous path: a per-message ephemeral key.
    final sig = signerOverride ?? signer;
    if (sig == null) return null;

    final isGeo = geohash != null && geohash.isNotEmpty;
    final badge = signerOverride == null ? attestBadge : null;
    final signed = await buildChannelMessage(
      signer: sig,
      channelKey: channelKey,
      content: content,
      nym: nym,
      geohash: geohash,
      badge: badge,
      emojiTags: emojiTags,
      powDifficulty: powDifficulty,
      threadRoot: threadRoot,
      createdAtSec: createdAtSec,
      extraTags: extraTags,
    );
    eventProvenance.recordLocal(signed, 'THIS CLIENT');
    if (buildOnly) return signed;

    if (queuedKey != null) QueuedSends.instance.register(signed.id, queuedKey);
    try {
      if (isGeo) {
        final closest =
            closestGeoRelays(geohash).map((r) => r.url).toList(growable: false);
        await pool.publishGeo(signed, closest);
      } else {
        await pool.publish(signed);
      }
    } finally {
      if (queuedKey != null) QueuedSends.instance.release(signed.id);
    }
    return signed;
  }

  static Future<NostrEvent> buildChannelMessage({
    required EventSigner signer,
    required String channelKey,
    required String content,
    required String nym,
    String? geohash,
    String? badge,
    List<List<String>> emojiTags = const [],
    int powDifficulty = 0,
    String? threadRoot,
    int? createdAtSec,
    List<List<String>> extraTags = const [],
  }) async {
    final isGeo = geohash != null && geohash.isNotEmpty;
    final kind = isGeo ? EventKind.geoChannel : EventKind.namedChannel;
    final hasStamp = createdAtSec != null && createdAtSec > 0;
    final nowSec =
        hasStamp ? createdAtSec : DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nowMs =
        hasStamp ? createdAtSec * 1000 : DateTime.now().millisecondsSinceEpoch;
    final tags = <List<String>>[
      ['n', nym],
      ['ms', '$nowMs'],
      [isGeo ? 'g' : 'd', isGeo ? geohash : channelKey],
      if (badge != null && badge.isNotEmpty) ['nymattest', badge],
      if (threadRoot != null && threadRoot.isNotEmpty)
        ['e', threadRoot, '', 'root'],
      ...emojiTags,
      ...extraTags,
    ];
    final difficulty =
        powDifficulty > kNymchatPowFloor ? powDifficulty : kNymchatPowFloor;
    final mined = await mineNonce(
      UnsignedEvent(
        pubkey: signer.pubkey,
        createdAt: nowSec,
        kind: kind,
        tags: tags,
        content: content,
      ),
      difficulty,
    );
    return signer.sign(mined);
  }

  /// Publishes a kind-7 channel reaction with `e`/`p`/`k`, NIP-30 emoji, channel `g`/`d`, and `action: remove` when [remove].
  Future<NostrEvent?> publishReaction({
    required String messageId,
    required String targetPubkey,
    required String emoji,
    required String originalKind, // '20000' | '23333' | '1059'
    String? geohash,
    String? channel,
    bool remove = false,
    List<List<String>> emojiTags = const [],
  }) async {
    final sig = signer;
    if (sig == null) return null;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tags = <List<String>>[
      ['e', messageId],
      ['p', targetPubkey],
      ['k', originalKind],
      if (remove) ['action', 'remove'],
      // NIP-30: declare the custom emoji.
      ...emojiTags,
    ];
    // Carry the channel id so the relay/D1 archive can key the reaction.
    if (originalKind == '20000' && geohash != null && geohash.isNotEmpty) {
      tags.add(['g', geohash]);
    } else if (originalKind == '23333' &&
        channel != null &&
        channel.isNotEmpty) {
      tags.add(['d', channel]);
    }
    final signed = await sig.sign(
      UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.reaction,
        tags: tags,
        content: emoji,
      ),
    );
    _queuePublish(signed);
    return signed;
  }

  /// Publishes a prebuilt kind-30078 poll create or vote.
  Future<NostrEvent?> publishPollEvent(UnsignedEvent rumor) async {
    final sig = signer;
    if (sig == null) return null;
    final signed = await sig.sign(rumor);
    await pool.publish(signed);
    return signed;
  }

  /// Publishes our kind-30078 `nym-vouches` list; no-op for an empty list.
  Future<NostrEvent?> publishVouches(List<String> vouchedPubkeys) async {
    final sig = signer;
    if (sig == null || vouchedPubkeys.isEmpty) return null;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final signed = await sig.sign(
      UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.appData,
        tags: const [
          ['d', AppDataTopic.vouches],
          ['t', AppDataTopic.vouches],
        ],
        content: jsonEncode(vouchedPubkeys),
      ),
    );
    await pool.publish(signed);
    return signed;
  }

  /// created_at of our last `nym-pq`, so a quick republish can't tie and be dropped.
  int _lastPqTs = 0;

  /// Publishes our `nym-pq` ML-KEM key, signature-bound with a NIP-40 expiration; sent even without a key.
  Future<NostrEvent?> publishPqAnnouncement({
    required Uint8List? kemPublicKey,
    required int epoch,
    required List<PqDevice> devices,
    bool rootSeeded = false,
    bool legacyCapable = true,
  }) async {
    final sig = signer;
    if (sig == null) return null;
    // Addressable replace keeps the lower id on a created_at tie, so use a monotonic floor.
    final nowSec = max(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      _lastPqTs + 1,
    );
    _lastPqTs = nowSec;
    final exp = nowSec + pqTtl.inSeconds;
    final signed = await sig.sign(
      UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.appData,
        tags: [
          ['d', AppDataTopic.postQuantum],
          ['t', AppDataTopic.postQuantum],
          ['expiration', '$exp'],
        ],
        content: PqAnnouncement.encode(
          publicKey: kemPublicKey,
          expiresAt: exp,
          epoch: epoch,
          devices: devices,
          rootSeeded: rootSeeded,
          legacyCapable: legacyCapable,
        ),
      ),
    );
    await pool.publish(signed);
    return signed;
  }

  void _queuePublish(NostrEvent signed) {
    unawaited(pool.publish(signed).then((_) {}, onError: (Object _) {}));
  }

  /// created_at of our newest published or received self kind-0: the floor for [publishProfile].
  int _lastKind0Ts = 0;

  /// Publishes kind 0 at `max(randomNow(), _lastKind0Ts + 1)`, so edits never tie or lose to skewed copies.
  Future<NostrEvent?> publishProfile(String content) async {
    final sig = signer;
    if (sig == null) return null;
    final createdAt = max(giftwrap.randomNow(), _lastKind0Ts + 1);
    _lastKind0Ts = createdAt;
    final signed = await sig.sign(
      UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: createdAt,
        kind: EventKind.profile,
        tags: const [],
        content: content,
      ),
    );
    _queuePublish(signed);
    return signed;
  }

  /// Publishes a prebuilt NIP-57 zap request and returns it for the LNURL `nostr` param.
  Future<NostrEvent?> publishZapRequest(UnsignedEvent rumor) async {
    final sig = signer;
    if (sig == null) return null;
    final signed = await sig.sign(rumor);
    await pool.publish(signed);
    return signed;
  }

  /// Mints our own kind-9735 receipt for a channel zap, with a `k` tag so live badge subscriptions match.
  Future<NostrEvent?> publishMessageZapReceipt({
    required String messageId,
    required String recipientPubkey,
    required String bolt11,
    required String originalKind, // '20000' | '23333'
    String? geohash,
    String? channel,
  }) async {
    final sig = signer;
    if (sig == null) return null;
    if (originalKind != '${EventKind.geoChannel}' &&
        originalKind != '${EventKind.namedChannel}') {
      return null;
    }
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final isGeo = geohash != null && geohash.isNotEmpty;
    final tags = <List<String>>[
      ['e', messageId],
      ['p', recipientPubkey],
      ['k', originalKind],
      ['bolt11', bolt11],
      // Carry the channel id so the relay/D1 archive can key the receipt.
      if (isGeo)
        ['g', geohash]
      else if (originalKind == '${EventKind.namedChannel}' &&
          channel != null &&
          channel.isNotEmpty)
        ['d', channel],
    ];
    final signed = await sig.sign(
      UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.zapReceipt,
        tags: tags,
        content: '',
      ),
    );
    if (isGeo) {
      final closest =
          closestGeoRelays(geohash).map((r) => r.url).toList(growable: false);
      await pool.publishGeo(signed, closest);
    } else {
      await pool.publish(signed);
    }
    return signed;
  }

  /// Gift-wraps [rumor] to each recipient and publishes; true if any wrap published.
  Future<bool> publishGiftWrappedRumor({
    required UnsignedEvent rumor,
    required List<String> recipients,
    String Function(String memberPubkey)? encryptTo,
    int? expiration,
    void Function(NostrEvent wrap)? onWrap,
  }) async {
    if (signer == null || recipients.isEmpty) return false;
    var any = false;
    for (final pk in recipients) {
      final pq = _pqTarget(pk);
      final wrap = await _wrapAndPublish(
        rumor,
        encryptTo?.call(pk) ?? pk,
        expiration: expiration,
        recipientKemPublicKey: pq.kem,
        layered: pq.layered,
        tier: rumorTier(rumor, recipients.length),
      );
      if (wrap != null) onWrap?.call(wrap);
      any = any || wrap != null;
    }
    return any;
  }

  Future<bool> publishCallSignal({
    required String to,
    required Map<String, dynamic> content,
    String Function(String memberPubkey)? encryptTo,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiresAt = now + callSignalTtl(content['type']);
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: now,
      kind: EventKind.callSignaling,
      tags: [
        ['p', to],
        ['expiration', '$expiresAt'],
      ],
      content: jsonEncode(content),
    );
    return publishGiftWrappedRumor(
      rumor: rumor,
      recipients: [to],
      encryptTo: encryptTo,
      expiration: expiresAt,
    );
  }

  // Gift-wrapped publish paths and presence

  /// Builds a wrap: local keys in the crypto worker, NIP-46 via the async path; [recipientKemPublicKey] makes it hybrid.
  Future<NostrEvent?> _buildWrap(
    UnsignedEvent rumor,
    String recipientPubkey, {
    int? expiration,
    Uint8List? recipientKemPublicKey,
    bool layered = false,
    List<List<String>> extraTags = const [],
  }) async {
    final sig = signer;
    if (sig == null) return null;
    if (sig is LocalSigner) {
      return _cryptoWorker.wrapOne(
        rumor: rumor,
        senderPrivkey: sig.privkey,
        recipientPubkey: recipientPubkey,
        expiration: expiration,
        recipientKemPk: recipientKemPublicKey,
        layered: layered,
        extraTags: extraTags,
      );
    }
    // NIP-46: remote seal; the local ephemeral wrap layer can still be hybrid.
    return giftwrap.nip59WrapAsync(
      rumor: rumor,
      senderSigner: sig,
      recipientPubkey: recipientPubkey,
      expiration: expiration,
      recipientKemPublicKey: recipientKemPublicKey,
      layered: layered,
      extraTags: extraTags,
    );
  }

  /// bitchat `v2:` gift wrap for bitchat peers; local keys only, null for NIP-46.
  Future<NostrEvent?> _buildBitchatWrap(
    UnsignedEvent rumor,
    String recipientPubkey, {
    int? expiration,
  }) async {
    final sig = signer;
    if (sig is! LocalSigner) return null;
    return giftwrap.bitchatWrap(
      rumor: rumor,
      senderPrivkey: sig.privkey,
      recipientPubkey: recipientPubkey,
      expiration: expiration,
    );
  }

  /// Gift-wraps [rumor] to [recipientPubkey] and publishes; null if we can't sign.
  Future<NostrEvent?> _wrapAndPublish(
    UnsignedEvent rumor,
    String recipientPubkey, {
    int? expiration,
    Uint8List? recipientKemPublicKey,
    bool layered = false,
    List<List<String>> extraTags = const [],
    int? tier,
    String? queuedKey,
  }) async {
    final wrap = await _buildWrap(rumor, recipientPubkey,
        expiration: expiration,
        recipientKemPublicKey: recipientKemPublicKey,
        layered: layered,
        extraTags: extraTags);
    if (wrap == null) return null;
    if (queuedKey != null) QueuedSends.instance.register(wrap.id, queuedKey);
    // Gift wraps publish via DM_EVENT so the proxy prioritizes default relays.
    publishDmQueued(wrap, tier: tier ?? rumorTier(rumor, 1));
    return wrap;
  }

  /// Publishes a NIP-17 PM and a self-copy, plus bitchat wraps for non-Nymchat peers; only NIP-17 wraps reach [onWrap].
  Future<bool> publishPM({
    required UnsignedEvent rumor,
    required String recipientPubkey,
    MessagingSettings settings = const MessagingSettings(),
    void Function(NostrEvent wrap)? onWrap,
    List<UnsignedEvent> bitchatRumors = const [],
    bool sendNymWrap = true,
    Uint8List? recipientKemPublicKey,
    Uint8List? selfKemPublicKey,
    bool recipientLayered = false,
    bool selfLayered = false,
    List<List<String>> wrapTags = const [],
    String? queuedKey,
  }) async {
    if (signer == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiration = settings.expirationFor(nowSec);

    // bitchat wrap: relay-only, never deposited, and no expiration tag since bitchat rejects extra tags.
    if (bitchatRumors.isNotEmpty && recipientPubkey != identity.pubkey) {
      for (final r in bitchatRumors) {
        final bwrap = await _buildBitchatWrap(r, recipientPubkey);
        if (bwrap != null) publishDmQueued(bwrap, tier: rumorTier(r, 1));
      }
    }

    // Report NIP-17 wraps for archive and deposit at send time; deposit is an offline peer's only delivery in pool mode.
    if (sendNymWrap) {
      final recipientWrap = await _wrapAndPublish(rumor, recipientPubkey,
          expiration: expiration,
          recipientKemPublicKey: recipientKemPublicKey,
          layered: recipientLayered,
          extraTags: wrapTags,
          queuedKey: queuedKey);
      if (recipientWrap != null) onWrap?.call(recipientWrap);
    }
    if (recipientPubkey != identity.pubkey) {
      // Self-copy is post-quantum whenever we are, so the archive isn't the weak link.
      final selfWrap = await _wrapAndPublish(rumor, identity.pubkey,
          expiration: expiration,
          recipientKemPublicKey: selfKemPublicKey,
          layered: selfLayered,
          extraTags: wrapTags);
      if (selfWrap != null) onWrap?.call(selfWrap);
    }
    return true;
  }

  /// One wrap per member: classical leg to [encryptTo], KEM leg to their identity key; [onCoverage] reports PQ coverage.
  Future<bool> publishGroupMessage({
    required UnsignedEvent rumor,
    required List<String> recipients,
    required String Function(String memberPubkey) encryptTo,
    MessagingSettings settings = const MessagingSettings(),
    void Function(NostrEvent wrap)? onWrap,
    Uint8List? Function(String memberPubkey)? kemKeyFor,
    bool Function(String memberPubkey)? rootSeededFor,
    bool Function(String memberPubkey)? layeredFor,
    void Function(int pqCount, int total, int rootCount)? onCoverage,
    Iterable<String> newMembers = const [],
    String? queuedKey,
  }) async {
    final sig = signer;
    if (sig == null) return false;
    final fresh = {
      for (final pk in newMembers)
        if (recipients.contains(pk)) pk
    };
    if (fresh.isNotEmpty) {
      recipients = [
        ...recipients.where(fresh.contains),
        ...recipients.where((pk) => !fresh.contains(pk)),
      ];
    }
    final fanout = recipients.length;
    int tierFor(String pk) =>
        rumorTier(rumor, fanout, toNew: fresh.contains(pk));
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiration = settings.expirationFor(nowSec);
    final memberKem = kemKeyFor;
    final Uint8List? Function(String)? kemOf = memberKem == null
        ? null
        : (pk) => pk == identity.pubkey ? _pqTarget(pk).kem : memberKem(pk);
    bool layeredOf(String pk) => pk == identity.pubkey
        ? _pqTarget(pk).layered
        : (layeredFor?.call(pk) ?? false);

    // Local key: wrap the whole recipient list in one isolate hop; NIP-46 loops per recipient.
    if (sig is LocalSigner) {
      final targets = [for (final pk in recipients) encryptTo(pk)];
      // Keyed by encryption target, as wrapMany looks jobs up; the key comes from the real pubkey.
      final kemByTarget = <String, Uint8List>{};
      // Keyed by encryption target, as wrapMany looks jobs up.
      final layeredTargets = <String>{};
      var pqCount = 0;
      var rootCount = 0;
      if (kemOf != null) {
        for (var i = 0; i < recipients.length; i++) {
          final k = kemOf(recipients[i]);
          if (k != null) {
            kemByTarget[targets[i]] = k;
            pqCount++;
            if (rootSeededFor?.call(recipients[i]) ?? false) rootCount++;
            if (layeredOf(recipients[i])) {
              layeredTargets.add(targets[i]);
            }
          }
        }
      }
      final wraps = await _cryptoWorker.wrapMany(
        rumor: rumor,
        senderPrivkey: sig.privkey,
        recipientPubkeys: targets,
        expiration: expiration,
        recipientKemPks: kemByTarget.isEmpty ? null : kemByTarget,
        layeredPubkeys: layeredTargets.isEmpty ? null : layeredTargets,
      );
      for (var i = 0; i < wraps.length; i++) {
        final wrap = wraps[i];
        if (wrap != null) {
          if (queuedKey != null) {
            QueuedSends.instance.register(wrap.id, queuedKey);
          }
          publishDmQueued(wrap,
              tier: tierFor(i < recipients.length ? recipients[i] : ''));
          onWrap?.call(wrap);
        }
      }
      onCoverage?.call(pqCount, recipients.length, rootCount);
      return true;
    }

    // NIP-46: the seal can't be hybrid, but the wrap can; coverage counts the same.
    var remotePq = 0;
    var remoteRoot = 0;
    for (final pk in recipients) {
      final kem = kemOf?.call(pk);
      if (kem != null) {
        remotePq++;
        if (rootSeededFor?.call(pk) ?? false) remoteRoot++;
      }
      final wrap = await _wrapAndPublish(rumor, encryptTo(pk),
          expiration: expiration,
          recipientKemPublicKey: kem,
          layered: kem != null && layeredOf(pk),
          tier: tierFor(pk),
          queuedKey: queuedKey);
      if (wrap != null) onWrap?.call(wrap);
    }
    onCoverage?.call(remotePq, recipients.length, remoteRoot);
    return true;
  }

  /// Publishes a gift-wrapped kind-69420 delivery/read receipt.
  Future<bool> publishReceipt({
    String? messageId,
    List<String>? messageIds,
    required String receiptType, // 'delivered' | 'read'
    required String recipientPubkey,
    String? encryptToPubkey,
  }) async {
    final ids = messageIds ?? (messageId == null ? const <String>[] : [messageId]);
    if (ids.isEmpty) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.nymReceiptRumor,
      tags: [
        ['p', recipientPubkey],
        for (final id in ids) ['x', id],
        ['receipt', receiptType],
      ],
      content: '',
    );
    final pq = _pqTarget(recipientPubkey);
    final wrap = await _wrapAndPublish(rumor, encryptToPubkey ?? recipientPubkey,
        recipientKemPublicKey: pq.kem, layered: pq.layered);
    return wrap != null;
  }

  Future<bool> publishControlRumor({
    required List<List<String>> tags,
    required String recipientPubkey,
    String? encryptToPubkey,
    int? createdAt,
  }) async {
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: EventKind.nymReceiptRumor,
      tags: tags,
      content: '',
    );
    final pq = _pqTarget(recipientPubkey);
    final wrap = await _wrapAndPublish(rumor, encryptToPubkey ?? recipientPubkey,
        recipientKemPublicKey: pq.kem, layered: pq.layered);
    return wrap != null;
  }

  /// Publishes a gift-wrapped kind-69420 typing indicator; [groupId] adds a `g` tag.
  Future<bool> publishTyping({
    required String status, // 'start' | 'stop'
    required List<String> recipients,
    String? groupId,
    int ttlSec = 0,
    String? activity,
    String Function(String memberPubkey)? encryptTo,
  }) async {
    if (recipients.isEmpty) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tags = <List<String>>[
      ...UploadActivity.encode(status, activity, ttlSec),
      if (groupId != null) ['g', groupId],
    ];
    var any = false;
    for (final pk in recipients) {
      final rumor = UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.nymReceiptRumor,
        tags: [
          ...tags,
          if (groupId == null) ['p', pk],
        ],
        content: '',
      );
      final pq = _pqTarget(pk);
      final wrap = await _wrapAndPublish(rumor, encryptTo?.call(pk) ?? pk,
          recipientKemPublicKey: pq.kem, layered: pq.layered);
      any = any || wrap != null;
    }
    return any;
  }

  final Map<String, int> _channelTypingLastAt = {};

  /// Publishes a kind-24420 channel typing indicator with the channel `g`/`d` tag.
  Future<NostrEvent?> publishChannelTyping({
    required String status,
    required String channelKey,
    required String nym,
    bool isGeohash = true,
    String? activity,
  }) async {
    final sig = signer;
    if (sig == null) return null;
    final nowSec = max(DateTime.now().millisecondsSinceEpoch ~/ 1000,
        (_channelTypingLastAt[channelKey] ?? 0) + 1);
    _channelTypingLastAt[channelKey] = nowSec;
    final signed = await sig.sign(
      UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.channelTyping,
        tags: UploadActivity.channelTags(
            status, activity, isGeohash ? 'g' : 'd', channelKey, nym),
        content: '',
      ),
    );
    await pool.publish(signed);
    return signed;
  }

  /// Publishes a fire-and-forget kind-24421 channel read receipt; null without a signer.
  Future<NostrEvent?> publishChannelReceipt({
    required String messageId,
    required String authorPubkey,
    required String channelKey,
    required String nym,
    bool isGeohash = true,
  }) async {
    final sig = signer;
    if (sig == null) return null;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final signed = await sig.sign(
      UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.channelReceipt,
        tags: [
          ['e', messageId],
          ['p', authorPubkey],
          [isGeohash ? 'g' : 'd', channelKey],
          ['n', nym],
        ],
        content: '',
      ),
    );
    await pool.publish(signed);
    return signed;
  }

  /// Publishes kind-30078 presence; [mode] decides whether the real [status] or `hidden` goes public.
  Future<NostrEvent?> publishPresence({
    required String status, // 'online' | 'away' | 'hidden'
    required String nym,
    String awayMessage = '',
    PresenceStatusMode mode = PresenceStatusMode.enabled,
    String? avatarUrl,
    bool shopUpdate = false,
  }) async {
    final sig = signer;
    if (sig == null) return null;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tags = PresencePayload(
      nym: nym,
      status: status,
      awayMessage: awayMessage,
      mode: mode,
      avatarUrl: avatarUrl,
      shopUpdate: shopUpdate,
    ).tags();
    final signed = await sig.sign(
      UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.appData,
        tags: tags,
        content: '',
      ),
    );
    _queuePublish(signed);
    return signed;
  }

  /// Gift-wraps a kind-25054 real-status rumor to each friend; true if any wrap published.
  Future<bool> sendFriendPresence({
    required String status, // Real status: 'online' | 'away'.
    required String nym,
    required List<String> recipients,
    String awayMessage = '',
  }) async {
    if (signer == null || recipients.isEmpty) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tags = <List<String>>[
      ['status', status],
      ['n', nym],
      if (status == 'away' && awayMessage.isNotEmpty) ['away', awayMessage],
    ];
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.friendPresence,
      tags: tags,
      content: '',
    );
    var any = false;
    for (final pk in recipients) {
      final pq = _pqTarget(pk);
      final wrap = await _wrapAndPublish(rumor, pk,
          recipientKemPublicKey: pq.kem, layered: pq.layered);
      any = any || wrap != null;
    }
    return any;
  }

  /// Publishes a settings category as a self-addressed `nym-sync` wrap; null if oversized or unsignable.
  Future<NostrEvent?> publishNymSyncWrap({
    required Map<String, dynamic> payload,
    required String dTag,
    int? createdAt,
  }) async {
    final sig = signer;
    if (sig == null) return null;
    final self = identity.pubkey;
    final now = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Inner rumor: kind 30078, real created_at, id computed, no sig.
    final rumorTags = [
      ['d', dTag],
    ];
    final content = jsonEncode(payload);
    final rumorMap = <String, dynamic>{
      'id': NostrEvent(
        pubkey: self,
        createdAt: now,
        kind: EventKind.appData,
        tags: rumorTags,
        content: content,
      ).computeId(),
      'pubkey': self,
      'created_at': now,
      'kind': EventKind.appData,
      'tags': rumorTags,
      'content': content,
    };
    final rumorJson = jsonEncode(rumorMap);
    if (utf8.encode(rumorJson).length > 65535) return null;

    final outerD = sha256.convert(utf8.encode('$self:$dTag')).toString();

    // Builds both layers, off-isolate where keys allow (whole thing for local keys, wrap only for signers); null if oversized.
    Future<NostrEvent?> build(
      Future<String> Function(String plaintext) seal,
      Uint8List? wrapKemPk,
    ) async {
      final sealed = await sig.sign(
        UnsignedEvent(
          pubkey: self,
          createdAt: giftwrap.randomNow(),
          kind: 13,
          tags: const [],
          content: await seal(rumorJson),
        ),
      );
      final sealJson = jsonEncode(sealed.toJson());
      if (utf8.encode(sealJson).length > 65535) return null;
      final job = <String, dynamic>{
        'sealJson': sealJson,
        'self': self,
        'outerD': outerD,
        'kemPk': ?wrapKemPk,
      };
      Map<String, dynamic>? json;
      try {
        json = kIsWeb
            ? await wrapNymSyncSealIsolate(job)
            : await compute(wrapNymSyncSealIsolate, job);
      } catch (_) {
        json = await wrapNymSyncSealIsolate(job);
      }
      return json == null ? null : NostrEvent.fromJson(json);
    }

    // Layered PQ so signer logins get it too; settings carry more than most single messages.
    final selfKem = _pqSelfKeys.isEmpty ? null : _pqSelfKeys.first;

    // Local key: one compute hop for the whole construction, with the inline path as fallback.
    if (sig is LocalSigner) {
      try {
        final job = <String, dynamic>{
          'sk': keys.bytesToHex(sig.privkey),
          'self': self,
          'rumorJson': rumorJson,
          'outerD': outerD,
          if (selfKem != null) 'kemPk': selfKem.kemPk,
        };
        final json = kIsWeb
            ? await buildNymSyncWrapIsolate(job)
            : await compute(buildNymSyncWrapIsolate, job);
        if (json == null) return null;
        final wrapped = NostrEvent.fromJson(json);
        publishDmQueued(wrapped, tier: WrapTier.normal);
        return wrapped;
      } catch (_) {
        // Isolate failure: build inline below instead.
      }
    }

    if (selfKem != null) {
      final wrapped = await build(
        // Outer seal: the signer or local key produces the inner NIP-44.
        (pt) async => pq.pq2Seal(
            await sig.nip44Encrypt(self, pt), self, self, selfKem.kemPk),
        // The wrap layer uses a throwaway key, so it never needs the signer.
        selfKem.kemPk,
      );
      if (wrapped != null) {
        publishDmQueued(wrapped, tier: WrapTier.normal);
        return wrapped;
      }
      // An oversized hybrid falls back to classical rather than going unpublished.
    }

    final wrapped = await build(
      (pt) => sig.nip44Encrypt(self, pt),
      null, // Classical wrap layer.
    );
    if (wrapped == null) return null;
    publishDmQueued(wrapped, tier: WrapTier.normal);
    return wrapped;
  }

  // Geo relays

  /// bitchat geo-relay CSV, the fallback when the proxy `geo-relays` action is unavailable.
  static const String geoRelayCsvUrl =
      'https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv';

  /// Validator-gated copy that bitchat iOS reads, diverged from [geoRelayCsvUrl].
  static const String geoRelayVettedCsvUrl =
      'https://raw.githubusercontent.com/permissionlesstech/bitchat/refs/heads/main/relays/online_relays_gps.csv';

  /// Upstream (Android) and vetted (iOS) directories, kept apart since each client selects by its own rule.
  final List<GeoRelay> _geoRelaysUpstream = [];
  final List<GeoRelay> _geoRelaysVetted = [];

  /// All geo relays loaded so far.
  final List<GeoRelay> geoRelays = [];

  /// Geo relays for entered geohash channels: the only ones in low-data mode, else prioritized.
  final Set<String> currentGeoRelays = <String>{};

  /// Low-data mode: shard only defaults, DM relays and [currentGeoRelays]; set via [setLowDataMode].
  bool lowDataMode = false;

  /// Applies a low-data mode change, collapsing or restoring geo-relay coverage; no-op when unchanged.
  Future<void> setLowDataMode(bool enabled) async {
    if (lowDataMode == enabled) return;
    lowDataMode = enabled;
    if (enabled) {
      // Keep only the current channels' geo relays sharded.
      applyGeoRelays();
    } else {
      // Reconnect the full geo relay coverage.
      await loadAndApplyGeoRelays();
    }
  }

  /// SharedPreferences key for the persisted geo-relay directory.
  static const String geoRelayCacheKey = 'nym_geo_relays';

  /// Cached directory lifetime, 24h like bitchat on both platforms.
  static const Duration geoRelayCacheTtl = Duration(hours: 24);

  /// Decodes the persisted directory; null only when absent or unusable, never merely stale.
  static List<GeoRelay> _decodeGeoRelayList(Object? raw) {
    if (raw is! List) return const [];
    final out = <GeoRelay>[];
    for (final r in raw) {
      if (r is! Map) continue;
      final url = (r['url'] ?? '').toString();
      final lat = r['lat'], lng = r['lng'];
      if (url.isEmpty || lat is! num || lng is! num) continue;
      if (!lat.toDouble().isFinite || !lng.toDouble().isFinite) continue;
      out.add(GeoRelay(url: url, lat: lat.toDouble(), lng: lng.toDouble()));
    }
    return out;
  }

  Future<({DateTime fetchedAt, List<GeoRelay> relays, List<GeoRelay> vetted})?>
      _loadGeoRelayCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(geoRelayCacheKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final relays = _decodeGeoRelayList(decoded['relays']);
      if (relays.isEmpty) return null;
      final ms = decoded['fetchedAt'];
      return (
        fetchedAt:
            DateTime.fromMillisecondsSinceEpoch(ms is num ? ms.toInt() : 0),
        relays: relays,
        vetted: _decodeGeoRelayList(decoded['vetted']),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveGeoRelayCache(
      List<GeoRelay> relays, List<GeoRelay> vetted) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        geoRelayCacheKey,
        jsonEncode({
          'fetchedAt': DateTime.now().millisecondsSinceEpoch,
          'vetted': [
            for (final r in vetted) {'url': r.url, 'lat': r.lat, 'lng': r.lng},
          ],
          'relays': [
            for (final r in relays) {'url': r.url, 'lat': r.lat, 'lng': r.lng},
          ],
        }),
      );
    } catch (_) {
      // Storage unavailable: the in-memory directory still works this session.
    }
  }

  /// Fetches geo relays via the proxy, else the CSV; a fresh cached directory skips the network unless [force].
  Future<List<GeoRelay>> fetchGeoRelays({
    Future<String> Function(Uri url)? csvFetcher,
    bool force = false,
  }) async {
    final cached = await _loadGeoRelayCache();
    if (cached != null) {
      // Adopt the cache either way; if stale it covers the refresh and its failure.
      _adoptGeoRelays(cached.relays, cached.vetted);
      final age = DateTime.now().difference(cached.fetchedAt);
      if (!force && !age.isNegative && age < geoRelayCacheTtl) {
        return geoRelays;
      }
    }

    var dirs = await _apiClient.geoRelayDirectories();
    if (dirs.upstream.isEmpty && csvFetcher != null) {
      // Direct fallback; the vetted list is best-effort.
      try {
        final csv = await csvFetcher(Uri.parse(geoRelayCsvUrl));
        var vetted = const <GeoRelay>[];
        try {
          vetted = parseGeoRelaysCsv(
              await csvFetcher(Uri.parse(geoRelayVettedCsvUrl)));
        } catch (_) {
          // Additive only.
        }
        dirs = (upstream: parseGeoRelaysCsv(csv), vetted: vetted);
      } catch (_) {
        // Keep whatever we have.
      }
    }
    if (dirs.upstream.isNotEmpty) {
      _adoptGeoRelays(dirs.upstream, dirs.vetted);
      await _saveGeoRelayCache(dirs.upstream, dirs.vetted);
    }
    return geoRelays;
  }

  /// Installs both directories; [geoRelays] is their union for sharding.
  void _adoptGeoRelays(List<GeoRelay> upstream, List<GeoRelay> vetted) {
    _geoRelaysUpstream
      ..clear()
      ..addAll(upstream);
    _geoRelaysVetted
      ..clear()
      ..addAll(vetted);
    final byUrl = <String, GeoRelay>{};
    for (final r in upstream) {
      byUrl[r.url] = r;
    }
    for (final r in vetted) {
      byUrl.putIfAbsent(r.url, () => r);
    }
    geoRelays
      ..clear()
      ..addAll(byUrl.values);
  }

  /// Geo relay urls to shard: current ones only in low-data mode, else all with current first.
  List<String> _geoRelayUrlsForPool() {
    if (lowDataMode) return currentGeoRelays.toList();
    final urls = <String>[
      for (final r in geoRelays) r.url,
    ];
    final seen = urls.toSet();
    // Prepend the entered-channel geo relays, deduped.
    for (final url in currentGeoRelays) {
      if (!seen.contains(url)) {
        urls.insert(0, url);
        seen.add(url);
      }
    }
    return urls;
  }

  /// Pushes the current geo-relay set onto the live pool; the pool reconciles only the delta.
  void applyGeoRelays() => pool.updateGeoRelays(_geoRelayUrlsForPool());

  /// Fetches and shards geo relays once after [start]; no-op in low-data mode.
  Future<void> loadAndApplyGeoRelays({
    Future<String> Function(Uri url)? csvFetcher,
  }) async {
    if (geoRelays.isEmpty) {
      await fetchGeoRelays(csvFetcher: csvFetcher);
    }
    if (!lowDataMode) applyGeoRelays();
  }

  /// Entering a geohash channel: mark the closest geo relays current and shard them onto the pool.
  Future<void> connectGeoRelaysForGeohash(String geohash,
      {Future<String> Function(Uri url)? csvFetcher}) async {
    if (geohash.isEmpty) return;
    // Skip in group-chat/PM-only mode, as the PWA does.
    if (!_channelMode) return;
    if (geoRelays.isEmpty) {
      await fetchGeoRelays(csvFetcher: csvFetcher);
    }
    final closest = closestGeoRelays(geohash);
    if (closest.isEmpty) return;
    var changed = false;
    for (final r in closest) {
      if (currentGeoRelays.add(r.url)) changed = true;
    }
    // Re-shard when a new geo relay was introduced, or always in low-data mode.
    if (changed || lowDataMode) applyGeoRelays();
  }

  // Geo-relay keep-alive

  Timer? _geoKeepAliveTimer;
  String? _geoKeepAliveGeohash;

  String? get activeGeohash => _geoKeepAliveGeohash;

  /// Every 30s, re-adds the active geohash's closest relays if any dropped; restarted per channel entry.
  void startGeoRelayKeepAlive(String geohash) {
    _geoKeepAliveTimer?.cancel();
    _geoKeepAliveTimer = null;
    if (geohash.isEmpty || !ch.isValidGeohash(geohash)) {
      _geoKeepAliveGeohash = null;
      return;
    }
    _geoKeepAliveGeohash = geohash;
    _geoKeepAliveTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _geoKeepAliveTick());
  }

  void _geoKeepAliveTick() {
    final gh = _geoKeepAliveGeohash;
    if (gh == null) return;
    // No channel filters in PM-only mode.
    if (!_channelMode) return;
    final closest = closestGeoRelays(gh);
    if (closest.isEmpty) return;
    final present = pool.connectedRelayUrls;
    final anyMissing = closest.any((r) =>
        !present.contains(r.url) &&
        !RelayBlock.isBlocked(_blockedRelays, r.url));
    if (anyMissing) unawaited(connectGeoRelaysForGeohash(gh));
  }

  /// Stops the geo-relay keep-alive.
  void stopGeoRelayKeepAlive() {
    _geoKeepAliveTimer?.cancel();
    _geoKeepAliveTimer = null;
    _geoKeepAliveGeohash = null;
  }

  /// Admits kind-20000 geohash messages only from that geohash's nearest relays, failing open whenever it can't judge.
  bool geoOriginAllowsEvent(NostrEvent e, String? relayUrl) {
    if (e.kind != EventKind.geoChannel) return true;
    if (relayUrl == null || relayUrl.isEmpty) return true;
    final gh = e.tagValue('g')?.toLowerCase();
    if (gh == null || gh.isEmpty) return true;
    // decodeGeohash accepts junk characters, so validate first.
    if (!ch.isValidGeohash(gh)) return true;

    final closest = closestGeoRelays(gh);
    if (closest.isEmpty) return true;
    final allow = {for (final r in closest) r.url};
    if (allow.contains(relayUrl)) return true;

    final connected = pool.connectedRelayUrls;
    for (final u in allow) {
      if (connected.contains(u)) return false; // A source exists and this is not it.
    }
    return true;
  }

  List<GeoRelay> closestGeoRelays(String geohash,
      {int count = RelayConfig.geoRelayCount}) {
    if (geoRelays.isEmpty || geohash.isEmpty) return const [];
    final center = ch.decodeGeohash(geohash);

    // Compute distance once per relay and tiebreak explicitly: List.sort is unstable and ties are common.
    List<({GeoRelay relay, double distance, int index})> rank(
            List<GeoRelay> list) =>
        [
          for (var i = 0; i < list.length; i++)
            (
              relay: list[i],
              distance: ch.calculateDistance(
                  center.lat, center.lng, list[i].lat, list[i].lng),
              index: i,
            ),
        ];

    // bitchat-android's rule: distance only, ties by directory position.
    final upstream =
        rank(_geoRelaysUpstream.isNotEmpty ? _geoRelaysUpstream : geoRelays)
          ..sort((a, b) {
            final d = a.distance.compareTo(b.distance);
            return d != 0 ? d : a.index.compareTo(b.index);
          });

    // bitchat iOS's rule: (distance, host) ascending.
    final vetted = rank(_geoRelaysVetted)
      ..sort((a, b) {
        final d = a.distance.compareTo(b.distance);
        return d != 0 ? d : a.relay.url.compareTo(b.relay.url);
      });

    // Union of both clients' picks, since their directories rarely agree on the closest five.
    final out = <GeoRelay>[];
    final seen = <String>{};
    for (final r in [...upstream.take(count), ...vetted.take(count)]) {
      if (seen.add(r.relay.url)) out.add(r.relay);
    }
    return out;
  }

  String get selfPubkey => identity.pubkey;

  /// True when a local key or connected NIP-46 signer can sign.
  bool get canSign => signer != null;

  /// Generates a fresh secret key for ephemeral group keys.
  static Uint8List freshSecretKey() => keys.generatePrivateKey();

  static dynamic channelMessageFrom(NostrEvent e, String selfPubkey) =>
      EventMapper.channelMessage(e, selfPubkey: selfPubkey);

  Future<void> stop() async {
    _stopped = true;
    _dmOutbox.dispose();
    _retireAllMain();
    _statusTimer?.cancel();
    _quietTimer?.cancel();
    _quietTimer = null;
    _criticalResubTimer?.cancel();
    _criticalResubTimer = null;
    stopGeoRelayKeepAlive();
    _stopBgRestore();
    _poolFallbackActive = false;
    // Detach our api-stats sink if still active, so a disposed service catches no traffic.
    if (identical(ApiClient.apiStatsSink, _apiStats)) {
      ApiClient.apiStatsSink = null;
    }
    await _eventSub?.cancel();
    await _channelTypingSub?.close();
    for (final sub in _wrapCatchUpSubs.toList()) {
      await sub.close();
    }
    _wrapCatchUpSubs.clear();
    await _mainSub?.close();
    await pool.disconnectAll();
  }
}

/// Fair FIFO async semaphore; always pair acquire() with a finally release().
class _AsyncSemaphore {
  _AsyncSemaphore(this._permits) : assert(_permits > 0);

  int _permits;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_permits > 0) {
      _permits--;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _permits++;
    }
  }
}

class _QuietPool implements PoolTransport {
  _QuietPool(this._inner);

  final PoolTransport _inner;

  @override
  void closeSubscription(Subscription sub) => _inner.closeSubscription(sub);

  @override
  Subscription subscribe(List<NostrFilter> filters, {String? subId}) =>
      _inner.subscribe(filters, subId: subId);

  @override
  void connectAll() => _inner.connectAll();

  @override
  void updateGeoRelays(List<String> geoRelayUrls) =>
      _inner.updateGeoRelays(geoRelayUrls);

  @override
  Future<int> publish(NostrEvent event) async => 1;

  @override
  Future<int> publishDm(NostrEvent event) async => 1;

  @override
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls) async =>
      1;

  @override
  int get connectedCount => _inner.connectedCount;

  @override
  Set<String> get connectedRelayUrls => _inner.connectedRelayUrls;

  @override
  set geoOriginAllows(bool Function(NostrEvent event, String? relayUrl)? fn) =>
      _inner.geoOriginAllows = fn;

  @override
  RelayStats get stats => _inner.stats;

  @override
  Future<void> disconnectAll() => _inner.disconnectAll();
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';

import '../../core/constants/event_kinds.dart';
import '../../core/constants/relays.dart';
import '../../core/crypto/bitchat.dart' as bitchat;
import '../../core/crypto/crypto_worker.dart';
import '../../core/crypto/gift_wrap.dart' as giftwrap;
import '../../core/crypto/isolate_verifier.dart';
import '../../core/crypto/keys.dart' as keys;
import '../../core/crypto/nip44.dart' as nip44;
import '../../core/crypto/pow.dart';
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../features/messages/trust_graph.dart';
import '../../models/channel.dart' as ch;
import '../../models/nostr_event.dart';
import '../api/api_client.dart';
import '../api/api_config.dart';
import '../relay/relay_message.dart';
import '../relay/relay_pool.dart';
import '../relay/relay_pool_proxy.dart';
import '../relay/relay_stats.dart';
import 'event_mapper.dart';
import 'event_signer.dart';
import 'identity_service.dart';

/// Parses the bitchat geo-relay CSV (`host,lat,lng` rows) into [GeoRelay]s.
/// Mirrors `_parseGeoRelaysCsv` (relays.js:51): strips scheme + trailing
/// slashes, skips the header row and any row missing a host or coords.
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

/// A decrypted gift-wrap result handed to the controller for routing.
class GiftWrapUnwrapped {
  GiftWrapUnwrapped({
    required this.wrapId,
    required this.wrapCreatedAt,
    required this.rumor,
    required this.senderVerified,
    required this.isBitchat,
    this.rawWrap,
  });

  /// The kind-1059 gift-wrap event id (used as the message id).
  final String wrapId;
  final int wrapCreatedAt;

  /// The full signed kind-1059 wrap event as received off the relay. The PM D1
  /// archive (`pm-put`/`pm-deposit`, pms.js `_archivePMEvent`) re-uploads the
  /// untouched wrap, so the controller needs the original event JSON — the rumor
  /// alone is not storable. Null for the remote-signer unwrap path (the wrap is
  /// still available there, but archiving is best-effort).
  final Map<String, dynamic>? rawWrap;

  /// The decrypted inner rumor (kind 14 / 69420 / 7 …).
  final Map<String, dynamic> rumor;

  /// True when the NIP-59 seal was authenticated (`seal.pubkey==rumor.pubkey
  /// && verifyEvent(seal)`); bitchat wraps are unverified.
  final bool senderVerified;
  final bool isBitchat;

  int? get rumorKind => (rumor['kind'] as num?)?.toInt();
}

/// Settings the service needs for TTL / receipt scoping, passed in from the
/// controller so the service never imports the settings provider.
class MessagingSettings {
  const MessagingSettings({
    this.dmForwardSecrecyEnabled = false,
    this.dmTtlSeconds = 0,
  });

  final bool dmForwardSecrecyEnabled;
  final int dmTtlSeconds;

  /// The gift-wrap `expiration` ts (now + ttl) when forward secrecy is on, else
  /// null (docs/specs/03 §10).
  int? expirationFor(int nowSec) =>
      (dmForwardSecrecyEnabled && dmTtlSeconds > 0)
          ? nowSec + dmTtlSeconds
          : null;
}

/// The user's status-visibility mode, derived from the `nym_show_status`
/// setting ('true' | 'friends' | 'false'). Mirrors nostr-core.js `_statusMode`.
enum PresenceStatusMode {
  /// `showStatus === true`: broadcast the real status publicly.
  enabled,

  /// `showStatus === 'friends'`: broadcast `hidden` publicly, share real status
  /// privately with friends (the gift-wrapped friend presence path).
  friends,

  /// `showStatus === false`: never assert presence; broadcasts `hidden`.
  disabled,
}

/// Maps the native `showStatus` string ('true' | 'friends' | 'false') to the
/// PWA's `_statusMode()` result.
PresenceStatusMode presenceStatusModeFrom(String showStatus) {
  if (showStatus == 'false') return PresenceStatusMode.disabled;
  if (showStatus == 'friends') return PresenceStatusMode.friends;
  return PresenceStatusMode.enabled;
}

/// Pure builder for the kind-30078 nym-presence tag list. Mirrors the PWA's
/// `publishPresence` / `publishAvatarUpdate` / `publishShopUpdate` tag shapes so
/// every presence flavor shares the `['d','nym-presence'],['t','nym-presence']`
/// replaceable identity. Kept pure (no signing / IO) so it's unit-testable.
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
  final String status; // caller's real status: 'online' | 'away' | 'hidden'
  final String awayMessage;
  final PresenceStatusMode mode;
  final String? avatarUrl;

  /// Emits the bare `['shop-update','1']` cache-bust flag (the ONLY shop tag
  /// the protocol carries — `publishShopUpdate`, nostr-core.js:2876-2885).
  /// Receivers react by force-refreshing the sender's D1 `shop-status` record;
  /// the actual style/flair/cosmetics never ride the presence event.
  final bool shopUpdate;

  /// The status that actually goes on the public replaceable event. Only the
  /// `enabled` mode broadcasts the real status; otherwise `hidden` (PWA:
  /// `const publicStatus = mode === 'enabled' ? status : 'hidden'`).
  String get publicStatus =>
      mode == PresenceStatusMode.enabled ? status : 'hidden';

  List<List<String>> tags() {
    final out = <List<String>>[
      ['d', AppDataTopic.presence],
      ['t', AppDataTopic.presence],
      ['n', nym],
      ['status', publicStatus],
    ];
    // away message only when fully enabled + actually away (PWA gate).
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

/// Callbacks the service emits as it routes inbound events.
class NostrHandlers {
  NostrHandlers({
    this.onEvent,
    this.onConnectionChanged,
    this.onGiftWrap,
  });

  /// Every verified inbound event (already signature-checked by the pool).
  final void Function(NostrEvent event)? onEvent;
  final void Function(int connectedCount)? onConnectionChanged;

  /// A decrypted kind-1059 gift wrap addressed to us.
  final void Function(GiftWrapUnwrapped unwrapped)? onGiftWrap;
}

/// Owns the relay pool and wires it to the crypto + identity layers. Subscribes
/// to the channel/profile/reaction kinds and publishes channel messages.
/// (docs/specs/01 §4.5, 03 §2.2)
class NostrService {
  /// Process-wide off-thread signature verifier, shared by every transport this
  /// service builds (proxy, direct-fallback, restore probe) so a burst of
  /// inbound EVENTs across them coalesces into one isolate hop. Mirrors the
  /// PWA's single shared `verify-worker.js`. Stateless, so one instance is safe.
  static final IsolateVerifier _verifier = IsolateVerifier();

  /// Process-wide off-thread gift-wrap worker (the PWA's `crypto-pool.js`
  /// analog), shared so inbound unwrap bursts and outbound wrap fan-outs across
  /// every service instance coalesce. Stateless aside from its in-flight batch,
  /// so one instance is safe.
  static final CryptoWorker _cryptoWorker = CryptoWorker.instance;

  /// The [EventVerifier] handed to every pool: verify each inbound event off
  /// the main thread (batched). Preserves the per-event keep/drop contract the
  /// relay layer relies on — see [IsolateVerifier].
  static Future<bool> _verifyOffThread(NostrEvent event) =>
      _verifier.verify(event);

  /// Default constructor. [useProxy] selects the transport: when true (the
  /// native default per spec §4.2) the service runs over the multiplexed
  /// `RelayPoolProxy` (`wss://<host>/api/relay-pool`); when false it uses the
  /// direct [RelayPool]. An explicit [pool] overrides selection (tests).
  ///
  /// The injected [verify] is preserved across both transports.
  NostrService({
    required this.identity,
    EventSigner? signer,
    List<String>? relays,
    PoolTransport? pool,
    bool useProxy = true,
    ApiClient? apiClient,
  })  : _apiClient = apiClient ?? ApiClient(),
        _relays = relays,
        // An explicitly-injected pool (tests) disables the proxy→direct
        // auto-fallback: the caller owns the transport.
        _autoFallback = pool == null && useProxy,
        signer = signer ??
            (identity.privkey != null
                ? LocalSigner(identity.privkey!)
                : null),
        _pool = pool ??
            (useProxy
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
    // Route every ApiClient's /api traffic into our persistent api-stats object
    // so the Network Stats "App data" section is populated (mirrors the PWA's
    // single shared `nym.relayStats` that `_trackApiData` writes to). This is
    // process-wide (the PWA has one global); only the production proxy-default
    // path arms it — an injected pool / `useProxy:false` (tests) leaves the sink
    // untouched so unit tests stay isolated.
    if (_autoFallback) {
      ApiClient.apiStatsSink = _apiStats;
    }
  }

  /// Persistent /api traffic counters, kept on the service (NOT the pool) so the
  /// App-data tallies survive a proxy↔direct pool swap. Folded into the live
  /// relay stats by [relayStats]. Mirrors the PWA's `nym.relayStats` api fields.
  final RelayStats _apiStats = RelayStats();

  /// Factory: force the direct-WebSocket transport. Mirrors the PWA's
  /// `_poolFallbackActive` direct path — used when the relay pool fails.
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

  /// The active identity. Mutable so hardcore keypair mode can swap the signing
  /// key in place (see [rotateIdentity]) without tearing down the live relay
  /// connections — every publish reads `identity.pubkey` at call time.
  Identity identity;

  /// The active signer: a [LocalSigner] for nsec/ephemeral keys, a
  /// [Nip46SignerAdapter] for a remote signer, or null when signing is
  /// unavailable. Every publish / gift-wrap path routes through this so the
  /// NIP-46 remote path works end-to-end (mirrors the PWA's `signEvent`).
  /// Mutable for the same hardcore-rotation reason as [identity].
  EventSigner? signer;

  /// Surgically swap the signing identity in place — hardcore keypair mode
  /// (messages.js:2392-2404 → `generateKeypair()`, which only swaps `privkey`/
  /// `pubkey`; it does NOT reconnect relays or re-subscribe). The live [pool]
  /// and its subscriptions persist (the `#p:[self]` gift-wrap filter stays on
  /// the prior pubkey, exactly like the PWA), and the NEXT publish signs with
  /// [newSigner] / advertises [newIdentity].
  void rotateIdentity(Identity newIdentity, EventSigner? newSigner) {
    identity = newIdentity;
    signer = newSigner;
  }

  /// The active transport. Swappable: starts as the proxy (default) and is
  /// replaced by a direct [RelayPool] if the proxy proves unreachable (and back
  /// again if the proxy recovers). Read through the [pool] getter so callers
  /// always route through the CURRENT transport.
  PoolTransport _pool;

  /// The relay set this service was constructed with (null = defaults). Reused
  /// when building the direct-fallback / restored-proxy pools so the swap keeps
  /// the same relay coverage.
  final List<String>? _relays;

  /// True only for the production proxy-default path: enables the
  /// proxy→direct auto-fallback + background restore. An injected pool (tests)
  /// or `useProxy:false` leaves the transport fixed.
  final bool _autoFallback;

  final ApiClient _apiClient;

  /// The active transport (current pool after any swap).
  PoolTransport get pool => _pool;

  /// Live relay stats for the Network Stats modal, with the persistent /api
  /// "App data" counters folded in. The pool tracks relay traffic + shard info;
  /// the service-owned [_apiStats] tracks the backend traffic (so it survives
  /// pool swaps). Mirrors the PWA's single `nym.relayStats` (which holds both).
  /// Read a fresh merged snapshot each call.
  RelayStats get relayStats {
    final s = _pool.stats; // already a snapshot
    final api = _apiStats;
    if (!api.hasApiData) return s;
    // Fold the API byte totals + per-action breakdown into the relay snapshot.
    // (The pool's bytesSent/Received already excludes API traffic, so add it.)
    s.bytesReceived += api.apiBytesReceived;
    s.bytesSent += api.apiBytesSent;
    s.apiBytesReceived += api.apiBytesReceived;
    s.apiBytesSent += api.apiBytesSent;
    api.apiActionStats.forEach((action, st) {
      s.apiActionStats[action] = st.copy();
    });
    return s;
  }

  /// True when the active transport is the multiplexed proxy pool. Reflects the
  /// CURRENT pool, so it flips to false after a fallback to direct and back to
  /// true after a background proxy restore.
  bool get isProxyMode => _pool is RelayPoolProxy;

  /// True while running on the direct-relay fallback (proxy was unreachable).
  /// Mirrors the PWA's `_poolFallbackActive`.
  bool _poolFallbackActive = false;
  bool get isFallbackActive => _poolFallbackActive;

  /// Background timer + attempt counter for restoring proxy mode after a
  /// fallback (mirrors `_schedulePoolReconnectInBackground`, relays.js:1610).
  Timer? _bgRestoreTimer;
  int _bgRestoreAttempts = 0;
  bool _bgRestoreInFlight = false;

  /// Guards [_swapPool] so overlapping triggers (multiple shard callbacks, or a
  /// restore racing a fallback) can't run two swaps at once.
  bool _swapping = false;

  Subscription? _mainSub;
  StreamSubscription<NostrEvent>? _eventSub;
  Timer? _statusTimer;
  NostrHandlers? _handlers;

  /// Connects to relays and subscribes to the core message kinds plus the
  /// gift-wrap (kind 1059, `#p:[self]`) and presence (kind 30078) feeds.
  Future<void> start(NostrHandlers handlers) async {
    _handlers = handlers;
    _wireProxyFallback();
    pool.connectAll();

    // REQ windows mirror the PWA's `_buildCriticalFilters` (relays.js:2485-2570).
    // When the D1 archive is reachable (the API host is configured — always true
    // in production), the relay-pool proxy has ALREADY archived history to D1, so
    // we ask relays for ONLY new live events (`since = now`) and collapse history
    // to `limit: 1`; the full backlog is restored from D1 by the controller's
    // `backfillFromD1OnReconnect`. Without D1 we fall back to a 24h relay window.
    // (This is the fix for "data should be pulled from D1, not re-REQ'd 1h from
    // relays on every connect".)
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final d1Available = ApiConfig.apiHost.isNotEmpty;
    final liveSince = d1Available ? nowSec : nowSec - 86400;
    int lim(int n) => d1Available ? 1 : n;
    final self = identity.pubkey;
    final filters = [
      // Channels (20000/23333): real-time `since` only, no limit
      // (relays.js:2497-2498).
      NostrFilter(
          kinds: [EventKind.geoChannel, EventKind.namedChannel],
          since: liveSince),
      // Channel reactions (kind 7, `#k:[20000,23333]`) (relays.js:2506).
      NostrFilter(
        kinds: [EventKind.reaction],
        since: liveSince,
        limit: lim(100),
        tags: {
          'k': ['${EventKind.geoChannel}', '${EventKind.namedChannel}'],
        },
      ),
      // Public NIP-57 zap receipts addressed to us (kind 9735, `#p:[self]`): the
      // recipient is always p-tagged, so this catches receipts for OUR authored
      // channel/profile messages — both the LNURL provider's (verified) receipt
      // and a peer's own-published kind-9735 (zaps.js `_publishOwnMessageZapEvent`).
      // Collapses to since=now/limit:1 under D1 (relays.js:2517); history from D1.
      NostrFilter(
        kinds: [EventKind.zapReceipt],
        since: liveSince,
        limit: lim(200),
        tags: {
          'p': [self],
        },
      ),
      // Gift wraps addressed to us (PMs, group messages, receipts, typing).
      // NIP-59 backdates created_at, so NO `since`; cap at limit:1 under D1
      // (relays.js:2494) — the PM/group backlog is restored from D1.
      NostrFilter(
        kinds: [EventKind.giftWrap],
        limit: d1Available ? 1 : 500,
        tags: {
          'p': [self],
        },
      ),
      // Presence (nym-presence): real-time only under D1 (relays.js:2528).
      NostrFilter(
        kinds: [EventKind.appData],
        since: d1Available ? nowSec : null,
        limit: lim(100),
        tags: {
          't': [AppDataTopic.presence],
        },
      ),
      // NIP-30 custom emoji packs (kind 30030): real-time + limit:1 under D1
      // (history via the D1 emoji restore); else discover up to 300
      // (relays.js:2546). Plus the user's own emoji-pack list (kind 10030).
      NostrFilter(
          kinds: [EventKind.emojiPack],
          since: d1Available ? nowSec : null,
          limit: d1Available ? 1 : 300),
      NostrFilter(
        kinds: [EventKind.userEmojiList],
        authors: [self],
        limit: 1,
      ),
    ];

    _mainSub = pool.subscribe(filters);
    _eventSub = _mainSub!.events.listen(_routeInbound);

    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      handlers.onConnectionChanged?.call(pool.connectedCount);
    });
    handlers.onConnectionChanged?.call(pool.connectedCount);

    // Fetch the geo-relay list and shard it onto the pool so geohash channels
    // connect to the closest geo relays (the P0 fix: without this the proxy is
    // built with NO geo shards and geohash subscriptions are never delivered).
    // Fire-and-forget — boot must not block on the proxy `geo-relays` round-trip;
    // a slow/failed fetch just leaves the pool on its default+critical shards
    // until the next channel entry retries. Mirrors the PWA's `_geoRelaysReady`
    // → `_poolSendRelayConfig` once the list arrives.
    unawaited(loadAndApplyGeoRelays().catchError((_) {}));
  }

  // ---------------------------------------------------------------------------
  // Proxy → direct fallback + background restore.
  //
  // The proxy (`wss://<host>/api/relay-pool`) is the DEFAULT transport. When it
  // can't establish a connection (host-lookup / socket errors before it EVER
  // confirms — e.g. the relay-pool host is unreachable on a real device), the
  // PWA falls back to DIRECT relay connections after 2 consecutive pool failures
  // and keeps trying to restore pool mode in the background (relays.js
  // `_fallbackToDirectConnections` / `_schedulePoolReconnectInBackground`). This
  // ports that: it swaps `_pool` to a direct [RelayPool], replays every live
  // subscription onto it (so channel / PM / gift-wrap feeds resume seamlessly),
  // then periodically retries a fresh proxy and swaps back if it comes up.
  // ---------------------------------------------------------------------------

  /// Wire the active pool's [RelayPoolProxy.onProxyUnreachable] to the
  /// fall-back-to-direct swap (no-op unless [_autoFallback] and the pool is a
  /// proxy). Re-invoked whenever a new proxy is constructed (initial + restore).
  void _wireProxyFallback() {
    if (!_autoFallback) return;
    final p = _pool;
    if (p is RelayPoolProxy) {
      p.onProxyUnreachable = _onProxyUnreachable;
    }
  }

  /// The proxy reported it can't reach its endpoint (2 consecutive pre-connect
  /// failures). Swap to a direct [RelayPool] and start the background restore.
  void _onProxyUnreachable() {
    if (!_autoFallback || _poolFallbackActive) return;
    _poolFallbackActive = true;
    final direct = RelayPool(
      relays: _relays ?? RelayConfig.defaultRelays,
      writeOnlyRelays: RelayConfig.writeOnlyRelays,
      verify: _verifyOffThread,
    );
    unawaited(_swapToDirect(direct));
  }

  /// Forward fallback: replace the proxy with the freshly-built direct [pool]
  /// (not yet connected). Tears the old proxy's SOCKETS down (keeping the live
  /// `Subscription` objects alive), connects [pool], and replays every active
  /// subscription onto it so its `events` stream keeps flowing. Then arms the
  /// background proxy-restore loop.
  Future<void> _swapToDirect(RelayPool direct) async {
    if (_swapping) return;
    _swapping = true;
    try {
      final old = _pool;

      // Snapshot the live subscriptions from the OLD pool's registry. This
      // captures BOTH service-created subs and any created directly via
      // `service.pool.subscribe(...)` (e.g. the controller's P2P sub), because
      // they all registered on the pool. Reuse the same `Subscription` objects
      // so every existing `events.listen(...)` downstream keeps receiving.
      final live = _activeSubsOf(old);

      // Detach the old pool's sockets without closing the subscriptions.
      await _detachSockets(old);

      // Bring up the direct pool and replay every live subscription on it (same
      // objects → same streams; the sub's dedup makes replay idempotent).
      _pool = direct;
      direct.connectAll();
      for (final entry in live.values) {
        direct.replaySubscription(entry.sub, entry.filters);
      }

      // Re-establish geo-relay coverage on the new transport (direct mode opens
      // a direct socket per geo url) so geohash channels keep working across the
      // swap.
      applyGeoRelays();

      // The mainSub object is unchanged, so _eventSub keeps routing inbound.
      debugPrint('[NostrService] proxy unreachable; swapped proxy → direct '
          '(${live.length} subs replayed)');

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

  Future<void> _detachSockets(PoolTransport p) async {
    if (p is RelayPoolProxy) {
      p.onProxyUnreachable = null; // don't let a teardown close fire the trigger
      await p.disconnectSocketsOnly();
    } else if (p is RelayPool) {
      await p.disconnectSocketsOnly();
    } else {
      await p.disconnectAll();
    }
  }

  /// Background restore cadence, mirroring `_schedulePoolReconnectInBackground`
  /// (relays.js:1610): first retry after 15s, then exponential backoff
  /// `min(15000 * 2^min(n-1,4), 120000)` with 50–100% jitter.
  void _scheduleBgRestore() {
    if (!_autoFallback || !_poolFallbackActive) return;
    if (_bgRestoreInFlight) return;
    _bgRestoreTimer?.cancel();
    final delay = _bgRestoreAttempts == 0
        ? const Duration(seconds: 15)
        : _bgRestoreBackoff(_bgRestoreAttempts);
    _bgRestoreTimer = Timer(delay, _tryRestoreProxy);
  }

  Duration _bgRestoreBackoff(int attempts) {
    final expIdx = min(attempts - 1, 4);
    final base = min(15000 * pow(2, expIdx).toInt(), 120000);
    // 50–100% jitter (relays.js `_jitter`).
    final jittered = (base * (0.5 + _bgRng.nextDouble() * 0.5)).floor();
    return Duration(milliseconds: jittered);
  }

  final Random _bgRng = Random();

  /// Try a fresh [RelayPoolProxy] connect in the background; if it CONFIRMS
  /// (reaches a connected POOL:STATUS), swap back to proxy mode. Otherwise the
  /// probe's own unreachable trigger reschedules the next attempt.
  void _tryRestoreProxy() {
    _bgRestoreTimer = null;
    if (!_poolFallbackActive) return;
    _bgRestoreAttempts++;
    _bgRestoreInFlight = true;

    // A short-lived probe proxy: if it confirms, we adopt it as the live pool
    // (already connected) and replay subs onto it. If it can't reach the host
    // (its own onProxyUnreachable fires), we discard it and back off.
    late final RelayPoolProxy probe;
    probe = RelayPoolProxy(
      relays: _relays ?? RelayConfig.defaultRelays,
      dmRelays: RelayConfig.defaultRelays,
      verify: _verifyOffThread,
      onProxyUnreachable: () {
        // Probe failed to reach the host — drop it and schedule the next try.
        _bgRestoreInFlight = false;
        unawaited(probe.disconnectAll());
        _scheduleBgRestore();
      },
    );
    probe.onProxyConnected = () {
      // Probe reached the host: promote it to the live transport.
      if (!_poolFallbackActive) {
        // A concurrent restore already happened; discard this probe.
        unawaited(probe.disconnectAll());
        return;
      }
      _bgRestoreInFlight = false;
      _bgRestoreAttempts = 0;
      // The probe is already connected; swap WITHOUT re-running connectAll on it
      // by handing it over as the live pool and replaying subs.
      unawaited(_adoptRestoredProxy(probe));
    };
    probe.connectAll();
  }

  /// Promote a probe proxy that has already confirmed connectivity to the live
  /// transport: replay the direct pool's live subscriptions onto it and tear the
  /// direct sockets down. (The probe is already connected, so unlike
  /// [_swapToDirect] we do NOT call `connectAll` again — we replay directly.)
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
      restored.onProxyUnreachable = _onProxyUnreachable; // future blips
      for (final entry in live.values) {
        restored.replaySubscription(entry.sub, entry.filters);
      }
      _poolFallbackActive = false;
      _stopBgRestore();
      // Re-shard the geo relays onto the restored proxy so geohash channels
      // keep their geo coverage after swapping back.
      applyGeoRelays();
      debugPrint('[NostrService] proxy restored; swapped direct → proxy '
          '(${live.length} subs replayed)');
      _handlers?.onConnectionChanged?.call(_pool.connectedCount);
    } finally {
      _swapping = false;
    }
  }

  void _stopBgRestore() {
    _bgRestoreTimer?.cancel();
    _bgRestoreTimer = null;
    _bgRestoreInFlight = false;
    _bgRestoreAttempts = 0;
  }

  /// Subscribes the active channel's typing/read-receipt feed (kinds 24420 /
  /// 24421, `#g` for geohash channels). Closes any previous channel-typing sub.
  /// (docs/specs/03 §1.4) Returns the [Subscription].
  Subscription? _channelTypingSub;
  String? _channelTypingKey;
  Subscription subscribeChannelTyping(String geohash, {bool isGeohash = true}) {
    if (_channelTypingKey == geohash && _channelTypingSub != null) {
      return _channelTypingSub!;
    }
    _channelTypingSub?.close();
    final since = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;
    final sub = pool.subscribe([
      NostrFilter(
        kinds: [EventKind.channelTyping, EventKind.channelReceipt],
        since: since,
        tags: {
          if (isGeohash) 'g': [geohash] else 'd': [geohash],
        },
      ),
    ]);
    final s = sub.events.listen((e) => _handlers?.onEvent?.call(e));
    sub.eose.then((_) => null);
    _channelTypingSub = sub;
    _channelTypingKey = geohash;
    // Route typing events through onEvent; cancellation handled on close.
    s.onError((_) {});
    return sub;
  }

  /// Adds ephemeral group pubkeys as additional `#p` gift-wrap subscriptions so
  /// rotated-key group messages reach us. Best-effort; auto-managed by the
  /// controller as keys rotate.
  Subscription subscribeEphemeral(List<String> ephemeralPubkeys) {
    return pool.subscribe([
      NostrFilter(
        kinds: [EventKind.giftWrap],
        tags: {'p': ephemeralPubkeys},
      ),
    ]);
  }

  /// Routes an inbound verified event: gift wraps are unwrapped + emitted via
  /// [NostrHandlers.onGiftWrap]; everything else flows through [onEvent].
  void _routeInbound(NostrEvent event) {
    if (event.kind == EventKind.giftWrap) {
      unawaited(_handleGiftWrap(event));
      return;
    }
    _handlers?.onEvent?.call(event);
  }

  /// Candidate secret keys for unwrap: our identity key plus any registered
  /// ephemeral group keys.
  List<({Uint8List sk, bool bitchat})> _candidates() {
    final out = <({Uint8List sk, bool bitchat})>[];
    final sk = identity.privkey;
    if (sk != null) out.add((sk: sk, bitchat: true));
    for (final esk in _ephemeralSks) {
      out.add((sk: esk, bitchat: false));
    }
    return out;
  }

  /// Registered ephemeral secret keys (current + previous group keys) supplied
  /// by the controller so rotated-key wraps can be decrypted.
  final List<Uint8List> _ephemeralSks = [];

  void setEphemeralKeys(List<Uint8List> sks) {
    _ephemeralSks
      ..clear()
      ..addAll(sks);
  }

  /// Unwraps a kind-1059 gift wrap restored from the D1 PM archive and routes it
  /// through the normal [NostrHandlers.onGiftWrap] path (pms.js
  /// `_pmRestoreD1Page` → `handleGiftWrapDM(ev, {fromD1:true})`). The controller's
  /// session dedup keeps the archive upload a no-op for restored wraps, so the
  /// same handler can be reused safely.
  void unwrapArchivedWrap(NostrEvent wrap) {
    if (wrap.kind != EventKind.giftWrap) return;
    unawaited(_handleGiftWrap(wrap));
  }

  Future<void> _handleGiftWrap(NostrEvent wrap) async {
    final handlers = _handlers;
    if (handlers?.onGiftWrap == null) return;
    final candidates = _candidates();

    // Remote-signer (NIP-46) path: no local identity key is available, so the
    // wrap addressed to *our* identity pubkey must be unwrapped via the remote
    // `nip44_decrypt` RPC for both the wrap and the seal layers (the wrap is
    // addressed to our identity key; the seal is between sender and us). Group
    // ephemeral keys are still local and handled by [candidates] above.
    final sig = signer;
    if (sig != null && sig.isRemote && _isAddressedToSelf(wrap)) {
      final res = await _unwrapRemote(wrap, sig);
      if (res != null) {
        _emitUnwrapped(handlers!, wrap, res.seal, res.rumor, isBitchat: false);
        return;
      }
    }

    if (candidates.isEmpty) return;
    // Local-key unwrap: per-DM ECDH + ChaCha20 + triple jsonDecode, looped over
    // candidate keys. Bursts to ~1000 wraps on PM backfill, so run it off the
    // main isolate via the shared crypto worker (the PWA's `crypto-pool.js`
    // analog). The worker runs the SAME [giftwrap.unwrapGiftWrap] inside an
    // isolate, preserving per-candidate try/next + the null-on-undecryptable
    // skip, and falls back to the inline path on web / on isolate failure.
    final res = await _cryptoWorker.unwrap(wrap, candidates);
    if (res == null) return;

    _emitUnwrapped(handlers!, wrap, res.seal, res.rumor,
        isBitchat: res.isBitchat);
  }

  /// True when [wrap] is addressed (`['p', …]`) to our identity pubkey (vs an
  /// ephemeral group key). Used to gate the remote-decrypt path.
  bool _isAddressedToSelf(NostrEvent wrap) {
    final self = identity.pubkey;
    for (final t in wrap.tags) {
      if (t.length > 1 && t[0] == 'p' && t[1] == self) return true;
    }
    return false;
  }

  /// Unwraps a self-addressed gift [wrap] via the remote signer's
  /// `nip44_decrypt` RPC (NIP-46): decrypt the wrap content (sealed by the
  /// ephemeral wrap key to our identity key), then the seal content (between the
  /// sender and us). Returns null on any failure (try the local candidates).
  Future<({NostrEvent seal, Map<String, dynamic> rumor})?> _unwrapRemote(
    NostrEvent wrap,
    EventSigner sig,
  ) async {
    try {
      final sealJson = await sig.nip44Decrypt(wrap.pubkey, wrap.content);
      final seal = NostrEvent.fromJson(
          jsonDecode(sealJson) as Map<String, dynamic>);
      final rumorJson = await sig.nip44Decrypt(seal.pubkey, seal.content);
      final rumor = jsonDecode(rumorJson) as Map<String, dynamic>;
      return (seal: seal, rumor: rumor);
    } catch (_) {
      return null;
    }
  }

  /// Verifies the seal authorship (NIP-59 sender auth) and emits the unwrapped
  /// rumor through [handlers]. Shared by the local + remote unwrap paths.
  void _emitUnwrapped(
    NostrHandlers handlers,
    NostrEvent wrap,
    NostrEvent seal,
    Map<String, dynamic> rumor, {
    required bool isBitchat,
  }) {
    final rumorPubkey = rumor['pubkey'] as String?;
    if (rumorPubkey == null || rumorPubkey.isEmpty) return;

    // NIP-59 sender auth: native seals must be signed by the claimed author.
    var senderVerified = true;
    var emitRumor = rumor;
    if (isBitchat) {
      senderVerified = false;
      // bitchat-app PMs carry a `bitchat1:` BitchatPacket as the rumor content
      // (NoisePayload TLV), not plain text. Decode it the way the PWA's
      // `parseBitchatMessage` does so the actual message text reaches the UI;
      // without this the message renders as the raw `bitchat1:…` blob.
      // Non-message payloads (delivery/read receipts) are not rumors to show —
      // drop them rather than ingesting a blank PM.
      final decoded = _decodeBitchatRumor(rumor);
      if (decoded == null) return;
      emitRumor = decoded;
    } else {
      if (seal.pubkey != rumorPubkey || !schnorr.verifyEvent(seal)) {
        return; // forged
      }
    }

    handlers.onGiftWrap!(GiftWrapUnwrapped(
      wrapId: wrap.id,
      wrapCreatedAt: wrap.createdAt,
      rumor: emitRumor,
      senderVerified: senderVerified,
      isBitchat: isBitchat,
      rawWrap: wrap.toJson(),
    ));
  }

  /// Normalizes a bitchat-app rumor for emission. When the rumor `content` is a
  /// `bitchat1:` BitchatPacket it is decoded (PWA `parseBitchatMessage`): a
  /// PRIVATE_MESSAGE yields a copy whose `content` is the decoded text (with the
  /// bitchat message id added as an `['x', id]` tag for dedup/receipts when the
  /// rumor lacks one); a receipt/other payload returns null so the caller drops
  /// it instead of surfacing a blank message. A non-`bitchat1:` content (e.g. a
  /// Nymchat rumor delivered over a bitchat wrap) is returned unchanged.
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

  /// Requests recent kind-0 profiles for [pubkeys] (best-effort, auto-closing).
  void fetchProfiles(List<String> pubkeys) {
    if (pubkeys.isEmpty) return;
    final sub = pool.subscribe([
      NostrFilter(kinds: [EventKind.profile], authors: pubkeys, limit: pubkeys.length),
    ]);
    final s = sub.events.listen((e) => _handlers?.onEvent?.call(e));
    sub.eose.then((_) {
      s.cancel();
      sub.close();
    });
  }

  /// Publishes a channel message (kind 20000/23333) per docs/specs/03 §2.2.
  /// Returns the signed event (with its id) or null if the identity can't sign.
  Future<NostrEvent?> publishChannelMessage({
    required String channelKey,
    required String content,
    required String nym,
    String? geohash,
    List<List<String>> emojiTags = const [],
    int powDifficulty = 0,
    EventSigner? signerOverride,
  }) async {
    // [signerOverride] is the pseudonymous-send path: a fresh per-message
    // ephemeral key (publishMessagePseudonymous) so the message is unlinkable to
    // the durable identity. Default = the logged-in signer.
    final sig = signerOverride ?? signer;
    if (sig == null) return null;

    final isGeo = geohash != null && geohash.isNotEmpty;
    final kind = isGeo ? EventKind.geoChannel : EventKind.namedChannel;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final tags = <List<String>>[
      ['n', nym],
      ['ms', '$nowMs'],
      [isGeo ? 'g' : 'd', isGeo ? geohash : channelKey],
      // NIP-30: declare any custom emoji used in the message so other clients
      // render them (messages.js `customEmojiTagsForContent`).
      ...emojiTags,
    ];

    // Channel messages carry the Nymchat NIP-13 PoW floor (and any higher user
    // setting) — the self-attestation the web-of-trust uses to tell a Nymchat
    // client from spam (PWA `max(userPow, nymchatPowFloor)`). Mined off the main
    // thread, then signed by the (local or remote) signer.
    final difficulty =
        powDifficulty > kNymchatPowFloor ? powDifficulty : kNymchatPowFloor;
    final mined = await mineNonce(
      UnsignedEvent(
        pubkey: sig.pubkey,
        createdAt: nowSec,
        kind: kind,
        tags: tags,
        content: content,
      ),
      difficulty,
    );
    final signed = await sig.sign(mined);

    // Geohash channel messages (kind 20000 with a `g` tag) route through
    // GEO_EVENT so the proxy prioritizes the closest geo relays; the proxy
    // falls back to a plain EVENT when no closest relays are known
    // (relays.js `broadcastEvent`). Named channels publish plainly.
    if (isGeo) {
      final closest =
          closestGeoRelays(geohash).map((r) => r.url).toList(growable: false);
      await pool.publishGeo(signed, closest);
    } else {
      await pool.publish(signed);
    }
    return signed;
  }

  /// Publishes a public channel reaction (kind 7) per docs/specs/03 §5.1.
  /// Tags: `['e',messageId], ['p',targetPubkey], ['k',originalKind]` plus the
  /// NIP-30 [emojiTags] for a custom `:shortcode:` reaction (reactions.js
  /// :990-995/:1111-1117 spread `...customEmojiTagsForContent(emoji)` into
  /// both the add and remove tag lists), a `['g',geohash]` (geohash channel)
  /// or `['d',channel]` (named channel) tag, and `['action','remove']` when
  /// [remove] is set. Returns the signed event.
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
      // NIP-30: declare the custom emoji so other clients can render the
      // :shortcode: (emoji.js `customEmojiTagsForContent`).
      ...emojiTags,
    ];
    // Carry the channel id so the relay/D1 archive can key the reaction
    // (reactions.js: geohash → ['g',gh]; else named → ['d',channel]).
    if (originalKind == '20000' && geohash != null && geohash.isNotEmpty) {
      tags.add(['g', geohash]);
    } else if (originalKind == '23333' && channel != null && channel.isNotEmpty) {
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
    await pool.publish(signed);
    return signed;
  }

  /// Publishes a kind-30078 poll-create or poll-vote event (already-built
  /// [rumor] from [PollLogic]). Returns the signed event with its id.
  Future<NostrEvent?> publishPollEvent(UnsignedEvent rumor) async {
    final sig = signer;
    if (sig == null) return null;
    final signed = await sig.sign(rumor);
    await pool.publish(signed);
    return signed;
  }

  /// Publishes our kind-30078 `nym-vouches` list (web-of-trust). Mirrors
  /// nostr-core.js `publishNymchatVouches` (line 2645): a parameterized
  /// replaceable event tagged `['d','nym-vouches'],['t','nym-vouches']` whose
  /// content is the JSON array of pubkeys we've observed running Nymchat, so
  /// other clients can expand their trust graph through us. No-op for an empty
  /// list (the PWA returns early when `list.length === 0`). Returns the signed
  /// event, or null when there's nothing to publish / no signer.
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

  /// (Re)subscribes to peers' kind-30078 `nym-vouches` lists, authored by the
  /// pubkeys currently in our trust graph ([nymchatPubkeys]). Mirrors the PWA's
  /// REQ (relays.js:2538-2542): `{ kinds:[30078], "#t":["nym-vouches"], authors:
  /// trusted-pubkeys-intersect-hex64-capped-500, limit: authors.length }`.
  /// Ingesting a trusted peer's vouches grows the graph one hop; the controller
  /// calls this again (debounced) when new authors appear, so the web of trust
  /// expands and then goes quiet. Returns null when there are no valid authors.
  Subscription? subscribeVouches(Iterable<String> nymchatPubkeys) {
    final authors = nymchatPubkeys
        .where(TrustGraph.isHex64)
        .take(_vouchAuthorCap)
        .toList();
    if (authors.isEmpty) return null;
    _vouchSub?.close();
    final sub = pool.subscribe([
      NostrFilter(
        kinds: [EventKind.appData],
        authors: authors,
        tags: {
          't': [AppDataTopic.vouches],
        },
        limit: authors.length,
      ),
    ]);
    _vouchSub = sub;
    sub.events.listen(_routeInbound);
    return sub;
  }

  /// Author cap on the vouch REQ (relays.js:2539 `.slice(0, 500)`).
  static const int _vouchAuthorCap = 500;

  Subscription? _vouchSub;

  /// Publishes a kind-0 profile metadata event with [content] (the JSON-encoded
  /// profile object). Returns the signed event. (docs/specs/03 §Appendix A)
  Future<NostrEvent?> publishProfile(String content) async {
    final sig = signer;
    if (sig == null) return null;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final signed = await sig.sign(
      UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.profile,
        tags: const [],
        content: content,
      ),
    );
    await pool.publish(signed);
    return signed;
  }

  /// Publishes a NIP-57 kind-9734 zap request (already-built [rumor] from
  /// [ZapLogic.buildZapRequest]). Returns the signed event so the caller can
  /// pass it to the LNURL callback's `nostr` param.
  Future<NostrEvent?> publishZapRequest(UnsignedEvent rumor) async {
    final sig = signer;
    if (sig == null) return null;
    final signed = await sig.sign(rumor);
    await pool.publish(signed);
    return signed;
  }

  /// Publishes OUR OWN signed kind-9735 zap-receipt for a CHANNEL message we
  /// paid, so peers' (and the recipient's) live `#k`/`#p` subscriptions update
  /// the zap badge in real time. Mirrors zaps.js `_publishOwnMessageZapEvent`
  /// (line 1527): the LNURL provider's receipt carries no top-level `k` tag and
  /// never matches those subs, so we mint a receipt that does. Tags:
  /// `['e',messageId], ['p',recipientPubkey], ['k',originalKind],
  /// ['bolt11',bolt11]` (+ `['g',geohash]` for a geohash channel, else
  /// `['d',channel]` for a named channel), content `''`. For a geohash channel
  /// it's additionally delivered to the closest geo relays (like
  /// [publishChannelMessage]). Returns the signed event so the controller can
  /// register its id (own-echo dedup) and route ingestion.
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
      // Carry the channel id so the relay/D1 archive can key the receipt
      // (zaps.js: geohash → ['g',gh]; else named → ['d',channel]).
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

  /// Gift-wraps [rumor] to each of [recipients] (one wrap per recipient,
  /// NIP-59) and publishes them. Used for private reactions / private zap
  /// announcements / call signaling. Returns true if any wrap was published.
  Future<bool> publishGiftWrappedRumor({
    required UnsignedEvent rumor,
    required List<String> recipients,
    String Function(String memberPubkey)? encryptTo,
    int? expiration,
  }) async {
    if (signer == null || recipients.isEmpty) return false;
    var any = false;
    for (final pk in recipients) {
      final wrap = await _wrapAndPublish(
        rumor,
        encryptTo?.call(pk) ?? pk,
        expiration: expiration,
      );
      any = any || wrap != null;
    }
    return any;
  }

  // ---------------------------------------------------------------------------
  // Gift-wrapped publish paths (PM / group / receipt / typing) + presence.
  // ---------------------------------------------------------------------------

  /// Builds the signed kind-1059 gift wrap of [rumor] for [recipientPubkey],
  /// choosing the off-thread worker for a [LocalSigner] and the remote-capable
  /// async path for a NIP-46 signer.
  ///
  /// For a [LocalSigner] the whole wrap (seal + ephemeral wrap) is pure local
  /// crypto, so it runs on the shared [_cryptoWorker] isolate (the PWA's
  /// `crypto-pool.js` analog) — the worker generates the ephemeral wrap key
  /// inside the isolate and runs the SAME `nip59Wrap`, producing a wrap
  /// indistinguishable from the synchronous path. For a NIP-46 remote signer
  /// the **seal** must round-trip the network (`nip44_encrypt` + `sign_event`),
  /// so that path stays on [giftwrap.nip59WrapAsync] as before.
  Future<NostrEvent?> _buildWrap(
    UnsignedEvent rumor,
    String recipientPubkey, {
    int? expiration,
  }) async {
    final sig = signer;
    if (sig == null) return null;
    if (sig is LocalSigner) {
      return _cryptoWorker.wrapOne(
        rumor: rumor,
        senderPrivkey: sig.privkey,
        recipientPubkey: recipientPubkey,
        expiration: expiration,
      );
    }
    // Remote (NIP-46) signer: seal via the remote RPCs; the wrap layer still
    // uses a fresh local ephemeral key.
    return giftwrap.nip59WrapAsync(
      rumor: rumor,
      senderSigner: sig,
      recipientPubkey: recipientPubkey,
      expiration: expiration,
    );
  }

  /// Gift-wraps [rumor] to [recipientPubkey] (NIP-59) and publishes it. Returns
  /// the wrap event, or null if we can't sign.
  Future<NostrEvent?> _wrapAndPublish(
    UnsignedEvent rumor,
    String recipientPubkey, {
    int? expiration,
  }) async {
    final wrap = await _buildWrap(rumor, recipientPubkey, expiration: expiration);
    if (wrap == null) return null;
    // Gift wraps (kind 1059) publish via DM_EVENT so the proxy gives them
    // priority to the default relays (relays.js `sendDMToRelays`). In direct
    // mode this is a plain publish (the PoolTransport default).
    await pool.publishDm(wrap);
    return wrap;
  }

  /// Publishes a NIP-17 PM rumor to the recipient AND a self-copy (so own
  /// messages restore across devices). Honors TTL via [settings].
  /// (docs/specs/03 §3.1–§3.2)
  Future<bool> publishPM({
    required UnsignedEvent rumor,
    required String recipientPubkey,
    MessagingSettings settings = const MessagingSettings(),
  }) async {
    if (signer == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiration = settings.expirationFor(nowSec);

    await _wrapAndPublish(rumor, recipientPubkey, expiration: expiration);
    if (recipientPubkey != identity.pubkey) {
      await _wrapAndPublish(rumor, identity.pubkey, expiration: expiration);
    }
    return true;
  }

  /// Publishes a group rumor: one gift wrap per [recipients], each encrypted to
  /// the supplied per-member [encryptTo] pubkey (ephemeral when known).
  /// (docs/specs/03 §4.3)
  Future<bool> publishGroupMessage({
    required UnsignedEvent rumor,
    required List<String> recipients,
    required String Function(String memberPubkey) encryptTo,
    MessagingSettings settings = const MessagingSettings(),
  }) async {
    final sig = signer;
    if (sig == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiration = settings.expirationFor(nowSec);

    // Group fan-out is the worst multiplier — one full wrap (ECDH + sign) per
    // recipient, right on the send tap. For a local key, ship the WHOLE
    // recipient list to the worker in a single isolate hop (loop runs inside the
    // isolate, one ephemeral key per recipient), then publish each result. The
    // remote (NIP-46) path can't batch (each seal is a network RPC), so it keeps
    // the per-recipient loop.
    if (sig is LocalSigner) {
      final targets = [for (final pk in recipients) encryptTo(pk)];
      final wraps = await _cryptoWorker.wrapMany(
        rumor: rumor,
        senderPrivkey: sig.privkey,
        recipientPubkeys: targets,
        expiration: expiration,
      );
      for (final wrap in wraps) {
        if (wrap != null) await pool.publishDm(wrap);
      }
      return true;
    }

    for (final pk in recipients) {
      await _wrapAndPublish(rumor, encryptTo(pk), expiration: expiration);
    }
    return true;
  }

  /// Publishes a gift-wrapped delivery/read receipt (kind 69420) for
  /// [messageId] to [recipientPubkey]. (docs/specs/03 §10)
  Future<bool> publishReceipt({
    required String messageId,
    required String receiptType, // 'delivered' | 'read'
    required String recipientPubkey,
    String? encryptToPubkey,
  }) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.nymReceiptRumor,
      tags: [
        ['p', recipientPubkey],
        ['x', messageId],
        ['receipt', receiptType],
      ],
      content: '',
    );
    final wrap = await _wrapAndPublish(rumor, encryptToPubkey ?? recipientPubkey);
    return wrap != null;
  }

  /// Publishes a gift-wrapped typing indicator (kind 69420) to each recipient.
  /// [groupId] is set for group typing (adds a `['g', …]` tag).
  Future<bool> publishTyping({
    required String status, // 'start' | 'stop'
    required List<String> recipients,
    String? groupId,
    String Function(String memberPubkey)? encryptTo,
  }) async {
    if (recipients.isEmpty) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tags = <List<String>>[
      ['typing', status],
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
      final wrap = await _wrapAndPublish(rumor, encryptTo?.call(pk) ?? pk);
      any = any || wrap != null;
    }
    return any;
  }

  /// Publishes a public channel typing indicator (kind 24420) for a geohash
  /// channel. (docs/specs/03 §10)
  Future<NostrEvent?> publishChannelTyping({
    required String status,
    required String geohash,
    required String nym,
  }) async {
    final sig = signer;
    if (sig == null) return null;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final signed = await sig.sign(
      UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.channelTyping,
        tags: [
          ['typing', status],
          ['g', geohash],
          ['n', nym],
        ],
        content: '',
      ),
    );
    await pool.publish(signed);
    return signed;
  }

  /// Publishes a public channel read receipt (kind 24421) for [messageId] by
  /// [authorPubkey] in the geohash [geohash]. Mirrors the PWA's
  /// `sendChannelReadReceipt` (nostr-core.js): tags are
  /// `['e', messageId]`, `['p', authorPubkey]`, `['g', geohash]`, `['n', nym]`.
  /// Ephemeral kind — relays don't store it, so it's fire-and-forget. Returns
  /// the signed event (null when there is no signer).
  Future<NostrEvent?> publishChannelReceipt({
    required String messageId,
    required String authorPubkey,
    required String geohash,
    required String nym,
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
          ['g', geohash],
          ['n', nym],
        ],
        content: '',
      ),
    );
    await pool.publish(signed);
    return signed;
  }

  /// Publishes a kind-30078 nym-presence event. (docs/specs/03 §2.5,
  /// nostr-core.js `publishPresence`).
  ///
  /// [status] is the caller's real status (`online`/`away`/`hidden`); the
  /// *public* status actually broadcast is computed by [PresencePayload] from
  /// [mode]: only the `enabled` mode broadcasts the real status, otherwise
  /// `hidden` goes out so non-friends see nothing (PWA: `publicStatus`).
  ///
  /// [avatarUrl] mirrors `publishAvatarUpdate` and [shopUpdate] mirrors
  /// `publishShopUpdate` (the bare `['shop-update','1']` cache-bust flag);
  /// combining them in one event matches the PWA's single-replaceable-event
  /// shape (all share `['d','nym-presence']`).
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
    await pool.publish(signed);
    return signed;
  }

  /// Friends-only private presence (nostr-core.js `_sendFriendPresence`):
  /// gift-wraps a kind-25054 presence rumor (carrying the *real* [status]) to
  /// each friend so only they can read it, while the public kind-30078 stays
  /// `hidden`. [recipients] is the friend pubkey set (the controller filters out
  /// self / empties). Returns true if any wrap was published.
  Future<bool> sendFriendPresence({
    required String status, // real status: 'online' | 'away'
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
      final wrap = await _wrapAndPublish(rumor, pk);
      any = any || wrap != null;
    }
    return any;
  }

  /// Publishes one settings category as a self-addressed NIP-59 `nym-sync`
  /// gift wrap (`_publishWrappedNostrEvent`, settings.js:599-663): an unsigned
  /// kind-30078 rumor tagged `['d', dTag]` whose content is the payload JSON,
  /// sealed (kind 13) to self through the active signer (so a NIP-46 remote
  /// signer works, mirroring the PWA's extension/NIP-46 branch), then wrapped
  /// (kind 1059) by a fresh ephemeral key with the outer tags
  /// `['p', self], ['d', sha256('<pubkey>:<dTag>')], ['k','nym-sync']` — relays
  /// only ever see the opaque per-account digest (`_syncOuterDTag`,
  /// settings.js:177-184).
  ///
  /// Size guards match the PWA byte-for-byte: a rumor or seal whose JSON
  /// exceeds the 65535-byte NIP-44 plaintext limit, or a final `["EVENT",…]`
  /// frame over 65000 chars (`_sendWrappedIfFits`, settings.js:590-596), skips
  /// the publish. The wrap goes out via the DM path (`sendDMToRelays`).
  /// Returns the wrap event, or null when skipped / unsignable.
  Future<NostrEvent?> publishNymSyncWrap({
    required Map<String, dynamic> payload,
    required String dTag,
    int? createdAt,
  }) async {
    final sig = signer;
    if (sig == null) return null;
    final self = identity.pubkey;
    final now = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Inner rumor: kind 30078, real created_at, id computed, no sig
    // (settings.js:604-611).
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

    // Seal (kind 13) encrypted + signed by the active signer, backdated
    // created_at like every NIP-59 seal (`randomNow`).
    final sealContent = await sig.nip44Encrypt(self, rumorJson);
    final seal = await sig.sign(
      UnsignedEvent(
        pubkey: self,
        createdAt: giftwrap.randomNow(),
        kind: 13,
        tags: const [],
        content: sealContent,
      ),
    );
    final sealJson = jsonEncode(seal.toJson());
    if (utf8.encode(sealJson).length > 65535) return null;

    // Wrap (kind 1059) by a fresh ephemeral key with the nym-sync outer tags.
    final ephSk = keys.generatePrivateKey();
    final ckWrap = nip44.getConversationKey(ephSk, self);
    final outerD = sha256.convert(utf8.encode('$self:$dTag')).toString();
    final wrapped = schnorr.finalizeEvent(
      UnsignedEvent(
        pubkey: keys.getPublicKeyHex(ephSk),
        createdAt: giftwrap.randomNow(),
        kind: EventKind.giftWrap,
        tags: [
          ['p', self],
          ['d', outerD],
          ['k', 'nym-sync'],
        ],
        content: nip44.encrypt(sealJson, ckWrap),
      ),
      ephSk,
    );
    if (jsonEncode(['EVENT', wrapped.toJson()]).length > 65000) return null;
    await pool.publishDm(wrapped);
    return wrapped;
  }

  // ---------------------------------------------------------------------------
  // Geo relays (spec §4.7 / relays.js fetchGeoRelays + getClosestRelaysForGeohash)
  // ---------------------------------------------------------------------------

  /// The bitchat geo-relay CSV (same source the proxy mirrors). Used as a
  /// fallback when the proxy `geo-relays` action is unavailable.
  static const String geoRelayCsvUrl =
      'https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv';

  /// All geo relays loaded so far (lazily fetched).
  final List<GeoRelay> geoRelays = [];

  /// Geo relays for the geohash channels the user has actually entered. In
  /// low-data mode these are the ONLY geo relays sharded onto the pool (the full
  /// list is skipped); otherwise they're prepended to the full list for priority.
  /// Mirrors the PWA's `currentGeoRelays` (relays.js:205).
  final Set<String> currentGeoRelays = <String>{};

  /// Low-Data Mode: when true the pool only carries defaults + DM relays + the
  /// [currentGeoRelays] for entered channels (geo relays load on demand);
  /// otherwise every geo relay is sharded onto the pool up front. Mirrors
  /// `settings.lowDataMode` (relays.js:1907/1978). Set by the controller from
  /// the live setting via [setLowDataMode]; defaults to false (the PWA default).
  bool lowDataMode = false;

  /// Applies a Low Data Mode change (`applyLowDataMode`, relays.js:350-399;
  /// invoked by the PWA on every settings save / toggle flip, app.js:3989 and
  /// :7268). Enabling collapses the relay set to the 5 defaults + DM relays +
  /// the entered channels' on-demand geo relays (in pool mode
  /// `_poolSendRelayConfig` respects lowDataMode — here [applyGeoRelays] does,
  /// via [_geoRelayUrlsForPool]); disabling fetches the full geo-relay list if
  /// needed and re-shards everything back on. Call once at boot with the
  /// persisted setting (before/after [start] both work) and again on every
  /// flip. No-op when the mode is unchanged.
  Future<void> setLowDataMode(bool enabled) async {
    if (lowDataMode == enabled) return;
    lowDataMode = enabled;
    if (enabled) {
      // Keep only the current channels' geo relays sharded
      // (relays.js:352-368).
      applyGeoRelays();
    } else {
      // Reconnect the full broadcast + geo relay coverage
      // (relays.js:371-399).
      await loadAndApplyGeoRelays();
    }
  }

  /// Fetches the geo relay list via the API proxy (`action=geo-relays`),
  /// falling back to a direct CSV fetch+parse. Caches into [geoRelays].
  Future<List<GeoRelay>> fetchGeoRelays({
    Future<String> Function(Uri url)? csvFetcher,
  }) async {
    var relays = await _apiClient.geoRelays();
    if (relays.isEmpty && csvFetcher != null) {
      try {
        final csv = await csvFetcher(Uri.parse(geoRelayCsvUrl));
        relays = parseGeoRelaysCsv(csv);
      } catch (_) {
        // keep whatever we have
      }
    }
    if (relays.isNotEmpty) {
      geoRelays
        ..clear()
        ..addAll(relays);
    }
    return geoRelays;
  }

  /// The geo-relay url list to shard onto the pool right now, mirroring
  /// `_computeExpectedShards` (relays.js:1905): in low-data mode only the
  /// [currentGeoRelays] for entered channels; otherwise every fetched geo relay
  /// with the current ones prepended for priority.
  List<String> _geoRelayUrlsForPool() {
    if (lowDataMode) return currentGeoRelays.toList();
    final urls = <String>[
      for (final r in geoRelays) r.url,
    ];
    final seen = urls.toSet();
    // Prepend the entered-channel geo relays (priority), de-duped.
    for (final url in currentGeoRelays) {
      if (!seen.contains(url)) {
        urls.insert(0, url);
        seen.add(url);
      }
    }
    return urls;
  }

  /// Push the current geo-relay set onto the live pool so geohash-channel
  /// subscriptions reach the closest geo relays (proxy: geo shards; direct:
  /// direct geo sockets). Safe to call repeatedly — the pool reconciles only
  /// the delta. Mirrors `_poolSendRelayConfig()` (relays.js:212/355).
  void applyGeoRelays() => pool.updateGeoRelays(_geoRelayUrlsForPool());

  /// Fetch the geo-relay list (if not already loaded) and shard it onto the
  /// live pool. Call once after [start] connects so geohash channels work from
  /// the first entry. No-op in low-data mode (geo relays load on channel entry
  /// via [connectGeoRelaysForGeohash]). Mirrors the PWA loading `_geoRelaysReady`
  /// then `_poolSendRelayConfig` once the list arrives.
  Future<void> loadAndApplyGeoRelays({
    Future<String> Function(Uri url)? csvFetcher,
  }) async {
    if (geoRelays.isEmpty) {
      await fetchGeoRelays(csvFetcher: csvFetcher);
    }
    if (!lowDataMode) applyGeoRelays();
  }

  /// Entering a geohash channel: pick the [RelayConfig.geoRelayCount] closest
  /// geo relays, mark them current, and shard them onto the live pool so the
  /// channel's subscription is delivered to them. Fetches the geo-relay list
  /// first if needed. Faithful port of `connectToGeoRelays` (relays.js:179).
  Future<void> connectGeoRelaysForGeohash(String geohash,
      {Future<String> Function(Uri url)? csvFetcher}) async {
    if (geohash.isEmpty) return;
    if (geoRelays.isEmpty) {
      await fetchGeoRelays(csvFetcher: csvFetcher);
    }
    final closest = closestGeoRelays(geohash);
    if (closest.isEmpty) return;
    var changed = false;
    for (final r in closest) {
      if (currentGeoRelays.add(r.url)) changed = true;
    }
    // Re-shard whenever the channel introduced a new geo relay (or always in
    // low-data mode, where the pool otherwise carries no geo relays).
    if (changed || lowDataMode) applyGeoRelays();
  }

  /// Picks the [count] geo relays closest to [geohash]'s center using the
  /// Haversine distance (`calculateDistance`, channel.dart). Mirrors
  /// `getClosestRelaysForGeohash`.
  List<GeoRelay> closestGeoRelays(String geohash,
      {int count = RelayConfig.geoRelayCount}) {
    if (geoRelays.isEmpty || geohash.isEmpty) return const [];
    final center = ch.decodeGeohash(geohash);
    final sorted = [...geoRelays]..sort((a, b) {
        final da = ch.calculateDistance(center.lat, center.lng, a.lat, a.lng);
        final db = ch.calculateDistance(center.lat, center.lng, b.lat, b.lng);
        return da.compareTo(db);
      });
    return sorted.take(count).toList();
  }

  /// Exposes the identity pubkey for the controller.
  String get selfPubkey => identity.pubkey;

  /// True when this identity can sign (a signer is present — a local key or a
  /// connected NIP-46 remote signer). Mirrors the PWA's `_canSendGiftWraps` /
  /// `_canPublishChannelEvent` (privkey OR remote signer connected).
  bool get canSign => signer != null;

  /// Generates a fresh secret key (for ephemeral group keys).
  static Uint8List freshSecretKey() => keys.generatePrivateKey();

  /// Convenience: parse a channel message from a raw event.
  static dynamic channelMessageFrom(NostrEvent e, String selfPubkey) =>
      EventMapper.channelMessage(e, selfPubkey: selfPubkey);

  Future<void> stop() async {
    _statusTimer?.cancel();
    _stopBgRestore();
    _poolFallbackActive = false;
    // Detach our api-stats sink if it's still the active one (avoid a stale
    // disposed-service object catching later ApiClient traffic).
    if (identical(ApiClient.apiStatsSink, _apiStats)) {
      ApiClient.apiStatsSink = null;
    }
    await _eventSub?.cancel();
    await _channelTypingSub?.close();
    await _vouchSub?.close();
    await _mainSub?.close();
    await pool.disconnectAll();
  }
}

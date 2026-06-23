import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/constants/event_kinds.dart';
import '../../core/constants/relays.dart';
import '../../core/crypto/gift_wrap.dart' as giftwrap;
import '../../core/crypto/keys.dart' as keys;
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/channel.dart' as ch;
import '../../models/nostr_event.dart';
import '../api/api_client.dart';
import '../relay/relay_message.dart';
import '../relay/relay_pool.dart';
import '../relay/relay_pool_proxy.dart';
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

/// The self user's active shop cosmetics, carried on a presence broadcast so
/// other clients can render flair without a shop-backend round-trip.
///
/// NOTE: the PWA's `publishShopUpdate` only emits `['shop-update','1']` as a
/// cache-bust signal and the actual style/flair/supporter are fetched from the
/// D1 shop backend (`shop-get-active`). The native build has no shop backend
/// wired, so — in addition to the faithful `['shop-update','1']` tag — these
/// values are inlined as extra presence tags so flair still renders.
/// TODO(verify): confirm this tag extension is acceptable, or wire a native
/// shop-status fetch to match the PWA's backend-driven flow exactly.
class PresenceCosmetics {
  const PresenceCosmetics({this.style, this.flair, this.supporter = false});

  final String? style; // active message-style id
  final String? flair; // active nickname-flair id
  final bool supporter;

  bool get isEmpty =>
      (style == null || style!.isEmpty) &&
      (flair == null || flair!.isEmpty) &&
      !supporter;
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
    this.cosmetics,
  });

  final String nym;
  final String status; // caller's real status: 'online' | 'away' | 'hidden'
  final String awayMessage;
  final PresenceStatusMode mode;
  final String? avatarUrl;
  final bool shopUpdate;
  final PresenceCosmetics? cosmetics;

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
      // Native-only cosmetic inlining (see PresenceCosmetics doc / TODO).
      final c = cosmetics;
      if (c != null) {
        if (c.style != null && c.style!.isNotEmpty) {
          out.add(['shop-style', c.style!]);
        }
        if (c.flair != null && c.flair!.isNotEmpty) {
          out.add(['shop-flair', c.flair!]);
        }
        if (c.supporter) out.add(['shop-supporter', '1']);
      }
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
        signer = signer ??
            (identity.privkey != null
                ? LocalSigner(identity.privkey!)
                : null),
        pool = pool ??
            (useProxy
                ? RelayPoolProxy(
                    relays: relays ?? RelayConfig.defaultRelays,
                    dmRelays: RelayConfig.defaultRelays,
                    verify: (e) async => schnorr.verifyEvent(e),
                  )
                : RelayPool(
                    relays: relays ?? RelayConfig.defaultRelays,
                    writeOnlyRelays: RelayConfig.writeOnlyRelays,
                    verify: (e) async => schnorr.verifyEvent(e),
                  ));

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

  final Identity identity;

  /// The active signer: a [LocalSigner] for nsec/ephemeral keys, a
  /// [Nip46SignerAdapter] for a remote signer, or null when signing is
  /// unavailable. Every publish / gift-wrap path routes through this so the
  /// NIP-46 remote path works end-to-end (mirrors the PWA's `signEvent`).
  final EventSigner? signer;

  final PoolTransport pool;
  final ApiClient _apiClient;

  /// True when the active transport is the multiplexed proxy pool.
  bool get isProxyMode => pool is RelayPoolProxy;

  Subscription? _mainSub;
  StreamSubscription<NostrEvent>? _eventSub;
  Timer? _statusTimer;
  NostrHandlers? _handlers;

  /// Connects to relays and subscribes to the core message kinds plus the
  /// gift-wrap (kind 1059, `#p:[self]`) and presence (kind 30078) feeds.
  Future<void> start(NostrHandlers handlers) async {
    _handlers = handlers;
    pool.connectAll();

    final since = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;
    final self = identity.pubkey;
    final filters = [
      NostrFilter(kinds: [EventKind.geoChannel, EventKind.namedChannel], since: since),
      NostrFilter(
        kinds: [EventKind.reaction],
        since: since,
        tags: {
          'k': ['${EventKind.geoChannel}', '${EventKind.namedChannel}'],
        },
      ),
      // Gift wraps addressed to us (PMs, group messages, receipts, typing).
      NostrFilter(
        kinds: [EventKind.giftWrap],
        tags: {
          'p': [self],
        },
      ),
      // Presence (nym-presence) — kept minimal.
      NostrFilter(
        kinds: [EventKind.appData],
        since: since,
        tags: {
          't': [AppDataTopic.presence],
        },
      ),
    ];

    _mainSub = pool.subscribe(filters);
    _eventSub = _mainSub!.events.listen(_routeInbound);

    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      handlers.onConnectionChanged?.call(pool.connectedCount);
    });
    handlers.onConnectionChanged?.call(pool.connectedCount);
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
    final res = await giftwrap.unwrapGiftWrap(wrap, candidates);
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
    if (isBitchat) {
      senderVerified = false;
    } else {
      if (seal.pubkey != rumorPubkey || !schnorr.verifyEvent(seal)) {
        return; // forged
      }
    }

    handlers.onGiftWrap!(GiftWrapUnwrapped(
      wrapId: wrap.id,
      wrapCreatedAt: wrap.createdAt,
      rumor: rumor,
      senderVerified: senderVerified,
      isBitchat: isBitchat,
      rawWrap: wrap.toJson(),
    ));
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
  }) async {
    final sig = signer;
    if (sig == null) return null;

    final isGeo = geohash != null && geohash.isNotEmpty;
    final kind = isGeo ? EventKind.geoChannel : EventKind.namedChannel;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final tags = <List<String>>[
      ['n', nym],
      ['ms', '$nowMs'],
      [isGeo ? 'g' : 'd', isGeo ? geohash : channelKey],
    ];

    final signed = await sig.sign(
      UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: kind,
        tags: tags,
        content: content,
      ),
    );

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
  /// Tags: `['e',messageId], ['p',targetPubkey], ['k',originalKind]` plus a
  /// `['g',geohash]` (geohash channel) or `['d',channel]` (named channel) tag,
  /// and `['action','remove']` when [remove] is set. Returns the signed event.
  Future<NostrEvent?> publishReaction({
    required String messageId,
    required String targetPubkey,
    required String emoji,
    required String originalKind, // '20000' | '23333' | '1059'
    String? geohash,
    String? channel,
    bool remove = false,
  }) async {
    final sig = signer;
    if (sig == null) return null;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tags = <List<String>>[
      ['e', messageId],
      ['p', targetPubkey],
      ['k', originalKind],
      if (remove) ['action', 'remove'],
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

  /// Gift-wraps [rumor] to [recipientPubkey] (NIP-59) and publishes it. Returns
  /// the wrap event, or null if we can't sign.
  Future<NostrEvent?> _wrapAndPublish(
    UnsignedEvent rumor,
    String recipientPubkey, {
    int? expiration,
  }) async {
    final sig = signer;
    if (sig == null) return null;
    // Route through the async, signer-driven wrap so a NIP-46 remote signer
    // seals via its `nip44_encrypt` + `sign_event` RPCs; the wrap layer always
    // uses a fresh local ephemeral key. For a [LocalSigner] this is equivalent
    // to the sync `nip59Wrap` (same seal author + conversation key).
    final wrap = await giftwrap.nip59WrapAsync(
      rumor: rumor,
      senderSigner: sig,
      recipientPubkey: recipientPubkey,
      expiration: expiration,
    );
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
    if (signer == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiration = settings.expirationFor(nowSec);
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

  /// Publishes a kind-30078 nym-presence event. (docs/specs/03 §2.5,
  /// nostr-core.js `publishPresence`).
  ///
  /// [status] is the caller's real status (`online`/`away`/`hidden`); the
  /// *public* status actually broadcast is computed by [PresencePayload] from
  /// [mode]: only the `enabled` mode broadcasts the real status, otherwise
  /// `hidden` goes out so non-friends see nothing (PWA: `publicStatus`).
  ///
  /// [avatarUrl] mirrors `publishAvatarUpdate` and [shopUpdate]/[cosmetics]
  /// mirror `publishShopUpdate`; combining them in one event matches the PWA's
  /// single-replaceable-event shape (all share `['d','nym-presence']`).
  Future<NostrEvent?> publishPresence({
    required String status, // 'online' | 'away' | 'hidden'
    required String nym,
    String awayMessage = '',
    PresenceStatusMode mode = PresenceStatusMode.enabled,
    String? avatarUrl,
    bool shopUpdate = false,
    PresenceCosmetics? cosmetics,
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
      cosmetics: cosmetics,
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

  // ---------------------------------------------------------------------------
  // Geo relays (spec §4.7 / relays.js fetchGeoRelays + getClosestRelaysForGeohash)
  // ---------------------------------------------------------------------------

  /// The bitchat geo-relay CSV (same source the proxy mirrors). Used as a
  /// fallback when the proxy `geo-relays` action is unavailable.
  static const String geoRelayCsvUrl =
      'https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv';

  /// All geo relays loaded so far (lazily fetched).
  final List<GeoRelay> geoRelays = [];

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
    await _eventSub?.cancel();
    await _channelTypingSub?.close();
    await _mainSub?.close();
    await pool.disconnectAll();
  }
}

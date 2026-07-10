import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crypto/bech32_codec.dart' as bech32;
import '../core/crypto/bitchat.dart' as bitchat;
import '../core/crypto/keys.dart' as keys;
import '../core/crypto/pow.dart' as pow;
import '../core/crypto/schnorr.dart' as schnorr;
import '../core/constants/event_kinds.dart';
import '../core/constants/relays.dart';
import '../core/constants/storage_keys.dart';
import '../core/theme/nym_colors.dart';
import '../core/utils/nym_utils.dart';
import '../features/calls/call_providers.dart';
import '../features/commands/action_rate_limit.dart';
import '../features/commands/command_handler.dart';
import '../features/commands/command_registry.dart';
import '../features/emoji/custom_emoji.dart';
import '../features/groups/group_logic.dart';
import '../features/groups/group_manager.dart';
import '../features/messages/trust_graph.dart';
import '../features/notifications/notifications_service.dart';
import '../features/shop/shop_controller.dart';
import '../features/nymbot/bot_commands.dart';
import '../features/nymbot/nymbot_providers.dart';
import '../features/p2p/p2p_models.dart';
import '../features/p2p/p2p_service.dart';
import '../features/pms/pm_logic.dart';
import '../features/polls/poll_logic.dart';
import '../features/zaps/lnurl.dart';
import '../features/zaps/zap_archive.dart';
import '../features/zaps/zap_logic.dart';
import '../services/api/api_client.dart';
import '../services/api/storage_sync.dart';
import '../services/relay/relay_message.dart';
import '../services/relay/relay_pool.dart';
import '../services/relay/relay_pool_proxy.dart';
import '../services/relay/relay_stats.dart';
import '../models/channel.dart';
import '../models/group.dart';
import '../models/message.dart';
import '../models/nostr_event.dart';
import '../models/poll.dart';
import '../models/settings.dart';
import '../models/user.dart';
import '../features/identity/dev_nsec_modal.dart' show isReservedNick;
import '../features/identity/nip46_service.dart';
import '../features/identity/panic_wipe.dart';
import '../features/identity/vault_settings_modal.dart'
    show identityVaultProvider;
import '../services/nostr/event_mapper.dart';
import '../services/nostr/event_signer.dart';
import '../services/nostr/identity_service.dart';
import '../services/nostr/nostr_service.dart';
import '../services/nostr/nym_generator.dart';
import '../services/storage/cache_store.dart';
import '../services/storage/key_value_store.dart';
import '../services/storage/secure_store.dart';
import 'app_state.dart';
import 'settings_provider.dart';

/// The well-known "common" geohash channels seeded into the sidebar on connect
/// (PWA `this.commonGeohashes`, app.js:681). `nymchat` is the default named
/// channel; the rest are geohash channels.
const List<String> kCommonGeohashes = [
  'nymchat', '9q', 'w2', 'dr5r', '9q8y', 'u4pr', 'gcpv', 'f2m6', 'xn77', 'tjm5',
];

/// A PM sent but not yet acknowledged by a delivery receipt, queued for
/// automatic re-send (pms.js `trackPendingDM`/`retryPendingDMs`, lines 117-176).
/// Keyed in [_pendingDms] by the stable `nymMessageId` (the `['x', …]` tag),
/// NOT the optimistic bubble id — a re-publish rebuilds a fresh gift-wrap (new
/// randomness, new wrap id), but the recipient dedups on `nymMessageId`, and the
/// delivery receipt that clears the entry also references `nymMessageId`.
class _PendingDm {
  _PendingDm({
    required this.rumor,
    required this.recipientPubkey,
    required this.lastAttemptMs,
  });

  final UnsignedEvent rumor;
  final String recipientPubkey;
  int attempts = 0;
  int lastAttemptMs;
}

/// Ties identity + relay + crypto to the [AppState] store: boots an ephemeral
/// identity, connects to relays, and routes inbound events into the store. Send
/// requests from the composer flow through here.
class NostrController {
  NostrController(this._ref);

  final Ref _ref;
  Identity? _identity;
  NostrService? _service;
  GroupManager? _groups;
  EventSigner? _signer;
  bool _started = false;

  /// Cross-device storage sync (`/api/storage`): encrypted settings, D1-first
  /// profile mirror, PM gift-wrap archive. Built in [init] once the identity +
  /// signer are known. Null before boot / when the signer is unavailable. All
  /// calls through it are lazy + failure-tolerant (the live host may be
  /// unreachable; the PWA treats every storage path as best-effort).
  StorageSync? _storageSync;

  /// Zap-receipt D1 archive: batched `zap-put` of observed kind-9735 receipts
  /// + `zap-get` backfill for hydrated history (zaps.js:29-93). Built alongside
  /// [_storageSync]; null before boot.
  ZapArchive? _zapArchive;

  /// Id of the last own kind-0 mirrored to D1 (`_lastMirroredOwnProfileId`,
  /// nostr-core.js:198) so duplicate relay receipts of the same profile — and
  /// the relay echo of a profile we just published — don't re-POST it.
  String? _lastMirroredOwnProfileId;

  /// Cached full self kind-0 content (`_cachedKind0Profile`,
  /// nostr-core.js:622-624) so [saveProfile] can merge the app-managed fields
  /// into the user's REAL profile without dropping fields the app doesn't
  /// manage (nip05, website, lud06, …). Kept fresh by [_adoptSelfKind0] from
  /// every self kind-0 (newest `created_at` wins).
  Map<String, dynamic>? _cachedKind0Profile;
  int _cachedKind0Ts = 0;

  /// Adopts a self kind-0's content into [_cachedKind0Profile] (the PWA's
  /// `this._cachedKind0Profile = profile` in the kind-0 handler,
  /// nostr-core.js:621-626), skipping stale events.
  void _adoptSelfKind0(NostrEvent event) {
    if (event.createdAt < _cachedKind0Ts) return;
    try {
      final decoded = jsonDecode(event.content);
      if (decoded is Map) {
        _cachedKind0Profile = Map<String, dynamic>.from(decoded);
        _cachedKind0Ts = event.createdAt;
      }
    } catch (_) {
      // Malformed content — keep the previous cache.
    }
  }

  /// Whether the user has real profile data worth mirroring to D1 — the PWA's
  /// `_hasCustomProfileData` (nostr-core.js:176-191): a durable login or the
  /// verified developer always qualifies, and an EPHEMERAL identity qualifies
  /// once it set a custom avatar / banner / bio / lightning address or a
  /// user-chosen nick (`nym_custom_nick` matching the current nym).
  /// Autogenerated throwaway identities stay off the bucket.
  bool _hasCustomProfileData() {
    final identity = _identity;
    if (identity == null) return false;
    if (identity.loginMethod != null) return true;
    if (isVerifiedDeveloper(identity.pubkey)) return true;
    final kv = _ref.read(keyValueStoreProvider);
    if ((kv.getString(StorageKeys.avatarUrl) ?? '').isNotEmpty) return true;
    if ((kv.getString(StorageKeys.bannerUrl) ?? '').isNotEmpty) return true;
    if ((kv.getString(StorageKeys.bio) ?? '').trim().isNotEmpty) return true;
    final lightning =
        kv.getString(StorageKeys.lightningAddressFor(identity.pubkey)) ??
            kv.getString(StorageKeys.lightningAddressGlobal);
    if (lightning != null && lightning.isNotEmpty) return true;
    final customNick = kv.getString(StorageKeys.customNick);
    if (customNick != null &&
        customNick.isNotEmpty &&
        stripPubkeySuffix(identity.nym) == customNick) {
      return true;
    }
    return false;
  }

  /// Re-mirrors our own authoritative signed kind-0 to D1 (`profile-set`) so a
  /// profile edited in another Nostr client stays reflected in the D1 public
  /// copy (`_saveProfileToD1`, nostr-core.js:194-204). Gated on
  /// [_hasCustomProfileData] — logged-in identities always mirror, and an
  /// ephemeral identity mirrors once it has ANY real profile data (custom
  /// nick/avatar/banner/bio/lightning), so peers' D1-first profile reads
  /// resolve its nym instead of the `nym#xxxx` fallback (nostr-core.js:162-169).
  /// Deduped by event id. Best-effort.
  void _mirrorOwnProfileToD1(NostrEvent event) {
    final sync = _storageSync;
    if (sync == null || !_hasCustomProfileData()) return;
    if (event.id.isEmpty || event.sig.isEmpty) return;
    if (event.id == _lastMirroredOwnProfileId) return;
    _lastMirroredOwnProfileId = event.id;
    unawaited(sync.profileSet(event.toJson()));
  }

  /// Shared [ApiClient] for the storage-sync paths (one instance, reused).
  ApiClient? _api;

  /// Debounce for the encrypted settings publish (settings.js
  /// `_debouncedNostrSettingsSave`, 5s).
  Timer? _settingsSyncTimer;

  /// Debounce for the LOCAL SharedPreferences persist of the group store and
  /// per-conversation read watermark. Both were previously rewritten on every
  /// inbound group message / read-advance; because SharedPreferences serializes
  /// the ENTIRE prefs file per write, that per-event churn was a background-I/O
  /// contributor to the ANR. Coalesce a burst into one write.
  Timer? _groupStorePersistTimer;
  Timer? _channelLastReadPersistTimer;

  /// Throttle: pubkey/groupId-scoped last typing-start send time (ms).
  final Map<String, int> _typingThrottle = {};

  /// Minimum gap between typing-start broadcasts (PWA `_typingSendInterval`,
  /// app.js:741), C03-D4.
  static const int _typingSendIntervalMs = 3000;

  /// Reaction toggle rate-limit tracker: `messageId:emoji` → timestamps within
  /// the 30s window + a cooldown-until ms (reactions.js
  /// `_checkReactionRateLimit`: 3 toggles / 30s, then 60s cooldown).
  final Map<String, _ReactionRateTracker> _reactionToggleTracker = {};

  /// Persisted message/profile/reaction cache (hydrated on boot, flushed on a
  /// debounce + on dispose). Null until [init].
  CacheStore? _cache;
  Timer? _flushTimer;

  // --- live inbound coalescing (perf) --------------------------------------
  // Live relay EVENTs arrive one per stream callback (separate event-loop
  // turns), so a connect burst would fire one AppState rebuild — plus a re-run
  // of the spam/flood render providers — PER event. Buffer a turn's worth and
  // replay them through [_onEvent] inside a single [AppStateNotifier.runBatched]
  // so the burst costs ~one rebuild. A zero-duration timer fires after the
  // current microtask queue drains, so a whole verifier cohort (delivered as a
  // microtask cascade in one turn) lands in one flush. `_onEvent` only reads raw
  // `appStateProvider` state (mutated in place, so content stays fresh mid-batch)
  // — never a cached derived provider — so deferring the emit changes nothing it
  // sees. The D1 archive backfill is already batched at its own loops
  // ([_runChannelBackfill] etc.); this covers the LIVE path.
  final List<NostrEvent> _liveInboundBuffer = <NostrEvent>[];
  Timer? _liveInboundTimer;

  /// Hard cap so one turn's burst can't grow the buffer unbounded; reaching it
  /// flushes immediately (an extra emit for a very large burst is acceptable).
  static const int _kLiveInboundFlushCap = 512;

  final Set<String> _dirtyChannelKeys = {};
  final Set<String> _dirtyPmKeys = {};
  bool _flushScheduled = false;

  /// Runtime cache caps — app.js uses 1000/1000 (the persistence module's own
  /// fallbacks are 100/500; we honor the runtime values).
  static const int _channelMessageLimit = 1000;
  static const int _pmStorageLimit = 1000;

  Identity? get identity => _identity;
  bool get isLive => _identity != null;

  /// The active [EventSigner]: a [LocalSigner] for nsec/ephemeral keys, a
  /// [Nip46SignerAdapter] for a restored NIP-46 remote signer, or null before
  /// boot. Every publish / gift-wrap path flows through this.
  EventSigner? get signer => _signer;

  /// The live relay [PoolTransport] (proxy or direct), or null before boot.
  /// Exposed so the NIP-46 remote-signer transport can ride the already-connected
  /// pool instead of a dedicated raw socket ([nip46ServiceProvider]).
  PoolTransport? get pool => _service?.pool;

  /// Per-relay connection status (url → connected) for the Network Stats modal
  /// (`relay_stats_modal.dart`). Direct mode reads [RelayPool.connectionStatus];
  /// proxy mode exposes its live connected set as `url → true`. Empty before boot.
  Map<String, bool> get relayConnectionStatus {
    final svc = _service;
    if (svc == null) return const {};
    final pool = svc.pool;
    if (pool is RelayPool) return pool.connectionStatus;
    if (pool is RelayPoolProxy) {
      return {for (final u in pool.connectedRelayUrls) u: true};
    }
    return const {};
  }

  /// Live relay throughput / byte / latency stats for the Network Stats modal
  /// (`relay_stats_modal.dart`), aggregated across the pool (PWA
  /// `nym.relayStats`). Null before boot → the modal renders the empty state.
  RelayStats? get relayStats => _service?.relayStats;

  // --- Slash commands -------------------------------------------------------

  /// System-message sink (`displaySystemMessage`). The composer/chat UI
  /// registers a callback to surface command feedback in the active
  /// conversation. Defaults to a debug print so commands work headless/in tests.
  void Function(String text)? _systemMessageSink;

  late final CommandDispatcher _dispatcher = CommandDispatcher(
    engine: _CommandEngineAdapter(this),
    hooks: const CommandHooks(),
    rateLimiter: ActionCommandRateLimiter(),
  );

  /// Registers the system-message sink + the optional command modal hooks.
  /// Called once by the composer when it mounts.
  void setCommandHooks({
    void Function(String text)? onSystemMessage,
    CommandHooks? hooks,
  }) {
    if (onSystemMessage != null) _systemMessageSink = onSystemMessage;
    if (hooks != null) _dispatcher.hooksOverride = hooks;
  }

  void _emitSystemMessage(String text) {
    final sink = _systemMessageSink;
    if (sink != null) {
      sink(text);
    } else {
      debugPrint('[system] $text');
    }
  }

  /// Boots the identity and starts the relay connection. Safe to call once.
  ///
  /// [unlockedSecrets] carries the in-memory decrypted vault secrets when the
  /// identity vault is enabled (passed by the boot-unlock gate) so identity
  /// restore never reads the encrypted blob at rest (native analogue of
  /// `_vaultMem`).
  Future<void> init({Map<String, String>? unlockedSecrets}) async {
    if (_started) return;
    _started = true;
    // Re-arm the onboarding hydration gate for this session, synchronously
    // (before any await) so it's pending by the time the shell mounts and
    // defers the tutorial on it.
    if (_settingsHydratedC.isCompleted) {
      _settingsHydratedC = Completer<void>();
    }
    try {
      final kv = _ref.read(keyValueStoreProvider);
      // `secretWrite` routes identity-secret persistence through the vault
      // (key-vault.js `secretSet`): with the vault enabled + unlocked (the
      // boot gate unlocked the SAME provider instance), post-boot writes stay
      // `enc:v1:`-encrypted instead of downgrading to plaintext.
      final identityService = IdentityService(
        kv: kv,
        secure: SecureStore(),
        secretWrite: _ref.read(identityVaultProvider).secretSet,
      );

      // NIP-46 remote-signer login: restore the persisted session and build a
      // remote signer (no local key). Mirrors the PWA's `signEvent` dispatch by
      // `nostrLoginMethod === 'nip46'` (Identity has pubkey=remotePubkey,
      // privkey=null). nsec/ephemeral fall through to IdentityService.boot().
      Identity identity;
      EventSigner? signer;
      if (kv.getString(StorageKeys.nostrLoginMethod) == 'nip46') {
        final restored = await _restoreNip46Signer(kv);
        if (restored != null) {
          identity = restored.$1;
          signer = restored.$2;
        } else {
          identity =
              await identityService.boot(unlockedSecrets: unlockedSecrets);
          signer = identity.privkey != null
              ? LocalSigner(identity.privkey!)
              : null;
        }
      } else {
        // Restore a saved nsec account, else boot/reuse the ephemeral identity.
        identity = await identityService.boot(unlockedSecrets: unlockedSecrets);
        signer =
            identity.privkey != null ? LocalSigner(identity.privkey!) : null;
      }
      _identity = identity;
      _signer = signer;

      // Durable login (nsec/NIP-46): never surface the boot chain's leftover
      // auto-ephemeral / derived nick as the account's name — the PWA seeds
      // the header from the CACHED kind-0 profile name
      // (`nym_nostr_login_profile`, app.js:4514-4522, fallback 'nym') and
      // lets the profile fetch below overwrite it. [_syncSelfNymFromProfile]
      // rewrites that cache whenever our own profile resolves, so relaunches
      // restore the account nick instantly.
      if (identity.loginMethod != null) {
        identity.nym = getNymFromPubkey(
            _cachedLoginProfileName(kv) ?? 'nym', identity.pubkey);
      }

      final appState = _ref.read(appStateProvider.notifier);
      appState.goLive(identity.pubkey, identity.nym);

      // Restore friends / blocked users / blocked keywords from KV.
      _hydrateSocialState(appState);
      // Restore the user's closed-PM set so deleted conversations don't
      // resurrect from the D1 backlog on relaunch (F02; pms.js `nym_closed_pms`
      // / `nym_closed_pm_times`).
      _hydrateClosedPMs(appState);
      // Restore left-group state from KV so a group left on any device stays
      // suppressed on relaunch and the retroactive-removal pass runs.
      _hydrateLeftGroups(appState);
      // Restore the per-conversation read watermark so a relaunch's D1 backfill
      // of older history doesn't re-count as unread (channelLastRead).
      _hydrateChannelLastRead(appState);
      // Eagerly instantiate the recents notifier so its async prefs hydration
      // completes at BOOT — created lazily on the first long-press it returned
      // the initial empty list (quick-react popup showed no recents until the
      // second open). The PWA loads `nym_recent_emojis` synchronously at boot.
      _ref.read(recentEmojisProvider);
      // Seed the notification badge's blocked-sender exclusion from the restored
      // block list (C02-4).
      _ref
          .read(notificationHistoryProvider.notifier)
          .setBlocked(_ref.read(appStateProvider).blockedUsers);

      // Mirror the persisted heuristic-spam-filter flags (PWA `spamFilterEnabled`
      // / `spamFilterAggressive`, default true) onto the AppState module globals
      // the pure `isMessageFiltered` gate reads. No settings-modal UI changes
      // them at runtime (the PWA has none), so seeding once at boot suffices.
      final settings = _ref.read(settingsProvider.notifier);
      appSpamFilterEnabled = settings.spamFilterEnabled;
      appSpamFilterAggressive = settings.spamFilterAggressive;

      // The active pubkey scopes the per-identity image-blur read
      // (`nym_image_blur_<pubkey>` first, then the global key —
      // `loadImageBlurSettings`, settings.js:1139-1156).
      settings.activePubkey = identity.pubkey;

      // Keypair-mode save side effects (app.js:3873-3890): switching to
      // random/hardcore removes the saved session nsec; switching back to
      // persistent saves the CURRENT keypair's nsec when none is stored so the
      // in-use identity survives reload. Skipped for durable logins (the PWA's
      // `!isNostrLoggedIn()` gate).
      settings.onKeypairModeChanged = _onKeypairModeChanged;

      // Mirror Low Data Mode onto the relay layer whenever the setting flips
      // (the PWA's `nym.applyLowDataMode(lowDataMode)` on every settings save,
      // app.js:3989) — covers the settings modal AND the inbound sync apply.
      settings.onLowDataModeChanged =
          (enabled) => unawaited(_service?.setLowDataMode(enabled));

      // Flip the critical REQ's channelMode gate when Group Chat & PM Only
      // mode changes (relays.js:2488; the PWA applies the changed setting via
      // `applyGroupChatPMOnlyMode`, app.js:3978 — the filter shape follows on
      // the next resubscribe, which updateCriticalInputs debounces here).
      settings.onGroupChatPMOnlyModeChanged =
          (enabled) => _service?.updateCriticalInputs(channelMode: !enabled);

      // Touch the live custom-emoji store so it hydrates the persisted NIP-30
      // cache (`nym_custom_emojis` / `nym_custom_emoji_packs`) at boot, mirroring
      // the PWA's `_loadCustomEmojiCache`; live 30030/10030 events then top it up.
      _ref.read(liveCustomEmojiProvider);

      // Hydrate channel/profile/reaction caches before connecting (raced
      // ≤1500ms so a slow disk never blocks boot — mirrors app.js
      // `Promise.race([hydrateFromCache(), 1500ms])`).
      await _hydrateFromCache(appState).timeout(
        const Duration(milliseconds: 1500),
        onTimeout: () {},
      );

      // The hydrated cache may hold our own kind-0 (flushed by a previous
      // session) — mirror its name onto the live identity BEFORE the first
      // presence broadcast below, so `recordOwnActivity` / channel `['n', …]`
      // tags never announce the ephemeral boot nick when the real one is
      // already known locally.
      _syncSelfNymFromProfile();

      final service = NostrService(identity: identity, signer: signer);
      _service = service;
      _groups = GroupManager(service);
      // Restore persisted group conversations + ephemeral secret keys BEFORE
      // any network I/O (the PWA loads `nym_groups_<pubkey>` /
      // `nym_ephemeral_keys_<pubkey>` synchronously at construction,
      // groups.js:291-311/556-600) so an offline/flaky-API launch still has
      // its groups and can decrypt group wraps; the D1 settings restore then
      // merges on top.
      _hydrateGroupStore();
      // Seed Low Data Mode from the persisted setting BEFORE the relay layer
      // shards its geo relays (the PWA reads `settings.lowDataMode` in
      // `_computeExpectedShards`, relays.js:1905-1978; boot applies the saved
      // value). No-op when the setting is off (the default).
      if (_ref.read(settingsProvider).lowDataMode) {
        unawaited(service.setLowDataMode(true));
      }
      // The critical REQ's inputs (relays.js:2485-2570): channelMode mirrors
      // `!settings.groupChatPMOnlyMode`; the vouch/profile author lists feed
      // the DIRECT-mode filters (trust-graph vouch lists, PM-contact kind-0
      // watches) from the hydrated caches. Kept fresh afterwards via
      // updateCriticalInputs (vouch hops, new PM contacts, mode flips).
      final bootState = _ref.read(appStateProvider);
      await service.start(
        NostrHandlers(
          onEvent: _enqueueLiveEvent,
          onConnectionChanged: _onConnectionChanged,
          onGiftWrap: _onGiftWrap,
        ),
        channelMode: !_ref.read(settingsProvider).groupChatPMOnlyMode,
        vouchAuthors: bootState.nymchatPubkeys,
        profileAuthors: [
          for (final c in bootState.pmConversations) c.pubkey,
        ],
      );

      // Live gift-wrap REQ over the restored ephemeral pubkeys (the PWA's
      // `_refreshEphemeralSubscriptions()` in the main subscribe chain,
      // relays.js:2624) — the main subscription's `#p` filter carries only the
      // self pubkey, so without this group messages other members wrap to our
      // ephemeral keys never arrive live. No-op when no keys are known yet.
      _refreshEphemeralSubscriptions();

      // Subscribe the INITIAL channel's typing/read-receipt feed (kinds
      // 24420/24421). The boot view is a channel (default #nymchat / restored
      // last channel) reached WITHOUT going through [switchChannel], so without
      // this its typing indicators + reader avatars would never arrive until the
      // user manually switches channels once.
      _subscribeActiveChannelTyping();

      // Broadcast presence on connect. The PWA's presence is purely
      // event-driven (`recordOwnActivity` fires on send/react only — there is
      // NO `setInterval` heartbeat), so a connected-but-idle user decays to
      // offline for peers after the 5-min window (C03-D7). Re-broadcasts come
      // from the send/react call sites below, not a timer.
      recordOwnActivity();

      // Seed the sidebar with the well-known common geohash channels so the
      // channel list isn't empty before the user joins anything (PWA
      // `discoverChannels`, called on connect from relays.js).
      discoverChannels();

      // Web of trust: on boot the only trusted authors are the seeded dev/bot
      // roots (plus the persisted graph); the graph then expands one hop at a
      // time as vouches arrive (relays.js:2536-2542). A no-op resubscribe here
      // (start already carried the same authors); kept for the expansion hops.
      _subscribeVouches();

      // A NEW PM contact must join the critical REQ's direct-mode kind-0
      // filter (the PWA's `addPMConversation` new-branch →
      // `_scheduleCriticalResubscribe`, pms.js:2795-2805). Recompute the full
      // author list; the service's 750ms debounce coalesces hydration bursts,
      // and in proxy/D1 mode the rebuilt set is unchanged so it's harmless.
      _ref.read(appStateProvider.notifier).onPMConversationAdded = (_) {
        final svc = _service;
        if (svc == null) return;
        svc.updateCriticalInputs(profileAuthors: [
          for (final c in _ref.read(appStateProvider).pmConversations) c.pubkey,
        ]);
      };

      // Cross-device storage sync (`/api/storage`). Durable = logged-in
      // (loginMethod != null, the PWA's `isNostrLoggedIn()`); ephemeral
      // identities skip the durable PM archive. All calls are best-effort.
      _initStorageSync(identity, signer);
      unawaited(_bootStorageSync());

      // PWA `applyNostrLogin` → `fetchProfileDirect(self)` (app.js:5531): restore
      // our own profile so the sidebar header shows our real nym + avatar instead
      // of the ephemeral derived nym. `resolveProfiles` reads the D1 database
      // FIRST (`profile-get`, the source of truth) and only falls back to a relay
      // kind-0 fetch if D1 holds no profile for us. It has no self-guard (unlike
      // `_maybeBackfillProfiles`), and `_ingestProfile` updates `selfNym` for
      // self, so this restores both the avatar and the header text; the chained
      // [_syncSelfNymFromProfile] then mirrors the resolved name onto the live
      // [Identity] (presence / `n` tags / mentions) and rewrites the
      // instant-restore login-profile cache (`updateSidebarFromProfile`,
      // app.js:5507-5528). The relay-fallback results land via [_onEvent], which
      // runs the same sync. Covers `loginWithNsec` too (it re-runs `init`).
      // Best-effort.
      unawaited(resolveProfiles([identity.pubkey])
          .then((_) => _syncSelfNymFromProfile()));

      // Immediately backfill the active channel's D1 archive on boot — the PWA
      // loads the current channel's (e.g. #nymchat) history right away on load,
      // not only on a later view switch (`_onViewOpened`). This MUST run after
      // `_initStorageSync` wires `_storageSync`; otherwise `_backfillChannelArchive`
      // hits its `sync == null` early-return and the default channel never loads.
      final bootView = _ref.read(appStateProvider).view;
      if (bootView.kind == ViewKind.channel) {
        unawaited(_backfillChannelArchive(bootView.id));
      }

      // Discover recently-active GEOHASH + NAMED channels from the D1 archive,
      // seed the sidebar / globe / unread floors, THEN restore the D1 message
      // archive for the full {current ∪ joined ∪ discovered} channel set — the
      // PWA's `fetchGeohashActivityFromD1` + `fetchNamedChannelActivityFromD1`
      // AND `channelRestoreManyFromD1` over {current ∪ joined}, both fired on
      // connect inside `backfillFromD1OnReconnect` (relays.js:2791-2805), NOT
      // only on a view switch. Restoring the whole set here (not just the boot
      // view above) keeps every badge-bearing channel's messages loaded up front
      // so a sidebar unread badge never opens to an empty channel. Runs after
      // `_initStorageSync` wires `_storageSync` (no-ops otherwise); discovery is
      // ~30s-throttled and each channel's fetch is deduped/bounded. Best-effort;
      // never blocks boot (also re-fired on reconnect, see [_onConnectionChanged]).
      // Arm the reconnect backfill's 30s throttle so the imminent 0→N connect
      // edge doesn't fan out a SECOND full channel restore seconds after this
      // one (the PWA runs `backfillFromD1OnReconnect` once per 30s window,
      // relays.js:2766-2768).
      _lastD1BackfillAt = DateTime.now().millisecondsSinceEpoch;
      unawaited(_restoreAllChannelArchives());
    } catch (e, st) {
      // Boot failed (e.g. no secure storage). Never strand the user on demo
      // data: if we never reached `goLive` (so the store is still the empty
      // logged-out shell, AppState.empty), force it explicitly so a partial
      // boot can't leave stale/seed content, and surface the error. A boot that
      // already went live (identity != null) and only failed a later
      // best-effort step keeps its live store.
      debugPrint('NostrController.init failed: $e\n$st');
      if (_identity == null) {
        try {
          _ref.read(appStateProvider.notifier).reset();
        } catch (_) {}
      }
      _emitSystemMessage('Connection failed — working offline.');
      // A failed boot must still release the onboarding gate — no settings
      // restore is coming (mirrors the PWA's 10s hydration fallback).
      _markSettingsHydrated();
    }
  }

  /// Seeds the sidebar with the well-known "common" geohash channels (PWA
  /// `discoverChannels`, channels.js:598, over the `commonGeohashes` list,
  /// app.js:681). Skipped in group/PM-only mode; `addChannel` is idempotent so
  /// re-running on each connect can't duplicate rows, and `#nymchat` (always
  /// present as the default named channel) is left to the registry.
  void discoverChannels() {
    if (_ref.read(settingsProvider).groupChatPMOnlyMode) return;
    final app = _ref.read(appStateProvider.notifier);
    for (final g in kCommonGeohashes) {
      if (g == 'nymchat') continue;
      app.addChannel(g, geohash: g);
    }
  }

  /// Public, throttled D1 activity refresh for the globe (GL3). The geohash
  /// explorer calls this on open and on its 30s active-window tick so the
  /// dots/heatmap reflect real D1 activity for channels we never loaded —
  /// mirroring the PWA's `showGeohashExplorer` + the `ACTIVE_WINDOW_REFRESH_MS`
  /// timer, both of which call `fetchGeohashActivityFromD1` (geohash-globe.js:210
  /// / :1024). Delegates to [_discoverChannelActivity], which is already
  /// ~30s-throttled and best-effort (so calling it on every tick is safe).
  Future<void> refreshGeohashActivity() => _discoverChannelActivity();

  /// Relay connection-count sink. Forwards the live count to [AppState] (the old
  /// direct `setConnectedRelays` binding) AND re-fires the D1 activity discovery
  /// on a 0→connected edge, mirroring the PWA, which calls
  /// `backfillFromD1OnReconnect` (→ `fetchGeohashActivityFromD1` +
  /// `fetchNamedChannelActivityFromD1`) from the connect→subscribe chain
  /// (relays.js:2761) and on every reconnect. The discovery is throttled ~30s
  /// internally so a flapping connection can't hammer the worker.
  void _onConnectionChanged(int count) {
    final wasOffline = _ref.read(appStateProvider).connectedRelays == 0;
    _ref.read(appStateProvider.notifier).setConnectedRelays(count);
    if (count > 0 && wasOffline) {
      // Reconnect edge → re-run the FULL D1 backfill (PWA
      // `backfillFromD1OnReconnect`, relays.js:2761/2764): PMs, group history,
      // channel activity, and the joined-channel archives. Now that the relay
      // REQ windows carry only NEW live events (`NostrService.start` collapses
      // history to D1), this is what recovers everything that landed while we
      // were disconnected — without it, the reconnect gap would silently drop
      // messages.
      unawaited(_backfillFromD1OnReconnect());
      // Re-send any PM still waiting on a delivery receipt — a reconnect is the
      // most likely moment a stuck DM finally lands (pms.js
      // `retryPendingDMsOnReconnect`, F02 auto-retry).
      _retryPendingDmsOnReconnect();
    }
  }

  /// Last `_backfillFromD1OnReconnect` run (ms) — the PWA's 30s throttle so a
  /// flapping connection can't hammer D1 (`_lastD1BackfillAt`, relays.js:2767).
  int _lastD1BackfillAt = 0;

  /// Re-pulls the full D1 backlog on a reconnect / app-resume — the native
  /// `backfillFromD1OnReconnect` (relays.js:2764). Because the relay REQ windows
  /// now carry ONLY new live events (D1 supplies all history, see
  /// [NostrService.start]), a reconnect MUST re-restore PMs, group history, and
  /// the joined-channel archives from D1 — otherwise messages that landed while
  /// we were disconnected (older than the reconnect's `since=now` window) are
  /// lost. 30s-throttled, best-effort, idempotent (every restore dedups by id).
  Future<void> _backfillFromD1OnReconnect() async {
    final sync = _storageSync;
    if (sync == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastD1BackfillAt != 0 && now - _lastD1BackfillAt < 30000) return;
    _lastD1BackfillAt = now;
    // Retry the boot settings restore when it failed (offline launch / flaky
    // /api/storage): for a fresh device the D1 settings row is the ONLY path
    // to another device's groups + ephemeral decryption keys, so it must not
    // stay lost for the whole session. Idempotent when nothing changed.
    if (_settingsGetFailed) {
      await _mergeRemoteSettings(sync);
    }
    // Relay reconnects drop server-side REQs — re-arm the ephemeral gift-wrap
    // subscription like the PWA's subscribe chain does (relays.js:2624).
    _refreshEphemeralSubscriptions();
    // 1:1 PM backlog (previously boot-only) + group ephemeral history
    // (previously group-open-only).
    await _restorePmArchive(sync);
    await _backfillGroupArchive();
    // Channel-activity discovery + archive restore over {current ∪ joined ∪
    // discovered} (relays.js:2791-2797), not just the single open view.
    await _restoreAllChannelArchives();
    // Custom-emoji archive hydration (`_emojiRestoreFromD1`, relays.js:2813-2815)
    // — packs archived by the relay-pool worker that have aged off relays must
    // re-hydrate on every reconnect/resume, not only at cold boot, or archived
    // shortcodes render broken on a long-lived session.
    unawaited(_restoreEmojiFromD1(sync));
    // Profile-zap backfill for ourselves (relays.js:2819-2821,
    // `_backfillZapReceiptsFromD1([this.pubkey], 'profile')`) — profile receipts
    // are keyed on the recipient pubkey with a tight relay #p window, so they
    // must be re-pulled from D1 on every reconnect/resume; boot-only misses zaps
    // that land while backgrounded/disconnected.
    final selfPk = _identity?.pubkey;
    final zapArchive = _zapArchive;
    if (selfPk != null && zapArchive != null) {
      final appState = _ref.read(appStateProvider.notifier);
      unawaited(zapArchive.backfill(
        [selfPk],
        'profile',
        (receipt) => _onPublicZapReceipt(receipt, appState),
      ));
    }
    // Web of trust: rebuild from the D1 `nym-vouches` pseudo-channel instead
    // of REQ-ing every trusted peer's vouch list from relays (relays.js:
    // 2824-2827) — under D1 the critical REQ carries only the live-tail
    // vouches filter, so this IS the history path.
    unawaited(_fetchVouchesFromD1(sync));
  }

  /// Rebuilds the web of trust from D1 (vouch lists are archived under the
  /// `nym-vouches` pseudo-channel) — nostr-core.js `_fetchVouchesFromD1`
  /// (line 2700). Signatures are verified (archived rows bypass the relay
  /// pipeline's verification, and the trust graph must not grow from forged
  /// rows) and the graph is expanded ITERATIVELY so a vouch from a
  /// newly-trusted author is applied once they're rooted. Best-effort.
  Future<void> _fetchVouchesFromD1(StorageSync sync) async {
    List<Map<String, dynamic>> rows;
    try {
      // force: the PWA's call has no freshness gate (it streams directly);
      // channelGet's 60s window must not silently skip the restore.
      rows = await sync.channelGet([AppDataTopic.vouches], force: true);
    } catch (_) {
      return;
    }
    final parsed = <NostrEvent>[];
    for (final raw in rows) {
      try {
        final ev = NostrEvent.fromJson(raw);
        if (ev.kind != EventKind.appData) continue;
        parsed.add(ev);
      } catch (_) {
        // Skip a malformed archived row.
      }
    }
    if (parsed.isEmpty) return;
    // Verify the whole archive cohort off the main isolate in ONE batched hop
    // (this used to run `schnorr.verifyEvent` INLINE per row on the render
    // thread). Build every future in this turn so IsolateVerifier coalesces
    // them; fall back to the inline verify when the service isn't up yet.
    final service = _service;
    final valid = <NostrEvent>[];
    if (service != null) {
      final oks =
          await Future.wait([for (final ev in parsed) service.verifyEvent(ev)]);
      for (var i = 0; i < parsed.length; i++) {
        if (oks[i]) valid.add(parsed[i]);
      }
    } else {
      for (final ev in parsed) {
        if (schnorr.verifyEvent(ev)) valid.add(ev);
      }
    }
    if (valid.isEmpty) return;
    // Coalesce the fixpoint expansion's per-vouch notifies into one rebuild.
    _ref.read(appStateProvider.notifier).runBatched(() {
      var changed = true;
      var guard = 0;
      while (changed && guard++ < 20) {
        final before = _ref.read(appStateProvider).nymchatPubkeys.length;
        for (final ev in valid) {
          try {
            _ingestVouch(ev);
          } catch (_) {}
        }
        changed =
            _ref.read(appStateProvider).nymchatPubkeys.length != before;
      }
    });
  }

  /// Max number of per-channel D1 archive restores in flight at once. The PWA
  /// coalesces the whole set into ONE `channel-get` (channels.js:1123); here
  /// each channel keeps its own in-flight dedup + 10s timeout inside
  /// [_backfillChannelArchive], so we cap the fan-out rather than await serially
  /// — a few slow/empty channels no longer stall the rest of the restore.
  static const int _kChannelBackfillConcurrency = 4;

  /// Discovers active channels from D1 (seeding the sidebar + unread floors),
  /// THEN restores the D1 message archive for the full {current ∪ joined ∪
  /// discovered} channel set — the PWA's `channelRestoreManyFromD1` over
  /// {current ∪ joined} run from `backfillFromD1OnReconnect` (relays.js:2791)
  /// and at boot. Discovery is AWAITED first so freshly-discovered channels
  /// (added to `state.channels` + given an unread floor by
  /// [AppStateNotifier.applyChannelActivity]) are included in the restore set;
  /// otherwise a discovered channel surfaces a badge but never has its messages
  /// backfilled → the phantom "No recent messages" on open. Best-effort.
  Future<void> _restoreAllChannelArchives() async {
    await _discoverChannelActivity();
    final keys = <String>{
      for (final c in _ref.read(appStateProvider).channels) c.key,
    };
    final view = _ref.read(appStateProvider).view;
    if (view.kind == ViewKind.channel && view.id.isNotEmpty) keys.add(view.id);
    await _backfillChannelArchivesFor(keys);
  }

  /// Restores the D1 archive for every channel in [keys] with bounded
  /// concurrency ([_kChannelBackfillConcurrency] at a time) via
  /// [_backfillChannelArchive] (which dedups concurrent calls per channel and
  /// time-bounds each fetch). NON-forced: the PWA's reconnect/boot mass
  /// restore honors the per-channel 60s freshness window
  /// (`channelRestoreManyFromD1` without force, channels.js:1127) — only an
  /// explicit view open forces. Best-effort; empty/blank keys are skipped.
  Future<void> _backfillChannelArchivesFor(Iterable<String> keys) async {
    final list = <String>{
      for (final k in keys)
        if (k.isNotEmpty) k,
    }.toList();
    if (list.isEmpty) return;
    var next = 0;
    Future<void> worker() async {
      while (next < list.length) {
        await _backfillChannelArchive(list[next++], force: false);
      }
    }

    final workerCount = _kChannelBackfillConcurrency < list.length
        ? _kChannelBackfillConcurrency
        : list.length;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
  }

  /// Last `_discoverChannelActivity` run (ms) — the ~30s throttle the PWA applies
  /// to `fetchGeohashActivityFromD1` / `fetchNamedChannelActivityFromD1`
  /// (`_geohashActivityFetchedAt` / `_namedActivityFetchedAt`, channels.js:131).
  /// Reset to 0 on a transport failure so the next attempt retries immediately.
  int _lastActivityDiscoveryAt = 0;

  /// Discovers recently-active GEOHASH + NAMED channels from the D1 archive and
  /// seeds the in-memory store (sidebar registry + last-activity sort + unread
  /// floors), the native port of the PWA's `fetchGeohashActivityFromD1` +
  /// `fetchNamedChannelActivityFromD1` (channels.js:128/289), which run on
  /// connect (relays.js:2799-2805) so the channel list/globe surface real
  /// recency before the user opens anything.
  ///
  /// Issues all three PUBLIC reads in parallel:
  ///   * `channel-active`        — discover active GEOHASH channels,
  ///   * `channel-active-named`  — discover active NAMED channels,
  ///   * `channel-activity`      — activity buckets for the geohashes we already
  ///     know (common + sidebar + channels with stored messages),
  /// then folds each result into [AppStateNotifier.applyChannelActivity]. The
  /// discovery results carry the globe/sidebar recency; the known-activity result
  /// seeds unread floors for joined channels. Throttled ~30s, best-effort
  /// (failures are swallowed; never blocks boot). Skipped in group/PM-only mode
  /// (the sidebar channel list is hidden there, like [discoverChannels]).
  Future<void> _discoverChannelActivity() async {
    final sync = _storageSync;
    if (sync == null) return;
    if (_ref.read(settingsProvider).groupChatPMOnlyMode) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastActivityDiscoveryAt != 0 && now - _lastActivityDiscoveryAt < 30000) {
      return;
    }
    _lastActivityDiscoveryAt = now;
    try {
      final app = _ref.read(appStateProvider.notifier);

      // Known geohashes to probe (PWA gathers commonGeohashes + sidebar channels
      // + channels with stored messages, channels.js:137-144). De-duped inside
      // [StorageSync.channelActivity]; nymchat included (it's a valid geohash key
      // in the PWA's `commonGeohashes`).
      final known = <String>{...kCommonGeohashes};
      for (final c in _ref.read(appStateProvider).channels) {
        known.add(c.key);
      }
      for (final storageKey in _ref.read(appStateProvider).messages.keys) {
        if (storageKey.startsWith('#')) known.add(storageKey.substring(1));
      }

      // All three reads in parallel (PWA `Promise.all`, each best-effort). The
      // StorageSync methods already resolve failures to empty results.
      final results = await Future.wait([
        sync.channelActive(),
        sync.channelActiveNamed(),
        sync.channelActivity(known.toList()),
      ]);
      final geo = results[0];
      final named = results[1];
      final knownActivity = results[2];

      // Discovered GEOHASH channels → sidebar (as geohash entries) +
      // last-activity ONLY. The raw discovery buckets are NOT spam-aware
      // (worker `topChannelActivityRows`, storage.js:1092-1121) so they never
      // feed unread floors — "Spam-aware activity feeds unread floors only"
      // (channels.js:320-323).
      app.applyChannelActivity(geo.activity, geo.last, geohash: true);
      // Discovered NAMED channels → sidebar (as named entries) + last-activity.
      app.applyChannelActivity(named.activity, named.last);
      // Known channels' spam-aware activity (`channel-activity`, worker
      // `spamAwareActivityRows`) → unread floors (+ last-activity top-up).
      // These keys are already joined, so no new sidebar rows appear here.
      app.applyChannelActivity(knownActivity.activity, knownActivity.last,
          seedUnread: true);
    } catch (_) {
      // Best-effort: allow the next trigger (reconnect / foreground) to retry.
      _lastActivityDiscoveryAt = 0;
    }
  }

  /// Restores a persisted NIP-46 remote-signer session and builds the matching
  /// [Identity] (pubkey=remote user pubkey, privkey=null, loginMethod='nip46')
  /// + a [Nip46SignerAdapter]. Returns null if there's no session to restore or
  /// the reconnect fails (caller then falls back to ephemeral). Mirrors the
  /// PWA's `restoreSession` → remote `signEvent` dispatch.
  Future<(Identity, EventSigner)?> _restoreNip46Signer(KeyValueStore kv) async {
    try {
      final svc = _ref.read(nip46ServiceProvider);
      // If the login modal just connected this SHARED instance (runtime adopt
      // via [loginWithNip46]), reuse the live socket as-is; only reconnect from
      // persisted storage on a genuine cold boot. Re-`restoreSession`ing a
      // connected instance would open a second socket and re-run the handshake.
      if (!(svc.isConnected && svc.pubkey.length == 64)) {
        final ok = await svc.restoreSession();
        if (!ok || svc.pubkey.length != 64) return null;
      }
      final pubkey = svc.pubkey;
      final nym = kv.getString(StorageKeys.customNick) ??
          kv.getString(StorageKeys.autoEphemeralNick) ??
          NymGenerator()
              .generate(pubkey, style: kv.getString(StorageKeys.nickStyle) ?? 'fancy');
      final identity = Identity(
        pubkey: pubkey,
        privkey: null,
        nym: nym,
        loginMethod: 'nip46',
      );
      return (identity, Nip46SignerAdapter(svc));
    } catch (_) {
      return null;
    }
  }

  /// The cached kind-0 profile name persisted for the durable login — the
  /// PWA's `nym_nostr_login_profile` instant-restore cache (written in
  /// `updateSidebarFromProfile`, app.js:5523-5527; read on boot BEFORE relays
  /// connect, app.js:4514-4522). Null when absent/corrupt.
  String? _cachedLoginProfileName(KeyValueStore kv) {
    final raw = kv.getString(StorageKeys.nostrLoginProfile);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final name = decoded['name'];
        if (name is String && name.isNotEmpty) return name;
      }
    } catch (_) {}
    return null;
  }

  /// Mirrors the resolved SELF kind-0 profile name onto the live [Identity]
  /// and refreshes the durable login's instant-restore profile cache — the
  /// PWA's `updateSidebarFromProfile` (`nym.nym = user.nym` + the
  /// `nym_nostr_login_profile` write, app.js:5507-5528).
  ///
  /// `_ingestProfile` / `hydrateProfiles` already keep `AppState.selfNym` (the
  /// sidebar header, composer/self messages, mention token, settings) in sync;
  /// this covers every `identity.nym` read site too — presence broadcasts,
  /// channel `['n', …]` tags, mention detection, group invites/leaves, polls,
  /// settings transfers, `/who` — so peers and self-surfaces all see the
  /// account nick, never the boot identity's ephemeral nick. No-op while our
  /// own profile has no name (a brand-new account keeps its fallback).
  void _syncSelfNymFromProfile() {
    final identity = _identity;
    if (identity == null) return;
    final profile = _ref.read(appStateProvider).users[identity.pubkey]?.profile;
    // PWA name chain `name || username || display_name` capped at 20 chars
    // (nostr-core.js:697-700) — a profile authored by another Nostr client
    // with only `display_name` must still resolve the account nick.
    var name = profile?.name;
    if (name == null || name.isEmpty) name = profile?.displayName;
    if (name == null || name.isEmpty) return;
    if (name.length > 20) name = name.substring(0, 20);
    final nym = getNymFromPubkey(name, identity.pubkey);
    if (identity.nym != nym) identity.nym = nym;
    if (_ref.read(appStateProvider).selfNym != nym) {
      _ref.read(appStateProvider.notifier).setIdentity(identity.pubkey, nym);
    }
    // Persist for instant restore on the next launch (durable logins only —
    // an ephemeral identity's nick lives in `nym_auto_ephemeral_nick`).
    if (identity.loginMethod != null) {
      final kv = _ref.read(keyValueStoreProvider);
      unawaited(kv.setString(
        StorageKeys.nostrLoginProfile,
        jsonEncode({'name': name, 'avatar': profile?.picture}),
      ));
    }
  }

  // ---------------------------------------------------------------------------
  // Sign out / disconnect (app.js `signOut`, 6740). Clears the active identity +
  // in-memory secrets, drops the persisted login + auto-ephemeral state so the
  // boot gate falls back to first-run setup, disconnects relays, and resets the
  // in-memory store. The UI call site (chat_pane / sidebar) is responsible for
  // confirming and then returning to the boot/setup gate (e.g. remounting it),
  // mirroring the PWA's post-`cmdQuit` reload to a pristine first-run state.
  // ---------------------------------------------------------------------------

  /// Signs out: forgets the identity, disconnects, and resets local state.
  ///
  /// Removes the same persisted keys the PWA's `signOut()` clears
  /// (`nym_nostr_login_*`, the session/dev/login nsec secrets, the auto-ephemeral
  /// prefs, and the per-identity profile/cosmetic caches) so the next launch (or
  /// the boot gate re-check) shows the setup modal instead of restoring the old
  /// identity. Stops the relay service + presence/flush/sync timers, tears down
  /// the storage sync, and resets [AppState] plus the notification history /
  /// pending settings transfers / live custom-emoji state that were scoped to the
  /// signed-out identity. Idempotent and safe to call before [init].
  ///
  /// After this returns the controller is back in its pre-boot state ([_started]
  /// is reset), so a fresh identity created through the setup flow can [init]
  /// again on the same provider instance.
  /// Tears down the live session: cancel timers, close subs, flush + close the
  /// cache, stop the relay service, drop the in-memory identity / signer /
  /// service / storage-sync handles + session-scoped maps, and unbind the
  /// settings/view callbacks that captured the old signer/sync. Shared by
  /// [signOut] (followed by clearing persisted login + resetting the store) and
  /// [loginWithNsec] (followed by re-booting as the imported account). Does NOT
  /// touch persisted KV/secrets, [AppState], or `_started` — the caller decides
  /// those. Idempotent and safe to call before [init].
  ///
  /// [flush] writes any dirty cache rows before closing (the default — sign-out /
  /// login want a clean commit). The PANIC path passes `flush:false` so no
  /// just-wiped data is re-persisted mid-wipe (panic.js stops persistence:
  /// `_cacheDisabled = true`), matching the PWA's "destroy, don't save" intent.
  Future<void> _teardownLiveSession({bool flush = true}) async {
    // Cancel timers, close subs, flush + close the cache, and stop the relay
    // service. (Mirrors `cmdQuit` + the page reload dropping all in-memory NYM
    // state.)
    _flushTimer?.cancel();
    // Drop any buffered live events (the session — and its AppState — is being
    // torn down; they'd be re-fetched on the next connect).
    _liveInboundTimer?.cancel();
    _liveInboundTimer = null;
    _liveInboundBuffer.clear();
    // Drop any buffered unwrapped gift-wraps (the session is tearing down).
    _giftWrapFlushTimer?.cancel();
    _giftWrapFlushTimer = null;
    _giftWrapInbound.clear();
    _settingsSyncTimer?.cancel();
    _vouchPublishTimer?.cancel();
    _vouchPublishTimer = null;
    _vouchExpansionTimer?.cancel();
    _vouchExpansionTimer = null;
    _trustPersistTimer?.cancel();
    _trustPersistTimer = null;
    _lastVouchPublishAt = 0;
    // Release the hydration gate (an in-flight onboarding await resolves; its
    // `mounted` check no-ops it after the remount). The next [init] re-arms.
    _settingsHydratedFallback?.cancel();
    _settingsHydratedFallback = null;
    if (!_settingsHydratedC.isCompleted) _settingsHydratedC.complete();
    _deletedIdsPersistTimer?.cancel();
    _deletedIdsPersistTimer = null;
    // Flush any pending debounced group-store / read-watermark writes before we
    // drop the identity + app-state handles below (the persist reads both).
    _flushDebouncedPersists();
    _ref.read(appStateProvider.notifier).onDeletedIdsChanged = null;
    _dmRetryTimer?.cancel();
    _dmRetryTimer = null;
    _pendingDms.clear();
    _profileBackfillTimer?.cancel();
    _profileBackfillTimer = null;
    _profileBackfillQueue.clear();
    _profileBackfillQueued.clear();
    _flushScheduled = false;
    _dirtyChannelKeys.clear();
    _dirtyPmKeys.clear();
    // Identity-scoped kind-0 cache must not leak into the next session.
    _cachedKind0Profile = null;
    _cachedKind0Ts = 0;
    _lastMirroredOwnProfileId = null;
    if (_p2pSub != null) {
      _service?.pool.closeSubscription(_p2pSub!);
      _p2pSub = null;
    }
    if (flush) {
      try {
        await _flush();
      } catch (_) {}
    }
    try {
      await _cache?.close();
    } catch (_) {}
    _cache = null;
    try {
      await _service?.stop();
    } catch (_) {}
    _api?.dispose();
    _api = null;
    // Drop any cached signed kind-27235 auth so the next identity never reuses
    // the previous one's auth event (the cache is keyed by pubkey, but clear it
    // explicitly on identity teardown to be safe).
    Nip98Auth.clearAuthCache();

    // Drop in-memory identity + signer + group/service/storage-sync handles
    // (panic.js: `this.privkey = null; this.pubkey = null; … _vaultMem = null`).
    _identity = null;
    _signer = null;
    _service = null;
    _groups = null;
    _storageSync = null;
    _zapArchive?.dispose();
    _zapArchive = null;
    _lastPresenceBroadcast = 0;
    _presenceTimestamps.clear();
    _typingThrottle.clear();
    _sentChannelReadReceipts.clear();
    _sentPmReadReceipts.clear();
    _reactionToggleTracker.clear();

    // Stop syncing settings on change (the binding captured the old signer).
    final settings = _ref.read(settingsProvider.notifier);
    settings.onSyncedChange = null;
    // Drop the identity-scoped settings hooks (blur pubkey scope, keypair-mode
    // side effects, low-data relay mirror — all captured the old identity).
    settings.activePubkey = null;
    settings.onKeypairModeChanged = null;
    settings.onLowDataModeChanged = null;
    settings.onGroupChatPMOnlyModeChanged = null;
    // Stop backfilling on view-open (the binding captured the old storage sync).
    _ref.read(appStateProvider.notifier).onViewOpened = null;
    _ref.read(appStateProvider.notifier).onPmMessageIngested = null;
    _ref.read(appStateProvider.notifier).onPMConversationAdded = null;
    _ref.read(appStateProvider.notifier).onGroupStoreChanged = null;
    _ref.read(appStateProvider.notifier).onChannelReadMarked = null;
    // Close the ephemeral-key gift-wrap REQ (it captured the old service).
    _ephemeralSub?.close();
    _ephemeralSub = null;
    // Stop broadcasting shop-update presence / gift DMs / system lines (the
    // bindings captured the old identity/service).
    final shop = _ref.read(shopControllerProvider.notifier);
    shop.onActiveItemsPublished = null;
    shop.giftEventPublisher = null;
    shop.onSystemMessage = null;
    // Detach the bot ledger from the shared `/api` socket: the [ApiClient]
    // that owned it (AUTHed as the old identity) was just disposed above, so
    // drop the service's request seam too. The next [_initStorageSync]
    // re-wires it against the new identity's client.
    try {
      _ref.read(nymbotServiceProvider).setApiSocketRequest(null);
    } catch (_) {}
  }

  /// Switches the running session to a freshly-imported nsec account WITHOUT an
  /// app restart — the native analogue of the PWA's `nostrLoginWithNsec` →
  /// `applyNostrLogin` (app.js:5036-5074 / 5487-5612), whose key step is
  /// `resubscribeAllRelays()` so the new pubkey's gift-wraps/PMs/zaps flow in.
  ///
  /// [IdentityService.loginWithNsec] persists `nostr_login_method='nsec'` + the
  /// nsec (so a later [boot]/relaunch restores the same account) and returns the
  /// durable identity; it throws [FormatException] on an invalid key (the modal
  /// validates first, but we stay defensive). We then tear down the live
  /// ephemeral session and re-run [init], which boots the now-persisted nsec
  /// identity, rebuilds the relay service + subscriptions under the new pubkey,
  /// and `goLive`s the store — the "re-run the boot→goLive path" that makes the
  /// next state the real account. Finally we bump [bootEpochProvider] so the
  /// boot gate (now seeing a saved login) lands on the shell.
  Future<void> loginWithNsec(String nsec) async {
    final kv = _ref.read(keyValueStoreProvider);
    // Vault-aware secret writes (see the [init] construction site).
    final identityService = IdentityService(
      kv: kv,
      secure: SecureStore(),
      secretWrite: _ref.read(identityVaultProvider).secretSet,
    );
    // Persist method + nsec + pubkey (throws on an invalid key — propagated so
    // the modal can show its existing error and NOT complete).
    await identityService.loginWithNsec(nsec);

    // Re-boot as the persisted nsec account: tear down the ephemeral session,
    // allow a fresh boot on this provider instance, then `init()` restores the
    // saved login and re-subscribes under the new pubkey.
    await _teardownLiveSession();
    _started = false;
    await init();

    // Remount the boot gate so it re-checks (now has a saved login) and tears
    // down the setup modal / shows the shell, mirroring the PWA's post-login
    // `nostrLoginBypassSetup` → `initializeNym` transition out of setup.
    _ref.read(bootEpochProvider.notifier).state++;
  }

  /// Adopts a just-established NIP-46 remote-signer session at RUNTIME — the
  /// native analogue of the PWA's `applyNostrLogin(pubkey, null, 'nip46')`
  /// (app.js:5324). The login modal already ran the `nostrconnect://`
  /// handshake on the shared [nip46ServiceProvider] (persisting the session and
  /// keeping the socket LIVE via `finishNostrConnect`), so this just re-boots
  /// the controller: tear down the ephemeral session, allow a fresh boot, and
  /// `init()` — which now sees `nostrLoginMethod == 'nip46'` and installs a
  /// [Nip46SignerAdapter] (reusing the already-connected instance) as the live
  /// `_signer`. Without this, remote signing only engaged after an app restart.
  Future<void> loginWithNip46() async {
    // `_teardownLiveSession` nulls the ephemeral identity/signer/service but
    // never touches `nip46ServiceProvider`, so the live socket survives into
    // the re-boot below (where `_restoreNip46Signer` adopts it as-is).
    await _teardownLiveSession();
    _started = false;
    await init();
    _ref.read(bootEpochProvider.notifier).state++;
  }

  /// Resets the RUNNING session to a logged-out, first-run state after an
  /// emergency wipe ([PanicWipe] has already shredded the on-disk stores). The
  /// in-memory half of the PWA's `panicWipe` (panic.js:54-144): it nulls
  /// `privkey/pubkey/_vaultMem` and reloads to a pristine first run.
  ///
  /// Drops the in-memory identity / signer / vault handles + the relay service
  /// WITHOUT flushing (panic stops persistence so wiped data is never
  /// re-written, `flush:false`), resets [AppState] to the empty logged-out shell,
  /// allows a fresh boot ([_started] = false), and bumps [bootEpochProvider] so
  /// `app.dart` remounts a fresh [BootGate] — which (no saved login + no
  /// auto-ephemeral after the wipe) lands on the setup screen. The end state:
  /// no identity, no data, setup shown. The boot-epoch bump's `popUntil(first)`
  /// also tears down the panic overlay route, so the caller need not pop it.
  Future<void> resetAfterPanic() async {
    // In-memory teardown only — DO NOT flush (the stores were just wiped; a
    // flush would re-persist the still-live AppState into the reset cache DB).
    await _teardownLiveSession(flush: false);

    // Allow a fresh identity to boot again on this provider instance.
    _started = false;

    // Reset the visible store + identity-scoped UI state to the empty shell.
    _ref.read(appStateProvider.notifier).reset();
    try {
      _ref.read(notificationHistoryProvider.notifier).clear();
    } catch (_) {}
    try {
      _ref.read(pendingSettingsTransfersProvider.notifier).clear();
    } catch (_) {}
    try {
      _ref.read(liveCustomEmojiProvider.notifier).clearAll();
    } catch (_) {}

    // Final sweep (panic.js:136: `localStorage.clear()` right before the
    // reload): drop anything a straggling writer — including the notifier
    // resets above, which persist their now-empty state — re-created between
    // the wipe and here, so the remount really is first-run-pristine.
    try {
      await _ref.read(keyValueStoreProvider).clear();
    } catch (_) {}

    // Reset live settings to first-run defaults from the now-empty store — the
    // PWA's page reload re-reads wiped localStorage; without this the in-memory
    // theme/layout/etc. survive the wipe until the next process launch.
    try {
      _ref.read(settingsProvider.notifier).resetToDefaults();
    } catch (_) {}

    // Re-enable persistence for the NEXT session (the PWA's page reload resets
    // its `_cacheDisabled`); everything the old session could have written is
    // gone by now.
    PanicWipe.inProgress = false;

    // Drive the UI back to a pristine first-run gate (the PWA reloads the page).
    _ref.read(bootEpochProvider.notifier).state++;
  }

  Future<void> signOut() async {
    // Capture before teardown nulls the identity — `cmdQuit` removes the
    // pubkey-scoped lightning address (`nym_lightning_address_${this.pubkey}`,
    // commands.js:1402-1404).
    final pubkey = _identity?.pubkey;

    // 1) Tear down the live session (timers, subs, cache flush+close, relay
    //    service, in-memory identity/signer/handles, unbind callbacks).
    await _teardownLiveSession();

    // 2) Remove the persisted login + auto-ephemeral + per-identity caches the
    //    PWA's `signOut()` clears (app.js:6743-6761).
    final kv = _ref.read(keyValueStoreProvider);
    for (final k in const [
      StorageKeys.autoEphemeral,
      StorageKeys.autoEphemeralNick,
      StorageKeys.autoEphemeralChannel,
      StorageKeys.randomKeypairPerSession,
      StorageKeys.colorMode,
      StorageKeys.purchasesCache,
      StorageKeys.activeStyle,
      StorageKeys.activeFlair,
      StorageKeys.nostrLoginMethod,
      StorageKeys.nostrLoginPubkey,
      StorageKeys.nostrLoginNpub,
      StorageKeys.nostrLoginProfile,
      StorageKeys.nip46RemotePubkey,
      StorageKeys.bio,
      StorageKeys.lightningAddressGlobal,
      StorageKeys.avatarUrl,
      StorageKeys.bannerUrl,
      StorageKeys.customNick,
    ]) {
      await kv.remove(k);
    }
    // `cmdQuit` (the PWA sign-out's disconnect half) also drops the signed-out
    // identity's pubkey-scoped lightning address.
    if (pubkey != null && pubkey.isNotEmpty) {
      await kv.remove(StorageKeys.lightningAddressFor(pubkey));
    }
    // Identity secrets live in the platform keystore (the PWA's `nymSecretRemove`
    // → vault). Clear the session/dev/login keys; leave the NIP-46 client secret
    // removal to the keystore wipe so a half-removed key can't linger.
    final secure = SecureStore();
    for (final s in SecretKeys.all) {
      try {
        await secure.remove(s);
      } catch (_) {}
    }

    // 3) Reset the in-memory store + identity-scoped UI state.
    _ref.read(appStateProvider.notifier).reset();
    try {
      _ref.read(notificationHistoryProvider.notifier).clear();
    } catch (_) {}
    try {
      _ref.read(pendingSettingsTransfersProvider.notifier).clear();
    } catch (_) {}
    try {
      _ref.read(liveCustomEmojiProvider.notifier).clearAll();
    } catch (_) {}
    // Re-read the live settings from the store now that the sign-out keys
    // (colorMode among them) are removed — the PWA's `cmdQuit` reload re-reads
    // the cleared localStorage (commands.js:1409-1411), so the post-sign-out
    // setup screen must not keep the signed-out user's color mode in memory.
    try {
      _ref.read(settingsProvider.notifier).reloadFromStore();
    } catch (_) {}
    // Rebuild the shop controller so its in-memory purchases / active
    // style+flair re-load from the now-cleared `nym_purchases_cache` /
    // `nym_active_*` keys — otherwise a new identity created in this process
    // inherits the signed-out user's cosmetics until a full restart.
    try {
      _ref.invalidate(shopControllerProvider);
    } catch (_) {}

    // 4) Allow a fresh identity to boot again on this provider instance.
    _started = false;

    // 5) Drive the UI back to a pristine first-run gate. The PWA reloads the
    //    page here; we bump the boot generation so `app.dart` remounts a fresh
    //    BootGate (which re-checks setup-needed — now true — and tears down the
    //    signed-out HomeShell + any modals stacked above it).
    _ref.read(bootEpochProvider.notifier).state++;
  }

  MessagingSettings get _msgSettings {
    final s = _ref.read(settingsProvider);
    return MessagingSettings(
      dmForwardSecrecyEnabled: s.dmForwardSecrecyEnabled,
      dmTtlSeconds: s.dmTtlSeconds,
    );
  }

  // ---------------------------------------------------------------------------
  // Inbound routing
  // ---------------------------------------------------------------------------

  /// Relay-service handler (wired in place of a direct `onEvent: _onEvent`):
  /// buffers the event and schedules a coalesced flush so a connect burst is
  /// one rebuild, not N. See [_liveInboundBuffer].
  void _enqueueLiveEvent(NostrEvent event) {
    _liveInboundBuffer.add(event);
    if (_liveInboundBuffer.length >= _kLiveInboundFlushCap) {
      _flushLiveInbound();
    } else {
      _liveInboundTimer ??= Timer(Duration.zero, _flushLiveInbound);
    }
  }

  /// Drains the live inbound buffer, replaying each event through [_onEvent]
  /// inside one [AppStateNotifier.runBatched] so the whole cohort emits once.
  /// Order is preserved; a throwing event is isolated to its own slot (the
  /// service previously delivered one event per call, so a throw could only ever
  /// affect that one event).
  void _flushLiveInbound() {
    _liveInboundTimer?.cancel();
    _liveInboundTimer = null;
    if (_liveInboundBuffer.isEmpty) return;
    final batch = List<NostrEvent>.of(_liveInboundBuffer);
    _liveInboundBuffer.clear();
    _ref.read(appStateProvider.notifier).runBatched(() {
      for (final event in batch) {
        try {
          _onEvent(event);
        } catch (_) {
          // Skip a single malformed/failed event; never abort the batch.
        }
      }
    });
  }

  void _onEvent(NostrEvent event) {
    final appState = _ref.read(appStateProvider.notifier);
    if (event.kind == EventKind.appData) {
      // Kind 30078 is multiplexed by the `['t', ...]` topic (nostr-core.js:
      // 570-577 dispatches on `tTag[1]`): presence / poll / poll-vote / vouches.
      final topic = event.tagValue('t');
      if (topic == AppDataTopic.vouches) {
        _ingestVouch(event);
      } else if (topic == AppDataTopic.poll || topic == AppDataTopic.pollVote) {
        // Live polls/votes from the critical REQ's poll filter (relays.js:
        // 2533-2535) route through the same store ingest the D1 archive
        // replay uses (`handlePollEvent`/`handlePollVoteEvent`).
        appState.ingestEvent(event);
      } else {
        _ingestPresence(event);
      }
      return;
    }
    // NIP-30 custom emoji packs / the user's emoji-pack list (nostr-core.js:595).
    if (event.kind == EventKind.emojiPack) {
      _ingestEmojiPack(event);
      return;
    }
    if (event.kind == EventKind.userEmojiList) {
      _ingestUserEmojiList(event);
      return;
    }
    // Public channel typing (kind 24420) — a peer is typing in a geohash
    // channel. Ephemeral; routed here from the active channel's typing/receipt
    // sub (C03-D6).
    if (event.kind == EventKind.channelTyping) {
      _onChannelTypingEvent(event, appState);
      return;
    }
    // Public channel read receipt (kind 24421) — someone saw one of our channel
    // messages. Ephemeral; routed here from the active channel's typing/receipt
    // sub.
    if (event.kind == EventKind.channelReceipt) {
      _onChannelReadReceipt(event);
      return;
    }
    // Public NIP-57 zap receipt (kind 9735) — a CHANNEL/profile zap on one of
    // our authored messages (or a peer's own-published receipt). Routed here
    // from the `#p:[self]` zap-receipt sub; gift-wrapped private zaps come via
    // `_onPrivateZap` instead. Not an `ingestEvent` kind.
    if (event.kind == EventKind.zapReceipt) {
      _onPublicZapReceipt(event, appState);
      return;
    }
    // A live kind-0 from relays refreshes the D1 profile cache so we don't
    // re-issue a `profile-get` for a profile we just received (mirrors the PWA's
    // `profileFetchedAt` freshness gate).
    if (event.kind == EventKind.profile) {
      _storageSync?.markProfileCached(event.pubkey);
    }
    appState.ingestEvent(event);
    // A SELF kind-0 (live relay update or the login profile-fetch fallback)
    // must also flow onto the live identity + the instant-restore login
    // profile cache (PWA `updateSidebarFromProfile`, app.js:5507-5528).
    if (event.kind == EventKind.profile && event.pubkey == _identity?.pubkey) {
      // Keep the full self kind-0 cached so profile saves merge against the
      // user's REAL profile (nostr-core.js:621-626).
      _adoptSelfKind0(event);
      _syncSelfNymFromProfile();
      // Re-mirror our OWN authoritative signed kind-0 to D1 so a profile edited
      // in another Nostr client — which reaches us over relays — refreshes the
      // D1 public copy other users batch-read (nostr-core.js:632-635 / 2266-2269,
      // `_saveProfileToD1`). Without this the D1 mirror goes stale until the next
      // in-app profile edit.
      _mirrorOwnProfileToD1(event);
    }
    // Public reaction (kind 7) to our message → notify + record (reactions.js
    // `handleReaction` notify block). Skip removals.
    if (event.kind == EventKind.reaction) {
      // Register any NIP-30 custom emoji declared on the reaction BEFORE any
      // routing (reactions.js:206 `this.ingestEmojiTags(event.tags)`) so a
      // custom `:shortcode:` reaction from a peer resolves to its image.
      if (event.tags.isNotEmpty) {
        _ref.read(liveCustomEmojiProvider.notifier).ingestEmojiTags(event.tags);
      }
      final removed =
          event.tagsNamed('action').any((t) => t.length > 1 && t[1] == 'remove');
      // The PWA's `handleReaction` supported-kind gates (reactions.js:216-242):
      // a `k` tag outside 20000/23333/1059/14 is another Nostr app's reaction,
      // and a MISSING `k` tag is only honored when the target is a message we
      // actually hold — without these, any kind-7 that p-tags us (a reaction
      // to a non-Nymchat note) raises a foreign notification.
      final kTag = event.tagValue('k');
      final foreignKind = kTag != null &&
          kTag != '20000' &&
          kTag != '23333' &&
          kTag != '1059' &&
          kTag != '14';
      final target = event.tagValue('e');
      final knownTarget = kTag != null ||
          (target != null &&
              _ref.read(appStateProvider.notifier).isKnownMessageId(target));
      if (!removed && !foreignKind && knownTarget) {
        // Resolve the REACTOR's D1 profile so the reactors sheet (and any
        // future surface) shows their custom avatar, not the identicon — the
        // PWA resolves list/reaction author avatars too (`ensureListProfiles`,
        // reactions.js:631). Guarded + debounced inside; a no-op once we know
        // their picture.
        _maybeBackfillProfiles(event.pubkey);
        final author = event.tagValue('p');
        if (target != null && author != null) {
          _maybeNotifyReaction(
            messageId: target,
            reactorPubkey: event.pubkey,
            targetAuthorPubkey: author,
            emoji: event.content,
            tsSec: event.createdAt,
            eventId: event.id,
            route: event.pubkey,
          );
        }
      }
    }
    // Channel-message notification: a public channel message that @-mentions us
    // (nostr-core.js channel `shouldNotify`). Runs after ingest so the store is
    // current; gating happens in `_maybeNotifyChannel`.
    if (event.kind == EventKind.geoChannel ||
        event.kind == EventKind.namedChannel) {
      // Register any NIP-30 custom emoji declared on the message so its
      // `:shortcode:` tokens render as images (emoji.js `ingestEmojiTags`).
      if (event.tags.isNotEmpty) {
        _ref.read(liveCustomEmojiProvider.notifier).ingestEmojiTags(event.tags);
      }
      // Register an inbound P2P file offer with the service so the rendered
      // file-offer card's download button can request it (nostr-core.js:434 —
      // `parseFileOfferTag` populates `p2pFileOffers`, the store `requestP2PFile`
      // reads). The mapper sets the message's isFileOffer/fileOffer (so the card
      // renders); this side makes the card actionable. Skip our own echo — the
      // offer is registered at share time by `shareP2PFile`.
      if (event.pubkey != (_identity?.pubkey ?? '')) {
        final offer = parseFileOfferTag(event.tags, event.pubkey);
        if (offer != null) {
          _ref.read(p2pServiceProvider).registerOffer(offer);
        }
      }
      _maybeNotifyChannel(event);

      // Web-of-trust observation for a non-own channel message (nostr-core.js:
      // 383-392). Two effects:
      //  (1) ≥2 distinct messages from a sender earns them session trust
      //      (`_trackPubkeyMessage`), exempting them from the spam gate.
      //  (2) NIP-13 PoW meeting the Nymchat floor (16 bits) is a self-attestation
      //      that the sender runs Nymchat → add to the trust graph + our vouch
      //      list (`_markNymchatPubkey` + `_observeNymchatPubkey`).
      _observeMessageTrust(event);

      // Hydrate the author's kind-0 from D1 if we don't have it (the PWA queues
      // a profile fetch for every message author it lacks a profile for —
      // `queueProfileFetch`, nostr-core.js:1767). Debounced/batched.
      _maybeBackfillProfiles(event.pubkey);

      // Send a public read receipt (kind 24421) for a fresh, visible, non-own
      // channel message in the channel we currently have open — the native
      // analogue of the PWA's `addMessageToUI` send (gated on `canBeSeen &&
      // !isOwn && !isHistorical && geohash && id matches`). The open channel is
      // our visibility proxy (no scroll-position tracking on native).
      final self = _identity?.pubkey ?? '';
      final geohash = event.tagValue('g');
      final isGeo = geohash != null && geohash.isNotEmpty;
      // Raw channel-wire key (no `#`) for the receipt's `g`/`d` tag: the geohash
      // for a geo channel, else the named channel's `d` value.
      final wireKey = isGeo ? geohash : event.tagValue('d');
      // `#`-prefixed storage key for the seen check / unread keying.
      final key = EventMapper.channelKeyOf(event);
      // In columns view the "visible" proxy is the deck's seen gate (focused +
      // at-bottom + app visible — the PWA sends the receipt only when
      // `_cvMarkColumnRead` returned true, messages.js:546-555); in single
      // view it degrades to "is the active view". Works for geohash (`g`) and
      // named (`d`) channels alike.
      if (event.pubkey != self &&
          key != null &&
          wireKey != null &&
          wireKey.isNotEmpty &&
          _isChannelMessageId(event.id) &&
          !_isHistorical(event.createdAt) &&
          appState.isConversationSeen(key)) {
        unawaited(sendChannelReadReceipt(event.id, event.pubkey, wireKey,
            isGeohash: isGeo));
      }
    }
  }

  /// Ingests a kind-30030 emoji-pack event into the live custom-emoji store
  /// (emoji.js `handleEmojiPackEvent`): parse the `d`/`title`/`emoji` tags into a
  /// pack (≤120 emoji, deduped) and store it (newest-wins per pubkey:identifier).
  void _ingestEmojiPack(NostrEvent e) {
    // PWA validation (emoji.js:253-255): shortcode must match
    // `^[a-zA-Z0-9_]+$` and the url `^https?://` BEFORE dedup / the 120-cap —
    // invalid tags never count toward the cap, and an all-invalid pack is
    // dropped entirely.
    final rxShortcode = RegExp(r'^[a-zA-Z0-9_]+$');
    final rxUrl = RegExp(r'^https?://', caseSensitive: false);
    final emojis = <({String shortcode, String url})>[];
    final seen = <String>{};
    for (final t in e.tags) {
      if (t.length >= 3 && t[0] == 'emoji') {
        final sc = t[1];
        final url = t[2];
        if (sc.isEmpty || url.isEmpty || seen.contains(sc)) continue;
        if (!rxShortcode.hasMatch(sc) || !rxUrl.hasMatch(url)) continue;
        seen.add(sc);
        emojis.add((shortcode: sc, url: url));
        if (emojis.length >= 120) break;
      }
    }
    if (emojis.isEmpty) return;
    final identifier = e.tagValue('d') ?? '';
    final title = e.tagValue('title') ??
        (identifier.isNotEmpty ? identifier : 'Emoji pack');
    _ref.read(liveCustomEmojiProvider.notifier).storePack(
          CustomEmojiPack(
            pubkey: e.pubkey,
            identifier: identifier,
            title: title,
            createdAt: e.createdAt,
            emojis: emojis,
          ),
        );
  }

  /// Ingests the user's kind-10030 emoji-pack list (emoji.js
  /// `handleUserEmojiListEvent`): our author only; record the `a`-tag pack refs
  /// (`30030:<pubkey>:<id>`) + any inline `emoji` tags (newest event wins).
  void _ingestUserEmojiList(NostrEvent e) {
    final self = _service?.selfPubkey ?? _identity?.pubkey;
    if (self != null && e.pubkey != self) return;
    final refs = <String>[];
    final inlineEmoji = <List<String>>[];
    for (final t in e.tags) {
      if (t.isEmpty) continue;
      if (t[0] == 'a' && t.length > 1 && t[1].startsWith('30030:')) {
        refs.add(t[1]);
      } else if (t[0] == 'emoji' && t.length >= 3) {
        inlineEmoji.add(t);
      }
    }
    _ref.read(liveCustomEmojiProvider.notifier).setUserPackRefs(
          refs,
          e.createdAt,
          inlineEmojiTags: inlineEmoji,
        );
  }

  // ---------------------------------------------------------------------------
  // Inbound notifications (notifications.js `showNotification` gate, wired into
  // the inbound pipeline per the PWA's `handleEvent` notification checks).
  // ---------------------------------------------------------------------------

  /// True when [content] @-mentions the self nym (messages.js `isMentioned`):
  /// matches `@<nym>` optionally followed by our `#suffix`, ignoring blockquoted
  /// (`>`-prefixed) lines so a quoted mention doesn't notify.
  bool _mentionsSelf(String content) {
    final identity = _identity;
    if (identity == null || content.isEmpty) return false;
    final cleanNym = stripPubkeySuffix(identity.nym);
    if (cleanNym.isEmpty) return false;
    final suffix = getPubkeySuffix(identity.pubkey);
    // Strip blockquoted lines (mentions inside quotes don't count).
    final scrubbed = content
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('>'))
        .join('\n');
    final esc = RegExp.escape(cleanNym);
    final sfx = RegExp.escape(suffix);
    // `@nym` followed by `#suffix` OR a boundary that isn't a *different*
    // #abcd suffix (mirrors `_getMentionPattern`'s tail).
    final tail = sfx.isNotEmpty
        ? '(?:#$sfx\\b|(?!#[0-9a-f]{4})(?:\\b|\$))'
        : '(?!#[0-9a-f]{4})(?:\\b|\$)';
    final pattern = RegExp('@$esc$tail', caseSensitive: false);
    return pattern.hasMatch(scrubbed);
  }

  /// Whether a message at [createdAtSec] is historical (replayed backlog):
  /// older than 10s (nostr-core.js `messageAge > 10000`).
  bool _isHistorical(int createdAtSec) =>
      DateTime.now().millisecondsSinceEpoch - createdAtSec * 1000 > 10000;

  bool get _notificationsEnabled =>
      _ref.read(settingsProvider).notificationsEnabled;
  bool get _notifyFriendsOnly =>
      _ref.read(keyValueStoreProvider).getString(StorageKeys.notifyFriendsOnly) ==
      'true';
  bool get _groupNotifyMentionsOnly =>
      _ref
          .read(keyValueStoreProvider)
          .getString(StorageKeys.groupNotifyMentionsOnly) ==
      'true';

  bool _isActiveView(String storageKey) =>
      _ref.read(appStateProvider).view.storageKey == storageKey;

  void _maybeNotifyChannel(NostrEvent e) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    final isOwn = e.pubkey == self;
    final appState = _ref.read(appStateProvider);
    final isBlocked = appState.blockedUsers.contains(e.pubkey);
    final key = EventMapper.channelKeyOf(e);
    final mention = _mentionsSelf(e.content);
    final isActive = key != null && _isActiveView(key);
    // Record gate (history) vs alert gate (sound/popup). A historical channel
    // mention is still added to history silently (nostr-core.js:546-555:
    // `_addNotificationToHistory` in the `isHistorical` branch) — only the loud
    // `showNotification` is suppressed.
    final record = shouldRecordNotification(
      kind: NotifyKind.channel,
      isOwn: isOwn,
      notificationsEnabled: _notificationsEnabled,
      isMention: mention,
      isFriend: appState.isFriend(e.pubkey),
      isBlocked: isBlocked,
      // The verified bot never notifies (notifications.js:14/126) — its public
      // `?ask` reply leads with `@asker#xxxx` and would otherwise pass the
      // channel mention gate.
      isBot: isVerifiedBot(e.pubkey),
      isActiveView: isActive,
      friendsOnly: _notifyFriendsOnly,
    );
    if (!record) return;
    final alert = !_isHistorical(e.createdAt);
    // PWA footer context label for a channel source is `in #<geohash>`
    // (notifications.js, derived from `channelInfo`). `channelKeyOf` already
    // returns the `#`-prefixed key (geohash `g` tag / named `d` tag), so reuse
    // it directly; null for an unkeyed event leaves the label off.
    // A channel @-mention routes to the CHANNEL (notifications.js type
    // 'geohash' → `switchChannel(info.channel, info.geohash)`), NOT the sender's
    // PM. The channel key from `channelKeyOf` is `#`-prefixed; switchChannel
    // takes the bare name (it auto-detects geohash via isChannelGeohash). The
    // sender pubkey is carried separately for the avatar + author; the panel
    // labels it via the `in #<key>` contextLabel.
    final channelRoute =
        key != null ? (key.startsWith('#') ? key.substring(1) : key) : '';
    _dispatchNotification(
      title: _nymDisplayFor(e.pubkey),
      body: e.content,
      senderPubkey: e.pubkey,
      isFriend: appState.isFriend(e.pubkey),
      isMention: mention,
      historyType: channelRoute.isNotEmpty ? 'channel' : 'mention',
      route: channelRoute.isNotEmpty ? channelRoute : e.pubkey,
      eventId: e.id,
      tsMs: e.createdAt * 1000,
      contextLabel: key != null ? 'in $key' : null,
      silent: !alert,
    );
  }

  /// PM/group notification for an ingested [Message] (mirrors the PWA's PM/group
  /// handlers, pms.js:1369-1385 / groups.js:1329-1351). The PWA always records a
  /// qualifying message into the bell history — loudly (`showNotification`) when
  /// it's fresh, silently (`_addNotificationToHistory`) when it's old — so a PM
  /// or group message must reach history regardless of age. Historical here is
  /// the PWA's `msg.isHistorical || ageMs > 30000`: only the loud sound/popup is
  /// gated on it, not the history record. PMs always qualify; group messages
  /// qualify unless mentions-only is on and the message isn't a mention.
  void _maybeNotifyMessage(Message m, {required bool isGroup}) {
    final appState = _ref.read(appStateProvider);
    final mention = _mentionsSelf(m.content);
    final key = m.conversationKey ??
        (isGroup
            ? GroupLogic.groupStorageKey(m.groupId ?? '')
            : (m.conversationPubkey != null
                ? PmLogic.pmStorageKey(m.conversationPubkey!)
                : ''));
    // Record gate (history) — NOT gated on age, so backlog/gift-wrapped PMs and
    // group messages (which always arrive with an old `created_at`) still land
    // in the bell. This is the fix for PMs/group messages never appearing.
    final record = shouldRecordNotification(
      kind: isGroup ? NotifyKind.group : NotifyKind.pm,
      isOwn: m.isOwn,
      notificationsEnabled: _notificationsEnabled,
      isMention: mention,
      isFriend: appState.isFriend(m.pubkey),
      isBlocked: appState.blockedUsers.contains(m.pubkey),
      // A verified-bot sender (fresh Nymbot PM reply) is fully silent — the
      // PWA returns before sound/popup/history (notifications.js:14/126).
      isBot: m.isBot || isVerifiedBot(m.pubkey),
      isActiveView: _isActiveView(key),
      friendsOnly: _notifyFriendsOnly,
      groupMentionsOnly: _groupNotifyMentionsOnly,
    );
    if (!record) return;
    // PWA `treatAsHistorical = msg.isHistorical || ageMs > 30000` — drives the
    // loud alert only. A fresh message alerts; an older one records silently.
    final ageMs = DateTime.now().millisecondsSinceEpoch - m.timestamp;
    final treatAsHistorical = m.isHistorical || ageMs > 30000;
    _dispatchNotification(
      // The panel renders the avatar + decorated `<author#suffix>` from the
      // sender pubkey (like the PWA modal, which keys both off `senderPubkey`),
      // so the title is the bare author for BOTH PM and group; the group name
      // is carried as the `in <GroupName>` context label below (mirrors the PWA
      // modal pulling `groupName` from the context, not rendering the raw title).
      title: m.author,
      body: m.content,
      senderPubkey: m.pubkey,
      isFriend: appState.isFriend(m.pubkey),
      isMention: mention,
      isGroup: isGroup,
      // PM → routes to the peer pubkey; group → routes to the group id. The
      // sender pubkey (for the avatar/author) is carried separately.
      historyType: isGroup ? 'group' : 'pm',
      route: isGroup ? (m.groupId ?? '') : m.pubkey,
      eventId: m.nymMessageId ?? m.id,
      tsMs: m.timestamp,
      // Group footer label `in <GroupName>` (PWA `channelInfo`); PMs leave it
      // null so the panel labels them 'PM' from the type.
      contextLabel: isGroup ? 'in ${_groupNameFor(m.groupId)}' : null,
      silent: treatAsHistorical,
    );
  }

  /// Group display name for a notification title/context (falls back to "Group").
  String _groupNameFor(String? groupId) {
    if (groupId == null) return 'Group';
    final g = _ref.read(appStateProvider.notifier).groupById(groupId);
    return (g != null && g.name.isNotEmpty) ? g.name : 'Group';
  }

  /// Records a notification into the in-app notification history
  /// (`notificationHistoryProvider`) and, unless [silent], also fires the loud
  /// alert (sound + local popup). Mirrors the PWA's two entry points: a fresh
  /// message goes through `showNotification` (alert + history), an old/replayed
  /// one through `_addNotificationToHistory` ([silent] — history only). So the
  /// bell always reflects the message; only the sound/popup is suppressed when
  /// historical. [historyType] is the panel category ('pm' | 'group' | 'mention'
  /// | 'reaction'); [route] is the tap target (peer pubkey or group id);
  /// [eventId] dedupes live + replayed copies.
  void _dispatchNotification({
    required String title,
    required String body,
    required String senderPubkey,
    required bool isFriend,
    required bool isMention,
    bool isGroup = false,
    String historyType = 'pm',
    String? route,
    String? eventId,
    int? tsMs,
    String? contextLabel,
    bool silent = false,
  }) {
    // The verified Nymbot never notifies AT ALL — the PWA returns BEFORE any
    // sound/popup/history in BOTH `showNotification` (notifications.js:14) and
    // `_addNotificationToHistory` (notifications.js:126). This gate must
    // precede the loud path: a fresh Nymbot PM reply landing while another
    // conversation is active would otherwise raise sound + popup.
    if (isVerifiedBot(senderPubkey)) return;
    // Friends-only gates BOTH halves at the entry points (notifications.js:12
    // and :124): with the preference ON, a non-friend's notification neither
    // alerts nor enters the bell history (the message/channel callers pre-gate
    // via `shouldRecordNotification`; group invite/control dispatches rely on
    // this shared gate, exactly like the PWA's `_addNotificationToHistory`).
    if (_notifyFriendsOnly && senderPubkey.isNotEmpty && !isFriend) return;
    // notifications.js `_addNotificationToHistory` (the silent/replayed path)
    // drops events older than 24h (line 135) so a D1 backfill or reconnect
    // replay doesn't resurface stale messages as fresh notifications (badge +
    // modal). The loud `showNotification` path only ever sees live events
    // (<10s old — see `_isHistorical`), so it carries no age gate; mirror that
    // exact split here rather than gating both paths.
    if (silent && tsMs != null) {
      final cutoff24hMs =
          DateTime.now().millisecondsSinceEpoch - 24 * 60 * 60 * 1000;
      if (tsMs < cutoff24hMs) return;
    }
    if (!silent) {
      unawaited(_ref.read(notificationsServiceProvider).notify(
            title: title,
            body: body,
            notifyFriendsOnly: _notifyFriendsOnly,
            groupNotifyMentionsOnly: _groupNotifyMentionsOnly,
            context: NotifyContext(
              senderPubkey: senderPubkey,
              isFriend: isFriend,
              isMention: isMention,
              isGroup: isGroup,
              // Belt-and-suspenders: the top-level gate above already returned
              // for the verified bot; the flag keeps the service's own
              // `context.isBot` gate live (notifications_service.dart:282).
              isBot: isVerifiedBot(senderPubkey),
              // eventId + timestamp engage the service's replay guards
              // (notifications.js:22-69): the 24h backlog age gate, the
              // eventId-precise dedup against the bell history, and the
              // persisted `e:<id>` seen-key — without them the guards fell
              // back to the fuzzy title/body key and "now" timestamps.
              eventId: eventId,
              timestampMs: tsMs,
            ),
          ));
    }
    try {
      _ref.read(notificationHistoryProvider.notifier).record(
            type: historyType,
            title: title,
            body: body,
            route: route ?? senderPubkey,
            ts: tsMs,
            eventId: eventId,
            senderPubkey: senderPubkey,
            contextLabel: contextLabel,
          );
    } catch (_) {
      // History store may be unavailable in teardown; alerting still happened.
    }
  }

  /// Notifies + records history when someone reacts to OUR message (reactions.js
  /// `handleReaction` notify block, lines 336-427). [messageId] is the reacted
  /// message (`e` tag), [reactorPubkey] the reactor, [targetAuthorPubkey] the
  /// reacted message's author (the `p` tag). Fires only when the target is us and
  /// the reactor isn't us (and isn't blocked / notifications are enabled). The
  /// body mirrors the PWA: `reacted <emoji> to: "<preview>"` (or `…to your
  /// message`). [route] is the conversation to open on tap.
  void _maybeNotifyReaction({
    required String messageId,
    required String reactorPubkey,
    required String targetAuthorPubkey,
    required String emoji,
    required int tsSec,
    String? eventId,
    String? route,
  }) {
    if (emoji.isEmpty || messageId.isEmpty) return;
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (self.isEmpty) return;
    // Only notify for reactions to our message, and not our own reaction.
    if (targetAuthorPubkey != self || reactorPubkey == self) return;
    if (!_notificationsEnabled) return;
    final appState = _ref.read(appStateProvider);
    if (appState.blockedUsers.contains(reactorPubkey)) return;
    if (_notifyFriendsOnly && !appState.isFriend(reactorPubkey)) return;

    // Preview of the reacted message (first non-quoted line, ≤80 chars).
    String? preview;
    for (final list in appState.messages.values) {
      for (final m in list) {
        if (m.id == messageId || m.nymMessageId == messageId) {
          preview = m.content
              .split('\n')
              .where((l) => !l.startsWith('>'))
              .join(' ')
              .trim();
          break;
        }
      }
      if (preview != null) break;
    }
    if (preview != null && preview.length > 80) {
      preview = '${preview.substring(0, 80)}…';
    }
    final body = (preview != null && preview.isNotEmpty)
        ? 'reacted $emoji to: "$preview"'
        : 'reacted $emoji to your message';

    // A replayed/backlogged reaction is still recorded to history, silently
    // (reactions.js:2032/2057: `isHistorical ? _addNotificationToHistory :
    // showNotification`). Only a fresh reaction plays the sound/popup.
    _dispatchNotification(
      title: _nymDisplayFor(reactorPubkey),
      body: body,
      senderPubkey: reactorPubkey,
      isFriend: appState.isFriend(reactorPubkey),
      isMention: false,
      historyType: 'reaction',
      route: route ?? reactorPubkey,
      eventId: eventId,
      tsMs: tsSec * 1000,
      silent: _isHistorical(tsSec),
    );
  }

  /// Abbreviates a sats count for the zap notification body, a 1:1 port of the
  /// PWA's `abbreviateNumber` (users.js:2069-2073) used by `_notifyZapToOurMessage`
  /// — kept local so the state layer doesn't import the widget that also exports
  /// it. `<1000` verbatim, `1.2k`/`12k`, `1.2M`.
  static String _abbreviateSats(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final v = n / 1000;
      return '${v.toStringAsFixed(n < 10000 ? 1 : 0)}k';
    }
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }

  /// Notifies + records history when someone zaps OUR message (zaps.js
  /// `_notifyZapToOurMessage`, lines 1347-1421), F07-Z15. Clones the reaction
  /// path ([_maybeNotifyReaction]) with the zap body `⚡ zapped N sats to:
  /// "&lt;preview&gt;"` (or `…to your message`). [messageId] is the zapped message
  /// (`e` tag), [zapperPubkey] the zapper. Fires only when WE are the recipient
  /// and the zapper isn't us (and isn't blocked / notifications are enabled). The
  /// caller already verified `recipient == self` and counted the zap; this raises
  /// the alert the PWA fires alongside the badge. [route] opens the zapper's PM.
  void _maybeNotifyZapToMessage({
    required String messageId,
    required int amountSats,
    required String zapperPubkey,
    required int tsSec,
    String? eventId,
  }) {
    if (messageId.isEmpty || amountSats <= 0) return;
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (self.isEmpty || zapperPubkey == self) return;
    if (!_notificationsEnabled) return;
    final appState = _ref.read(appStateProvider);
    if (appState.blockedUsers.contains(zapperPubkey)) return;
    if (_notifyFriendsOnly && !appState.isFriend(zapperPubkey)) return;

    // Preview of the zapped message (first non-quoted line, ≤80 chars) —
    // mirrors `_notifyZapToOurMessage`'s `rawContent`/message-store lookup.
    String? preview;
    for (final list in appState.messages.values) {
      for (final m in list) {
        if (m.id == messageId || m.nymMessageId == messageId) {
          preview = m.content
              .split('\n')
              .where((l) => !l.startsWith('>'))
              .join(' ')
              .trim();
          break;
        }
      }
      if (preview != null) break;
    }
    if (preview != null && preview.length > 80) {
      preview = '${preview.substring(0, 80)}…';
    }
    final sats = _abbreviateSats(amountSats);
    final body = (preview != null && preview.isNotEmpty)
        ? '⚡ zapped $sats sats to: "$preview"'
        : '⚡ zapped $sats sats to your message';

    // PWA zap notifications route as `type: 'reaction'` to the zapper's PM and
    // are silent (history-only) when historical (>10s, zaps.js:1419).
    _dispatchNotification(
      title: _nymDisplayFor(zapperPubkey),
      body: body,
      senderPubkey: zapperPubkey,
      isFriend: appState.isFriend(zapperPubkey),
      isMention: false,
      historyType: 'reaction',
      route: zapperPubkey,
      eventId: eventId,
      tsMs: tsSec * 1000,
      silent: _isHistorical(tsSec),
    );
  }

  /// Inbound PROFILE-zap receipt ids we've already handled, so a re-delivered
  /// receipt can't double-notify (zaps.js `_profileZapReceipts`, line 1301).
  final Set<String> _profileZapReceipts = <String>{};

  /// Handles an inbound PROFILE zap (a kind-9735 receipt with NO `['e']` tag,
  /// `['p'] == self`) — records nothing to a message badge but notifies the
  /// recipient "⚡ zapped N sats to your profile" (zaps.js
  /// `_handleIncomingProfileZap`, lines 1300-1345), F07-Z16. Deduped by event id;
  /// skips our own zap + blocked senders. Verified iff the receipt author is our
  /// LNURL provider; an unverified zap from a non-provider author appends
  /// "(unverified)" exactly like the PWA. No-ops without an amount.
  void _maybeNotifyProfileZap(NostrEvent event) {
    if (!_profileZapReceipts.add(event.id)) return; // already handled
    if (_profileZapReceipts.length > 2000) {
      _profileZapReceipts
        ..clear()
        ..add(event.id);
    }
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (self.isEmpty) return;
    final appState = _ref.read(appStateProvider);
    if (appState.blockedUsers.contains(event.pubkey)) return;
    final amount = ZapLogic.parseAmountFromBolt11(event.tagValue('bolt11'));
    if (amount == null || amount <= 0) return;
    final zapper = event.pubkey;
    if (zapper == self) return;
    if (!_notificationsEnabled) return;
    if (_notifyFriendsOnly && !appState.isFriend(zapper)) return;

    // Verified iff the receipt author IS our LNURL provider (zaps.js:1322-1324).
    _getZapProviderPubkey(self).then((providerPubkey) {
      // PWA: a provider is configured but this receipt isn't from it → drop.
      if (providerPubkey != null &&
          event.pubkey.toLowerCase() != providerPubkey) {
        return;
      }
      final verified = providerPubkey != null &&
          event.pubkey.toLowerCase() == providerPubkey;
      final sats = _abbreviateSats(amount);
      final body =
          '⚡ zapped $sats sats to your profile${verified ? '' : ' (unverified)'}';
      _dispatchNotification(
        title: _nymDisplayFor(zapper),
        body: body,
        senderPubkey: zapper,
        isFriend: appState.isFriend(zapper),
        isMention: false,
        historyType: 'reaction',
        route: zapper,
        eventId: event.id,
        tsMs: event.createdAt * 1000,
        silent: _isHistorical(event.createdAt),
      );
    }).catchError((_) {});
  }

  void _ingestPresence(NostrEvent e) {
    // nym-presence ingestion (users.js `handlePresenceEvent`). Skip our own
    // presence and stale (older than last-seen) events.
    final isPresence = e.tagsNamed('t').any((t) => t.length > 1 && t[1] == AppDataTopic.presence);
    if (!isPresence) return;
    if (e.tagValue('status') == null) return; // PWA: `if (!statusTag) return`.
    final self = _service?.selfPubkey ?? _identity?.pubkey;
    if (self != null && e.pubkey == self) return;

    final lastTs = _presenceTimestamps[e.pubkey] ?? 0;
    if (e.createdAt < lastTs) return;
    _presenceTimestamps[e.pubkey] = e.createdAt;

    final statusStr = e.tagValue('status');
    final nym = e.tagValue('n');
    final away = e.tagValue('away');
    final avatar = e.tagValue('avatar-update');
    // Shop cosmetics: the `shop-update` presence tag is a pure cache-bust flag
    // (the ONLY shop tag the protocol carries — `publishShopUpdate`,
    // nostr-core.js:2876-2885). The real items live in D1: on an inbound flag
    // we drop the cached record and force-refresh the sender's `shop-status`
    // (users.js:1221-1223 `invalidateShopCache` → shop.js:302-313).
    final hasShopUpdate =
        e.tagsNamed('shop-update').any((t) => t.length > 1 && t[1] == '1');
    if (hasShopUpdate) {
      _ref.read(otherUsersShopProvider.notifier).invalidate(e.pubkey);
    }
    _ref.read(appStateProvider.notifier).setUserPresence(
          pubkey: e.pubkey,
          status: userStatusFromString(statusStr),
          nym: nym,
          awayMessage: away,
          // A bare nym-presence broadcast is NOT activity: the PWA's
          // `handlePresenceEvent` updates status/avatar but never touches
          // `lastSeen` (users.js:1246-1255), so a replayed/older-but-<5min
          // presence must NOT mark a user online (C01-4). Friend-presence and
          // own-activity stay at the default `stampLastSeen: true`.
          lastSeenMs: e.createdAt * 1000,
          stampLastSeen: false,
          avatarUrl: avatar,
          hasAvatarTag: avatar != null,
        );

    // Resolve this user's D1 profile so their custom avatar replaces the
    // identicon even when they never send a message — the PWA resolves avatars
    // for presence/list users too (`queueProfileFetch`/`ensureListProfiles`).
    // No-op when presence already carried an `avatar-update` (picture set); the
    // backfill guard keys on the picture, so it only fetches when one is missing.
    _maybeBackfillProfiles(e.pubkey);
  }

  /// Per-pubkey newest presence timestamp (users.js `presenceTimestamps`) so a
  /// redelivered/older replaceable presence event can't clobber a newer one.
  final Map<String, int> _presenceTimestamps = {};

  // ---------------------------------------------------------------------------
  // Web of trust ("nym-vouch") — kind 30078, `['t','nym-vouches']`. Ported from
  // nostr-core.js (`handleVouchEvent`, `_observeNymchatPubkey`,
  // `publishNymchatVouches`, `_scheduleVouchExpansion`). The trust graph gates
  // channel/PM spam (app_state `isSpamGated`); observing PoW-valid Nymchat
  // activity grows OUR vouch list (published so peers expand through us), and
  // ingesting a trusted peer's vouch list grows the graph (and triggers a
  // one-hop resubscribe so the web of trust expands and then goes quiet).
  // ---------------------------------------------------------------------------

  /// Ingests a peer's kind-30078 `nym-vouches` event (nostr-core.js
  /// `handleVouchEvent`, line 2663). The content is a JSON array of pubkeys the
  /// author vouches for. Only honored when the author is already trusted
  /// (rooted at dev/bot); each valid pubkey is added to the graph. When new
  /// pubkeys appear, schedule a one-hop expansion (resubscribe to the now-larger
  /// author set).
  void _ingestVouch(NostrEvent e) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (e.pubkey.isEmpty || e.pubkey == self) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(e.content.isEmpty ? '[]' : e.content);
    } catch (_) {
      return;
    }
    final list = TrustGraph.parseVouchList(decoded, selfPubkey: self);
    final added = _ref.read(appStateProvider.notifier).ingestVouchList(
          authorPubkey: e.pubkey,
          vouchedPubkeys: list,
        );
    // Newly trusted pubkeys are new vouch authors to fetch — expand one hop via
    // a heavily debounced resubscribe (converges, then goes quiet).
    if (added) {
      _scheduleVouchExpansion();
      _scheduleTrustPersist();
    }
  }

  /// Records an observation that [pubkey] is running Nymchat (valid PoW channel
  /// message or read receipt) — nostr-core.js `_observeNymchatPubkey` (line
  /// 2623). Marks them in the graph AND in our own vouch list, then schedules a
  /// debounced publish of the updated list.
  void _observeNymchatPubkey(String pubkey) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (pubkey.isEmpty || pubkey == self) return;
    final notifier = _ref.read(appStateProvider.notifier);
    notifier.markNymchatPubkey(pubkey);
    final added = notifier.observeNymchatPubkey(pubkey);
    if (added) _scheduleVouchPublish();
    _scheduleTrustPersist();
  }

  /// Web-of-trust observation for a non-own message (nostr-core.js:383-392):
  /// ≥2 distinct messages from a sender earns them session trust
  /// ([AppStateNotifier.trackPubkeyMessage]); a message meeting the NIP-13 PoW
  /// floor is a Nymchat-client self-attestation that adds the sender to the
  /// trust graph + our vouch list ([_observeNymchatPubkey]).
  ///
  /// This MUST run on the D1 archive/backfill path as well as the live relay
  /// path — otherwise, with the web-of-trust spam gate enabled (main.dart), a
  /// channel's restored history from senders who aren't yet trusted is silently
  /// filtered out of the visible list, so the channel "loads nothing" even
  /// though `channel-get` returned the messages.
  void _observeMessageTrust(NostrEvent event) {
    final selfPk = _identity?.pubkey ?? '';
    if (event.pubkey.isEmpty || event.pubkey == selfPk) return;
    final earnedTrust = _ref
        .read(appStateProvider.notifier)
        .trackPubkeyMessage(event.pubkey, event.id);
    if (earnedTrust) _scheduleTrustPersist();
    if (pow.validatePow(event, _nymchatPowFloor)) {
      _observeNymchatPubkey(event.pubkey);
    }
  }

  /// NIP-13 PoW floor (leading zero bits) a channel message must meet to be
  /// treated as a Nymchat-client self-attestation (`this.nymchatPowFloor = 16`,
  /// app.js:556).
  static const int _nymchatPowFloor = 16;

  /// Debounce for the vouch-list publish (nostr-core.js `_scheduleVouchPublish`,
  /// line 2635): at most one publish per 60s, else a 5s coalescing delay.
  Timer? _vouchPublishTimer;
  int _lastVouchPublishAt = 0;

  void _scheduleVouchPublish() {
    if (_vouchPublishTimer != null) return;
    final sinceLast = DateTime.now().millisecondsSinceEpoch - _lastVouchPublishAt;
    final delayMs = sinceLast < 60000 ? 60000 - sinceLast : 5000;
    _vouchPublishTimer = Timer(Duration(milliseconds: delayMs), () {
      _vouchPublishTimer = null;
      unawaited(_publishVouches());
    });
  }

  /// Signs + publishes our `nym-vouches` list (nostr-core.js
  /// `publishNymchatVouches`, line 2645). Best-effort.
  Future<void> _publishVouches() async {
    final service = _service;
    if (service == null) return;
    if (service.pool.connectedCount == 0) return;
    final list = _ref.read(appStateProvider).nymchatVouches.toList();
    if (list.isEmpty) return;
    try {
      await service.publishVouches(list);
      _lastVouchPublishAt = DateTime.now().millisecondsSinceEpoch;
    } catch (_) {
      // best-effort
    }
  }

  /// Debounced (5s coalescing) persist of the three web-of-trust sets to the
  /// on-disk cache, so the graph survives a restart instead of rebuilding cold
  /// every launch (the PWA persists nymchatPubkeys/Vouches/trusted to its meta
  /// store). Scheduled whenever an observation/vouch/earned-trust mutates a set.
  Timer? _trustPersistTimer;
  void _scheduleTrustPersist() {
    if (_trustPersistTimer != null) return;
    _trustPersistTimer = Timer(const Duration(seconds: 5), () {
      _trustPersistTimer = null;
      unawaited(_persistTrust());
    });
  }

  Future<void> _persistTrust() async {
    final cache = _cache;
    if (cache == null) return;
    final s = _ref.read(appStateProvider);
    try {
      await cache.saveMetaSet(CacheStore.metaNymchatPubkeys, s.nymchatPubkeys);
      await cache.saveMetaSet(CacheStore.metaNymchatVouches, s.nymchatVouches);
      await cache.saveMetaSet(CacheStore.metaTrustedPubkeys, s.trustedPubkeys);
    } catch (_) {
      // best-effort
    }
  }

  /// Debounce for the one-hop graph expansion (nostr-core.js
  /// `_scheduleVouchExpansion`, line 2685): 15s after new trusted pubkeys
  /// appear, resubscribe to vouches authored by the now-larger trust set.
  Timer? _vouchExpansionTimer;

  void _scheduleVouchExpansion() {
    if (_vouchExpansionTimer != null) return;
    _vouchExpansionTimer = Timer(const Duration(seconds: 15), () {
      _vouchExpansionTimer = null;
      _subscribeVouches();
    });
  }

  /// Feeds the current trust graph into the critical REQ's DIRECT-mode vouch
  /// filter (relays.js:2538-2542) — a changed author set triggers the debounced
  /// critical resubscribe (nostr-core.js:2685-2693 → `resubscribeAllRelays`).
  /// Called on connect and on each expansion hop; a no-op when the set is
  /// unchanged (e.g. right after boot passed the same list to `start`).
  void _subscribeVouches() {
    final service = _service;
    if (service == null) return;
    final authors = _ref.read(appStateProvider).nymchatPubkeys;
    service.updateCriticalInputs(vouchAuthors: authors);
  }

  /// Buffer of unwrapped gift-wraps awaiting a coalesced ingest. The unwrap +
  /// seal-verify run off-isolate and complete in bursts (one per crypto batch);
  /// routing each completion straight into the store fired one Riverpod rebuild
  /// PER wrap, so a first-load PM/group restore of hundreds of wraps caused a
  /// rebuild storm on the main isolate even though the crypto itself was
  /// off-thread. Coalesce a burst into ONE [AppStateNotifier.runBatched] emit,
  /// mirroring [_flushLiveInbound] for channel events.
  final List<GiftWrapUnwrapped> _giftWrapInbound = <GiftWrapUnwrapped>[];
  Timer? _giftWrapFlushTimer;
  static const int _kGiftWrapFlushCap = 256;

  void _onGiftWrap(GiftWrapUnwrapped u) {
    _giftWrapInbound.add(u);
    if (_giftWrapInbound.length >= _kGiftWrapFlushCap) {
      _flushGiftWrapInbound();
    } else {
      _giftWrapFlushTimer ??= Timer(Duration.zero, _flushGiftWrapInbound);
    }
  }

  /// Drains the unwrapped-gift-wrap buffer through one batched emit. Order is
  /// preserved; a throwing wrap is isolated to its own slot.
  void _flushGiftWrapInbound() {
    _giftWrapFlushTimer?.cancel();
    _giftWrapFlushTimer = null;
    if (_giftWrapInbound.isEmpty) return;
    final batch = List<GiftWrapUnwrapped>.of(_giftWrapInbound);
    _giftWrapInbound.clear();
    _ref.read(appStateProvider.notifier).runBatched(() {
      for (final u in batch) {
        try {
          _processGiftWrap(u);
        } catch (_) {
          // Skip a single malformed/failed wrap; never abort the batch.
        }
      }
    });
  }

  void _processGiftWrap(GiftWrapUnwrapped u) {
    final appState = _ref.read(appStateProvider.notifier);
    final rumor = u.rumor;
    final kind = u.rumorKind;
    final self = _service?.selfPubkey ?? '';

    // Track the peer's PM transport so replies go out in a format they can
    // decrypt (PWA `handleGiftWrapDM`: bitchatUsers / nymUsers). A bitchat-
    // encrypted wrap → bitchat; a NIP-17 wrap carrying an `['x', …]` id → nym.
    final sender = rumor['pubkey'] as String?;
    if (sender != null && sender.isNotEmpty && sender != self) {
      if (u.isBitchat) {
        _bitchatUsers.add(sender);
      } else if (_tags(rumor).any((t) => t.length > 1 && t[0] == 'x')) {
        _nymUsers.add(sender);
      }
    }

    switch (kind) {
      case EventKind.dmRumor: // 14 — PM or group message
        // Archive the durable DM wrap to D1 (PMs + group messages; the PWA
        // archives `event` in `handleGiftWrapDM` BEFORE the group/PM/reaction
        // split, pms.js:1021 — durable content only: messages, reactions, and
        // private zap announcements. Receipts/typing (69420), call signaling,
        // presence, and settings wraps are NOT archived).
        _archiveGiftWrap(u);
        _onRumorMessage(u, appState, self);
      case EventKind.nymReceiptRumor: // 69420 — receipt or typing
        _onReceiptOrTyping(rumor, appState);
      case EventKind.reaction: // 7 — gift-wrapped reaction
        // Durable content: archived like messages (pms.js:1021 runs before the
        // kind-7 branch) — without this, PM/group reactions never reach D1 and
        // vanish on relaunch instead of backfilling.
        _archiveGiftWrap(u);
        _onPrivateReaction(rumor, appState);
      case EventKind.zapReceipt: // 9735 — gift-wrapped private zap announcement
        _archiveGiftWrap(u);
        _onPrivateZap(rumor, appState, u.wrapId);
      case EventKind.callSignaling: // 25053 — call signaling transport
        if (u.senderVerified) _callSignalHandler?.call(rumor);
      case EventKind.friendPresence: // 25054 — friends-only private presence
        if (u.senderVerified) _onFriendPresence(rumor, appState);
      case EventKind.appData: // 30078 — settings transfer / own settings sync
        if (u.senderVerified) _onSettingsRumor(rumor, u);
      default:
        break;
    }
  }

  /// Routes a gift-wrapped kind-30078 rumor (pms.js:840-890): a peer's
  /// user-to-user settings transfer (`d` = `nym-settings-transfer-…`) becomes a
  /// pending offer; EVERY own wrap (any d-tag — a core `nymchat-settings-*`
  /// section, `nymchat-groups`, `nymchat-keys-<gid>`, `nymchat-history-*`,
  /// `nymchat-notifications`, `nymchat-readstate`) is applied ADDITIVELY
  /// unconditionally (pms.js:859-867: `await applyNostrSettingsAdditive(s)`
  /// runs before the core-section ts gate) so a group created / key rotated /
  /// notification read on the user's other device lands LIVE here; a core
  /// section additionally takes the replace-style apply when newer than the
  /// per-section applied ts + stored sync ts — the PWA never prompts for its
  /// own sections.
  void _onSettingsRumor(Map<String, dynamic> rumor, GiftWrapUnwrapped u) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    final tags = _tags(rumor);
    final dTag = _tagValue(tags, 'd') ?? '';
    final senderPubkey = rumor['pubkey'] as String? ?? '';

    // Inbound user-to-user settings transfer (shop.js:1837
    // `handleSettingsTransferEvent`).
    if (dTag.startsWith('nym-settings-transfer-') && senderPubkey != self) {
      _handleSettingsTransferRumor(rumor, tags, u, self);
      return;
    }

    final isOwn = self.isNotEmpty && senderPubkey == self;
    if (!isOwn) return;
    Map<String, dynamic> decoded;
    try {
      final raw = jsonDecode(rumor['content'] as String? ?? '');
      if (raw is! Map) return;
      decoded = Map<String, dynamic>.from(raw);
    } catch (_) {
      // Malformed settings blob — ignore.
      return;
    }

    // Additive merge for EVERY own wrap — this also keeps a core section's
    // additive halves (closedPMs, leftGroups, channelLastRead, group data
    // riding a section wrap) even when the ts gate below rejects the
    // replace-style apply.
    try {
      _applySyncedSettingsAdditive(decoded);
    } catch (_) {
      // Best-effort — the replace-style apply below still runs.
    }

    // Live cross-device settings SECTION from our other device: replace-style
    // apply when strictly newer than both the per-section applied ts and the
    // stored sync ts (pms.js:868-888).
    final isCoreSettings =
        dTag == 'nymchat-settings' || dTag.startsWith('nymchat-settings-');
    if (isCoreSettings && dTag != 'nymchat-settings') {
      final rumorTs = (rumor['created_at'] as num?)?.toInt() ?? 0;
      final kv = _ref.read(keyValueStoreProvider);
      final lastTs = int.tryParse(
              kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ??
          0;
      if (rumorTs > (_appliedSectionTs[dTag] ?? 0) && rumorTs >= lastTs) {
        _appliedSectionTs[dTag] = rumorTs;
        if (rumorTs > lastTs) {
          kv.setString(StorageKeys.lastSettingsSyncTs, '$rumorTs');
        }
        _applySyncedSettings(decoded);
      }
    }
  }

  /// Per-section applied-ts guard for live settings wraps (the PWA's
  /// `_appliedSectionTs`, pms.js:877).
  final Map<String, int> _appliedSectionTs = <String, int>{};

  /// Surfaces an inbound user-to-user settings-transfer rumor as a pending
  /// offer (shop.js:1837-1867): the `settings-transfer-to` tag must name us,
  /// the payload must carry `fromPubkey` + `settings`, the rumor author must
  /// equal `fromPubkey`, and previously-dismissed / already-pending event ids
  /// are dropped. The user resolves it via [acceptUserSettingsTransfer] /
  /// [rejectUserSettingsTransfer] in the settings modal.
  void _handleSettingsTransferRumor(
    Map<String, dynamic> rumor,
    List<List<String>> tags,
    GiftWrapUnwrapped u,
    String self,
  ) {
    final transferTo = _tagValue(tags, 'settings-transfer-to');
    if (transferTo == null || transferTo != self) return;

    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(rumor['content'] as String? ?? '');
      if (decoded is! Map) return;
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    final fromPubkey = data['fromPubkey'] as String? ?? '';
    final settings = data['settings'];
    if (fromPubkey.isEmpty || settings is! Map) return;
    if ((rumor['pubkey'] as String? ?? '') != fromPubkey) return;

    final eventId = u.wrapId;
    if (_dismissedTransferEvents().contains(eventId)) return;
    final notifier = _ref.read(pendingUserSettingsTransfersProvider.notifier);
    if (notifier.containsEventId(eventId)) return;

    final short8 =
        fromPubkey.length >= 8 ? fromPubkey.substring(0, 8) : fromPubkey;
    final fromNym = data['fromNym'] as String? ?? '$short8...';
    notifier.add(UserSettingsTransfer(
      eventId: eventId,
      fromPubkey: fromPubkey,
      fromNym: fromNym,
      nickname: data['nickname'] as String?,
      avatarUrl: data['avatarUrl'] as String?,
      settings: Map<String, dynamic>.from(settings),
      transferredAt: (data['transferredAt'] as num?)?.toInt() ??
          ((rumor['created_at'] as num?)?.toInt() ?? 0),
    ));

    _emitSystemMessage(
        'Settings received from $short8...! Approve from settings modal.');
  }

  /// The persisted dismissed-transfer event ids (`nym_dismissed_transfers`,
  /// app.js:553 / shop.js:1992).
  Set<String> _dismissedTransferEvents() {
    final kv = _ref.read(keyValueStoreProvider);
    final raw = kv.getString(StorageKeys.dismissedTransfers);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toSet();
    } catch (_) {}
    return <String>{};
  }

  /// Persists [eventId] as dismissed (shop.js `dismissTransferEvent`).
  void _dismissTransferEvent(String eventId) {
    final set = _dismissedTransferEvents()..add(eventId);
    _ref.read(keyValueStoreProvider).setString(
        StorageKeys.dismissedTransfers, jsonEncode(set.toList()));
  }

  /// Accepts an inbound user-to-user settings transfer (shop.js:1869-1899
  /// `acceptSettingsTransfer`): applies the sender's nickname (persisted +
  /// republished to our kind-0 profile), avatar, and full settings payload,
  /// then republishes our own sync so the change propagates to our other
  /// devices. Persists the dismissal so the offer never resurfaces.
  Future<bool> acceptUserSettingsTransfer(String eventId) async {
    final notifier = _ref.read(pendingUserSettingsTransfersProvider.notifier);
    final transfer = notifier.removeByEventId(eventId);
    if (transfer == null) return false;
    final identity = _identity;

    final nickname = transfer.nickname;
    final avatarUrl = transfer.avatarUrl;
    if (identity != null && avatarUrl != null && avatarUrl.isNotEmpty) {
      // Avatar applies locally (`userAvatars.set` + `nym_avatar_url`,
      // shop.js:1880-1884).
      _ref
          .read(keyValueStoreProvider)
          .setString(StorageKeys.avatarUrl, avatarUrl);
      _ref.read(appStateProvider.notifier).setUserPresence(
            pubkey: identity.pubkey,
            status: _ref.read(appStateProvider).users[identity.pubkey]?.status ??
                UserStatus.online,
            avatarUrl: avatarUrl,
            hasAvatarTag: true,
            stampLastSeen: false,
          );
    }
    if (identity != null && nickname != null && nickname.isNotEmpty) {
      // Nickname → identity + kind-0 republish (`this.nym = transfer.nickname`
      // + `saveToNostrProfile`, shop.js:1872-1878); the avatar rides the same
      // kind-0 when present.
      await saveProfile(
        name: nickname,
        picture: (avatarUrl != null && avatarUrl.isNotEmpty)
            ? avatarUrl
            : null,
      );
    }

    // Full settings payload through the same apply path as cross-device sync
    // (the PWA routes it through `applyNostrSettings`), then republish our own
    // sync (`saveSyncedSettings`).
    _applySyncedSettings(transfer.settings);
    final lightning = transfer.settings['lightningAddress'];
    if (lightning is String && lightning.isNotEmpty && identity != null) {
      _ref.read(keyValueStoreProvider).setString(
          StorageKeys.lightningAddressFor(identity.pubkey), lightning);
    }
    syncSettings();

    _dismissTransferEvent(eventId);
    _emitSystemMessage(
        'Settings from ${transfer.fromNym} applied successfully!');
    return true;
  }

  /// Rejects an inbound user-to-user settings transfer (shop.js:1984-1990):
  /// drops the offer and persists the dismissal in `nym_dismissed_transfers`.
  bool rejectUserSettingsTransfer(String eventId) {
    final notifier = _ref.read(pendingUserSettingsTransfersProvider.notifier);
    final transfer = notifier.removeByEventId(eventId);
    _dismissTransferEvent(eventId);
    if (transfer != null) {
      _emitSystemMessage(
          'Settings transfer from ${transfer.fromNym} rejected.');
      return true;
    }
    return false;
  }

  /// Ingests an inbound friends-only presence rumor (kind 25054,
  /// nostr-core.js `handleFriendPresenceRumor`): a friend running in "Friends
  /// only" mode shared their real status privately. Verified senders only; we
  /// only honor presence from someone we already know or have friended so a
  /// stranger can't inject themselves as "online".
  void _onFriendPresence(Map<String, dynamic> rumor, AppStateNotifier appState) {
    final pubkey = rumor['pubkey'] as String? ?? '';
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (pubkey.isEmpty || pubkey == self) return;

    final state = _ref.read(appStateProvider);
    if (!state.isFriend(pubkey) && !state.users.containsKey(pubkey)) return;

    final tags = _tags(rumor);
    final status = _tagValue(tags, 'status');
    if (status == null || status == 'hidden') return;

    final nym = _tagValue(tags, 'n');
    final away = _tagValue(tags, 'away');
    appState.setUserPresence(
      pubkey: pubkey,
      status: userStatusFromString(status),
      nym: nym,
      awayMessage: status == 'away' ? away : null,
      lastSeenMs: DateTime.now().millisecondsSinceEpoch,
    );
    // Resolve the friend's D1 profile so their custom avatar loads even without
    // a message this session (guard no-ops once a picture is known).
    _maybeBackfillProfiles(pubkey);
  }

  void _onRumorMessage(
      GiftWrapUnwrapped u, AppStateNotifier appState, String self) {
    final rumor = u.rumor;
    final tags = _tags(rumor);
    final groupId = _tagValue(tags, 'g');
    final type = _tagValue(tags, 'type');
    final senderPubkey = rumor['pubkey'] as String? ?? '';

    // Register any NIP-30 custom emoji declared on the PM/group rumor so its
    // `:shortcode:` tokens render (emoji.js `ingestEmojiTags` runs on every event).
    if (tags.isNotEmpty) {
      _ref.read(liveCustomEmojiProvider.notifier).ingestEmojiTags(tags);
    }

    // Track an advertised group ephemeral key.
    if (groupId != null) {
      final ephPk = _tagValue(tags, 'ephemeral_pk');
      final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
      if (ephPk != null && senderPubkey != self) {
        _groups?.recordMemberKey(groupId, senderPubkey, ephPk, ts);
      }
    }

    // Group control / invite events.
    if (groupId != null && type != null && type != GroupControlType.message) {
      if (!u.senderVerified) return;
      _onGroupControl(groupId, type, tags, senderPubkey, rumor, u, appState);
      return;
    }

    // Incoming group/PM EDIT: a rumor carrying `['edit', originalId]` rewrites
    // the original bubble in place (pms.js:1177-1182 / groups.js:1219-1224
    // `handleIncomingPMEdit`) — it must NOT be ingested as a new message (the
    // user-reported duplicate). `applyLocalEdit` matches PM/group bubbles on the
    // shared nymMessageId; out-of-order arrival is buffered. Applies to both the
    // group and 1:1 PM branches below.
    final editId = _tagValue(tags, 'edit');
    if (editId != null && editId.isNotEmpty) {
      final content = rumor['content'] as String? ?? '';
      appState.applyEditOrDefer(editId, content);
      return;
    }

    // Group message.
    if (groupId != null) {
      if (!u.senderVerified) return;
      final m = _mapGroupMessage(rumor, u, self, groupId);
      if (m == null) return;
      final landed = appState.ingestGroupMessage(m);
      if (landed) {
        // Every group message re-asserts the group's current name (`subject`
        // tag) + member roster — `addGroupConversation(groupId, groupName,
        // memberPubkeys, tsSec * 1000)` runs on EVERY inbound group message
        // (groups.js:1292, `groupName = subjectTag ? subjectTag[1] : 'Group'`
        // at :714), which is how a rename reaches members who missed the
        // owner's `group-metadata` control event. Without this the Flutter
        // sidebar/header/columns titles stayed on the old name forever. A
        // deduped replay skips the merge, like the PWA's dup-check `return`
        // before :1292.
        appState.mergeGroupFromMessage(
          groupId: groupId,
          name: _tagValue(tags, 'subject') ?? 'Group',
          memberPubkeys: [
            for (final t in tags)
              if (t.length > 1 && t[0] == 'p') t[1],
          ],
          timestampMs: m.createdAt * 1000,
        );
        // `meta_ts` piggyback (groups.js:1293-1296): the owner's recent
        // metadata change rides regular messages for a window
        // (`_attachGroupMetaTags`), so members who missed the control event
        // still converge on the new name/avatar/banner/description + invite
        // policy. Same owner-only + monotonic-ts guards as the control path.
        final metaTs = int.tryParse(_tagValue(tags, 'meta_ts') ?? '');
        if (metaTs != null && metaTs > 0) {
          appState.applyGroupControl(
            groupId: groupId,
            type: GroupControlType.metadata,
            tags: tags,
            senderPubkey: senderPubkey,
            ts: metaTs,
            eventId: u.wrapId,
          );
        }
      }
      _maybeNotifyMessage(m, isGroup: true);
      // Backfill the sender's kind-0 from D1 if unknown (PWA `queueProfileFetch`).
      _maybeBackfillProfiles(m.pubkey);
      // Auto-send a delivery receipt to the sender (best-effort).
      if (!m.isOwn && m.nymMessageId != null) {
        final ek = _groups?.keysFor(groupId);
        _service?.publishReceipt(
          messageId: m.nymMessageId!,
          receiptType: 'delivered',
          recipientPubkey: senderPubkey,
          encryptToPubkey: ek?.encryptionPubkeyFor(senderPubkey, self),
        );
        // When the group is the active view, also send a READ receipt so the
        // sender sees our reader avatar (PWA groups.js:1321). Group receipts show
        // as stacked reader avatars, not a checkmark. Scope-gated + deduped.
        if (_isActiveView(GroupLogic.groupStorageKey(groupId))) {
          unawaited(sendGroupReadReceipt(m.nymMessageId!, senderPubkey, groupId));
        }
      }
      return;
    }

    // 1:1 PM message.
    final m = PmLogic.mapPmRumor(
      rumor: rumor,
      wrapId: u.wrapId,
      selfPubkey: self,
      senderVerified: u.senderVerified,
    );
    if (m == null) return;
    // Resolve the display author against the users map — the PWA's
    // `author: isOwn ? this.nym : this.getNymFromPubkey(senderPubkey)`
    // (pms.js:1258 via the `peerName` resolution at :1321). `mapPmRumor` is
    // pure (no store access), so its fallback `nym#xxxx` only stands when the
    // sender is genuinely unknown; a known kind-0/presence nym must win so
    // the PM row/bubbles never show the bare fallback for a known contact.
    if (m.isOwn) {
      final selfNym = _ref.read(appStateProvider).selfNym;
      if (selfNym.isNotEmpty) m.author = selfNym;
    } else {
      m.author = _nymDisplayFor(m.pubkey);
    }
    // "Who can PM you" enforcement (pms.js:1247-1250): `disabled` drops every
    // incoming PM; `friends` drops PMs from non-friends. Our own self-copy is
    // always kept. Previously inert (F02) — the setting persisted/synced but no
    // ingest path consulted it.
    if (!m.isOwn) {
      final scope = _ref.read(settingsProvider).acceptPMs;
      if (scope == 'disabled') return;
      if (scope == 'friends' &&
          !_ref.read(appStateProvider).isFriend(m.pubkey)) {
        return;
      }
    }
    // Nymbot replies may lead with a <think> reasoning block — split it into
    // its own field for ANY verified-bot sender at ingest (`handleGiftWrapDM`,
    // pms.js:1255-1265, the one path every bot reply flows through), so
    // previews/search see only the visible reply and the renderer shows the
    // collapsed Reasoning section no matter how the wrap arrived (relay echo,
    // archive/backlog restore, delegated-signer accounts).
    if (!m.isOwn && isVerifiedBot(m.pubkey)) {
      final tm = RegExp(r'^\s*<think>([\s\S]*?)<\/think>\s*',
              caseSensitive: false)
          .firstMatch(m.content);
      if (tm != null && m.content.substring(tm.end).trim().isNotEmpty) {
        m.thinking = tm.group(1)?.trim();
        m.content = m.content.substring(tm.end);
      }
      m.isBot = true;
    }
    appState.ingestPMMessage(m);
    _maybeNotifyMessage(m, isGroup: false);
    // Backfill the sender's kind-0 from D1 if unknown (PWA `queueProfileFetch`).
    _maybeBackfillProfiles(m.pubkey);
    // Delivery receipt back to the sender (not for our own self-copy).
    if (!m.isOwn && m.nymMessageId != null) {
      _service?.publishReceipt(
        messageId: m.nymMessageId!,
        receiptType: 'delivered',
        recipientPubkey: m.pubkey,
      );
      // If this PM is the active view, also send a READ receipt right away
      // (PWA send-while-viewing, pms.js:1345-1356) so the peer's bubble advances
      // to '✓✓ read'. Scope-gated + deduped inside sendReadReceipt.
      final key = m.conversationKey ?? PmLogic.pmStorageKey(m.pubkey);
      if (_isActiveView(key)) {
        unawaited(sendReadReceipt(m.nymMessageId!, m.pubkey));
      }
    }
  }

  Message? _mapGroupMessage(
    Map<String, dynamic> rumor,
    GiftWrapUnwrapped u,
    String self,
    String groupId,
  ) {
    final content = rumor['content'];
    final senderPubkey = rumor['pubkey'] as String?;
    if (content is! String || senderPubkey == null) return null;
    final tags = _tags(rumor);
    final nymMessageId = _tagValue(tags, 'x');
    final ms = int.tryParse(_tagValue(tags, 'ms') ?? '') ?? 0;
    final createdAtRaw = (rumor['created_at'] as num?)?.toInt() ?? 0;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final createdAt = createdAtRaw > nowSec + 60 ? nowSec : createdAtRaw;
    final isOwn = senderPubkey == self;
    return Message(
      id: u.wrapId.isNotEmpty ? u.wrapId : (nymMessageId ?? ''),
      author: _nymFor(senderPubkey),
      pubkey: senderPubkey,
      content: content,
      createdAt: createdAt,
      originalCreatedAt: createdAtRaw,
      ms: ms,
      isOwn: isOwn,
      isGroup: true,
      groupId: groupId,
      conversationKey: GroupLogic.groupStorageKey(groupId),
      eventKind: EventKind.giftWrap,
      nymMessageId: nymMessageId,
      senderVerified: u.senderVerified,
      deliveryStatus:
          isOwn ? DeliveryStatus.sent : DeliveryStatus.delivered,
    );
  }

  void _onGroupControl(
    String groupId,
    String type,
    List<List<String>> tags,
    String senderPubkey,
    Map<String, dynamic> rumor,
    GiftWrapUnwrapped u,
    AppStateNotifier appState,
  ) {
    // Backfill kind-0 profiles for everyone this control event names — the
    // sender plus all p-tagged members/targets/owner — so members who joined via
    // invite/add-member (and never sent a message) still show their real avatar
    // in the member list + group header instead of an identicon. The PWA fetches
    // these in every groups.js control handler (e.g. :954/:991/:1448).
    // `_maybeBackfillProfiles` self-guards (self / already-pictured / staleness).
    _maybeBackfillProfiles(senderPubkey);
    for (final t in tags) {
      if (t.length > 1 && t[0] == 'p') _maybeBackfillProfiles(t[1]);
    }
    final inviteTs = (rumor['created_at'] as num?)?.toInt() ?? 0;
    // Bootstrap invite: create the local group if we don't have it yet.
    if (type == GroupControlType.invite) {
      // A fresh invite resurrects a group we previously left (F04-H3): clear the
      // "left" mark FIRST so `upsertGroup` (which bails on a left group) accepts
      // it. Mirrors the PWA `leftGroups.delete(groupId)` at the top of the
      // `group-invite` handler (groups.js:798-804). The clear is gated on
      // `created_at > leaveTime` (F04-H4, groups.js:719-722): a stale invite
      // older than our leave is rejected and the group stays gone.
      if (!appState.clearLeftGroup(groupId, createdAtSec: inviteTs)) return;
      final members = tags
          .where((t) => t.length > 1 && t[0] == 'p')
          .map((t) => t[1])
          .toList();
      final owner = _tagValue(tags, 'owner') ?? senderPubkey;
      final name = _tagValue(tags, 'subject') ?? '';
      // Restore the bootstrap metadata the invite carries (groups.js:805-873
      // pre-creates the entry with createdBy/avatar/banner/description) so a
      // re-created group isn't a bare shell (F04-H3 trustBootstrap). Each tag is
      // only adopted when present, byte-matching the PWA's optional pushes.
      final avatar = _tagValue(tags, 'avatar');
      final banner = _tagValue(tags, 'banner');
      final description = _tagValue(tags, 'description');
      final mods = tags
          .where((t) => t.length > 1 && t[0] == 'mod')
          .map((t) => t[1])
          .toList();
      // A bare shell (learned via a group MESSAGE before this invite, planted by
      // `mergeGroupFromMessage` with no owner/avatar) already exists: BACKFILL
      // its owner + appearance from the invite bootstrap instead of dropping them
      // — the custom-group-avatar-missing-in-sidebar bug — then stop (an existing
      // group is not re-notified). Enriching a known group is safe; only CREATING
      // one stays gated below.
      if (appState.groupById(groupId) != null) {
        appState.enrichGroupIdentity(groupId,
            createdBy: owner,
            name: name,
            avatar: avatar,
            banner: banner,
            description: description,
            members: members,
            mods: mods);
        return;
      }
      appState.upsertGroup(Group(
        id: groupId,
        name: name,
        members: members,
        mods: mods,
        createdBy: owner,
        avatar: (avatar != null && avatar.isNotEmpty) ? avatar : null,
        banner: (banner != null && banner.isNotEmpty) ? banner : null,
        description:
            (description != null && description.isNotEmpty) ? description : null,
        allowMemberInvites: _tagValue(tags, 'allow_invites') != '0',
        inviteEnabled: _tagValue(tags, 'invite_enabled') == '1',
        inviteEpoch: int.tryParse(_tagValue(tags, 'invite_epoch') ?? '') ?? 0,
        lastMessageTime: DateTime.now().millisecondsSinceEpoch,
      ));
      // Group invite notification (groups.js:851-871 `Group invite: <name>`).
      if (_notificationsEnabled &&
          !_ref.read(appStateProvider).blockedUsers.contains(senderPubkey)) {
        // Body is the invite rumor's own content when present, else the PWA's
        // fallback line (groups.js:856 `rumor.content || "You've been added
        // to group ..."`).
        final content = rumor['content'];
        final body = (content is String && content.isNotEmpty)
            ? content
            : 'You\'ve been added to group "${name.isNotEmpty ? name : 'group'}"';
        // Live-vs-history gate (groups.js:857-859): a backlog/boot replay of
        // an invite records silently; only a fresh invite (≤30s old) takes the
        // loud sound/popup path. The PWA also flags `_isGiftWrapBacklog()`;
        // gift-wrap backlog replays carry the rumor's REAL created_at, so the
        // 30s age term covers them here.
        final inviteAgeMs =
            DateTime.now().millisecondsSinceEpoch - inviteTs * 1000;
        final isHistorical = inviteTs <= 0 || inviteAgeMs > 30000;
        _dispatchNotification(
          title: 'Group invite: ${name.isNotEmpty ? name : 'group'}',
          body: body,
          senderPubkey: senderPubkey,
          isFriend: _ref.read(appStateProvider).isFriend(senderPubkey),
          isMention: false,
          isGroup: true,
          historyType: 'group',
          route: groupId,
          eventId: u.wrapId,
          tsMs: inviteTs > 0 ? inviteTs * 1000 : null,
          // Group source → footer label `in <GroupName>` (PWA `channelInfo`).
          contextLabel: 'in ${name.isNotEmpty ? name : 'a group'}',
          silent: isHistorical,
        );
      }
      // Render the invite's content as the first in-chat bubble (F04-M2): the
      // PWA "falls through to display the invite message inline" after creating
      // the group (groups.js:874), so the new group opens with the "You've been
      // added to group …" message instead of empty. `_mapGroupMessage` returns
      // null for an empty/own-copy rumor, so a content-less invite stays empty.
      final inviteMsg =
          _mapGroupMessage(rumor, u, _identity?.pubkey ?? '', groupId);
      if (inviteMsg != null && inviteMsg.content.isNotEmpty) {
        appState.ingestGroupMessage(inviteMsg);
      }
      return;
    }

    // Invite-link join approval (groups.js:506 `_handleGroupJoinRequest`, called
    // at 790-792): when WE are the link sharer and receive a `group-join-request`,
    // auto-admit the requester if invites are enabled, we can add members, the
    // request's epoch matches our current invite epoch, and they aren't already a
    // member/banned. Without this the joiner's request (joinGroupViaInvite,
    // :2583, which sends `invite_epoch`) lands in the void — the whole invite-link
    // join never completes (F04-H2). This must run BEFORE the generic
    // `applyGroupControl` (join-request has no `applyControlEvent` case → ignored).
    if (type == GroupControlType.joinRequest) {
      final group = appState.groupById(groupId);
      if (group == null) return;
      if (!group.inviteEnabled) return;
      final identity = _identity;
      if (identity == null) return;
      // Never act on our own request echoing back.
      if (senderPubkey == identity.pubkey) return;
      if (!GroupLogic.canAddMembers(group, identity.pubkey)) return;
      final reqEpoch = int.tryParse(_tagValue(tags, 'invite_epoch') ?? '') ?? 0;
      if (reqEpoch != group.inviteEpoch) return;
      if (group.members.contains(senderPubkey)) return;
      if (group.banned.contains(senderPubkey)) return;
      unawaited(addGroupMembers(groupId, [senderPubkey]));
      return;
    }

    // A `group-add-member` that re-adds US clears the "left" mark so the group
    // can resurrect (F04-H3): mirrors the PWA `leftGroups.delete(groupId)` at the
    // top of the `group-add-member` handler (groups.js:879-884). Runs before
    // `applyGroupControl` so a still-known-but-left group accepts the re-add.
    if (type == GroupControlType.addMember) {
      final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
      final addsSelf = self.isNotEmpty &&
          tags.any((t) => t.length > 1 && t[0] == 'p' && t[1] == self);
      if (addsSelf) {
        // Gate on `created_at > leaveTime` (F04-H4): a stale re-add older than
        // our leave is rejected and the group stays gone (groups.js:719-722).
        if (!appState.clearLeftGroup(groupId, createdAtSec: inviteTs)) return;
        // F04-H3 (FULL): if the group was FULLY removed locally (self-kick did
        // `state.groups.removeWhere`), `applyGroupControl` would bail with
        // `groupById == null` and the add-member would never land. Re-create the
        // entry from the add-member's trusted bootstrap tags — but only when the
        // claimed owner IS the sender (`senderIsClaimedOwner`, groups.js:900-904)
        // so a non-owner can't conjure a group into the sidebar. Mirrors the
        // PWA's `trustBootstrap` create (groups.js:912-934).
        final claimedOwner = _tagValue(tags, 'owner');
        final members = tags
            .where((t) => t.length > 1 && t[0] == 'p')
            .map((t) => t[1])
            .toList();
        final name = _tagValue(tags, 'subject') ?? '';
        final avatar = _tagValue(tags, 'avatar');
        final banner = _tagValue(tags, 'banner');
        final description = _tagValue(tags, 'description');
        final mods = tags
            .where((t) => t.length > 1 && t[0] == 'mod')
            .map((t) => t[1])
            .toList();
        if (appState.groupById(groupId) == null) {
          if (claimedOwner != null && claimedOwner == senderPubkey) {
            final allowInv = _tagValue(tags, 'allow_invites');
            final inviteEnabledTag = _tagValue(tags, 'invite_enabled');
            final inviteEpochTag = _tagValue(tags, 'invite_epoch');
            appState.upsertGroup(Group(
              id: groupId,
              name: name,
              members: members,
              mods: mods,
              createdBy: claimedOwner,
              avatar: (avatar != null && avatar.isNotEmpty) ? avatar : null,
              banner: (banner != null && banner.isNotEmpty) ? banner : null,
              description: (description != null && description.isNotEmpty)
                  ? description
                  : null,
              allowMemberInvites: allowInv != null ? allowInv != '0' : true,
              inviteEnabled: inviteEnabledTag == '1',
              inviteEpoch: int.tryParse(inviteEpochTag ?? '') ?? 0,
              lastMessageTime: inviteTs > 0
                  ? inviteTs * 1000
                  : DateTime.now().millisecondsSinceEpoch,
            ));
          }
        } else {
          // The group is already known — possibly a bare message-shell with no
          // owner/avatar (member added by a NON-owner never hit the create above,
          // which stays owner-gated to block spoofed conjuring). Backfill its
          // owner + appearance from the add-member bootstrap so the sidebar shows
          // the custom avatar; enriching a group we're already in is safe.
          appState.enrichGroupIdentity(groupId,
              createdBy: claimedOwner,
              name: name,
              avatar: avatar,
              banner: banner,
              description: description,
              members: members,
              mods: mods);
        }
      }
    }

    final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
    // Resolve the group's display name BEFORE applying the control: a self-kick/
    // ban makes `applyGroupControl` drop the group locally (app_state.dart:1671),
    // after which `groupById` is null — but the "Removed from <group>"
    // notification still needs the name (PWA `groupName`, groups.js:714 →
    // `grp.name || groupName`).
    final groupNameForNotif = appState.groupById(groupId)?.name;
    final result = appState.applyGroupControl(
      groupId: groupId,
      type: type,
      tags: tags,
      senderPubkey: senderPubkey,
      ts: ts,
      eventId: u.wrapId,
    );
    if (result == GroupControlResult.applied) {
      _emitGroupControlSystemLine(groupId, type, tags, senderPubkey);
      _maybeNotifyGroupControl(
        groupId: groupId,
        groupName: groupNameForNotif,
        type: type,
        tags: tags,
        senderPubkey: senderPubkey,
        ts: ts,
        eventId: u.wrapId,
      );
    }
  }

  /// Dispatches the PWA's SELF-TARGETED group-control notification when an
  /// inbound control event (kick/ban/promote/revoke/transfer/unban) is applied
  /// AND it targets us (F04-H4 / CC-18). The in-chat system line for ALL members
  /// is emitted separately by [_emitGroupControlSystemLine]; this is the
  /// "you might not have the group open" alert the PWA also fires
  /// (groups.js:736/1016/1078/1116/1156). Gated exactly like the PWA's
  /// `_addNotificationToHistory`/`showNotification`: skip when WE are the actor,
  /// when the sender is blocked, and when notifications are disabled. A
  /// historical event (>10s old) records to history only (no toast) — mirrored
  /// here via `silent: true`. Title/body strings are verbatim from the PWA.
  void _maybeNotifyGroupControl({
    required String groupId,
    required String? groupName,
    required String type,
    required List<List<String>> tags,
    required String senderPubkey,
    required int ts,
    String? eventId,
  }) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (self.isEmpty) return;
    // Never notify for our own action (PWA `if (isOwn) return`).
    if (senderPubkey == self) return;
    if (!_notificationsEnabled) return;
    final appState = _ref.read(appStateProvider);
    if (appState.blockedUsers.contains(senderPubkey)) return;

    // PWA fallback chain: `grp.name || groupName` where `groupName = subjectTag
    // ? subjectTag[1] : 'Group'` (groups.js:714).
    final name = (groupName != null && groupName.isNotEmpty)
        ? groupName
        : (_tagValue(tags, 'subject') ?? 'Group');
    final actor = _nymDisplayFor(senderPubkey);

    String? title;
    String? body;
    switch (type) {
      case GroupControlType.removeMember:
        // Self-kick/ban only — the `kick` tag is the removed member.
        if (_tagValue(tags, 'kick') != self) return;
        final banned =
            tags.any((t) => t.length > 1 && t[0] == 'ban' && t[1] == '1');
        title = banned ? 'Banned from $name' : 'Removed from $name';
        body = banned
            ? '$actor banned you. You can be re-invited only by the group owner.'
            : '$actor removed you from the group.';
      case GroupControlType.promoteMod:
        if (_tagValue(tags, 'mod') != self) return;
        title = 'Promoted in $name';
        body = '$actor made you a moderator.';
      case GroupControlType.revokeMod:
        if (_tagValue(tags, 'mod') != self) return;
        title = 'Moderator removed in $name';
        body = '$actor revoked your moderator role.';
      case GroupControlType.transferOwner:
        if (_tagValue(tags, 'owner') != self) return;
        title = 'Owner of $name';
        body = '$actor transferred group ownership to you.';
      case GroupControlType.unban:
        if (_tagValue(tags, 'unban') != self) return;
        title = 'Unbanned from $name';
        body = '$actor unbanned you from "$name". You may be re-invited.';
      default:
        return;
    }
    // Every non-returning case above assigns both title + body, and `default`
    // returns — so the analyzer promotes them to non-null here for the
    // `required String` notification params.

    // Historical (>10s) → record to history only, no toast (PWA `isHistorical`).
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final silent = (nowSec - ts) > 10;

    _dispatchNotification(
      title: title,
      body: body,
      senderPubkey: senderPubkey,
      isFriend: appState.isFriend(senderPubkey),
      isMention: false,
      isGroup: true,
      historyType: 'group',
      route: groupId,
      eventId: eventId,
      tsMs: ts > 0 ? ts * 1000 : null,
      silent: silent,
    );
  }

  /// Emits the PWA's in-chat system line for an applied inbound group control
  /// (groups.js: leave 777 / removed 1045 / added 961 / promoted 1074 /
  /// revoked 1113 / transferred 1153 / deleted 1194), F04-H4. Routed to the
  /// group's message flow so it shows when the group is opened, mirroring
  /// `displaySystemMessage`. Skipped when WE were the removed member (the group
  /// is dropped locally, so there's nowhere to show it — the PWA navigates away).
  void _emitGroupControlSystemLine(
    String groupId,
    String type,
    List<List<String>> tags,
    String senderPubkey,
  ) {
    final appState = _ref.read(appStateProvider.notifier);
    // For a removal, the group may already be gone (we were kicked) — bail so we
    // don't recreate an orphan message list for a group we just left.
    if (appState.groupById(groupId) == null) return;
    final actor = _nymDisplayFor(senderPubkey);
    String? line;
    switch (type) {
      case GroupControlType.leave:
        line = '$actor left the group.';
      case GroupControlType.removeMember:
        final target = _tagValue(tags, 'kick');
        if (target == null) break;
        final banned = tags.any((t) => t.length > 1 && t[0] == 'ban' && t[1] == '1');
        line = banned
            ? '${_nymDisplayFor(target)} was banned by $actor.'
            : '${_nymDisplayFor(target)} was removed by $actor.';
      case GroupControlType.addMember:
        final added = tags
            .where((t) => t.length > 1 && t[0] == 'p')
            .map((t) => _nymDisplayFor(t[1]))
            .toList();
        if (added.isEmpty) break;
        line = '${added.join(', ')} was added by $actor.';
      case GroupControlType.promoteMod:
        final target = _tagValue(tags, 'mod');
        if (target != null) line = '$actor made ${_nymDisplayFor(target)} a moderator.';
      case GroupControlType.revokeMod:
        final target = _tagValue(tags, 'mod');
        if (target != null) {
          line = '$actor removed ${_nymDisplayFor(target)} as a moderator.';
        }
      case GroupControlType.transferOwner:
        final target = _tagValue(tags, 'owner');
        if (target != null) {
          line = '$actor transferred ownership to ${_nymDisplayFor(target)}.';
        }
      case GroupControlType.unban:
        final target = _tagValue(tags, 'unban');
        if (target != null) line = '${_nymDisplayFor(target)} was unbanned by $actor.';
      case GroupControlType.deleteMessage:
        final author = _tagValue(tags, 'target_pubkey');
        line = author != null
            ? '$actor deleted a message from ${_nymDisplayFor(author)}.'
            : '$actor deleted a message.';
    }
    if (line == null || line.isEmpty) return;
    appState.addSystemMessage(line, storageKey: GroupLogic.groupStorageKey(groupId));
  }

  void _onReceiptOrTyping(
      Map<String, dynamic> rumor, AppStateNotifier appState) {
    if (PmLogic.isTyping(rumor)) {
      final info = PmLogic.parseTyping(rumor);
      if (info == null || info.pubkey == null) return;
      // Stale typing indicators are dropped. PWA drops at `_typingExpireMs/1000`
      // = 5s (pms.js:924 / nostr-core.js:1547), C03-D5.
      final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 -
          ((rumor['created_at'] as num?)?.toInt() ?? 0);
      if (age > 5) return;
      final storageKey = info.groupId != null
          ? GroupLogic.groupStorageKey(info.groupId!)
          : PmLogic.pmStorageKey(info.pubkey!);
      appState.setTyping(
        storageKey: storageKey,
        pubkey: info.pubkey!,
        typing: info.isStart,
      );
      return;
    }
    if (PmLogic.isReceipt(rumor)) {
      final info = PmLogic.parseReceipt(rumor);
      if (info != null) {
        appState.applyReceipt(info);
        // A delivery/read receipt acks the PM → drop it from the auto-retry
        // queue (pms.js: `retryPendingDMs` removes any entry whose status left
        // 'sent'). Keyed by `nymMessageId`, which the receipt's messageId is.
        _pendingDms.remove(info.messageId);
      }
    }
  }

  void _onPrivateReaction(
      Map<String, dynamic> rumor, AppStateNotifier appState) {
    // Reactions land in app_state's reaction store via a synthetic event.
    final tags = _tags(rumor);
    // Register any NIP-30 custom emoji declared on the rumor (the PWA ingests
    // EVERY unwrapped DM rumor's tags before the kind-7 routing, pms.js:898)
    // so a private custom-emoji reaction resolves to its image.
    if (tags.isNotEmpty) {
      _ref.read(liveCustomEmojiProvider.notifier).ingestEmojiTags(tags);
    }
    final target = _tagValue(tags, 'e');
    if (target == null) return;
    final pubkey = rumor['pubkey'] as String? ?? '';
    final content = rumor['content'] as String? ?? '';
    final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
    final action = tags.any((t) => t.length > 1 && t[0] == 'action' && t[1] == 'remove');
    // The reacted message's author (`p` tag); reaction targets us when this is
    // our pubkey. Group reactions also carry the group id (`g`) for routing.
    final targetAuthor = _tagValue(tags, 'p') ?? '';
    final groupId = _tagValue(tags, 'g');
    final synthetic = NostrEvent(
      pubkey: pubkey,
      createdAt: ts,
      kind: EventKind.reaction,
      tags: [
        ['e', target],
        ['p', targetAuthor.isNotEmpty ? targetAuthor : pubkey],
        if (action) ['action', 'remove'],
        // Forward the rumor's NIP-30 emoji declarations so downstream
        // consumers of the synthetic event keep them (pms.js keeps the full
        // rumor tags through `handleReaction`).
        for (final t in tags)
          if (t.length >= 3 && t[0] == 'emoji') ['emoji', t[1], t[2]],
      ],
      content: content,
    );
    appState.ingestEvent(synthetic);

    // Notify + record when someone reacts to OUR PM/group message (pms.js:2032 /
    // groups reaction notify). Skip removals.
    if (!action) {
      _maybeNotifyReaction(
        messageId: target,
        reactorPubkey: pubkey,
        targetAuthorPubkey: targetAuthor,
        emoji: content,
        tsSec: ts,
        route: groupId ?? pubkey,
      );
    }
  }

  /// Routes a gift-wrapped private zap announcement (kind 9735 rumor, sent to
  /// PM/group members). Accrues sats to the zapped message's aggregate. The
  /// rumor carries an `['e', msgId]`, `['p', recipient]`, `['bolt11', …]`.
  void _onPrivateZap(
      Map<String, dynamic> rumor, AppStateNotifier appState, String wrapId) {
    final tags = _tags(rumor);
    final messageId = _tagValue(tags, 'e');
    final bolt11 = _tagValue(tags, 'bolt11');
    if (messageId == null || bolt11 == null) return;
    final amount = ZapLogic.parseAmountFromBolt11(bolt11);
    if (amount == null) return;
    final zapper = rumor['pubkey'] as String? ?? '';
    // A gift-wrapped private zap is zapper-signed, so it is NOT cryptographically
    // verified against the recipient's LNURL provider pubkey (zaps.js treats the
    // gift-wrap announcement as unverified — the badge tooltip flags the sats).
    // Deduped by bolt11 so our own self-record (verified) and this announcement
    // of the SAME payment can't double-count: whichever lands first wins the
    // count, and the verified self-record upgrades it out of `unverified`.
    final counted = appState.recordMessageZap(
      messageId: messageId,
      zapperPubkey: zapper,
      amountSats: amount,
      dedupKey: ZapLogic.dedupKey(bolt11: bolt11, eventId: ''),
      verified: false,
    );
    // Resolve the zapper's avatar (the zappers sheet / badge), like the PWA
    // resolves zap-list authors (`ensureListProfiles`, zaps.js:223).
    if (zapper.isNotEmpty) _maybeBackfillProfiles(zapper);
    // Notify the recipient when THEIR PM/group message was zapped (Z15): only on
    // a freshly-counted zap and when the gift-wrap targets us (`['p'] == self`)
    // from someone other than us. Mirrors pms.js:1102-1104 /
    // groups.js:handleGroupZap which call `_notifyZapToOurMessage` after
    // `_recordMessageZap`. The gift-wrap `p` is the recipient.
    if (counted && zapper.isNotEmpty) {
      final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
      final pTag = _tagValue(tags, 'p');
      if (self.isNotEmpty && pTag == self && zapper != self) {
        _maybeNotifyZapToMessage(
          messageId: messageId,
          amountSats: amount,
          zapperPubkey: zapper,
          tsSec: (rumor['created_at'] as num?)?.toInt() ?? 0,
          eventId: wrapId, // wrap id = the PWA's `event.id` dedup key
        );
      }
    }
  }

  /// Event ids of kind-9735 receipts WE published ourselves (channel announce,
  /// [announceMessageZap]) so the `#p:[self]` zap-receipt sub echoing them back
  /// is ignored — our own zap is already recorded at payment time (zaps.js
  /// `_ownPublishedZapIds`, handleZapReceipt:1152). Capped to bound memory.
  final Set<String> _ownPublishedZapIds = <String>{};

  /// Routes an inbound PUBLIC kind-9735 zap receipt (channel/profile zap) for one
  /// of our authored messages. Mirrors the channel/message arm of zaps.js
  /// `handleZapReceipt` (lines 1147-1284): parse the `e`/`p`/`bolt11` tags,
  /// resolve whether it's VERIFIED (the receipt's event pubkey equals the
  /// recipient's LNURL provider pubkey), and accrue the sats to the message —
  /// deduped by bolt11 so the LNURL provider's receipt, our own self-record, and
  /// a peer's own-published echo of the SAME payment never multi-count.
  ///
  /// Profile zaps (no `['e', …]` tag) don't accrue to a message and are skipped
  /// here (the PWA handles them via a separate notification path).
  void _onPublicZapReceipt(NostrEvent event, AppStateNotifier appState) {
    // Ignore the receipt we just published ourselves echoing back.
    if (_ownPublishedZapIds.contains(event.id)) return;
    if (_ref.read(appStateProvider).blockedUsers.contains(event.pubkey)) return;

    // Archive channel/pm (keyed on the e tag) and profile receipts (keyed on
    // the recipient pubkey) to D1 so `zap-get` backfill can serve them
    // (zaps.js:1164 `if (boltTag) this._archiveZapReceipt(…)`; the scope +
    // e-tag gating lives inside [ZapArchive.archive]).
    if (event.tagValue('bolt11') != null) _zapArchive?.archive(event);

    final info = ZapLogic.parseReceipt(event);
    if (info == null) {
      // No `['e']` tag → not a message zap. A PROFILE zap (`['p'] == self`, no
      // `e`) still notifies the recipient (zaps.js:1217-1220 → Z16); everything
      // else (unparseable bolt11, someone else's profile) is dropped.
      final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
      if (event.tagValue('e') == null &&
          self.isNotEmpty &&
          event.tagValue('p') == self) {
        _maybeNotifyProfileZap(event);
      }
      return;
    }
    final messageId = info.messageId;
    final amount = info.amountSats;
    final recipientPubkey = info.recipientPubkey;
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';

    // Resolve the recipient's LNURL provider pubkey, then decide verified:
    // VERIFIED ⇔ the receipt author IS that provider (zaps.js:1259-1260).
    _getZapProviderPubkey(recipientPubkey).then((providerPubkey) {
      final verified = providerPubkey != null &&
          event.pubkey.toLowerCase() == providerPubkey;
      // Attribute the zap to the requester (description's kind-9734 author) when
      // verified; otherwise to the receipt's own author (zaps.js zapper logic,
      // simplified — we don't parse the description here, so fall back to the
      // event author, which is correct for both the provider-verified and the
      // peer-published-receipt cases).
      final zapper = info.zapperPubkey;
      if (_ref.read(appStateProvider).blockedUsers.contains(zapper)) return;
      final counted = appState.recordMessageZap(
        messageId: messageId,
        zapperPubkey: zapper,
        amountSats: amount,
        dedupKey: info.dedupKey, // 'b:'+bolt11.toLowerCase()
        verified: verified,
      );
      if (zapper.isNotEmpty) _maybeBackfillProfiles(zapper);
      // Notify the recipient when THEIR message was zapped (Z15): only on a
      // freshly-counted zap, when we're the recipient, the zapper isn't us, and
      // the zap is verified OR the recipient has no provider pubkey (matching
      // zaps.js:1279-1283 `if (verified || !providerPubkey)`).
      if (counted &&
          self.isNotEmpty &&
          recipientPubkey == self &&
          zapper != self &&
          (verified || providerPubkey == null)) {
        _maybeNotifyZapToMessage(
          messageId: messageId,
          amountSats: amount,
          zapperPubkey: zapper,
          tsSec: event.createdAt,
          eventId: event.id,
        );
      }
    }).catchError((_) {});
  }

  /// Cache: recipient pubkey → resolved LNURL provider Nostr pubkey (lowercased)
  /// or null. Mirrors zaps.js `_zapProviderPubkeys` (line 1464) — the NIP-57
  /// receipt is "verified" only when its author equals this provider pubkey.
  final Map<String, String?> _zapProviderPubkeys = {};
  final Map<String, Future<String?>> _zapProviderLookups = {};

  /// Resolves [recipientPubkey]'s LNURL provider Nostr pubkey (the `nostrPubkey`
  /// in their `.well-known/lnurlp` metadata), cached + de-duplicated like the
  /// PWA's `_getZapProviderPubkey` (zaps.js:1462). Returns null when the user has
  /// no lightning address, the provider doesn't advertise a Nostr pubkey, or the
  /// fetch fails. Used to mark public zap receipts verified/unverified.
  Future<String?> _getZapProviderPubkey(String? recipientPubkey) async {
    if (recipientPubkey == null || recipientPubkey.isEmpty) return null;
    if (_zapProviderPubkeys.containsKey(recipientPubkey)) {
      return _zapProviderPubkeys[recipientPubkey];
    }
    final inflight = _zapProviderLookups[recipientPubkey];
    if (inflight != null) return inflight;
    final lookup = () async {
      try {
        final lnAddress = _ref
            .read(appStateProvider)
            .users[recipientPubkey]
            ?.profile
            ?.lightningAddress;
        if (lnAddress == null || lnAddress.isEmpty) return null;
        final params = await Lnurl.fetchPayParams(lnAddress);
        final pk = params.nostrPubkey;
        if (params.allowsNostr &&
            pk != null &&
            RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(pk)) {
          return pk.toLowerCase();
        }
        return null;
      } catch (_) {
        return null;
      }
    }();
    _zapProviderLookups[recipientPubkey] = lookup;
    final pk = await lookup;
    _zapProviderLookups.remove(recipientPubkey);
    _zapProviderPubkeys[recipientPubkey] = pk;
    return pk;
  }

  // ---------------------------------------------------------------------------
  // Call signaling (kind 25053) — transport only; WebRTC is the calls agent's.
  // ---------------------------------------------------------------------------

  void Function(Map<String, dynamic> rumor)? _callSignalHandler;

  /// Registers the inbound call-signaling handler. Gift-wrapped kind-25053
  /// rumors addressed to us are decoded and handed to [fn] verbatim.
  void setCallSignalHandler(void Function(Map<String, dynamic> rumor)? fn) {
    _callSignalHandler = fn;
  }

  /// Gift-wraps and sends a kind-25053 call-signaling rumor to [to]. [payload]
  /// is the SDP/ICE body the calls layer wants delivered (carried as the rumor
  /// content, JSON-encoded). A self-copy is NOT sent (signaling is 1:1).
  ///
  /// [groupId] (optional) makes a GROUP call-signal ride the group conversation
  /// key (F06-A9): when set and the group's ephemeral keys are known, the gift
  /// wrap to [to] is encrypted to that peer's group ephemeral pubkey instead of
  /// their durable key — mirroring the PWA threading `_callSignalGroupId(callId)`
  /// into `_sendGiftWrapsAsync` (calls.js:149-162). A 1:1 call passes no groupId
  /// (the default) and wraps to the durable key as before. Falls back to the
  /// durable wrap if the group/keys are unavailable.
  Future<bool> sendCallSignal({
    required String to,
    required Map<String, dynamic> payload,
    String? groupId,
  }) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Mirror calls.js `_sendCallSignal` (line 146): the rumor content is
    // `{ ...payload, nym }` — the sender's display name is injected into EVERY
    // signal so the recipient's incoming-call UI can label the caller even
    // before a kind-0 profile arrives. Without it an invite shows a truncated
    // pubkey instead of the nym.
    final content = <String, dynamic>{...payload, 'nym': identity.nym};
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.callSignaling,
      tags: [
        ['p', to],
      ],
      content: jsonEncode(content),
    );
    // Group call-signal: encrypt the wrap to the peer's group ephemeral pubkey
    // (the same `encryptTo` the group message path uses) so it rides the group
    // key. No-op fallback to the durable key when the group or its keys are
    // unknown (e.g. we left the group mid-call).
    String Function(String)? encryptTo;
    if (groupId != null && groupId.isNotEmpty && _groups != null) {
      final group = _ref.read(appStateProvider.notifier).groupById(groupId);
      if (group != null) {
        final ek = _groups!.keysFor(group.id);
        encryptTo = (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey);
      }
    }
    return service.publishGiftWrappedRumor(
      rumor: rumor,
      recipients: [to],
      encryptTo: encryptTo,
    );
  }

  // ---------------------------------------------------------------------------
  // Outbound: composer SEND + entry points
  // ---------------------------------------------------------------------------

  /// Sends [text] to the current view: optimistic local echo, then relay
  /// publish (channel / PM / group).
  Future<void> sendCurrent(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // Slash-command interception (commands.js `content.startsWith('/')`): route
    // `/cmd args` to the command handler instead of publishing as a message.
    if (isCommandLine(trimmed)) {
      _dispatcher.handle(trimmed);
      return;
    }

    // Nymbot interception (messages.js:2381): a `?` command or `@Nymbot` mention
    // in a CHANNEL view routes to the bot (publishes the message + surfaces the
    // reply) instead of a plain send.
    if (shouldRouteToBot(trimmed)) {
      await routeToBot(trimmed);
      return;
    }

    await _sendMessageContent(trimmed);
  }

  // Anon-nym word lists for pseudonymous sends (nostr-core.js:2511-2525).
  static const List<String> _anonAdjectives = [
    'quantum', 'neon', 'cyber', 'shadow', 'plasma', //
    'echo', 'nexus', 'void', 'flux', 'ghost',
    'phantom', 'stealth', 'cryptic', 'dark', 'neural',
    'binary', 'matrix', 'digital', 'virtual', 'zero',
    'null', 'nym', 'masked', 'hidden', 'cipher',
    'enigma', 'spectral', 'rogue', 'omega', 'alpha',
  ];
  static const List<String> _anonNouns = [
    'ghost', 'nomad', 'drift', 'pulse', 'wave', //
    'spark', 'node', 'byte', 'mesh', 'link',
    'runner', 'hacker', 'coder', 'agent', 'proxy',
    'daemon', 'virus', 'worm', 'bot', 'droid',
    'reaper', 'shadow', 'wraith', 'specter', 'shade',
  ];
  final Random _anonRng = Random();

  /// Pseudonymous channel send (composer ANON 2s-hold → "ANON";
  /// `sendMessagePseudonymous` → `publishMessagePseudonymous`,
  /// nostr-core.js:2493). Publishes [text] to the active CHANNEL signed with a
  /// FRESH per-message ephemeral keypair under a random anon nym, so it is
  /// unlinkable to the durable identity. Mirrors [sendCurrent]'s `/`-command and
  /// `?`/@Nymbot interception; PM/group views fall through to the normal
  /// logged-in-key send (the PWA always uses the real key for PMs/groups).
  Future<void> sendCurrentPseudonymous(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (isCommandLine(trimmed)) {
      _dispatcher.handle(trimmed);
      return;
    }
    if (shouldRouteToBot(trimmed)) {
      await routeToBot(trimmed);
      return;
    }
    final view = _ref.read(appStateProvider).view;
    if (view.kind != ViewKind.channel) {
      await _sendMessageContent(trimmed);
      return;
    }
    await _sendChannelPseudonymous(trimmed);
  }

  /// Publishes one pseudonymous channel message: a fresh ephemeral keypair +
  /// random anon nym, an optimistic echo under that anon identity, and the
  /// in-place optimistic→real id reconciliation [_sendMessageContent] uses.
  /// Deliberately does NOT `recordOwnActivity` — presence is broadcast under the
  /// durable key, and emitting it would link the anon message to the user.
  Future<void> _sendChannelPseudonymous(String content) async {
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final view = state.view;
    _markDirty(view.storageKey);

    final ephemeralSigner = LocalSigner(keys.generatePrivateKey());
    final anonNym = _generateAnonNym();

    final echo = appState.sendLocal(
      content,
      pubkeyOverride: ephemeralSigner.pubkey,
      authorOverride: anonNym,
    );
    if (service == null) return;
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    try {
      final signed = await service.publishChannelMessage(
        channelKey: view.id,
        content: content,
        nym: anonNym,
        geohash: isGeo ? view.id : null,
        emojiTags: _ref
            .read(liveCustomEmojiProvider.notifier)
            .emojiTagsForContent(content),
        // Honor the user's Proof-of-Work Difficulty setting (settings.js
        // `powDifficulty`); the service clamps it up to the Nymchat floor.
        powDifficulty: _ref.read(settingsProvider.notifier).powDifficulty,
        signerOverride: ephemeralSigner,
      );
      if (signed != null && echo != null) {
        appState.replaceOptimistic(
          echo.id,
          signed.id,
          realCreatedAt: signed.createdAt,
          realMs: int.tryParse(signed.tagValue('ms') ?? ''),
        );
      }
    } catch (_) {
      if (echo != null) appState.markOptimisticFailed(echo.id);
    }
  }

  /// A random anon nym for a pseudonymous message (nostr-core.js:2506-2529):
  /// `nym<1000-9999>` for the 'simple' nick style, else `<adjective>_<noun>`.
  String _generateAnonNym() {
    final style = _ref.read(settingsProvider).nickStyle;
    if (style == 'simple') {
      return 'nym${1000 + _anonRng.nextInt(9000)}';
    }
    final adj = _anonAdjectives[_anonRng.nextInt(_anonAdjectives.length)];
    final noun = _anonNouns[_anonRng.nextInt(_anonNouns.length)];
    return '${adj}_$noun';
  }

  // --- PM auto-retry queue (pms.js trackPendingDM/retryPendingDMs) -----------
  //
  // A PM sent while the recipient is briefly offline gets no delivery receipt;
  // the PWA re-publishes it on a 5s cadence up to 3 times, then stops (a missing
  // receipt means "recipient offline", not a send failure — the bubble stays
  // '✓ sent', NOT '!'). Also re-fired on relay reconnect. F02 auto-retry.

  /// Re-send cadence + cap (app.js:589-590: `dmRetryCheckMs = 5000`,
  /// `dmRetryMaxAttempts = 3`).
  static const int _kDmRetryCheckMs = 5000;
  static const int _kDmRetryMaxAttempts = 3;

  /// Outstanding sent-but-unacked PMs keyed by `nymMessageId`.
  final Map<String, _PendingDm> _pendingDms = <String, _PendingDm>{};
  Timer? _dmRetryTimer;

  /// Peers we've received a bitchat-format PM from (PWA `bitchatUsers`) — we
  /// send them a parallel `bitchat1:` wrap so the bitchat app can decrypt us.
  final Set<String> _bitchatUsers = <String>{};

  /// Peers we've received a Nymchat-format PM/receipt from (PWA `nymUsers`) —
  /// they get a NIP-17 wrap. An UNKNOWN peer (in neither set) gets BOTH.
  final Set<String> _nymUsers = <String>{};

  /// Publishes a 1:1 PM in the transport(s) the peer understands (PWA
  /// `sendNIP17PM` dual-send, pms.js:326-372). A known-bitchat peer gets a
  /// `bitchat1:` wrap, a known-nym peer a NIP-17 wrap, and an unknown peer BOTH.
  /// The self-copy is always NIP-17 (handled inside [NostrService.publishPM]).
  /// Used by the initial send and every auto-retry so the format decision stays
  /// consistent as [_bitchatUsers] / [_nymUsers] learn the peer over time.
  Future<void> _publishDualPm({
    required UnsignedEvent rumor,
    required String recipientPubkey,
    void Function(NostrEvent wrap)? onWrap,
  }) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;

    final isKnownBitchat = _bitchatUsers.contains(recipientPubkey);
    final isKnownNym = _nymUsers.contains(recipientPubkey);
    final isUnknown = !isKnownBitchat && !isKnownNym;

    UnsignedEvent? bitchatRumor;
    if (isKnownBitchat || isUnknown) {
      // The bitchat rumor's content is a `bitchat1:` packet; it carries the SAME
      // `nymMessageId` (`x` tag) as the nym rumor so a peer's reaction/receipt
      // matches across both formats (pms.js:339-346).
      String? nymMessageId;
      for (final t in rumor.tags) {
        if (t.length > 1 && t[0] == 'x') {
          nymMessageId = t[1];
          break;
        }
      }
      final encoded = bitchat.encodeBitchatMessage(
        rumor.content,
        identity.pubkey,
        recipientPubkey: recipientPubkey,
      );
      bitchatRumor = UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: rumor.createdAt,
        kind: EventKind.dmRumor,
        tags: [
          if (nymMessageId != null) ['x', nymMessageId],
        ],
        content: encoded.content,
      );
    }

    await service.publishPM(
      rumor: rumor,
      recipientPubkey: recipientPubkey,
      settings: _msgSettings,
      onWrap: onWrap,
      bitchatRumor: bitchatRumor,
      sendNymWrap: isKnownNym || isUnknown,
    );
  }

  /// Enqueues a freshly-sent PM for receipt-driven auto-retry and starts the
  /// retry checker if idle (pms.js:116-130 `trackPendingDM`).
  void _trackPendingDm({
    required String nymMessageId,
    required UnsignedEvent rumor,
    required String recipientPubkey,
  }) {
    _pendingDms[nymMessageId] = _PendingDm(
      rumor: rumor,
      recipientPubkey: recipientPubkey,
      lastAttemptMs: DateTime.now().millisecondsSinceEpoch,
    );
    _dmRetryTimer ??= Timer.periodic(
      const Duration(milliseconds: _kDmRetryCheckMs),
      (_) => _retryPendingDms(),
    );
  }

  /// True once the PM with [nymMessageId] has a delivery status past `sent`
  /// (delivered/read) — used to drop it from the retry queue.
  bool _isDmAcked(String nymMessageId) {
    final lists = _ref.read(appStateProvider).messages.values;
    for (final list in lists) {
      for (final m in list) {
        if (m.isOwn && m.nymMessageId == nymMessageId) {
          return m.deliveryStatus != DeliveryStatus.sent &&
              m.deliveryStatus != DeliveryStatus.sending &&
              m.deliveryStatus != DeliveryStatus.failed;
        }
      }
    }
    return false;
  }

  /// Periodic tick (pms.js:133-176 `retryPendingDMs`): drop acked/maxed entries,
  /// re-publish the rest whose cooldown elapsed. Stops the timer when the queue
  /// empties.
  void _retryPendingDms() {
    if (_pendingDms.isEmpty) {
      _dmRetryTimer?.cancel();
      _dmRetryTimer = null;
      return;
    }
    final service = _service;
    final now = DateTime.now().millisecondsSinceEpoch;
    final done = <String>[];
    _pendingDms.forEach((id, pending) {
      // Delivered/read → stop retrying.
      if (_isDmAcked(id)) {
        done.add(id);
        return;
      }
      if (now - pending.lastAttemptMs < _kDmRetryCheckMs) return;
      // Cap reached: leave the bubble '✓ sent' (recipient offline, not a failure).
      if (pending.attempts >= _kDmRetryMaxAttempts) {
        done.add(id);
        return;
      }
      pending.attempts++;
      pending.lastAttemptMs = now;
      if (service != null) {
        unawaited(_publishDualPm(
          rumor: pending.rumor,
          recipientPubkey: pending.recipientPubkey,
        ));
      }
    });
    for (final id in done) {
      _pendingDms.remove(id);
    }
    if (_pendingDms.isEmpty) {
      _dmRetryTimer?.cancel();
      _dmRetryTimer = null;
    }
  }

  /// Re-send every still-unacked pending PM on a relay reconnect, bypassing the
  /// per-tick cooldown/cap (pms.js:225-293 `retryPendingDMsOnReconnect`) — a
  /// reconnect is the most likely moment a stuck DM can finally land.
  void _retryPendingDmsOnReconnect() {
    if (_pendingDms.isEmpty) return;
    final service = _service;
    if (service == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final done = <String>[];
    _pendingDms.forEach((id, pending) {
      if (_isDmAcked(id)) {
        done.add(id);
        return;
      }
      pending.lastAttemptMs = now;
      unawaited(_publishDualPm(
        rumor: pending.rumor,
        recipientPubkey: pending.recipientPubkey,
      ));
    });
    for (final id in done) {
      _pendingDms.remove(id);
    }
  }

  /// Publishes [content] to the active conversation surface
  /// (`_sendToCurrentTarget`), WITHOUT command interception. Used both by the
  /// composer (after the `/` check) and by formatting/action commands whose
  /// output (e.g. `/me …`) must be sent verbatim even though it starts with a
  /// slash.
  Future<void> _sendMessageContent(String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    // Every outgoing send marks us active + throttle-broadcasts presence
    // (nostr-core.js calls recordOwnActivity on each channel/PM/group send).
    recordOwnActivity();
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final identity = _identity;
    final view = state.view;
    _markDirty(view.storageKey);

    if (view.kind == ViewKind.channel) {
      // Optimistic local echo with a temp `_optim_*` id (messages.js sendMessage).
      final echo = appState.sendLocal(trimmed);
      if (service == null || identity == null) return;
      final isGeo = state.channels
          .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
      try {
        final signed = await service.publishChannelMessage(
          channelKey: view.id,
          content: trimmed,
          nym: identity.nym,
          geohash: isGeo ? view.id : null,
          emojiTags: _ref
              .read(liveCustomEmojiProvider.notifier)
              .emojiTagsForContent(trimmed),
          // Honor the user's Proof-of-Work Difficulty setting (clamped up to
          // the Nymchat floor by the service).
          powDifficulty: _ref.read(settingsProvider.notifier).powDifficulty,
        );
        // Swap the temp id for the real signed-event id IN PLACE and register
        // it so the relay echo is deduped — never shown twice (the PWA's
        // `_replaceOptimisticMessage`). Without a signer `signed` is null and the
        // echo simply stays (no relay round-trip will echo it back).
        if (signed != null && echo != null) {
          appState.replaceOptimistic(
            echo.id,
            signed.id,
            realCreatedAt: signed.createdAt,
            realMs: int.tryParse(signed.tagValue('ms') ?? ''),
          );
        }
        // Hardcore keypair mode: rotate to a brand-new keypair + nym after every
        // sent channel message (messages.js:2392-2404). Runs AFTER the publish
        // above so the message that just went out used the OLD identity; the
        // next send uses the fresh one. No-op unless ephemeral + 'hardcore'.
        await _rotateHardcoreIdentityIfNeeded();
      } catch (_) {
        // Publish failed: flip the placeholder to failed (`_markOptimisticFailed`).
        if (echo != null) appState.markOptimisticFailed(echo.id);
      }
      return;
    }

    if (view.kind == ViewKind.pm) {
      // Bot `?` control commands are handled entirely on-device and intercepted
      // BEFORE any echo/encrypt/publish (pms.js:1581-1591): they are never
      // encrypted, published, shown as bubbles, or stored — `?git` can carry a
      // GitHub access token that must never reach the relays.
      if (isVerifiedBot(view.id)) {
        if (botPMCommandRe.hasMatch(trimmed)) {
          unawaited(_ref
              .read(botChatControllerProvider.notifier)
              .handleBotPMCommand(trimmed));
          return;
        }
        // A normal message to the bot routes through the engine's send path so
        // exactly ONE bot-addressed wrap is published and its id rides the paid
        // request (`sendPM` → `sendNIP17PM` → `_handleBotPM(content, wrapped)`,
        // pms.js:1595-1598). The engine echoes the message into the canonical
        // store itself — publishing here via `publishPM` (which never surfaces
        // its wrap ids) would make the observer build and publish a SECOND
        // bot-addressed wrap just to have an eventId for the worker.
        unawaited(_ref
            .read(botChatControllerProvider.notifier)
            .sendUserBotPM(trimmed));
        return;
      }
      final nymMessageId = PmLogic.generateSharedEventId();
      final echo = appState.sendLocal(trimmed, nymMessageId: nymMessageId);
      if (service == null || identity == null) return;
      final base = PmLogic.buildPmRumor(
        selfPubkey: identity.pubkey,
        recipientPubkey: view.id,
        content: trimmed,
        nymMessageId: nymMessageId,
      );
      // buildPmRumor has no extra-tag seam, so append the NIP-30 declarations
      // for any known custom `:shortcode:` in the body to the rumor we just
      // built (pms.js:313 spreads `...customEmojiTagsForContent(content)`).
      final emojiTags = _ref
          .read(liveCustomEmojiProvider.notifier)
          .emojiTagsForContent(trimmed);
      final rumor = emojiTags.isEmpty
          ? base
          : UnsignedEvent(
              pubkey: base.pubkey,
              createdAt: base.createdAt,
              kind: base.kind,
              tags: [...base.tags, ...emojiTags],
              content: base.content,
            );
      try {
        await _publishDualPm(
          rumor: rumor,
          recipientPubkey: view.id,
          onWrap: _archiveSentWrap,
        );
        // Queue for automatic re-send until a delivery receipt acks it
        // (pms.js `trackPendingDM`). Cleared in [_onReceiptOrTyping] the moment
        // a receipt for this `nymMessageId` lands, or dropped after the cap.
        // The verified bot never sends receipts (the engine advances delivery
        // locally), so its PMs are never queued for auto-resend.
        if (!isVerifiedBot(view.id)) {
          _trackPendingDm(
            nymMessageId: nymMessageId,
            rumor: rumor,
            recipientPubkey: view.id,
          );
        }
      } catch (_) {
        // Publish failed → flip the bubble to the failed "!" state (F02; the
        // channel branch already does this — PMs were silently left "✓ sent").
        if (echo != null) appState.markOptimisticFailed(echo.id);
      }
      return;
    }

    if (view.kind == ViewKind.group) {
      final group = appState.groupById(view.id);
      // Local echo carries its own nymMessageId for receipt matching.
      if (service == null || identity == null || group == null) {
        appState.sendLocal(trimmed);
        return;
      }
      // Build + send first so we know the shared id, then echo with it.
      final ek = _groups!.keysFor(group.id);
      final next = ek.rotateSelf();
      _service!.setEphemeralKeys(_groups!.allEphemeralSecretKeys());
      // A self-key rotation on send: persist the new key locally, re-REQ the
      // live ephemeral gift-wrap subscription so replies wrapped to the NEW
      // key arrive, and sync so our other devices can decrypt this message's
      // wrap (the PWA saves + refreshes subs + debounce-syncs after every
      // group send, groups.js:1754-1758 / :1298).
      _afterSelfKeyRotation();
      final nymMessageId = GroupLogic.generateGroupId();
      appState.sendLocal(trimmed, nymMessageId: nymMessageId);
      final rumor = GroupLogic.buildGroupMessageRumor(
        group: group,
        selfPubkey: identity.pubkey,
        content: trimmed,
        nymMessageId: nymMessageId,
        ephemeralPk: next.pk,
        // NIP-30 declarations for any known custom `:shortcode:` in the body
        // (groups.js:1699 `tags.push(...customEmojiTagsForContent(content))`),
        // plus the owner's group-metadata piggyback (`_attachGroupMetaTags`) so
        // members converge on the custom avatar/banner even from a D1 backfill.
        extraTags: [
          ..._ref
              .read(liveCustomEmojiProvider.notifier)
              .emojiTagsForContent(trimmed),
          ...GroupLogic.groupMetaPiggybackTags(group, identity.pubkey),
        ],
      );
      await service.publishGroupMessage(
        rumor: rumor,
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
        settings: _msgSettings,
        onWrap: _archiveSentWrap,
      );
    }
  }

  /// Keypair-mode save side effects (app.js:3873-3890, the `saveSettings`
  /// random-keypair block, gated on `!isNostrLoggedIn()`):
  ///   * random/hardcore → remove the saved `nym_session_nsec` so the next
  ///     reload generates a fresh keypair;
  ///   * persistent → save the CURRENT keypair's nsec when none is stored, so
  ///     the identity the user is using right now survives reload (instead of
  ///     a stale pre-random keypair resurrecting from the keystore).
  Future<void> _onKeypairModeChanged(String mode) async {
    final identity = _identity;
    // Durable logins never touch the ephemeral session key (the PWA skips the
    // whole block for logged-in users).
    if (identity == null || identity.loginMethod != null) return;
    final secure = SecureStore();
    try {
      if (mode == 'random' || mode == 'hardcore') {
        await secure.remove(SecretKeys.sessionNsec);
      } else {
        final existing = await secure.get(SecretKeys.sessionNsec);
        if ((existing == null || existing.isEmpty) &&
            identity.privkey != null) {
          await secure.set(
            SecretKeys.sessionNsec,
            bech32.encodeNsecBytes(identity.privkey!),
          );
        }
      }
    } catch (_) {
      // Best-effort (matches the PWA's silent try/catch around nsecEncode).
    }
  }

  /// Hardcore keypair mode: replace the live ephemeral identity with a brand-new
  /// keypair + random nym after a sent message (messages.js:2392-2404 — the
  /// `connectionMode === 'ephemeral' && nym_keypair_mode === 'hardcore'` branch
  /// that runs `generateKeypair()` + `generateRandomNym()` + `updateSidebarAvatar()`).
  ///
  /// No-op unless we are EPHEMERAL (`loginMethod == null`, the PWA's
  /// `connectionMode === 'ephemeral'`) AND the keypair mode is `'hardcore'`, so a
  /// durable nsec/extension/NIP-46 account is never rotated out from under the
  /// user.
  ///
  /// Rotation swaps the signing key IN PLACE on the live [NostrService]
  /// ([NostrService.rotateIdentity]) — the relay connections + subscriptions
  /// persist, matching the PWA's `generateKeypair` (which only swaps the key,
  /// never reconnecting or re-subscribing). It then refreshes `selfPubkey`/
  /// `selfNym` in [AppState] (the sidebar header avatar seed + nym react — the
  /// native `updateSidebarAvatar`) and re-asserts presence under the new
  /// identity via [recordOwnActivity].
  Future<void> _rotateHardcoreIdentityIfNeeded() async {
    final current = _identity;
    final oldService = _service;
    // Ephemeral only (no durable login) + the 'hardcore' keypair mode.
    if (current == null ||
        oldService == null ||
        current.loginMethod != null) {
      return;
    }
    if (_ref.read(settingsProvider.notifier).keypairMode != 'hardcore') return;

    final kv = _ref.read(keyValueStoreProvider);
    // Vault-aware secret writes (see the [init] construction site).
    final identityService = IdentityService(
      kv: kv,
      secure: SecureStore(),
      secretWrite: _ref.read(identityVaultProvider).secretSet,
    );
    final rotated = await identityService.rotateEphemeral(current);
    // rotateEphemeral returns the same instance for a durable login; the guard
    // above already excludes that, but stay safe against a no-op rotation.
    if (identical(rotated, current) || rotated.pubkey == current.pubkey) return;

    final signer =
        rotated.privkey != null ? LocalSigner(rotated.privkey!) : null;

    // Swap the key IN PLACE on the live service — keep the relay connections +
    // subscriptions (the PWA's `generateKeypair` only swaps privkey/pubkey; it
    // does NOT reconnect or re-subscribe, so the `#p:[self]` gift-wrap filter
    // stays on the prior pubkey). A full service rebuild would reconnect every
    // relay on every sent message, which hardcore mode can't afford. The same
    // [NostrService]/[GroupManager] instances are retained — only the signing
    // identity changes for the NEXT publish.
    oldService.rotateIdentity(rotated, signer);
    _identity = rotated;
    _signer = signer;
    // Re-scope the per-pubkey settings reads (image blur) to the new identity.
    _ref.read(settingsProvider.notifier).activePubkey = rotated.pubkey;

    // Refresh the sidebar (header avatar seed + nym) without wiping the
    // conversation — the native `updateSidebarAvatar`. (NOT goLive, which would
    // reset the live store.)
    _ref.read(appStateProvider.notifier).setIdentity(rotated.pubkey, rotated.nym);

    // Re-assert presence under the new identity, like the boot path does for a
    // freshly-booted identity (nostr-core.js presence-on-connect).
    recordOwnActivity();
  }

  // --- Command effects (engine half of the cmd* handlers) -------------------

  /// `/join` — sanitize, block-check, add + switch (cmdJoin). The name is
  /// lowercased and `#`-stripped; geohash channels register their geohash.
  void cmdJoin(String rawChannel) {
    var channel = rawChannel.trim().toLowerCase();
    if (channel.startsWith('#')) channel = channel.substring(1);
    // Sanitize: only letters (incl. international) and digits (sanitizeChannelName).
    channel = channel.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    if (channel.isEmpty) {
      _emitSystemMessage(
          'Invalid channel name. Only letters and numbers are allowed.');
      return;
    }
    final blocked = _ref.read(appStateProvider).blockedChannels;
    if (blocked.contains(channel)) {
      _emitSystemMessage(
          'Channel #$channel is blocked. Use /unblock #$channel to unblock it first.');
      return;
    }
    final geohash = isChannelGeohash(channel) ? channel : '';
    addChannel(channel, geohash: geohash);
    switchChannel(channel, geohash: geohash);
  }

  /// `/leave` — channel→removeChannel (cmdLeave). PM/group leave is wired by the
  /// pms/groups UI via [setCommandHooks] (not owned here).
  void cmdLeave() {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return; // PM/group handled by hook
    final key = state.view.id.toLowerCase();
    if (key == 'nymchat') {
      _emitSystemMessage('Cannot leave the default #nymchat channel');
      return;
    }
    removeChannel(key);
    // PWA `removeChannel` posts a "Left channel #X" confirmation
    // (channels.js:1623). `key` is already the bare geohash/name, matching the
    // PWA's `'#' + (geohash || channel)` since it never carries a leading '#'.
    _emitSystemMessage('Left channel #$key');
  }

  /// `/who` — lists current-channel users active within 300s (cmdWho).
  void cmdWho() {
    final state = _ref.read(appStateProvider);
    final key = state.view.id.toLowerCase();
    final now = DateTime.now().millisecondsSinceEpoch;
    final names = state.users.values
        .where((u) => u.channels.contains(key))
        .where((u) => now - u.lastSeen < kActiveThresholdMs)
        .map((u) =>
            '${stripPubkeySuffix(u.nym)}#${getPubkeySuffix(u.pubkey)}')
        .toList()
      ..sort();
    _emitSystemMessage(
        'Online nyms in this channel: ${names.isEmpty ? 'none' : names.join(', ')}');
  }

  /// `/nick` — change nickname (cmdNick, commands.js:600-660): trim + cap 20,
  /// no-op on the unchanged nym, gate a RESERVED nickname behind the
  /// developer-nsec challenge (`showDevNsecModal('nick')` →
  /// `applyDeveloperIdentity`, commands.js:614-626) via the composer-wired
  /// [CommandHooks.openDevNsecChallenge] — the hook owns verify/cancel and
  /// their system lines; headless (no hook) aborts with the PWA's
  /// cancellation line — then publish the kind-0. [saveProfile] also persists
  /// `nym_custom_nick` + the auto-ephemeral nick so the rename survives a
  /// relaunch (commands.js:633-639).
  Future<void> cmdNick(String newNym) async {
    final trimmed = newNym.trim();
    if (trimmed.isEmpty) {
      _emitSystemMessage('Usage: /nick newnym');
      return;
    }
    final next = trimmed.length > 20 ? trimmed.substring(0, 20) : trimmed;
    if (stripPubkeySuffix(_identity?.nym ?? '') == next) {
      _emitSystemMessage('That is already your current nym');
      return;
    }
    if (isReservedNick(next)) {
      final challenge = _dispatcher.hooks.openDevNsecChallenge;
      if (challenge != null) {
        challenge();
        return;
      }
      _emitSystemMessage('Nickname change cancelled.');
      return;
    }
    await saveProfile(name: next);
    _emitSystemMessage("Your nym's new nick is now ${_identity?.nym ?? next}");
  }

  /// `/brb` — set away message + broadcast away presence (cmdBRB).
  Future<void> cmdSetAway(String message) async {
    await publishPresence('away', awayMessage: message);
    _emitSystemMessage('Away message set: "$message"');
    _emitSystemMessage(
        'You will auto-reply to mentions in ALL channels while away');
  }

  /// `/back` — clear away + broadcast online (cmdBack).
  Future<void> cmdBack() async {
    await publishPresence('online');
    _emitSystemMessage('Away message cleared - you are back!');
  }

  /// `/clear` — clear the conversation view (cmdClear). The message store is
  /// owned by app_state; we surface the PWA's confirmation. TODO(verify): a
  /// real clear needs an app_state clear API (not owned by this agent).
  void cmdClear() => _emitSystemMessage('Chat cleared');

  /// `/share` — share the current channel URL (cmdShare/shareChannel).
  void cmdShare() {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return;
    _emitSystemMessage('https://app.nym.bar/#${state.view.id}');
  }

  /// `/quit` — disconnect (cmdQuit). Stops the service; full reload is the
  /// shell's job. Clears the saved dev nsec + the pubkey-scoped lightning
  /// address (commands.js:1395-1404 — the other cmdQuit keys,
  /// `nym_connection_mode`/`nym_relay_url`/`nym_nsec`, are never written by
  /// the port).
  void cmdQuit() {
    _emitSystemMessage('Disconnecting from Nymchat...');
    final pubkey = _identity?.pubkey;
    if (pubkey != null && pubkey.isNotEmpty) {
      unawaited(_ref
          .read(keyValueStoreProvider)
          .remove(StorageKeys.lightningAddressFor(pubkey)));
    }
    unawaited(SecureStore().remove(SecretKeys.devNsec));
    unawaited(_service?.stop());
  }

  /// `/block` — block #channel (cmdBlock channel path) or report a user block.
  void cmdBlock(String arg) {
    final state = _ref.read(appStateProvider);
    final target = arg.trim();
    if (target.isEmpty) {
      if (state.view.kind != ViewKind.channel) {
        _emitSystemMessage(
            'Usage: /block nym, /block nym#xxxx, /block [pubkey], or /block #channel');
        return;
      }
      final key = state.view.id.toLowerCase();
      if (key == 'nymchat') {
        _emitSystemMessage('Cannot block the default #nymchat channel');
        return;
      }
      if (blockChannel(key)) {
        _emitSystemMessage(isChannelGeohash(key)
            ? 'Blocked geohash channel #$key'
            : 'Blocked channel #$key');
        switchChannel('nymchat');
      }
      return;
    }
    if (target.startsWith('#')) {
      final name = target.substring(1).toLowerCase();
      if (name == 'nymchat') {
        _emitSystemMessage('Cannot block the default #nymchat channel');
        return;
      }
      if (blockChannel(name)) {
        _emitSystemMessage(isChannelGeohash(name)
            ? 'Blocked geohash channel #$name'
            : 'Blocked channel #$name');
      }
      return;
    }
    // User block — app_state owns blockedUsers; surface the PWA confirmation.
    final t = resolveTarget(target, state.users);
    if (t == null) {
      _emitSystemMessage('User $target not found');
      return;
    }
    blockUser(t.pubkey);
  }

  /// `/unblock` — unblock #channel (cmdUnblock channel path) or a user.
  void cmdUnblock(String arg) {
    final state = _ref.read(appStateProvider);
    final target = arg.trim();
    if (target.startsWith('#')) {
      final name = target.substring(1).toLowerCase();
      if (state.blockedChannels.contains(name)) {
        unblockChannelEffect(name);
        _emitSystemMessage(isChannelGeohash(name)
            ? 'Unblocked geohash channel #$name'
            : 'Unblocked channel #$name');
      } else {
        _emitSystemMessage('Channel #$name is not blocked');
      }
      return;
    }
    final t = resolveTarget(target, state.users);
    if (t == null || !state.blockedUsers.contains(t.pubkey)) {
      _emitSystemMessage('User $target not found or is not blocked');
      return;
    }
    unblockUser(t.pubkey);
  }

  /// Unblocks [key] and persists (mirrors blockChannel's inverse).
  void unblockChannelEffect(String key) {
    _ref.read(appStateProvider.notifier).unblockChannel(key);
    _persistSet(StorageKeys.blockedChannels,
        _ref.read(appStateProvider).blockedChannels);
  }

  /// Whether [key] is a geohash channel (isValidGeohash, non-default).
  bool isChannelGeohash(String key) =>
      isValidGeohash(key) && key != 'nymchat';

  /// Opens (or creates) a PM thread with [peerPubkey] and switches to it.
  ///
  /// [peerPubkey] is canonicalized to lowercase 64-hex first (an `npub1…` is
  /// decoded) so every entry point — profile "Message", author tap, new-PM
  /// modal, notification tap, deep link — lands on the SAME `pm-<pubkey>`
  /// thread and the exact-match routing checks downstream (the Nymbot
  /// `view.id == kNymbotPubkey` screen swap, unread keys, receipts) can never
  /// miss on a differently-encoded id.
  void startPM(String peerPubkey, {String? nym}) {
    var peer = peerPubkey.trim();
    if (RegExp(r'^npub1', caseSensitive: false).hasMatch(peer)) {
      try {
        peer = bech32.decodeNpub(peer.toLowerCase());
      } catch (_) {
        return; // malformed npub — nothing to open
      }
    }
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(peer)) {
      peer = peer.toLowerCase();
    }
    if (peer.isEmpty) return;
    final appState = _ref.read(appStateProvider.notifier);
    appState.ensurePMConversation(peer, nym: nym);
    appState.switchView(ChatView.pm(peer));
    // Resolve the peer's kind-0 so a brand-new PM (no prior events from them, e.g.
    // started from the new-PM picker or a profile tap) still shows their real
    // avatar/nym instead of an identicon (PWA `openUserPM` → `fetchProfileDirect`,
    // pms.js:3115). Self-/picture-guarded inside `_maybeBackfillProfiles`.
    ensureProfiles([peer]);
  }

  /// Creates a group with [memberPubkeys], registers it locally, and switches.
  ///
  /// The optional [avatar] / [banner] / [description] / [allowMemberInvites]
  /// are the group-creation extras the New-Group modal collects; they thread
  /// through to [GroupManager.createGroup] and onto the bootstrap invite's
  /// metadata tags (groups.js `createGroup(name, members, opts)`). The positional
  /// `(name, memberPubkeys)` shape is preserved so existing callers/tests keep
  /// compiling; [allowMemberInvites] defaults to true (PWA
  /// `opts.allowMemberInvites !== false`).
  Future<Group?> createGroup(
    String name,
    List<String> memberPubkeys, {
    String? avatar,
    String? banner,
    String? description,
    bool allowMemberInvites = true,
  }) async {
    final service = _service;
    final identity = _identity;
    final groups = _groups;
    if (service == null || identity == null || groups == null) return null;
    final group = await groups.createGroup(
      selfPubkey: identity.pubkey,
      name: name,
      memberPubkeys: memberPubkeys,
      avatar: avatar,
      banner: banner,
      description: description,
      allowMemberInvites: allowMemberInvites,
      settings: _msgSettings,
    );
    if (group == null) return null;
    final appState = _ref.read(appStateProvider.notifier);
    appState.upsertGroup(group);
    appState.switchView(ChatView.group(group.id));
    return group;
  }

  /// Joiner side of the group invite-link flow (groups.js
  /// `requestJoinGroupViaInvite`, 449-492): gift-wrap a single
  /// `group-join-request` (kind-14) to the link's sharer (`approver`), who
  /// auto-admits us when invite links are enabled and our `invite_epoch`
  /// matches. Short-circuits when we already have the group (just opens it) or
  /// the link is our own, and degrades to a system message when no signer is
  /// available yet (the PWA prompts setup and resumes after onboarding).
  Future<void> joinGroupViaInvite(GroupInviteToken token) async {
    final appState = _ref.read(appStateProvider.notifier);
    // Already a member → just open it (groups.js:453).
    if (appState.groupById(token.groupId) != null) {
      appState.switchView(ChatView.group(token.groupId));
      return;
    }
    final identity = _identity;
    final service = _service;
    // Your own invite link (groups.js:458).
    if (identity != null && token.approver == identity.pubkey) {
      _emitSystemMessage('That is your own invite link.');
      return;
    }
    final sanitized = _sanitizeGroupName(token.name);
    final name = sanitized.isEmpty ? 'this group' : sanitized;
    // No identity / signer yet (groups.js:466 `_canSendGiftWraps`).
    if (identity == null || service == null || !service.canSign) {
      _emitSystemMessage(
          'Pick a nym or log in to join "$name", then you\'ll be added.');
      return;
    }
    // Build + gift-wrap the join request to the sharer (groups.js:480-491).
    recordOwnActivity();
    final subject = token.name.isEmpty
        ? 'Group'
        : (token.name.length > 80 ? token.name.substring(0, 80) : token.name);
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: EventKind.dmRumor, // 14
      tags: [
        ['p', token.approver],
        ['g', token.groupId],
        ['subject', subject],
        ['type', GroupControlType.joinRequest],
        ['invite_epoch', '${token.epoch}'],
        ['x', PmLogic.generateSharedEventId()],
      ],
      content: 'requested to join via invite link',
    );
    try {
      await service.publishGiftWrappedRumor(
        rumor: rumor,
        recipients: [token.approver],
      );
      _emitSystemMessage(
          'Join request sent for "$name". You\'ll be added once a member is '
          'online.');
    } catch (_) {
      _emitSystemMessage('Failed to send join request. Please try again.');
    }
  }

  /// Sends [body] as a gift-wrapped kind-14 PM to the verified developer
  /// ([verifiedDeveloperPubkey]) — the About → "Send Message" / contact form
  /// (app.js:4438 `nym.sendPM(body, nym.verifiedDeveloper.pubkey)`). Returns true
  /// when the wrap was published.
  ///
  /// Mirrors `sendPM` → `sendNIP17PM`: a kind-14 rumor wrapped to the recipient
  /// plus a self-copy (so the message also lands in our own PM thread with the
  /// developer). The recipient is a normal pubkey (not the Nymbot), so the
  /// bot-command short-circuit in `sendPM` doesn't apply. Empty bodies and the
  /// no-signer / not-connected states return false, matching the PWA's guards
  /// (`if (!content.trim()) return false` / `if (!connected) throw`).
  Future<bool> sendContactMessage(String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return false;
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null || !service.canSign) return false;

    // Mark us active (recordOwnActivity) like every other PM send.
    recordOwnActivity();

    final nymMessageId = PmLogic.generateSharedEventId();
    final rumor = PmLogic.buildPmRumor(
      selfPubkey: identity.pubkey,
      recipientPubkey: verifiedDeveloperPubkey,
      content: trimmed,
      nymMessageId: nymMessageId,
    );
    try {
      return await service.publishPM(
        rumor: rumor,
        recipientPubkey: verifiedDeveloperPubkey,
        settings: _msgSettings,
      );
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Outbound settings transfer (F9; shop.js:1767 `executeSettingsTransfer`).
  // ---------------------------------------------------------------------------

  /// Transfers this user's nickname, avatar, and transferable preferences to
  /// [recipientPubkey] by publishing a gift-wrapped kind-30078 event, mirroring
  /// the PWA's `executeSettingsTransfer` (shop.js:1804). The recipient surfaces
  /// it as a pending settings-transfer offer (`handleSettingsTransferEvent`).
  ///
  /// The event uses the replaceable `d` tag
  /// `nym-settings-transfer-<selfPubkey>-<recipientPubkey>` plus
  /// `['settings-transfer-to', recipientPubkey]`; the content is the JSON payload
  /// `{fromPubkey, fromNym, toPubkey, transferredAt, nickname, avatarUrl,
  /// settings}` where `settings` is the flat synced payload (PWA
  /// `_buildSettingsPayload`) minus the device-local keys the PWA strips
  /// (`closedPMs`, `leftGroups`, `notificationLastReadTime`, `userJoinedChannels`,
  /// `pinnedChannels`, `keypairMode`).
  ///
  /// It is gift-wrapped (NIP-59, encrypted-to-recipient) like the other 30078
  /// transfer path, reusing [NostrService.publishGiftWrappedRumor]. Caller is
  /// expected to have validated the recipient (64-hex, non-self); this also
  /// guards on a signer being available. Returns true when a wrap was published.
  Future<bool> sendSettingsTransfer(String recipientPubkey) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null || !service.canSign) return false;

    // Mark us active like every other outbound gift-wrap path.
    recordOwnActivity();

    // Flat synced payload (PWA `_buildSettingsPayload`): flatten the section
    // payloads and drop the per-section `v` markers so the shape matches the
    // PWA's flat settings object.
    final settings = _ref.read(settingsProvider);
    final transferSettings = <String, dynamic>{};
    StorageSync.buildSectionPayloads(settings).forEach((_, fields) {
      fields.forEach((k, v) {
        if (k == 'v') return;
        transferSettings[k] = v;
      });
    });
    // Strip the device-local keys the PWA deletes before sending (most aren't in
    // the native subset; this stays byte-faithful if any are added later).
    for (final k in const [
      'closedPMs',
      'leftGroups',
      'notificationLastReadTime',
      'userJoinedChannels',
      'pinnedChannels',
      'keypairMode',
    ]) {
      transferSettings.remove(k);
    }

    final avatar =
        _ref.read(appStateProvider).users[identity.pubkey]?.profile?.picture ??
            '';
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = <String, dynamic>{
      'fromPubkey': identity.pubkey,
      'fromNym': identity.nym,
      'toPubkey': recipientPubkey,
      'transferredAt': nowSec,
      'nickname': identity.nym,
      'avatarUrl': avatar,
      'settings': transferSettings,
    };

    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.appData, // 30078
      tags: [
        ['d', 'nym-settings-transfer-${identity.pubkey}-$recipientPubkey'],
        ['title', 'Nymchat Settings Transfer'],
        ['p', recipientPubkey],
        ['settings-transfer-to', recipientPubkey],
      ],
      content: jsonEncode(payload),
    );
    try {
      return await service.publishGiftWrappedRumor(
        rumor: rumor,
        recipients: [recipientPubkey],
      );
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Cache size / clear (settings.js data controls: "Cache: N MB" + "Clear
  // cache"). The on-disk [CacheStore] owns the real byte accounting + wipe; this
  // exposes them to the settings UI. Both no-op safely before [init].
  // ---------------------------------------------------------------------------

  /// Real on-disk size of the message/profile/reaction cache, in bytes
  /// (settings.js `estimateCacheSize`). 0 when the cache hasn't been opened yet.
  Future<int> cacheSizeBytes() async {
    final cache = _cache;
    if (cache == null || !cache.isOpen) return 0;
    return cache.totalBytes();
  }

  /// Clears all cached channels / PMs / profiles / reactions (settings.js
  /// "Clear cache"). Flushes any pending dirty writes first so an in-flight
  /// debounce can't immediately re-persist what we just wiped, drops the dirty
  /// sets, wipes the store, then mirrors the wipe in the OPEN SESSION too —
  /// the PWA clears `nym.messages` / `nym.pmMessages` / `nym.reactions` /
  /// `nym.userBios` and empties the rendered `#messages` after `resetCache`
  /// (app.js:4013-4030) so the UI immediately reflects the cleared state.
  Future<void> clearCache() async {
    final cache = _cache;
    if (cache == null || !cache.isOpen) return;
    // Cancel the pending flush + forget dirty keys so we don't re-write the
    // conversations we're about to drop.
    _flushTimer?.cancel();
    _flushScheduled = false;
    _dirtyChannelKeys.clear();
    _dirtyPmKeys.clear();
    await cache.wipe();
    // In-memory mirror (app.js:4013-4030): `messages` holds channel + PM +
    // group histories (the PWA's `messages` + `pmMessages`), `reactions` is
    // the tally map, and the users' `about` fields are the PWA's `userBios`.
    final appState = _ref.read(appStateProvider);
    appState.messages.clear();
    appState.reactions.clear();
    for (final u in appState.users.values) {
      u.profile?.about = null;
    }
    // The PWA also wipes the session dedup sets (`processedPMEventIds` /
    // `deletedEventIds`, app.js:4021-4022) — here `_seenIds` /
    // `_seenNymMessageIds` — so relay backlog can re-ingest the wiped
    // conversations instead of being dropped as already-seen duplicates.
    _ref.read(appStateProvider.notifier).clearSessionDedup();
    // Publish the mutated state (an empty hydrate is a bare
    // `state = state.copyWith()` republish) so every open conversation
    // re-renders from the now-empty store — the PWA's emptied `#messages`.
    _ref.read(appStateProvider.notifier).hydrateReactions(const {});
  }

  /// Wipes the on-device PM + group-chat cache (the shared `pms` table). Called
  /// when the user disables "Cache PMs & Group Chats" — the PWA's `clearPMCache`
  /// that the setting's hint promises ("Toggling off clears the existing cached
  /// PM/group data"). Drops the dirty PM keys first so a pending flush can't
  /// immediately re-persist what we just dropped.
  Future<void> clearPmGroupCache() async {
    final cache = _cache;
    if (cache == null || !cache.isOpen) return;
    _dirtyPmKeys.clear();
    await cache.clearPms();
  }

  // --- moderation entry points (role-checked) -------------------------------

  Future<bool> kickFromGroup(String groupId, String targetPubkey,
      {bool ban = false}) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.canModerate(group, identity.pubkey)) return false;
    final ok = await groups.sendControl(
      group: group,
      selfPubkey: identity.pubkey,
      type: GroupControlType.removeMember,
      extraTags: [
        ['kick', targetPubkey],
        if (ban) ['ban', '1'],
      ],
    );
    if (ok) {
      // Apply locally too.
      appState.applyGroupControl(
        groupId: groupId,
        type: GroupControlType.removeMember,
        tags: [
          ['kick', targetPubkey],
          if (ban) ['ban', '1'],
        ],
        senderPubkey: identity.pubkey,
        ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        eventId: GroupLogic.generateGroupId(),
      );
    }
    return ok;
  }

  Future<bool> banFromGroup(String groupId, String targetPubkey) =>
      kickFromGroup(groupId, targetPubkey, ban: true);

  /// Promotes [targetPubkey] to moderator (owner-only). Mirrors users.js
  /// `promoteModerator` → `group-promote-mod`. The role pubkey rides the `mod`
  /// tag (groups.js:2004) — the inbound handler reads `tagValue(tags,'mod')`
  /// (group_logic), so the previous `['promote']` tag applied NOWHERE (F04-B1).
  Future<bool> promoteModerator(String groupId, String targetPubkey) =>
      _sendModRoleControl(
          groupId, targetPubkey, GroupControlType.promoteMod, ['mod', targetPubkey]);

  /// Revokes [targetPubkey]'s moderator role (owner-only). users.js
  /// `revokeModerator` → `group-revoke-mod`. Same `mod` tag the inbound handler
  /// reads (groups.js:2045); the old `['revoke']` tag was a no-op (F04-B2).
  Future<bool> revokeModerator(String groupId, String targetPubkey) =>
      _sendModRoleControl(
          groupId, targetPubkey, GroupControlType.revokeMod, ['mod', targetPubkey]);

  /// Transfers ownership to [targetPubkey] (owner-only). users.js
  /// `transferOwner` → `group-transfer-owner`. New owner rides the `owner` tag
  /// (groups.js:2086); the old `['new_owner']` tag matched nothing inbound, so
  /// ownership transfer was fully non-functional (F04-B3).
  Future<bool> transferOwner(String groupId, String targetPubkey) =>
      _sendModRoleControl(groupId, targetPubkey, GroupControlType.transferOwner,
          ['owner', targetPubkey]);

  Future<bool> _sendModRoleControl(
    String groupId,
    String targetPubkey,
    String type,
    List<String> tag,
  ) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    // Promote/revoke/transfer are owner-only (group_logic §4.1).
    if (!GroupLogic.isOwner(group, identity.pubkey)) return false;
    final extraTags = [tag];
    final ok = await groups.sendControl(
      group: group,
      selfPubkey: identity.pubkey,
      type: type,
      extraTags: extraTags,
    );
    if (ok) {
      appState.applyGroupControl(
        groupId: groupId,
        type: type,
        tags: extraTags,
        senderPubkey: identity.pubkey,
        ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        eventId: GroupLogic.generateGroupId(),
      );
    }
    return ok;
  }

  /// Mod/owner deletion of another member's group message (users.js
  /// `modDeleteGroupMessage`). Publishes a `group-delete-message` control and
  /// removes the message locally. Role is checked.
  Future<bool> modDeleteGroupMessage(
      String groupId, String messageId, String authorPubkey) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    final ownerSelf = GroupLogic.isOwner(group, identity.pubkey);
    final modSelf = GroupLogic.isMod(group, identity.pubkey);
    final targetIsOwner = GroupLogic.isOwner(group, authorPubkey);
    if (!(ownerSelf || (modSelf && !targetIsOwner))) return false;
    // PWA `group-delete-message` carries `['e', targetId]` + `['target_pubkey',
    // author]` (groups.js:2403-2405); the inbound handler (group_logic +
    // app_state) reads exactly those. The previous `['delete']`/`['p']` tags
    // matched nothing, so the delete only ever applied on the actor's own device
    // (F04-B4).
    final extraTags = [
      ['e', messageId],
      ['target_pubkey', authorPubkey],
    ];
    final ok = await groups.sendControl(
      group: group,
      selfPubkey: identity.pubkey,
      type: GroupControlType.deleteMessage,
      extraTags: extraTags,
    );
    appState.removeMessage(messageId);
    if (ok) _emitSystemMessage('Message deleted');
    return ok;
  }

  // ---------------------------------------------------------------------------
  // Group owner / membership controls (groups.js:3046-3083 owner rows). The
  // metadata/leave/add primitives live in [GroupManager]; these drive the local
  // mutation + the gift-wrapped control publish + the PWA's system feedback.
  // ---------------------------------------------------------------------------

  /// Leaves [groupId]: notifies the remaining members with a `group-leave`
  /// control rumor (groups.js `leaveGroup`, 1792), then drops the group locally
  /// so it doesn't reappear from stale relay data (the self-removal path in
  /// app_state's `applyGroupControl`). Switches away if the left group was open.
  /// Returns true if the group existed and was left.
  Future<bool> leaveGroup(String groupId) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;

    // Notify the other members (best-effort; needs a signer).
    final suffix = getPubkeySuffix(identity.pubkey);
    final leaveContent =
        '${stripPubkeySuffix(identity.nym)}#$suffix left the group.';
    await groups.sendLeave(
      group: group,
      selfPubkey: identity.pubkey,
      content: leaveContent,
      settings: _msgSettings,
    );

    // Delete the left group's ephemeral key entry and re-arm the service's
    // unwrap candidates (PWA `groupEphemeralKeys.delete(groupId)` +
    // `_saveEphemeralKeys()`, groups.js:1822-1824) — AFTER the leave wrap
    // above (it encrypts with these keys), BEFORE the control below (whose
    // `onGroupStoreChanged` persist then writes the pruned
    // `nym_ephemeral_keys_<pubkey>` blob without them).
    groups.removeGroup(groupId);

    // Drop locally via the self-removal path (adds to leftGroups, removes the
    // group + its messages). The self-kick is always authorized (group_logic).
    // The applied control fires `onGroupStoreChanged`, which persists the
    // left-group KV (`_saveLeftGroups` + `nym_left_group_times`,
    // groups.js:1813-1817) and the pruned group store, and schedules the
    // outbound settings sync carrying the leave.
    appState.applyGroupControl(
      groupId: groupId,
      type: GroupControlType.removeMember,
      tags: [
        ['kick', identity.pubkey],
      ],
      senderPubkey: identity.pubkey,
      ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      eventId: GroupLogic.generateGroupId(),
    );

    // Security-relevant: overwrite the left group's D1 `nymchat-keys-<gid>`
    // blob with an empty entry so its ephemeral SECRET keys stop being
    // recoverable from D1 (the PWA's `_clearGroupSyncData`, settings.js:193-197
    // — the time-bucketed history shards are intentionally KEPT so the user's
    // own backlog stays durable). Best-effort; the later debounced group sync
    // skips left groups entirely, so this tombstone is the final write.
    final sync = _storageSync;
    if (sync != null) {
      unawaited(sync.groupSyncSet(
        groupConversations: const {},
        ephemeralKeysByGroup: {groupId: const <String, dynamic>{}},
        historyByConvKey: const {},
      ));
    }

    // Stamp the group conversation's read watermark to now and drop its unread
    // badge (groups.js:1818-1821: `channelLastRead.set(groupConvKey, now)` +
    // `unreadCounts.delete` + persist), so a later re-invite can't resurrect a
    // stale unread count. `clearUnread` also fires the watermark persistence.
    appState.clearUnread(GroupLogic.groupStorageKey(groupId));

    // If we were viewing the group, fall back to the last-viewed channel
    // (groups.js:1843-1845 `switchChannel(this.currentChannel || 'nymchat')` —
    // `currentChannel` is nulled while a group is open, so this resolves to
    // the default channel exactly like the PWA).
    if (_ref.read(appStateProvider).view.kind == ViewKind.group &&
        _ref.read(appStateProvider).view.id == groupId) {
      appState.switchView(ChatView.channel('nymchat'));
    }
    return true;
  }

  /// Owner-only: updates [groupId]'s metadata in place (any of [name],
  /// [description], [avatar], [banner]) and broadcasts a `group-metadata` control
  /// to the other members (groups.js `setGroupName`/`setGroupDescription`/
  /// `_applyGroupImage`, all funnel through `_broadcastGroupMetadata`).
  ///
  /// Passing `null` for a field leaves it unchanged; passing an empty string for
  /// [avatar]/[banner] clears it (matching the Remove Avatar/Banner rows). [name]
  /// is single-line sanitized (cap 40); [description] is multiline sanitized
  /// (cap 150, empty ⇒ cleared). Returns true if a change was applied.
  Future<bool> updateGroupMetadata(
    String groupId, {
    String? name,
    String? description,
    String? avatar,
    String? banner,
  }) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.isOwner(group, identity.pubkey)) return false;

    var changed = false;
    if (name != null) {
      final trimmed = _sanitizeGroupName(name);
      if (trimmed.isNotEmpty && trimmed != group.name) {
        group.name = trimmed;
        changed = true;
      }
    }
    if (description != null) {
      final trimmed = _sanitizeGroupDescription(description);
      final next = trimmed.isEmpty ? null : trimmed;
      if (next != group.description) {
        group.description = next;
        changed = true;
      }
    }
    if (avatar != null) {
      final next = avatar.isEmpty ? null : avatar;
      if (next != group.avatar) {
        group.avatar = next;
        changed = true;
      }
    }
    if (banner != null) {
      final next = banner.isEmpty ? null : banner;
      if (next != group.banner) {
        group.banner = next;
        changed = true;
      }
    }
    if (!changed) return false;

    group.metaUpdatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    appState.upsertGroup(group);
    await groups.sendMetadata(
      group: group,
      selfPubkey: identity.pubkey,
      settings: _msgSettings,
    );
    return true;
  }

  /// Owner-only: toggles whether regular members may add others
  /// (groups.js `setGroupAllowMemberInvites`, 2267). Mutates the group locally
  /// and broadcasts a `group-metadata` control. Returns true if the value
  /// changed.
  Future<bool> setGroupAllowInvites(String groupId, bool allow) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.isOwner(group, identity.pubkey)) return false;
    if (allow == group.allowMemberInvites) return false;

    group.allowMemberInvites = allow;
    group.metaUpdatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    appState.upsertGroup(group);
    await groups.sendMetadata(
      group: group,
      selfPubkey: identity.pubkey,
      settings: _msgSettings,
    );
    _emitSystemMessage(allow
        ? 'Group members can now add new users.'
        : 'Only the group owner can add new users now.');
    return true;
  }

  /// Owner-only: turns joining [groupId] via an invite link on or off
  /// (groups.js `setGroupInviteEnabled`, 2288). Mutates the group locally and
  /// broadcasts a `group-metadata` control so members pick up the new
  /// `invite_enabled` flag. Returns true if the value changed.
  Future<bool> setGroupInviteEnabled(String groupId, bool enabled) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.isOwner(group, identity.pubkey)) {
      _emitSystemMessage('Only the group owner can change this setting.');
      return false;
    }
    if (enabled == group.inviteEnabled) return false;

    group.inviteEnabled = enabled;
    group.metaUpdatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    appState.upsertGroup(group);
    await groups.sendMetadata(
      group: group,
      selfPubkey: identity.pubkey,
      settings: _msgSettings,
    );
    _emitSystemMessage(enabled
        ? 'Joining via invite link is now enabled.'
        : 'Joining via invite link is now disabled.');
    return true;
  }

  /// Owner-only: rotates [groupId]'s invite epoch, revoking every outstanding
  /// invite link (groups.js `rotateGroupInviteEpoch`, 2309). Mutates the group
  /// locally and broadcasts a `group-metadata` control. Returns true on success.
  Future<bool> rotateGroupInviteEpoch(String groupId) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.isOwner(group, identity.pubkey)) {
      _emitSystemMessage('Only the group owner can reset the invite link.');
      return false;
    }

    group.inviteEpoch = group.inviteEpoch + 1;
    group.metaUpdatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    appState.upsertGroup(group);
    await groups.sendMetadata(
      group: group,
      selfPubkey: identity.pubkey,
      settings: _msgSettings,
    );
    _emitSystemMessage(
        'Previous invite links revoked. A new link is now active.');
    return true;
  }

  /// Adds [pubkeys] to [groupId] (owner, or a member when member-invites are
  /// allowed; groups.js `addMemberToGroup`, 1418). Each new member is appended
  /// locally, then a single `group-add-member` control is broadcast carrying the
  /// updated roster + metadata + the self ephemeral key. Already-present members
  /// are skipped; banned users are skipped unless the caller can moderate.
  /// Returns true if at least one member was added.
  Future<bool> addGroupMembers(String groupId, List<String> pubkeys) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.canAddMembers(group, identity.pubkey)) return false;

    final canMod = GroupLogic.canModerate(group, identity.pubkey);
    final added = <String>[];
    for (final pk in pubkeys) {
      if (pk.isEmpty || pk == identity.pubkey) continue;
      if (group.members.contains(pk)) continue;
      // Re-admitting a banned user requires owner/mod.
      if (group.banned.contains(pk)) {
        if (!canMod) continue;
        group.banned.remove(pk);
      }
      group.members.add(pk);
      added.add(pk);
    }
    if (added.isEmpty) return false;
    appState.upsertGroup(group);

    final inviter = '${stripPubkeySuffix(identity.nym)}#'
        '${getPubkeySuffix(identity.pubkey)}';
    final names = added.map((pk) => _nymDisplayFor(pk)).join(', ');
    final content = added.length == 1
        ? '$names was added by $inviter.'
        : '$names were added by $inviter.';
    await groups.addMembers(
      group: group,
      selfPubkey: identity.pubkey,
      content: content,
      settings: _msgSettings,
    );
    _emitSystemMessage(content);
    return true;
  }

  /// Single-line group-name sanitizer (groups.js `sanitizeGroupName`): strips
  /// control chars, collapses whitespace, caps at 40.
  static String _sanitizeGroupName(String name) {
    final collapsed = name
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return collapsed.length > 40 ? collapsed.substring(0, 40) : collapsed;
  }

  /// Multiline group-description sanitizer (groups.js `sanitizeGroupDescription`):
  /// keeps newlines, strips other control chars, collapses 3+ newlines, caps 150.
  static String _sanitizeGroupDescription(String description) {
    final cleaned = description
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return cleaned.length > 150 ? cleaned.substring(0, 150) : cleaned;
  }

  // ---------------------------------------------------------------------------
  // Social / moderation (docs/specs/03 §11) — friends, user blocking, keyword
  // filtering. State lives in app_state; this layer drives the change +
  // persistence + the PWA's system-message feedback.
  // ---------------------------------------------------------------------------

  /// Toggles [pubkey] as a friend, persists `nym_friends`, and surfaces the
  /// PWA's add/remove system message. Mirrors users.js `toggleFriend`.
  bool toggleFriend(String pubkey) {
    if (pubkey.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final nowFriend = appState.toggleFriend(pubkey);
    _persistSet(StorageKeys.friends, _ref.read(appStateProvider).friends);
    final nymHtml = _nymDisplayFor(pubkey);
    _emitSystemMessage(nowFriend
        ? 'Added $nymHtml as a friend'
        : 'Removed $nymHtml from friends');
    return nowFriend;
  }

  /// Blocks [pubkey] (hides their messages), persists `nym_blocked`, and
  /// surfaces the PWA's "Blocked …" message. users.js
  /// `toggleBlockUserByPubkey` (add branch).
  bool blockUser(String pubkey) {
    if (pubkey.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final added = appState.blockUser(pubkey);
    if (added) {
      _persistSet(StorageKeys.blocked, _ref.read(appStateProvider).blockedUsers);
      // A blocked sender's notifications stop counting toward the bell badge
      // immediately (PWA count-time exclusion, notifications.js:404-426; C02-4).
      _ref
          .read(notificationHistoryProvider.notifier)
          .setBlocked(_ref.read(appStateProvider).blockedUsers);
      _emitSystemMessage('Blocked ${_nymDisplayFor(pubkey)}');
      // Blocking mid-call ends a 1:1 call / drops the peer from a group call and
      // hides their chat (calls.js `_onUserBlockedForCall`).
      _ref.read(callServiceProvider).onUserBlocked(pubkey);
    }
    return added;
  }

  /// Unblocks [pubkey], persists `nym_blocked`, restores their messages, and
  /// surfaces "Unblocked …". users.js `unblockByPubkey`.
  bool unblockUser(String pubkey) {
    final appState = _ref.read(appStateProvider.notifier);
    final removed = appState.unblockUser(pubkey);
    if (removed) {
      _persistSet(StorageKeys.blocked, _ref.read(appStateProvider).blockedUsers);
      // Re-sync the badge's blocked-sender set so an unblocked user's
      // notifications count again (C02-4).
      _ref
          .read(notificationHistoryProvider.notifier)
          .setBlocked(_ref.read(appStateProvider).blockedUsers);
      _emitSystemMessage('Unblocked ${_nymDisplayFor(pubkey)}');
    }
    return removed;
  }

  /// Toggles [pubkey]'s block state (context-menu Block/Unblock toggle).
  bool toggleBlockUser(String pubkey) {
    final blocked = _ref.read(appStateProvider).blockedUsers.contains(pubkey);
    return blocked ? !unblockUser(pubkey) : blockUser(pubkey);
  }

  /// Adds a blocked keyword (lowercased), persists `nym_blocked_keywords`, and
  /// surfaces the PWA message. users.js `addBlockedKeyword`.
  bool addBlockedKeyword(String keyword) {
    final appState = _ref.read(appStateProvider.notifier);
    final kw = appState.addBlockedKeyword(keyword);
    if (kw == null) return false;
    _persistSet(
        StorageKeys.blockedKeywords, _ref.read(appStateProvider).blockedKeywords);
    _emitSystemMessage('Blocked keyword: "$kw"');
    return true;
  }

  /// Removes a blocked keyword, persists, surfaces the PWA message. users.js
  /// `removeBlockedKeyword`.
  bool removeBlockedKeyword(String keyword) {
    final appState = _ref.read(appStateProvider.notifier);
    final removed = appState.removeBlockedKeyword(keyword);
    if (removed) {
      _persistSet(StorageKeys.blockedKeywords,
          _ref.read(appStateProvider).blockedKeywords);
      _emitSystemMessage('Unblocked keyword: "${keyword.toLowerCase()}"');
    }
    return removed;
  }

  // ---------------------------------------------------------------------------
  // Message edit / delete (messages.js startEditMessage / publishEdited… /
  // publishDeletionEvent). Tag construction is in pure helpers so it's testable
  // without a live signer; publishing uses existing service primitives.
  // ---------------------------------------------------------------------------

  /// Edits [messageId] to [newContent]. For a channel message this re-publishes
  /// the channel event with an extra `['edit', originalId]` tag (mirrors
  /// `publishEditedChannelMessage`); for PM/group it re-sends the rumor with the
  /// same `['edit', originalId]` tag. The local copy is rewritten + flagged
  /// edited. Returns true if a publish was attempted.
  Future<bool> editMessage(String messageId, String newContent) async {
    final trimmed = newContent.trim();
    if (messageId.isEmpty || trimmed.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final identity = _identity;
    final view = state.view;

    // Local rewrite first (optimistic, matches the PWA's in-place update).
    appState.applyLocalEdit(messageId, trimmed);
    _markDirty(view.storageKey);

    if (service == null || identity == null || !service.canSign) return false;

    if (view.kind == ViewKind.channel) {
      final isGeo = state.channels
          .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
      final tags = buildChannelEditTags(
        nym: identity.nym,
        channelKey: view.id,
        isGeohash: isGeo,
        originalId: messageId,
      );
      final unsigned = UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: isGeo ? EventKind.geoChannel : EventKind.namedChannel,
        tags: tags,
        content: trimmed,
      );
      final signed = await _signer!.sign(unsigned);
      await service.pool.publish(signed);
      return true;
    }

    // PM / group edit: gift-wrap the rumor (kind 14) carrying ['edit', id].
    if (view.kind == ViewKind.pm) {
      final base = PmLogic.buildPmRumor(
        selfPubkey: identity.pubkey,
        recipientPubkey: view.id,
        content: trimmed,
        nymMessageId: PmLogic.generateSharedEventId(),
      );
      await service.publishPM(
        rumor: _withEditTag(base, messageId),
        recipientPubkey: view.id,
        settings: _msgSettings,
      );
      return true;
    }

    if (view.kind == ViewKind.group) {
      final group = appState.groupById(view.id);
      if (group == null) return false;
      final ek = _groups!.keysFor(group.id);
      final next = ek.rotateSelf();
      _service!.setEphemeralKeys(_groups!.allEphemeralSecretKeys());
      // A self-key rotation on send: persist the new key locally, re-REQ the
      // live ephemeral gift-wrap subscription so replies wrapped to the NEW
      // key arrive, and sync so our other devices can decrypt this message's
      // wrap (the PWA saves + refreshes subs + debounce-syncs after every
      // group send, groups.js:1754-1758 / :1298).
      _afterSelfKeyRotation();
      final base = GroupLogic.buildGroupMessageRumor(
        group: group,
        selfPubkey: identity.pubkey,
        content: trimmed,
        nymMessageId: GroupLogic.generateGroupId(),
        ephemeralPk: next.pk,
        // Owner metadata piggyback, same as a fresh send.
        extraTags: GroupLogic.groupMetaPiggybackTags(group, identity.pubkey),
      );
      await service.publishGroupMessage(
        rumor: _withEditTag(base, messageId),
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
        settings: _msgSettings,
        onWrap: _archiveSentWrap,
      );
      return true;
    }
    return false;
  }

  /// Returns a copy of [rumor] with an appended `['edit', originalId]` tag
  /// (pms.js / groups.js append `['edit', originalNymMessageId || originalId]`).
  UnsignedEvent _withEditTag(UnsignedEvent rumor, String originalId) {
    return UnsignedEvent(
      pubkey: rumor.pubkey,
      createdAt: rumor.createdAt,
      kind: rumor.kind,
      tags: [
        ...rumor.tags,
        ['edit', originalId],
      ],
      content: rumor.content,
    );
  }

  /// Publishes a kind-5 deletion for [messageId] (`['e', id], ['k', origKind]`)
  /// and removes the message locally. [originalKind] defaults to the active
  /// view's kind: 1059 for PM/group (gift wraps), else the channel wire kind
  /// (20000 geohash / 23333 named). Mirrors `publishDeletionEvent` +
  /// `deleteMessageFromContext`.
  Future<bool> deleteMessage(String messageId, {String? originalKind}) async {
    if (messageId.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final identity = _identity;
    final view = state.view;

    final kind = originalKind ?? _viewDeletionKind(state);

    // Locate the channel (if any) holding this message BEFORE the local
    // removal, so the D1 purge can name it (nostr-core.js:1862-1873 scans the
    // in-memory store for the message id).
    String? channelName;
    for (final entry in state.messages.entries) {
      if (!entry.key.startsWith('#')) continue;
      if (entry.value.any((m) => m.id == messageId)) {
        channelName = entry.key.substring(1);
        break;
      }
    }

    appState.removeMessage(messageId);
    _markDirty(view.storageKey);

    if (service == null || identity == null || !service.canSign) return false;
    final unsigned = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: EventKind.deletion,
      tags: buildDeletionTags(messageId, kind),
      content: '',
    );
    final signed = await _signer!.sign(unsigned);
    await service.pool.publish(signed);

    // Mirror the NIP-09 deletion into the D1 archive (`_propagateDeletionToD1`,
    // nostr-core.js:1858-1885): the channel copy via the PUBLIC `channel-delete`
    // (the signed kind-5 IS the authorization, storage.js:1123-1150) and our
    // own archived gift wrap via the authed `pm-delete` (storage.js:945-961) —
    // otherwise the "deleted" message resurrects on the next D1 rehydration.
    final sync = _storageSync;
    if (sync != null) {
      if (channelName != null) {
        unawaited(sync.channelDelete(channelName, signed.toJson()));
      }
      // PM/group wraps we archived are keyed by their gift-wrap event ids;
      // gate on the same archive-allowed check the PWA uses
      // (`_pmArchiveAllowed`: durable identity + cachePMs).
      if (kind == '${EventKind.giftWrap}' &&
          sync.durableIdentity &&
          _ref.read(settingsProvider).cachePMs) {
        unawaited(sync.pmDelete([messageId]));
      }
    }
    _emitSystemMessage('Deletion request sent to relays');
    return true;
  }

  /// The kind tag a deletion should carry for the active view: 1059 for PM/group
  /// (the gift wraps), else the channel wire kind.
  String _viewDeletionKind(AppState state) {
    final view = state.view;
    if (view.kind != ViewKind.channel) return '${EventKind.giftWrap}';
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    return '${isGeo ? EventKind.geoChannel : EventKind.namedChannel}';
  }

  String _nymDisplayFor(String pubkey) {
    // Unknown-user fallback is 'nym' (PWA `getNymFromPubkey` → `nym#xxxx`,
    // users.js:1085 — the PWA never renders 'anon').
    final u = _ref.read(appStateProvider).users[pubkey];
    final base = stripPubkeySuffix(u?.nym ?? 'nym');
    return '$base#${getPubkeySuffix(pubkey)}';
  }

  // --- presence / typing / receipts -----------------------------------------

  /// Last public presence broadcast (ms). Throttles `recordOwnActivity` relay
  /// broadcasts to ≤1/60s (nostr-core.js `_lastPresenceBroadcast`).
  int _lastPresenceBroadcast = 0;

  static const int _presenceBroadcastThrottleMs = 60000;

  /// The status-visibility mode from `nym_show_status`
  /// ('true'|'friends'|'false') → PresenceStatusMode (PWA `_statusMode`).
  PresenceStatusMode get _statusMode =>
      presenceStatusModeFrom(_ref.read(settingsProvider).showStatus);

  /// Publishes our presence (kind-30078 nym-presence). [status] is our real
  /// status; the service computes the public status from [_statusMode]. Always
  /// carries the avatar tag so others can render our latest avatar from the
  /// single replaceable event. [shopUpdate] adds the one-off
  /// `['shop-update','1']` cache-bust flag — ONLY set right after our active
  /// shop items change (`publishShopUpdate`, nostr-core.js:2876-2885); routine
  /// presence never carries it (nostr-core.js:2743-2751), so peers aren't
  /// forced into a fresh D1 `shop-status` fetch on every broadcast.
  Future<void> publishPresence(String status,
      {String awayMessage = '', bool shopUpdate = false}) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;
    final avatar =
        _ref.read(appStateProvider).users[identity.pubkey]?.profile?.picture;
    await service.publishPresence(
      status: status,
      nym: identity.nym,
      awayMessage: awayMessage,
      mode: _statusMode,
      avatarUrl: (avatar != null && avatar.isNotEmpty) ? avatar : null,
      shopUpdate: shopUpdate,
    );
    _lastPresenceBroadcast = DateTime.now().millisecondsSinceEpoch;

    // Friends-only: also deliver our real status privately to each friend via a
    // gift-wrapped kind-25054 rumor (nostr-core.js `_sendFriendPresence`). The
    // public event above already went out as `hidden`.
    if (_statusMode == PresenceStatusMode.friends) {
      unawaited(_sendFriendPresence(status, awayMessage: awayMessage));
    }
  }

  /// Gift-wraps our real presence (kind-25054) to each friend so only they can
  /// read it (nostr-core.js `_sendFriendPresence`). Best-effort; routed through
  /// the active [EventSigner] so it works under nsec/ephemeral and NIP-46.
  Future<void> _sendFriendPresence(String status,
      {String awayMessage = ''}) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null || !service.canSign) return;
    final friends = _ref.read(appStateProvider).friends;
    if (friends.isEmpty) return;
    final recipients =
        friends.where((pk) => pk.isNotEmpty && pk != identity.pubkey).toList();
    if (recipients.isEmpty) return;
    await service.sendFriendPresence(
      status: status,
      nym: identity.nym,
      recipients: recipients,
      awayMessage: awayMessage,
    );
  }

  /// Records local activity so our own status stays "online" and other clients
  /// see us as recently active. Called on connect and on every send/react — the
  /// PWA's presence is purely event-driven, with NO periodic heartbeat (C03-D7).
  /// Throttles relay broadcasts to ≤1/60s; skipped while away or when status is
  /// disabled (nostr-core.js `recordOwnActivity`).
  void recordOwnActivity() {
    final identity = _identity;
    if (identity == null) return;
    final appState = _ref.read(appStateProvider.notifier);
    final now = DateTime.now().millisecondsSinceEpoch;

    final existing = _ref.read(appStateProvider).users[identity.pubkey];
    final away = existing?.awayMessage != null &&
        existing!.awayMessage!.isNotEmpty;
    // Mark ourselves recently-seen (online unless locally away).
    appState.setUserPresence(
      pubkey: identity.pubkey,
      status: away ? UserStatus.away : UserStatus.online,
      nym: identity.nym,
      awayMessage: away ? existing.awayMessage : null,
      lastSeenMs: now,
    );

    // Disabled: never re-assert presence (a routine send would undo 'hidden').
    if (_statusMode == PresenceStatusMode.disabled) return;
    // Throttle to ≤1/60s; skip while away (cmdSetAway/cmdBack handle those).
    if (now - _lastPresenceBroadcast < _presenceBroadcastThrottleMs) return;
    if (away) return;
    unawaited(publishPresence('online'));
  }

  /// Signals typing in the current PM/group view (throttled ~3/s — C03-D4).
  Future<void> sendTypingStart() async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;
    final state = _ref.read(appStateProvider);
    final view = state.view;
    // Context-aware scope gate (PWA `isIndicatorAllowedFor`): a typing scope of
    // 'pms' / 'groups' / 'pms-groups' restricts indicators to those surfaces and
    // 'disabled' suppresses them; channels require the default 'everywhere'.
    final scope = _ref.read(settingsProvider).typingIndicatorsScope;
    final ctx = view.kind == ViewKind.pm
        ? 'pm'
        : view.kind == ViewKind.group
            ? 'group'
            : 'channel';
    if (!_indicatorScopeAllows(scope, ctx)) return;

    final key = view.storageKey;
    final now = DateTime.now().millisecondsSinceEpoch;
    // PWA `_typingSendInterval = 3000` (app.js:741) — re-broadcast typing-start
    // at most once per 3s, not 1s (C03-D4).
    if (now - (_typingThrottle[key] ?? 0) < _typingSendIntervalMs) return;
    _typingThrottle[key] = now;

    if (view.kind == ViewKind.channel) {
      // Public channel typing (kind 24420). The channel wire tag is `g` for a
      // geohash channel and `d` for a named channel (e.g. #nymchat); the PWA
      // gates its send on `currentGeohash`, but the receive + subscribe sides
      // already handle both tags, so we send for both to make named-channel
      // typing work Flutter↔Flutter.
      final entry = state.channels.where((c) => c.key == view.id.toLowerCase());
      if (entry.isEmpty) return;
      await service.publishChannelTyping(
        status: 'start',
        channelKey: entry.first.key,
        isGeohash: entry.first.isGeohash,
        nym: identity.nym,
      );
      return;
    }

    if (view.kind == ViewKind.pm) {
      await service.publishTyping(status: 'start', recipients: [view.id]);
    } else {
      final group = _ref.read(appStateProvider.notifier).groupById(view.id);
      if (group == null) return;
      final ek = _groups!.keysFor(group.id);
      final others =
          group.members.where((p) => p != identity.pubkey).toList();
      await service.publishTyping(
        status: 'start',
        recipients: others,
        groupId: group.id,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
      );
    }
  }

  /// Mirrors the PWA `isIndicatorAllowedFor`: a typing / read-receipt scope of
  /// 'pms', 'groups', or 'pms-groups' limits indicators to those contexts,
  /// 'disabled' suppresses them, and anything else ('everywhere') allows all
  /// surfaces — including public channels.
  bool _indicatorScopeAllows(String scope, String context) {
    switch (scope) {
      case 'disabled':
        return false;
      case 'pms':
        return context == 'pm';
      case 'groups':
        return context == 'group';
      case 'pms-groups':
        return context == 'pm' || context == 'group';
      default:
        return true;
    }
  }

  /// PM message ids (nymMessageIds) we've already published a 'read' receipt
  /// for, so opening / re-opening a PM never re-announces the same read (mirrors
  /// [_sentChannelReadReceipts]); capped 2000 → trimmed to the most recent 1500.
  final Set<String> _sentPmReadReceipts = <String>{};

  /// Sends a read receipt for [messageId] to [peerPubkey], scope-gated to the
  /// PM context (PWA `_indicatorScopeAllows(readReceiptsScope, 'pm')`, F02): a
  /// scope of 'groups' / 'disabled' must NOT leak a PM read receipt. Deduped via
  /// [_sentPmReadReceipts] so the same message is receipted at most once.
  Future<void> sendReadReceipt(String messageId, String peerPubkey) async {
    if (!_indicatorScopeAllows(
        _ref.read(settingsProvider).readReceiptsScope, 'pm')) {
      return;
    }
    if (messageId.isEmpty || peerPubkey.isEmpty) return;
    final service = _service;
    if (service == null) return;
    if (!_sentPmReadReceipts.add(messageId)) return;
    if (_sentPmReadReceipts.length > 2000) {
      final keep = _sentPmReadReceipts
          .toList()
          .sublist(_sentPmReadReceipts.length - 1500);
      _sentPmReadReceipts
        ..clear()
        ..addAll(keep);
    }
    await service.publishReceipt(
      messageId: messageId,
      receiptType: 'read',
      recipientPubkey: peerPubkey,
    );
  }

  /// Receipts every loaded, non-own PM message in the open conversation with
  /// [peerPubkey] as 'read' (PWA `openPM` send + send-while-viewing,
  /// pms.js:3015-3019 / 1345-1356). Per-message dedup lives in [sendReadReceipt].
  void markVisiblePmMessagesRead(String peerPubkey) {
    if (peerPubkey.isEmpty) return;
    final messages =
        _ref.read(appStateProvider).messages[PmLogic.pmStorageKey(peerPubkey)];
    if (messages == null || messages.isEmpty) return;
    for (final m in messages) {
      if (m.isOwn) continue;
      final id = m.nymMessageId;
      if (id == null || id.isEmpty) continue;
      unawaited(sendReadReceipt(id, peerPubkey));
    }
  }

  // --- Public channel read receipts (kind 24421) -----------------------------
  // Mirrors the PWA's channel read-receipt path (nostr-core.js
  // `sendChannelReadReceipt` / `markVisibleChannelMessagesRead` /
  // `handleChannelReadReceipt`). Geohash channels only, like channel typing.

  /// Message ids we've already published a 24421 read receipt for, so we never
  /// re-announce the same channel message (PWA `_sentChannelReadReceipts`,
  /// capped 2000 → trimmed to the most recent 1500).
  final Set<String> _sentChannelReadReceipts = <String>{};

  bool _channelReceiptAllowed() =>
      _indicatorScopeAllows(
          _ref.read(settingsProvider).readReceiptsScope, 'channel');

  /// Publishes a public channel read receipt (kind 24421) for [messageId] by
  /// [authorPubkey] in [channelKey], once per message. Scope-gated to the
  /// channel context (PWA `sendChannelReadReceipt`): never receipts our own
  /// message, and dedupes via [_sentChannelReadReceipts]. [isGeohash] selects
  /// the `g` (geohash) vs `d` (named channel) wire tag.
  Future<void> sendChannelReadReceipt(
      String messageId, String authorPubkey, String channelKey,
      {bool isGeohash = true}) async {
    if (!_channelReceiptAllowed()) return;
    if (messageId.isEmpty || authorPubkey.isEmpty || channelKey.isEmpty) return;
    final identity = _identity;
    final service = _service;
    if (identity == null || service == null) return;
    if (authorPubkey == identity.pubkey) return;
    if (_sentChannelReadReceipts.contains(messageId)) return;
    _sentChannelReadReceipts.add(messageId);
    if (_sentChannelReadReceipts.length > 2000) {
      final keep = _sentChannelReadReceipts.toList().sublist(
          _sentChannelReadReceipts.length - 1500);
      _sentChannelReadReceipts
        ..clear()
        ..addAll(keep);
    }
    await service.publishChannelReceipt(
      messageId: messageId,
      authorPubkey: authorPubkey,
      channelKey: channelKey,
      isGeohash: isGeohash,
      nym: identity.nym,
    );
  }

  /// Catch-up: receipts every visible, fresh, non-own message in the currently
  /// open geohash channel (PWA `markVisibleChannelMessagesRead`). Called when
  /// the user opens / returns to a channel and on inbound messages, so receipts
  /// fire for messages that piled up while away. Per-message dedup lives in
  /// [sendChannelReadReceipt].
  void markVisibleChannelMessagesRead() {
    if (!_channelReceiptAllowed()) return;
    final identity = _identity;
    if (identity == null) return;
    final state = _ref.read(appStateProvider);
    final view = state.view;
    if (view.kind != ViewKind.channel) return;
    final entry = state.channels.where((c) => c.key == view.id.toLowerCase());
    if (entry.isEmpty) return;
    final channelKey = entry.first.key;
    final isGeohash = entry.first.isGeohash;
    final messages = state.messages[view.storageKey];
    if (messages == null || messages.isEmpty) return;
    // Mirror the PWA's tail window (`messages.slice(-channelPageSize)`); 100 is
    // the runtime channel page size used elsewhere.
    final tail = messages.length > 100
        ? messages.sublist(messages.length - 100)
        : messages;
    for (final m in tail) {
      if (m.isOwn || m.isHistorical) continue;
      if (!_isChannelMessageId(m.id)) continue;
      // Geohash channels can carry a per-message geohash; named channels always
      // use the channel key as the `d`-tag value.
      final key = isGeohash
          ? ((m.geohash ?? '').isNotEmpty ? m.geohash! : channelKey)
          : channelKey;
      unawaited(
          sendChannelReadReceipt(m.id, m.pubkey, key, isGeohash: isGeohash));
    }
  }

  /// True for a 64-hex channel-message id (PWA `/^[0-9a-f]{64}$/i` gate before
  /// a channel read receipt is sent).
  static final RegExp _channelMessageIdRe = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
  bool _isChannelMessageId(String id) => _channelMessageIdRe.hasMatch(id);

  // --- Group read receipts (gift-wrapped kind-69420, shown as reader avatars) -
  // Mirrors the PWA's group receipt path (groups.js `sendNymReceipt(..,'read',
  // ..,'group',groupId)` + `_markVisibleGroupMessagesRead`). A group renders
  // stacked reader avatars (like channels), NOT a delivery checkmark, so we only
  // send/track the 'read' receipt; encryption targets the sender's ephemeral key.

  /// nymMessageIds we've already published a group 'read' receipt for.
  final Set<String> _sentGroupReadReceipts = <String>{};

  /// Publishes a group read receipt (gift-wrapped kind 69420, `receipt:'read'`)
  /// for [messageId] to its author [authorPubkey] in [groupId], encrypted to the
  /// author's advertised ephemeral key. Scope-gated to the `group` context and
  /// deduped once per message; never receipts our own message.
  Future<void> sendGroupReadReceipt(
      String messageId, String authorPubkey, String groupId) async {
    if (!_indicatorScopeAllows(
        _ref.read(settingsProvider).readReceiptsScope, 'group')) {
      return;
    }
    if (messageId.isEmpty || authorPubkey.isEmpty) return;
    final identity = _identity;
    final service = _service;
    if (identity == null || service == null) return;
    if (authorPubkey == identity.pubkey) return;
    if (!_sentGroupReadReceipts.add(messageId)) return;
    if (_sentGroupReadReceipts.length > 2000) {
      final keep = _sentGroupReadReceipts
          .toList()
          .sublist(_sentGroupReadReceipts.length - 1500);
      _sentGroupReadReceipts
        ..clear()
        ..addAll(keep);
    }
    final ek = _groups?.keysFor(groupId);
    await service.publishReceipt(
      messageId: messageId,
      receiptType: 'read',
      recipientPubkey: authorPubkey,
      encryptToPubkey: ek?.encryptionPubkeyFor(authorPubkey, identity.pubkey),
    );
  }

  /// Catch-up: read-receipts every loaded, non-own message in the open group
  /// [groupId] (PWA `_markVisibleGroupMessagesRead`). Called on opening / return
  /// to a group so receipts fire for messages that piled up while away.
  void markVisibleGroupMessagesRead(String groupId) {
    if (groupId.isEmpty) return;
    if (!_indicatorScopeAllows(
        _ref.read(settingsProvider).readReceiptsScope, 'group')) {
      return;
    }
    final messages =
        _ref.read(appStateProvider).messages[GroupLogic.groupStorageKey(groupId)];
    if (messages == null || messages.isEmpty) return;
    for (final m in messages) {
      if (m.isOwn || m.isHistorical) continue;
      final id = m.nymMessageId;
      if (id == null || id.isEmpty) continue;
      unawaited(sendGroupReadReceipt(id, m.pubkey, groupId));
    }
  }

  /// Routes an inbound public channel typing indicator (kind 24420): a peer is
  /// typing in a geohash channel. Mirrors the PWA's `handleChannelTypingEvent`
  /// (nostr-core.js:1542-1578): skips our own + scope-disallowed + stale (>5s,
  /// `_typingExpireMs`) signals + blocked senders, parses the `['typing',
  /// status]` / `['g'|'d', geo]` tags, and feeds the per-channel typing store
  /// keyed by the active channel's storageKey (`#<geohash>`) with a 5s TTL —
  /// status `'stop'` clears the indicator immediately. Without this the public
  /// channel typing indicator never appeared (C03-D6).
  void _onChannelTypingEvent(NostrEvent event, AppStateNotifier appState) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (event.pubkey == self) return;
    // Scope gate (PWA `isTypingIndicatorAllowedFor('channel')`): channel typing
    // only shows when the typing-indicator scope is 'everywhere'.
    final scope = _ref.read(settingsProvider).typingIndicatorsScope;
    if (!_indicatorScopeAllows(scope, 'channel')) return;
    // Stale-drop at 5s (`_typingExpireMs`), matching the receive-side TTL.
    final ageMs = DateTime.now().millisecondsSinceEpoch - event.createdAt * 1000;
    if (ageMs > 5000) return;
    if (_ref.read(appStateProvider).blockedUsers.contains(event.pubkey)) return;

    final status = event.tagValue('typing');
    final geohash = event.tagValue('g') ?? event.tagValue('d');
    if (status == null || geohash == null || geohash.isEmpty) return;

    // The typing store keys on the active view's storageKey; a geohash channel
    // view is `ChatView.channel(geohash)` → storageKey `'#<geohash>'`
    // (app_state.dart:94). `setTyping` removes the entry on `typing: false`,
    // mirroring the PWA's `status === 'stop'` branch. The `['n', nym]` tag lets
    // the typing row show the real name for a sender we've never seen a message
    // from (else it falls back to "Someone").
    appState.setTyping(
      storageKey: '#${geohash.toLowerCase()}',
      pubkey: event.pubkey,
      typing: status == 'start',
      nym: event.tagValue('n'),
    );
  }

  /// Routes an inbound public channel read receipt (kind 24421): someone saw a
  /// channel message. Mirrors the PWA's `handleChannelReadReceipt`: skips our
  /// own + stale (>5 min) receipts, parses the `['e', id]` / `['g'|'d', geo]` /
  /// `['n', nym]` tags, resolves the reader's display nym, and records it so the
  /// matching own message's reader avatars render.
  void _onChannelReadReceipt(NostrEvent event) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (event.pubkey == self) return;
    final ageMs = DateTime.now().millisecondsSinceEpoch - event.createdAt * 1000;
    if (ageMs > 5 * 60 * 1000) return;

    final messageId = event.tagValue('e');
    final geohash = event.tagValue('g') ?? event.tagValue('d');
    if (messageId == null || messageId.isEmpty || geohash == null) return;

    final appState = _ref.read(appStateProvider);
    if (appState.blockedUsers.contains(event.pubkey)) return;

    // A read receipt is a self-attestation that the reader runs Nymchat — add
    // them to the trust graph + our vouch list (nostr-core.js:1647-1650).
    _observeNymchatPubkey(event.pubkey);

    // Reader display name: the receipt's `['n', nym]` (base), else the known
    // user nym, decorated with the pubkey suffix (PWA `stripPubkeySuffix(rawNym
    // || getNymFromPubkey(pubkey))`).
    final rawNym = event.tagValue('n');
    // Fallback 'nym', matching `getNymFromPubkey`'s default (users.js:1085).
    final base = stripPubkeySuffix(
        rawNym ?? appState.users[event.pubkey]?.nym ?? 'nym');
    final readerNym = '$base#${getPubkeySuffix(event.pubkey)}';

    _ref.read(appStateProvider.notifier).applyChannelReader(
          messageId: messageId,
          readerPubkey: event.pubkey,
          readerNym: readerNym,
        );
  }

  // ---------------------------------------------------------------------------
  // Reactions (kind 7 public / gift-wrapped private)
  // ---------------------------------------------------------------------------

  /// Toggles the local user's [emoji] reaction on [messageId]. [target] is the
  /// reacted message's author pubkey; [kind] is the reacted message's kind
  /// ('20000' geohash / '23333' named / '1059' PM / '14' group rumor). Applies
  /// an optimistic local update, enforces the 3/30s rate limit + 60s cooldown,
  /// and re-sends with `['action','remove']` to un-react. Private (PM/group)
  /// reactions are gift-wrapped per docs/specs/03 §5.2.
  ///
  /// Returns true if the toggle was sent (false when rate-limited or no signer).
  Future<bool> toggleReaction(
    String messageId,
    String emoji, {
    required String target,
    required String kind,
  }) async {
    if (messageId.isEmpty || emoji.isEmpty) return false;
    if (!_checkReactionRateLimit(messageId, emoji)) return false;

    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final self = state.selfPubkey;

    // Determine current reaction state to decide add vs remove.
    final existing = state.reactions[messageId] ?? const [];
    final reacted = existing.any((r) => r.emoji == emoji && r.userReacted);
    final remove = reacted;

    // Optimistic local update.
    appState.applyReaction(
      messageId: messageId,
      emoji: emoji,
      reactor: self,
      removed: remove,
      reactorNym: state.selfNym,
    );

    final service = _service;
    if (service == null || !service.canSign) return false;

    // Private reactions (PM/group) are gift-wrapped to the conversation. The
    // PUBLISHED `e` tag must reference the SHARED `nymMessageId` — the local
    // gift-wrap id is meaningless to the recipient's client (and the PWA), which
    // correlate the reaction to their own copy by the shared id. The optimistic
    // local update above stays keyed on the wrap `messageId`.
    if (kind == '1059' || kind == '14') {
      final shareId = appState.messageById(messageId)?.nymMessageId ?? messageId;
      return _sendPrivateReaction(shareId, emoji, target, remove);
    }

    // Public channel reaction. Resolve the channel context from the active view.
    String? geohash;
    String? channel;
    if (state.view.kind == ViewKind.channel) {
      final entry = state.channels
          .where((c) => c.key == state.view.id.toLowerCase());
      if (entry.isNotEmpty && entry.first.isGeohash) {
        geohash = entry.first.geohash;
      } else {
        channel = state.view.id;
      }
    }
    await service.publishReaction(
      messageId: messageId,
      targetPubkey: target,
      emoji: emoji,
      originalKind: kind,
      geohash: geohash,
      channel: channel,
      remove: remove,
    );
    return true;
  }

  Future<bool> _sendPrivateReaction(
      String messageId, String emoji, String target, bool remove) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // NIP-30 declarations for a custom `:shortcode:` reaction — the PWA
    // spreads `...customEmojiTagsForContent(emoji)` onto BOTH the group and
    // 1:1 rumors, add and remove alike (reactions.js:1018-1041, 1139-1161).
    final emojiTags = _ref
        .read(liveCustomEmojiProvider.notifier)
        .emojiTagsForContent(emoji);

    // Group message reaction: gift-wrap to all members with ['g',groupId].
    final view = _ref.read(appStateProvider).view;
    if (view.kind == ViewKind.group) {
      final group = appState.groupById(view.id);
      if (group == null) return false;
      final ek = _groups!.keysFor(group.id);
      final rumor = UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.reaction,
        tags: [
          ['g', group.id],
          ['e', messageId],
          ['k', '14'],
          if (remove) ['action', 'remove'],
          ...emojiTags,
        ],
        content: emoji,
      );
      return service.publishGiftWrappedRumor(
        rumor: rumor,
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
        // Durable content: archive/deposit the sent wraps like the PWA
        // (reactions ride `_depositPMEvent`, pms.js:467) so the reaction
        // BACKFILLS for offline members and on relaunch.
        onWrap: _archiveSentWrap,
      );
    }

    // 1:1 PM reaction: gift-wrap to [self, peer] with ['p',target],['k','1059'].
    final peer = view.kind == ViewKind.pm ? view.id : target;
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.reaction,
      tags: [
        ['e', messageId],
        ['p', target],
        ['k', '1059'],
        if (remove) ['action', 'remove'],
        ...emojiTags,
      ],
      content: emoji,
    );
    return service.publishGiftWrappedRumor(
      rumor: rumor,
      recipients: [identity.pubkey, peer],
      // Archive our copy + deposit the peer's at send (pms.js:467) so PM
      // reactions restore from D1 on both sides.
      onWrap: _archiveSentWrap,
    );
  }

  bool _checkReactionRateLimit(String messageId, String emoji) {
    final key = '$messageId:$emoji';
    final now = DateTime.now().millisecondsSinceEpoch;
    const windowMs = 30000;
    const maxToggles = 3;
    final tracker =
        _reactionToggleTracker.putIfAbsent(key, _ReactionRateTracker.new);
    if (now < tracker.cooldownUntil) return false;
    tracker.timestamps.removeWhere((ts) => now - ts >= windowMs);
    if (tracker.timestamps.length >= maxToggles) {
      tracker.cooldownUntil = now + 60000; // 60s cooldown on breach
      return false;
    }
    tracker.timestamps.add(now);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Polls (kind 30078 nym-poll / nym-poll-vote) — channel-only.
  // ---------------------------------------------------------------------------

  /// Creates a poll in the current geohash channel (`publishPoll`). Returns the
  /// created [Poll], or null when not in a channel view or unable to sign.
  Future<Poll?> publishPoll(String question, List<String> options) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return null;
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return null;
    final geohash = state.view.id;

    final id8 = PollLogic.generatePollId8();
    final rumor = PollLogic.buildPollEvent(
      pubkey: identity.pubkey,
      nym: identity.nym,
      geohash: geohash,
      question: question,
      options: options,
      pollId8: id8,
    );
    final signed = await service.publishPollEvent(rumor);
    if (signed == null) return null;

    final poll = Poll(
      id: signed.id,
      question: question,
      options: [
        for (var i = 0; i < options.length; i++)
          PollOption(index: i, text: options[i]),
      ],
      pubkey: identity.pubkey,
      nym: identity.nym,
      geohash: geohash,
      createdAt: signed.createdAt,
    );
    _ref.read(appStateProvider.notifier).upsertPoll(poll);
    return poll;
  }

  /// Casts the local user's vote on [pollId] for [optionIndex] (`votePoll`).
  /// One vote per pubkey — no-op if already voted. Returns true if sent.
  Future<bool> votePoll(String pollId, int optionIndex) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final poll = _ref.read(appStateProvider).polls[pollId];
    if (poll == null) return false;
    if (poll.votes.containsKey(identity.pubkey)) return false;

    final rumor = PollLogic.buildVoteEvent(
      pubkey: identity.pubkey,
      nym: identity.nym,
      geohash: poll.geohash,
      pollId: pollId,
      optionIndex: optionIndex,
    );
    final signed = await service.publishPollEvent(rumor);
    if (signed == null) return false;
    appState.applyLocalVote(pollId, optionIndex);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Profile save (kind 0)
  // ---------------------------------------------------------------------------

  /// Builds, signs, and publishes a kind-0 profile, updating the local
  /// [UserProfile] + identity nym (`saveToNostrProfile`). For a durable login
  /// (or the verified developer) the app-managed fields are MERGED into the
  /// user's existing cached kind-0 so fields the app doesn't manage (nip05,
  /// website, lud06, …) survive the save (`ownsRealProfile` branch,
  /// nostr-core.js:76-121); an ephemeral identity publishes the minimal
  /// app-built profile. Returns true on publish.
  Future<bool> saveProfile({
    String? name,
    String? about,
    String? picture,
    String? banner,
    String? lud16,
  }) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return false;

    final ownsRealProfile =
        identity.loginMethod != null || isVerifiedDeveloper(identity.pubkey);
    final Map<String, dynamic> profile;
    if (ownsRealProfile) {
      // Merge changes into the existing profile; only overwrite the fields
      // the app manages (a null param leaves the field untouched, an
      // explicit empty string clears it — the PWA's delete branches).
      profile = Map<String, dynamic>.of(_cachedKind0Profile ?? const {});
      if (name != null && name.isNotEmpty) {
        profile['name'] = name;
        profile['display_name'] = name;
      }
      if (about != null) profile['about'] = about;
      if (picture != null) {
        picture.isNotEmpty
            ? profile['picture'] = picture
            : profile.remove('picture');
      }
      if (banner != null) {
        banner.isNotEmpty
            ? profile['banner'] = banner
            : profile.remove('banner');
      }
      if (lud16 != null) {
        lud16.isNotEmpty ? profile['lud16'] = lud16 : profile.remove('lud16');
      }
      // Subsequent saves merge against the latest state (nostr-core.js:120).
      _cachedKind0Profile = Map<String, dynamic>.of(profile);
    } else {
      // Ephemeral mode — minimal profile from the passed fields only.
      profile = <String, dynamic>{};
      if (name != null && name.isNotEmpty) {
        profile['name'] = name;
        profile['display_name'] = name;
      }
      if (about != null) profile['about'] = about;
      if (picture != null && picture.isNotEmpty) profile['picture'] = picture;
      if (banner != null && banner.isNotEmpty) profile['banner'] = banner;
      if (lud16 != null && lud16.isNotEmpty) profile['lud16'] = lud16;
    }

    final signed = await service.publishProfile(jsonEncode(profile));
    if (signed == null) return false;
    // Keep the kind-0 cache + its ts in step with what was just published so
    // the relay echo's stale-skip and later merges stay coherent.
    _adoptSelfKind0(signed);

    // Update local identity nym + user profile.
    if (name != null && name.isNotEmpty) {
      identity.nym = getNymFromPubkey(name, identity.pubkey);
      // Persist the user-chosen nick — every rename path funnels through here
      // (the PWA's cmdNick/changeNick write both keys, commands.js:633-639 /
      // app.js:2697-2703): `nym_custom_nick` marks the nick as user-chosen
      // (it qualifies the identity for the D1 profile mirror), and the
      // auto-ephemeral nick keeps an ephemeral session's relaunch
      // (`bootEphemeral` seeds `Identity.nym` from it) on the NEW name.
      final kv = _ref.read(keyValueStoreProvider);
      kv.setString(StorageKeys.customNick, name);
      if (identity.loginMethod == null) {
        kv.setString(StorageKeys.autoEphemeralNick, name);
      }
    }
    final appState = _ref.read(appStateProvider.notifier);
    appState.setIdentity(identity.pubkey, identity.nym);
    appState.ingestEvent(signed); // routes kind-0 → _ingestProfile
    // Refresh the durable login's instant-restore profile cache with the new
    // name/avatar (PWA `updateSidebarFromProfile` re-caches after every self
    // kind-0, app.js:5519-5528) so a relaunch shows the new nick immediately.
    _syncSelfNymFromProfile();

    // Mirror the signed kind-0 to D1 (`profile-set`) in addition to the relay
    // publish, so other clients get a fast public read (`_saveProfileToD1`,
    // nostr-core.js:194). Records the mirrored event id so the relay echo of
    // this same profile (which re-enters via the self kind-0 ingest path) is a
    // no-op instead of a duplicate POST.
    _mirrorOwnProfileToD1(signed);
    return true;
  }

  /// Resolves unknown [pubkeys] D1-first: batch-reads kind-0 events from D1 via
  /// `profile-get` (faster), routes each through the kind-0 ingest path (the
  /// `kind0Ts` dedup keeps live relay updates authoritative), then falls back to
  /// a relay kind-0 sub for the ones D1 didn't have. Mirrors the PWA's
  /// `_flushProfileBatch` (nostr-core.js:1784). Best-effort.
  Future<void> resolveProfiles(List<String> pubkeys) async {
    if (pubkeys.isEmpty) return;
    final service = _service;
    final appState = _ref.read(appStateProvider.notifier);
    final sync = _storageSync;
    var missing = pubkeys;
    if (sync != null) {
      try {
        final found = await sync.profileGet(pubkeys);
        assert(() {
          final withPics = found.values
              .where((ev) => ev.isNotEmpty && (ev['content']?.toString() ?? '')
                  .contains('"picture"'))
              .length;
          debugPrint('[avatar-pop] resolve req=${pubkeys.length} '
              'd1Found=${found.length} d1WithPicture=$withPics');
          return true;
        }());
        if (found.isNotEmpty) {
          // One emit for the whole D1 profile batch (up to 100 rows) instead of
          // one Riverpod rebuild per profile.
          appState.runBatched(() {
            for (final entry in found.entries) {
              final ev = entry.value;
              if (ev.isEmpty) continue; // cache hit, no event payload
              try {
                appState.ingestEvent(NostrEvent.fromJson(ev));
              } catch (_) {}
            }
          });
          // Relay-fallback for anyone D1 didn't supply an AVATAR for — not just
          // D1 misses. A D1 row that exists but carries no `picture` (e.g. a
          // kind-0 that predates the user's avatar, set in another client), or a
          // pictureless TTL cache-hit (reported as an empty entry), would
          // otherwise be treated as "resolved" and stay stuck on the identicon.
          // Re-read the store AFTER the batched ingest so just-applied pictures
          // count.
          final users = _ref.read(appStateProvider).users;
          missing = pubkeys.where((pk) {
            final low = pk.toLowerCase();
            if (!found.containsKey(low)) return true; // D1 miss
            final pic = (users[low] ?? users[pk])?.profile?.picture;
            return pic == null || pic.isEmpty; // D1/cache had no avatar
          }).toList();
        }
      } catch (_) {
        // Fall through to relays.
      }
    }
    if (missing.isEmpty) return;
    service?.fetchProfiles(missing);
  }

  // ---------------------------------------------------------------------------
  // Channel management (docs/specs/03 §1.3–§1.6) — persists to KV list sets.
  // ---------------------------------------------------------------------------

  /// Switches to [channel] (adds it if unknown), persists the joined-channel
  /// list, and subscribes the active channel's typing sub (`switchChannel`).
  void switchChannel(String channel, {String geohash = ''}) {
    final appState = _ref.read(appStateProvider.notifier);
    appState.switchChannel(channel, geohash: geohash);
    _persistJoinedChannels();
    _subscribeActiveChannelTyping();
    // Connect the closest geo relays for a geohash channel so its messages are
    // delivered to nearby relays (PWA `connectToGeoRelays` on channel entry).
    final gh = geohash.isNotEmpty ? geohash : channel;
    if (isChannelGeohash(gh)) {
      unawaited(_service?.connectGeoRelaysForGeohash(gh) ?? Future.value());
    }
  }

  /// Adds [channel] to the registry + persists (`addChannel`).
  ChannelEntry addChannel(String channel, {String geohash = ''}) {
    final entry =
        _ref.read(appStateProvider.notifier).addChannel(channel, geohash: geohash);
    _persistJoinedChannels();
    return entry;
  }

  /// Column-open side effects WITHOUT switching the active view — the PWA's
  /// `_cvSubscribeChannel` (columns.js:520-540), fired for every channel column
  /// seeded/added/repurposed by the columns deck:
  ///   * register + persist the channel (`addChannel` + `userJoinedChannels`),
  ///   * restore its D1 history (`channelRestoreFromD1` →
  ///     [_backfillChannelArchive]),
  ///   * connect the geohash's geo relays (`connectToGeoRelays`) — the native
  ///     relay pool owns reconnection, so the PWA's `startGeoRelayKeepAlive` /
  ///     `ensureDefaultRelaysConnected` have no separate counterpart here, and
  ///     channel messages arrive on the always-on shared channel subscription
  ///     (`loadChannelFromRelays`'s job in the PWA),
  ///   * (re)subscribe the typing/receipt feed when this column IS the active
  ///     conversation ([NostrService.subscribeChannelTyping] is single-sub —
  ///     latest-wins — so a background column must not steal the focused
  ///     column's feed).
  void subscribeChannelColumn(String channel, {String geohash = ''}) {
    addChannel(channel, geohash: geohash);
    final key = geohash.isNotEmpty ? geohash : channel;
    // D1 archive restore (throttled/idempotent inside; no-op pre-boot).
    unawaited(_backfillChannelArchive(key));
    if (isChannelGeohash(key)) {
      unawaited(_service?.connectGeoRelaysForGeohash(key) ?? Future.value());
    }
    final view = _ref.read(appStateProvider).view;
    if (view.kind == ViewKind.channel &&
        view.id.toLowerCase() == key.toLowerCase()) {
      _subscribeActiveChannelTyping();
    }
  }

  /// Removes [key] (not `#nymchat`) and persists (`removeChannel`).
  bool removeChannel(String key) {
    final ok = _ref.read(appStateProvider.notifier).removeChannel(key);
    if (ok) _persistJoinedChannels();
    return ok;
  }

  /// Toggles pinned (favorite) and persists `nym_pinned_channels` (`togglePin`).
  bool togglePin(String key) {
    final pinned = _ref.read(appStateProvider.notifier).togglePin(key);
    _persistSet(StorageKeys.pinnedChannels,
        _ref.read(appStateProvider).pinnedChannels);
    return pinned;
  }

  /// Hides [key] from the sidebar and persists `nym_hidden_channels`.
  bool hideChannel(String key) {
    final ok = _ref.read(appStateProvider.notifier).hideChannel(key);
    _persistSet(StorageKeys.hiddenChannels,
        _ref.read(appStateProvider).hiddenChannels);
    return ok;
  }

  /// Un-hides [key] and persists `nym_hidden_channels` (the mirror of
  /// [hideChannel] — `toggleHideChannel`'s remove branch + `saveHiddenChannels`,
  /// channels.js). Callers should use this instead of the bare
  /// [AppStateNotifier.unhideChannel] so the un-hide survives a relaunch.
  void unhideChannel(String key) {
    _ref.read(appStateProvider.notifier).unhideChannel(key);
    _persistSet(StorageKeys.hiddenChannels,
        _ref.read(appStateProvider).hiddenChannels);
  }

  /// Blocks [key] (not `#nymchat`) and persists `nym_blocked_channels`.
  bool blockChannel(String key) {
    final ok = _ref.read(appStateProvider.notifier).blockChannel(key);
    if (ok) {
      _persistSet(StorageKeys.blockedChannels,
          _ref.read(appStateProvider).blockedChannels);
      _persistJoinedChannels();
    }
    return ok;
  }

  void _persistJoinedChannels() {
    final kv = _ref.read(keyValueStoreProvider);
    final channels = _ref.read(appStateProvider).channels;
    final keys = channels.map((c) => c.key).toList();
    kv.setString(StorageKeys.userJoinedChannels, jsonEncode(keys));
    final snapshot = channels.map((c) => c.toJson()).toList();
    kv.setString(StorageKeys.userChannels, jsonEncode(snapshot));
  }

  void _persistSet(String key, Set<String> values) {
    _ref.read(keyValueStoreProvider).setString(key, jsonEncode(values.toList()));
  }

  /// The PWA's `nym_left_groups` localStorage key (`_saveLeftGroups`). No typed
  /// [StorageKeys] constant exists (the native group store doesn't yet hydrate
  /// from it — see [_applySyncedSettings]); kept as a literal so the outbound
  /// settings sync (storage_sync.dart reads `'nym_left_groups'`) round-trips.
  static const String _kLeftGroupsKey = 'nym_left_groups';

  /// Applies a synced `channelLastRead` map (app.js:6565-6577): monotonic max per
  /// key via [AppStateNotifier.markChannelRead], which keeps the newer watermark
  /// and persists through `onChannelReadChanged`. No-op for a null/non-map value.
  void _applyChannelLastRead(dynamic raw) {
    if (raw is! Map) return;
    final appState = _ref.read(appStateProvider.notifier);
    raw.forEach((k, v) {
      final ts = v is num ? v.toInt() : int.tryParse('$v');
      if (ts != null && ts > 0) {
        try {
          appState.markChannelRead('$k', ts);
        } catch (_) {}
      }
    });
  }

  /// Merges a synced favorite-GIF list into the local `nym_favorite_gifs` store,
  /// deduped by url, local entries first, capped at 100 (app.js:6454-6468). Each
  /// remote entry must be a `{url, title}` object with a string url.
  void _mergeFavoriteGifs(KeyValueStore kv, List<dynamic> remote) {
    try {
      final out = <Map<String, dynamic>>[];
      final seen = <String>{};
      void add(dynamic g) {
        if (g is! Map || g['url'] is! String) return;
        final url = g['url'] as String;
        if (url.isEmpty || !seen.add(url)) return;
        out.add({'url': url, 'title': g['title'] is String ? g['title'] : ''});
      }

      final localRaw = kv.getString(StorageKeys.favoriteGifs);
      if (localRaw != null && localRaw.isNotEmpty) {
        final decoded = jsonDecode(localRaw);
        if (decoded is List) {
          for (final g in decoded) {
            add(g);
          }
        }
      }
      for (final g in remote) {
        add(g);
      }
      final capped = out.length > 100 ? out.sublist(0, 100) : out;
      kv.setString(StorageKeys.favoriteGifs, jsonEncode(capped));
    } catch (_) {}
  }

  /// Merges a synced recent-emoji MRU list into `nym_recent_emojis`, most-recent
  /// first (remote before local), deduped, capped at 24 (app.js:6480-6491).
  void _mergeRecentEmojis(KeyValueStore kv, List<dynamic> remote) {
    try {
      final out = <String>[];
      final seen = <String>{};
      for (final e in remote) {
        if (e is String && e.isNotEmpty && seen.add(e)) out.add(e);
      }
      final localRaw = kv.getString(StorageKeys.recentEmojis);
      if (localRaw != null && localRaw.isNotEmpty) {
        final decoded = jsonDecode(localRaw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is String && e.isNotEmpty && seen.add(e)) out.add(e);
          }
        }
      }
      final capped = out.length > 24 ? out.sublist(0, 24) : out;
      kv.setString(StorageKeys.recentEmojis, jsonEncode(capped));
    } catch (_) {}
  }

  /// Reads a persisted JSON string-array set (`['a','b']`) from KV; empty if
  /// missing/malformed.
  Set<String> _readSet(String key) {
    final raw = _ref.read(keyValueStoreProvider).getString(key);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toSet();
      }
    } catch (_) {}
    return <String>{};
  }

  /// Hydrates friends / blocked users / blocked keywords from KV (boot). Mirrors
  /// the PWA constructor parsing `nym_friends` / `nym_blocked` /
  /// `nym_blocked_keywords` JSON arrays into Sets.
  void _hydrateSocialState(AppStateNotifier appState) {
    appState.hydrateSocialState(
      friends: _readSet(StorageKeys.friends),
      blockedUsers: _readSet(StorageKeys.blocked),
      blockedKeywords: _readSet(StorageKeys.blockedKeywords),
    );
  }

  /// Persists the closed-PM set + close-times to KV (F02). Closed peers go to
  /// `nym_closed_pms` as a JSON string array (reusing [_persistSet]); the
  /// peer→close-time map goes to `nym_closed_pm_times` as a JSON object — so a
  /// deleted conversation isn't re-opened by stale D1 backlog after a relaunch.
  void _persistClosedPMs() {
    final appState = _ref.read(appStateProvider.notifier);
    _persistSet(StorageKeys.closedPms, appState.closedPMs);
    _ref
        .read(keyValueStoreProvider)
        .setString(StorageKeys.closedPmTimes, jsonEncode(appState.closedPmTimes));
  }

  /// Hydrates the closed-PM set + close-times from KV at boot (F02), mirroring
  /// the PWA constructor parsing `nym_closed_pms` / `nym_closed_pm_times`.
  void _hydrateClosedPMs(AppStateNotifier appState) {
    final closed = _readSet(StorageKeys.closedPms);
    final times = <String, int>{};
    final raw = _ref.read(keyValueStoreProvider).getString(StorageKeys.closedPmTimes);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final t = v is num ? v.toInt() : int.tryParse('$v');
            if (t != null) times['$k'] = t;
          });
        }
      } catch (_) {}
    }
    appState.hydrateClosedPMs(closed, times);
  }

  /// Reads the KV left-group set + leave times and merges them into the live
  /// group store (boot + post-sync). Mirrors the PWA `_loadLeftGroups`.
  void _hydrateLeftGroups(AppStateNotifier appState) {
    final ids = _readSet(_kLeftGroupsKey);
    final times = <String, int>{};
    final raw =
        _ref.read(keyValueStoreProvider).getString(StorageKeys.leftGroupTimes);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final t = v is num ? v.toInt() : int.tryParse('$v');
            if (t != null) times['$k'] = t;
          });
        }
      } catch (_) {}
    }
    if (ids.isNotEmpty || times.isNotEmpty) appState.mergeLeftGroups(ids, times);
  }

  /// Persists the live left-group state to KV — the PWA's `_saveLeftGroups()`
  /// + `nym_left_group_times` write on every leave/kick (groups.js:1813-1817).
  /// Without it a group left HERE never reaches the outbound settings payload
  /// (storage_sync.dart reads these keys) and the boot resurrection guard
  /// ([_hydrateLeftGroups]) is lost across a relaunch.
  void _persistLeftGroups() {
    final appState = _ref.read(appStateProvider.notifier);
    _persistSet(_kLeftGroupsKey, appState.leftGroups);
    _ref.read(keyValueStoreProvider).setString(
        StorageKeys.leftGroupTimes, jsonEncode(appState.leftGroupTimes));
  }

  /// Persists the group store + per-group ephemeral keys to KV — the PWA's
  /// `_saveGroupConversations()` (`nym_groups_<pubkey>`, groups.js:317-355)
  /// and `_saveEphemeralKeys()` (`nym_ephemeral_keys_<pubkey>`,
  /// groups.js:281-289), run on every group mutation. The LOCAL blob (unlike
  /// the D1 `nymchat-groups` sync payload) carries the device-local extras:
  /// memberProfiles snapshots, allowMemberInvites, lastModTs/lastModEventId.
  /// [_hydrateGroupStore] restores both synchronously at boot BEFORE any
  /// network I/O, so groups + decryption keys survive an offline launch — the
  /// D1 settings row stays the cross-device layer on top.
  void _persistGroupStore() {
    final identity = _identity;
    if (identity == null) return;
    final kv = _ref.read(keyValueStoreProvider);
    try {
      final st = _ref.read(appStateProvider);
      final data = <String, dynamic>{};
      for (final g in st.groups) {
        data[g.id] = _serializeGroupForLocal(g, st);
      }
      kv.setString('nym_groups_${identity.pubkey}', jsonEncode(data));
    } catch (_) {}
    try {
      final groups = _groups;
      if (groups != null) {
        kv.setString('nym_ephemeral_keys_${identity.pubkey}',
            jsonEncode(groups.ephemeralKeysForSync()));
      }
    } catch (_) {}
  }

  /// Restores the persisted group store + ephemeral keys at boot (the PWA's
  /// `_loadGroupConversations`, groups.js:556-600, and `_loadEphemeralKeys`,
  /// groups.js:291-311). Runs through the same additive apply the D1 restore
  /// uses, so left groups stay dropped and later sync merges dedup cleanly.
  void _hydrateGroupStore() {
    final identity = _identity;
    if (identity == null) return;
    final kv = _ref.read(keyValueStoreProvider);
    final appState = _ref.read(appStateProvider.notifier);
    try {
      final raw = kv.getString('nym_groups_${identity.pubkey}');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((gid, data) {
            if (data is Map) {
              try {
                appState.applyGroupConversationSync(
                    '$gid', data.cast<String, dynamic>());
              } catch (_) {
                // Skip a malformed group entry.
              }
            }
          });
        }
      }
    } catch (_) {}
    try {
      final groups = _groups;
      final raw = kv.getString('nym_ephemeral_keys_${identity.pubkey}');
      if (groups != null && raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((gid, entry) {
            if (entry is Map) {
              try {
                groups.mergeEphemeralKeys('$gid', entry.cast<String, dynamic>());
              } catch (_) {
                // Skip a malformed key entry.
              }
            }
          });
          _service?.setEphemeralKeys(groups.allEphemeralSecretKeys());
        }
      }
    } catch (_) {}
  }

  /// Post-rotation bookkeeping shared by every group send path: persist the
  /// new key locally (`_saveEphemeralKeys`, groups.js:1754), re-REQ the live
  /// ephemeral gift-wrap subscription so replies wrapped to the NEW key arrive
  /// (`_refreshEphemeralSubscriptions`, groups.js:1758), and schedule the
  /// debounced cross-device key sync (groups.js:1298).
  void _afterSelfKeyRotation() {
    _persistGroupStore();
    _refreshEphemeralSubscriptions();
    syncSettings();
  }

  /// Persists the per-conversation read watermark (`nym_channel_last_read`) as a
  /// JSON object so a relaunch's D1 backfill doesn't re-count already-read
  /// history as unread (PWA `channelLastRead`, channels.js:1709-1735).
  void _persistChannelLastRead() {
    _ref.read(keyValueStoreProvider).setString(
          StorageKeys.channelLastRead,
          jsonEncode(_ref.read(appStateProvider.notifier).channelLastRead),
        );
  }

  /// Debounced local persist of the group store (`onGroupStoreChanged` fires on
  /// every group mutation, including each inbound message). Coalesces a burst of
  /// group traffic into one prefs write. The cross-device publish stays on its
  /// own 5s-debounced `syncSettings`.
  void _scheduleGroupStorePersist() {
    _groupStorePersistTimer?.cancel();
    _groupStorePersistTimer = Timer(const Duration(seconds: 2), () {
      _groupStorePersistTimer = null;
      _persistGroupStore();
      _persistLeftGroups();
    });
  }

  /// Debounced local persist of the read watermark (`onChannelReadChanged` fires
  /// on nearly every ingested message in columns mode). Coalesces the churn into
  /// one prefs write.
  void _scheduleChannelLastReadPersist() {
    _channelLastReadPersistTimer?.cancel();
    _channelLastReadPersistTimer = Timer(const Duration(seconds: 2), () {
      _channelLastReadPersistTimer = null;
      _persistChannelLastRead();
    });
  }

  /// Flushes any pending debounced local-prefs writes immediately. Called from
  /// teardown so a sign-out / identity switch never drops the most recent group
  /// or read-state mutation.
  void _flushDebouncedPersists() {
    if (_groupStorePersistTimer != null) {
      _groupStorePersistTimer!.cancel();
      _groupStorePersistTimer = null;
      _persistGroupStore();
      _persistLeftGroups();
    }
    if (_channelLastReadPersistTimer != null) {
      _channelLastReadPersistTimer!.cancel();
      _channelLastReadPersistTimer = null;
      _persistChannelLastRead();
    }
  }

  /// Restores the read watermark from KV at boot.
  void _hydrateChannelLastRead(AppStateNotifier appState) {
    final raw =
        _ref.read(keyValueStoreProvider).getString(StorageKeys.channelLastRead);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final m = <String, int>{};
      decoded.forEach((k, v) {
        final t = v is num ? v.toInt() : int.tryParse('$v');
        if (t != null) m['$k'] = t;
      });
      appState.hydrateChannelLastRead(m);
    } catch (_) {}
  }

  void _subscribeActiveChannelTyping() {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return;
    final entry =
        state.channels.where((c) => c.key == state.view.id.toLowerCase());
    if (entry.isEmpty) return;
    _service?.subscribeChannelTyping(entry.first.key,
        isGeohash: entry.first.isGeohash);
    // Receipt the messages that piled up here while we were away (PWA
    // `openChannel` → `markVisibleChannelMessagesRead`).
    markVisibleChannelMessagesRead();
  }

  // ---------------------------------------------------------------------------
  // Zaps (nostr side only) — the LNURL HTTP/invoice/pay flow is the UI's job.
  // ---------------------------------------------------------------------------

  /// Builds and signs a NIP-57 kind-9734 zap request, publishing it and
  /// returning the signed event so the UI can pass it to the LNURL callback's
  /// `nostr` param. [originalKind] is the zapped message's kind for message zaps
  /// ('20000'/'23333'/'1059'); null for a profile zap.
  Future<NostrEvent?> buildZapRequest({
    required String recipientPubkey,
    required int amountSats,
    String? messageId,
    String? originalKind,
    String comment = '',
  }) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return null;
    final rumor = ZapLogic.buildZapRequest(
      pubkey: identity.pubkey,
      recipientPubkey: recipientPubkey,
      amountSats: amountSats,
      relays: RelayConfig.defaultRelays,
      messageId: messageId,
      originalKind: originalKind,
      comment: comment,
    );
    return service.publishZapRequest(rumor);
  }

  /// Announces a message zap we just paid so OTHER clients update the badge
  /// (zaps.js `handleZapPaymentSuccess`:1099-1110 → `_publishOwnPrivateZapEvent`
  /// / `_publishOwnMessageZapEvent`). Reads the CURRENT view and routes:
  ///   * PM (1:1) → gift-wrap a kind-9735 rumor to `[self, peer]` (private; never
  ///     leaks the zap to public relays),
  ///   * group → gift-wrap a kind-9735 rumor to `group.members`,
  ///   * channel → publish a real signed kind-9735 to relays (+ geo relays for a
  ///     geohash channel).
  ///
  /// Called from `zap_modal._markPaid` right after the self-record. Deduped end
  /// to end by bolt11: the self-record (verified), this announcement, and any
  /// public-receipt echo share the `'b:'+bolt11.toLowerCase()` dedup key, so a
  /// single payment is counted once. [bolt11] is the paid invoice's `pr`.
  Future<void> announceMessageZap({
    required String messageId,
    required String recipientPubkey,
    required String bolt11,
    String? originalKind,
  }) async {
    if (messageId.isEmpty || recipientPubkey.isEmpty || bolt11.isEmpty) return;
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;
    final view = _ref.read(appStateProvider).view;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    if (view.kind == ViewKind.group) {
      // Group rumor tags (zaps.js:1578): g/e/k('14')/p/bolt11 → group.members.
      final group = _ref.read(appStateProvider.notifier).groupById(view.id);
      if (group == null) return;
      final ek = _groups?.keysFor(group.id);
      final rumor = UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.zapReceipt,
        tags: [
          ['g', group.id],
          ['e', messageId],
          ['k', '${EventKind.dmRumor}'], // '14'
          ['p', recipientPubkey],
          ['bolt11', bolt11],
        ],
        content: '',
      );
      await service.publishGiftWrappedRumor(
        rumor: rumor,
        recipients: group.members,
        encryptTo: ek != null
            ? (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey)
            : null,
      );
      return;
    }

    if (view.kind == ViewKind.pm) {
      // PM rumor tags (zaps.js:1587): e/p/k('1059')/bolt11 → [self, peer].
      final peer = view.id;
      final rumor = UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.zapReceipt,
        tags: [
          ['e', messageId],
          ['p', recipientPubkey],
          ['k', '${EventKind.giftWrap}'], // '1059'
          ['bolt11', bolt11],
        ],
        content: '',
      );
      await service.publishGiftWrappedRumor(
        rumor: rumor,
        recipients: [identity.pubkey, peer],
      );
      return;
    }

    // Channel: publish a real, signed kind-9735 to relays. Only geohash/named
    // channel kinds are publishable (zaps.js `_publishOwnMessageZapEvent` bails
    // on any other kind). Infer the kind from the view when not supplied.
    final isGeo = _ref
        .read(appStateProvider)
        .channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    final kind = originalKind ??
        (isGeo ? '${EventKind.geoChannel}' : '${EventKind.namedChannel}');
    if (kind != '${EventKind.geoChannel}' &&
        kind != '${EventKind.namedChannel}') {
      return;
    }
    final signed = await service.publishMessageZapReceipt(
      messageId: messageId,
      recipientPubkey: recipientPubkey,
      bolt11: bolt11,
      originalKind: kind,
      geohash: isGeo ? view.id : null,
      channel: isGeo ? null : view.id,
    );
    if (signed != null) {
      // Ignore the `#p:[self]` echo of our own published receipt (zaps.js
      // `_ownPublishedZapIds`); the self-record already counted this payment.
      _ownPublishedZapIds.add(signed.id);
      if (_ownPublishedZapIds.length > 500) {
        _ownPublishedZapIds.remove(_ownPublishedZapIds.first);
      }
      // Archive our own published channel receipt to D1 (zaps.js:1562
      // `_archiveZapReceipt(signed, …)`) so other clients' backfill sees it.
      _zapArchive?.archive(signed);
    }
  }

  /// Resolves [pubkey]'s lightning address for a quick-zap (zaps.js
  /// `fetchLightningAddressForUser`/`handleQuickZap`): returns the cached lud16/
  /// lud06 if we already hold their kind-0, else fetches their profile (D1-first
  /// via [resolveProfiles], falling back to a relay kind-0 sub) and awaits the
  /// resolved address up to [timeout], returning null when none is found.
  ///
  /// This fixes the quick-zap button wrongly reporting "cannot receive zaps" for
  /// an author whose kind-0 simply hasn't been ingested yet — the PWA always does
  /// a fresh fetch first before deciding (`handleQuickZap`, zaps.js:1794).
  Future<String?> resolveLightningAddressForZap(
    String pubkey, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    String? cached() =>
        _ref.read(appStateProvider).users[pubkey]?.profile?.lightningAddress;
    final existing = cached();
    if (existing != null && existing.isNotEmpty) return existing;

    // Trigger a D1-first (then relay) kind-0 fetch — the same path message/
    // presence backfill uses — and poll the store for the resolved address.
    unawaited(resolveProfiles([pubkey]));
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final addr = cached();
      if (addr != null && addr.isNotEmpty) return addr;
    }
    return cached();
  }

  // ---------------------------------------------------------------------------
  // Persistence hydration / flush
  // ---------------------------------------------------------------------------

  Future<void> _hydrateFromCache(AppStateNotifier appState) async {
    try {
      final cache = CacheStore();
      await cache.open();
      _cache = cache;
      // PMs hydrate only when caching is enabled; disabled → wipe the store,
      // exactly the PWA's `cachePMsAllowed ? … : this.clearPMCache()`
      // (persistence.js:455-475).
      final cachePms = _ref.read(settingsProvider).cachePMs;
      // Load stores in parallel (mirrors hydrateFromCache's Promise.all).
      final results = await Future.wait([
        cache.loadAllProfiles(),
        cache.loadAllReactions(),
        cache.loadAllChannelMessages(),
        cachePms
            ? cache.loadAllPmMessages()
            : Future.value(<String, List<Message>>{}),
      ]);
      final profiles = results[0] as Map<String, UserProfile>;
      final reactions = results[1] as Map<String, List<dynamic>>;
      final channelMsgs = results[2] as Map<String, List<Message>>;
      final pmMsgs = results[3] as Map<String, List<Message>>;
      if (profiles.isNotEmpty) appState.hydrateProfiles(profiles);
      // Boot message hydration (persistence.js:427-475): every cached channel
      // + PM/group history lands in state BEFORE the D1/relay backfills, so
      // the open view paints instantly and the archive replay dedups against
      // the seeded `_seenIds` instead of double-inserting. One copyWith inside.
      if (channelMsgs.isNotEmpty || pmMsgs.isNotEmpty) {
        appState.hydrateAllMessages({...channelMsgs, ...pmMsgs});
      }
      // Seed the crypto skip-caches from what we just restored as PLAINTEXT, so
      // the D1 archive/live replay after boot doesn't re-verify or re-unwrap
      // history already on disk (the boot/resume CPU hammer). PM & group message
      // ids ARE their gift-wrap ids (`_onGiftWrap` keys the row on `wrapId`), so
      // they seed the unwrap skip; channel event ids seed the signature-verify
      // skip. Both were signature-checked/decrypted when first received.
      if (pmMsgs.isNotEmpty) {
        NostrService.seedProcessedWraps([
          for (final list in pmMsgs.values)
            for (final m in list)
              if (m.id.isNotEmpty) m.id,
        ]);
      }
      if (channelMsgs.isNotEmpty) {
        NostrService.seedVerifiedIds([
          for (final list in channelMsgs.values)
            for (final m in list)
              if (m.id.isNotEmpty) m.id,
        ]);
      }
      if (!cachePms) unawaited(cache.clearPms());
      // Reactions hydrate AFTER messages so their tallies attach to rows that
      // now exist (same effective order as the PWA's single hydration pass).
      if (reactions.isNotEmpty) appState.hydrateReactions(reactions);
      // Web-of-trust graph: restore the persisted nymchatPubkeys / vouches /
      // trusted sets so the spam gate isn't cold on launch (it still grows live
      // from PoW-valid messages + receipts + vouches).
      final trust = await Future.wait([
        cache.loadMetaSet(CacheStore.metaNymchatPubkeys),
        cache.loadMetaSet(CacheStore.metaNymchatVouches),
        cache.loadMetaSet(CacheStore.metaTrustedPubkeys),
        cache.loadMetaSet(CacheStore.metaDeletedEventIds),
      ]);
      appState.hydrateTrustSets(trust[0], trust[1], trust[2]);
      // NIP-09 deleted ids survive a relaunch (the PWA's `persistDedupSets`)
      // so relay backlog / D1 replay can't resurrect a deleted message.
      appState.hydrateDeletedIds(trust[3]);
      appState.onDeletedIdsChanged = _schedulePersistDeletedIds;
    } catch (e) {
      debugPrint('hydrateFromCache failed: $e');
    }
  }

  /// Debounced (5s) persist of the NIP-09 deleted-id set (the PWA's
  /// `persistDedupSets`, called from `_applyVerifiedDeletion` /
  /// `_consumePendingDeletion`). Best-effort.
  Timer? _deletedIdsPersistTimer;
  void _schedulePersistDeletedIds() {
    if (_deletedIdsPersistTimer != null) return;
    if (PanicWipe.inProgress) return;
    _deletedIdsPersistTimer = Timer(const Duration(seconds: 5), () {
      _deletedIdsPersistTimer = null;
      final cache = _cache;
      if (cache == null || !cache.isOpen) return;
      unawaited(cache
          .saveMetaSet(CacheStore.metaDeletedEventIds,
              _ref.read(appStateProvider.notifier).deletedEventIds)
          .catchError((_) {}));
    });
  }

  /// Marks [storageKey] dirty and schedules a debounced flush to the cache.
  void _markDirty(String storageKey) {
    if (_cache == null) return;
    if (storageKey.startsWith('pm-') || storageKey.startsWith('group-')) {
      _dirtyPmKeys.add(storageKey);
    } else {
      _dirtyChannelKeys.add(storageKey);
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    // Never re-arm persistence while a panic wipe is destroying the stores
    // (panic.js sets `_cacheDisabled = true` + clears the persist timers first
    // so nothing re-writes data mid-wipe).
    if (PanicWipe.inProgress) return;
    if (_flushScheduled) return;
    _flushScheduled = true;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 6), () {
      _flushScheduled = false;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    // A flush scheduled before the panic fired must not re-persist the live
    // AppState into the just-shredded cache DB (panic.js `_cacheDisabled`).
    if (PanicWipe.inProgress) return;
    final cache = _cache;
    if (cache == null) return;
    final state = _ref.read(appStateProvider);
    final cachePms = _ref.read(settingsProvider).cachePMs;
    try {
      final channelKeys = _dirtyChannelKeys.toList();
      final pmKeys = _dirtyPmKeys.toList();
      final reactionEntries =
          _ref.read(appStateProvider.notifier).reactionEntriesSnapshot();
      // Commit the whole flush as ONE transaction so a busy channel's hundreds
      // of channel/PM/profile/reaction rows don't queue up as hundreds of
      // separately-locked inserts (which tripped sqflite's 10s lock warning and
      // stalled D1 ingest). Dirty sets are cleared only after the tx succeeds.
      await cache.runInTransaction((txn) async {
        for (final key in channelKeys) {
          final msgs = state.messages[key];
          if (msgs != null) {
            // Never persist an UNRECONCILED optimistic row (`_optim_*`): its id
            // isn't the real event id, so on reload it re-hydrates as a stale
            // placeholder that the merge loop can mis-pair (or that lingers if
            // its real event has aged out of relay/D1 retention), re-injecting a
            // duplicate. Only real, reconciled sends belong in the cache.
            final persistable =
                msgs.where((m) => !m.optimistic && !m.id.startsWith('_optim_'));
            await cache.saveChannelMessages(
                key, _capChannel(persistable.toList()), txn);
          }
        }
        for (final key in pmKeys) {
          final msgs = state.messages[key];
          if (msgs != null) {
            // Transient Nymbot info bubbles never persist (the PWA's
            // `_displayBotInfoMessage`/help/welcome rows are display-only —
            // pms.js persists real messages via `persistPMMessages` but never
            // these synthetic ids). Unreconciled optimistic rows are excluded for
            // the same reason as channels (above).
            final persistable = msgs
                .where((m) =>
                    !m.optimistic &&
                    !m.id.startsWith('_optim_') &&
                    !m.id.startsWith('nymbot-info-') &&
                    !m.id.startsWith('nymbot-help-') &&
                    m.id != 'nymbot-welcome')
                .toList();
            await cache.savePmMessages(key, _capPm(persistable),
                enabled: cachePms, executor: txn);
          }
        }
        for (final entry in state.users.entries) {
          final p = entry.value.profile;
          if (p != null) await cache.saveProfile(entry.key, p, txn);
        }
        for (final e in reactionEntries.entries) {
          await cache.saveReactions(e.key, e.value, txn);
        }
      });
      _dirtyChannelKeys.clear();
      _dirtyPmKeys.clear();
      await cache.enforceLruLimits();
    } catch (e) {
      debugPrint('cache flush failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Cross-device storage sync (`/api/storage`): encrypted settings, D1-first
  // profile mirror, PM gift-wrap archive. Mirrors settings.js / nostr-core.js /
  // pms.js. Every call is lazy + failure-tolerant.
  // ---------------------------------------------------------------------------

  /// Builds the [StorageSync] for the booted identity and wires the NIP-98
  /// (kind-27235) auth builder. Durable identities (loginMethod != null, the
  /// PWA's `isNostrLoggedIn()`) participate in the PM archive; ephemeral skip it.
  void _initStorageSync(Identity identity, EventSigner? signer) {
    // A (re-)boot restarts the settings-hydration gate: outbound saves stay
    // deferred until THIS identity's boot restore attempt settles, so a
    // just-logged-in account can't clobber its D1 rows with default state
    // (`_publishEncryptedSettings` hydration gate, settings.js:393-399).
    _settingsHydrated = false;
    _settingsSavePending = false;
    _settingsGetFailed = true;
    if (signer == null) return;
    final api = _api ??= ApiClient();
    final durable = identity.loginMethod != null;
    final sync = StorageSync(
      api: api,
      signer: signer,
      pubkey: identity.pubkey,
      durableIdentity: durable,
    );
    // Auth builder: sign a kind-27235 event bound to the storage URL + action
    // through the active signer (`Nip98Auth.buildSigned` mirrors the PWA's
    // `_signBotAuth` → `signEvent` dispatch). This signs for BOTH a local key and
    // a NIP-46 remote signer, so durable remote-signer accounts now authenticate
    // their settings/PM sync too. Non-sensitive auth is cached 90s so a remote
    // signer isn't round-tripped per request (the PWA's `_botAuthCache`).
    sync.setAuthBuilder((action) => Nip98Auth.buildSigned(
          action: action,
          url: StorageSync.storageUrl(),
          signer: signer,
        ));

    // Activate the WS-first storage transport (the PWA's persistent `/api`
    // socket). Reads in [StorageSync] now try `wss://<host>/api` FIRST and fall
    // back to HTTP on ANY socket failure (no socket, auth failure, timeout,
    // error frame, disconnect — all routed to null inside [ApiClient._trySocket]).
    // The HTTP path is untouched, so data loading is never lost to the socket.
    //
    // The socket's one-time AUTH handshake signs a kind-27235 `api-ws` event
    // bound to `https://<host>/api/WS` — the PWA's `_signBotAuth('api-ws','WS')`
    // (endpoint 'WS' → `/api/WS`), distinct from the storage `/api/storage`
    // `u`-tag. Signed through the same signer, so a NIP-46 remote signer also
    // authenticates the socket (one remote sign at connect, cached). If signing
    // fails (remote unreachable/declined), the socket opens UNAUTHENTICATED for
    // public reads, exactly like a logged-out PWA.
    api.setApiSocketAuthBuilder(() => Nip98Auth.buildSigned(
          action: 'api-ws',
          url: _apiWsAuthUrl(),
          signer: signer,
        ));
    api.activateApiSocket();
    // ONE multiplexed `/api` socket for the whole app (the PWA's single
    // `_apiSock`, shop.js:12): the bot ledger ops ride the SAME identity-authed
    // socket as the storage sync — `_botMoneyRequest`'s WS leg shares
    // `_ensureApiSocket` (shop.js:158-161) — instead of opening (and
    // AUTH-signing) a second one.
    _ref
        .read(nymbotServiceProvider)
        .setApiSocketRequest(api.botSocketRequest);
    _storageSync = sync;
    // Wire the relay-side NIP-59 `nym-sync` publisher so every synced category
    // (settings sections, notifications, read-state, group conversations/keys/
    // history) is BOTH written to D1 AND pushed live as a gift-wrapped event to
    // our other devices — the PWA's dual sink (`_publishEncryptedSettings` calls
    // `_saveSettingsBlobToD1` AND `_publishWrappedNostrEvent`). Without this the
    // wrap half was dead: D1 held the truth but online devices only saw changes
    // on their next boot/reconnect `settings-get`, never a live push.
    sync.setSyncWrapPublisher((payload, dTag) async {
      await _service?.publishNymSyncWrap(payload: payload, dTag: dTag);
    });
    _zapArchive?.dispose();
    _zapArchive = ZapArchive(sync);

    // N26: republish the notification read-state wrap whenever the seen-keys map
    // grows here (a notification read/dismissed), the native equivalent of the
    // PWA's debounced settings save on `_rememberNotificationSeen`. Routed
    // through the same 5s-debounced `syncSettings` as every other synced change.
    _ref.read(notificationHistoryProvider.notifier).onSeenChanged = syncSettings;

    // The other-users shop-status fetcher (cosmetics for OTHER pubkeys) must
    // never query our own pubkey — our own record loads via shop-get below.
    _ref.read(otherUsersShopProvider.notifier).selfPubkey =
        identity.pubkey.toLowerCase();

    // Broadcast the one-off `['shop-update','1']` presence after our active
    // shop items change (shop.js:428 → `publishShopUpdate`,
    // nostr-core.js:2876-2885) so peers drop their cached record and re-fetch
    // our D1 `shop-status`. PWA status choice: online when enabled, else the
    // payload's mode gate broadcasts `hidden`.
    final shop = _ref.read(shopControllerProvider.notifier);
    shop.onActiveItemsPublished =
        () => unawaited(publishPresence('online', shopUpdate: true));

    // Publish the server's pre-signed gift/transfer `giftEvent` DM to the DM
    // relays so the recipient learns of the item immediately (shop.js:1349/
    // 1748 `sendDMToRelays(['EVENT', data.giftEvent])`).
    shop.giftEventPublisher = (giftEvent) {
      try {
        final ev = NostrEvent.fromJson(giftEvent);
        unawaited(_service?.pool.publishDm(ev) ?? Future<int>.value(0));
      } catch (_) {
        // Malformed gift event — dropped exactly like a PWA relay miss.
      }
    };

    // Surface reconciliation results as system chat lines (shop.js
    // `displaySystemMessage` inside `_reconcileShopEntry`).
    shop.onSystemMessage = _emitSystemMessage;

    // Fire a debounced encrypted-settings publish whenever a synced setting
    // changes (the PWA's `nostrSettingsSave()` peppered through every setter).
    _ref.read(settingsProvider.notifier).onSyncedChange = syncSettings;

    // Backfill conversation history from the D1 archive on open (the PWA's
    // per-open `channelRestoreFromD1` in `switchChannel`, plus the ephemeral
    // group inbox). Best-effort; gated/idempotent inside the handler.
    _ref.read(appStateProvider.notifier).onViewOpened = _onViewOpened;

    // Persist inbound / engine-injected PM+group messages on insert (the PWA's
    // per-insert `persistPMMessages`, pms.js:1307) — covers the Nymbot thread,
    // whose messages arrive via `ingestPMMessage` outside any send path.
    _ref.read(appStateProvider.notifier).onPmMessageIngested = _markDirty;

    // Persist the closed-PM set on every mutation so a deleted PM stays deleted
    // across a relaunch (F02; pms.js `nym_closed_pms` / `nym_closed_pm_times`).
    _ref.read(appStateProvider.notifier).onClosedPmsChanged = _persistClosedPMs;
    // Persist the read watermark locally AND schedule a debounced cross-device
    // read-state publish (`nymchat-readstate`) so a message read here silences
    // its unread badge on our other devices (the PWA's `_syncReadStateToD1`
    // debounce, settings.js:774-775). `syncSettings` is 5s-debounced + gated.
    _ref.read(appStateProvider.notifier).onChannelReadChanged = () {
      _scheduleChannelLastReadPersist();
      syncSettings();
    };
    // Reading a conversation (locally, or via a synced watermark from another
    // device) retro-marks its pending bell entries viewed — the PWA's
    // `_markChannelRead` → `_markConversationNotificationsSeen`
    // (channels.js:1735-1741). Notification routes are the BARE channel name /
    // peer pubkey / group id, so strip the storage-key prefix.
    _ref.read(appStateProvider.notifier).onChannelReadMarked = (key, tsSec) {
      var route = key;
      if (route.startsWith('#')) {
        route = route.substring(1);
      } else if (route.startsWith('pm-')) {
        route = route.substring(3);
      } else if (route.startsWith('group-')) {
        route = route.substring(6);
      }
      try {
        _ref
            .read(notificationHistoryProvider.notifier)
            .markConversationSeen(route, tsSec: tsSec);
      } catch (_) {
        // History store may be unavailable in teardown.
      }
    };

    // Persist + publish the group store whenever it mutates — a group
    // created/joined, a message ingested, a control applied. The PWA pairs
    // `_saveGroupConversations()` (+ `_saveLeftGroups` on a leave/kick) with
    // `_debouncedNostrSettingsSave()` through every `groups.js` mutation.
    // The sync routes through the same 5s-debounced `syncSettings` as every
    // other synced change; `_flushSettingsSync` publishes the group categories
    // alongside the settings sections, and content-hash dedup makes an
    // unchanged group a no-op.
    _ref.read(appStateProvider.notifier).onGroupStoreChanged = () {
      _scheduleGroupStorePersist();
      syncSettings();
    };
  }

  /// The NIP-98 `u`-tag URL the `/api` socket's `api-ws` AUTH event binds to:
  /// `https://<host>/api/WS`. Mirrors the PWA's `_signBotAuth('api-ws', 'WS')`
  /// (endpoint 'WS' → `https://${apiHost}/api/WS`, pms.js:1652). Derived from the
  /// storage URL so it tracks the same fixed host without an extra import.
  static String _apiWsAuthUrl() {
    final u = Uri.parse(StorageSync.storageUrl()); // …/api/storage
    final segs = List<String>.from(u.pathSegments);
    if (segs.isNotEmpty) {
      segs[segs.length - 1] = 'WS';
    } else {
      segs.add('WS');
    }
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      pathSegments: segs,
    ).toString();
  }

  /// Reacts to a conversation being opened ([AppStateNotifier.switchView]) by
  /// fetching its D1 message archive and ingesting it through the same pipeline
  /// live events use. Channels hit `channel-get`; groups pull the ephemeral
  /// inbox. PMs need no per-open fetch — their archive is restored globally at
  /// boot via [_restorePmArchive] (`pmRestoreFromD1`), matching the PWA, which
  /// also restores all 1:1 PMs up front rather than per-conversation. All work
  /// is best-effort and never blocks the (already-committed) view switch.
  void _onViewOpened(ChatView view) {
    // Reading a conversation clears ITS bell-badge entries WITHOUT opening the
    // notifications modal (PWA `_markChannelRead` → `_markConversationNotifications
    // Seen`, channels.js:1738-1739; C02-4). The notification `route` is the bare
    // channel key / peer pubkey / group id — all `view.id` — and the open marks
    // everything up to now seen.
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _ref
        .read(notificationHistoryProvider.notifier)
        .markConversationSeen(view.id, tsSec: nowSec);
    // Geo-relay keep-alive follows the ACTIVE view: run the 30s re-check only
    // while a geohash channel is open, and stop it on any other view (named
    // channel, PM, group, bot). This is the single-authority equivalent of the
    // PWA's split wiring — `startGeoRelayKeepAlive` in switchChannel
    // (channels.js:1303/1305) + `stopGeoRelayKeepAlive` on PM open
    // (pms.js:3826). On resume [onAppResumed] re-runs this, so a geohash channel
    // that was open when the app backgrounded gets its keep-alive restarted.
    if (view.kind == ViewKind.channel && isChannelGeohash(view.id)) {
      _service?.startGeoRelayKeepAlive(view.id);
    } else {
      _service?.stopGeoRelayKeepAlive();
    }
    switch (view.kind) {
      case ViewKind.channel:
        unawaited(_backfillChannelArchive(view.id));
        // Catch up read receipts for messages already loaded in this channel
        // (PWA `openChannel` → `markVisibleChannelMessagesRead`). Newly
        // backfilled messages are receipted as they ingest in `_onEvent`.
        markVisibleChannelMessagesRead();
      case ViewKind.group:
        unawaited(_backfillGroupArchive());
        // Catch up read receipts for the loaded group backlog (PWA
        // `_markVisibleGroupMessagesRead`) so the sender sees our reader avatar.
        markVisibleGroupMessagesRead(view.id);
        // PM-scope zap badges for the rendered group backlog (messages.js:3112
        // gathers the rendered ids → `_backfillZapReceipts`, pm scope).
        _backfillZapReceiptsFor(view.storageKey, scope: 'pm');
      case ViewKind.pm:
        // Send a read receipt to the peer for each of their loaded messages
        // (PWA `openPM` → read-receipt send, pms.js:3015-3019; F02 blocker —
        // `sendReadReceipt` previously had zero callers). Scope-gated + deduped.
        markVisiblePmMessagesRead(view.id);
        // PM-scope zap badges for the rendered conversation (messages.js:3112).
        _backfillZapReceiptsFor(view.storageKey, scope: 'pm');
    }
  }

  /// Backfills archived kind-9735 receipts for every message currently loaded
  /// under [storageKey] — the native `_backfillZapReceipts` (zaps.js:5-27,
  /// called with the rendered ids at messages.js:3112-3120). [scope] is `'pm'`
  /// for PM/group conversations, `'channel'` otherwise. PM entries also push
  /// the shared `nymMessageId` when it differs from the wrap id (the PWA's
  /// `m.isPM && m.nymMessageId` branch). Each returned receipt rides the same
  /// handler live receipts take ([_onPublicZapReceipt] = `handleZapReceipt`).
  void _backfillZapReceiptsFor(String storageKey, {required String scope}) {
    final archive = _zapArchive;
    if (archive == null) return;
    final msgs = _ref.read(appStateProvider).messages[storageKey];
    if (msgs == null || msgs.isEmpty) return;
    final ids = <String>[];
    for (final m in msgs) {
      if (m.id.isNotEmpty) ids.add(m.id);
      final shared = m.nymMessageId;
      if (scope == 'pm' &&
          shared != null &&
          shared.isNotEmpty &&
          shared != m.id) {
        ids.add(shared);
      }
    }
    if (ids.isEmpty) return;
    final appState = _ref.read(appStateProvider.notifier);
    unawaited(archive.backfill(
      ids,
      scope,
      (receipt) => _onPublicZapReceipt(receipt, appState),
    ));
  }

  /// App returned to the foreground. Re-hydrate the open conversation from D1 so
  /// the active channel/group immediately catches up on anything missed while
  /// backgrounded — the native equivalent of the PWA's `visibilitychange →
  /// backfillFromD1OnReconnect`. Live relay feeds resume via the service's own
  /// socket reconnect, so this only needs the per-view archive top-up. Also
  /// re-checks pending shop purchases (the PWA's visibility/connect trigger,
  /// relays.js:490) and clears the focused at-bottom column's unread badge in
  /// columns mode (`_cvMarkVisibleColumnsRead`, relays.js:532/584).
  void onAppResumed() {
    _onViewOpened(_ref.read(appStateProvider).view);
    // Re-pull the FULL D1 backlog on every foreground/resume — the PWA fires
    // `backfillFromD1OnReconnect` on visibilitychange/focus/resume (relays.js:
    // 536/588/622), independent of whether the socket actually dropped, so PMs
    // and messages/activity in every non-focused channel and group that landed
    // while backgrounded are restored even when the relay count never hit 0.
    // 30s-throttled + idempotent inside, so pairing it with the per-view top-up
    // above (which gives the active conversation an immediate refresh) is safe.
    unawaited(_backfillFromD1OnReconnect());
    _ref.read(appStateProvider.notifier).markVisibleColumnsRead();
    unawaited(_reconcileShopPurchases());
  }

  /// App backgrounded / hidden: pause the geo-relay keep-alive so it doesn't
  /// fire reconnect attempts while off-screen (the PWA's `document.hidden`
  /// skip in `startGeoRelayKeepAlive`, relays.js:144). [onAppResumed] re-runs
  /// `_onViewOpened`, which restarts it when a geohash channel is still active.
  void onAppPaused() {
    _service?.stopGeoRelayKeepAlive();
  }

  /// Per-channel in-flight backfill (channels.js `_channelD1FetchedAt`). The
  /// 60s freshness window lives in [StorageSync.channelGet]; this map lets
  /// concurrent triggers for the same channel SHARE the running fetch instead
  /// of being dropped — the previous `Set` guard silently swallowed the
  /// reconnect-edge and view-reopen retries while a hung boot fetch sat in
  /// flight, leaving the channel empty with no second chance. Each future
  /// resolves to whether the fetch produced any events; a waiter whose shared
  /// run came back empty re-runs the fetch itself.
  final Map<String, Future<bool>> _channelBackfillInFlight =
      <String, Future<bool>>{};

  // --- D1 profile backfill (PWA `queueProfileFetch` / `_flushProfileBatch`) ---

  /// Pubkeys queued for a batched D1 `profile-get` because we ingested a
  /// message from them but hold no kind-0 profile yet (PWA `_profileBatchQueue`,
  /// nostr-core.js:1774). Deduped against [_profileBackfillQueued] so a busy
  /// channel can't enqueue the same author repeatedly within a flush window.
  final List<String> _profileBackfillQueue = <String>[];
  final Set<String> _profileBackfillQueued = <String>{};
  Timer? _profileBackfillTimer;

  /// Resolves D1 profiles for a LIST of pubkeys (a reactors / zappers sheet, a
  /// group-member or poll-voter list, a mention set) so each row shows its custom
  /// avatar instead of the identicon — the PWA's `ensureListProfiles`. Each entry
  /// goes through the same debounced, picture-guarded [_maybeBackfillProfiles], so
  /// known avatars are skipped and the rest batch into one `profile-get`.
  void ensureProfiles(Iterable<String> pubkeys) {
    for (final pk in pubkeys) {
      _maybeBackfillProfiles(pk);
    }
  }

  /// Enqueues [pubkey] for a debounced D1 profile fetch when we have no kind-0
  /// profile for it yet. Mirrors the PWA's `queueProfileFetch`
  /// (nostr-core.js:1767): a busy channel/PM/group stream only triggers ONE
  /// batched `profile-get` per ~400ms window rather than a request per message.
  /// No-op without storage sync, for an invalid/self pubkey, or when the user is
  /// already known with a profile. The flush routes each returned kind-0 event
  /// through [resolveProfiles] (same ingest path live relay kind-0 events take).
  void _maybeBackfillProfiles(String? pubkey) {
    if (pubkey == null || pubkey.length != 64) return;
    if (_storageSync == null) return;
    final self = _service?.selfPubkey ?? _identity?.pubkey;
    if (pubkey == self) return;
    // Already have this user's AVATAR → nothing to fetch. Keying on the picture
    // (not profile-existence) mirrors the PWA, which guards on `userAvatars`
    // (nostr-core.js:440/1771): a nym-only kind-0, or a presence that cleared the
    // avatar, leaves a picture-less profile stub that must NOT permanently block
    // the avatar backfill (the old `profile != null` guard did exactly that).
    final pic = _ref.read(appStateProvider).users[pubkey]?.profile?.picture;
    if (pic != null && pic.isNotEmpty) return;
    // Staleness gate (PWA `profileFetchedAt`, 5 min): an AVATAR-LESS user (anon,
    // or a kind-0 with no picture) would otherwise re-queue a fetch on EVERY
    // presence/message/reaction — a steady background churn. Only re-attempt
    // once the previous attempt is ≥5 min old.
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _profileBackfillAttemptedAt[pubkey];
    if (last != null && now - last < 5 * 60 * 1000) return;
    _profileBackfillAttemptedAt[pubkey] = now;
    if (_profileBackfillAttemptedAt.length > 5000) {
      _profileBackfillAttemptedAt.remove(_profileBackfillAttemptedAt.keys.first);
    }
    if (!_profileBackfillQueued.add(pubkey)) return;
    _profileBackfillQueue.add(pubkey);
    _profileBackfillTimer ??= Timer(
      const Duration(milliseconds: 400),
      _flushProfileBackfill,
    );
  }

  /// Per-pubkey last profile-backfill ATTEMPT (ms) — the PWA's `profileFetchedAt`
  /// staleness gate so an avatar-less user isn't re-fetched on every event.
  final Map<String, int> _profileBackfillAttemptedAt = {};

  /// Drains the queued pubkeys and resolves their profiles D1-first
  /// (`resolveProfiles` → `profileGet`, falling back to a relay kind-0 sub for
  /// any D1 didn't have). Mirrors the PWA's `_flushProfileBatch`
  /// (nostr-core.js:1784). Best-effort; failures are swallowed inside
  /// [resolveProfiles].
  void _flushProfileBackfill() {
    _profileBackfillTimer = null;
    if (_profileBackfillQueue.isEmpty) return;
    final batch = List<String>.from(_profileBackfillQueue);
    _profileBackfillQueue.clear();
    _profileBackfillQueued.clear();
    unawaited(resolveProfiles(batch));
  }

  /// Fetches a single channel's D1 archive (`channel-get`) and replays each
  /// archived event through [AppStateNotifier.ingestEvent] — the SAME path the
  /// live relay subscription uses (`_onEvent`), so dedup by id (`_seenIds`),
  /// `created_at`/`ms` ordering, and cosmetics all apply. [channelKey] is the
  /// geohash or named-channel key (the PWA's `geohash || channel`). No-op
  /// without storage sync; failures are swallowed.
  /// [force] (default true — the explicit OPEN/boot-view path) bypasses
  /// `channelGet`'s 60s freshness window; the RECONNECT/boot mass restore
  /// passes false, matching `channelRestoreManyFromD1`'s non-forced skip
  /// (`!force && fetchedAt > now-60000`, channels.js:1127).
  Future<void> _backfillChannelArchive(String channelKey,
      {bool force = true}) async {
    final sync = _storageSync;
    if (sync == null || channelKey.isEmpty) return;
    final name = channelKey.toLowerCase();
    final inFlight = _channelBackfillInFlight[name];
    if (inFlight != null) {
      // A fetch for this channel is already running: await ITS outcome rather
      // than dropping this trigger. If it produced events we're done; if it
      // hung (10s timeout), errored, or came back empty, fall through and run
      // a fresh attempt — unless another waiter already started one (the map
      // was repopulated by the time we resumed).
      final produced = await inFlight;
      if (produced || _channelBackfillInFlight.containsKey(name)) return;
    }
    final run = _runChannelBackfill(name, channelKey, sync, force: force);
    _channelBackfillInFlight[name] = run;
    try {
      await run;
    } finally {
      // Clear only our own entry — a waiter that re-ran may have replaced it.
      if (identical(_channelBackfillInFlight[name], run)) {
        _channelBackfillInFlight.remove(name);
      }
    }
  }

  /// One `channel-get` attempt for [_backfillChannelArchive]: fetch
  /// (time-bounded), replay through the live ingest path, top up zap badges.
  /// Returns whether any archived events were produced, so a sharing waiter
  /// knows an immediate retry is warranted. Never throws.
  Future<bool> _runChannelBackfill(
      String name, String channelKey, StorageSync sync,
      {required bool force}) async {
    try {
      // [force] bypasses channelGet's 60s freshness window on an explicit
      // channel OPEN/boot-view, which the PWA always forces
      // (`channelRestoreFromD1(geohash || channel, { force: true })` in
      // `switchChannel`, channels.js:1264, and the boot landing-channel switch,
      // relays.js:1066). Without `force` a prior probe (or a FAILED earlier
      // attempt — `channelGet` marks `_channelFetchedAt` BEFORE the request and
      // doesn't unmark on error) would suppress the boot/open restore for 60s,
      // leaving #nymchat empty with no retry. The reconnect/boot MASS restore
      // passes force:false so a channel fetched within the last 60s is skipped
      // (`channelRestoreManyFromD1` without force, relays.js:2796 →
      // channels.js:1127). `_channelBackfillInFlight` still de-dups concurrent
      // calls for the same channel.
      //
      // TIME-BOUND the fetch (10s → empty): an orphaned socket request must not
      // pin the in-flight slot until the transport's own 45s timeout — the PWA
      // fails a pending request the moment its socket closes, so the next
      // trigger (reconnect edge / view reopen) retries immediately. The empty
      // result reads as "produced nothing", which is exactly what tells a
      // concurrent waiter to re-run.
      final events = await sync.channelGet([name], force: force).timeout(
            const Duration(seconds: 10),
            onTimeout: () => const <Map<String, dynamic>>[],
          );
      final appState = _ref.read(appStateProvider.notifier);
      // One emit for the whole archive page instead of one Riverpod rebuild (+
      // spam/flood re-run) per archived event — the D1-backfill freeze fix.
      appState.runBatched(() {
        for (final raw in events) {
          try {
            final ev = NostrEvent.fromJson(raw);
            // Backlog restore: mark historical by provenance so an archived event
            // that reads as ≈now isn't flood-dimmed or snap-in animated.
            appState.ingestEvent(ev, historical: true);
            // Observe web-of-trust for restored channel messages exactly like the
            // live path (`_onEvent`) does — WITHOUT this, the spam gate hides
            // backfilled history from not-yet-trusted senders and the channel
            // renders empty. Only channel-message kinds carry the PoW
            // self-attestation the gate keys on.
            if (ev.kind == EventKind.geoChannel ||
                ev.kind == EventKind.namedChannel) {
              _observeMessageTrust(ev);
              // Backfill each restored author's kind-0 (with avatar) from D1.
              // The LIVE path does this via `_maybeBackfillProfiles`
              // (queueProfileFetch, nostr-core.js:1767), but this archive replay
              // ingests straight into app_state and would otherwise leave every
              // HISTORICAL author stuck on the identicon until they post again
              // live — the reason restored-channel avatars never loaded. Self-
              // /picture-/throttle-guarded + debounced inside, so calling it per
              // restored message coalesces into one batched `profile-get`.
              _maybeBackfillProfiles(ev.pubkey);
            }
          } catch (_) {
            // Skip a malformed archived event (mirrors the PWA's per-event catch).
          }
        }
      });
      // Zap-badge backfill for the hydrated history (`_backfillZapReceipts`
      // with the rendered ids, messages.js:3112-3120; channel scope).
      // `channel-get` streams zaps rows only within the channel window — this
      // also recovers receipts on older cached messages.
      _backfillZapReceiptsFor('#$channelKey', scope: 'channel');
      return events.isNotEmpty;
    } catch (_) {
      // Best-effort: live subscription continues regardless.
      return false;
    }
  }

  /// Restores group history from the ephemeral-key D1 inbox on group open
  /// (`_recoverEphemeralHistory`, relays.js:2631). Group messages OTHER members
  /// sent are gift-wrapped to our per-group ephemeral keys, so they live in the
  /// `pm-get?pubkeys=` inbox rather than our own (those addressed-to-us wraps,
  /// incl. our own sent copies, are restored at boot by [_restorePmArchive]).
  /// Each restored wrap is unwrapped + routed through the normal gift-wrap
  /// handler (re-archiving is a no-op via the session dedup). Gated to one
  /// in-flight pass; idempotent via the wrap-id dedup in [StorageSync].
  Future<void> _backfillGroupArchive() async {
    final sync = _storageSync;
    final groups = _groups;
    final service = _service;
    if (sync == null || groups == null || service == null) return;
    if (_groupBackfillInFlight) return;
    _groupBackfillInFlight = true;
    try {
      final ephPks = groups.allEphemeralPubkeys();
      if (ephPks.isEmpty) return;
      final wraps = await sync.pmGetByPubkeys(ephPks);
      for (final w in wraps) {
        _replayArchivedWrap(w);
      }
    } catch (_) {
      // Best-effort.
    } finally {
      _groupBackfillInFlight = false;
    }
  }

  bool _groupBackfillInFlight = false;

  /// Completes once the boot settings restore has applied (or determined it
  /// never will: no durable login, a failed fetch, or the 10s fallback —
  /// app.js:5691-5692). Onboarding (the first-run tutorial, via the boot
  /// gate) awaits this so device-spanning flags like `tutorialSeen` from
  /// another device land BEFORE deciding to show — the PWA's
  /// `startOnboardingWhenHydrated` → `_onSettingsHydrated` deferral
  /// (app.js:5652-5661 / settings.js:262-267).
  Future<void> get settingsHydrated => _settingsHydratedC.future;

  /// Starts COMPLETED so a shell mounted without a controller boot (pure
  /// widget tests, or any pre-init read) never blocks on it; [init] re-arms a
  /// fresh pending gate synchronously before its first await, which always
  /// precedes the shell mount (runApp comes after the init() call in main,
  /// and the post-panic/login setup flows re-init before completing).
  Completer<void> _settingsHydratedC = Completer<void>()..complete();
  Timer? _settingsHydratedFallback;

  /// Boot-time sync: merge cross-device encrypted settings (honoring
  /// `nym_last_settings_sync_ts`), then restore the PM backlog from D1 for
  /// durable identities (gated by `cachePMs`). Both best-effort.
  Future<void> _bootStorageSync() async {
    final sync = _storageSync;
    if (sync == null) {
      // No durable login → no remote settings will ever arrive; onboarding
      // may proceed on the local flags (the PWA's no-sync fallback runs the
      // onboarding callback immediately, app.js:5659-5660).
      _markSettingsHydrated();
      return;
    }
    // Arm the PWA's 10s hydration fallback so a hung/offline settings fetch
    // can't suppress onboarding forever (app.js:5691-5692). It releases ONLY the
    // onboarding gate — a hung load must not open the SAVE gate, or a pending
    // save would clobber the account's unread D1 settings with default state.
    _settingsHydratedFallback ??=
        Timer(const Duration(seconds: 10), _releaseOnboardingGate);
    // `_mergeRemoteSettings` marks hydration in its own `finally`.
    await _mergeRemoteSettings(sync);
    await _restorePmArchive(sync);
    // Profile-zap backfill for ourselves (relays.js:2819-2820:
    // `_backfillZapReceiptsFromD1([this.pubkey], 'profile')`) — profile
    // receipts are keyed on the recipient pubkey, not an event id.
    final selfPk = _identity?.pubkey;
    if (selfPk != null && _zapArchive != null) {
      final appState = _ref.read(appStateProvider.notifier);
      unawaited(_zapArchive!.backfill(
        [selfPk],
        'profile',
        (receipt) => _onPublicZapReceipt(receipt, appState),
      ));
    }
    // Custom-emoji hydration from D1 (`_emojiRestoreFromD1`, emoji.js:198) —
    // packs archived by the relay-pool worker but no longer on relays still
    // appear. Runs alongside the live kind-30030 relay subscription.
    unawaited(_restoreEmojiFromD1(sync));
    // Load the user's own shop record (owned + active cosmetics) from D1 so their
    // purchased flair/style applies on a fresh device (PWA `loadShopFromServer`,
    // shop.js:358). Any signable identity qualifies — the shop layer signs its
    // NIP-98 auth through the [ShopIdentity.signer] (the PWA's generic
    // `signEvent` dispatch, pms.js:1649-1679), so NIP-46 accounts restore their
    // cosmetics too; [privkey] stays as the signer-less fallback.
    final id = _identity;
    final signer = _signer;
    if (id != null && (signer != null || id.privkey != null)) {
      unawaited(_ref.read(shopControllerProvider.notifier).loadFromServer(
          ShopIdentity(
              pubkey: id.pubkey, privkey: id.privkey, signer: signer)));
      // Finalize any shop purchase that settled while the app was closed (the
      // PWA fires `reconcilePendingPurchases` on connect, relays.js:490).
      unawaited(_reconcileShopPurchases());
    }
  }

  // --- Shop NIP-57 receipt fallback (shop.js `_listenForShopReceipt`) --------

  Subscription? _shopReceiptSub;
  Timer? _shopReceiptTimer;
  Completer<Object>? _shopReceiptCompleter;

  /// Fallback payment detection for a shop buy whose invoice has neither a
  /// LUD-21 `verify` nor a `serverVerify` URL (shop.js:1483-1511
  /// `_listenForShopReceipt` + zaps.js:1181-1189): REQ `kinds:[9735]`,
  /// `#p:[bot pubkey]`, `since: now-60`, `limit: 25`, and match the receipt's
  /// `bolt11` tag against the invoice [bolt11] (case-insensitive). Completes
  /// with the matched kind-9735 receipt event JSON when it lands (the PWA's
  /// `currentShopInvoice.receipt = event`, shop.js:1187 — a `needsReceipt`
  /// invoice is confirmed by the worker ONLY from `body.receipt`,
  /// storage.js:381, so the claim must carry it), or `false` on the 180s
  /// timeout (the modal then shows the "Payment not detected yet" status). A
  /// new call replaces any previous wait; [clearShopReceiptWait] cancels it
  /// (modal closed / verify path took over).
  Future<Object> listenForShopReceipt(String bolt11) {
    clearShopReceiptWait();
    final completer = Completer<Object>();
    _shopReceiptCompleter = completer;
    final service = _service;
    if (service == null || bolt11.isEmpty) {
      completer.complete(false);
      _shopReceiptCompleter = null;
      return completer.future;
    }
    final want = bolt11.toLowerCase();
    final sub = service.pool.subscribe([
      NostrFilter(
        kinds: const [EventKind.zapReceipt],
        since: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60,
        limit: 25,
        tags: {
          'p': const [nymbotPubkey],
        },
      ),
    ]);
    _shopReceiptSub = sub;
    sub.events.listen((event) {
      final bolt = event.tagValue('bolt11');
      if (bolt == null || bolt.toLowerCase() != want) return;
      if (_shopReceiptCompleter == completer && !completer.isCompleted) {
        clearShopReceiptWait(result: event.toJson());
      }
    }, onError: (_) {});
    // 180s timeout (shop.js:1499 `setTimeout(…, 180000)`).
    _shopReceiptTimer = Timer(const Duration(seconds: 180), () {
      if (_shopReceiptCompleter == completer && !completer.isCompleted) {
        clearShopReceiptWait(result: false);
      }
    });
    return completer.future;
  }

  /// Cancels the pending shop-receipt wait (shop.js `_clearShopReceiptWait`),
  /// closing the REQ and the timer. [result] resolves an in-flight
  /// [listenForShopReceipt] future — the matched receipt event JSON, or the
  /// default `false` (= not detected / cancelled).
  void clearShopReceiptWait({Object result = false}) {
    _shopReceiptSub?.close();
    _shopReceiptSub = null;
    _shopReceiptTimer?.cancel();
    _shopReceiptTimer = null;
    final completer = _shopReceiptCompleter;
    _shopReceiptCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  /// Re-checks persisted pending shop purchases against `shop-check` and claims
  /// any that settled (shop.js `reconcilePendingPurchases`, triggered on
  /// connect + foreground from relays.js:490). Needs a signable identity for
  /// the claim's NIP-98 auth — a local key OR the active signer (NIP-46
  /// accounts sign through it like the PWA's generic `signEvent` dispatch).
  /// Best-effort.
  Future<void> _reconcileShopPurchases() async {
    final id = _identity;
    final signer = _signer;
    if (id == null || (signer == null && id.privkey == null)) return;
    try {
      await _ref.read(shopControllerProvider.notifier).reconcilePendingPurchases(
            ShopIdentity(
                pubkey: id.pubkey, privkey: id.privkey, signer: signer),
            gifterNym: id.nym,
          );
    } catch (_) {
      // Left for the next foreground (shop.js:1412).
    }
  }

  /// True when the last boot/reconnect `settings-get` failed (or has not run
  /// yet) — [_backfillFromD1OnReconnect] then retries [_mergeRemoteSettings],
  /// because for a fresh device the D1 settings row is the ONLY restore path
  /// for another device's groups/ephemeral keys (no relay REQ fallback here).
  bool _settingsGetFailed = true;

  /// `settings-get` → merge into the local [Settings] (settings.js
  /// `settingsLoadFromD1`). The core sections apply UNCONDITIONALLY — the
  /// PWA's D1 load has no freshness gate (settings.js:831-846): the apply is
  /// idempotent and heals any local KV drift — and the stored sync ts only
  /// ADVANCES monotonically. Marks settings hydration complete afterwards so
  /// deferred outbound saves may flush (see [_markSettingsHydrated]).
  Future<void> _mergeRemoteSettings(StorageSync sync) async {
    try {
      final result = await sync.settingsGet();
      if (result == null) {
        // Load FAILED (offline / flaky /api/storage). Do NOT open the save gate:
        // a pending outbound save would publish this device's local/default
        // settings over the account's real D1 row that we never read — the
        // cross-device clobber. The PWA returns false here and keeps the gate
        // closed; the reconnect retry ([_backfillFromD1OnReconnect]) re-attempts
        // and opens the gate only once a load succeeds. Release just the
        // onboarding gate so the tutorial isn't blocked.
        _settingsGetFailed = true;
        _releaseOnboardingGate();
        return;
      }
      _settingsGetFailed = false;
      // N26 inbound: merge the cross-device notification read-state additively
      // (idempotent) BEFORE the settings ts gate — a notification read on another
      // device clears its badge here even if no settings section changed
      // (app.js:5760/5791/5817: seenNotifications → lastReadTime → history).
      final notif = result.notificationsPayload;
      if (notif != null) {
        _applyNotificationsSync(notif);
      }
      // Cross-device read watermarks ride the non-core `nymchat-readstate`
      // category, which the PWA applies additively regardless of the core-section
      // ts gate (settings.js:815-819). Merge it (monotonic max per conversation)
      // BEFORE the gate so unread badges sync even when no core setting changed.
      final readState = result.readStatePayload;
      if (readState != null) {
        _applyChannelLastRead(readState['channelLastRead']);
      }
      // Per-group cross-device restore (`nymchat-groups` / `nymchat-keys-<gid>` /
      // `nymchat-history-<gid>`) — applied additively BEFORE the core-section ts
      // gate (the PWA runs these non-core categories through
      // `applyNostrSettingsAdditive`, settings.js:812-816) so a fresh device
      // restores group membership, decryption keys, and backlog even when no
      // core setting changed.
      _applyGroupSync(result);
      // Core sections apply UNCONDITIONALLY — `settingsLoadFromD1` runs
      // `applyNostrSettingsAdditive` + `applyNostrSettings` for every core
      // section with NO `<=` skip (settings.js:831-846), so an ordinary boot
      // re-runs the additive merges and repairs local drift from the D1 truth.
      // `_applySyncedSettings` persists the monotonic `encryptAtRestPreferred`
      // hint itself (every apply path, matching the PWA's `applyNostrSettings`).
      if (result.payload.isNotEmpty) {
        _applySyncedSettingsAdditive(result.payload);
        _applySyncedSettings(result.payload);
      }
      final kv = _ref.read(keyValueStoreProvider);
      final lastTs = int.tryParse(
              kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ??
          0;
      // The stored ts is in seconds (PWA); newestTs is ms. Only ever ADVANCE.
      final newestSec = result.newestTs ~/ 1000;
      if (newestSec > lastTs) {
        kv.setString(StorageKeys.lastSettingsSyncTs, '$newestSec');
      }
      // Load SUCCEEDED — the account's existing settings have been read and
      // merged (even an empty result means "nothing saved yet", so there is
      // nothing to clobber). ONLY NOW open the outbound-save gate, matching the
      // PWA's `_markSettingsHydrated` after `settingsLoadFromD1` succeeds.
      _markSettingsHydrated();
    } catch (_) {
      // Best-effort — retried on the next reconnect edge. As with the null
      // result, leave the SAVE gate closed (don't clobber unread remote state);
      // release only the onboarding gate.
      _settingsGetFailed = true;
      _releaseOnboardingGate();
    }
  }

  /// Applies the decoded per-group cross-device categories from a settings-get,
  /// mirroring the group branches of the PWA's `applyNostrSettingsAdditive`
  /// (app.js:5938-6076):
  ///
  ///  1. **conversations** → the group store (membership/roles/metadata), so a
  ///     fresh device sees its groups.
  ///  2. **ephemeral keys** → merged into [GroupManager] and pushed to the
  ///     [NostrService] as unwrap candidates, so group gift-wraps addressed to
  ///     our restored ephemeral pubkeys DECRYPT (the crux of the fresh-device
  ///     restore). When new self pubkeys were added we kick a group-archive
  ///     backfill to recover their history from D1 (`_recoverEphemeralHistory`,
  ///     app.js:6015-6017).
  ///  3. **history** → merged into the message store (deduped by id, capped).
  ///
  /// Applied additively/idempotently regardless of the core-section ts gate;
  /// safe to run on every boot (the D1 write path dedups any republish).
  void _applyGroupSync(SettingsLoadResult result) {
    _applyGroupSyncMaps(
      conversations: result.groupConversations,
      ephemeralKeys: result.groupEphemeralKeys,
      history: result.groupMessageHistory,
    );
  }

  /// Shared apply for the three per-group cross-device maps, used by the boot
  /// settings-get merge ([_applyGroupSync]) AND the live own nym-sync wraps
  /// ([_applySyncedSettingsAdditive]) — the PWA routes both through the same
  /// `applyNostrSettingsAdditive` group branches (app.js:5938-6076).
  void _applyGroupSyncMaps({
    Map<String, dynamic>? conversations,
    Map<String, dynamic>? ephemeralKeys,
    Map<String, List<dynamic>>? history,
  }) {
    final appState = _ref.read(appStateProvider.notifier);

    // 1) Group conversations → membership/metadata.
    var groupsChanged = false;
    if (conversations != null) {
      conversations.forEach((gid, data) {
        if (data is Map) {
          try {
            if (appState.applyGroupConversationSync(
                gid, data.cast<String, dynamic>())) {
              groupsChanged = true;
            }
          } catch (_) {
            // Skip a malformed group entry.
          }
        }
      });
    }

    // 2) Ephemeral keys → decryption. Merge into the manager, re-arm the
    // service's unwrap candidates, and backfill history for any new self keys.
    // Left groups are skipped (defense-in-depth against an old un-cleared
    // `nymchat-keys-<gid>` blob resurrecting keys the leave path deleted —
    // the leave writes an empty tombstone, but a device that missed it can
    // still republish the stale entry).
    final groups = _groups;
    var keysAdded = false;
    if (groups != null && ephemeralKeys != null && ephemeralKeys.isNotEmpty) {
      ephemeralKeys.forEach((gid, entry) {
        if (appState.isLeftGroup(gid)) return;
        if (entry is Map) {
          try {
            if (groups.mergeEphemeralKeys(gid, entry.cast<String, dynamic>())) {
              keysAdded = true;
            }
          } catch (_) {
            // Skip a malformed key entry.
          }
        }
      });
      _service?.setEphemeralKeys(groups.allEphemeralSecretKeys());
    }

    // 3) Group message history → message store.
    if (history != null && history.isNotEmpty) {
      try {
        appState.applyGroupHistorySync(history);
      } catch (_) {
        // Best-effort.
      }
    }

    // Persist the restored groups/keys locally (the PWA's apply ends with
    // `_saveGroupConversations()` / `_saveEphemeralKeys()`, app.js:6039/6014)
    // so a relaunch restores them without the network.
    if (groupsChanged || keysAdded) _persistGroupStore();

    // New self keys: re-REQ the live ephemeral gift-wrap subscription AND
    // recover the D1 backlog those keys unlock — the PWA runs BOTH
    // `_refreshEphemeralSubscriptions()` and `_recoverEphemeralHistory(newPks)`
    // (app.js:6015-6021).
    if (keysAdded) {
      _refreshEphemeralSubscriptions();
      unawaited(_backfillGroupArchive());
    }
  }

  /// The live ephemeral-key gift-wrap REQ (`_refreshEphemeralSubscriptions`,
  /// relays.js:2689-2739): one subscription over `kinds:[1059]`,
  /// `#p: <all self ephemeral pks>`. Without it, group messages OTHER members
  /// wrap to our rotated/restored ephemeral keys never arrive live — the main
  /// gift-wrap filter is `#p:[self]` only. Closed + re-opened whenever the key
  /// set changes (restore, rotation on send, reconnect). Events route through
  /// the SAME unwrap path live wraps use.
  Subscription? _ephemeralSub;

  void _refreshEphemeralSubscriptions() {
    final service = _service;
    final groups = _groups;
    if (service == null || groups == null) return;
    _ephemeralSub?.close();
    _ephemeralSub = null;
    final pks = groups.allEphemeralPubkeys();
    if (pks.isEmpty) return;
    // Filter split per relays.js:2711-2721: in PROXY/D1 mode the REQ is
    // real-time only (`limit: 1` — D1 supplies the group history via
    // `_backfillGroupArchive`, so reconnects don't pull a relay backlog through
    // the expensive unwrap path); only in DIRECT mode (the proxy failed and we
    // fell back to per-relay sockets) does a 7-day `since` + per-key limit
    // recover the backlog from relays.
    //
    // Gate on the SAME live proxy-vs-direct signal the main critical filters use
    // (`_d1Available` == `isProxyMode`, since the API host is always set), NOT on
    // `_storageSync != null`: the latter is a durable-identity flag that is null
    // for the first few boot frames (before `_initStorageSync`) and stays set
    // after an auto-fallback to direct — both of which mis-selected the branch,
    // so proxy-mode boots still backfilled a week of group gift wraps off relays
    // (hundreds of kind-1059 events unwrapped on the main isolate at startup).
    final d1Mode = service.isProxyMode;
    final sub = service.subscribeEphemeral(
      pks,
      limit: d1Mode ? 1 : 200 * pks.length,
      since: d1Mode
          ? null
          : DateTime.now().millisecondsSinceEpoch ~/ 1000 - 604800,
    );
    // Route each wrap through the LIVE gift-wrap handler (the PWA's ephemeral
    // REQ feeds `handleGiftWrapDM` like any other live 1059, with `fromD1`
    // unset). `unwrapLiveWrap` keeps `fromArchive: false` so a group message
    // another member wrapped to our ephemeral key is archived to D1, notified,
    // and shown real-time — NOT `unwrapArchivedWrap`, which would flag it
    // `fromArchive` and skip the D1 upload, losing received group messages on
    // relaunch.
    sub.events.listen(service.unwrapLiveWrap, onError: (_) {});
    _ephemeralSub = sub;
  }

  /// The additive half of the settings apply — the PWA's
  /// `applyNostrSettingsAdditive` (app.js:5750-6076) — shared by the boot
  /// settings-get merge, every live own nym-sync wrap, and the section-offer
  /// accepts. Everything here is idempotent / monotonic (set unions, per-key
  /// max merges, id-deduped history), so re-application is safe.
  void _applySyncedSettingsAdditive(Map<String, dynamic> s) {
    // Cross-device notification read-state (app.js:5760-5894) — a notification
    // read/dismissed on another device clears its badge here, and its bell
    // history merges in.
    _applyNotificationsSync(s);
    // Closed-PM read state: additive set + INDEPENDENT per-key monotonic-max
    // time merge (app.js:6528-6547 — a set entry without a time gets NO time).
    final closedPMs = s['closedPMs'];
    final closedTimes = <String, int>{};
    final rawClosedTimes = s['closedPMTimes'];
    if (rawClosedTimes is Map) {
      rawClosedTimes.forEach((k, v) {
        final t = v is num ? v.toInt() : int.tryParse('$v');
        if (t != null && t > 0) closedTimes['$k'] = t;
      });
    }
    if (closedPMs is List || closedTimes.isNotEmpty) {
      try {
        _ref.read(appStateProvider.notifier).mergeClosedPmSync(
              closedPMs is List
                  ? closedPMs.whereType<String>()
                  : const <String>[],
              closedTimes,
            );
      } catch (_) {}
    }
    // Left-group state (app.js:6549-6561) — KV union + live-store merge.
    _mergeLeftGroupsFromSync(s['leftGroups'], s['leftGroupTimes']);
    // Per-conversation read watermarks (app.js:6565-6577 twin block).
    _applyChannelLastRead(s['channelLastRead']);
    // Per-group categories (app.js:5938-6076).
    Map<String, List<dynamic>>? history;
    final rawHistory = s['groupMessageHistory'];
    if (rawHistory is Map) {
      final h = <String, List<dynamic>>{};
      rawHistory.forEach((k, v) {
        if (v is List) h['$k'] = v;
      });
      history = h;
    }
    final rawConversations = s['groupConversations'];
    final rawKeys = s['groupEphemeralKeys'];
    if (rawConversations is Map || rawKeys is Map || history != null) {
      _applyGroupSyncMaps(
        conversations: rawConversations is Map
            ? rawConversations.map((k, v) => MapEntry('$k', v))
            : null,
        ephemeralKeys:
            rawKeys is Map ? rawKeys.map((k, v) => MapEntry('$k', v)) : null,
        history: history,
      );
    }
  }

  /// Applies the inbound `nymchat-notifications` read-state trio in the PWA's
  /// order (app.js:5760-5894): `seenNotifications` merge, then a NEWER
  /// `notificationLastReadTime` (with its receivedAt-based retro-mark), then
  /// the `notificationHistory` merge (eventId/fuzzy matching, blocked-sender +
  /// answered-missed-call exclusions). All idempotent; inbound applies never
  /// republish. Shared by the boot settings-get merge and the live own
  /// nym-sync wrap apply.
  void _applyNotificationsSync(Map<String, dynamic> s) {
    try {
      final notifier = _ref.read(notificationHistoryProvider.notifier);
      final seen = s['seenNotifications'];
      if (seen is Map) {
        notifier.mergeSeenNotifications(seen);
      }
      final lastRead = s['notificationLastReadTime'];
      if (lastRead is num) {
        notifier.adoptNotificationLastReadTime(lastRead.toInt());
      }
      final history = s['notificationHistory'];
      if (history is List && history.isNotEmpty) {
        notifier.mergeHistory(
          history,
          // The answered status is the tombstone for a synced missed-call
          // entry (app.js:5860-5862, `_callStatus(...) === 'answered'`).
          isCallAnswered: (callId) =>
              _ref.read(callServiceProvider).seenCallStatus(callId) ==
              'answered',
        );
      }
    } catch (_) {
      // History store may be unavailable in teardown.
    }
  }

  /// Merges synced left-group state into KV + the live store (the leftGroups /
  /// leftGroupTimes halves of `applyNostrSettingsAdditive`, app.js:6549-6561):
  /// union the ids, keep the newest leave time per group, then retroactively
  /// drop any now-left group. Shared by the additive apply and the
  /// replace-style [_applySyncedSettings] (whose PWA twin carries the same
  /// blocks, app.js:6549-6561).
  void _mergeLeftGroupsFromSync(dynamic leftGroups, dynamic rawLeftTimes) {
    final appState = _ref.read(appStateProvider.notifier);
    if (leftGroups is List) {
      try {
        final merged = _readSet(_kLeftGroupsKey)
          ..addAll(leftGroups.whereType<String>().where((s) => s.isNotEmpty));
        _persistSet(_kLeftGroupsKey, merged);
      } catch (_) {}
    }
    if (rawLeftTimes is Map) {
      try {
        final merged = <String, int>{};
        final existing = _ref
            .read(keyValueStoreProvider)
            .getString(StorageKeys.leftGroupTimes);
        if (existing != null && existing.isNotEmpty) {
          final decoded = jsonDecode(existing);
          if (decoded is Map) {
            decoded.forEach((k, v) {
              final t = v is num ? v.toInt() : int.tryParse('$v');
              if (t != null) merged['$k'] = t;
            });
          }
        }
        rawLeftTimes.forEach((k, v) {
          final t = v is num ? v.toInt() : int.tryParse('$v');
          if (t == null || t <= 0) return;
          if (t > (merged['$k'] ?? 0)) merged['$k'] = t;
        });
        _ref
            .read(keyValueStoreProvider)
            .setString(StorageKeys.leftGroupTimes, jsonEncode(merged));
      } catch (_) {}
    }
    // Apply the merged left-group state to the LIVE group store (not just KV):
    // union the ids + newest leave times and retroactively drop any now-left
    // group (app.js:6692-6712). Reads back from the KV just written so it
    // covers both branches above.
    if (leftGroups is List || rawLeftTimes is Map) {
      _hydrateLeftGroups(appState);
    }
  }

  /// Applies a decoded synced-settings payload (PWA field names) into the
  /// [SettingsController] via its typed setters. Unknown / device-local keys are
  /// ignored. Wrapped so a single bad field can't abort the merge.
  void _applySyncedSettings(Map<String, dynamic> p) {
    final c = _ref.read(settingsProvider.notifier);
    void str(String key, void Function(String) set) {
      final v = p[key];
      if (v is String && v.isNotEmpty) {
        try {
          set(v);
        } catch (_) {}
      }
    }

    void boolean(String key, void Function(bool) set) {
      final v = p[key];
      if (v is bool) {
        try {
          set(v);
        } catch (_) {}
      }
    }

    void integer(String key, void Function(int) set) {
      final v = p[key];
      if (v is num) {
        try {
          set(v.toInt());
        } catch (_) {}
      }
    }

    // Theme + color mode (applyNostrSettings, app.js:6105-6117): `s.theme` →
    // `applyTheme` + `nym_theme`, `s.colorMode` → `nym_color_mode` +
    // `applyColorMode`. Native parses to the typed enums (unknown theme ids
    // fall back to bitchat, matching `Settings.fromStore`).
    final theme = p['theme'];
    if (theme is String && theme.isNotEmpty) {
      try {
        c.setTheme(NymThemeKey.fromId(theme));
      } catch (_) {}
    }
    final cm = p['colorMode'];
    if (cm is String && cm.isNotEmpty) {
      try {
        c.setColorMode(cm == 'light'
            ? ColorMode.light
            : cm == 'dark'
                ? ColorMode.dark
                : ColorMode.auto);
      } catch (_) {}
    }
    str('sound', c.setSound);
    boolean('autoscroll', c.setAutoscroll);
    boolean('showTimestamps', c.setShowTimestamps);
    str('timeFormat', c.setTimeFormat);
    str('dateFormat', c.setDateFormat);
    str('chatLayout', c.setChatLayout);
    str('chatViewMode', c.setChatViewMode);
    boolean('columnsWallpaper', c.setColumnsWallpaper);
    str('nickStyle', c.setNickStyle);
    str('wallpaperType', c.setWallpaperType);
    // Text size only applies within the PWA's accepted range (app.js:6310:
    // `>= 12 && <= 28` — out-of-range values are ignored, not clamped).
    final textSize = p['textSize'];
    if (textSize is num && textSize >= 12 && textSize <= 28) {
      try {
        c.setTextSize(textSize.toInt());
      } catch (_) {}
    }
    boolean('transparencyEnabled', c.setTransparencyEnabled);
    boolean('dmForwardSecrecyEnabled', c.setDmForwardSecrecy);
    integer('dmTTLSeconds', c.setDmTtlSeconds);
    // Indicator scopes are validated against the five valid values, with the
    // legacy `*Enabled` boolean fallback (applyNostrSettings, app.js:6165-6190)
    // — an out-of-enum value must never reach the settings dropdowns.
    void scope(String scopeKey, String enabledKey, void Function(String) set) {
      final v = p[scopeKey];
      if (v is String && Settings.indicatorScopes.contains(v)) {
        try {
          set(v);
        } catch (_) {}
        return;
      }
      final enabled = p[enabledKey];
      if (enabled is bool) {
        try {
          set(enabled ? 'everywhere' : 'disabled');
        } catch (_) {}
      }
    }

    scope('readReceiptsScope', 'readReceiptsEnabled', c.setReadReceiptsScope);
    scope('typingIndicatorsScope', 'typingIndicatorsEnabled',
        c.setTypingIndicatorsScope);
    str('acceptPMs', c.setAcceptPMs);
    str('acceptCalls', c.setAcceptCalls);
    boolean('groupChatPMOnlyMode', c.setGroupChatPMOnlyMode);
    str('translateLanguage', c.setTranslateLanguage);
    // Default landing channel rides the sync as a `{type,geohash}` OBJECT (PWA
    // `pinnedLandingChannel`, settings.js:116), not a string — re-encode it to
    // the JSON the KV store + `setPinnedLandingChannel` expect. SETTINGS-SYNC
    // seam (inbound apply).
    final landing = p['pinnedLandingChannel'];
    if (landing is Map &&
        landing['geohash'] is String &&
        (landing['geohash'] as String).isNotEmpty) {
      try {
        // Legacy payloads still carry the pre-rename default key: migrate
        // `{geohash:'nym'}` → `{type:'geohash',geohash:'nymchat'}` at apply
        // time like the PWA (app.js:6300-6307).
        final migrated = landing['geohash'] == 'nym'
            ? const {'type': 'geohash', 'geohash': 'nymchat'}
            : landing;
        c.setPinnedLandingChannel(jsonEncode(migrated));
      } catch (_) {}
    }
    boolean('gesturesEnabled', c.setGesturesEnabled);
    // Swipe actions/threshold/emoji apply only when valid (applyNostrSettings,
    // app.js:6204-6224: VALID_SWIPE_ACTIONS list, threshold 30-120, emoji 1-8
    // chars) — a legacy/corrupt value must not break the Mobile dropdowns.
    const validSwipeActions = [
      'quote', 'translate', 'copy', 'react', 'zap', 'slap', 'hug', 'none',
    ];
    final swipeLeft = p['swipeLeftAction'];
    if (swipeLeft is String && validSwipeActions.contains(swipeLeft)) {
      try {
        c.setSwipeLeftAction(swipeLeft);
      } catch (_) {}
    }
    final swipeRight = p['swipeRightAction'];
    if (swipeRight is String && validSwipeActions.contains(swipeRight)) {
      try {
        c.setSwipeRightAction(swipeRight);
      } catch (_) {}
    }
    final swipeThreshold = p['swipeThreshold'];
    if (swipeThreshold is num &&
        swipeThreshold >= 30 &&
        swipeThreshold <= 120) {
      try {
        c.setSwipeThreshold(swipeThreshold.toInt());
      } catch (_) {}
    }
    final swipeEmoji = p['swipeReactEmoji'];
    if (swipeEmoji is String &&
        swipeEmoji.isNotEmpty &&
        swipeEmoji.length <= 8) {
      try {
        c.setSwipeReactEmoji(swipeEmoji);
      } catch (_) {}
    }
    boolean('sortByProximity', c.setSortByProximity);
    boolean('lowDataMode', c.setLowDataMode);
    boolean('cachePMs', c.setCachePMs);
    // Favorite custom emoji packs / default emoji categories replace the local
    // lists so an unfavorite on one device propagates (applyNostrSettings,
    // app.js:6447-6476). Stored as the same JSON arrays the pickers'
    // `EmojiFavoritesStore` reads (`nym_emoji_pack_favorites` /
    // `nym_emoji_category_favorites`).
    final kvStore = _ref.read(keyValueStoreProvider);
    final packFavs = p['emojiPackFavorites'];
    if (packFavs is List) {
      try {
        kvStore.setString(StorageKeys.emojiPackFavorites,
            jsonEncode(packFavs.whereType<String>().toList()));
      } catch (_) {}
    }
    final catFavs = p['emojiCategoryFavorites'];
    if (catFavs is List) {
      try {
        kvStore.setString(StorageKeys.emojiCategoryFavorites,
            jsonEncode(catFavs.whereType<String>().toList()));
      } catch (_) {}
    }
    // showStatus arrives as bool|'friends' (settings.js normalization).
    final ss = p['showStatus'];
    if (ss is bool) {
      c.setShowStatus(ss ? 'true' : 'false');
    } else if (ss == 'friends') {
      c.setShowStatus('friends');
    }
    // Seen-call map merged from another device (app.js:6422 `_mergeSeenCalls`):
    // a call answered/declined elsewhere stops re-ringing here, and one that
    // becomes `answered` retracts a missed-call notification we surfaced
    // (`missed-call-<id>` → NotificationHistoryNotifier.removeByEventId).
    // F06-A3 inbound seam.
    final sc = p['seenCalls'];
    if (sc is Map) {
      try {
        _ref.read(callServiceProvider).mergeSeenCalls(
              sc,
              retract: _ref
                  .read(notificationHistoryProvider.notifier)
                  .removeByEventId,
            );
      } catch (_) {}
    }

    // =======================================================================
    // KV-backed synced prefs the PWA writes straight to localStorage in
    // applyNostrSettings but the native apply never restored — the "not all
    // data is fetched" completeness gaps. Each mirrors the PWA field name,
    // shape and merge semantics so every synced key round-trips.
    // =======================================================================
    final appState = _ref.read(appStateProvider.notifier);
    final selfPk = _ref.read(appStateProvider).selfPubkey;

    // Saved column layout (app.js:6256-6259) — the multi-column arrangement.
    final columnsLayout = p['columnsLayout'];
    if (columnsLayout is List) {
      try {
        kvStore.setString(StorageKeys.columnsLayout, jsonEncode(columnsLayout));
      } catch (_) {}
    }
    // Custom wallpaper URL (app.js:6226-6244): paired with `wallpaperType`
    // (applied above) so a synced `custom` wallpaper keeps its background URL
    // instead of arriving blank on the receiving device.
    final wallpaperUrl = p['wallpaperCustomUrl'];
    if (wallpaperUrl is String && wallpaperUrl.isNotEmpty) {
      try {
        kvStore.setString(StorageKeys.wallpaperCustomUrl, wallpaperUrl);
      } catch (_) {}
    }
    // Lightning receive/zap address (app.js:6272-6275): the global cache plus the
    // per-pubkey key `loadImageBlurSettings`'s sibling reads (zaps.js:234). Applied
    // on EVERY settings sync, not only the user-to-user accept path.
    final lightning = p['lightningAddress'];
    if (lightning is String && lightning.isNotEmpty) {
      try {
        kvStore.setString(StorageKeys.lightningAddressGlobal, lightning);
        if (selfPk.isNotEmpty) {
          kvStore.setString(
              StorageKeys.lightningAddressFor(selfPk), lightning);
        }
      } catch (_) {}
    }
    // Proof-of-work difficulty (app.js:6278-6282) — the spam-control setting.
    final pow = p['powDifficulty'];
    if (pow is num) {
      try {
        c.setPowDifficulty(pow.toInt());
      } catch (_) {}
    }
    // Hide non-pinned channels toggle (app.js:6285-6288).
    boolean('hideNonPinned', c.setHideNonPinned);
    // Image-blur privacy preference (app.js:6291-6297): true | false | 'friends'.
    // Writes the global + per-pubkey keys via the PWA-faithful setter.
    final blur = p['blurOthersImages'];
    if (blur is bool || blur == 'friends') {
      try {
        final v = blur == 'friends'
            ? 'friends'
            : (blur == true ? 'true' : 'false');
        c.setBlurImages(v, pubkey: selfPk.isEmpty ? null : selfPk);
      } catch (_) {}
    }
    // Sidebar section order (app.js:6494-6496).
    final sidebar = p['sidebarSectionOrder'];
    if (sidebar is List) {
      try {
        kvStore.setString(StorageKeys.sidebarSectionOrder,
            jsonEncode(sidebar.whereType<String>().toList()));
      } catch (_) {}
    }
    // Favorite translation languages (app.js:6440-6444) — replace the list.
    final translateFavs = p['translateFavoriteLanguages'];
    if (translateFavs is List) {
      try {
        kvStore.setString(StorageKeys.translateFavorites,
            jsonEncode(translateFavs.whereType<String>().toList()));
      } catch (_) {}
    }
    // Notifications master toggle (app.js:6515-6518) — typed Settings state +
    // KV (the notifications panel writes both, notifications_panel.dart:367).
    final notif = p['notificationsEnabled'];
    if (notif is bool) {
      try {
        c.update((s) => s.copyWith(notificationsEnabled: notif));
        kvStore.setString(StorageKeys.notificationsEnabled, '$notif');
      } catch (_) {}
    }
    // Group mentions-only / friends-only notification prefs (app.js:6519-6526):
    // KV-backed booleans read as the string 'true'/'false' (nostr_controller
    // gates on `== 'true'`, :1243/:1239).
    final groupMentions = p['groupNotifyMentionsOnly'];
    if (groupMentions is bool) {
      try {
        kvStore.setString(
            StorageKeys.groupNotifyMentionsOnly, '$groupMentions');
      } catch (_) {}
    }
    final friendsOnly = p['notifyFriendsOnly'];
    if (friendsOnly is bool) {
      try {
        kvStore.setString(StorageKeys.notifyFriendsOnly, '$friendsOnly');
      } catch (_) {}
    }
    // MLS history-sync preference (app.js:6509-6512) — typed Settings + KV.
    final mls = p['syncMLSHistory'];
    if (mls is bool) {
      try {
        c.update((s) => s.copyWith(syncMLSHistory: mls));
        kvStore.setBool(StorageKeys.syncMlsHistory, mls);
      } catch (_) {}
    }
    // Favorite GIFs — merge remote into local, dedupe by url, cap 100
    // (app.js:6454-6468).
    final favGifs = p['favoriteGifs'];
    if (favGifs is List && favGifs.isNotEmpty) {
      _mergeFavoriteGifs(kvStore, favGifs);
    }
    // Recent emojis — merge most-recent-first, dedupe, cap 24 (app.js:6480-6491).
    final recent = p['recentEmojis'];
    if (recent is List && recent.isNotEmpty) {
      _mergeRecentEmojis(kvStore, recent);
    }

    // -----------------------------------------------------------------------
    // Social / moderation lists. The PWA REPLACES friends / blockedUsers /
    // blockedKeywords from the payload (app.js:6392-6430); reconcile the live
    // AppState set via add/remove diffs (so an unfriend/unblock on one device
    // propagates) and persist the KV list the boot hydrator reads.
    // -----------------------------------------------------------------------
    final friends = p['friends'];
    if (friends is List) {
      try {
        final incoming = friends
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toSet();
        final current = {..._ref.read(appStateProvider).friends};
        for (final pk in incoming.difference(current)) {
          appState.addFriend(pk);
        }
        for (final pk in current.difference(incoming)) {
          appState.removeFriend(pk);
        }
        _persistSet(StorageKeys.friends, _ref.read(appStateProvider).friends);
      } catch (_) {}
    }
    final blockedUsers = p['blockedUsers'];
    if (blockedUsers is List) {
      try {
        final incoming = blockedUsers
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toSet();
        final current = {..._ref.read(appStateProvider).blockedUsers};
        for (final pk in incoming.difference(current)) {
          appState.blockUser(pk);
        }
        for (final pk in current.difference(incoming)) {
          appState.unblockUser(pk);
        }
        final blocked = _ref.read(appStateProvider).blockedUsers;
        _persistSet(StorageKeys.blocked, blocked);
        // Keep the bell badge's blocked-sender exclusion in sync (C02-4).
        _ref.read(notificationHistoryProvider.notifier).setBlocked(blocked);
      } catch (_) {}
    }
    final blockedKeywords = p['blockedKeywords'];
    if (blockedKeywords is List) {
      try {
        final incoming = blockedKeywords
            .whereType<String>()
            .map((k) => k.toLowerCase())
            .where((k) => k.isNotEmpty)
            .toSet();
        final current = {..._ref.read(appStateProvider).blockedKeywords};
        for (final kw in incoming.difference(current)) {
          appState.addBlockedKeyword(kw);
        }
        for (final kw in current.difference(incoming)) {
          appState.removeBlockedKeyword(kw);
        }
        _persistSet(StorageKeys.blockedKeywords,
            _ref.read(appStateProvider).blockedKeywords);
      } catch (_) {}
    }

    // -----------------------------------------------------------------------
    // Channel lists (app.js:6350-6389). The PWA REPLACES the pinned/blocked/
    // hidden sets (`nym.pinnedChannels = new Set(s.pinnedChannels)` etc.) so an
    // unpin/unhide/unblock on one device propagates — a union would resurrect
    // stale entries and re-publish them, re-pinning the channel everywhere.
    // Joined channels stay additive (the PWA's userJoinedChannels apply only
    // adds). Persist the KV lists after; migrate the legacy default key
    // 'nym' → 'nymchat' like the PWA (app.js:6364).
    // -----------------------------------------------------------------------
    final pinnedChannels = p['pinnedChannels'];
    final hiddenChannels = p['hiddenChannels'];
    final blockedChannels = p['blockedChannels'];
    Set<String>? pinnedSet;
    Set<String>? hiddenSet;
    Set<String>? blockedSet;
    List<ChannelEntry>? joinedEntries;
    if (pinnedChannels is List) {
      pinnedSet = pinnedChannels
          .whereType<String>()
          .map((k) => k == 'nym' ? 'nymchat' : k.toLowerCase())
          .where((k) => k.isNotEmpty)
          .toSet();
    }
    if (hiddenChannels is List) {
      hiddenSet =
          hiddenChannels.whereType<String>().where((k) => k.isNotEmpty).toSet();
    }
    if (blockedChannels is List) {
      blockedSet = blockedChannels
          .whereType<String>()
          .where((k) => k.isNotEmpty)
          .toSet();
    }
    final userJoined = p['userJoinedChannels'];
    if (userJoined is List) {
      final keys = <String>{
        for (final raw in userJoined.whereType<String>())
          if (raw.isNotEmpty) (raw == 'nym' ? 'nymchat' : raw),
      };
      joinedEntries = [
        for (final k in keys)
          if (k != kDefaultChannel) ChannelEntry(channel: k, geohash: k),
      ];
    }
    if (pinnedSet != null ||
        hiddenSet != null ||
        blockedSet != null ||
        joinedEntries != null) {
      try {
        appState.hydrateChannelState(
          pinned: pinnedSet,
          hidden: hiddenSet,
          blocked: blockedSet,
          joinedChannels: joinedEntries,
          replace: true,
        );
        if (pinnedSet != null) {
          _persistSet(StorageKeys.pinnedChannels,
              _ref.read(appStateProvider).pinnedChannels);
        }
        if (hiddenSet != null) {
          _persistSet(StorageKeys.hiddenChannels,
              _ref.read(appStateProvider).hiddenChannels);
        }
        if (blockedSet != null) {
          _persistSet(StorageKeys.blockedChannels,
              _ref.read(appStateProvider).blockedChannels);
        }
        if (joinedEntries != null) _persistJoinedChannels();
      } catch (_) {}
    }

    // -----------------------------------------------------------------------
    // Closed-PM / left-group read state — the PWA's `applyNostrSettings`
    // carries the SAME additive blocks as `applyNostrSettingsAdditive`
    // (app.js:6535-6561): closedPMs is a pure set union (an entry WITHOUT a
    // time gets NO invented time) and closedPMTimes / leftGroupTimes are
    // independent per-key monotonic-max merges.
    // -----------------------------------------------------------------------
    final closedTimes = <String, int>{};
    final rawClosedTimes = p['closedPMTimes'];
    if (rawClosedTimes is Map) {
      rawClosedTimes.forEach((k, v) {
        final t = v is num ? v.toInt() : int.tryParse('$v');
        if (t != null && t > 0) closedTimes['$k'] = t;
      });
    }
    final closedPMs = p['closedPMs'];
    if (closedPMs is List || closedTimes.isNotEmpty) {
      try {
        appState.mergeClosedPmSync(
          closedPMs is List ? closedPMs.whereType<String>() : const <String>[],
          closedTimes,
        );
      } catch (_) {}
    }

    // Left-group state (app.js:6549-6561): KV union + newest leave time, then
    // the retroactive live-store drop.
    _mergeLeftGroupsFromSync(p['leftGroups'], p['leftGroupTimes']);

    // Per-conversation read watermarks (app.js:6565-6577): monotonic max per
    // channel/PM/group so a new device's badges don't re-surface already-read
    // history. `markChannelRead` keeps the max and persists via its callback.
    _applyChannelLastRead(p['channelLastRead']);

    // Tutorial / bot-PM markers (applyNostrSettings, app.js:6083-6098):
    // `tutorialSeen` / `botPmWelcomed` only ever flip ON (seen on any device →
    // suppressed everywhere), and `botPmClearedAt` is monotonic — a `?clear`
    // on another device hides this device's pre-clear Nymbot history too.
    // SETTINGS-SYNC seam (inbound apply of the ?clear/welcome push).
    if (p['tutorialSeen'] == true) {
      try {
        kvStore.setString(StorageKeys.tutorialSeen, 'true');
      } catch (_) {}
    }
    final botCleared = p['botPmClearedAt'];
    try {
      _ref.read(botChatControllerProvider.notifier).applySyncedMarkers(
            welcomed: p['botPmWelcomed'] == true,
            clearedAtSec: botCleared is num ? botCleared.toInt() : 0,
          );
    } catch (_) {}
    // Cross-device "encryption at rest preferred" hint (applyNostrSettings,
    // app.js:6101-6103): monotonic — persisted on EVERY inbound apply path
    // (settings-get merge, live nym-sync wrap, section transfer, user-transfer
    // accept), not just the settings-get merge, so an encrypt-at-rest preference
    // set on another device gates this device's prompt (key-vault.js:419). The
    // PWA sets it inside `applyNostrSettings`, which every apply routes through.
    if (p['encryptAtRestPreferred'] == true) {
      try {
        kvStore.setBool(StorageKeys.encryptAtRestPref, true);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Cross-device settings sections published after boot. The PWA AUTO-APPLIES
  // remote settings (settingsLoadFromD1, settings.js:781-850, and live
  // nym-sync gift wraps) — it never surfaces its own sections as manual
  // accept/decline offers. The "Pending Settings Transfers" list is reserved
  // for USER-TO-USER transfers ([pendingUserSettingsTransfersProvider]).
  // ---------------------------------------------------------------------------

  /// Fetches any settings sections in D1 newer than our last applied sync ts
  /// and AUTO-APPLIES them oldest→newest (so the newest values win), advancing
  /// the stored sync ts — the PWA's `settingsLoadFromD1` behavior. Called when
  /// the settings modal opens; best-effort; no-op without storage sync.
  Future<void> refreshPendingSettingsTransfers() async {
    final sync = _storageSync;
    if (sync == null) return;
    try {
      final sinceMs = _lastSettingsSyncMs();
      final sections = await sync.settingsTransfersSince(sinceMs);
      if (sections.isEmpty) return;
      // Oldest→newest so the most recently saved values win
      // (settings.js:826-828 sorts sections by updatedAt ascending).
      final ordered = [...sections]
        ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      var newestSec = 0;
      for (final s in ordered) {
        // Additive merge THEN replace-style apply per section, like
        // `settingsLoadFromD1` (settings.js:832-835).
        _applySyncedSettingsAdditive(s.payload);
        _applySyncedSettings(s.payload);
        final sec = s.updatedAt ~/ 1000;
        if (sec > newestSec) newestSec = sec;
      }
      final kv = _ref.read(keyValueStoreProvider);
      final lastSec = int.tryParse(
              kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ??
          0;
      if (newestSec > lastSec) {
        kv.setString(StorageKeys.lastSettingsSyncTs, '$newestSec');
      }
      // The accept/decline offer list stays empty — the PWA has no such UX for
      // its own sections.
      _ref.read(pendingSettingsTransfersProvider.notifier).clear();
    } catch (_) {
      // Best-effort.
    }
  }

  /// Accepts an inbound settings-transfer [id]: applies the section's payload to
  /// the local [Settings] (PWA field names → typed setters), advances the stored
  /// sync ts to its `updatedAt` so it won't re-offer, and removes it from the
  /// pending list. Returns true if an offer with that id was applied.
  bool acceptSettingsTransfer(String id) {
    final notifier = _ref.read(pendingSettingsTransfersProvider.notifier);
    final offer = notifier.removeById(id);
    if (offer == null) return false;
    // Additive merge then replace-style apply, like `settingsLoadFromD1`
    // (settings.js:832-835).
    _applySyncedSettingsAdditive(offer.payload);
    _applySyncedSettings(offer.payload);
    // Advance the sync ts (stored in seconds, matching the PWA) so the accepted
    // section isn't re-surfaced on the next refresh.
    final kv = _ref.read(keyValueStoreProvider);
    final lastSec = int.tryParse(
            kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ??
        0;
    final offerSec = offer.updatedAt ~/ 1000;
    if (offerSec > lastSec) {
      kv.setString(StorageKeys.lastSettingsSyncTs, '$offerSec');
    }
    return true;
  }

  /// Declines an inbound settings-transfer [id]: drops it from the pending list
  /// without applying it. Returns true if it was present. (It may re-appear on a
  /// later refresh if that section is published again with a newer ts — matching
  /// the PWA, which has no permanent per-section suppression.)
  bool declineSettingsTransfer(String id) {
    return _ref.read(pendingSettingsTransfersProvider.notifier).removeById(id) !=
        null;
  }

  int _lastSettingsSyncMs() {
    final kv = _ref.read(keyValueStoreProvider);
    final sec =
        int.tryParse(kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ?? 0;
    return sec * 1000;
  }

  /// True once the boot settings restore attempt has settled (the PWA's
  /// `_settingsHydrated`, settings.js:230). Outbound saves are DEFERRED until
  /// then: "on a fresh device an early save (e.g. from an incoming group
  /// message) would otherwise clobber D1/relay with default state before the
  /// load lands" (`_publishEncryptedSettings`, settings.js:393-399) — e.g. a
  /// one-group `nymchat-groups` row or a fresh-key `nymchat-keys-<gid>` row
  /// overwriting the account's real backup (a WHOLE-ROW D1 upsert).
  bool _settingsHydrated = false;
  bool _settingsSavePending = false;

  /// Marks the initial settings load complete so saves may begin, flushing one
  /// reconcile save if any were suppressed while loading (the PWA's
  /// `_markSettingsHydrated`, settings.js:230-246). Also releases the
  /// onboarding gate ([settingsHydrated]) — the PWA fires its
  /// `_onHydratedCbs` (tutorial / bot welcome) from the same place
  /// (settings.js:247-252).
  void _markSettingsHydrated() {
    _releaseOnboardingGate();
    if (_settingsHydrated) return;
    _settingsHydrated = true;
    if (_settingsSavePending) {
      _settingsSavePending = false;
      syncSettings();
    }
  }

  /// Releases ONLY the onboarding gate ([settingsHydrated] future) — the
  /// tutorial / bot-welcome may proceed — WITHOUT opening the outbound-save gate
  /// ([_settingsHydrated]). Used when the boot settings load FAILS or times out:
  /// onboarding must not hang, but a device that never read the account's
  /// existing D1 settings must NOT publish its local/default state over them (the
  /// PWA keeps the save gate closed on a failed `settingsLoadFromD1` and only
  /// opens it at a real load's completion — settings.js). The reconnect retry
  /// ([_backfillFromD1OnReconnect] → [_mergeRemoteSettings]) opens the save gate
  /// once a load actually succeeds, flushing any deferred save merged with the
  /// restored remote state.
  void _releaseOnboardingGate() {
    _settingsHydratedFallback?.cancel();
    _settingsHydratedFallback = null;
    if (!_settingsHydratedC.isCompleted) _settingsHydratedC.complete();
  }

  /// Debounced encrypted-settings publish (`_debouncedNostrSettingsSave`, 5s).
  /// Call after any synced-setting change. No-op when storage sync is
  /// unavailable, or for an EPHEMERAL identity running in 'random'/'hardcore'
  /// keypair mode (`saveSyncedSettings`, settings.js:54-61 — the keypair
  /// changes every session/message, so publishing settings-set rows under each
  /// throwaway pubkey would be useless; the hardcore warning even promises
  /// "Settings will not sync across devices"). Deferred (one pending flush)
  /// until the boot settings restore has landed — see [_settingsHydrated].
  void syncSettings() {
    final sync = _storageSync;
    if (sync == null) return;
    if (!_settingsHydrated) {
      _settingsSavePending = true;
      return;
    }
    if (_identity?.loginMethod == null) {
      final mode = _ref.read(settingsProvider.notifier).keypairMode;
      if (mode == 'random' || mode == 'hardcore') return;
    }
    _settingsSyncTimer?.cancel();
    _settingsSyncTimer = Timer(const Duration(seconds: 5), () {
      unawaited(_flushSettingsSync(sync));
    });
  }

  Future<void> _flushSettingsSync(StorageSync sync) async {
    try {
      // The default landing channel is KV-only (not a typed Settings field), so
      // thread it in explicitly so it rides the `channels` section like the PWA
      // (`pinnedLandingChannel`, settings.js:21,116). SETTINGS-SYNC seam.
      final appState = _ref.read(appStateProvider.notifier);
      await sync.settingsSet(
        _ref.read(settingsProvider),
        pinnedLandingChannelJson:
            _ref.read(settingsProvider.notifier).pinnedLandingChannelJson,
        // Seen-call map rides the `messaging` section so a call answered/
        // declined/missed on this device reflects on our others (calls.js
        // `_seenCallsForSync`, settings.js:152). F06-A3 outbound seam.
        seenCalls: _ref.read(callServiceProvider).seenCallsForSync(),
        // Left-group state from the LIVE app state (the PWA serializes
        // `this.leftGroups`/`this.leftGroupTimes`, settings.js:147-149) —
        // the KV fallback in buildSectionPayloads can lag the fire-and-forget
        // `_persistLeftGroups` write, publishing a stale/empty leave set.
        extras: {
          'leftGroups': appState.leftGroups.toList(),
          'leftGroupTimes':
              Map<String, dynamic>.from(appState.leftGroupTimes),
        },
      );
      // N26 outbound: publish the cross-device notification read-state wrap (the
      // `nymchat-notifications` category) so a notification read/dismissed here
      // is silenced on our other devices (settings.js:559). Carries the LIVE
      // bell history + last-read watermark alongside the seen keys — the PWA
      // payload `{notificationHistory, notificationLastReadTime,
      // seenNotifications?}` (settings.js:534-557). No-op when unchanged.
      final notifHistory = _ref.read(notificationHistoryProvider.notifier);
      await sync.notificationsWrapSet(
        notifHistory.seenNotificationsForSync(),
        notificationHistory: notifHistory.historyForSync(),
        notificationLastReadTime: notifHistory.notificationLastReadTime,
      );
      // Publish the cross-device read-state category (`nymchat-readstate`) so a
      // channel/PM/group marked read here restores its unread watermark on our
      // other devices (`_syncReadStateToD1`, settings.js:745-776). No-op when
      // empty/unchanged. Read state changes route here via the debounced
      // `syncSettings` fired from `onChannelReadChanged`.
      await sync.readStateSet(
        _ref.read(appStateProvider.notifier).channelLastRead,
      );
      // Per-group cross-device sync (`nymchat-groups` / `nymchat-keys-<gid>` /
      // `nymchat-history-<gid>`) so group membership, decryption keys, and
      // backlog restore on a fresh device (`_publishEncryptedSettings` group
      // branches, settings.js:435-529). No-op per category when unchanged.
      await _flushGroupSync(sync);
    } catch (_) {
      // Best-effort.
    }
  }

  /// Builds the three per-group sync payloads from the live group store +
  /// ephemeral-key manager + message store and publishes them via
  /// [StorageSync.groupSyncSet]. Mirrors the group branches of the PWA's
  /// `_publishEncryptedSettings` (settings.js:435-529): group conversations →
  /// `nymchat-groups`, ephemeral keys → `nymchat-keys-<gid>`, and the backlog →
  /// month-bucketed `nymchat-history-<gid>` shards. Own optimistic echoes and
  /// system pills are excluded from the history (they carry synthetic ids and
  /// aren't durable messages). Best-effort.
  Future<void> _flushGroupSync(StorageSync sync) async {
    final groups = _groups;
    if (groups == null) return;
    final appState = _ref.read(appStateProvider.notifier);
    final st = _ref.read(appStateProvider);

    // Group conversation metadata (PWA `_buildGroupConversationsSync`,
    // settings.js:298-322) — the SYNC shape only. memberProfiles /
    // allowMemberInvites / lastModTs / lastModEventId are localStorage-only in
    // the PWA (`_saveGroupConversations`, groups.js:317-355) and ride the
    // local `nym_groups_<pubkey>` blob here ([_persistGroupStore]) instead;
    // publishing them would diverge from the shared D1 category.
    final conversations = <String, Map<String, dynamic>>{};
    for (final g in st.groups) {
      conversations[g.id] = _serializeGroupForSync(g);
    }

    // Serialized per-group ephemeral keys.
    final ephemeralKeys = groups.ephemeralKeysForSync();

    // Group message backlog per conversation key (PWA `_buildGroupHistorySync`).
    final history = <String, List<Map<String, dynamic>>>{};
    st.messages.forEach((key, msgs) {
      if (!key.startsWith('group-') || msgs.isEmpty) return;
      final out = <Map<String, dynamic>>[];
      for (final m in msgs) {
        if (m.isSystemRow || m.optimistic || m.id.isEmpty) continue;
        if (m.id.startsWith('_optim_') || m.id.startsWith('sys-')) continue;
        out.add({
          'id': m.id,
          'pubkey': m.pubkey,
          'content': m.content,
          'created_at': m.createdAt,
          'isOwn': m.isOwn,
          'groupId': m.groupId,
          'nymMessageId': m.nymMessageId,
        });
      }
      if (out.isNotEmpty) history[key] = out;
    });

    await sync.groupSyncSet(
      groupConversations: conversations,
      ephemeralKeysByGroup: ephemeralKeys,
      historyByConvKey: history,
      leftGroups: appState.leftGroups,
    );
  }

  /// Serializes a [Group] for the `nymchat-groups` category, byte-matching the
  /// PWA's `_buildGroupConversationsSync` (settings.js:298-322): {name,
  /// members, lastMessageTime, createdBy, mods, banned, banner, avatar,
  /// description, inviteEnabled, inviteEpoch, metaUpdatedAt, modLog} — NO
  /// memberProfiles / allowMemberInvites / lastModTs / lastModEventId (those
  /// are localStorage-only; see [_serializeGroupForLocal]). modLog is capped
  /// to the most recent 50 entries.
  static Map<String, dynamic> _serializeGroupForSync(Group g) {
    final modLog = g.modLog.length > 50
        ? g.modLog.sublist(g.modLog.length - 50)
        : g.modLog;
    return {
      'name': g.name,
      'members': g.members,
      'lastMessageTime': g.lastMessageTime,
      'createdBy': g.createdBy,
      'mods': g.mods,
      'banned': g.banned,
      'banner': g.banner,
      'avatar': g.avatar,
      'description': g.description,
      'inviteEnabled': g.inviteEnabled == true,
      'inviteEpoch': g.inviteEpoch,
      'metaUpdatedAt': g.metaUpdatedAt,
      'modLog': [for (final e in modLog) e.toJson()],
    };
  }

  /// Serializes a [Group] for the LOCAL `nym_groups_<pubkey>` blob — the PWA's
  /// `_saveGroupConversations` shape (groups.js:317-355): the sync fields plus
  /// the device-local extras `memberProfiles` (cached kind-0 nym/avatar
  /// snapshots so a relaunch shows names immediately), `allowMemberInvites`,
  /// and the moderation-dedup watermark `lastModTs`/`lastModEventId`.
  static Map<String, dynamic> _serializeGroupForLocal(Group g, AppState st) {
    final data = _serializeGroupForSync(g);
    final memberProfiles = <String, Map<String, dynamic>>{};
    for (final pk in g.members) {
      final u = st.users[pk];
      final name = u?.nym;
      final pic = u?.profile?.picture;
      final hasName = name != null && name.isNotEmpty;
      final hasPic = pic != null && pic.isNotEmpty;
      if (!hasName && !hasPic) continue;
      memberProfiles[pk] = {
        if (hasName) 'name': name,
        if (hasPic) 'picture': pic,
      };
    }
    data['memberProfiles'] = memberProfiles;
    data['allowMemberInvites'] = g.allowMemberInvites;
    data['lastModTs'] = g.lastModTs;
    data['lastModEventId'] = g.lastModEventId;
    return data;
  }

  /// Hydrates the deduped custom-emoji set from the D1 archive (`emoji-get` —
  /// `_emojiRestoreFromD1`, emoji.js:198-222): each returned kind-30030 pack /
  /// own kind-10030 list is signature-verified (the PWA's
  /// `_verifyRelayEventAsync`) and routed through the SAME ingest handlers the
  /// live relay subscription uses ([_ingestEmojiPack] / [_ingestUserEmojiList],
  /// which dedup newest-wins), so a pack arriving from both sources applies
  /// once. Throttling (10 min) lives in [StorageSync.emojiGet]. Best-effort.
  Future<void> _restoreEmojiFromD1(StorageSync sync) async {
    try {
      final events = await sync.emojiGet();
      final parsed = <NostrEvent>[];
      for (final raw in events) {
        try {
          parsed.add(NostrEvent.fromJson(raw));
        } catch (_) {
          // Skip a malformed archived pack.
        }
      }
      if (parsed.isEmpty) return;
      // Verify the whole emoji cohort off the main isolate in ONE batched hop
      // (was inline `schnorr.verifyEvent` per pack on the render thread).
      // Newest-wins dedup makes dispatch order irrelevant, so verify-all then
      // dispatch is equivalent to the old interleaved loop.
      final service = _service;
      final oks = service != null
          ? await Future.wait([for (final ev in parsed) service.verifyEvent(ev)])
          : [for (final ev in parsed) schnorr.verifyEvent(ev)];
      for (var i = 0; i < parsed.length; i++) {
        if (!oks[i]) continue;
        final event = parsed[i];
        try {
          if (event.kind == EventKind.emojiPack) {
            _ingestEmojiPack(event);
          } else if (event.kind == EventKind.userEmojiList) {
            _ingestUserEmojiList(event);
          }
        } catch (_) {
          // Skip a malformed archived pack.
        }
      }
    } catch (_) {
      // Best-effort.
    }
  }

  /// Restores the PM gift-wrap backlog from D1 for a durable identity, gated by
  /// `cachePMs` (pms.js `pmRestoreFromD1`). Each restored wrap is unwrapped +
  /// routed through the normal gift-wrap handler with the session dedup so it
  /// isn't re-applied.
  Future<void> _restorePmArchive(StorageSync sync) async {
    if (!sync.durableIdentity) return;
    if (!_ref.read(settingsProvider).cachePMs) return;
    try {
      final wraps = await sync.pmRestoreFromD1();
      for (final w in wraps) {
        _replayArchivedWrap(w);
      }
    } catch (_) {
      // Best-effort.
    }
  }

  /// Loads the next older page of archived PMs when a conversation is scrolled
  /// back (pms.js `pmLoadOlderFromD1`). Gated by `cachePMs` + durable identity.
  /// Returns the number of wraps replayed.
  Future<int> loadOlderPmArchive() async {
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return 0;
    if (!_ref.read(settingsProvider).cachePMs) return 0;
    try {
      final wraps = await sync.pmLoadOlderFromD1();
      for (final w in wraps) {
        _replayArchivedWrap(w);
      }
      return wraps.length;
    } catch (_) {
      return 0;
    }
  }

  /// Unwraps a D1-archived kind-1059 wrap through the service and routes it into
  /// the store (the same path as a live inbound wrap, minus re-archiving).
  void _replayArchivedWrap(Map<String, dynamic> wrap) {
    final service = _service;
    if (service == null) return;
    try {
      service.unwrapArchivedWrap(NostrEvent.fromJson(wrap));
    } catch (_) {
      // Skip a malformed/undecryptable archived wrap.
    }
  }

  /// Archives an inbound gift wrap to D1 for a durable identity: wraps addressed
  /// to us go to our own inbox (`pm-put`); recipient-addressed wraps we sent get
  /// deposited into the recipient's inbox (`pm-deposit`). No-op for ephemeral
  /// identities or when the raw wrap isn't available. Mirrors `_archivePMEvent`
  /// / `_depositPMEvent`.
  /// Archives a wrap we just PUBLISHED (send-time): the self-addressed copy to
  /// our own inbox (`pm-put`) and recipient-addressed wraps into theirs
  /// (`pm-deposit`) — the PWA's `_depositPMEvent(nymWrapped)` +
  /// `_archivePMEvent(selfWrapped)` at send (pms.js:365-378; reactions :467,
  /// group fan-out :3181/:3207). Without the deposit an OFFLINE peer never
  /// receives the wrap in pool mode (relays carry no history — their next
  /// `pm-get` restore is the only delivery path). The worker dedups by wrap id,
  /// so overlap with the live loop-back archive is harmless.
  void _archiveSentWrap(NostrEvent wrap) {
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return;
    if (!_ref.read(settingsProvider).cachePMs) return;
    final raw = wrap.toJson();
    unawaited(sync.pmPut([raw]));
    unawaited(sync.pmDeposit([raw]));
  }

  void _archiveGiftWrap(GiftWrapUnwrapped u) {
    // Never re-upload a wrap that CAME from the archive (`pm-get` boot /
    // reconnect replay) — the PWA's `if (!fromD1)` gate at pms.js:1021.
    if (u.fromArchive) return;
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return;
    if (!_ref.read(settingsProvider).cachePMs) return;
    final raw = u.rawWrap;
    if (raw == null) return;
    final self = _identity?.pubkey;
    if (self == null) return;
    // A wrap addressed to us → archive to our inbox. A wrap we sent to someone
    // else (recipient p-tag != us) → deposit into theirs. The same wrap is never
    // both (its single p-tag is either us or them).
    unawaited(sync.pmPut([raw]));
    unawaited(sync.pmDeposit([raw]));
  }

  /// Caps a channel message list to the runtime limit (1000) before saving.
  List<Message> _capChannel(List<Message> msgs) => msgs.length > _channelMessageLimit
      ? msgs.sublist(msgs.length - _channelMessageLimit)
      : msgs;

  List<Message> _capPm(List<Message> msgs) => msgs.length > _pmStorageLimit
      ? msgs.sublist(msgs.length - _pmStorageLimit)
      : msgs;

  String _nymFor(String pubkey) {
    final u = _ref.read(appStateProvider).users[pubkey];
    return u?.nym ?? getNymFor(pubkey);
  }

  static String getNymFor(String pubkey) {
    // Lightweight fallback display name when no profile is known — `nym#xxxx`,
    // the PWA's `getNymFromPubkey` default (users.js:1085), never 'anon'.
    final suffix = pubkey.length >= 4 ? pubkey.substring(pubkey.length - 4) : '????';
    return 'nym#$suffix';
  }

  List<List<String>> _tags(Map<String, dynamic> rumor) {
    final raw = rumor['tags'];
    if (raw is! List) return const [];
    return raw
        .whereType<List>()
        .map((t) => t.map((e) => e.toString()).toList())
        .toList();
  }

  String? _tagValue(List<List<String>> tags, String name) {
    for (final t in tags) {
      if (t.isNotEmpty && t[0] == name && t.length > 1) return t[1];
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Composer attachments — image upload (Blossom) + P2P file share
  // ---------------------------------------------------------------------------

  /// Uploads [bytes] to a Blossom server (with the 3-server fallback list,
  /// users.js `_uploadWithFallback`) and returns the public media URL, or null
  /// on failure. The kind-24242 BUD auth event is signed locally and sent as the
  /// `Authorization: Nostr <base64>` header (`_signBlossomEvent`/`_putToBlossom`,
  /// users.js:516/533). [onProgress] reports 0..1 for the `#uploadProgress` bar.
  Future<String?> uploadImage(
    Uint8List bytes, {
    required String contentType,
    void Function(double progress)? onProgress,
  }) async {
    final identity = _identity;
    final sig = _signer;
    if (identity == null || sig == null) return null;

    onProgress?.call(0.15);
    // SHA-256 the bytes for the BUD-02 `x` tag (users.js:1013).
    final hashHex = sha256Hex(bytes);
    onProgress?.call(0.55);

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final authEvent = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.blossomAuth, // 24242 BUD-01 auth (NOT NIP-98 27235)
      tags: [
        ['t', 'upload'],
        ['x', hashHex],
        ['expiration', '${nowSec + 600}'],
      ],
      content: 'Uploading blob with SHA-256 hash',
    );
    final signed = await sig.sign(authEvent);
    final authHeader = 'Nostr ${base64.encode(utf8.encode(jsonEncode(signed.toJson())))}';

    final api = ApiClient();
    try {
      for (final server in kBlossomServers) {
        try {
          final data = await api.uploadBlob(bytes, server, authHeader,
              contentType: contentType);
          final url = data['url'];
          if (url is String && url.isNotEmpty) {
            onProgress?.call(1.0);
            // Replicate to the OTHER servers in the background via Blossom
            // `mirror` (the server pulls the blob from the primary URL) —
            // the bytes upload once, like the PWA (`_mirrorBlobBackground`,
            // users.js:583/640-661).
            unawaited(_mirrorBlobBackground(url, server, authHeader));
            return url;
          }
        } catch (e) {
          debugPrint('Blossom upload to $server failed: $e');
        }
      }
    } finally {
      api.dispose();
    }
    return null;
  }

  /// Mirrors an uploaded blob to the remaining Blossom servers through the
  /// proxy's `action=mirror` (users.js:508-513 `_getBlossomMirrorUrl`;
  /// proxy.js `handleBlossomMirror`): a PUT of `{url: <primaryUrl>}` carrying
  /// the SAME kind-24242 `t:upload` auth header the primary upload used
  /// (the PWA signs the mirror auth with `'upload'` too, users.js:642).
  /// Best-effort and fully backgrounded — a mirror failure never affects the
  /// already-returned primary URL.
  Future<void> _mirrorBlobBackground(
    String primaryUrl,
    String excludeServer,
    String authHeader,
  ) async {
    final remaining =
        kBlossomServers.where((s) => s != excludeServer).toList();
    if (remaining.isEmpty) return;
    final api = ApiClient();
    try {
      await Future.wait(remaining.map((server) async {
        try {
          await api.mirrorBlob(primaryUrl, server, authHeader);
        } catch (e) {
          debugPrint('Blossom mirror to $server failed: $e');
        }
      }));
    } finally {
      api.dispose();
    }
  }

  /// Shares [bytes] as a P2P file: builds the offer via [P2PService.shareFile],
  /// then announces it into the active conversation as a message carrying the
  /// `['offer', JSON]` tag (`shareP2PFile` → `publishFileOffer`, p2p.js:86/127).
  /// The local echo is shown as a file-offer message.
  Future<void> shareP2PFile({
    required Uint8List bytes,
    required String name,
    required String type,
  }) async {
    final identity = _identity;
    final service = _service;
    final p2p = _ref.read(p2pServiceProvider);
    p2p.start();
    final offer = p2p.shareFile(bytes: bytes, name: name, type: type);

    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final view = state.view;
    final content =
        'Sharing file through Nymchat: ${offer.name} (${formatFileSize(offer.size)})';

    // PM / group offers gift-wrap the SAME message a normal send would, with the
    // `['offer', JSON]` tag threaded onto the rumor so the peer/members pick up a
    // download card (`publishFileOffer` → `sendPM`/`sendGroupMessage` with
    // `{fileOffer}`, p2p.js:128-135). The local echo carries the shared
    // nymMessageId so the relay echo dedupes (same guarantee as a plain send).
    if (view.kind == ViewKind.pm) {
      if (identity == null || service == null) {
        appState.sendLocal(content, fileOffer: offer.toJson());
        return;
      }
      final nymMessageId = PmLogic.generateSharedEventId();
      appState.sendLocal(
        content,
        fileOffer: offer.toJson(),
        nymMessageId: nymMessageId,
      );
      final base = PmLogic.buildPmRumor(
        selfPubkey: identity.pubkey,
        recipientPubkey: view.id,
        content: content,
        nymMessageId: nymMessageId,
      );
      // buildPmRumor has no extra-tag seam (unlike the group builder), so append
      // the offer tag to the rumor we just built before wrapping.
      final rumor = UnsignedEvent(
        pubkey: base.pubkey,
        createdAt: base.createdAt,
        kind: base.kind,
        tags: [...base.tags, fileOfferTag(offer)],
        content: base.content,
      );
      try {
        await service.publishPM(
          rumor: rumor,
          recipientPubkey: view.id,
          settings: _msgSettings,
          onWrap: _archiveSentWrap,
        );
      } catch (_) {
        // PM send paths don't expose the echo id here; leave the optimistic
        // bubble in its sent state (mirrors a normal PM send with no receipt).
      }
      return;
    }

    if (view.kind == ViewKind.group) {
      final group = appState.groupById(view.id);
      if (identity == null || service == null || group == null) {
        appState.sendLocal(content, fileOffer: offer.toJson());
        return;
      }
      final ek = _groups!.keysFor(group.id);
      final next = ek.rotateSelf();
      _service!.setEphemeralKeys(_groups!.allEphemeralSecretKeys());
      // A self-key rotation on send: persist the new key locally, re-REQ the
      // live ephemeral gift-wrap subscription so replies wrapped to the NEW
      // key arrive, and sync so our other devices can decrypt this message's
      // wrap (the PWA saves + refreshes subs + debounce-syncs after every
      // group send, groups.js:1754-1758 / :1298).
      _afterSelfKeyRotation();
      final nymMessageId = GroupLogic.generateGroupId();
      appState.sendLocal(
        content,
        fileOffer: offer.toJson(),
        nymMessageId: nymMessageId,
      );
      final rumor = GroupLogic.buildGroupMessageRumor(
        group: group,
        selfPubkey: identity.pubkey,
        content: content,
        nymMessageId: nymMessageId,
        ephemeralPk: next.pk,
        // Thread the file-offer tag the same way the PWA does (groups.js:1707).
        extraTags: [fileOfferTag(offer)],
      );
      await service.publishGroupMessage(
        rumor: rumor,
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
        settings: _msgSettings,
        onWrap: _archiveSentWrap,
      );
      return;
    }

    // Channel branch: local echo + re-publish the channel message with the offer
    // tag (displayMessage isFileOffer path, p2p.js:158-173).
    final echo = appState.sendLocal(content, fileOffer: offer.toJson());
    if (identity == null || service == null) return;
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    // Re-publish the channel message with the extra offer tag so peers can pick
    // up the offer (publishChannelMessage builds the base ['n', nym]+wire tags;
    // we append the offer tag via a hand-built signed event).
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final unsigned = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: isGeo ? EventKind.geoChannel : EventKind.namedChannel,
      tags: [
        ['n', identity.nym],
        fileOfferTag(offer),
        ['ms', '$nowMs'],
        [isGeo ? 'g' : 'd', view.id],
      ],
      content: content,
    );
    final sig = _signer;
    if (sig == null) return;
    final signed = await sig.sign(unsigned);
    await service.pool.publish(signed);
    // Reconcile the optimistic echo with the real id so the relay echo is
    // deduped (same one-message guarantee as a normal channel send).
    if (echo != null) {
      _ref.read(appStateProvider.notifier).replaceOptimistic(
            echo.id,
            signed.id,
            realCreatedAt: signed.createdAt,
            realMs: nowMs,
          );
    }
  }

  // ---------------------------------------------------------------------------
  // P2P signaling transport — plain kind 25051/25052 over the service pool
  // ---------------------------------------------------------------------------

  Subscription? _p2pSub;

  /// Subscribes to inbound plain kind-25051/25052 events p-tagged to us (NOT
  /// gift-wrapped — nostr-core.js:736 routes these by kind). [onEvent] gets
  /// `(senderPubkey, kind, content)`. Returns an unsubscribe callback.
  void Function() subscribeP2P(
    void Function(String senderPubkey, int kind, String content) onEvent,
  ) {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return () {};
    final sub = service.pool.subscribe([
      NostrFilter(
        kinds: [EventKind.p2pSignaling, EventKind.p2pFileStatus],
        tags: {
          'p': [identity.pubkey],
        },
      ),
    ]);
    _p2pSub = sub;
    final streamSub = sub.events.listen((e) {
      onEvent(e.pubkey, e.kind, e.content);
    });
    return () {
      unawaited(streamSub.cancel());
      service.pool.closeSubscription(sub);
      if (identical(_p2pSub, sub)) _p2pSub = null;
    };
  }

  /// Signs and publishes a plain kind-[kind] P2P event ([tags]+[content]) to the
  /// relay pool (`sendP2PSignal` / `stopSeeding`). NOT gift-wrapped.
  Future<void> publishP2P({
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) async {
    final service = _service;
    final identity = _identity;
    final sig = _signer;
    if (service == null || identity == null || sig == null) return;
    final unsigned = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: kind,
      tags: tags,
      content: content,
    );
    final signed = await sig.sign(unsigned);
    await service.pool.publish(signed);
  }

  /// Builds, signs and publishes a NIP-56 kind-1984 report event for [pubkey]
  /// (optionally about a specific [messageId]), mirroring `submitReport`
  /// (`ui-context.js:312-352`). [type] is the NIP-56 report-type string used as
  /// the third element of the `p`/`e` tags (e.g. `nudity`, `spam`, `illegal`,
  /// `profanity`, `impersonation`, `other`); [details] is the free-text content.
  /// Surfaces a system message on success/failure (matching the PWA).
  Future<bool> submitReport({
    required String pubkey,
    String? messageId,
    required String type,
    String? details,
  }) async {
    final service = _service;
    final identity = _identity;
    final sig = _signer;
    if (service == null || identity == null || sig == null) return false;
    try {
      final tags = <List<String>>[
        ['p', pubkey, type],
        if (messageId != null && messageId.isNotEmpty) ['e', messageId, type],
      ];
      final unsigned = UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 1984,
        tags: tags,
        content: details ?? '',
      );
      final signed = await sig.sign(unsigned);
      await service.pool.publish(signed);
      _emitSystemMessage('Report submitted successfully');
      return true;
    } catch (_) {
      _emitSystemMessage('Failed to submit report');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Nymbot interception (`?`/@Nymbot) — commands.js `_handleBotCommand`
  // ---------------------------------------------------------------------------

  /// The verified Nymbot pubkey (`verifiedBot.pubkey`, app.js:1096).
  static const String nymbotPubkey =
      'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2';

  /// The verified Nymchat developer pubkey (`verifiedDeveloper.pubkey`,
  /// app.js:1090-1094). Used for the "Nymchat Developer" verified badge.
  static const String verifiedDeveloperPubkey =
      'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';

  /// True when [pubkey] is the verified developer (`isVerifiedDeveloper`,
  /// users.js:62). Shared API for the profile card / mention dropdown / composer.
  bool isVerifiedDeveloper(String pubkey) => pubkey == verifiedDeveloperPubkey;

  /// True when [pubkey] is the verified Nymbot (`isVerifiedBot`, users.js:71).
  /// Case-insensitive against the known constant so an id restored from
  /// D1/cache in a legacy (non-lowercased) encoding still counts — every
  /// bot-routing gate (BotChatScreen swap, columns bot header, composer `?`
  /// interception) shares this one detection.
  bool isVerifiedBot(String pubkey) =>
      pubkey == nymbotPubkey || pubkey.toLowerCase() == nymbotPubkey;

  /// True when [text] in a CHANNEL view should be routed to Nymbot instead of
  /// published as a normal message: a `?` command or an `@Nymbot` mention
  /// (messages.js:2381), detected on the non-quoted body since a quote prepend
  /// can hide the prefix (the PWA checks `rawInput`), or a reply-quote of a
  /// Nymbot message (`isNymbotReply`, messages.js:2383). PM/group views never
  /// intercept (the channel bot commands aren't wired for the paid PM surface —
  /// commands.js:438).
  bool shouldRouteToBot(String text) {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return false;
    if (isBotCommand(text) || isNymbotMention(text)) return true;
    final body = _quoteBody(text);
    if (body != text.trim() && (isBotCommand(body) || isNymbotMention(body))) {
      return true;
    }
    return _quotedNymbotAuthor(text) != null && body.isNotEmpty;
  }

  /// The non-quoted remainder of a composed message (the PWA's
  /// `nonQuotedText`, messages.js:138): every line not starting with `>`,
  /// joined and trimmed.
  static String _quoteBody(String text) => text
      .split('\n')
      .where((l) => !l.startsWith('>'))
      .join('\n')
      .trim();

  /// The quoted author when the message replies to a Nymbot message
  /// (`/^nymbot(?:#[a-f0-9]{4})?$/i` on the quote author, commands.js:28),
  /// else null.
  static String? _quotedNymbotAuthor(String text) {
    final m = RegExp(r'^>\s*@([^:]+):').firstMatch(text);
    if (m == null) return null;
    final author = m.group(1)!.trim();
    return RegExp(r'^nymbot(#[a-f0-9]{4})?$', caseSensitive: false)
            .hasMatch(author)
        ? author
        : null;
  }

  /// Ports `_extractQuoteChain` (messages.js:103-143): parses the leading
  /// `> @Author: text` / `> continuation` quote lines of a composed message
  /// into `[{author, text}]` conversation entries for the worker's `?ask` /
  /// `?guess` reply-chain context.
  static List<Map<String, String>> _extractQuoteChain(String text) {
    final conversation = <Map<String, String>>[];
    String? author;
    var buf = <String>[];
    for (final line in text.split('\n')) {
      final m = RegExp(r'^>\s*@([^:]+):\s*(.*)').firstMatch(line);
      if (m != null) {
        if (author != null) {
          conversation.add({'author': author, 'text': buf.join('\n').trim()});
        }
        author = m.group(1)!.trim();
        buf = [m.group(2) ?? ''];
      } else if (line.startsWith('>') && author != null) {
        buf.add(line.replaceFirst(RegExp(r'^>\s?'), ''));
      } else if (author != null) {
        conversation.add({'author': author, 'text': buf.join('\n').trim()});
        author = null;
        buf = [];
      }
    }
    if (author != null) {
      conversation.add({'author': author, 'text': buf.join('\n').trim()});
    }
    return conversation;
  }

  /// Routes a channel message to Nymbot: resolves `@Nymbot …` / a reply-quote
  /// of a Nymbot message to `?ask`/`?guess` (commands.js:14-35), gathers the
  /// channel key + reply-chain `conversation` + recent messages + active users
  /// for the AI-aware commands, POSTs the command to `/api/bot`, and publishes
  /// the worker-SIGNED reply event verbatim to the relay pool (`data.event`,
  /// commands.js:196-224) — the reply then renders when it arrives back
  /// through the channel subscription, exactly like the PWA, so every
  /// participant sees it with the verified-bot signature and `nymquote` intact.
  Future<void> routeToBot(String rawText) async {
    final state = _ref.read(appStateProvider);
    final view = state.view;
    if (view.kind != ViewKind.channel) {
      await _sendMessageContent(rawText);
      return;
    }

    // Command detection runs on the non-quoted body (the PWA uses `rawInput`;
    // a quote prepend would hide the `?` prefix).
    final body = _quoteBody(rawText);
    var content = body.isNotEmpty ? body : rawText.trim();

    // @Nymbot mention → ?ask <question> (commands.js:14-26). A bare @Nymbot
    // with a quote uses the quoted text as the question (commands.js:19-25).
    if (!isBotCommand(content) && isNymbotMention(content)) {
      final question = stripNymbotMention(content);
      if (question.isNotEmpty) {
        content = '?ask $question';
      } else {
        final chain = _extractQuoteChain(rawText);
        final quoted = chain.isNotEmpty ? (chain.first['text'] ?? '') : '';
        if (quoted.isNotEmpty) content = '?ask $quoted';
      }
    }

    // Reply to a Nymbot message without an explicit command → ?ask, or ?guess
    // when the quoted message carries a wordplay game token (commands.js:28-35).
    if (_quotedNymbotAuthor(rawText) != null && !content.startsWith('?')) {
      final hasGameToken =
          RegExp(r'\[gc:[A-Za-z0-9+/=]+\]').hasMatch(rawText);
      content = (hasGameToken ? '?guess ' : '?ask ') + content;
    }

    final parsed = parseBotCommand(content);
    if (parsed == null) {
      await _sendMessageContent(rawText);
      return;
    }

    // The PWA passes `this.currentGeohash` — the raw channel key for BOTH
    // geohash and named channels (the worker's `isGeohashName` decides the
    // reply kind/tag, bot.js:1826-1832).
    final channelKey =
        view.id.startsWith('#') ? view.id.substring(1) : view.id;
    final storageKey = view.storageKey;
    final cmd = parsed.name;

    // Reply-chain conversation context for ?ask / ?guess (commands.js:42-45).
    var conversation = const <Map<String, String>>[];
    if (cmd == 'ask' || cmd == 'guess') {
      conversation = _extractQuoteChain(rawText);
    }

    // Channel context for the AI-aware commands (commands.js:46-191). A `?ask`
    // may reference OTHER channels with #hashtags ("?ask #dr5r what's
    // happening there?") — context then comes from those channels
    // (commands.js:52-137), including a bounded fetch for any the store hasn't
    // loaded yet.
    var channelMessages = const <Map<String, dynamic>>[];
    var activeUsers = const <Map<String, dynamic>>[];
    const aiCommands = {'ask', 'summarize'};
    const memoryCommands = {'top', 'last', 'seen', 'who'};
    if (aiCommands.contains(cmd) || memoryCommands.contains(cmd)) {
      var contextKeys = {storageKey};
      if (cmd == 'ask' && parsed.args.isNotEmpty) {
        final referenced = await _resolveReferencedChannels(parsed.args);
        if (referenced.isNotEmpty) contextKeys = referenced;
      }
      // Re-read: the referenced-channel fetch may have ingested history.
      final ctxState = _ref.read(appStateProvider);
      channelMessages = _botChannelMessages(ctxState, contextKeys,
          allChannels: memoryCommands.contains(cmd));
      activeUsers = _botActiveUsers(ctxState, contextKeys,
          allUsers: memoryCommands.contains(cmd));
    }

    // The published user message (what the bot replies to).
    await _sendMessageContent(rawText);

    final identity = _identity;
    final senderNym = identity != null
        ? '${stripPubkeySuffix(identity.nym)}#${getPubkeySuffix(identity.pubkey)}'
        : null;

    // "Nymbot is thinking" in the channel's typing strip for the whole worker
    // round-trip (`_setBotChannelThinking(true)`, commands.js:194: 45s
    // auto-expiry; cleared early on the error paths like the PWA).
    _setBotChannelThinking(storageKey, true);
    try {
      // Body mirrors commands.js:196: `{command, args, geohash, conversation,
      // senderNym, publishedContent, channelMessages, activeUsers}` (public —
      // no auth). The worker returns `{event}`: a SIGNED kind-20000/23333
      // event from the verified bot key.
      final api = _api ??= ApiClient();
      final data = await api.botAction({
        'command': cmd,
        'args': parsed.args,
        'geohash': channelKey,
        'conversation': conversation,
        if (senderNym != null) 'senderNym': senderNym,
        'publishedContent': rawText,
        'channelMessages': channelMessages,
        'activeUsers': activeUsers,
      });
      final event = data['event'];
      if (event is Map) {
        // Publish the worker-signed event VERBATIM (`['EVENT', data.event]`,
        // commands.js:203-216); it arrives back via the channel subscription.
        final botEvent =
            NostrEvent.fromJson(Map<String, dynamic>.from(event));
        await _service?.pool.publish(botEvent);
      }
    } catch (e) {
      _setBotChannelThinking(storageKey, false);
      debugPrint('Nymbot command failed: $e');
      _emitSystemMessage('Nymbot is unavailable right now.');
    }
  }

  /// Shows/clears the bot in a CHANNEL's typing strip while a public `?`
  /// command round-trips the worker — the PWA's `_setBotChannelThinking`
  /// (commands.js:226-241): an entry under the bot pubkey with a 45s
  /// auto-expiry, rendered by the shared typing indicator.
  void _setBotChannelThinking(String storageKey, bool on) {
    try {
      _ref.read(appStateProvider.notifier).setTyping(
            storageKey: storageKey,
            pubkey: nymbotPubkey,
            typing: on,
            expiresAtMs:
                on ? DateTime.now().millisecondsSinceEpoch + 45000 : null,
          );
    } catch (_) {
      // Typing strip is cosmetic; never block the command.
    }
  }

  /// Resolves `#channel` references in a `?ask`'s args to `#`-prefixed
  /// storage keys (commands.js:52-113): exact stored-thread match first, then
  /// a case-insensitive bidirectional prefix match across stored threads and
  /// the sidebar registry; a name found nowhere is fetched from the D1
  /// archive with a bounded wait (the native analogue of the PWA's targeted
  /// relay REQ + 2s wait — history here comes from D1) and included so the
  /// freshly-ingested messages count. Empty when the args reference nothing.
  Future<Set<String>> _resolveReferencedChannels(String args) async {
    final names = <String>[];
    final refRx = RegExp(r'(?:^|[^a-z0-9])#([a-z0-9_-]+)', caseSensitive: false);
    for (final m in refRx.allMatches(args)) {
      final n = m.group(1)!.toLowerCase();
      if (!names.contains(n)) names.add(n);
    }
    if (names.isEmpty) return const {};
    final state = _ref.read(appStateProvider);
    final referenced = <String>{};
    final toFetch = <String>[];
    for (final name in names) {
      var found = false;
      if (state.messages.containsKey('#$name')) {
        referenced.add('#$name');
        found = true;
      }
      if (!found) {
        for (final key in state.messages.keys) {
          if (!key.startsWith('#')) continue;
          final stored = key.substring(1).toLowerCase();
          if (stored == name ||
              stored.startsWith(name) ||
              name.startsWith(stored)) {
            referenced.add(key);
            found = true;
            break;
          }
        }
      }
      if (!found) {
        // Sidebar registry may know a channel with no stored messages yet.
        for (final c in state.channels) {
          final k = c.key.toLowerCase();
          if (k == name || k.startsWith(name) || name.startsWith(k)) {
            referenced.add('#$k');
            found = true;
            break;
          }
        }
      }
      if (!found) {
        toFetch.add(name);
        referenced.add('#$name');
      }
    }
    if (toFetch.isNotEmpty) {
      // Brief bounded wait for the archive fetch (the PWA waits 2s for its
      // relay subscription, commands.js:104-111).
      try {
        await Future.wait([
          for (final n in toFetch) _backfillChannelArchive(n),
        ]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
      } catch (_) {
        // Best-effort: proceed with whatever ingested.
      }
    }
    return referenced;
  }

  /// Recent channel messages mapped to the worker's context shape
  /// (`{nym,pubkey,content,timestamp,isBot,channel}`, commands.js:113-121).
  /// AI commands send the NEWEST [_kBotContextMsgLimit] per referenced channel
  /// (`msgs.slice(-msgLimit)`, commands.js:122), re-capped to the newest 100
  /// after a multi-channel merge (commands.js:130-133); the in-memory commands
  /// ([allChannels]) map EVERY stored message with no cap (commands.js:167-179).
  static const int _kBotContextMsgLimit = 100;

  List<Map<String, dynamic>> _botChannelMessages(
      AppState state, Set<String> keys,
      {required bool allChannels}) {
    final out = <Map<String, dynamic>>[];
    void mapList(String key, List<Message> msgs, {int? limit}) {
      final kept = msgs.where((m) => !m.spamGated).toList();
      final start =
          (limit != null && kept.length > limit) ? kept.length - limit : 0;
      for (final m in kept.sublist(start)) {
        out.add({
          'nym': m.author,
          'pubkey': m.pubkey,
          'content':
              m.content.length > 300 ? m.content.substring(0, 300) : m.content,
          'timestamp': m.createdAt,
          'isBot': m.isBot,
          'channel': key,
        });
      }
    }

    if (allChannels) {
      state.messages.forEach(mapList);
    } else {
      for (final key in keys) {
        final msgs = state.messages[key];
        if (msgs != null) mapList(key, msgs, limit: _kBotContextMsgLimit);
      }
    }
    out.sort((a, b) =>
        (a['timestamp'] as int).compareTo(b['timestamp'] as int));
    // Multi-channel merge keeps only the newest 100 overall (commands.js:132).
    if (!allChannels && keys.length > 1 && out.length > _kBotContextMsgLimit) {
      return out.sublist(out.length - _kBotContextMsgLimit);
    }
    return out;
  }

  /// Active users in the referenced channel(s) mapped to the worker's context
  /// shape (multi-channel prefix matching mirrors commands.js:137-152). The
  /// AI-command path ([allUsers] false) carries the user's active shop `flair`
  /// (comma-joined, `flair-` prefix stripped) and `style` (`style-` prefix
  /// stripped) from `getUserShopItems(pubkey)` (commands.js:154-160); the
  /// in-memory commands (top/last/seen/who) send bare `{nym,pubkey}` entries
  /// (commands.js:183-188).
  List<Map<String, dynamic>> _botActiveUsers(AppState state, Set<String> keys,
      {required bool allUsers}) {
    final rawNames = [
      for (final k in keys) k.startsWith('#') ? k.substring(1) : k,
    ];
    final out = <Map<String, dynamic>>[];
    state.users.forEach((pubkey, user) {
      final inChannel = allUsers ||
          user.channels.any((c) => rawNames.any(
              (r) => c == r || c.startsWith(r) || r.startsWith(c)));
      if (inChannel && user.nym.isNotEmpty) {
        final entry = <String, dynamic>{
          'nym':
              '${stripPubkeySuffix(user.nym)}#${getPubkeySuffix(pubkey)}',
          'pubkey': pubkey,
        };
        if (!allUsers) {
          final items = _shopItemsFor(pubkey);
          entry['flair'] = (items != null && items.flair.isNotEmpty)
              ? items.flair
                  .map((f) => f.replaceFirst('flair-', ''))
                  .join(',')
              : null;
          entry['style'] = (items != null &&
                  items.style != null &&
                  items.style!.isNotEmpty)
              ? items.style!.replaceFirst('style-', '')
              : null;
        }
        out.add(entry);
      }
    });
    return out;
  }

  /// A user's active shop items as a `{style, flair[]}` view for the bot
  /// context — self from the live shop state, others from the D1-backed
  /// `shop-status` cache (the PWA's `getUserShopItems(pubkey)`).
  ({String? style, List<String> flair})? _shopItemsFor(String pubkey) {
    final self = _identity?.pubkey;
    if (self != null && pubkey == self) {
      final active = _ref.read(shopControllerProvider).active;
      return (style: active.style, flair: active.flair);
    }
    final other = _ref.read(otherUsersShopProvider)[pubkey.toLowerCase()];
    if (other == null) return null;
    return (style: other.style, flair: other.flair);
  }

  /// Binds the private Nymbot chat to the live identity (so the paid PM surface
  /// can authenticate) and returns whether a bind happened. The composer calls
  /// this before opening `BotChatScreen`.
  bool bindBotChat() {
    final identity = _identity;
    if (identity == null) return false;
    // Pass the privkey so the bot controller can build per-action NIP-98 auth
    // for paid requests (PWA `_signBotAuth`). Null for delegated signers
    // (ext/nip46) — those fall back to the pre-supplied auth blob.
    final bot = _ref.read(botChatControllerProvider.notifier);
    bot.bind(
      pubkey: identity.pubkey,
      privkey: identity.privkey,
    );
    // `?clear`'s server-visible legs beyond clear-history: the D1 PM-archive
    // purge (`_purgeBotPMArchive` via pm-delete, pms.js:1900) and the debounced
    // synced-settings push of the cleared-at / welcomed markers
    // (`_debouncedNostrSettingsSave`, pms.js:1878/1903).
    bot.pmArchivePurger = purgeBotPmArchive;
    bot.settingsSyncRequester = syncSettings;
    return true;
  }

  /// Best-effort removal of the Nymbot conversation's encrypted wraps from the
  /// D1 PM archive so a cleared thread can't be restored on any device —
  /// `_purgeBotPMArchive` (pms.js:1881-1891). Gated like the PWA's
  /// `_pmArchiveAllowed` (durable identity + cachePMs); [StorageSync.pmDelete]
  /// filters to 64-hex ids and chunks to the server's 200-id cap.
  Future<void> purgeBotPmArchive(List<String> wrapIds) async {
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return;
    if (!_ref.read(settingsProvider).cachePMs) return;
    await sync.pmDelete(wrapIds);
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _liveInboundTimer?.cancel();
    _liveInboundTimer = null;
    _liveInboundBuffer.clear();
    // Drop any buffered unwrapped gift-wraps (the session is tearing down).
    _giftWrapFlushTimer?.cancel();
    _giftWrapFlushTimer = null;
    _giftWrapInbound.clear();
    _settingsSyncTimer?.cancel();
    _profileBackfillTimer?.cancel();
    clearShopReceiptWait();
    if (_p2pSub != null) {
      _service?.pool.closeSubscription(_p2pSub!);
      _p2pSub = null;
    }
    await _flush(); // final flush so unsaved messages/reactions persist
    await _cache?.close();
    await _service?.stop();
    _api?.dispose();
  }
}

/// Blossom upload servers + fallback order (users.js:3 `BLOSSOM_SERVERS`).
const List<String> kBlossomServers = [
  'https://blossom.band',
  'https://blossom.primal.net',
  'https://nostr.download',
];

/// The live [P2PService], wired to the controller's signaling transport.
final p2pServiceProvider = Provider<P2PService>((ref) {
  final controller = ref.read(nostrControllerProvider);
  final service = P2PService(_ControllerP2PTransport(controller));
  // Route transfer status into the conversation (mirrors callServiceProvider)
  // and start the 25051/25052 signaling subscription so a pure receiver is
  // listening before it ever sends an offer.
  service.onSystemMessage = (m) {
    try {
      ref.read(appStateProvider.notifier).addSystemMessage(m);
    } catch (_) {}
  };
  service.start();
  ref.onDispose(service.dispose);
  return service;
});

/// Adapts [NostrController]'s `publishP2P`/`subscribeP2P` to [P2PTransport].
class _ControllerP2PTransport implements P2PTransport {
  _ControllerP2PTransport(this._c);
  final NostrController _c;

  @override
  String get selfPubkey => _c.identity?.pubkey ?? '';

  @override
  Future<void> publishP2P({
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) =>
      _c.publishP2P(kind: kind, tags: tags, content: content);

  @override
  void Function() subscribeP2P(
    void Function(String senderPubkey, int kind, String content) onEvent,
  ) =>
      _c.subscribeP2P(onEvent);
}

/// Bridges the pure [CommandDispatcher] to the [NostrController]'s engine
/// methods. Keeps the dispatcher free of controller/app_state internals.
class _CommandEngineAdapter implements CommandEngine {
  _CommandEngineAdapter(this._c);
  final NostrController _c;

  AppState get _state => _c._ref.read(appStateProvider);

  @override
  bool get inPM => _state.view.kind == ViewKind.pm;
  @override
  bool get inGroup => _state.view.kind == ViewKind.group;
  @override
  String get selfPubkey => _state.selfPubkey;
  @override
  Map<String, User> get users => _state.users;

  @override
  void sendToCurrentTarget(String content) =>
      unawaited(_c._sendMessageContent(content));
  @override
  void systemMessage(String text) => _c._emitSystemMessage(text);

  @override
  void join(String channel) => _c.cmdJoin(channel);
  @override
  void clear() => _c.cmdClear();
  @override
  void leave() => _c.cmdLeave();
  @override
  void quit() => _c.cmdQuit();
  @override
  void setNick(String newNym) => unawaited(_c.cmdNick(newNym));
  @override
  void who() => _c.cmdWho();
  @override
  void setAway(String message) => unawaited(_c.cmdSetAway(message));
  @override
  void clearAway() => unawaited(_c.cmdBack());
  @override
  void share() => _c.cmdShare();
  @override
  void block(String arg) => _c.cmdBlock(arg);
  @override
  void unblock(String arg) => _c.cmdUnblock(arg);
}

/// Per-(messageId,emoji) reaction rate-limit tracker (reactions.js
/// `reactionToggleTracker`): timestamps within the window + cooldown-until ms.
class _ReactionRateTracker {
  final List<int> timestamps = [];
  int cooldownUntil = 0;
}

/// Builds the tags for a channel message edit re-publish (messages.js
/// `publishEditedChannelMessage`): `['n', nym], [wire.tag, key], ['edit', id]`.
/// [wire.tag] is `'g'` for a geohash channel else `'d'`.
List<List<String>> buildChannelEditTags({
  required String nym,
  required String channelKey,
  required bool isGeohash,
  required String originalId,
}) {
  return [
    ['n', nym],
    [isGeohash ? 'g' : 'd', channelKey],
    ['edit', originalId],
  ];
}

/// Builds the kind-5 deletion tags (`['e', id], ['k', origKind]`) — nostr-core.js
/// `publishDeletionEvent`.
List<List<String>> buildDeletionTags(String messageId, String originalKind) {
  return [
    ['e', messageId],
    if (originalKind.isNotEmpty) ['k', originalKind],
  ];
}

final nostrControllerProvider = Provider<NostrController>((ref) {
  final c = NostrController(ref);
  ref.onDispose(c.dispose);
  return c;
});

/// Monotonically increasing "boot generation". The PWA's `signOut()` ends with
/// a full page reload to a pristine first-run state; Flutter has no reload, so
/// [NostrController.signOut] bumps this counter and the root (`app.dart`)
/// remounts a fresh [BootGate] keyed on it — tearing down the whole `HomeShell`
/// subtree and re-running the setup-needed check (which now passes because the
/// login keys were cleared). Starts at 0 (first boot needs no remount).
final bootEpochProvider = StateProvider<int>((ref) => 0);

/// Holds the inbound settings-transfer offers (cross-device settings sections
/// newer than this device's last applied sync) for the settings UI's
/// accept/decline list. Populated by
/// [NostrController.refreshPendingSettingsTransfers]; resolved via
/// [NostrController.acceptSettingsTransfer] / `declineSettingsTransfer`.
final pendingSettingsTransfersProvider = StateNotifierProvider<
    PendingSettingsTransfersNotifier, List<SettingsTransferOffer>>((ref) {
  return PendingSettingsTransfersNotifier();
});

/// StateNotifier backing [pendingSettingsTransfersProvider]. Holds the offers
/// newest-first; the controller mutates it through [setOffers] / [removeById].
class PendingSettingsTransfersNotifier
    extends StateNotifier<List<SettingsTransferOffer>> {
  PendingSettingsTransfersNotifier() : super(const []);

  /// Replaces the pending list (newest-first as supplied by the fetch).
  void setOffers(List<SettingsTransferOffer> offers) {
    state = List.unmodifiable(offers);
  }

  /// Removes and returns the offer with [id], or null if absent.
  SettingsTransferOffer? removeById(String id) {
    SettingsTransferOffer? found;
    final next = <SettingsTransferOffer>[];
    for (final o in state) {
      if (found == null && o.id == id) {
        found = o;
      } else {
        next.add(o);
      }
    }
    if (found != null) state = List.unmodifiable(next);
    return found;
  }

  /// Clears all pending offers (e.g. on logout).
  void clear() => state = const [];
}

/// An inbound USER-TO-USER settings transfer (a gift-wrapped kind-30078 with a
/// `nym-settings-transfer-…` d-tag from another user), the PWA's
/// `pendingSettingsTransfers` entry shape (shop.js:1851-1859). Rendered in the
/// settings modal's "Pending Settings Transfers" list with the sender nym,
/// `Verified sender key: <first16>…<last8>`, the localized date, and an
/// `Includes: nickname, avatar, preferences` summary.
class UserSettingsTransfer {
  const UserSettingsTransfer({
    required this.eventId,
    required this.fromPubkey,
    required this.fromNym,
    required this.settings,
    required this.transferredAt,
    this.nickname,
    this.avatarUrl,
  });

  /// The gift-wrap event id (the PWA keys accept/reject/dismiss on it).
  final String eventId;

  /// Sender pubkey (64-hex), verified against the rumor author.
  final String fromPubkey;

  /// Sender display nym (falls back to `<first8>...` of the pubkey).
  final String fromNym;

  /// Optional nickname to adopt on accept.
  final String? nickname;

  /// Optional avatar URL to adopt on accept.
  final String? avatarUrl;

  /// The flat transferable settings payload (PWA `_buildSettingsPayload`
  /// minus device-local keys).
  final Map<String, dynamic> settings;

  /// Sender wall-clock (unix seconds) of the transfer.
  final int transferredAt;
}

/// Holds the inbound user-to-user settings transfers awaiting Accept/Reject —
/// the feature the PWA's "Pending Settings Transfers" list actually shows
/// (shop.js `renderPendingSettingsTransfers`). Populated live by the
/// controller's gift-wrap handler; resolved via
/// [NostrController.acceptUserSettingsTransfer] /
/// [NostrController.rejectUserSettingsTransfer].
final pendingUserSettingsTransfersProvider = StateNotifierProvider<
    PendingUserSettingsTransfersNotifier, List<UserSettingsTransfer>>((ref) {
  return PendingUserSettingsTransfersNotifier();
});

/// StateNotifier backing [pendingUserSettingsTransfersProvider].
class PendingUserSettingsTransfersNotifier
    extends StateNotifier<List<UserSettingsTransfer>> {
  PendingUserSettingsTransfersNotifier() : super(const []);

  bool containsEventId(String eventId) =>
      state.any((t) => t.eventId == eventId);

  /// Appends a new pending transfer (dedup is the caller's job).
  void add(UserSettingsTransfer transfer) {
    state = List.unmodifiable([...state, transfer]);
  }

  /// Removes and returns the transfer with [eventId], or null if absent.
  UserSettingsTransfer? removeByEventId(String eventId) {
    UserSettingsTransfer? found;
    final next = <UserSettingsTransfer>[];
    for (final t in state) {
      if (found == null && t.eventId == eventId) {
        found = t;
      } else {
        next.add(t);
      }
    }
    if (found != null) state = List.unmodifiable(next);
    return found;
  }

  /// Clears all pending transfers (e.g. on logout).
  void clear() => state = const [];
}

/// The NIP-46 remote-signer transport. The controller reads this at boot to
/// restore a persisted `'nip46'` session and build a [Nip46SignerAdapter]. A
/// single instance is reused so the live WebSocket / pending-request state is
/// shared (disposed with the provider scope). `SecureStore` / `KeyValueStore`
/// structurally satisfy the service's `Nip46SecureStore` / `Nip46KeyValueStore`
/// interfaces.
final nip46ServiceProvider = Provider<Nip46Service>((ref) {
  final svc = Nip46Service(
    kv: _Nip46KvAdapter(ref.read(keyValueStoreProvider)),
    secure: _Nip46SecureAdapter(SecureStore()),
    // Route NIP-46 through the shared relay pool (proxy/direct, already
    // connected to the default signer relay) when it covers the relay. Lazy —
    // resolved at `_openRelay` time, by which point the controller/pool exist.
    poolProvider: () => ref.read(nostrControllerProvider).pool,
  );
  ref.onDispose(svc.dispose);
  return svc;
});

/// Adapts [KeyValueStore] to the NIP-46 service's [Nip46KeyValueStore]
/// interface (Dart's abstract classes aren't structurally satisfied).
class _Nip46KvAdapter implements Nip46KeyValueStore {
  _Nip46KvAdapter(this._kv);
  final KeyValueStore _kv;
  @override
  String? getString(String key) => _kv.getString(key);
  @override
  Future<void> setString(String key, String value) => _kv.setString(key, value);
}

/// Adapts [SecureStore] to the NIP-46 service's [Nip46SecureStore] interface.
class _Nip46SecureAdapter implements Nip46SecureStore {
  _Nip46SecureAdapter(this._secure);
  final SecureStore _secure;
  @override
  Future<String?> get(String key) => _secure.get(key);
  @override
  Future<void> set(String key, String value) => _secure.set(key, value);
  @override
  Future<void> remove(String key) => _secure.remove(key);
}

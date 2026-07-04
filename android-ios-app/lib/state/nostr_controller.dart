import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crypto/bech32_codec.dart' as bech32;
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
import '../features/identity/nip46_service.dart';
import '../features/identity/panic_wipe.dart';
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

  /// Re-mirrors our own authoritative signed kind-0 to D1 (`profile-set`) so a
  /// profile edited in another Nostr client stays reflected in the D1 public
  /// copy (`_saveProfileToD1`, nostr-core.js:194-204). Gated on a durable
  /// identity (the native analogue of `_hasCustomProfileData`) and deduped by
  /// event id. Best-effort.
  void _mirrorOwnProfileToD1(NostrEvent event) {
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return;
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
    try {
      final kv = _ref.read(keyValueStoreProvider);
      final identityService =
          IdentityService(kv: kv, secure: SecureStore());

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
      // Seed Low Data Mode from the persisted setting BEFORE the relay layer
      // shards its geo relays (the PWA reads `settings.lowDataMode` in
      // `_computeExpectedShards`, relays.js:1905-1978; boot applies the saved
      // value). No-op when the setting is off (the default).
      if (_ref.read(settingsProvider).lowDataMode) {
        unawaited(service.setLowDataMode(true));
      }
      await service.start(NostrHandlers(
        onEvent: _onEvent,
        onConnectionChanged: _onConnectionChanged,
        onGiftWrap: _onGiftWrap,
      ));

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

      // Subscribe to peers' `nym-vouches` lists (web of trust). On boot the only
      // trusted authors are the seeded dev/bot roots; the graph then expands one
      // hop at a time as their vouches arrive (relays.js:2536-2542).
      _subscribeVouches();

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
  /// time-bounds each fetch). Best-effort; empty/blank keys are skipped.
  Future<void> _backfillChannelArchivesFor(Iterable<String> keys) async {
    final list = <String>{
      for (final k in keys)
        if (k.isNotEmpty) k,
    }.toList();
    if (list.isEmpty) return;
    var next = 0;
    Future<void> worker() async {
      while (next < list.length) {
        await _backfillChannelArchive(list[next++]);
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

      // Discovered GEOHASH channels → sidebar (as geohash entries) + last-activity.
      app.applyChannelActivity(geo.activity, geo.last, geohash: true);
      // Discovered NAMED channels → sidebar (as named entries) + last-activity.
      app.applyChannelActivity(named.activity, named.last);
      // Known channels' activity → unread floors (+ last-activity top-up). These
      // keys are already joined, so no new sidebar rows are created here.
      app.applyChannelActivity(knownActivity.activity, knownActivity.last);
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
      final ok = await svc.restoreSession();
      if (!ok || svc.pubkey.length != 64) return null;
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
    final name = profile?.name;
    if (name == null || name.isEmpty) return;
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
    _settingsSyncTimer?.cancel();
    _vouchPublishTimer?.cancel();
    _vouchPublishTimer = null;
    _vouchExpansionTimer?.cancel();
    _vouchExpansionTimer = null;
    _trustPersistTimer?.cancel();
    _trustPersistTimer = null;
    _lastVouchPublishAt = 0;
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
    // Stop backfilling on view-open (the binding captured the old storage sync).
    _ref.read(appStateProvider.notifier).onViewOpened = null;
    _ref.read(appStateProvider.notifier).onPmMessageIngested = null;
    _ref.read(appStateProvider.notifier).onGroupStoreChanged = null;
    // Stop broadcasting shop-update presence / gift DMs / system lines (the
    // bindings captured the old identity/service).
    final shop = _ref.read(shopControllerProvider.notifier);
    shop.onActiveItemsPublished = null;
    shop.giftEventPublisher = null;
    shop.onSystemMessage = null;
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
    final identityService = IdentityService(kv: kv, secure: SecureStore());
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

  void _onEvent(NostrEvent event) {
    final appState = _ref.read(appStateProvider.notifier);
    if (event.kind == EventKind.appData) {
      // Kind 30078 is multiplexed by the `['t', ...]` topic (nostr-core.js:
      // 570-577 dispatches on `tTag[1]`): presence / poll / poll-vote / vouches.
      final topic = event.tagValue('t');
      if (topic == AppDataTopic.vouches) {
        _ingestVouch(event);
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
      // Resolve the REACTOR's D1 profile so the reactors sheet (and any future
      // surface) shows their custom avatar, not the identicon — the PWA resolves
      // list/reaction author avatars too (`ensureListProfiles`, reactions.js:631).
      // Guarded + debounced inside; a no-op once we know their picture.
      if (!removed) _maybeBackfillProfiles(event.pubkey);
      if (!removed) {
        final target = event.tagValue('e');
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
      final selfPk = _identity?.pubkey ?? '';
      if (event.pubkey != selfPk) {
        final earnedTrust = _ref
            .read(appStateProvider.notifier)
            .trackPubkeyMessage(event.pubkey, event.id);
        if (earnedTrust) _scheduleTrustPersist();
        if (pow.validatePow(event, _nymchatPowFloor)) {
          _observeNymchatPubkey(event.pubkey);
        }
      }

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
      final key = EventMapper.channelKeyOf(event);
      // In columns view the "visible" proxy is the deck's seen gate (focused +
      // at-bottom + app visible — the PWA sends the receipt only when
      // `_cvMarkColumnRead` returned true, messages.js:546-555); in single
      // view it degrades to "is the active view".
      if (event.pubkey != self &&
          geohash != null &&
          geohash.isNotEmpty &&
          _isChannelMessageId(event.id) &&
          !_isHistorical(event.createdAt) &&
          key != null &&
          appState.isConversationSeen(key)) {
        unawaited(sendChannelReadReceipt(event.id, event.pubkey, geohash));
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
    // The verified Nymbot never records to history (notifications.js:14).
    if (isVerifiedBot(senderPubkey)) return;
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

  /// (Re)subscribes to peers' `nym-vouches` lists authored by our current trust
  /// graph (relays.js:2538-2542). Called on connect and on each expansion hop.
  void _subscribeVouches() {
    final service = _service;
    if (service == null) return;
    final authors = _ref.read(appStateProvider).nymchatPubkeys;
    service.subscribeVouches(authors);
  }

  void _onGiftWrap(GiftWrapUnwrapped u) {
    final appState = _ref.read(appStateProvider.notifier);
    final rumor = u.rumor;
    final kind = u.rumorKind;
    final self = _service?.selfPubkey ?? '';

    switch (kind) {
      case EventKind.dmRumor: // 14 — PM or group message
        // Archive the durable DM wrap to D1 (PMs + group messages; the PWA
        // archives `event` in `handleGiftWrapDM` before the group/PM split,
        // pms.js:1021). Receipts/typing (kind 69420) are NOT archived.
        _archiveGiftWrap(u);
        _onRumorMessage(u, appState, self);
      case EventKind.nymReceiptRumor: // 69420 — receipt or typing
        _onReceiptOrTyping(rumor, appState);
      case EventKind.reaction: // 7 — gift-wrapped reaction
        _onPrivateReaction(rumor, appState);
      case EventKind.zapReceipt: // 9735 — gift-wrapped private zap announcement
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
  /// pending offer; our OWN `nymchat-settings-<section>` wrap (published live
  /// by another of our devices) is auto-applied when newer than what we've
  /// already applied — the PWA never prompts for its own sections.
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

    // Live cross-device settings section from OUR other device: apply when
    // strictly newer than both the per-section applied ts and the stored sync
    // ts (pms.js:858-888) — never re-surfaced as a manual offer.
    final isOwn = self.isNotEmpty && senderPubkey == self;
    final isCoreSettings =
        dTag == 'nymchat-settings' || dTag.startsWith('nymchat-settings-');
    if (isOwn && isCoreSettings && dTag != 'nymchat-settings') {
      try {
        final decoded = jsonDecode(rumor['content'] as String? ?? '');
        if (decoded is! Map) return;
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
          _applySyncedSettings(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // Malformed settings blob — ignore.
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
      if (appState.groupById(groupId) != null) return;
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
      // Group invite notification (groups.js:868 `Group invite: <name>`).
      if (_notificationsEnabled &&
          !_ref.read(appStateProvider).blockedUsers.contains(senderPubkey)) {
        final inviter = _nymDisplayFor(senderPubkey);
        _dispatchNotification(
          title: 'Group invite: ${name.isNotEmpty ? name : 'group'}',
          body: '$inviter added you to ${name.isNotEmpty ? name : 'a group'}',
          senderPubkey: senderPubkey,
          isFriend: _ref.read(appStateProvider).isFriend(senderPubkey),
          isMention: false,
          isGroup: true,
          historyType: 'group',
          route: groupId,
          eventId: u.wrapId,
          tsMs: (rumor['created_at'] as num?)?.toInt() != null
              ? (rumor['created_at'] as num).toInt() * 1000
              : null,
          // Group source → footer label `in <GroupName>` (PWA `channelInfo`).
          contextLabel: 'in ${name.isNotEmpty ? name : 'a group'}',
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
        if (appState.groupById(groupId) == null) {
          final claimedOwner = _tagValue(tags, 'owner');
          if (claimedOwner != null && claimedOwner == senderPubkey) {
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
        unawaited(service.publishPM(
          rumor: pending.rumor,
          recipientPubkey: pending.recipientPubkey,
          settings: _msgSettings,
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
      unawaited(service.publishPM(
        rumor: pending.rumor,
        recipientPubkey: pending.recipientPubkey,
        settings: _msgSettings,
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
        await service.publishPM(
          rumor: rumor,
          recipientPubkey: view.id,
          settings: _msgSettings,
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
      // A self-key rotation on send must reach our other devices so they can
      // decrypt this message's wrap (the PWA saves after every group send,
      // groups.js:1298). Debounced + content-hash-deduped in `syncSettings`.
      syncSettings();
      final nymMessageId = GroupLogic.generateGroupId();
      appState.sendLocal(trimmed, nymMessageId: nymMessageId);
      final rumor = GroupLogic.buildGroupMessageRumor(
        group: group,
        selfPubkey: identity.pubkey,
        content: trimmed,
        nymMessageId: nymMessageId,
        ephemeralPk: next.pk,
        // NIP-30 declarations for any known custom `:shortcode:` in the body
        // (groups.js:1699 `tags.push(...customEmojiTagsForContent(content))`).
        extraTags: _ref
            .read(liveCustomEmojiProvider.notifier)
            .emojiTagsForContent(trimmed),
      );
      await service.publishGroupMessage(
        rumor: rumor,
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
        settings: _msgSettings,
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
    final identityService = IdentityService(kv: kv, secure: SecureStore());
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

  /// `/nick` — change nickname (cmdNick): publish a kind-0 with the new name.
  Future<void> cmdNick(String newNym) async {
    final next = newNym.trim();
    if (next.length > 20) {
      await saveProfile(name: next.substring(0, 20));
    } else {
      await saveProfile(name: next);
    }
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

    // Drop locally via the self-removal path (adds to leftGroups, removes the
    // group + its messages). The self-kick is always authorized (group_logic).
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
      // A self-key rotation on send must reach our other devices so they can
      // decrypt this message's wrap (the PWA saves after every group send,
      // groups.js:1298). Debounced + content-hash-deduped in `syncSettings`.
      syncSettings();
      final base = GroupLogic.buildGroupMessageRumor(
        group: group,
        selfPubkey: identity.pubkey,
        content: trimmed,
        nymMessageId: GroupLogic.generateGroupId(),
        ephemeralPk: next.pk,
      );
      await service.publishGroupMessage(
        rumor: _withEditTag(base, messageId),
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
        settings: _msgSettings,
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
      // Public channel typing (kind 24420) — only for geohash channels, exactly
      // like the PWA `handleChannelTypingSignal` (gated on `currentGeohash`).
      final entry = state.channels.where((c) => c.key == view.id.toLowerCase());
      if (entry.isEmpty || !entry.first.isGeohash) return;
      await service.publishChannelTyping(
        status: 'start',
        geohash: entry.first.geohash,
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
  /// [authorPubkey] in [geohash], once per message. Scope-gated to the channel
  /// context and geohash channels only (PWA `sendChannelReadReceipt`): never
  /// receipts our own message, and dedupes via [_sentChannelReadReceipts].
  Future<void> sendChannelReadReceipt(
      String messageId, String authorPubkey, String geohash) async {
    if (!_channelReceiptAllowed()) return;
    if (messageId.isEmpty || authorPubkey.isEmpty || geohash.isEmpty) return;
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
      geohash: geohash,
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
    if (entry.isEmpty || !entry.first.isGeohash) return;
    final geohash = entry.first.geohash;
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
      final gh = (m.geohash ?? '').isNotEmpty ? m.geohash! : geohash;
      unawaited(sendChannelReadReceipt(m.id, m.pubkey, gh));
    }
  }

  /// True for a 64-hex channel-message id (PWA `/^[0-9a-f]{64}$/i` gate before
  /// a channel read receipt is sent).
  static final RegExp _channelMessageIdRe = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
  bool _isChannelMessageId(String id) => _channelMessageIdRe.hasMatch(id);

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
    // mirroring the PWA's `status === 'stop'` branch.
    appState.setTyping(
      storageKey: '#${geohash.toLowerCase()}',
      pubkey: event.pubkey,
      typing: status == 'start',
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

    // Private reactions (PM/group) are gift-wrapped to the conversation.
    if (kind == '1059' || kind == '14') {
      return _sendPrivateReaction(messageId, emoji, target, remove);
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
  /// [UserProfile] + identity nym (`saveToNostrProfile`). Empty/null fields are
  /// omitted. Returns true on publish.
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

    final profile = <String, dynamic>{};
    if (name != null && name.isNotEmpty) {
      profile['name'] = name;
      profile['display_name'] = name;
    }
    if (about != null) profile['about'] = about;
    if (picture != null && picture.isNotEmpty) profile['picture'] = picture;
    if (banner != null && banner.isNotEmpty) profile['banner'] = banner;
    if (lud16 != null && lud16.isNotEmpty) profile['lud16'] = lud16;

    final signed = await service.publishProfile(jsonEncode(profile));
    if (signed == null) return false;

    // Update local identity nym + user profile.
    if (name != null && name.isNotEmpty) {
      identity.nym = getNymFromPubkey(name, identity.pubkey);
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
        if (found.isNotEmpty) {
          for (final entry in found.entries) {
            final ev = entry.value;
            if (ev.isEmpty) continue; // cache hit, no event payload
            try {
              appState.ingestEvent(NostrEvent.fromJson(ev));
            } catch (_) {}
          }
          missing = pubkeys
              .where((pk) => !found.containsKey(pk.toLowerCase()))
              .toList();
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

  /// Persists the per-conversation read watermark (`nym_channel_last_read`) as a
  /// JSON object so a relaunch's D1 backfill doesn't re-count already-read
  /// history as unread (PWA `channelLastRead`, channels.js:1709-1735).
  void _persistChannelLastRead() {
    _ref.read(keyValueStoreProvider).setString(
          StorageKeys.channelLastRead,
          jsonEncode(_ref.read(appStateProvider.notifier).channelLastRead),
        );
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
    if (entry.isEmpty || !entry.first.isGeohash) return;
    _service?.subscribeChannelTyping(entry.first.geohash);
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
      ]);
      appState.hydrateTrustSets(trust[0], trust[1], trust[2]);
    } catch (e) {
      debugPrint('hydrateFromCache failed: $e');
    }
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
            await cache.saveChannelMessages(key, _capChannel(msgs), txn);
          }
        }
        for (final key in pmKeys) {
          final msgs = state.messages[key];
          if (msgs != null) {
            // Transient Nymbot info bubbles never persist (the PWA's
            // `_displayBotInfoMessage`/help/welcome rows are display-only —
            // pms.js persists real messages via `persistPMMessages` but never
            // these synthetic ids).
            final persistable = msgs
                .where((m) =>
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
    _storageSync = sync;
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
      _persistChannelLastRead();
      syncSettings();
    };

    // Publish the per-group cross-device categories (`nymchat-groups` /
    // `nymchat-keys-<gid>` / `nymchat-history-<gid>`) whenever the group store
    // mutates — a group created/joined, a message ingested, a control applied —
    // mirroring the PWA's `_debouncedNostrSettingsSave()` peppered through every
    // `groups.js` mutation. Routes through the same 5s-debounced `syncSettings`
    // as every other synced change; `_flushSettingsSync` publishes the group
    // categories alongside the settings sections. Content-hash dedup means an
    // unchanged group is a no-op.
    _ref.read(appStateProvider.notifier).onGroupStoreChanged = syncSettings;
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
    switch (view.kind) {
      case ViewKind.channel:
        unawaited(_backfillChannelArchive(view.id));
        // Catch up read receipts for messages already loaded in this channel
        // (PWA `openChannel` → `markVisibleChannelMessagesRead`). Newly
        // backfilled messages are receipted as they ingest in `_onEvent`.
        markVisibleChannelMessagesRead();
      case ViewKind.group:
        unawaited(_backfillGroupArchive());
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
  Future<void> _backfillChannelArchive(String channelKey) async {
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
    final run = _runChannelBackfill(name, channelKey, sync);
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
      String name, String channelKey, StorageSync sync) async {
    try {
      // FORCE the fetch, bypassing channelGet's 60s freshness window — this is an
      // explicit channel OPEN/boot, which the PWA always forces
      // (`channelRestoreFromD1(geohash || channel, { force: true })` in
      // `switchChannel`, channels.js:1264, and the boot landing-channel switch,
      // relays.js:1066). Without `force` a prior probe (or a FAILED earlier
      // attempt — `channelGet` marks `_channelFetchedAt` BEFORE the request and
      // doesn't unmark on error) would suppress the boot/open restore for 60s,
      // leaving #nymchat empty with no retry. `_channelBackfillInFlight` still
      // de-dups concurrent calls for the same channel.
      //
      // TIME-BOUND the fetch (10s → empty): an orphaned socket request must not
      // pin the in-flight slot until the transport's own 45s timeout — the PWA
      // fails a pending request the moment its socket closes, so the next
      // trigger (reconnect edge / view reopen) retries immediately. The empty
      // result reads as "produced nothing", which is exactly what tells a
      // concurrent waiter to re-run.
      final events = await sync.channelGet([name], force: true).timeout(
            const Duration(seconds: 10),
            onTimeout: () => const <Map<String, dynamic>>[],
          );
      final appState = _ref.read(appStateProvider.notifier);
      for (final raw in events) {
        try {
          appState.ingestEvent(NostrEvent.fromJson(raw));
        } catch (_) {
          // Skip a malformed archived event (mirrors the PWA's per-event catch).
        }
      }
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

  /// Boot-time sync: merge cross-device encrypted settings (honoring
  /// `nym_last_settings_sync_ts`), then restore the PM backlog from D1 for
  /// durable identities (gated by `cachePMs`). Both best-effort.
  Future<void> _bootStorageSync() async {
    final sync = _storageSync;
    if (sync == null) return;
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
    // shop.js:358). Local-key only (remote signers can't auth the read).
    final id = _identity;
    if (id != null && id.privkey != null) {
      unawaited(_ref.read(shopControllerProvider.notifier).loadFromServer(
          ShopIdentity(pubkey: id.pubkey, privkey: id.privkey)));
      // Finalize any shop purchase that settled while the app was closed (the
      // PWA fires `reconcilePendingPurchases` on connect, relays.js:490).
      unawaited(_reconcileShopPurchases());
    }
  }

  // --- Shop NIP-57 receipt fallback (shop.js `_listenForShopReceipt`) --------

  Subscription? _shopReceiptSub;
  Timer? _shopReceiptTimer;
  Completer<bool>? _shopReceiptCompleter;

  /// Fallback payment detection for a shop buy whose invoice has neither a
  /// LUD-21 `verify` nor a `serverVerify` URL (shop.js:1483-1511
  /// `_listenForShopReceipt` + zaps.js:1181-1189): REQ `kinds:[9735]`,
  /// `#p:[bot pubkey]`, `since: now-60`, `limit: 25`, and match the receipt's
  /// `bolt11` tag against the invoice [bolt11] (case-insensitive). Completes
  /// `true` when the matching receipt lands, `false` on the 180s timeout (the
  /// modal then shows the "Payment not detected yet" status). A new call
  /// replaces any previous wait; [clearShopReceiptWait] cancels it (modal
  /// closed / verify path took over).
  Future<bool> listenForShopReceipt(String bolt11) {
    clearShopReceiptWait();
    final completer = Completer<bool>();
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
        clearShopReceiptWait(result: true);
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
  /// [listenForShopReceipt] future (defaults to false = not detected).
  void clearShopReceiptWait({bool result = false}) {
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
  /// connect + foreground from relays.js:490). Local-key identities only (the
  /// claim needs NIP-98 auth). Best-effort.
  Future<void> _reconcileShopPurchases() async {
    final id = _identity;
    if (id == null || id.privkey == null) return;
    try {
      await _ref.read(shopControllerProvider.notifier).reconcilePendingPurchases(
            ShopIdentity(pubkey: id.pubkey, privkey: id.privkey),
            gifterNym: id.nym,
          );
    } catch (_) {
      // Left for the next foreground (shop.js:1412).
    }
  }

  /// `settings-get` → merge into the local [Settings] when the remote blob is
  /// newer than the stored sync ts (settings.js `settingsLoadFromD1`).
  Future<void> _mergeRemoteSettings(StorageSync sync) async {
    try {
      final result = await sync.settingsGet();
      if (result == null) return;
      // N26 inbound: merge the cross-device notification read-state additively
      // (idempotent) BEFORE the settings ts gate — a notification read on another
      // device clears its badge here even if no settings section changed
      // (app.js:5760, `seenNotifications` → `_mergeSeenNotifications`).
      final notif = result.notificationsPayload;
      if (notif != null) {
        final seen = notif['seenNotifications'];
        if (seen is Map) {
          _ref
              .read(notificationHistoryProvider.notifier)
              .mergeSeenNotifications(seen);
        }
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
      final kv = _ref.read(keyValueStoreProvider);
      final lastTs = int.tryParse(
              kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ??
          0;
      // The stored ts is in seconds (PWA); newestTs is ms. Compare in seconds.
      final newestSec = result.newestTs ~/ 1000;
      if (newestSec <= lastTs) return;
      // `_applySyncedSettings` now persists the monotonic `encryptAtRestPreferred`
      // hint itself (every apply path, matching the PWA's `applyNostrSettings`),
      // so the merge path no longer needs a separate copy.
      _applySyncedSettings(result.payload);
      kv.setString(StorageKeys.lastSettingsSyncTs, '$newestSec');
    } catch (_) {
      // Best-effort.
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
    final appState = _ref.read(appStateProvider.notifier);

    // 1) Group conversations → membership/metadata.
    final conversations = result.groupConversations;
    if (conversations != null) {
      conversations.forEach((gid, data) {
        if (data is Map) {
          try {
            appState.applyGroupConversationSync(
                gid, data.cast<String, dynamic>());
          } catch (_) {
            // Skip a malformed group entry.
          }
        }
      });
    }

    // 2) Ephemeral keys → decryption. Merge into the manager, re-arm the
    // service's unwrap candidates, and backfill history for any new self keys.
    final groups = _groups;
    final ek = result.groupEphemeralKeys;
    var keysAdded = false;
    if (groups != null && ek.isNotEmpty) {
      ek.forEach((gid, entry) {
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
    final history = result.groupMessageHistory;
    if (history.isNotEmpty) {
      try {
        appState.applyGroupHistorySync(history);
      } catch (_) {
        // Best-effort.
      }
    }

    // Recover group messages OTHER members sent to our newly-restored ephemeral
    // keys from the D1 ephemeral inbox (PWA `_recoverEphemeralHistory(newPks)`).
    if (keysAdded) unawaited(_backfillGroupArchive());
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
        c.setPinnedLandingChannel(jsonEncode(landing));
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
    // Channel lists (app.js:6350-6389). The PWA replaces each set + registers
    // joined channels; apply additively into the live registry (restoring them
    // on a fresh device) and persist the KV lists. Migrate the legacy default
    // key 'nym' → 'nymchat' like the PWA (app.js:6364).
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
    // Closed-PM / left-group read state. closedPMs is additive and closedPMTimes
    // is a per-key monotonic-max merge (app.js:6535-6547): a PM closed on any
    // device stays closed everywhere, and the newest close time wins.
    // -----------------------------------------------------------------------
    final closedPmTimes = <String, int>{};
    final rawClosedTimes = p['closedPMTimes'];
    if (rawClosedTimes is Map) {
      rawClosedTimes.forEach((k, v) {
        final t = v is num ? v.toInt() : int.tryParse('$v');
        if (t != null && t > 0) closedPmTimes['$k'] = t;
      });
    }
    final closedPMs = p['closedPMs'];
    if (closedPMs is List) {
      try {
        final existingTimes = appState.closedPmTimes;
        final existingClosed = appState.closedPMs;
        for (final raw in closedPMs.whereType<String>()) {
          if (raw.isEmpty) continue;
          final incomingTs = closedPmTimes[raw] ??
              (DateTime.now().millisecondsSinceEpoch ~/ 1000);
          final curTs = existingTimes[raw] ?? 0;
          // Additive close; only (re)stamp the time when strictly newer so the
          // monotonic close/reopen ordering is preserved.
          if (!existingClosed.contains(raw) || incomingTs > curTs) {
            appState.closePM(raw, nowSec: incomingTs);
          }
        }
      } catch (_) {}
    }

    // Left-group state (app.js:6549-6561). The native group store has no public
    // "mark left" / boot-hydrate path (see app_state `_leftGroups`), so this
    // persists the KV the PWA writes (`_saveLeftGroups` + `nym_left_group_times`)
    // — enabling the outbound round-trip and a future boot hydrator — with a
    // per-key monotonic-max merge for the leave times.
    final leftGroups = p['leftGroups'];
    if (leftGroups is List) {
      try {
        final merged = _readSet(_kLeftGroupsKey)
          ..addAll(leftGroups.whereType<String>().where((s) => s.isNotEmpty));
        _persistSet(_kLeftGroupsKey, merged);
      } catch (_) {}
    }
    final rawLeftTimes = p['leftGroupTimes'];
    if (rawLeftTimes is Map) {
      try {
        final merged = <String, int>{};
        final existing =
            _ref.read(keyValueStoreProvider).getString(StorageKeys.leftGroupTimes);
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
    // group (app.js:6692-6712). Reads back from the KV we just wrote so it
    // covers both the leftGroups and leftGroupTimes branches above.
    if (leftGroups is List || rawLeftTimes is Map) {
      _hydrateLeftGroups(appState);
    }

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

  /// Debounced encrypted-settings publish (`_debouncedNostrSettingsSave`, 5s).
  /// Call after any synced-setting change. No-op when storage sync is
  /// unavailable, or for an EPHEMERAL identity running in 'random'/'hardcore'
  /// keypair mode (`saveSyncedSettings`, settings.js:54-61 — the keypair
  /// changes every session/message, so publishing settings-set rows under each
  /// throwaway pubkey would be useless; the hardcore warning even promises
  /// "Settings will not sync across devices").
  void syncSettings() {
    final sync = _storageSync;
    if (sync == null) return;
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
      await sync.settingsSet(
        _ref.read(settingsProvider),
        pinnedLandingChannelJson:
            _ref.read(settingsProvider.notifier).pinnedLandingChannelJson,
        // Seen-call map rides the `messaging` section so a call answered/
        // declined/missed on this device reflects on our others (calls.js
        // `_seenCallsForSync`, settings.js:152). F06-A3 outbound seam.
        seenCalls: _ref.read(callServiceProvider).seenCallsForSync(),
      );
      // N26 outbound: publish the cross-device notification read-state wrap (the
      // `nymchat-notifications` category) so a notification read/dismissed here
      // is silenced on our other devices (settings.js:559). No-op when unchanged.
      await sync.notificationsWrapSet(
        _ref
            .read(notificationHistoryProvider.notifier)
            .seenNotificationsForSync(),
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

    // Group conversation metadata (PWA `_buildGroupConversationsSync`).
    final conversations = <String, Map<String, dynamic>>{};
    for (final g in st.groups) {
      final data = _serializeGroupForSync(g);
      // Snapshot each member's cached kind-0 (nym + avatar) so a fresh device
      // shows names/avatars immediately on restore instead of "nym" while
      // relay profiles load (PWA `_saveGroupConversations` memberProfiles,
      // groups.js:323-335). Only members with a known nym or picture.
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
      conversations[g.id] = data;
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

  /// Serializes a [Group] for the `nymchat-groups` category, matching the PWA's
  /// `_buildGroupConversationsSync` (groups.js:337-355). Includes
  /// `allowMemberInvites` / `lastModTs` / `lastModEventId` — the PWA writes them
  /// into the group blob, and since the native client has no local group
  /// persistence this D1 blob is the ONLY restore path (same-device relaunch and
  /// cross-device), so dropping them would reset member-invite policy to `true`
  /// and lose moderation-dedup state on every launch. modLog is capped to the
  /// most recent 50 entries.
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
      'allowMemberInvites': g.allowMemberInvites,
      'inviteEnabled': g.inviteEnabled == true,
      'inviteEpoch': g.inviteEpoch,
      'metaUpdatedAt': g.metaUpdatedAt,
      'lastModTs': g.lastModTs,
      'lastModEventId': g.lastModEventId,
      'modLog': [for (final e in modLog) e.toJson()],
    };
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
      for (final raw in events) {
        try {
          final event = NostrEvent.fromJson(raw);
          if (!schnorr.verifyEvent(event)) continue;
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
  void _archiveGiftWrap(GiftWrapUnwrapped u) {
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
      // A self-key rotation on send must reach our other devices so they can
      // decrypt this message's wrap (the PWA saves after every group send,
      // groups.js:1298). Debounced + content-hash-deduped in `syncSettings`.
      syncSettings();
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
  bool isVerifiedBot(String pubkey) => pubkey == nymbotPubkey;

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

    // Channel context for the AI-aware commands (commands.js:46-191).
    var channelMessages = const <Map<String, dynamic>>[];
    var activeUsers = const <Map<String, dynamic>>[];
    const aiCommands = {'ask', 'summarize'};
    const memoryCommands = {'top', 'last', 'seen', 'who'};
    if (aiCommands.contains(cmd) || memoryCommands.contains(cmd)) {
      channelMessages = _botChannelMessages(state, storageKey,
          allChannels: memoryCommands.contains(cmd));
      activeUsers = _botActiveUsers(state, view.id,
          allUsers: memoryCommands.contains(cmd));
    }

    // The published user message (what the bot replies to).
    await _sendMessageContent(rawText);

    final identity = _identity;
    final senderNym = identity != null
        ? '${stripPubkeySuffix(identity.nym)}#${getPubkeySuffix(identity.pubkey)}'
        : null;

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
      debugPrint('Nymbot command failed: $e');
      _emitSystemMessage('Nymbot is unavailable right now.');
    }
  }

  /// Recent channel messages mapped to the worker's context shape
  /// (`{nym,pubkey,content,timestamp,isBot,channel}`, commands.js:121).
  List<Map<String, dynamic>> _botChannelMessages(
      AppState state, String storageKey,
      {required bool allChannels}) {
    final out = <Map<String, dynamic>>[];
    void mapList(String key, List<Message> msgs) {
      for (final m in msgs.where((m) => !m.spamGated).take(100)) {
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
      final msgs = state.messages[storageKey];
      if (msgs != null) mapList(storageKey, msgs);
    }
    out.sort((a, b) =>
        (a['timestamp'] as int).compareTo(b['timestamp'] as int));
    return out;
  }

  /// Active users in the channel mapped to the worker's context shape. The
  /// AI-command path ([allUsers] false) carries the user's active shop `flair`
  /// (comma-joined, `flair-` prefix stripped) and `style` (`style-` prefix
  /// stripped) from `getUserShopItems(pubkey)` (commands.js:154-160); the
  /// in-memory commands (top/last/seen/who) send bare `{nym,pubkey}` entries
  /// (commands.js:183-188).
  List<Map<String, dynamic>> _botActiveUsers(AppState state, String channelId,
      {required bool allUsers}) {
    final rawName =
        channelId.startsWith('#') ? channelId.substring(1) : channelId;
    final out = <Map<String, dynamic>>[];
    state.users.forEach((pubkey, user) {
      final inChannel = allUsers ||
          user.channels.any((c) =>
              c == rawName || c.startsWith(rawName) || rawName.startsWith(c));
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

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crypto/bech32_codec.dart' as bech32;
import '../core/crypto/key_format.dart'
    show normalizePrivkeyInput, normalizePubkeyInput;
import '../core/crypto/bitchat.dart' as bitchat;
import '../core/crypto/crypto_worker.dart' show CryptoWorker;
import '../core/crypto/gift_wrap.dart' as giftwrap;
import '../core/crypto/keys.dart' as keys;
import '../core/crypto/ml_kem.dart';
import '../core/crypto/native_schnorr.dart';
import '../core/crypto/pow.dart' as pow;
import '../core/crypto/pq.dart' as pq;
import '../core/crypto/schnorr.dart' as schnorr;
import '../core/constants/event_kinds.dart';
import '../core/constants/relays.dart';
import '../core/constants/storage_keys.dart';
import '../core/theme/nym_colors.dart';
import '../core/utils/nym_utils.dart';
import '../features/toasts/toast_center.dart';
import '../services/api/api_config.dart';
import '../features/calls/call_providers.dart';
import '../features/commands/action_rate_limit.dart';
import '../features/identity/pq_announcement_source.dart';
import '../features/identity/pq_registry.dart';
import '../features/identity/pq_root.dart';
import '../features/mesh/ghost_mode.dart';
import '../features/mesh/mesh_controller.dart';
import '../features/mesh/mesh_outbox.dart';
import '../features/commands/command_handler.dart';
import '../features/commands/command_i18n.dart';
import '../features/commands/command_registry.dart';
import '../features/emoji/custom_emoji.dart';
import '../features/dm_polls/dm_polls_providers.dart';
import '../features/accounts/account_host.dart';
import '../features/groups/group_logic.dart';
import '../features/group_tools/group_tools.dart';
import '../features/group_tools/group_tools_providers.dart';
import '../features/groups/group_manager.dart';
import '../features/groups/own_ephemeral_subscription.dart';
import '../features/groups/wrap_outbox.dart';
import '../features/i18n/i18n.dart';
import '../features/i18n/localization_service.dart';
import '../features/messages/format/nym_format.dart' show NymFormat;
import '../features/messages/archive_gate.dart';
import '../features/messages/trust_graph.dart';
import '../features/messages/media_fallbacks.dart';
import '../features/media_notes/media_note_stores.dart';
import '../features/media_notes/media_notes.dart' as media_notes;
import '../features/notifications/background_catch_up.dart';
import '../features/notifications/live_gap.dart';
import '../features/notifications/notification_routing.dart';
import '../features/notifications/self_reference.dart';
import '../features/notifications/notifications_service.dart';
import '../services/attest/attest_service.dart';
import '../services/filter/filter_packs.dart';
import '../services/notification_service.dart' show NotificationService;
import '../features/shop/shop_controller.dart';
import '../features/nymbot/bot_commands.dart';
import '../features/nymbot/nymbot_providers.dart';
import '../features/nymbot/nymbot_threads.dart';
import '../features/nymbot/anon_channel_bot.dart';
import '../features/p2p/p2p_models.dart';
import '../features/p2p/p2p_service.dart';
import '../features/pms/pm_logic.dart';
import '../features/pms/pm_support_tokens.dart';
import '../features/polls/poll_logic.dart';
import '../features/zaps/lnurl.dart';
import '../features/zaps/zap_archive.dart';
import '../features/zaps/zap_logic.dart';
import '../services/api/api_client.dart';
import '../services/api/storage_sync.dart';
import '../services/relay/relay_message.dart';
import '../services/nostr/event_provenance.dart';
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
import '../features/chat_tools/chat_tools.dart' as chat_tools;
import '../features/chat_tools/chat_tools_providers.dart';
import '../features/chat_tools/chat_tools_service.dart';
import '../features/chat_nav/chat_nav.dart';
import '../features/chat_nav/chat_nav_service.dart';
import '../features/chat_nav/chat_nav_providers.dart';
import '../features/chat_lock/chat_lock_providers.dart';
import '../features/identity/nip46_service.dart';
import '../features/identity/panic_wipe.dart';
import '../features/identity/vault_settings_modal.dart'
    show identityVaultProvider;
import '../services/nostr/event_mapper.dart';
import '../services/nostr/event_signer.dart';
import '../services/nostr/event_time_ceilings.dart';
import '../services/nostr/identity_service.dart';
import '../services/nostr/nostr_service.dart';
import '../services/nostr/nym_generator.dart';
import '../services/nostr/verified_rows.dart';
import '../services/storage/cache_store.dart';
import '../services/storage/key_value_store.dart';
import '../services/storage/sealed_key_value.dart';
import '../services/storage/secure_store.dart';
import 'app_state.dart';
import 'last_view.dart';
import 'settings_provider.dart';

/// Common channels seeded into the sidebar on connect; `nymchat` is named, the rest are geohashes.
const List<String> kCommonGeohashes = [
  'nymchat',
  '9q',
  'w2',
  'dr5r',
  '9q8y',
  'u4pr',
  'gcpv',
  'f2m6',
  'xn77',
  'tjm5',
];

/// A PM awaiting its delivery receipt, keyed by the stable `nymMessageId` since each re-send gets a fresh wrap id.
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

/// Ties identity, relays and crypto to the [AppState] store; composer sends flow through here.
class NostrController {
  NostrController(this._ref) {
    _rememberSyncedBaseline();
    _ref.read(appStateProvider.notifier).onGroupMembersEvicted =
        _onGroupMembersEvicted;
  }

  final Ref _ref;
  Identity? _identity;
  NostrService? _service;

  /// The live relay service, or null before boot.
  NostrService? get relayService => _service;

  GroupManager? _groups;
  EventSigner? _signer;
  bool _started = false;

  /// Cross-device storage sync; null before boot or without a signer; every call is best-effort.
  StorageSync? _storageSync;

  /// Zap-receipt D1 archive; null before boot.
  ZapArchive? _zapArchive;

  /// Id of the last own kind-0 mirrored to D1, so duplicate receipts and echoes don't re-POST it.
  String? _lastMirroredOwnProfileId;

  /// Full self kind-0 content so [saveProfile] can merge without dropping fields the app doesn't manage.
  Map<String, dynamic>? _cachedKind0Profile;
  int _cachedKind0Ts = 0;

  void _adoptSelfKind0(NostrEvent event) {
    if (event.createdAt < _cachedKind0Ts) return;
    try {
      final decoded = jsonDecode(event.content);
      if (decoded is Map) {
        _cachedKind0Profile = Map<String, dynamic>.from(decoded);
        _cachedKind0Ts = event.createdAt;
      }
    } catch (_) {
      // Malformed content: keep the previous cache.
    }
  }

  /// Whether the profile is worth mirroring to D1: durable logins always, ephemeral ones only with custom data.
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

  /// Mirrors our signed kind-0 to D1 when [_hasCustomProfileData]; deduped by event id; best-effort.
  void _mirrorOwnProfileToD1(NostrEvent event) {
    final sync = _storageSync;
    if (sync == null || !_hasCustomProfileData()) return;
    if (event.id.isEmpty || event.sig.isEmpty) return;
    if (event.id == _lastMirroredOwnProfileId) return;
    _lastMirroredOwnProfileId = event.id;
    unawaited(sync.profileSet(event.toJson()));
  }

  ApiClient? _api;

  /// The signed event behind [eventId] from the D1 archive, or null when never archived.
  Future<NostrEvent?> relayEvent(String eventId) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(eventId)) return null;
    final service = _service;
    if (service == null) return null;
    Subscription? sub;
    try {
      sub = service.pool.subscribe([
        NostrFilter(ids: [eventId], limit: 1)
      ]);
      return await sub.events
          .firstWhere((e) => e.id == eventId)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    } finally {
      if (sub != null) unawaited(sub.close());
    }
  }

  Future<bool> _verifyArchived(NostrEvent event) =>
      _service?.verifyEvent(event) ??
      Future<bool>.value(schnorr.verifyEvent(event));

  Future<NostrEvent?> archivedEvent(String eventId) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(eventId)) return null;
    try {
      final api = _api ??= ApiClient();
      final res = await api.storageAction(<String, dynamic>{
        'action': 'event-get',
        'ids': <String>[eventId],
      });
      final list = res['events'];
      if (list is! List || list.isEmpty) return null;
      final first = list.first;
      if (first is! Map) return null;
      final ev = NostrEvent.fromJson(Map<String, dynamic>.from(first));
      if (ev.id != eventId) return null;
      return await _verifyArchived(ev) ? ev : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> editHistoryEvents(
      String surface, String id, int at) async {
    if (surface == 'channel') {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) return const [];
      final api = _api ??= ApiClient();
      final res = await api.storageAction(
          <String, dynamic>{'action': 'channel-edits', 'id': id});
      final list = res['events'];
      final rows = <Map<String, dynamic>>[
        if (list is List)
          for (final e in list)
            if (e is Map) Map<String, dynamic>.from(e),
      ];
      final ok = await verifiedRows(rows, _verifyArchived);
      return [
        for (final e in ok)
          if (e.kind == 20000 || e.kind == 23333) e.toJson(),
      ];
    }
    final sync = _storageSync;
    final service = _service;
    if (sync == null || service == null) throw StateError('no archive');
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    Future<void> scan(List<String>? pubkeys) async {
      var from = max(0, at - chat_tools.ChatToolsLimits.editFetchSlackSec);
      for (var i = 0; i < chat_tools.ChatToolsLimits.editFetchPages; i++) {
        final wraps = await sync.pmScanForward(
            since: from,
            limit: chat_tools.ChatToolsLimits.editFetchPageSize,
            pubkeys: pubkeys);
        final probes = <Future<GiftWrapUnwrapped?>>[];
        for (final w in wraps) {
          if (!seen.add('${w['id']}')) continue;
          probes.add(Future<GiftWrapUnwrapped?>.sync(
                  () => service.probeArchivedWrap(NostrEvent.fromJson(w)))
              .catchError((Object _) => null));
        }
        for (final u in await Future.wait(probes)) {
          if (u != null && u.senderVerified) out.add(u.rumor);
        }
        final last = wraps.isEmpty
            ? 0
            : ((wraps.last['created_at'] as num?)?.toInt() ?? 0);
        if (wraps.length < chat_tools.ChatToolsLimits.editFetchPageSize ||
            last <= from) {
          return;
        }
        from = last;
      }
    }

    Future<bool> attempt(List<String>? pubkeys) =>
        scan(pubkeys).then((_) => true, onError: (_) => false);
    final ephPks = surface == 'group'
        ? (_groups?.allEphemeralPubkeys() ?? const <String>[])
        : const <String>[];
    final jobs = <Future<bool>>[
      if (sync.durableIdentity) attempt(null),
      if (ephPks.isNotEmpty) attempt(ephPks),
    ];
    if (jobs.isEmpty) throw StateError('no archive');
    final done = await Future.wait(jobs);
    if (!done.contains(true)) throw StateError('archive unavailable');
    return out;
  }

  /// Debounce for the encrypted settings publish (5s).
  Timer? _settingsSyncTimer;

  /// Debounce for the local group-store and read-watermark persist; each prefs write rewrites the whole file.
  Timer? _groupStorePersistTimer;
  Timer? _channelLastReadPersistTimer;

  /// pubkey/groupId → last typing-start send time (ms).
  final Map<String, int> _typingThrottle = {};

  /// Minimum gap between typing-start broadcasts.
  static const int _typingSendIntervalMs = 12000;
  static const int _typingStartDebounceMs = 1500;
  static const int _typingTtlSec = 15;
  static const int _typingStopDelayMs = 4000;
  final Map<String, Timer> _typingStartTimers = {};
  final Map<String, Timer> _typingStopTimers = {};
  final Set<String> _typingStartedFor = <String>{};

  /// `messageId:emoji` → toggle rate-limit state: 3 toggles per 30s, then a 60s cooldown.
  final Map<String, _ReactionRateTracker> _reactionToggleTracker = {};

  /// Persisted message/profile/reaction cache; null until [init].
  CacheStore? _cache;
  Timer? _flushTimer;

  // Live events buffered for one turn and replayed inside [AppStateNotifier.runBatched] so a burst costs one rebuild.
  final List<NostrEvent> _liveInboundBuffer = <NostrEvent>[];
  Timer? _liveInboundTimer;

  /// Reaching this cap flushes immediately.
  static const int _kLiveInboundFlushCap = 512;

  final Set<String> _dirtyChannelKeys = {};
  final Set<String> _dirtyPmKeys = {};
  bool _flushScheduled = false;

  /// Runtime cache caps, matching app.js.
  static const int _channelMessageLimit = 1000;
  static const int _pmStorageLimit = 1000;

  Identity? get identity => _identity;
  bool get isLive => _identity != null;

  /// The active signer ([LocalSigner] or [Nip46SignerAdapter]), or null before boot.
  EventSigner? get signer => _signer;

  /// Exposed so the NIP-46 transport can ride the connected pool.
  PoolTransport? get pool => _service?.pool;

  /// Per-relay connection status for the stats modal; empty before boot.
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

  /// Pool-wide relay stats for the stats modal; null before boot.
  RelayStats? get relayStats => _service?.relayStats;

  bool get isProxyMode => _service?.isProxyMode ?? true;

  bool get isProxyFallbackActive => _service?.isFallbackActive ?? false;

  bool get isUserDirectMode =>
      _service?.isUserDirect ??
      _ref.read(keyValueStoreProvider).getBool(StorageKeys.relayDirectMode);

  bool get canSwitchRelayTransport => _service?.canSwitchTransport ?? false;

  bool get isProxyRetryInFlight => _service?.isProxyRetryInFlight ?? false;

  bool get relayDirectAcknowledged =>
      _ref.read(keyValueStoreProvider).getBool(StorageKeys.relayDirectAck);

  void acknowledgeRelayDirect() {
    unawaited(_ref
        .read(keyValueStoreProvider)
        .setBool(StorageKeys.relayDirectAck, true));
  }

  Future<void> setUserDirectMode(bool direct) async {
    final kv = _ref.read(keyValueStoreProvider);
    if (direct) {
      await kv.setBool(StorageKeys.relayDirectMode, true);
    } else {
      await kv.remove(StorageKeys.relayDirectMode);
    }
    final svc = _service;
    if (svc == null) return;
    await svc.setUserDirect(direct);
    _ref.read(appStateProvider.notifier).setProxyMode(svc.isProxyMode);
    _refreshEphemeralSubscriptions();
  }

  void retryProxyNow() => _service?.retryProxyNow();

  /// Surfaces command feedback in the active conversation; defaults to a debug print.
  void Function(String text)? _systemMessageSink;

  late final CommandDispatcher _dispatcher = CommandDispatcher(
    engine: _CommandEngineAdapter(this),
    hooks: const CommandHooks(),
    rateLimiter: ActionCommandRateLimiter(),
  );

  /// Registers the system-message sink and command modal hooks.
  void setCommandHooks({
    void Function(String text)? onSystemMessage,
    CommandHooks? hooks,
  }) {
    if (onSystemMessage != null) _systemMessageSink = onSystemMessage;
    if (hooks != null) _dispatcher.hooksOverride = hooks;
  }

  void showSystemNotice(String text) => _emitSystemMessage(text);

  void _emitSystemMessage(String text) {
    final sink = _systemMessageSink;
    if (sink != null) {
      sink(localizeCommandTokensIn(text));
    } else {
      showToast(localizeCommandTokensIn(text));
    }
  }

  void _emitFeedMessage(String text) => _ref
      .read(appStateProvider.notifier)
      .addSystemMessage(localizeCommandTokensIn(text));

  /// Boots the identity and connects; [unlockedSecrets] holds decrypted vault secrets so the at-rest blob isn't read.
  Future<void> init({Map<String, String>? unlockedSecrets}) async {
    if (_started) return;
    _started = true;
    // Re-arm the hydration gate synchronously, before any await, so the shell can defer the tutorial on it.
    if (_settingsHydratedC.isCompleted) {
      _settingsHydratedC = Completer<void>();
    }
    // Load native secp256k1 for the main isolate's inline verify calls; falls back to pure Dart until loaded.
    unawaited(NativeSchnorr.ensureLoaded());
    try {
      final kv = _ref.read(keyValueStoreProvider);
      final bootView =
          BootViewRestore(_ref.read(appStateProvider.notifier), kv);
      // `secretWrite` keeps post-boot secret writes vault-encrypted instead of plaintext.
      final identityService = IdentityService(
        kv: kv,
        secure: SecureStore(),
        secretWrite: _ref.read(identityVaultProvider).secretSet,
      );

      // PQ policy must resolve before the first send; its first-boot default depends on whether this is an upgrade.
      _loadPqSettings();

      // NIP-46 login restores the remote-signer session; nsec/ephemeral boot through IdentityService.
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
          signer =
              identity.privkey != null ? LocalSigner(identity.privkey!) : null;
        }
      } else {
        identity = await identityService.boot(unlockedSecrets: unlockedSecrets);
        signer =
            identity.privkey != null ? LocalSigner(identity.privkey!) : null;
      }
      _identity = identity;
      _signer = signer;

      // Load the PQ root (PQ-ROOT-SPEC §5.3) before anything derives a key; it arrives via [unlockedSecrets].
      await _loadPqRoot(unlockedSecrets: unlockedSecrets);
      await _seedNewKeyPqRoot(identity,
          freshKey: identityService.generatedFreshKey);

      // Durable logins seed the nym from the cached login profile, never the boot chain's ephemeral nick.
      if (identity.loginMethod != null) {
        identity.nym = getNymFromPubkey(
            _cachedLoginProfileName(kv) ?? 'nym', identity.pubkey);
      }

      await _loadLeftGroupStore();
      final appState = _ref.read(appStateProvider.notifier);
      bootView.beforeGoLive();
      appState.goLive(identity.pubkey, identity.nym);
      bootView.afterGoLive();

      _hydrateSocialState(appState);
      _wireAutoMute(appState);
      // Restore closed PMs so deleted conversations don't resurrect on relaunch.
      _hydrateClosedPMs(appState);
      // Restore left groups so they stay suppressed on relaunch.
      _hydrateLeftGroups(appState);
      _pmSupportStore();
      // Restore read watermarks so the relaunch backfill isn't counted as unread.
      _hydrateChannelLastRead(appState);
      // Instantiate eagerly so recents hydrate at boot rather than on the first long-press.
      _ref.read(recentEmojisProvider);
      // Seed the badge's blocked-sender exclusion.
      _ref
          .read(notificationHistoryProvider.notifier)
          .setBlocked(_ref.read(appStateProvider).blockedUsers);

      // Seed the spam-filter module globals once; nothing changes them at runtime.
      final settings = _ref.read(settingsProvider.notifier);
      appSpamFilterEnabled = settings.spamFilterEnabled;
      appSpamFilterAggressive = settings.spamFilterAggressive;
      // The settings toggle updates this live; seed it at boot.
      appThreadsEnabled = _ref.read(settingsProvider).threadsEnabled;
      // Unlike the spam flags this has settings UI, so it's also refreshed on save.
      appPowFilterBits = pow.normalizePowDifficulty(settings.powDifficulty);
      appVerifiedFilter = settings.appVerifiedFilter;
      unawaited(FilterPacks.setActive(settings.filterPacks));

      // Scopes the per-identity image-blur read.
      settings.activePubkey = identity.pubkey;

      // Keypair-mode side effects on the session nsec; skipped for durable logins.
      settings.onKeypairModeChanged = _onKeypairModeChanged;

      // Mirror Low Data Mode onto the relay layer whenever it flips, including via sync.
      settings.onLowDataModeChanged =
          (enabled) => unawaited(_service?.setLowDataMode(enabled));

      // Flip the critical REQ's channel-mode gate; the resubscribe is debounced.
      settings.onGroupChatPMOnlyModeChanged =
          (enabled) => _service?.updateCriticalInputs(channelMode: !enabled);

      // Hydrate the persisted NIP-30 cache at boot.
      _ref.read(liveCustomEmojiProvider);

      // Hydrate caches before connecting so the replay doesn't redo history; the timeout only guards a broken disk.
      await _hydrateFromCache(appState).timeout(
        const Duration(seconds: 10),
        onTimeout: () {},
      );

      // Mirror a cached own name onto the identity before the first presence broadcast.
      _syncSelfNymFromProfile();

      final poolFactory = debugPoolFactory;
      final service = NostrService(
        identity: identity,
        signer: signer,
        pool: poolFactory?.call(),
        userDirect: _ref
            .read(keyValueStoreProvider)
            .getBool(StorageKeys.relayDirectMode),
      );
      _service = service;
      service.pqPeerKey = _pqLayeredPeerKey;
      service.pqSelfKey = pqSelfKey;
      service.pqSelfLayered = pqSelfUsesLayered;
      final attest =
          _attest ??= AttestService(kv: _ref.read(keyValueStoreProvider));
      appAttestAuthority = attest.authorityPubkey;
      final selfPubkey = signer?.pubkey;
      if (selfPubkey != null && attest.restore(selfPubkey)) {
        service.attestBadge = attest.badge;
      }
      unawaited(_ensureAttestBadge());
      _groups = GroupManager(service)
        ..onSelfKeysChanged = _ensureOwnEphemeralSub
        ..onWrap = _archiveSentWrap;
      // Restore groups and ephemeral keys before network I/O so an offline launch can still decrypt group wraps.
      await _hydrateGroupStore();
      final restoredView = bootView.apply();
      if (restoredView?.kind == ViewKind.channel) _persistJoinedChannels();
      // Seed Low Data Mode before the relay layer shards its geo relays.
      if (_ref.read(settingsProvider).lowDataMode) {
        unawaited(service.setLowDataMode(true));
      }
      // Critical REQ inputs from the hydrated caches, kept fresh via updateCriticalInputs.
      final bootState = _ref.read(appStateProvider);
      await service.start(
        NostrHandlers(
          onEvent: _enqueueLiveEvent,
          onConnectionChanged: _onConnectionChanged,
          onGiftWrap: _onGiftWrap,
          onEventRetracted: _onEventRetracted,
          onShardLost: _onShardLost,
          onShardReconnected: _onShardReconnected,
        ),
        channelMode: !_ref.read(settingsProvider).groupChatPMOnlyMode,
        vouchAuthors: bootState.nymchatPubkeys,
        profileAuthors: [
          for (final c in bootState.pmConversations) c.pubkey,
        ],
        pqAuthors: _pqAuthorList(),
      );

      // Live gift-wrap REQ over restored ephemeral keys, since the main `#p` filter only carries the self pubkey.
      _refreshEphemeralSubscriptions();

      // The boot channel skips [switchChannel], so subscribe its typing/receipt feed here.
      _subscribeActiveChannelTyping();

      // Presence is event-driven only (no heartbeat), so idle users decay to offline.
      recordOwnActivity();

      // Seed the sidebar with the common channels.
      discoverChannels();

      // No-op on boot; kept for the one-hop vouch expansion.
      _subscribeVouches();

      // New PM contacts join the critical REQ's kind-0 filter; the service debounces bursts.
      _ref.read(appStateProvider.notifier).onPMConversationAdded = (_) {
        final svc = _service;
        if (svc == null) return;
        svc.updateCriticalInputs(
          profileAuthors: [
            for (final c in _ref.read(appStateProvider).pmConversations)
              c.pubkey,
          ],
          pqAuthors: _pqAuthorList(),
        );
      };

      // Durable (logged-in) identities also use the PM archive; best-effort.
      _initStorageSync(identity, signer);
      // Resolve the seal policy before anything saves; a single-device account must not keep the default.
      unawaited(_pqDeviceId().then((_) => _refreshPqSealPolicy()));
      unawaited(_bootStorageSync());

      // Restore our own profile (D1 first, relay fallback) so the header shows our real nym and avatar.
      unawaited(resolveProfiles([identity.pubkey])
          .then((_) => _syncSelfNymFromProfile()));

      // Backfill the active channel's archive on boot; must run after `_storageSync` is wired.
      final openView = _ref.read(appStateProvider).view;
      if (restoredView != null && openView == restoredView) {
        _onViewOpened(openView);
        if (openView.kind == ViewKind.channel &&
            isChannelGeohash(openView.id)) {
          unawaited(_service?.connectGeoRelaysForGeohash(openView.id) ??
              Future.value());
        }
      } else if (openView.kind == ViewKind.channel) {
        unawaited(_backfillChannelArchive(openView.id));
      }

      // Discover channels and restore every channel's archive up front; arm the reconnect throttle so it doesn't repeat.
      _lastD1BackfillAt = DateTime.now().millisecondsSinceEpoch;
      unawaited(_restoreAllChannelArchives());
      // A killed session can return with a full outbox and no reconnect edge, so flush once here.
      unawaited(flushMeshOutbox());
    } catch (e, st) {
      // Never strand the user on seed data: force the empty shell if we never went live.
      debugPrint('NostrController.init failed: $e\n$st');
      if (_identity == null) {
        try {
          _ref.read(appStateProvider.notifier).reset();
        } catch (_) {}
      }
      _emitSystemMessage(tr('Connection failed — working offline.'));
      // A failed boot must still release the onboarding gate.
      _markSettingsHydrated();
    }
  }

  /// Seeds the common geohash channels; skipped in group/PM-only mode; idempotent.
  void discoverChannels() {
    if (_ref.read(settingsProvider).groupChatPMOnlyMode) return;
    final app = _ref.read(appStateProvider.notifier);
    for (final g in kCommonGeohashes) {
      if (g == 'nymchat') continue;
      app.addChannel(g, geohash: g);
    }
  }

  /// Throttled D1 activity refresh for the globe; safe to call every tick.
  Future<void> refreshGeohashActivity() => _discoverChannelActivity();

  void _onEventRetracted(String eventId) {
    _ref.read(appStateProvider.notifier).retractMessage(eventId);
  }

  void _onShardLost(int lastLiveAtMs) {
    _liveGap.note(lastLiveAtMs: lastLiveAtMs);
  }

  void _onShardReconnected() {
    if (_liveGap.pending) unawaited(_catchUpLiveGap());
  }

  void _onConnectionChanged(int count) {
    final wasOffline = _ref.read(appStateProvider).connectedRelays == 0;
    _ref.read(appStateProvider.notifier).setConnectedRelays(count);
    final svc = _service;
    if (svc != null) {
      _ref.read(appStateProvider.notifier).setProxyMode(svc.isProxyMode);
    }
    if (count == 0 && !wasOffline) _liveGap.note();
    if (count > 0 && wasOffline) {
      // Reconnect edge: re-run the full D1 backfill, since relay REQs only carry new events.
      if (_liveGap.pending) {
        unawaited(_catchUpLiveGap());
      } else {
        unawaited(_backfillFromD1OnReconnect());
      }
      // Re-send PMs still waiting on a receipt.
      _retryPendingDmsOnReconnect();
      // Publish what the mesh carried while offline.
      unawaited(flushMeshOutbox());
      _chatNavReconnect();
      // Driven by the connection edge, not the backfill, so failures there can't skip it.
      schedulePqAnnouncement();
    }
  }

  Timer? _pqAnnounceTimer;

  /// Schedules our capability announcement after connecting; idempotent and throttled by [pqRepublishInterval].
  void schedulePqAnnouncement() {
    if (_pqAnnounceTimer != null) return;
    // Long enough for our existing announcement to arrive, so the device roster merges instead of clobbering it.
    _pqAnnounceTimer = Timer(const Duration(seconds: 3), () {
      _pqAnnounceTimer = null;
      if (_service == null || _identity == null) return;
      unawaited(publishPqAnnouncement());
      unawaited(_ensureAttestBadge());
    });
  }

  AttestService? _attest;

  AttestService? get attest => _attest;

  Future<void> _awaitAttestBadge() async {
    final service = _service;
    final attest = _attest;
    if (service == null || attest == null) return;
    if (service.attestBadge != null) return;
    final pending = attest.inFlight;
    if (pending == null) return;
    await pending.timeout(const Duration(seconds: 8), onTimeout: () {});
    service.attestBadge = attest.badge;
  }

  /// Enrolls or renews this install's attestation badge; best-effort and silent when the device can't attest.
  Future<void> _ensureAttestBadge() async {
    final service = _service;
    final signer = service?.signer;
    if (service == null || signer == null) return;
    final attest =
        _attest ??= AttestService(kv: _ref.read(keyValueStoreProvider));
    appAttestAuthority = attest.authorityPubkey;
    await attest.ensureBadge(signer);
    service.attestBadge = attest.badge;
    appAttestAuthority = attest.authorityPubkey;
  }

  /// Last reconnect backfill run (ms), for the 30s throttle.
  int _lastD1BackfillAt = 0;

  final LiveGap _liveGap = LiveGap();
  int _liveGapSinceSec = 0;

  Future<void> _catchUpLiveGap() => _liveGap.run((sinceSec) async {
        _catchUpGiftWraps(sinceSec);
        if (_storageSync == null) return false;
        _lastD1BackfillAt = 0;
        _lastActivityDiscoveryAt = 0;
        _liveGapSinceSec = sinceSec;
        try {
          await _backfillFromD1OnReconnect();
          await _restoreAllChannelArchives(force: true, sinceSec: sinceSec);
        } finally {
          _liveGapSinceSec = 0;
        }
        return true;
      });

  final Map<String, int> _gapWrapFloors = <String, int>{};

  void _catchUpGiftWraps(int floorSec) {
    final service = _service;
    if (service == null) return;
    final groups = _groups;
    service.catchUpGiftWraps(
      [
        ...?groups?.allEphemeralPubkeys(),
        ..._ref.read(ghostModeProvider).pubkeys,
        ..._anonBotPubkeys(),
      ],
      floorSec: floorSec,
      onWrap: (wrap) {
        if (wrap.id.isEmpty) return;
        _gapWrapFloors.remove(wrap.id);
        _gapWrapFloors[wrap.id] = floorSec;
        while (_gapWrapFloors.length > 2000) {
          _gapWrapFloors.remove(_gapWrapFloors.keys.first);
        }
      },
    );
  }

  ({bool stale, int? cutoffMs}) _gapWrapVerdict(GiftWrapUnwrapped u) {
    final floorSec = _gapWrapFloors.remove(u.wrapId);
    if (floorSec == null) return (stale: false, cutoffMs: null);
    final ts = (u.rumor['created_at'] as num?)?.toInt() ?? 0;
    if (!gapWrapIsFresh(rumorCreatedAtSec: ts, floorSec: floorSec)) {
      return (stale: true, cutoffMs: null);
    }
    return (stale: false, cutoffMs: floorSec * 1000 - 1);
  }

  /// Re-pulls the full D1 backlog on reconnect/resume, since relay REQs only carry new events; throttled and idempotent.
  Future<void> _backfillFromD1OnReconnect() async {
    final sync = _storageSync;
    if (sync == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastD1BackfillAt != 0 && now - _lastD1BackfillAt < 30000) return;
    _lastD1BackfillAt = now;
    // Retry a failed boot settings restore; a fresh device can only get groups and keys from it.
    if (_settingsGetFailed) {
      await _mergeRemoteSettings(sync);
    }
    // Reconnects drop server-side REQs, so re-arm the ephemeral gift-wrap subscription.
    _refreshEphemeralSubscriptions();
    await _restorePmArchive(sync);
    await _backfillGroupArchive();
    // Discovery plus archive restore over every current, joined and discovered channel.
    if (_liveGapSinceSec == 0) await _restoreAllChannelArchives();
    // Re-hydrate archived emoji packs that aged off relays on every reconnect.
    unawaited(_restoreEmojiFromD1(sync));
    // Profile zap receipts use a tight relay window, so re-pull them from D1 on every reconnect.
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
    // Rebuild the web of trust from D1; the critical REQ only carries the live tail.
    unawaited(_fetchVouchesFromD1(sync));
    // Re-exchange group keys if we were offline long enough for rotations to expire off relays.
    unawaited(_maybeSendGroupKeyResyncs());
    // Also scheduled off the connection edge, so a failure above can't cost us the announcement.
    schedulePqAnnouncement();
  }

  /// Rebuilds the web of trust from D1, verifying signatures and expanding iteratively; best-effort.
  Future<void> _fetchVouchesFromD1(StorageSync sync) async {
    List<Map<String, dynamic>> rows;
    try {
      // force: channelGet's 60s window must not skip this restore.
      rows = await sync.channelGet([AppDataTopic.vouches], force: true);
    } catch (_) {
      return;
    }
    final parsed = <NostrEvent>[];
    for (final raw in rows) {
      // The archive grows with the whole network, so cap it; live vouches still expand the graph.
      if (parsed.length >= _kVouchD1MaxEvents) break;
      try {
        final ev = NostrEvent.fromJson(raw);
        if (ev.kind != EventKind.appData) continue;
        parsed.add(ev);
      } catch (_) {
        // Skip a malformed archived row.
      }
    }
    if (parsed.isEmpty) return;
    // Verify the cohort off the main isolate in one batch; build every future this turn so they coalesce.
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
    // Coalesce the expansion's notifies into one rebuild.
    _ref.read(appStateProvider.notifier).runBatched(() {
      // Each vouch is applied at most once; the fixpoint is unchanged.
      final applied = <int>{};
      var changed = true;
      var guard = 0;
      while (changed && guard++ < 20) {
        final before = _ref.read(appStateProvider).nymchatPubkeys.length;
        for (var i = 0; i < valid.length; i++) {
          if (applied.contains(i)) continue;
          final ev = valid[i];
          // Not rooted yet; retry on a later pass.
          if (!_ref.read(appStateProvider).nymchatPubkeys.contains(ev.pubkey)) {
            continue;
          }
          applied.add(i);
          try {
            _ingestVouch(ev);
          } catch (_) {}
        }
        changed = _ref.read(appStateProvider).nymchatPubkeys.length != before;
      }
    });
  }

  /// Max vouch archive rows one rebuild ingests.
  static const int _kVouchD1MaxEvents = 5000;

  /// Max concurrent per-channel archive restores, so slow channels don't stall the rest.
  static const int _kChannelBackfillConcurrency = 4;

  /// Awaits discovery first so newly discovered channels are in the restore set and don't open empty; best-effort.
  Future<void> _restoreAllChannelArchives(
      {bool force = false, int sinceSec = 0}) async {
    await _discoverChannelActivity();
    if (_retired) return;
    final keys = <String>{
      for (final c in _ref.read(appStateProvider).channels) c.key,
    };
    final view = _ref.read(appStateProvider).view;
    if (view.kind == ViewKind.channel && view.id.isNotEmpty) keys.add(view.id);
    await _backfillChannelArchivesFor(keys, force: force, sinceSec: sinceSec);
  }

  /// Restores [keys] with bounded concurrency; [force] bypasses the per-channel 60s freshness window.
  Future<void> _backfillChannelArchivesFor(
    Iterable<String> keys, {
    bool force = false,
    int sinceSec = 0,
    void Function(NostrEvent event)? onRestored,
  }) async {
    final list = <String>{
      for (final k in keys)
        if (k.isNotEmpty) k,
    }.toList();
    if (list.isEmpty) return;
    var next = 0;
    Future<void> worker() async {
      while (next < list.length) {
        await _backfillChannelArchive(list[next++],
            force: force, sinceSec: sinceSec, onRestored: onRestored);
      }
    }

    final workerCount = _kChannelBackfillConcurrency < list.length
        ? _kChannelBackfillConcurrency
        : list.length;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
  }

  /// Last discovery run (ms) for the ~30s throttle; reset to 0 on failure so the next attempt retries.
  int _lastActivityDiscoveryAt = 0;

  /// Discovers active channels from D1 and seeds sidebar, recency and unread floors; throttled, best-effort.
  Future<void> _discoverChannelActivity() async {
    final sync = _storageSync;
    if (sync == null) return;
    if (_ref.read(settingsProvider).groupChatPMOnlyMode) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastActivityDiscoveryAt != 0 &&
        now - _lastActivityDiscoveryAt < 30000) {
      return;
    }
    _lastActivityDiscoveryAt = now;
    try {
      final app = _ref.read(appStateProvider.notifier);

      final known = <String>{...kCommonGeohashes};
      for (final c in _ref.read(appStateProvider).channels) {
        known.add(c.key);
      }
      for (final storageKey in _ref.read(appStateProvider).messages.keys) {
        if (storageKey.startsWith('#')) known.add(storageKey.substring(1));
      }

      // Failures already resolve to empty results.
      final results = await Future.wait([
        sync.channelActive(),
        sync.channelActiveNamed(),
        sync.channelActivity(known.toList()),
      ]);
      final geo = results[0];
      final named = results[1];
      final knownActivity = results[2];

      // Discovery buckets aren't spam-aware, so they never feed unread floors.
      app.applyChannelActivity(geo.activity, geo.last, geohash: true);
      app.applyChannelActivity(named.activity, named.last);
      // Spam-aware activity for known channels feeds unread floors.
      app.applyChannelActivity(knownActivity.activity, knownActivity.last,
          seedUnread: true);
    } catch (_) {
      // Allow the next trigger to retry.
      _lastActivityDiscoveryAt = 0;
    }
  }

  /// Restores a persisted NIP-46 session as an identity and signer; null when absent or reconnect fails.
  Future<(Identity, EventSigner)?> _restoreNip46Signer(KeyValueStore kv) async {
    try {
      final svc = _ref.read(nip46ServiceProvider);
      // Reuse a socket the login modal just connected; re-restoring would open a second one.
      if (!(svc.isConnected && svc.pubkey.length == 64)) {
        final ok = await svc.restoreSession();
        if (!ok || svc.pubkey.length != 64) return null;
      }
      final pubkey = svc.pubkey;
      final nym = kv.getString(StorageKeys.customNick) ??
          kv.getString(StorageKeys.autoEphemeralNick) ??
          NymGenerator().generate(pubkey,
              style: kv.getString(StorageKeys.nickStyle) ?? 'fancy');
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

  /// The cached login profile name for instant restore, or null.
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

  /// Mirrors our resolved kind-0 name onto the live [Identity] and the instant-restore cache; no-op without a name.
  void _syncSelfNymFromProfile() {
    final identity = _identity;
    if (identity == null) return;
    final profile = _ref.read(appStateProvider).users[identity.pubkey]?.profile;
    // Name chain name → username → display_name, capped at 20 chars.
    var name = profile?.name;
    if (name == null || name.isEmpty) name = profile?.displayName;
    if (name == null || name.isEmpty) return;
    if (name.length > 20) name = name.substring(0, 20);
    final nym = getNymFromPubkey(name, identity.pubkey);
    if (identity.nym != nym) identity.nym = nym;
    if (_ref.read(appStateProvider).selfNym != nym) {
      _ref.read(appStateProvider.notifier).setIdentity(identity.pubkey, nym);
    }
    // Persist for instant restore; durable logins only.
    if (identity.loginMethod != null) {
      final kv = _ref.read(keyValueStoreProvider);
      unawaited(kv.setString(
        StorageKeys.nostrLoginProfile,
        jsonEncode({'name': name, 'avatar': profile?.picture}),
      ));
    }
  }

  // Sign out / disconnect.

  /// Tears down the live session without touching persisted state, [AppState] or `_started`; panic passes `flush: false`.
  Future<void> _teardownLiveSession({bool flush = true}) async {
    _flushTimer?.cancel();
    _chatToolsTimer?.cancel();
    _chatToolsTimer = null;
    // Drop buffered live events; they'd be re-fetched on the next connect.
    _liveInboundTimer?.cancel();
    _liveInboundTimer = null;
    _liveInboundBuffer.clear();
    _cancelGiftWrapInbound();
    _settingsSyncTimer?.cancel();
    _vouchPublishTimer?.cancel();
    _vouchPublishTimer = null;
    _vouchExpansionTimer?.cancel();
    _vouchExpansionTimer = null;
    _trustPersistTimer?.cancel();
    _trustPersistTimer = null;
    _lastVouchPublishAt = 0;
    // Release the hydration gate; the next [init] re-arms it.
    _settingsHydratedFallback?.cancel();
    _settingsHydratedFallback = null;
    if (!_settingsHydratedC.isCompleted) _settingsHydratedC.complete();
    _deletedIdsPersistTimer?.cancel();
    _deletedIdsPersistTimer = null;
    _pqKeysPersistTimer?.cancel();
    _pqKeysPersistTimer = null;
    _verifiedIdsPersistTimer?.cancel();
    _verifiedIdsPersistTimer = null;
    NostrService.onVerifiedIdsChanged = null;
    _pqAnnounceTimer?.cancel();
    _pqAnnounceTimer = null;
    // Flush pending persists before the handles they read are dropped.
    _flushDebouncedPersists();
    _ref.read(appStateProvider.notifier).onDeletedIdsChanged = null;
    _dmRetryTimer?.cancel();
    _dmRetryTimer = null;
    _pendingDms.clear();
    _profileBackfillTimer?.cancel();
    _profileBackfillTimer = null;
    _profileBackfillQueue.clear();
    _profileBackfillQueued.clear();
    _channelWindowPruneTimer?.cancel();
    _channelWindowPruneTimer = null;
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
    // Clear cached NIP-98 auth so the next identity never reuses it.
    Nip98Auth.clearAuthCache();

    _identity = null;
    _signer = null;
    _service = null;
    _groups = null;
    _storageSync = null;
    _resetPqRootState();
    _zapArchive?.dispose();
    _zapArchive = null;
    _lastOnlineTimer?.cancel();
    _lastOnlineTimer = null;
    _lastOnlineTrackingStarted = false;
    _keyResyncReplyMs.clear();
    _pendingGroupHistory.clear();
    _lastPresenceBroadcast = 0;
    _presenceTimestamps.clear();
    _typingThrottle.clear();
    _sentChannelReadReceipts.clear();
    _sentPmReadReceipts.clear();
    _reactionToggleTracker.clear();

    // The sync binding captured the old signer.
    final settings = _ref.read(settingsProvider.notifier);
    settings.onSyncedChange = null;
    // These hooks captured the old identity.
    settings.activePubkey = null;
    settings.onKeypairModeChanged = null;
    settings.onLowDataModeChanged = null;
    settings.onGroupChatPMOnlyModeChanged = null;
    // The binding captured the old storage sync.
    _ref.read(appStateProvider.notifier).onViewOpened = null;
    _ref.read(appStateProvider.notifier).onPmMessageIngested = null;
    _ref.read(appStateProvider.notifier).onPMConversationAdded = null;
    _ref.read(appStateProvider.notifier).onGroupStoreChanged = null;
    _ref.read(appStateProvider.notifier).onChannelReadMarked = null;
    _ref.read(appStateProvider.notifier).onViewEntering = null;
    _ref.read(appStateProvider.notifier).onNavReadMarked = null;
    _chatNavTimer?.cancel();
    _chatNavTimer = null;
    // The ephemeral gift-wrap REQ captured the old service.
    _ownEph.close();
    // These bindings captured the old identity/service.
    final shop = _ref.read(shopControllerProvider.notifier);
    shop.onActiveItemsPublished = null;
    shop.giftEventPublisher = null;
    shop.onSystemMessage = null;
    // The ApiClient backing the bot ledger was disposed, so drop the service's request seam too.
    try {
      _ref.read(nymbotServiceProvider).setApiSocketRequest(null);
    } catch (_) {}
  }

  /// Switches the session to an imported nsec account without a restart; throws [FormatException] on a bad key.
  Future<void> loginWithNsec(String nsec,
      {String? pqRootCode, bool newKey = false}) async {
    final kv = _ref.read(keyValueStoreProvider);
    final identityService = IdentityService(
      kv: kv,
      secure: SecureStore(),
      secretWrite: _ref.read(identityVaultProvider).secretSet,
    );
    final candidate = normalizePrivkeyInput(nsec);
    if (candidate != null && candidate.length == 32) {
      final saved = _ref
          .read(accountsProvider)
          ?.savedElsewhere(keys.getPublicKeyHex(candidate));
      if (saved != null) throw AccountAlreadySaved(saved);
    }
    // Throws on an invalid key so the modal shows its error.
    final loggedIn = await identityService.loginWithNsec(nsec);

    await _teardownLiveSession();
    _started = false;
    final root = pqRootCode == null ? null : pqRootFromCode(pqRootCode.trim());
    if (root != null) {
      if (newKey) {
        _pqRootForNewKey = (pubkey: loggedIn.pubkey, root: root);
      } else {
        _pqRootCandidate = root;
      }
    }
    await init();

    // Remount the boot gate so it sees the saved login.
    _ref.read(bootEpochProvider.notifier).state++;
  }

  /// Adopts a NIP-46 session the login modal just established by re-booting the controller onto it.
  Future<void> loginWithNip46() async {
    // Teardown leaves `nip46ServiceProvider` alone, so the live socket survives into the re-boot.
    await _teardownLiveSession();
    _started = false;
    await init();
    _ref.read(bootEpochProvider.notifier).state++;
  }

  /// Resets the running session to first-run after [PanicWipe] has shredded storage, then remounts the boot gate.
  Future<void> resetAfterPanic() async {
    // Don't flush: that would re-persist live state into the wiped cache.
    await _teardownLiveSession(flush: false);

    _started = false;

    // The PQ root dies with the identity (spec §5.3).
    _pqRoot = null;
    _pqRootLocked = false;
    try {
      await SecureStore().remove(SecretKeys.pqRoot);
    } catch (_) {}

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

    // Final sweep for anything a straggling writer re-created after the wipe.
    try {
      await _ref.read(keyValueStoreProvider).clear();
    } catch (_) {}

    // Reset in-memory settings to defaults from the now-empty store.
    try {
      _ref.read(settingsProvider.notifier).resetToDefaults();
    } catch (_) {}

    // Re-enable persistence for the next session.
    PanicWipe.inProgress = false;

    _ref.read(bootEpochProvider.notifier).state++;
  }

  @visibleForTesting
  static PoolTransport Function()? debugPoolFactory;

  bool _suspended = false;
  bool _retired = false;

  bool get suspended => _suspended;

  int unreadTotal() {
    try {
      final st = _ref.read(appStateProvider);
      final keys = <String>{
        for (final c in st.pmConversations) c.pubkey,
        for (final g in st.groups) GroupLogic.groupStorageKey(g.id),
      };
      var total = 0;
      for (final k in keys) {
        total += st.unreadCounts[k] ?? 0;
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<void> suspendForAccountSwitch({
    bool persist = true,
    Duration drainBudget = const Duration(seconds: 3),
  }) async {
    if (_suspended) return;
    _suspended = true;
    if (persist) {
      try {
        flushPendingGroupReactions();
      } catch (_) {}
      try {
        _persistMeshOutbox();
      } catch (_) {}
      final sync = _storageSync;
      if (sync != null && sync.durableIdentity) {
        try {
          await sync.flushDeposits().timeout(drainBudget);
        } catch (_) {}
      }
      final mode = _ref.read(settingsProvider.notifier).keypairMode;
      final throwaway = _identity?.loginMethod == null &&
          (mode == 'random' || mode == 'hardcore');
      if (_settingsSyncTimer != null &&
          sync != null &&
          _settingsHydrated &&
          !throwaway) {
        _settingsSyncTimer?.cancel();
        _settingsSyncTimer = null;
        try {
          await _flushSettingsSync(sync).timeout(drainBudget);
        } catch (_) {}
      }
      final deadline = DateTime.now().add(drainBudget);
      while ((_service?.pendingDmCount ?? 0) > 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      try {
        await sync?.persistDepositsNow();
      } catch (_) {}
    }
    await _teardownLiveSession(flush: persist);
    _started = false;
    _retired = true;
  }

  Future<void> signOut() async {
    // Capture before teardown nulls the identity; the pubkey-scoped lightning address is removed below.
    final pubkey = _identity?.pubkey;

    await _teardownLiveSession();

    // Remove the persisted login and per-identity caches the PWA's signOut clears.
    final kv = _ref.read(keyValueStoreProvider);
    for (final k in const [
      StorageKeys.autoEphemeral,
      StorageKeys.autoEphemeralNick,
      StorageKeys.autoEphemeralChannel,
      StorageKeys.lastView,
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
    if (pubkey != null && pubkey.isNotEmpty) {
      await kv.remove(StorageKeys.lightningAddressFor(pubkey));
    }
    // Clear session/dev/login secrets; the NIP-46 client secret is left to the keystore wipe.
    final secure = SecureStore();
    for (final s in SecretKeys.all) {
      try {
        await secure.remove(s);
      } catch (_) {}
    }
    _pqRoot = null;
    _pqRootLocked = false;

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
    // Re-read settings so the setup screen doesn't keep the signed-out user's color mode.
    try {
      _ref.read(settingsProvider.notifier).reloadFromStore();
    } catch (_) {}
    // Rebuild the shop controller so a new identity doesn't inherit the old cosmetics.
    try {
      _ref.invalidate(shopControllerProvider);
    } catch (_) {}

    _started = false;

    // Bump the boot generation so a fresh BootGate remounts on setup.
    _ref.read(bootEpochProvider.notifier).state++;
  }

  MessagingSettings get _msgSettings {
    final s = _ref.read(settingsProvider);
    return MessagingSettings(
      dmForwardSecrecyEnabled: s.dmForwardSecrecyEnabled,
      dmTtlSeconds: s.dmTtlSeconds,
    );
  }

  // Inbound routing.

  /// Wall clock of the last [_flushLiveInbound].
  int _lastLiveFlushMs = 0;

  /// Minimum gap between live flushes so catch-up bursts don't saturate the UI thread; the size cap still flushes.
  static const int _kLiveInboundMinGapMs = 150;

  void _enqueueLiveEvent(NostrEvent event) {
    _liveInboundBuffer.add(event);
    if (_liveInboundBuffer.length >= _kLiveInboundFlushCap) {
      _flushLiveInbound();
      return;
    }
    if (_liveInboundTimer != null) return;
    final since = DateTime.now().millisecondsSinceEpoch - _lastLiveFlushMs;
    final delayMs =
        since >= _kLiveInboundMinGapMs ? 0 : _kLiveInboundMinGapMs - since;
    _liveInboundTimer =
        Timer(Duration(milliseconds: delayMs), _flushLiveInbound);
  }

  /// Replays the buffer through [_onEvent] in one batch, preserving order and isolating each event's errors.
  void _flushLiveInbound() {
    _liveInboundTimer?.cancel();
    _liveInboundTimer = null;
    _lastLiveFlushMs = DateTime.now().millisecondsSinceEpoch;
    if (_liveInboundBuffer.isEmpty) return;
    final batch = List<NostrEvent>.of(_liveInboundBuffer);
    _liveInboundBuffer.clear();
    _ref.read(appStateProvider.notifier).runBatched(() {
      for (final event in batch) {
        try {
          _onEvent(event);
        } catch (_) {
          // Skip a single failed event; never abort the batch.
        }
      }
    });
  }

  void _onEvent(NostrEvent event) {
    final appState = _ref.read(appStateProvider.notifier);
    if (event.kind == EventKind.appData) {
      // Kind 30078 is multiplexed by its `t` topic.
      final topic = event.tagValue('t');
      if (topic == AppDataTopic.vouches) {
        _ingestVouch(event);
      } else if (topic == AppDataTopic.postQuantum) {
        _ingestPqAnnouncement(event);
      } else if (topic == AppDataTopic.poll || topic == AppDataTopic.pollVote) {
        // Live polls/votes use the same store ingest as the D1 replay.
        appState.ingestEvent(event);
      } else {
        _ingestPresence(event);
      }
      return;
    }
    if (event.kind == EventKind.emojiPack) {
      _ingestEmojiPack(event);
      return;
    }
    if (event.kind == EventKind.userEmojiList) {
      _ingestUserEmojiList(event);
      return;
    }
    // Ephemeral channel typing from the active channel's sub.
    if (event.kind == EventKind.channelTyping) {
      _onChannelTypingEvent(event, appState);
      return;
    }
    // Ephemeral channel read receipt from the active channel's sub.
    if (event.kind == EventKind.channelReceipt) {
      _onChannelReadReceipt(event);
      return;
    }
    // Public zap receipts; gift-wrapped private zaps arrive via `_onPrivateZap`.
    if (event.kind == EventKind.zapReceipt) {
      _onPublicZapReceipt(event, appState);
      return;
    }
    // A live kind-0 refreshes the D1 profile cache so we don't re-fetch it.
    if (event.kind == EventKind.profile) {
      _storageSync?.markProfileCached(event.pubkey);
    }
    final knownBefore = appState.isKnownEventId(event.id);
    appState.ingestEvent(event);
    // A self kind-0 also updates the live identity and the instant-restore cache.
    if (event.kind == EventKind.profile && event.pubkey == _identity?.pubkey) {
      // Keep the full self kind-0 so profile saves merge against the real profile.
      _adoptSelfKind0(event);
      _syncSelfNymFromProfile();
      // Re-mirror our own kind-0 to D1 so edits made in other clients reach D1 readers.
      _mirrorOwnProfileToD1(event);
    }
    // Kind-7 reactions to our messages notify and record; removals are skipped.
    if (event.kind == EventKind.reaction) {
      // Register NIP-30 emoji before routing so custom reactions resolve to images.
      if (event.tags.isNotEmpty) {
        _ref.read(liveCustomEmojiProvider.notifier).ingestEmojiTags(event.tags);
      }
      final removed = event
          .tagsNamed('action')
          .any((t) => t.length > 1 && t[1] == 'remove');
      // Unsupported `k` kinds, or a missing `k` on an unknown target, are other apps' reactions and must not notify.
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
        // Resolve the reactor's profile so the reactors sheet shows their avatar.
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
    // Channel mention notifications run after ingest so the store is current.
    if (event.kind == EventKind.geoChannel ||
        event.kind == EventKind.namedChannel) {
      // Register NIP-30 emoji so `:shortcode:` tokens render.
      if (event.tags.isNotEmpty) {
        _ref.read(liveCustomEmojiProvider.notifier).ingestEmojiTags(event.tags);
        _ref.read(mediaFallbacksProvider).ingestImetaTags(event.tags);
      }
      // Register inbound P2P file offers so the card's download works; our own are registered at share time.
      if (event.pubkey != (_identity?.pubkey ?? '')) {
        final offer = parseFileOfferTag(event.tags, event.pubkey);
        if (offer != null) {
          _ref.read(p2pServiceProvider).registerOffer(offer);
        }
      }
      if (!knownBefore) _maybeNotifyChannel(event);

      // Clear the bot's thinking strip as soon as its reply lands.
      if (isVerifiedBot(event.pubkey)) {
        final botChannelKey = EventMapper.channelKeyOf(event);
        if (botChannelKey != null) {
          _setBotChannelThinking(botChannelKey, false);
        }
      }

      // Earned trust (two messages) and PoW-floor trust-graph observation.
      _observeMessageTrust(event);

      // Hydrate the author's kind-0 from D1 if missing; batched.
      _maybeBackfillProfiles(event.pubkey);

      // Send a read receipt for fresh, visible, non-own messages in the open channel.
      final self = _identity?.pubkey ?? '';
      final geohash = event.tagValue('g');
      final isGeo = geohash != null && geohash.isNotEmpty;
      // Raw wire key for the receipt's `g`/`d` tag.
      final wireKey = isGeo ? geohash : event.tagValue('d');
      final key = EventMapper.channelKeyOf(event);
      // Columns view uses the deck's seen gate; single view uses the active view.
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

  /// Ingests a kind-30030 pack (at most 120 deduped emoji); newest wins per pubkey:identifier.
  void _ingestEmojiPack(NostrEvent e) {
    // Validate before dedup and the cap, so invalid tags never count and an all-invalid pack is dropped.
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

  /// Ingests our own kind-10030 pack list (newest wins) plus inline `emoji` tags.
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

  // Inbound notifications.

  /// Whether [content] addresses us: an unquoted @-mention, or a quote reply to one of our messages.
  bool _refersToSelf(String content) {
    final identity = _identity;
    if (identity == null || content.isEmpty) return false;
    final nym = stripPubkeySuffix(identity.nym);
    if (nym.isEmpty) return false;
    final suffix = getPubkeySuffix(identity.pubkey);
    return mentionsSelf(content: content, nym: nym, suffix: suffix) ||
        quotesSelf(content: content, nym: nym, suffix: suffix);
  }

  /// Replayed backlog: older than 10s.
  bool _isHistorical(int createdAtSec) =>
      DateTime.now().millisecondsSinceEpoch - createdAtSec * 1000 > 10000;

  /// Whether an event at [tsMs] must be recorded silently; see [silentForAlert].
  bool _silentForAlert(
    int tsMs, {
    bool historical = false,
    int liveWindowMs = 10000,
  }) =>
      silentForAlert(
        tsMs: tsMs,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        catchUpCutoffMs: _catchUpAlertCutoffMs,
        historical: historical,
        liveWindowMs: liveWindowMs,
      );

  bool get _notificationsEnabled =>
      _ref.read(settingsProvider).notificationsEnabled;
  bool get _notifyFriendsOnly =>
      _ref
          .read(keyValueStoreProvider)
          .getString(StorageKeys.notifyFriendsOnly) ==
      'true';
  bool get _groupNotifyMentionsOnly =>
      _ref
          .read(keyValueStoreProvider)
          .getString(StorageKeys.groupNotifyMentionsOnly) ==
      'true';

  /// When on, thread replies only notify for mentions or quote replies.
  bool get _threadNotifyMentionsOnly =>
      _ref
          .read(keyValueStoreProvider)
          .getString(StorageKeys.threadNotifyMentionsOnly) ==
      'true';

  bool _appInForeground = true;

  /// True only when [storageKey] is open and the app is foregrounded; a reply collapsed in a thread isn't visible.
  bool _isActiveView(String storageKey, {String? threadRoot}) {
    if (!_appInForeground) return false;
    final app = _ref.read(appStateProvider);
    if (app.view.storageKey != storageKey) return false;
    return !threadReplyHidden(
      state: app,
      openThread: _ref.read(activeThreadProvider),
      storageKey: storageKey,
      threadRoot: threadRoot,
    );
  }

  void _maybeNotifyChannel(NostrEvent e) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    final isOwn = e.pubkey == self;
    final appState = _ref.read(appStateProvider);
    final isBlocked = appState.blockedUsers.contains(e.pubkey);
    final key = EventMapper.channelKeyOf(e);
    final mention = _refersToSelf(e.content);
    final threadRoot = EventMapper.threadRootFromTags(e.tags);
    // A thread-reply mention is hidden behind the reply row, so the active-view gate must not swallow it.
    final isActive = key != null && _isActiveView(key, threadRoot: threadRoot);
    final inThread = isThreadReplyMarker(threadRoot);
    final ownThread = key != null &&
        threadRootIsOwn(
            state: appState, storageKey: key, threadRoot: threadRoot);
    // Historical mentions still record to history, silently.
    final record = shouldRecordNotification(
      kind: NotifyKind.channel,
      isOwn: isOwn,
      notificationsEnabled: _notificationsEnabled,
      isMention: mention,
      isFriend: appState.isFriend(e.pubkey),
      isBlocked: isBlocked,
      // The verified bot never notifies.
      isBot: isVerifiedBot(e.pubkey),
      isActiveView: isActive,
      friendsOnly: _notifyFriendsOnly,
      // Thread rules let replies to the user's own message reach the bell.
      isThreadReply: inThread,
      isOwnThreadRoot: ownThread,
      threadMentionsOnly: _threadNotifyMentionsOnly,
    );
    if (!record) return;
    // A channel mention routes to the channel, labeled `in #<key>`.
    final channelRoute =
        key != null ? (key.startsWith('#') ? key.substring(1) : key) : '';
    final notifTsMs = EventMapper.effectiveMsOf(e);
    _dispatchNotification(
      title: _nymDisplayFor(e.pubkey),
      // Quote replies lead with the quoted message; show the reply itself.
      body: notificationBodyFor(e.content),
      senderPubkey: e.pubkey,
      isFriend: appState.isFriend(e.pubkey),
      isMention: mention,
      historyType: channelRoute.isNotEmpty ? 'channel' : 'mention',
      route: channelRoute.isNotEmpty ? channelRoute : e.pubkey,
      eventId: e.id,
      // Use the mapper's clamped time so future-dated events don't pin to the top or alert as live.
      tsMs: notifTsMs,
      // Thread replies name the thread as well as the channel.
      contextLabel: key == null
          ? null
          : (inThread
              ? tr('in a thread in {key}', {'key': key})
              : tr('in {key}', {'key': key})),
      threadRoot: inThread ? threadRoot : null,
      // `_silentForAlert` is the whole live-arrival rule; don't OR in `_isHistorical`, which silenced catch-up mentions.
      silent: _silentForAlert(notifTsMs),
    );
  }

  /// PM/group notification: always recorded to history; only the loud alert depends on age.
  void _maybeNotifyMessage(Message m,
      {required bool isGroup, int? alertCutoffMs}) {
    final appState = _ref.read(appStateProvider);
    if (m.slowHeld) return;
    final mention = _refersToSelf(m.content) ||
        (isGroup && _ref.read(groupToolsProvider).mentionsAll(m));
    final key = m.conversationKey ??
        (isGroup
            ? GroupLogic.groupStorageKey(m.groupId ?? '')
            : (m.conversationPubkey != null
                ? PmLogic.pmStorageKey(m.conversationPubkey!)
                : ''));
    final inThread = isThreadReplyMarker(m.threadRoot);
    final ownThread = threadRootIsOwn(
        state: appState, storageKey: key, threadRoot: m.threadRoot);
    // Not age-gated, since gift-wrapped messages always carry an old `created_at`.
    final record = shouldRecordNotification(
      kind: isGroup ? NotifyKind.group : NotifyKind.pm,
      isOwn: m.isOwn,
      notificationsEnabled: _notificationsEnabled,
      isMention: mention,
      isFriend: appState.isFriend(m.pubkey),
      isBlocked: appState.blockedUsers.contains(m.pubkey),
      // A verified-bot sender is fully silent.
      isBot: m.isBot || isVerifiedBot(m.pubkey),
      isActiveView: _isActiveView(key, threadRoot: m.threadRoot),
      friendsOnly: _notifyFriendsOnly,
      groupMentionsOnly: _groupNotifyMentionsOnly,
      // Group threads use thread rules; PM threads stay exempt since every 1:1 message is addressed to the user.
      isThreadReply: inThread,
      isOwnThreadRoot: ownThread,
      threadMentionsOnly: _threadNotifyMentionsOnly,
    );
    if (!record) return;
    // Loud alert only when fresh; a background catch-up is handled inside [_silentForAlert].
    final treatAsHistorical = alertCutoffMs != null
        ? silentForAlert(
            tsMs: m.timestamp,
            nowMs: DateTime.now().millisecondsSinceEpoch,
            catchUpCutoffMs: alertCutoffMs,
          )
        : _silentForAlert(
            m.timestamp,
            historical: m.isHistorical,
            liveWindowMs: 30000,
          );
    _dispatchNotification(
      // Title is the bare author; the group name goes in the context label.
      title: m.author,
      body: notificationBodyFor(m.content),
      senderPubkey: m.pubkey,
      isFriend: appState.isFriend(m.pubkey),
      isMention: mention,
      isGroup: isGroup,
      historyType: isGroup ? 'group' : 'pm',
      route: isGroup ? (m.groupId ?? '') : m.pubkey,
      eventId: m.nymMessageId ?? m.id,
      tsMs: m.timestamp,
      contextLabel: _messageContextLabel(
          isGroup: isGroup, inThread: inThread, groupId: m.groupId),
      threadRoot: inThread ? m.threadRoot : null,
      silent: treatAsHistorical,
    );
  }

  /// Bell footer label: `in <GroupName>` for groups, null for PMs; thread replies say so.
  String? _messageContextLabel({
    required bool isGroup,
    required bool inThread,
    required String? groupId,
  }) {
    if (isGroup) {
      final name = _groupNameFor(groupId);
      return inThread
          ? tr('in a thread in {name}', {'name': name})
          : tr('in {name}', {'name': name});
    }
    return inThread ? tr('PM thread') : null;
  }

  /// Falls back to "Group".
  String _groupNameFor(String? groupId) {
    if (groupId == null) return tr('Group');
    final g = _ref.read(appStateProvider.notifier).groupById(groupId);
    return (g != null && g.name.isNotEmpty) ? g.name : tr('Group');
  }

  /// Records into the bell history and, unless [silent], fires sound and popup.
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
    String? threadRoot,
    bool silent = false,
  }) {
    final tapRoute = route ?? senderPubkey;
    // A thread-reply notification opens the thread.
    final payload = encodeNotificationPayload(
      type: historyType,
      route: tapRoute,
      senderPubkey: senderPubkey,
      threadRoot: threadRoot,
    );
    // One OS notification per conversation, keyed like the bell routes.
    final conversationKey = notificationConversationKey(
      historyType: historyType,
      route: tapRoute,
    );
    final kind = notificationKindFor(historyType);
    // The verified bot never notifies; must precede the loud path.
    if (isVerifiedBot(senderPubkey)) return;
    // Blocked users are gated centrally so every caller, including mesh, is covered.
    final blockState = _ref.read(appStateProvider);
    final isBlocked = senderPubkey.isNotEmpty &&
        blockState.blockedUsers.contains(senderPubkey);
    if (isBlocked) return;
    // Blocked keywords hide the message, so don't notify about it.
    if (blockState.hasBlockedKeyword(
      body,
      senderPubkey.isEmpty ? null : _nymDisplayFor(senderPubkey),
    )) {
      return;
    }
    // Friends-only blocks both alert and history for non-friends.
    if (_notifyFriendsOnly && senderPubkey.isNotEmpty && !isFriend) return;
    // Silent replays older than 24h are dropped; the loud path only sees live events.
    if (silent && tsMs != null) {
      final cutoff24hMs =
          DateTime.now().millisecondsSinceEpoch - 24 * 60 * 60 * 1000;
      if (tsMs < cutoff24hMs) return;
    }
    var shownTitle = title;
    var shownBody = NymFormat.stripForPreview(body);
    var shownLabel = contextLabel;
    var lockedChat = false;
    try {
      final lock = _ref.read(chatLockProvider);
      lockedChat = lock.notificationIsLocked(historyType, tapRoute, senderPubkey);
      if (lockedChat) {
        final r = lock.redact(title, shownBody, true);
        shownTitle = r.title;
        shownBody = r.body;
        shownLabel = null;
      }
    } catch (_) {}
    if (!silent) {
      unawaited(_ref.read(notificationsServiceProvider).notify(
            title: shownTitle,
            body: shownBody,
            notifyFriendsOnly: _notifyFriendsOnly,
            groupNotifyMentionsOnly: _groupNotifyMentionsOnly,
            threadNotifyMentionsOnly: _threadNotifyMentionsOnly,
            context: NotifyContext(
              senderPubkey: senderPubkey,
              isFriend: isFriend,
              isMention: isMention,
              isGroup: isGroup,
              isThreadReply: threadRoot != null && threadRoot.isNotEmpty,
              // Keeps the service's own blocked check live.
              isBlocked: isBlocked,
              payload: payload,
              conversationKey: conversationKey,
              kind: kind,
              // Keeps the service's own bot gate live.
              isBot: isVerifiedBot(senderPubkey),
              // eventId and timestamp enable the service's replay guards.
              eventId: eventId,
              timestampMs: tsMs,
            ),
          ));
    }
    try {
      _ref.read(notificationHistoryProvider.notifier).record(
            type: historyType,
            title: shownTitle,
            body: shownBody,
            route: route ?? senderPubkey,
            ts: tsMs,
            eventId: eventId,
            senderPubkey: senderPubkey,
            contextLabel: shownLabel,
            threadRoot: threadRoot,
            exactOnly: lockedChat,
          );
    } catch (_) {
      // History store may be unavailable in teardown; alerting still happened.
    }
  }

  /// Handles a signed event carried over the mesh, verifying it first; [publish] relays it for a mesh-only peer.
  Future<void> handleMeshCarriedEvent({
    required Map<String, dynamic> event,
    required String geohash,
    required bool publish,
  }) async {
    final service = _service;
    if (service == null) return;
    NostrEvent parsed;
    try {
      parsed = NostrEvent.fromJson(event);
    } catch (_) {
      return;
    }
    if (!await service.verifyEvent(parsed)) {
      debugPrint('[mesh] carried event failed verification — dropped');
      return;
    }
    if (publish) {
      await service.pool.publish(parsed);
      return;
    }
    // Ingest like an event from our own socket.
    if (parsed.kind == EventKind.geoChannel ||
        parsed.kind == EventKind.namedChannel) {
      _ref.read(appStateProvider.notifier).ingestEvent(parsed);
      _maybeNotifyChannel(parsed);
    }
  }

  /// Routes mesh notifications through the same pipeline as Nostr ones.
  void dispatchMeshNotification({
    required String title,
    required String body,
    required String senderPubkey,
    required bool isMention,
    String historyType = 'pm',
    String? route,
    int? tsMs,
    String? eventId,
    String? contextLabel,
  }) {
    final isFriend = _ref.read(appStateProvider).friends.contains(senderPubkey);
    _dispatchNotification(
      title: title,
      body: body,
      senderPubkey: senderPubkey,
      isFriend: isFriend,
      isMention: isMention,
      historyType: historyType,
      route: route,
      eventId: eventId,
      tsMs: tsMs,
      contextLabel: contextLabel,
    );
  }

  /// Notifies and records history when someone else reacts to our message.
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
    if (preview != null) preview = NymFormat.stripForPreview(preview);
    if (preview != null && preview.length > 80) {
      preview = '${preview.substring(0, 80)}…';
    }
    final body = (preview != null && preview.isNotEmpty)
        ? tr('reacted {emoji} to: "{preview}"',
            {'emoji': emoji, 'preview': preview})
        : tr('reacted {emoji} to your message', {'emoji': emoji});

    // Replayed reactions record silently.
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
      silent: _silentForAlert(tsSec * 1000),
    );
  }

  /// Port of the PWA's `abbreviateNumber`: `<1000` verbatim, `1.2k`/`12k`, `1.2M`.
  static String _abbreviateSats(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final v = n / 1000;
      return '${v.toStringAsFixed(n < 10000 ? 1 : 0)}k';
    }
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }

  /// Notifies when someone else zaps our message; the caller has verified the recipient and counted the zap.
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

    // Preview of the zapped message (first non-quoted line, ≤80 chars).
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
    if (preview != null) preview = NymFormat.stripForPreview(preview);
    if (preview != null && preview.length > 80) {
      preview = '${preview.substring(0, 80)}…';
    }
    final sats = _abbreviateSats(amountSats);
    final body = (preview != null && preview.isNotEmpty)
        ? tr('⚡ zapped {sats} sats to: "{preview}"',
            {'sats': sats, 'preview': preview})
        : tr('⚡ zapped {sats} sats to your message', {'sats': sats});

    // Zap notifications route to the zapper's PM and are silent when historical.
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
      silent: _silentForAlert(tsSec * 1000),
    );
  }

  /// Profile-zap receipt ids already handled, to prevent double notifications.
  final Set<String> _profileZapReceipts = <String>{};

  /// Notifies a profile zap (no `e` tag); deduped by id, "(unverified)" unless from our LNURL provider.
  void _maybeNotifyProfileZap(NostrEvent event) {
    if (!_profileZapReceipts.add(event.id)) return;
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

    // Verified only when the receipt author is our LNURL provider.
    _getZapProviderPubkey(self).then((providerPubkey) {
      // A provider is configured but this receipt isn't from it, so drop.
      if (providerPubkey != null &&
          event.pubkey.toLowerCase() != providerPubkey) {
        return;
      }
      final verified = providerPubkey != null &&
          event.pubkey.toLowerCase() == providerPubkey;
      final sats = _abbreviateSats(amount);
      final body = verified
          ? tr('⚡ zapped {sats} sats to your profile', {'sats': sats})
          : tr('⚡ zapped {sats} sats to your profile (unverified)',
              {'sats': sats});
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
        silent: _silentForAlert(event.createdAt * 1000),
      );
    }).catchError((_) {});
  }

  void _ingestPresence(NostrEvent e) {
    // Skip our own and stale presence events.
    final isPresence = e
        .tagsNamed('t')
        .any((t) => t.length > 1 && t[1] == AppDataTopic.presence);
    if (!isPresence) return;
    if (e.tagValue('status') == null) return;
    final self = _service?.selfPubkey ?? _identity?.pubkey;
    if (self != null && e.pubkey == self) return;

    final lastTs = _presenceTimestamps[e.pubkey] ?? 0;
    if (e.createdAt < lastTs) return;
    _presenceTimestamps[e.pubkey] = e.createdAt;

    final statusStr = e.tagValue('status');
    final nym = e.tagValue('n');
    final away = e.tagValue('away');
    final avatar = e.tagValue('avatar-update');
    // `shop-update` is a pure cache-bust flag; items live in D1, so force-refresh the sender's shop status.
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
          // Presence isn't activity, so it must not stamp lastSeen.
          lastSeenMs: e.createdAt * 1000,
          stampLastSeen: false,
          avatarUrl: avatar,
          hasAvatarTag: avatar != null,
        );

    // Resolve the user's D1 profile so their avatar shows without a message; guarded on picture.
    _maybeBackfillProfiles(e.pubkey);
  }

  /// Newest presence timestamp per pubkey so older replays can't clobber newer ones.
  final Map<String, int> _presenceTimestamps = {};

  // Web of trust ("nym-vouch"), kind 30078 `['t','nym-vouches']`.

  /// Ingests a trusted author's vouch list and schedules a one-hop expansion when it adds pubkeys.
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
    // Newly trusted pubkeys are new vouch authors; expand one hop via a debounced resubscribe.
    if (added) {
      _scheduleVouchExpansion();
      _scheduleTrustPersist();
    }
  }

  /// Marks [pubkey] as running Nymchat in the graph and our vouch list, then schedules a publish.
  void _observeNymchatPubkey(String pubkey) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (pubkey.isEmpty || pubkey == self) return;
    // Our vouch list is public, so a Ghost Mode key in it would deanonymize the session; fail closed.
    if (_ref.read(ghostModeProvider).pubkeys.contains(pubkey.toLowerCase())) {
      return;
    }
    final notifier = _ref.read(appStateProvider.notifier);
    notifier.markNymchatPubkey(pubkey);
    final added = notifier.observeNymchatPubkey(pubkey);
    if (added) _scheduleVouchPublish();
    _scheduleTrustPersist();
  }

  /// Earned trust and PoW-floor observation; must also run on the D1 backfill path or restored history is filtered out.
  void _observeMessageTrust(NostrEvent event) {
    final selfPk = _identity?.pubkey ?? '';
    if (event.pubkey.isEmpty || event.pubkey == selfPk) return;
    if (nymVouchSpamGateEnabled) {
      final earnedTrust = _ref
          .read(appStateProvider.notifier)
          .trackPubkeyMessage(event.pubkey, event.id);
      if (earnedTrust) _scheduleTrustPersist();
    }
    if (pow.validatePow(event, _nymchatPowFloor)) {
      _observeNymchatPubkey(event.pubkey);
    }
  }

  /// NIP-13 PoW floor (leading zero bits) that counts as a Nymchat self-attestation.
  static const int _nymchatPowFloor = 16;

  /// At most one vouch publish per 60s, else a 5s coalescing delay.
  Timer? _vouchPublishTimer;
  int _lastVouchPublishAt = 0;

  void _scheduleVouchPublish() {
    if (_vouchPublishTimer != null) return;
    final sinceLast =
        DateTime.now().millisecondsSinceEpoch - _lastVouchPublishAt;
    final delayMs = sinceLast < 60000 ? 60000 - sinceLast : 5000;
    _vouchPublishTimer = Timer(Duration(milliseconds: delayMs), () {
      _vouchPublishTimer = null;
      unawaited(_publishVouches());
    });
  }

  /// Signs and publishes our `nym-vouches` list; best-effort.
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

  /// Debounced (5s) persist of the web-of-trust sets so the graph survives restarts.
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

  /// One-hop expansion fires 15s after new trusted pubkeys appear.
  Timer? _vouchExpansionTimer;

  void _scheduleVouchExpansion() {
    if (_vouchExpansionTimer != null) return;
    _vouchExpansionTimer = Timer(const Duration(seconds: 15), () {
      _vouchExpansionTimer = null;
      _subscribeVouches();
    });
  }

  /// Feeds the trust graph into the critical REQ's direct-mode vouch filter; no-op when unchanged.
  void _subscribeVouches() {
    final service = _service;
    if (service == null) return;
    final authors = _ref.read(appStateProvider).nymchatPubkeys;
    service.updateCriticalInputs(vouchAuthors: authors);
  }

  /// Unwrapped gift-wraps awaiting one batched ingest, so a restore of hundreds doesn't rebuild per wrap.
  final List<GiftWrapUnwrapped> _giftWrapInbound = <GiftWrapUnwrapped>[];
  Timer? _giftWrapFlushTimer;
  static const int _kGiftWrapFlushCap = 256;
  static const int _kGiftWrapSliceMicros = 8000;

  @visibleForTesting
  int giftWrapSliceMicros = _kGiftWrapSliceMicros;

  bool _giftWrapDraining = false;
  int _giftWrapEpoch = 0;
  Future<void>? _giftWrapDrain;

  void _onGiftWrap(GiftWrapUnwrapped u) {
    _giftWrapInbound.add(u);
    if (_giftWrapDraining) return;
    if (_giftWrapInbound.length >= _kGiftWrapFlushCap) {
      _flushGiftWrapInbound();
    } else {
      _giftWrapFlushTimer ??= Timer(Duration.zero, _flushGiftWrapInbound);
    }
  }

  void _flushGiftWrapInbound() {
    _giftWrapFlushTimer?.cancel();
    _giftWrapFlushTimer = null;
    if (_giftWrapDraining || _giftWrapInbound.isEmpty) return;
    _giftWrapDraining = true;
    _giftWrapDrain = _drainGiftWrapInbound(_giftWrapEpoch);
  }

  Future<void> _drainGiftWrapInbound(int epoch) async {
    try {
      var pending = <GiftWrapUnwrapped>[];
      var next = 0;
      while (true) {
        if (next >= pending.length) {
          if (_giftWrapInbound.isEmpty) return;
          pending = List<GiftWrapUnwrapped>.of(_giftWrapInbound);
          _giftWrapInbound.clear();
          next = 0;
        }
        next = _runGiftWrapSlice(pending, next);
        await Future<void>.delayed(Duration.zero);
        if (epoch != _giftWrapEpoch) return;
      }
    } finally {
      if (epoch == _giftWrapEpoch) _giftWrapDraining = false;
    }
  }

  int _runGiftWrapSlice(List<GiftWrapUnwrapped> batch, int start) {
    final watch = Stopwatch()..start();
    var i = start;
    _ref.read(appStateProvider.notifier).runBatched(() {
      while (i < batch.length) {
        try {
          _processGiftWrap(batch[i]);
        } catch (_) {}
        i++;
        if (watch.elapsedMicroseconds >= giftWrapSliceMicros) break;
      }
    });
    return i;
  }

  void _cancelGiftWrapInbound() {
    _giftWrapFlushTimer?.cancel();
    _giftWrapFlushTimer = null;
    _giftWrapInbound.clear();
    _giftWrapEpoch++;
    _giftWrapDraining = false;
    _giftWrapDrain = null;
  }

  void _processGiftWrap(GiftWrapUnwrapped u) {
    final appState = _ref.read(appStateProvider.notifier);
    final rumor = u.rumor;
    final kind = u.rumorKind;
    final self = _service?.selfPubkey ?? '';
    final gap = _gapWrapVerdict(u);

    // Track the peer's PM format so replies go out in one they can decrypt.
    final sender = rumor['pubkey'] as String?;
    if (!u.senderVerified &&
        (!PmLogic.unverifiedWrapAllowed(rumor, selfPubkey: self) ||
            _isAnonBotPubkey(sender) ||
            isVerifiedBot(sender ?? ''))) {
      return;
    }
    if (sender != null && sender.isNotEmpty && sender != self) {
      if (u.isBitchat) {
        // With its timestamp, so older evidence can't win against the peer's announcement.
        _noteBitchatFormatSeen(
            sender, (rumor['created_at'] as int?) ?? _nowSecForBitchat());
      } else if (_tags(rumor).any((t) => t.length > 1 && t[0] == 'x')) {
        _nymUsers.add(sender);
      }
    }

    switch (kind) {
      case EventKind.dmRumor: // 14 — PM or group message
        // Archive durable DM wraps to D1; receipts, typing, signaling, presence and settings wraps are not archived.
        _archiveGiftWrap(u);
        _onRumorMessage(u, appState, self, gap: gap);
      case EventKind.nymReceiptRumor: // 69420 — receipt or typing
        if (u.senderVerified) _onReceiptOrTyping(rumor, appState);
      case EventKind.reaction: // 7 — gift-wrapped reaction
        // Reactions are durable content and archived too, or they vanish on relaunch.
        if (!u.senderVerified) return;
        _archiveGiftWrap(u);
        _onPrivateReaction(rumor, appState);
      case EventKind.zapReceipt: // 9735 — gift-wrapped private zap announcement
        if (!u.senderVerified) return;
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

  /// Stable per-process id so a device ignores the echo of its own ping.
  String? _syncInstanceIdCache;
  String get _syncInstanceId =>
      _syncInstanceIdCache ??= '${Random().nextInt(1 << 32).toRadixString(36)}'
          '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

  int _lastSyncPingTs = 0;
  Timer? _syncPingTimer;

  /// Treats a sync ping as a doorbell: ignore our own and non-newer pings, and pull from D1 debounced.
  void _onSettingsChangedPing(Map<String, dynamic> ping, int rumorTs) {
    final src = ping['src'];
    if (src is String && src == _syncInstanceId) return;

    final rawTs = ping['ts'];
    final ts = rawTs is num ? rawTs.toInt() : rumorTs;
    if (ts != 0 && ts <= _lastSyncPingTs) return;
    _lastSyncPingTs = ts;

    _syncPingTimer?.cancel();
    _syncPingTimer = Timer(const Duration(milliseconds: 1200), () {
      _syncPingTimer = null;
      unawaited(_pullSettingsAfterPing());
    });
  }

  Future<void> _pullSettingsAfterPing() async {
    try {
      final sync = _storageSync;
      if (sync == null) return;
      await _mergeRemoteSettings(sync);
    } catch (_) {
      // A failed pull leaves the next scheduled read to catch up.
    }
  }

  void _onSettingsRumor(Map<String, dynamic> rumor, GiftWrapUnwrapped u) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    final tags = _tags(rumor);
    final dTag = _tagValue(tags, 'd') ?? '';
    final senderPubkey = rumor['pubkey'] as String? ?? '';

    if (dTag.startsWith('nym-settings-transfer-') && senderPubkey != self) {
      _handleSettingsTransferRumor(rumor, tags, u, self);
      return;
    }

    final isOwn = self.isNotEmpty && senderPubkey == self;
    if (!isOwn) return;

    // Another of our devices saved settings; pull the authoritative values from D1.
    if (dTag == 'nymchat-sync-ping') {
      try {
        final raw = jsonDecode(rumor['content'] as String? ?? '');
        if (raw is Map) {
          _onSettingsChangedPing(Map<String, dynamic>.from(raw),
              (rumor['created_at'] as num?)?.toInt() ?? 0);
        }
      } catch (_) {
        // Malformed ping — ignore.
      }
      return;
    }

    Map<String, dynamic> decoded;
    try {
      final raw = jsonDecode(rumor['content'] as String? ?? '');
      if (raw is! Map) return;
      decoded = Map<String, dynamic>.from(raw);
    } catch (_) {
      // Malformed settings blob — ignore.
      return;
    }

    // Additive merge for every own wrap, even when the ts gate below rejects the replace-style apply.
    try {
      _applySyncedSettingsAdditive(decoded);
    } catch (_) {
      // Best-effort; the replace-style apply below still runs.
    }

    // Replace-style apply only when strictly newer than both the applied and stored sync ts.
    final isCoreSettings =
        dTag == 'nymchat-settings' || dTag.startsWith('nymchat-settings-');
    if (isCoreSettings && dTag != 'nymchat-settings') {
      final rumorTs = (rumor['created_at'] as num?)?.toInt() ?? 0;
      final kv = _ref.read(keyValueStoreProvider);
      final lastTs =
          int.tryParse(kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ??
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

  /// Per-section applied ts for live settings wraps.
  final Map<String, int> _appliedSectionTs = <String, int>{};

  /// Surfaces a settings-transfer rumor addressed to us as a pending offer, dropping invalid, dismissed or duplicate ones.
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

    _emitSystemMessage(tr(
        'Settings received from {short8}...! Approve from settings modal.',
        {'short8': short8}));
  }

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

  void _dismissTransferEvent(String eventId) {
    final set = _dismissedTransferEvents()..add(eventId);
    _ref
        .read(keyValueStoreProvider)
        .setString(StorageKeys.dismissedTransfers, jsonEncode(set.toList()));
  }

  /// Accepts a settings transfer (nickname, avatar, settings), republishes our sync, and persists the dismissal.
  Future<bool> acceptUserSettingsTransfer(String eventId) async {
    final notifier = _ref.read(pendingUserSettingsTransfersProvider.notifier);
    final transfer = notifier.removeByEventId(eventId);
    if (transfer == null) return false;
    final identity = _identity;

    final nickname = transfer.nickname;
    final avatarUrl = transfer.avatarUrl;
    if (identity != null && avatarUrl != null && avatarUrl.isNotEmpty) {
      _ref
          .read(keyValueStoreProvider)
          .setString(StorageKeys.avatarUrl, avatarUrl);
      _ref.read(appStateProvider.notifier).setUserPresence(
            pubkey: identity.pubkey,
            status:
                _ref.read(appStateProvider).users[identity.pubkey]?.status ??
                    UserStatus.online,
            avatarUrl: avatarUrl,
            hasAvatarTag: true,
            stampLastSeen: false,
          );
    }
    if (identity != null && nickname != null && nickname.isNotEmpty) {
      // The nickname republishes our kind-0, carrying the avatar too.
      await saveProfile(
        name: nickname,
        picture: (avatarUrl != null && avatarUrl.isNotEmpty) ? avatarUrl : null,
      );
    }

    // Apply through the sync path, then republish our own sync.
    _applySyncedSettings(transfer.settings, userAcceptedTransfer: true);
    final lightning = transfer.settings['lightningAddress'];
    if (lightning is String && lightning.isNotEmpty && identity != null) {
      _ref.read(keyValueStoreProvider).setString(
          StorageKeys.lightningAddressFor(identity.pubkey), lightning);
    }
    syncSettings();

    _dismissTransferEvent(eventId);
    _emitSystemMessage(tr('Settings from {nym} applied successfully!',
        {'nym': transfer.fromNym}));
    return true;
  }

  /// Rejects a settings transfer and persists the dismissal.
  bool rejectUserSettingsTransfer(String eventId) {
    final notifier = _ref.read(pendingUserSettingsTransfersProvider.notifier);
    final transfer = notifier.removeByEventId(eventId);
    _dismissTransferEvent(eventId);
    if (transfer != null) {
      _emitSystemMessage(tr(
          'Settings transfer from {nym} rejected.', {'nym': transfer.fromNym}));
      return true;
    }
    return false;
  }

  /// Ingests a friend's private presence; only from verified senders we know, so strangers can't appear online.
  void _onFriendPresence(
      Map<String, dynamic> rumor, AppStateNotifier appState) {
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
    // Resolve the friend's profile so their avatar loads.
    _maybeBackfillProfiles(pubkey);
  }

  void _onRumorMessage(
      GiftWrapUnwrapped u, AppStateNotifier appState, String self,
      {({bool stale, int? cutoffMs}) gap = (stale: false, cutoffMs: null)}) {
    final rumor = u.rumor;
    final tags = _tags(rumor);
    final groupId = _tagValue(tags, 'g');
    final type = _tagValue(tags, 'type');
    final senderPubkey = rumor['pubkey'] as String? ?? '';

    // Register NIP-30 emoji so `:shortcode:` tokens render.
    if (tags.isNotEmpty) {
      _ref.read(liveCustomEmojiProvider.notifier).ingestEmojiTags(tags);
      _ref.read(mediaFallbacksProvider).ingestImetaTags(tags);
    }

    final knownGroup = groupId == null ? null : appState.groupById(groupId);
    final nonMember = knownGroup != null &&
        senderPubkey != self &&
        !GroupLogic.isMember(knownGroup, senderPubkey);

    if (groupId != null && u.senderVerified && !nonMember) {
      final ephPk = _tagValue(tags, 'ephemeral_pk');
      final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
      if (ephPk != null && senderPubkey != self) {
        _groups?.recordMemberKey(groupId, senderPubkey, ephPk, ts);
      }
    }

    if (type != null &&
        _ref
            .read(dmPollsProvider)
            .handleControl(rumor, senderPubkey, groupId, u.senderVerified)) {
      return;
    }

    if (groupId != null && type != null && type != GroupControlType.message) {
      if (!u.senderVerified) return;
      if (nonMember && !GroupLogic.acceptsFromNonMember(type)) return;
      _onGroupControl(groupId, type, tags, senderPubkey, rumor, u, appState);
      return;
    }

    // An edit rumor rewrites the original in place instead of being ingested as a new message.
    final editId = _tagValue(tags, 'edit');
    if (editId != null && editId.isNotEmpty) {
      if (!u.senderVerified || nonMember) return;
      final content = rumor['content'] as String? ?? '';
      appState.applyEditOrDefer(editId, content,
          editorPubkey: senderPubkey,
          verified: u.senderVerified,
          editAt: (rumor['created_at'] as num?)?.toInt() ?? 0,
          editId: rumor['id'] is String ? rumor['id'] as String : '');
      return;
    }

    final gapStale = gap.stale;
    final gapCutoffMs = gap.cutoffMs;

    if (groupId != null) {
      if (!u.senderVerified || nonMember) return;
      final m = _mapGroupMessage(rumor, u, self, groupId);
      if (m == null) return;
      if (gapStale) m.isHistorical = true;
      final landed = appState.ingestGroupMessage(m, countUnread: !gapStale);
      if (landed) {
        // Every group message re-asserts name and roster so renames reach members who missed the control event.
        appState.mergeGroupFromMessage(
          groupId: groupId,
          name: _tagValue(tags, 'subject') ?? 'Group',
          memberPubkeys: [
            for (final t in tags)
              if (t.length > 1 && t[0] == 'p') t[1],
          ],
          timestampMs: m.createdAt * 1000,
          senderPubkey: senderPubkey,
        );
        final advertised = _tagValue(tags, 'rh');
        if (advertised != null && advertised.isNotEmpty) {
          unawaited(_maybeRepairRoster(groupId, advertised, senderPubkey));
        }
        // `meta_ts` piggybacks the owner's recent metadata change; same owner-only, monotonic guards as control events.
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
      if (!gapStale) {
        _maybeNotifyMessage(m, isGroup: true, alertCutoffMs: gapCutoffMs);
      }
      _maybeBackfillProfiles(m.pubkey);
      // Best-effort delivery receipt to the sender.
      if (!m.isOwn && m.nymMessageId != null) {
        final ek = _groups?.keysFor(groupId);
        _service?.publishReceipt(
          messageId: m.nymMessageId!,
          receiptType: 'delivered',
          recipientPubkey: senderPubkey,
          encryptToPubkey: ek?.encryptionPubkeyFor(senderPubkey, self),
        );
        // Active group view also sends a read receipt; scope-gated and deduped.
        if (_isActiveView(GroupLogic.groupStorageKey(groupId))) {
          unawaited(
              sendGroupReadReceipt(m.nymMessageId!, senderPubkey, groupId));
        }
      }
      return;
    }

    final anonAuthor = _isAnonBotPubkey(rumor['pubkey']);
    if (u.senderVerified &&
        !anonAuthor &&
        senderPubkey.isNotEmpty &&
        !_ref.read(appStateProvider).blockedUsers.contains(senderPubkey)) {
      _notePmSupportToken(senderPubkey, rumor);
    }
    final m = PmLogic.mapPmRumor(
      rumor: rumor,
      wrapId: u.wrapId,
      selfPubkey: anonAuthor ? (rumor['pubkey'] as String) : self,
      senderVerified: u.senderVerified,
      pqEncrypted: u.isPq,
      pqRootFor: (peer) => pqSealRootVerdict(peer) == true,
    );
    if (m == null) return;
    m.expiresAt = u.expiration;
    if (anonAuthor) m.pubkey = self;
    // Our own archived copy says nothing about the recipient's encryption, so ask the recipient's verdict instead.
    if (m.isOwn) {
      final peer = m.conversationPubkey ?? m.pubkey;
      final layered = _pqRegistry.acceptsLayered(peer,
          nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          enabled:
              PqPolicy.enabled(privkey: _identity?.privkey, mode: _pqMode));
      m.pqEncrypted = layered;
      m.pqRoot = layered && pqSealRootVerdict(peer) == true;
    }
    // The announcement may still be in flight; fill the verdict in later.
    if (m.pqEncrypted) {
      _resolvePqRootVerdict(m.conversationPubkey ?? m.pubkey, m.nymMessageId);
    }
    // A known nym wins over the pure mapper's `nym#xxxx` fallback.
    if (m.isOwn) {
      final selfNym = _ref.read(appStateProvider).selfNym;
      if (selfNym.isNotEmpty) m.author = selfNym;
    } else {
      m.author = _nymDisplayFor(m.pubkey);
    }
    // Enforce "Who can PM you"; our own self-copy is always kept.
    if (!m.isOwn) {
      final scope = _ref.read(settingsProvider).acceptPMs;
      if (scope == 'disabled') return;
      if (scope == 'friends' &&
          !_ref.read(appStateProvider).isFriend(m.pubkey)) {
        return;
      }
    }
    // Split a verified bot's `<think>` block at ingest so every arrival path renders it the same.
    if (!m.isOwn && isVerifiedBot(m.pubkey)) {
      final tm =
          RegExp(r'^\s*<think>([\s\S]*?)<\/think>\s*', caseSensitive: false)
              .firstMatch(m.content);
      if (tm != null && m.content.substring(tm.end).trim().isNotEmpty) {
        m.thinking = tm.group(1)?.trim();
        m.content = m.content.substring(tm.end);
      }
      m.isBot = true;
    }
    if (appState.holdForeignBotThread(m)) return;
    if (gapStale) m.isHistorical = true;
    final landed = appState.ingestPMMessage(m, countUnread: !gapStale);
    if (landed && !gapStale) {
      _maybeNotifyMessage(m, isGroup: false, alertCutoffMs: gapCutoffMs);
    }
    _maybeBackfillProfiles(m.pubkey);
    // Delivery receipt back to the sender (not for our own self-copy).
    if (!m.isOwn && m.nymMessageId != null && !anonSuppressSendTo(m.pubkey)) {
      _service?.publishReceipt(
        messageId: m.nymMessageId!,
        receiptType: 'delivered',
        recipientPubkey: m.pubkey,
      );
      // Active PM view also sends a read receipt; scope-gated and deduped.
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
    // Thread reply marker: the root's shared nymMessageId.
    final threadRoot = _tagValue(tags, 'nymthread');
    final createdAtRaw = (rumor['created_at'] as num?)?.toInt() ?? 0;
    final times = EventMapper.rumorTimes(
      key: nymMessageId ?? u.wrapId,
      createdAtRaw: createdAtRaw,
      ms: ms,
    );
    final isOwn = senderPubkey == self;
    if (u.isPq) _resolvePqRootVerdict(senderPubkey, nymMessageId);
    return Message(
      id: u.wrapId.isNotEmpty ? u.wrapId : (nymMessageId ?? ''),
      author: _nymFor(senderPubkey),
      pubkey: senderPubkey,
      content: content,
      createdAt: times.createdAt,
      originalCreatedAt: createdAtRaw,
      ms: ms,
      timestamp: times.timestampMs,
      isOwn: isOwn,
      isGroup: true,
      groupId: groupId,
      conversationKey: GroupLogic.groupStorageKey(groupId),
      eventKind: EventKind.giftWrap,
      nymMessageId: nymMessageId,
      threadRoot: threadRoot,
      senderVerified: u.senderVerified,
      pqEncrypted: u.isPq,
      pqRoot: u.isPq && pqSealRootVerdict(senderPubkey) == true,
      deliveryStatus: isOwn ? DeliveryStatus.sent : DeliveryStatus.delivered,
      expiresAt: u.expiration,
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
    // Backfill profiles for everyone the control event names so non-posting members get avatars.
    _maybeBackfillProfiles(senderPubkey);
    for (final t in tags) {
      if (t.length > 1 && t[0] == 'p') _maybeBackfillProfiles(t[1]);
    }
    if (type == GroupToolsTypes.joinDeclined &&
        _tagValue(tags, 'reason') == 'full' &&
        _lostJoinRace(groupId, tags, senderPubkey, appState)) {
      _leaveFullGroupLocally(groupId);
      return;
    }
    if (GroupToolsTypes.all.contains(type)) {
      unawaited(_ref.read(groupToolsProvider).handleControl(type, tags,
          groupId, senderPubkey, (rumor['created_at'] as num?)?.toInt() ?? 0));
      return;
    }
    // The sender's key was already recorded; a resync request gets a rate-limited reply, never a bubble.
    if (type == GroupControlType.keyResync) {
      final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
      if (senderPubkey != self && _tagValue(tags, 'resync_req') == '1') {
        unawaited(_maybeReplyKeyResync(groupId, senderPubkey));
      }
      return;
    }

    // Shared history after we were added; never displayed as a bubble.
    if (type == GroupControlType.history) {
      final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
      if (senderPubkey != self) {
        _handleGroupHistoryShare(groupId, senderPubkey, rumor);
      }
      return;
    }

    final inviteTs = (rumor['created_at'] as num?)?.toInt() ?? 0;
    final joiningViaInvite =
        _ref.read(groupToolsProvider).isPendingJoin(groupId);
    if (type == GroupControlType.invite ||
        type == GroupControlType.addMember) {
      _ref.read(groupToolsProvider).clearPendingJoin(groupId);
    }
    if (type == GroupControlType.invite) {
      // Clear the left mark first, only if this invite is newer than our leave.
      if (!appState.clearLeftGroup(groupId, createdAtSec: inviteTs)) return;
      final members = tags
          .where((t) => t.length > 1 && t[0] == 'p')
          .map((t) => t[1])
          .toList();
      final owner = _tagValue(tags, 'owner') ?? senderPubkey;
      final name = _tagValue(tags, 'subject') ?? '';
      // Restore the invite's bootstrap metadata so a re-created group isn't a bare shell.
      final avatar = _tagValue(tags, 'avatar');
      final banner = _tagValue(tags, 'banner');
      final description = _tagValue(tags, 'description');
      final mods = tags
          .where((t) => t.length > 1 && t[0] == 'mod')
          .map((t) => t[1])
          .toList();
      final admins = tags
          .where((t) => t.length > 1 && t[0] == 'admin')
          .map((t) => t[1])
          .toList();
      final genesisOwner = _tagValue(tags, 'gowner');
      final genesisNonce = _tagValue(tags, 'gnonce');
      final genesis =
          GroupLogic.verifyGenesis(groupId, genesisOwner, genesisNonce);
      if (genesis == false) return;
      if (genesis == true && senderPubkey != genesisOwner) return;
      // Backfill an existing bare shell from the invite instead of dropping it; creating stays gated below.
      final existingGroup = appState.groupById(groupId);
      if (existingGroup != null) {
        final trusted = GroupLogic.mayRewriteInviteIdentity(
            existingGroup, senderPubkey,
            claimedOwner: owner,
            genesis: genesis,
            genesisOwner: genesisOwner);
        final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
        if (trusted) {
          appState.enrichGroupIdentity(groupId,
              createdBy: owner,
              name: name,
              avatar: avatar,
              banner: banner,
              description: description,
              members: members,
              mods: mods,
              membersAt: _joinAt(inviteTs));
        } else if (senderPubkey == self ||
            GroupLogic.canAddMembers(existingGroup, senderPubkey)) {
          appState.enrichGroupIdentity(groupId,
              members: members, membersAt: _joinAt(inviteTs));
        }
        _processPendingGroupHistory(groupId);
        if (!(senderPubkey == self &&
            (_groups?.isOwnEphemeralPk(
                    groupId, _tagValue(tags, 'ephemeral_pk')) ??
                false))) {
          unawaited(announceGroupEphemeralKey(groupId));
        }
        return;
      }
      final invited = Group(
        id: groupId,
        name: name,
        mods: mods,
        admins: admins,
        createdBy: owner,
        genesisOwner: genesis == true ? genesisOwner : null,
        genesisNonce: genesis == true ? genesisNonce : null,
        avatar: (avatar != null && avatar.isNotEmpty) ? avatar : null,
        banner: (banner != null && banner.isNotEmpty) ? banner : null,
        description: (description != null && description.isNotEmpty)
            ? description
            : null,
        allowMemberInvites: _tagValue(tags, 'allow_invites') != '0',
        inviteEnabled: _tagValue(tags, 'invite_enabled') == '1',
        inviteEpoch: int.tryParse(_tagValue(tags, 'invite_epoch') ?? '') ?? 0,
        shareHistory: _tagValue(tags, 'share_history') == '1',
        lastMessageTime: DateTime.now().millisecondsSinceEpoch,
      );
      invited.joinedVia = senderPubkey;
      if (!_admitBootstrapRoster(
          invited, {for (final pk in members) pk: _joinAt(inviteTs)})) {
        return;
      }
      appState.upsertGroup(invited);
      final createdGroup = appState.groupById(groupId);
      if (createdGroup != null &&
          GroupLogic.applyGroupToolsMeta(createdGroup, tags, inviteTs)) {
        appState.upsertGroup(createdGroup);
      }
      _processPendingGroupHistory(groupId);
      unawaited(announceGroupEphemeralKey(groupId));
      if (_notificationsEnabled &&
          !_ref.read(appStateProvider).blockedUsers.contains(senderPubkey)) {
        // Invite content, else the PWA's fallback line.
        final content = rumor['content'];
        final body = (content is String && content.isNotEmpty)
            ? content
            : tr('You\'ve been added to group "{name}"',
                {'name': name.isNotEmpty ? name : tr('group')});
        // Fresh invites alert loudly; replays record silently, same rule as other notifications.
        final isHistorical = inviteTs <= 0 ||
            _silentForAlert(inviteTs * 1000, liveWindowMs: 30000);
        _dispatchNotification(
          title: tr('Group invite: {name}',
              {'name': name.isNotEmpty ? name : tr('group')}),
          body: body,
          senderPubkey: senderPubkey,
          isFriend: _ref.read(appStateProvider).isFriend(senderPubkey),
          isMention: false,
          isGroup: true,
          historyType: 'group',
          route: groupId,
          eventId: u.wrapId,
          tsMs: inviteTs > 0 ? inviteTs * 1000 : null,
          contextLabel:
              tr('in {name}', {'name': name.isNotEmpty ? name : tr('a group')}),
          silent: isHistorical,
        );
      }
      // Show the invite's content as the new group's first bubble; content-less invites stay empty.
      final inviteMsg =
          _mapGroupMessage(rumor, u, _identity?.pubkey ?? '', groupId);
      if (inviteMsg != null && inviteMsg.content.isNotEmpty) {
        appState.ingestGroupMessage(inviteMsg);
      }
      return;
    }

    // As link sharer, auto-admit valid join requests (invites on, epoch matches); must precede `applyGroupControl`.
    if (type == GroupControlType.rosterReq) {
      final group = appState.groupById(groupId);
      final identity = _identity;
      final groups = _groups;
      if (group == null || identity == null || groups == null) return;
      if (senderPubkey == identity.pubkey) return;
      if (!GroupLogic.canModerate(group, identity.pubkey)) return;
      if (!group.members.contains(senderPubkey)) return;
      final key = '$groupId:$senderPubkey';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if ((_rosterReplyTs[key] ?? 0) > nowMs - kGroupRosterRepairCooldownMs) {
        return;
      }
      _rosterReplyTs[key] = nowMs;
      final replyTags = GroupLogic.buildRosterReplyTags(group, senderPubkey);
      unawaited(groups.sendControl(
        group: group,
        selfPubkey: identity.pubkey,
        type: GroupControlType.roster,
        extraTags: replyTags
            .where((t) => t[0] != 'g' && t[0] != 'subject' && t[0] != 'type')
            .toList(),
        recipients: [senderPubkey],
      ));
      return;
    }

    if (type == GroupControlType.roster) {
      final group = appState.groupById(groupId);
      final identity = _identity;
      if (group == null || identity == null) return;
      if (senderPubkey == identity.pubkey) return;
      if (GroupLogic.applyRoster(group, tags, senderPubkey, identity.pubkey,
          ts: (rumor['created_at'] as num?)?.toInt() ?? 0)) {
        appState.notifyGroupsChanged();
      }
      return;
    }

    if (type == GroupControlType.joinRequest) {
      final group = appState.groupById(groupId);
      if (group == null) return;
      if (!group.inviteEnabled) return;
      final identity = _identity;
      if (identity == null) return;
      // Never act on our own request echoing back.
      if (senderPubkey == identity.pubkey) return;
      final reqEpoch = int.tryParse(_tagValue(tags, 'invite_epoch') ?? '') ?? 0;
      if (group.joinApproval) {
        unawaited(_ref.read(groupToolsProvider).handleJoinRequest(
            group,
            senderPubkey,
            reqEpoch,
            (rumor['created_at'] as num?)?.toInt() ?? 0,
            GroupLogic.canAddMembers(group, identity.pubkey)));
        return;
      }
      if (!GroupLogic.canAddMembers(group, identity.pubkey)) return;
      if (reqEpoch != group.inviteEpoch) return;
      if (group.members.contains(senderPubkey)) return;
      if (group.banned.contains(senderPubkey)) return;
      final rank =
          GroupLogic.joinAdmitRank(group, identity.pubkey, senderPubkey);
      if (rank <= 0) {
        unawaited(addGroupMembers(groupId, [senderPubkey], viaJoin: true));
        return;
      }
      unawaited(Future<void>.delayed(
          Duration(milliseconds: (rank > 6 ? 6 : rank) * kGroupAdmitBackoffMs),
          () {
        final now = appState.groupById(groupId);
        if (now == null) return;
        if (now.members.contains(senderPubkey)) return;
        if (now.banned.contains(senderPubkey)) return;
        if (!GroupLogic.canAddMembers(now, identity.pubkey)) return;
        unawaited(addGroupMembers(groupId, [senderPubkey], viaJoin: true));
      }));
      return;
    }

    // An add-member that re-adds us clears the left mark before `applyGroupControl`.
    if (type == GroupControlType.addMember) {
      final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
      final addsSelf = self.isNotEmpty &&
          tags.any((t) => t.length > 1 && t[0] == 'p' && t[1] == self);
      if (addsSelf) {
        // Only if newer than our leave.
        if (!appState.clearLeftGroup(groupId, createdAtSec: inviteTs)) return;
        // Re-create a fully removed group from the add-member bootstrap, but only when the sender is the claimed owner.
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
        final admins = tags
            .where((t) => t.length > 1 && t[0] == 'admin')
            .map((t) => t[1])
            .toList();
        final genesisOwner = _tagValue(tags, 'gowner');
        final genesisNonce = _tagValue(tags, 'gnonce');
        final genesis =
            GroupLogic.verifyGenesis(groupId, genesisOwner, genesisNonce);
        if (genesis == false) return;
        final existing = appState.groupById(groupId);
        if (existing?.genesisOwner != null &&
            genesis == true &&
            genesisOwner != existing!.genesisOwner) {
          return;
        }
        if (existing == null) {
          if (claimedOwner != null &&
              (claimedOwner == senderPubkey || joiningViaInvite) &&
              (genesis != true || claimedOwner == genesisOwner)) {
            final allowInv = _tagValue(tags, 'allow_invites');
            final inviteEnabledTag = _tagValue(tags, 'invite_enabled');
            final inviteEpochTag = _tagValue(tags, 'invite_epoch');
            final joined = Group(
              id: groupId,
              name: name,
              mods: mods,
              admins: admins,
              createdBy: claimedOwner,
              genesisOwner: genesis == true ? genesisOwner : null,
              genesisNonce: genesis == true ? genesisNonce : null,
              avatar: (avatar != null && avatar.isNotEmpty) ? avatar : null,
              banner: (banner != null && banner.isNotEmpty) ? banner : null,
              description: (description != null && description.isNotEmpty)
                  ? description
                  : null,
              allowMemberInvites: allowInv != null ? allowInv != '0' : true,
              inviteEnabled: inviteEnabledTag == '1',
              inviteEpoch: int.tryParse(inviteEpochTag ?? '') ?? 0,
              shareHistory: _tagValue(tags, 'share_history') == '1',
              lastMessageTime: inviteTs > 0
                  ? inviteTs * 1000
                  : DateTime.now().millisecondsSinceEpoch,
            );
            joined.joinedVia = senderPubkey;
            if (!_admitBootstrapRoster(joined, {
              for (final pk in members) pk: pk == self ? _joinAt(inviteTs) : 0,
            })) {
              return;
            }
            appState.upsertGroup(joined);
            final created = appState.groupById(groupId);
            if (created != null &&
                GroupLogic.applyGroupToolsMeta(created, tags, inviteTs)) {
              appState.upsertGroup(created);
            }
          }
        } else {
          // Backfill a known shell group's owner and appearance; safe since we're already in it.
          appState.enrichGroupIdentity(groupId,
              createdBy: claimedOwner,
              name: name,
              avatar: avatar,
              banner: banner,
              description: description,
              members: members,
              mods: mods,
              membersAt: _joinAt(inviteTs));
        }
      }
    }

    final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
    // Resolve the name first: a self-kick drops the group, but the notification still needs it.
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
    // A shared-history blob can arrive before the group exists; apply any stashed one now.
    if (type == GroupControlType.addMember) {
      _processPendingGroupHistory(groupId);
      final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
      if (!(senderPubkey == self &&
          (_groups?.isOwnEphemeralPk(
                  groupId, _tagValue(tags, 'ephemeral_pk')) ??
              false))) {
        unawaited(announceGroupEphemeralKey(groupId));
      }
    }
  }

  /// Notifies when an inbound control targets us (not our own or blocked senders'); historical ones are silent.
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
    if (senderPubkey == self) return;
    if (!_notificationsEnabled) return;
    final appState = _ref.read(appStateProvider);
    if (appState.blockedUsers.contains(senderPubkey)) return;

    // Fallback chain `grp.name || groupName`, where groupName defaults to 'Group'.
    final name = (groupName != null && groupName.isNotEmpty)
        ? groupName
        : (_tagValue(tags, 'subject') ?? tr('Group'));
    final actor = _nymDisplayFor(senderPubkey);

    String? title;
    String? body;
    switch (type) {
      case GroupControlType.removeMember:
        // Self-kick/ban only; the `kick` tag is the removed member.
        if (_tagValue(tags, 'kick') != self) return;
        final banned =
            tags.any((t) => t.length > 1 && t[0] == 'ban' && t[1] == '1');
        title = banned
            ? tr('Banned from {name}', {'name': name})
            : tr('Removed from {name}', {'name': name});
        body = banned
            ? tr(
                '{actor} banned you. You can be re-invited only by the group owner.',
                {'actor': actor})
            : tr('{actor} removed you from the group.', {'actor': actor});
      case GroupControlType.promoteMod:
        if (_tagValue(tags, 'mod') != self) return;
        title = tr('Promoted in {name}', {'name': name});
        body = tr('{actor} made you a moderator.', {'actor': actor});
      case GroupControlType.revokeMod:
        if (_tagValue(tags, 'mod') != self) return;
        title = tr('Moderator removed in {name}', {'name': name});
        body = tr('{actor} revoked your moderator role.', {'actor': actor});
      case GroupControlType.transferOwner:
        if (_tagValue(tags, 'owner') != self) return;
        title = tr('Owner of {name}', {'name': name});
        body =
            tr('{actor} transferred group ownership to you.', {'actor': actor});
      case GroupControlType.unban:
        if (_tagValue(tags, 'unban') != self) return;
        title = tr('Unbanned from {name}', {'name': name});
        body = tr('{actor} unbanned you from "{name}". You may be re-invited.',
            {'actor': actor, 'name': name});
      default:
        return;
    }

    // Historical (>10s) or catch-up events record to history only.
    final silent = _silentForAlert(ts * 1000);

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

  /// Emits the in-chat system line for an applied group control; skipped when we were removed.
  void _emitGroupControlSystemLine(
    String groupId,
    String type,
    List<List<String>> tags,
    String senderPubkey,
  ) {
    final appState = _ref.read(appStateProvider.notifier);
    // We may have just been kicked; don't recreate an orphan message list.
    if (appState.groupById(groupId) == null) return;
    final actor = _nymDisplayFor(senderPubkey);
    String? line;
    switch (type) {
      case GroupControlType.leave:
        line = tr('{actor} left the group.', {'actor': actor});
      case GroupControlType.removeMember:
        final target = _tagValue(tags, 'kick');
        if (target == null) break;
        final banned =
            tags.any((t) => t.length > 1 && t[0] == 'ban' && t[1] == '1');
        line = banned
            ? tr('{target} was banned by {actor}.',
                {'target': _nymDisplayFor(target), 'actor': actor})
            : tr('{target} was removed by {actor}.',
                {'target': _nymDisplayFor(target), 'actor': actor});
      case GroupControlType.addMember:
        final added = tags
            .where((t) => t.length > 1 && t[0] == 'p')
            .map((t) => _nymDisplayFor(t[1]))
            .toList();
        if (added.isEmpty) break;
        line = tr('{names} was added by {actor}.',
            {'names': added.join(', '), 'actor': actor});
      case GroupControlType.promoteMod:
        final target = _tagValue(tags, 'mod');
        if (target != null) {
          line = tr('{actor} made {target} a moderator.',
              {'actor': actor, 'target': _nymDisplayFor(target)});
        }
      case GroupControlType.revokeMod:
        final target = _tagValue(tags, 'mod');
        if (target != null) {
          line = tr('{actor} removed {target} as a moderator.',
              {'actor': actor, 'target': _nymDisplayFor(target)});
        }
      case GroupControlType.transferOwner:
        final target = _tagValue(tags, 'owner');
        if (target != null) {
          line = tr('{actor} transferred ownership to {target}.',
              {'actor': actor, 'target': _nymDisplayFor(target)});
        }
      case GroupControlType.unban:
        final target = _tagValue(tags, 'unban');
        if (target != null) {
          line = tr('{target} was unbanned by {actor}.',
              {'target': _nymDisplayFor(target), 'actor': actor});
        }
      case GroupControlType.deleteMessage:
        final author = _tagValue(tags, 'target_pubkey');
        line = author != null
            ? tr('{actor} deleted a message from {target}.',
                {'actor': actor, 'target': _nymDisplayFor(author)})
            : tr('{actor} deleted a message.', {'actor': actor});
    }
    if (line == null || line.isEmpty) return;
    appState.addSystemMessage(line,
        storageKey: GroupLogic.groupStorageKey(groupId));
  }

  void _onReceiptOrTyping(
      Map<String, dynamic> rumor, AppStateNotifier appState) {
    if (_onOnceOpenedReceipt(rumor)) return;
    if (_ref
        .read(chatToolsProvider)
        .handleKeepRumor(rumor, rumor['pubkey'] as String? ?? '')) {
      return;
    }
    if (PmLogic.isTyping(rumor)) {
      final info = PmLogic.parseTyping(rumor);
      if (info == null || info.pubkey == null) return;
      // Stale typing indicators (older than 5s) are dropped.
      final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 -
          ((rumor['created_at'] as num?)?.toInt() ?? 0);
      final ttl = info.ttlSec > 0 ? (info.ttlSec > 30 ? 30 : info.ttlSec) : 5;
      if (age > ttl) return;
      final typingGroup = info.groupId;
      if (typingGroup != null) {
        final group = appState.groupById(typingGroup);
        if (group == null || !GroupLogic.isMember(group, info.pubkey!)) return;
      }
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
        // A receipt acks the PM, so drop it from the retry queue.
        _pendingDms.remove(info.messageId);
      }
    }
  }

  void _onPrivateReaction(
      Map<String, dynamic> rumor, AppStateNotifier appState) {
    final tags = _tags(rumor);
    // Register NIP-30 emoji before routing so private custom reactions resolve.
    if (tags.isNotEmpty) {
      _ref.read(liveCustomEmojiProvider.notifier).ingestEmojiTags(tags);
    }
    final target = _tagValue(tags, 'e');
    if (target == null) return;
    final pubkey = rumor['pubkey'] as String? ?? '';
    final content = rumor['content'] as String? ?? '';
    final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
    final action =
        tags.any((t) => t.length > 1 && t[0] == 'action' && t[1] == 'remove');
    final batchTag = _tagValue(tags, 'batch');
    if (batchTag != null && batchTag.isNotEmpty) {
      List<dynamic>? extra;
      try {
        final decoded = jsonDecode(batchTag);
        if (decoded is List) extra = decoded;
      } catch (_) {}
      if (extra != null) {
        final hexRe = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
        for (final raw in extra.take(64)) {
          if (raw is! Map) continue;
          final e = raw['e'];
          final c = raw['c'];
          if (e is! String || !hexRe.hasMatch(e)) continue;
          if (c is! String || c.isEmpty) continue;
          final rest = Map<String, dynamic>.from(rumor);
          rest['content'] = c;
          rest['tags'] = [
            for (final t in tags)
              if (t.isNotEmpty &&
                  t[0] != 'e' &&
                  t[0] != 'action' &&
                  t[0] != 'batch')
                t,
            ['e', e],
            if (raw['a'] == 'remove') ['action', 'remove'],
          ];
          _onPrivateReaction(rest, appState);
        }
      }
    }
    // The reacted message's author; group reactions also carry `g` for routing.
    final targetAuthor = _tagValue(tags, 'p') ?? '';
    final groupId = _tagValue(tags, 'g');
    if (groupId != null) {
      final group = appState.groupById(groupId);
      if (group == null || !GroupLogic.isMember(group, pubkey)) return;
    }
    final synthetic = NostrEvent(
      pubkey: pubkey,
      createdAt: ts,
      kind: EventKind.reaction,
      tags: [
        ['e', target],
        ['p', targetAuthor.isNotEmpty ? targetAuthor : pubkey],
        if (action) ['action', 'remove'],
        // Keep the rumor's NIP-30 emoji tags on the synthetic event.
        for (final t in tags)
          if (t.length >= 3 && t[0] == 'emoji') ['emoji', t[1], t[2]],
      ],
      content: content,
    );
    appState.ingestEvent(synthetic);

    // Notify when someone reacts to our PM/group message; skip removals.
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

  /// Accrues a gift-wrapped private zap (`e`, `p`, `bolt11` tags) to the zapped message.
  void _onPrivateZap(
      Map<String, dynamic> rumor, AppStateNotifier appState, String wrapId) {
    final tags = _tags(rumor);
    final messageId = _tagValue(tags, 'e');
    final bolt11 = _tagValue(tags, 'bolt11');
    if (messageId == null || bolt11 == null) return;
    final amount = ZapLogic.parseAmountFromBolt11(bolt11);
    if (amount == null) return;
    final zapper = rumor['pubkey'] as String? ?? '';
    final zapGroup = _tagValue(tags, 'g');
    if (zapGroup != null) {
      final group = appState.groupById(zapGroup);
      if (group == null || !GroupLogic.isMember(group, zapper)) return;
    }
    // Zapper-signed, so unverified; bolt11 dedup lets a verified self-record upgrade it without double-counting.
    final counted = appState.recordMessageZap(
      messageId: messageId,
      zapperPubkey: zapper,
      amountSats: amount,
      dedupKey: ZapLogic.dedupKey(bolt11: bolt11, eventId: ''),
      verified: false,
    );
    // Resolve the zapper's avatar.
    if (zapper.isNotEmpty) _maybeBackfillProfiles(zapper);
    // Notify only on a freshly counted zap to us from someone else.
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

  /// Ids of zap receipts we published, so their echo is ignored; capped.
  final Set<String> _ownPublishedZapIds = <String>{};

  /// Accrues a public zap receipt to our message, verified when authored by the LNURL provider; deduped by bolt11.
  void _onPublicZapReceipt(NostrEvent event, AppStateNotifier appState) {
    // Ignore the receipt we just published ourselves echoing back.
    if (_ownPublishedZapIds.contains(event.id)) return;
    if (_ref.read(appStateProvider).blockedUsers.contains(event.pubkey)) return;

    // Archive to D1 for `zap-get` backfill; scope gating lives in [ZapArchive.archive].
    if (event.tagValue('bolt11') != null) _zapArchive?.archive(event);

    final info = ZapLogic.parseReceipt(event);
    if (info == null) {
      // No `e` tag: a profile zap to us still notifies; everything else is dropped.
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

    // Verified when the receipt author is the recipient's LNURL provider.
    _getZapProviderPubkey(recipientPubkey).then((providerPubkey) {
      final verified = providerPubkey != null &&
          event.pubkey.toLowerCase() == providerPubkey;
      // Falls back to the receipt author, which is correct for both provider and peer-published receipts.
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
      // Notify on a fresh zap to us from someone else when verified or the recipient has no provider.
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

  /// recipient → lowercased LNURL provider pubkey, or null.
  final Map<String, String?> _zapProviderPubkeys = {};
  final Map<String, Future<String?>> _zapProviderLookups = {};

  /// Resolves [recipientPubkey]'s LNURL provider pubkey (cached, deduped); null when unavailable.
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

  // Call signaling (kind 25053); transport only.

  void Function(Map<String, dynamic> rumor)? _callSignalHandler;

  /// Registers the handler that receives decoded call-signaling rumors.
  void setCallSignalHandler(void Function(Map<String, dynamic> rumor)? fn) {
    _callSignalHandler = fn;
  }

  /// Gift-wraps a call-signaling rumor to [to] (no self-copy); [groupId] wraps to the group ephemeral key when known.
  Future<bool> sendCallSignal({
    required String to,
    required Map<String, dynamic> payload,
    String? groupId,
  }) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Inject our nym into every signal so the callee can label the caller before a profile arrives.
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
    // Group signals ride the group ephemeral key, falling back to the durable key.
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

  // Outbound: composer send and entry points.

  /// Sends [text] to the current view: optimistic echo, then publish.
  Future<void> sendCurrent(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // Route slash commands to the command handler.
    if (isCommandLine(trimmed)) {
      _dispatcher.handle(trimmed);
      return;
    }

    // `?` commands and @Nymbot mentions in a channel route to the bot.
    if (shouldRouteToBot(trimmed)) {
      await routeToBot(trimmed);
      return;
    }

    await _sendMessageContent(trimmed);
  }

  // Anon-nym word lists for pseudonymous sends.
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

  /// Sends to the active channel under a fresh ephemeral key and anon nym; PM/group views use the real key.
  Future<bool> sendCurrentPseudonymous(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (isCommandLine(trimmed)) {
      _dispatcher.handle(trimmed);
      return false;
    }
    final view = _ref.read(appStateProvider).view;
    if (view.kind != ViewKind.channel) return false;
    final threadTarget = _threadBotTarget();
    final ask = anonNymbotTriggers(
      body: _quoteBody(trimmed),
      quoteAuthor: _quotedAuthor(trimmed) ?? '',
      threadBot: threadTarget != null,
    );
    if (!ask) return (await _sendChannelPseudonymous(trimmed)) != null;
    final blocked = anonNymbotBlocker(
      apiHost: true,
      mesh: _ref
              .read(meshControllerProvider.notifier)
              .bridge
              ?.shouldSendOverMesh(view) ??
          false,
    );
    final request = blocked == null
        ? await _botChannelRequest(trimmed, threadTarget, anon: true)
        : null;
    final sender = await _sendChannelPseudonymous(trimmed);
    if (sender == null) return false;
    if (blocked != null) {
      unawaited(Future<void>(() => _anonBotNotice(blocked)));
    } else if (request != null) {
      unawaited(_askNymbotAnonymously(request, sender, view.storageKey));
    }
    return true;
  }

  Future<void> _askNymbotAnonymously(Map<String, dynamic> request,
      ({String nym, String pubkey}) sender, String storageKey) async {
    _setBotChannelThinking(storageKey, true);
    String? reason;
    var answered = false;
    try {
      answered = await _postBotChannelRequest({
        ...request,
        'senderNym': anonNymbotSenderNym(sender.nym, sender.pubkey),
      }, storageKey);
      if (!answered) reason = 'failed';
    } on ApiException catch (e) {
      reason = anonNymbotOutcome(e.statusCode, false);
    } catch (_) {
      reason = 'failed';
    }
    if (!answered) _setBotChannelThinking(storageKey, false);
    _anonBotNotice(reason);
  }

  void _anonBotNotice(String? reason) {
    final text = anonNymbotNotice(reason);
    if (text.isNotEmpty) showToast(tr(text));
  }

  /// Publishes one pseudonymous channel message; never records presence, which would link it to the user.
  Future<({String nym, String pubkey})?> _sendChannelPseudonymous(
      String content) async {
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final view = state.view;
    _markDirty(view.storageKey);

    String? threadRoot;
    final at = _ref.read(activeThreadProvider);
    if (at != null && at.view == view && appThreadsEnabled) {
      threadRoot = at.rootId;
    }

    final ephemeralSigner = LocalSigner(keys.generatePrivateKey());
    final anonNym = _generateAnonNym();

    final echo = appState.sendLocal(
      content,
      pubkeyOverride: ephemeralSigner.pubkey,
      authorOverride: anonNym,
      threadRoot: threadRoot,
    );
    final publishHook = pseudonymousPublishForTest;
    if (service == null && publishHook == null) return null;
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    try {
      final signed = publishHook != null
          ? await publishHook(content, ephemeralSigner, anonNym, threadRoot)
          : await service!.publishChannelMessage(
              channelKey: view.id,
              content: content,
              nym: anonNym,
              geohash: isGeo ? view.id : null,
              emojiTags: _contentTags(content),
              powDifficulty: _ref.read(settingsProvider.notifier).powDifficulty,
              signerOverride: ephemeralSigner,
              threadRoot: threadRoot,
            );
      if (signed != null && echo != null) {
        appState.replaceOptimistic(
          echo.id,
          signed.id,
          realCreatedAt: signed.createdAt,
          realMs: int.tryParse(signed.tagValue('ms') ?? ''),
          powTarget: EventMapper.powTargetOf(signed),
        );
      }
      return signed != null
          ? (nym: anonNym, pubkey: ephemeralSigner.pubkey)
          : null;
    } catch (_) {
      if (echo != null) appState.markOptimisticFailed(echo.id);
      return null;
    }
  }

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

  // PM auto-retry: re-publish unacked PMs every 5s up to 3 times; a missing receipt means offline, not failure.

  /// Re-send cadence and cap.
  static const int _kDmRetryCheckMs = 5000;
  static const int _kDmRetryMaxAttempts = 3;

  /// Sent-but-unacked PMs keyed by `nymMessageId`.
  final Map<String, _PendingDm> _pendingDms = <String, _PendingDm>{};

  // Mesh sender outbox.

  /// Sends the mesh carried while offline, published to Nostr once relays return; drops fail the bubble.
  late final MeshOutbox _meshOutbox = MeshOutbox(onDropped: (localId) {
    try {
      _ref.read(appStateProvider.notifier).markOptimisticFailed(localId);
    } catch (_) {}
    _persistMeshOutbox();
  });

  bool _meshOutboxLoaded = false;
  bool _flushingMeshOutbox = false;

  /// Loads the persisted outbox so sends queued before a kill survive the restart.
  void _loadMeshOutbox() {
    if (_meshOutboxLoaded) return;
    _meshOutboxLoaded = true;
    try {
      _meshOutbox.decode(
          _ref.read(keyValueStoreProvider).getString(StorageKeys.meshOutbox));
    } catch (_) {}
  }

  void _persistMeshOutbox() {
    try {
      unawaited(_ref
          .read(keyValueStoreProvider)
          .setString(StorageKeys.meshOutbox, _meshOutbox.encode()));
    } catch (_) {}
  }

  /// Retains a mesh-carried send for republishing; the caller excludes ghost-pinned and mesh-only peers.
  void enqueueMeshOutbox(MeshOutboxEntry entry) {
    _loadMeshOutbox();
    _meshOutbox.add(entry);
    _persistMeshOutbox();
  }

  /// Attaches the send-time signed event to a queued entry; ignored if the entry is gone.
  void attachMeshOutboxSignedEvent(String localId, Map<String, dynamic> event) {
    _loadMeshOutbox();
    if (_meshOutbox.attachSignedEvent(localId, event)) _persistMeshOutbox();
  }

  /// Publishes the outbox oldest first, on reconnect and once after boot; re-entrant calls are ignored.
  Future<void> flushMeshOutbox() async {
    _loadMeshOutbox();
    if (_flushingMeshOutbox) return;
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;
    if (_ref.read(appStateProvider).connectedRelays == 0) return;
    final due = _meshOutbox.due(DateTime.now().millisecondsSinceEpoch);
    if (due.isEmpty) {
      _persistMeshOutbox(); // A prune may have emptied it.
      return;
    }
    _flushingMeshOutbox = true;
    try {
      for (final entry in due) {
        final sent = await _publishMeshOutboxEntry(entry, service, identity);
        if (sent) {
          _meshOutbox.remove(entry.localId);
        } else {
          // `noteAttempt` drops and fails the bubble at the ceiling.
          _meshOutbox.noteAttempt(entry.localId);
        }
      }
    } finally {
      _flushingMeshOutbox = false;
      _persistMeshOutbox();
    }
  }

  /// The one place a mesh-carried channel send becomes a Nostr event, shared by replay and gateway mode.
  Future<NostrEvent?> _channelEventForOutbox({
    required NostrService service,
    required Identity identity,
    required String channelKey,
    required String content,
    required int createdAtSec,
    required bool buildOnly,
    String? threadRoot,
    String? meshMessageId,
  }) {
    final isGeo = _ref
        .read(appStateProvider)
        .channels
        .any((c) => c.key == channelKey.toLowerCase() && c.isGeohash);
    return service.publishChannelMessage(
      buildOnly: buildOnly,
      channelKey: channelKey,
      content: content,
      nym: identity.nym,
      geohash: isGeo ? channelKey : null,
      emojiTags: _ref
          .read(liveCustomEmojiProvider.notifier)
          .emojiTagsForContent(content),
      powDifficulty: _ref.read(settingsProvider.notifier).powDifficulty,
      threadRoot: threadRoot,
      createdAtSec: createdAtSec,
      extraTags: [
        if ((meshMessageId ?? '').isNotEmpty) ['nymmesh', meshMessageId!],
      ],
    );
  }

  /// Signs the event a mesh-carried channel send would publish, for a gateway peer to relay; null without a signer.
  Future<NostrEvent?> buildMeshOutboxEvent({
    required String channelKey,
    required String content,
    required int createdAtSec,
    String? threadRoot,
    String? meshMessageId,
  }) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return null;
    try {
      return await _channelEventForOutbox(
        service: service,
        identity: identity,
        channelKey: channelKey,
        content: content,
        createdAtSec: createdAtSec,
        threadRoot: threadRoot,
        meshMessageId: meshMessageId,
        buildOnly: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Publishes a self-signed event as-is; null when unparseable so the caller rebuilds.
  Future<NostrEvent?> _republishSignedEvent(
    Map<String, dynamic> raw,
    NostrService service,
  ) async {
    try {
      final event = NostrEvent.fromJson(raw);
      var geo = '';
      for (final t in event.tags) {
        if (t.length >= 2 && t[0] == 'g') {
          geo = t[1];
          break;
        }
      }
      if (event.kind == EventKind.geoChannel && geo.isNotEmpty) {
        final closest = service
            .closestGeoRelays(geo)
            .map((r) => r.url)
            .toList(growable: false);
        await service.pool.publishGeo(event, closest);
      } else {
        await service.pool.publish(event);
      }
      return event;
    } catch (_) {
      return null;
    }
  }

  /// Publishes one retained send; returns whether it went out.
  Future<bool> _publishMeshOutboxEntry(
    MeshOutboxEntry entry,
    NostrService service,
    Identity identity,
  ) async {
    try {
      switch (entry.kind) {
        case MeshOutboxKind.channel:
          // Prefer the send-time event so a gateway's earlier copy dedups on the same id.
          final stashed = entry.signedEvent;
          if (stashed != null) {
            final replayed = await _republishSignedEvent(stashed, service);
            if (replayed != null) {
              _ref.read(appStateProvider.notifier).replaceOptimistic(
                    entry.localId,
                    replayed.id,
                    realCreatedAt: replayed.createdAt,
                    powTarget: EventMapper.powTargetOf(replayed),
                  );
              return true;
            }
            // Fall through and rebuild rather than lose the message.
          }
          final signed = await _channelEventForOutbox(
            service: service,
            identity: identity,
            channelKey: entry.target,
            content: entry.content,
            createdAtSec: entry.createdAtSec,
            threadRoot: entry.threadRoot,
            meshMessageId: entry.meshMessageId,
            buildOnly: false,
          );
          if (signed == null) return false;
          // Give the mesh placeholder the real id so our relay echo reconciles onto it.
          _ref.read(appStateProvider.notifier).replaceOptimistic(
                entry.localId,
                signed.id,
                realCreatedAt: signed.createdAt,
                powTarget: EventMapper.powTargetOf(signed),
              );
          return true;
        case MeshOutboxKind.pm:
          final nymMessageId =
              entry.nymMessageId ?? entry.meshMessageId ?? entry.localId;
          final rumor = PmLogic.buildPmRumor(
            selfPubkey: identity.pubkey,
            recipientPubkey: entry.target,
            content: entry.content,
            nymMessageId: nymMessageId,
            // Keep the original send time.
            nowSec: entry.createdAtSec,
            nowMs: entry.createdAtSec * 1000,
            extraTags: [
              if ((entry.threadRoot ?? '').isNotEmpty)
                ['nymthread', entry.threadRoot!],
            ],
          );
          // `onWrap` archives to D1; replays must archive like live sends or offline recipients never get them.
          await _publishDualPm(
            rumor: rumor,
            recipientPubkey: entry.target,
            onWrap: _archiveSentWrap,
          );
          return true;
      }
    } catch (_) {
      return false;
    }
  }

  Timer? _dmRetryTimer;

  /// Peers who sent us a Bitchat-format PM; they also get a `bitchat1:` wrap.
  final Set<String> _bitchatUsers = <String>{};

  /// When each peer's last Bitchat-format wrap opened (0 when unknown), weighed against their announcement.
  final Map<String, int> _bitchatSeenAt = <String, int>{};

  int _nowSecForBitchat() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Live PQ values as copyable diagnostics text.
  String pqDiagnosticsText() {
    final identity = _identity;
    if (identity == null) return 'not signed in';
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // ML-KEM is compiled in, so support is constant here.
    const supported = true;
    final modeOff = _pqMode == PqMode.off;
    final capable = PqPolicy.capable(privkey: identity.privkey, root: _pqRoot);
    final out = <String>[
      'supported=$supported capable=$capable '
          'enabled=${PqPolicy.enabled(privkey: identity.privkey, mode: _pqMode)}',
      'mode=$_pqMode epoch=$_pqEpoch devices=${_pqDevices.length}',
      'root: held=${_pqRoot != null} settled=$_pqRootSettled '
          'locked=$_pqRootLocked',
      'announced: ${_pqLastPublishMs == 0 ? 'never this session' : '${(DateTime.now().millisecondsSinceEpoch - _pqLastPublishMs) ~/ 1000}s ago'}'
          ' withKey=${_pqSelfSignedAnnouncement != null}',
      '',
    ];
    final peers = _appPmPeers();
    out.add('${peers.length} PM contact${peers.length == 1 ? '' : 's'}:');
    for (final pk in peers) {
      final key = _pqRegistry.keyFor(pk, nowSec: nowSec, enabled: true);
      final layered =
          _pqRegistry.acceptsLayered(pk, nowSec: nowSec, enabled: true);
      final announcedAt = _pqRegistry.announcedAtFor(pk, nowSec: nowSec);
      final bitchatAt = _bitchatSeenAt[pk] ?? 0;
      final miss = _pqLookupLimiter.missedAt(pk);
      final why = pqPeerDiagnosis(
        supported: supported,
        modeOff: modeOff,
        haveEntry: _pqRegistry.isKnownNymchatClient(pk, nowSec: nowSec),
        haveKey: key != null,
        acceptsLayered: layered,
        lookupAgeSec: miss == null
            ? null
            : (DateTime.now().millisecondsSinceEpoch - miss) ~/ 1000,
      );
      out
        ..add('  ${pk.substring(0, 8)}… -> '
            '${why == 'post-quantum' ? 'POST-QUANTUM' : 'classical'}')
        ..add('    $why')
        ..add('    key=${key != null} layered=$layered '
            'announced=${announcedAt == 0 ? '-' : '${nowSec - announcedAt}s ago'} '
            'bitchatSeen=${bitchatAt == 0 ? 'never' : '${nowSec - bitchatAt}s ago'}');
    }
    return out.join('\n');
  }

  /// The PM peers the diagnostics reports on.
  List<String> _appPmPeers() {
    final seen = <String>{};
    for (final key in _ref.read(appStateProvider).messages.keys) {
      if (!key.startsWith('pm-')) continue;
      final pk = key.substring(3);
      if (pk.length == 64 && pk != _identity?.pubkey) seen.add(pk);
    }
    return seen.toList();
  }

  void _noteBitchatFormatSeen(String pubkey, int atSec) {
    if (pubkey.isEmpty) return;
    _bitchatUsers.add(pubkey);
    if (atSec > (_bitchatSeenAt[pubkey] ?? 0)) _bitchatSeenAt[pubkey] = atSec;
    while (_bitchatSeenAt.length > 5000) {
      _bitchatSeenAt.remove(_bitchatSeenAt.keys.first);
    }
  }

  /// Peers who sent Nymchat-format PMs/receipts get NIP-17; unknown peers get both formats.
  final Set<String> _nymUsers = <String>{};

  /// Announced ML-KEM keys by pubkey.
  final PqRegistry _pqRegistry = PqRegistry();

  /// First-seen clamps for future-dated events, shared with [EventMapper].
  final EventTimeCeilings _eventTimeCeilings = EventTimeCeilings();

  Timer? _eventTimeCeilingsPersistTimer;
  void _schedulePersistEventTimeCeilings() {
    if (_eventTimeCeilingsPersistTimer != null) return;
    if (PanicWipe.inProgress) return;
    _eventTimeCeilingsPersistTimer = Timer(const Duration(seconds: 5), () {
      _eventTimeCeilingsPersistTimer = null;
      final cache = _cache;
      if (cache == null || !cache.isOpen) return;
      unawaited(cache
          .saveMetaMap(
              CacheStore.metaEventTimeCeilings, _eventTimeCeilings.toJson())
          .catchError((_) {}));
    });
  }

  /// In-flight and recently failed announcement lookups, so racing sends share one and keyless peers aren't re-queried.
  final Map<String, Future<void>> _pqLookups = {};
  final PqLookupLimiter _pqLookupLimiter = PqLookupLimiter();

  /// Max time a send waits on a peer's announcement; a classical first message beats one that never leaves.
  static const int _pqSendLookupBudgetMs = 1500;

  /// Cap on one prefetch sweep.
  static const int _pqPrefetchMax = 60;

  /// Ensures [pubkey]'s announcement has been looked up once; resolves either way.
  Future<void> ensurePqAnnouncement(String pubkey) {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return Future<void>.value();
    if (!PqPolicy.enabled(privkey: identity.privkey, mode: _pqMode)) {
      return Future<void>.value();
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nowSec = nowMs ~/ 1000;
    // Only a fresh, usable layered entry ends the search; keyless or stale entries look again.
    final announcedAt = _pqRegistry.announcedAtFor(pubkey, nowSec: nowSec);
    final staleVsBitchat =
        announcedAt > 0 && (_bitchatSeenAt[pubkey] ?? 0) > announcedAt;
    if (!staleVsBitchat &&
        _pqRegistry.acceptsLayered(pubkey, nowSec: nowSec, enabled: true)) {
      return Future<void>.value();
    }
    final existing = _pqLookups[pubkey];
    if (existing != null) return existing;
    // Rate-limited so keyless peers aren't re-queried on every send.
    if (!_pqLookupLimiter.due(pubkey,
        nowMs: nowMs,
        announcedAtSec: announcedAt,
        keyless: _pqRegistry.keyFor(pubkey, nowSec: nowSec, enabled: true) ==
            null)) {
      return Future<void>.value();
    }
    var answered = false;
    final f = _pqAnnouncementSource()
        .resolve(
      pubkey,
      ingest: (event) => _ingestPqAnnouncementForKey(event, pubkey),
      relays: () => service.fetchPqAnnouncement(
        pubkey,
        found: () =>
            _pqRegistry.keyFor(
              pubkey,
              nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
              enabled: true,
            ) !=
            null,
      ),
    )
        .then((v) {
      answered = v;
    }).whenComplete(() {
      _pqLookups.remove(pubkey);
      final ms = DateTime.now().millisecondsSinceEpoch;
      // A keyless result counts as a miss for the rate limit.
      _pqLookupLimiter.record(
        pubkey,
        found: _pqRegistry.keyFor(pubkey, nowSec: ms ~/ 1000, enabled: true) !=
            null,
        answered: answered,
        nowMs: ms,
      );
    });
    // Bounded and error-swallowing because the send path awaits it; later callers share the bounded future.
    final bounded = f
        .timeout(
          const Duration(milliseconds: _pqSendLookupBudgetMs),
          onTimeout: () {},
        )
        .catchError((_) {});
    _pqLookups[pubkey] = bounded;
    return bounded;
  }

  /// Contacts we hold a live PQ key for, shown in settings.
  int get pqKnownPeerCount => _pqRegistry
      .knownPeers(nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000)
      .length;

  PqAnnouncementSource _pqAnnouncementSource() {
    final sync = _storageSync;
    final service = _service;
    return PqAnnouncementSource(
      pqKey: sync == null ? null : (_ref.read(pqKeyFetchProvider) ?? sync.pqKey),
      archive: sync == null
          ? null
          : (pk) => sync.channelGetByAuthor(AppDataTopic.postQuantum, pk),
      verify: service == null
          ? (_) async => false
          : service.verifyEvent,
    );
  }

  bool _ingestPqAnnouncementForKey(NostrEvent event, String pubkey) {
    _ingestPqAnnouncement(event);
    return _pqRegistry.keyFor(
          pubkey,
          nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          enabled: true,
        ) !=
        null;
  }

  /// Warms announcements for a conversation's members before the first send.
  void prefetchPqAnnouncements(Iterable<String> pubkeys) {
    var n = 0;
    for (final pk in pubkeys) {
      if (!TrustGraph.isHex64(pk)) continue;
      if (++n > _pqPrefetchMax) break;
      unawaited(ensurePqAnnouncement(pk));
    }
  }

  /// Whether we send PQ and advertise receiving it; an upgrade defaults off (see [PqPolicy.initialMode]).
  PqMode _pqMode = PqMode.off;

  /// Wall clock of our last announcement publish, for the daily republish.
  int _pqLastPublishMs = 0;

  /// Our last signed announcement, handed to the Nymbot worker so replies can seal PQ without a lookup.
  NostrEvent? _pqSelfSignedAnnouncement;

  /// Wire form of the last announcement, or null before this session's first publish.
  Map<String, dynamic>? get pqSelfAnnouncementJson =>
      _pqSelfSignedAnnouncement?.toJson();

  /// Our announcement's device roster, merged on republish.
  List<PqDevice> _pqDevices = const [];

  PqMode get pqMode => _pqMode;

  /// True when this install was upgraded into PQ and the user hasn't been told.
  bool get pqUpgradeNoticePending =>
      _ref.read(keyValueStoreProvider).getString(StorageKeys.pqUpgradeNotice) ==
      'pending';

  Future<void> dismissPqUpgradeNotice() async =>
      _ref.read(keyValueStoreProvider).remove(StorageKeys.pqUpgradeNotice);

  /// Whether this device still needs the link prompt, e.g. a fresh install on an account with a root; shown once.
  bool get pqRootLinkPromptPending {
    if (!pqRootLinkNeeded) return false;
    final self = _identity?.pubkey ?? '';
    return _ref
            .read(keyValueStoreProvider)
            .getString('nym_pq_link_prompt_$self') !=
        'shown';
  }

  Future<void> dismissPqRootLinkPrompt() async {
    final self = _identity?.pubkey ?? '';
    await _ref
        .read(keyValueStoreProvider)
        .setString('nym_pq_link_prompt_$self', 'shown');
  }

  bool get pqEnabled =>
      PqPolicy.enabled(privkey: _identity?.privkey, mode: _pqMode);

  /// Whether we can receive PQ: true once this device holds the root, including signer logins.
  bool get pqCapable =>
      PqPolicy.capable(privkey: _identity?.privkey, root: _pqRoot);

  bool get pqSelfEnabled => PqPolicy.selfEnabled(
      privkey: _identity?.privkey, root: _pqRoot, mode: _pqMode);

  /// Layered (`pq2`) key to seal a DM to [pubkey] after one lookup, or null for classical; used by the Nymbot engine.
  Future<Uint8List?> pqLayeredWrapKeyFor(String pubkey) async {
    try {
      await ensurePqAnnouncement(pubkey);
    } catch (_) {}
    try {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final pqOn = PqPolicy.enabled(privkey: _identity?.privkey, mode: _pqMode);
      if (!pqOn) return null;
      final key = _pqRegistry.keyFor(pubkey, nowSec: nowSec, enabled: pqOn);
      if (key == null) return null;
      return _pqRegistry.acceptsLayered(pubkey, nowSec: nowSec, enabled: pqOn)
          ? key
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Decrypt candidates for our identity key: every ML-KEM keypair we can decapsulate with, then classical.
  List<giftwrap.UnwrapCandidate> selfUnwrapCandidates() {
    final sk = _identity?.privkey;
    if (sk == null) return const [];
    return [
      if (pqCapable)
        for (final k in pqSelfCandidateKeys())
          (sk: sk, bitchat: false, kemSk: k.kemSk, kemPk: k.kemPk),
      giftwrap.classicalCandidate(sk),
    ];
  }

  Uint8List? pqSelfKey() {
    if (!pqSelfEnabled) return null;
    // Derived, not from the registry, so our own blobs are never sealed to a key this device can't open.
    return _pqSelfKeys()?.publicKey;
  }

  Uint8List? _pqLayeredPeerKey(String pubkey) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final key = _pqRegistry.keyFor(pubkey, nowSec: nowSec, enabled: pqEnabled);
    if (key == null) return null;
    return _pqRegistry.acceptsLayered(pubkey, nowSec: nowSec, enabled: pqEnabled)
        ? key
        : null;
  }

  bool _pqGroupLayeredFor(String memberPubkey) => _pqRegistry.acceptsLayered(
        memberPubkey,
        nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        enabled: pqEnabled,
      );

  /// Keyed by the member's real pubkey, not the rotating ephemeral key.
  Uint8List? _pqGroupKeyFor(String memberPubkey) => _pqRegistry.keyFor(
        memberPubkey,
        nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        enabled: pqEnabled,
      );

  /// False as soon as one live device on the account only opens the combined format.
  bool pqSelfUsesLayered() => PqPolicy.allDevicesLayered(
        _pqDevices,
        _pqDeviceIdCached ?? '',
        nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );

  /// Whether a peer's announced key is root-seeded (spec §3).
  bool pqPeerIsRootSeeded(String pubkey) => _pqRegistry.isRootSeeded(
        pubkey,
        nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        enabled: pqEnabled,
      );

  /// Fully PQ only when both ends' keys are root-seeded.
  bool pqSealIsRootSeeded(String peerPubkey) =>
      _pqRoot != null && pqPeerIsRootSeeded(peerPubkey);

  /// Like [pqSealIsRootSeeded] but null while unknown; unknown is not legacy.
  bool? pqSealRootVerdict(String peerPubkey) {
    // Unknown until §6 settles, or the boot burst gets stamped legacy.
    if (!_pqRootSettled) return null;
    if (_pqRoot == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (!_pqRegistry.isKnownNymchatClient(peerPubkey, nowSec: nowSec)) {
      return null;
    }
    return pqPeerIsRootSeeded(peerPubkey);
  }

  /// Fills a pending verdict once the announcement lands and repaints the row.
  void _resolvePqRootVerdict(String peerPubkey, String? nymMessageId) {
    if (nymMessageId == null) return;
    if (pqSealRootVerdict(peerPubkey) != null) return;
    unawaited(ensurePqAnnouncement(peerPubkey).then((_) {
      final verdict = pqSealRootVerdict(peerPubkey);
      if (verdict == true) {
        _ref.read(appStateProvider.notifier).markMessagePqRoot(nymMessageId);
        return;
      }
      // Our root hasn't settled; wait for it.
      if (verdict == null) _pqWhenRootSettles(peerPubkey, nymMessageId);
    }));
  }

  /// Polls until §6 settles, since settling has no event.
  void _pqWhenRootSettles(String peerPubkey, String nymMessageId) {
    if (_pqRootWaiters.length >= 500) return;
    _pqRootWaiters.add((peerPubkey, nymMessageId));
    if (_pqRootWaitTimer != null) return;
    var tries = 0;
    void tick(Timer _) {
      if (!_pqRootSettled) {
        if (++tries <= 60) return;
        _pqRootWaitTimer?.cancel();
        _pqRootWaitTimer = null;
        _pqRootWaiters.clear();
        return;
      }
      _pqRootWaitTimer?.cancel();
      _pqRootWaitTimer = null;
      final waiting = List.of(_pqRootWaiters);
      _pqRootWaiters.clear();
      final notifier = _ref.read(appStateProvider.notifier);
      for (final (peer, id) in waiting) {
        if (pqSealRootVerdict(peer) == true) notifier.markMessagePqRoot(id);
      }
    }

    _pqRootWaitTimer = Timer.periodic(const Duration(seconds: 1), tick);
  }

  final List<(String, String)> _pqRootWaiters = [];
  Timer? _pqRootWaitTimer;

  /// Announcement authors to watch: conversation partners, group members and ourselves.
  List<String> _pqAuthorList() {
    if (!pqEnabled) return const [];
    final out = <String>{};
    final self = _identity?.pubkey;
    if (self != null) out.add(self);
    final state = _ref.read(appStateProvider);
    for (final c in state.pmConversations) {
      out.add(c.pubkey);
    }
    for (final g in _ref.read(groupsProvider)) {
      out.addAll(g.members);
    }
    return out.toList();
  }

  /// Ingests a verified `nym-pq` announcement.
  void _ingestPqAnnouncement(NostrEvent event) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _pqRegistry.ingest(event.pubkey, event.content,
        nowSec: nowSec, createdAt: event.createdAt);
    if (event.pubkey == _identity?.pubkey) {
      final ann = PqAnnouncement.parse(event.content);
      if (ann != null && !ann.retracted) {
        // A new device on the account changes the seal policy immediately.
        _pqDevices = ann.devices;
        _refreshPqSealPolicy();
      }
      // A linked device learns the account's epoch from the announcement.
      unawaited(_adoptAnnouncedPqEpoch());
    }
    _schedulePersistPqKeys();
  }

  /// Debounced (30s) persist of verified signature ids so the next launch skips re-verifying.
  Timer? _verifiedIdsPersistTimer;
  void _schedulePersistVerifiedIds() {
    if (_verifiedIdsPersistTimer != null) return;
    if (PanicWipe.inProgress) return;
    _verifiedIdsPersistTimer = Timer(const Duration(seconds: 30), () {
      _verifiedIdsPersistTimer = null;
      final cache = _cache;
      if (cache == null || !cache.isOpen) return;
      if (PanicWipe.inProgress) return;
      unawaited(cache
          .saveMetaSet(CacheStore.metaVerifiedEventIds,
              NostrService.snapshotVerifiedIds().toSet())
          .catchError((_) {}));
    });
  }

  Timer? _pqKeysPersistTimer;
  void _schedulePersistPqKeys() {
    if (_pqKeysPersistTimer != null) return;
    if (PanicWipe.inProgress) return;
    _pqKeysPersistTimer = Timer(const Duration(seconds: 5), () {
      _pqKeysPersistTimer = null;
      final cache = _cache;
      if (cache == null || !cache.isOpen) return;
      if (PanicWipe.inProgress) return;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      unawaited(cache
          .saveMetaMap(
              CacheStore.metaPqKeys, _pqRegistry.toJson(nowSec: nowSec))
          .catchError((_) {}));
    });
  }

  /// Our ML-KEM keypair for the current epoch: root-seeded with a root, else nsec-seeded.
  MlKemKeyPair? _pqSelfKeys() {
    // The root alone derives the key; the nsec fallback keeps legacy keys v1 peers may still use.
    final root = _pqRoot;
    if (root != null) return pq.pqKeypairFromRoot(root, _pqEpoch);
    final privkey = _identity?.privkey;
    if (privkey == null) return null;
    return pq.pqKeypairFromPrivkey(privkey, _pqEpoch);
  }

  int _pqEpoch = 0;

  /// How far back to look for the epoch our own announcement names.
  static const int _pqEpochScan = 12;

  /// Adopts the epoch our own announcement names so a restored device doesn't sit at 0.
  Future<bool> _adoptAnnouncedPqEpoch() async {
    final self = _identity?.pubkey;
    if (self == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final announced = _pqRegistry.keyFor(self, nowSec: nowSec, enabled: true);
    if (announced == null) return false;

    final root = _pqRoot;
    final privkey = _identity?.privkey;
    Uint8List? derive(int epoch) {
      try {
        if (root != null) return pq.pqKeypairFromRoot(root, epoch).publicKey;
        if (privkey != null) {
          return pq.pqKeypairFromPrivkey(privkey, epoch).publicKey;
        }
      } catch (_) {}
      return null;
    }

    bool same(Uint8List a, Uint8List b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    final here = derive(_pqEpoch);
    if (here != null && same(here, announced)) return false;

    final order = <int>[];
    final claimed = _pqRegistry.epochFor(self);
    if (claimed != null && claimed >= 0) order.add(claimed);
    for (var e = 0; e <= _pqEpochScan; e++) {
      order.add(e);
    }
    final tried = <int>{_pqEpoch};
    for (final epoch in order) {
      if (!tried.add(epoch)) continue;
      final keys = derive(epoch);
      if (keys == null || !same(keys, announced)) continue;
      _pqEpoch = epoch;
      await _ref
          .read(keyValueStoreProvider)
          .setString(StorageKeys.pqEpoch, '$epoch');
      return true;
    }
    return false;
  }

  /// Loads PQ settings; first boot defaults via [PqPolicy.initialMode]: on for fresh installs, off for upgrades.
  void _loadPqSettings() {
    final kv = _ref.read(keyValueStoreProvider);
    // Only the undocumented escape hatch reads this key.
    _pqMode =
        kv.getString(StorageKeys.pqMode) == 'off' ? PqMode.off : PqMode.on;
    // `nym_last_online_ts` marks an upgrade, which is what can strand an older device.
    if (kv.getString(StorageKeys.pqUpgradeSeen) == null) {
      unawaited(kv.setString(StorageKeys.pqUpgradeSeen, '1'));
      if (PqPolicy.upgradeNoticeNeeded(
          seenBefore: kv.getString('nym_last_online_ts') != null)) {
        unawaited(kv.setString(StorageKeys.pqUpgradeNotice, 'pending'));
      }
    }
    _pqEpoch = int.tryParse(kv.getString(StorageKeys.pqEpoch) ?? '') ?? 0;
  }

  /// Random per-device id for the announcement roster.
  Future<String> _pqDeviceId() async {
    final kv = _ref.read(keyValueStoreProvider);
    final existing = kv.getString(StorageKeys.pqDeviceId);
    if (existing != null && existing.isNotEmpty) {
      return _pqDeviceIdCached = existing;
    }
    final bytes = keys.randomBytes(4);
    final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await kv.setString(StorageKeys.pqDeviceId, id);
    return _pqDeviceIdCached = id;
  }

  /// Cached for the synchronous seal-policy check.
  String? _pqDeviceIdCached;

  /// Publishes our capability announcement (every client does); the ML-KEM key only when PQ is possible and on.
  Future<void> publishPqAnnouncement({bool force = false}) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;
    // Spec §7: a device that can't open the root publishes nothing, or it would clobber the v2 announcement.
    if (_pqRootLocked) return;
    // The epoch isn't in the backup; catch up before publishing.
    await _adoptAnnouncedPqEpoch();
    if (!force &&
        _pqLastPublishMs != 0 &&
        DateTime.now().millisecondsSinceEpoch - _pqLastPublishMs <
            pqRepublishInterval.inMilliseconds) {
      return;
    }
    // Announce a KEM key only after §6 settles, or peers cache an nsec-derived key; `nym: 1` still goes out.
    final keys = (pqEnabled && _pqRootSettled) ? _pqSelfKeys() : null;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final selfDeviceId = await _pqDeviceId();
    final devices = PqPolicy.mergeDeviceRoster(
        _pqDevices, selfDeviceId, ApiConfig.appVersion,
        nowSec: nowSec,
        capable: PqPolicy.capable(privkey: _identity?.privkey, root: _pqRoot),
        layered: PqPolicy.capable(privkey: _identity?.privkey, root: _pqRoot));
    final signed = await service.publishPqAnnouncement(
      kemPublicKey: keys?.publicKey,
      // `pk` is only honored by a login holding the nsec.
      legacyCapable: PqPolicy.legacyCapable(privkey: identity.privkey),
      epoch: _pqEpoch,
      devices: devices,
      // Only a genuinely root-seeded key may claim `src:"root"`.
      rootSeeded: keys != null && _pqRoot != null,
    );
    if (signed == null) return;
    // Kept for the Nymbot worker to seal replies to our key.
    _pqSelfSignedAnnouncement = signed;
    _pqDevices = devices;
    _refreshPqSealPolicy();
    _pqLastPublishMs = DateTime.now().millisecondsSinceEpoch;
    // Record our own entry so self-addressed wraps resolve like everyone else's.
    _pqRegistry.record(
        identity.pubkey, keys?.publicKey, nowSec + pqTtl.inSeconds, _pqEpoch);
    _schedulePersistPqKeys();
  }

  /// Seals new self-addressed blobs classical while a signer-login device is on the account; existing blobs still open.
  void _refreshPqSealPolicy() {
    final capable = _identity?.privkey != null &&
        PqPolicy.allDevicesCapable(
          _pqDevices,
          _pqDeviceIdCached ?? '',
          nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );
    _storageSync?.setPqSealToSelf(capable);
  }

  /// Our decrypt candidates: current epoch first, then a few previous ones.
  List<({Uint8List kemSk, Uint8List kemPk})> pqSelfCandidateKeys() {
    final privkey = _identity?.privkey;
    if (privkey == null) return const [];
    // Root-derived first; the nsec-derived half is permanent (spec §4).
    return pqSelfCandidates(privkey, _pqEpoch, root: _pqRoot);
  }

  // The post-quantum root secret (docs/PQ-ROOT-SPEC.md).

  Uint8List? _pqRoot;

  /// The account has a root this device can't open (§7).
  bool _pqRootLocked = false;

  bool get pqRootHeld => _pqRoot != null;

  bool get pqRootLinkNeeded => _pqRootLocked;

  /// Whether §6 has run; until then any announced key is nsec-derived by default.
  bool _pqRootSettled = false;

  /// Asks the worker to delete this account's rows during a wipe, signed while the key is still here.
  Future<bool> purgeServerRecords() async {
    final sync = _storageSync;
    if (sync == null) return false;
    try {
      return await sync.purgeAccount();
    } catch (_) {
      return false;
    }
  }

  /// The root as its `nympq1…` code.
  String? get pqRootCode {
    final root = _pqRoot;
    return root == null ? null : pqRootToCode(root);
  }

  /// A root generated here whose code the user hasn't seen (§6.4).
  bool get pqRootBackupPending =>
      _ref
          .read(keyValueStoreProvider)
          .getString(StorageKeys.pqRootBackupNotice) ==
      'pending';

  Future<void> dismissPqRootBackupNotice() async =>
      _ref.read(keyValueStoreProvider).remove(StorageKeys.pqRootBackupNotice);

  /// Reads the locally held root (§5.3); with the vault on it arrives in [unlockedSecrets]; unreadable means no root.
  Future<Uint8List?> _loadPqRoot({Map<String, String>? unlockedSecrets}) async {
    final cached = _pqRoot;
    if (cached != null) return cached;
    final pubkey = _identity?.pubkey;
    if (pubkey == null) return null;
    String? raw = unlockedSecrets?[SecretKeys.pqRoot];
    if (raw == null || raw.isEmpty) {
      try {
        raw = await SecureStore().get(SecretKeys.pqRoot);
      } catch (_) {
        return null;
      }
    }
    final store = PqRootStore.parse(raw);
    _pqRootStore = store;
    _pqRootStoreUnreadable = store.unreadable;
    final code = store.codeFor(pubkey);
    if (code == null) return null;
    final root = pqRootFromCode(code);
    if (root == null) {
      _pqRootStoreUnreadable = true;
      return null;
    }
    return _pqRoot = root;
  }

  PqRootStore _pqRootStore = const PqRootStore();
  bool _pqRootStoreUnreadable = false;

  Uint8List? get _pqRootLegacy {
    final code = _pqRootStore.legacy;
    return code == null ? null : pqRootFromCode(code);
  }

  Future<bool> _writePqRootStore(PqRootStore store) async {
    if (_retired) return false;
    try {
      final vault = _ref.read(identityVaultProvider);
      final encoded = store.encode();
      if (encoded == null) {
        await SecureStore().remove(SecretKeys.pqRoot);
      } else {
        await vault.secretSet(SecretKeys.pqRoot, encoded);
      }
      _pqRootStore = store;
      _pqRootStoreUnreadable = false;
      return true;
    } catch (_) {
      return false;
    }
  }

  void _resetPqRootState() {
    _pqRootRetryTimer?.cancel();
    _pqRootRetryTimer = null;
    _pqRootRetryCount = 0;
    _pqRoot = null;
    _pqRootLocked = false;
    _pqRootSettled = false;
    _pqRootRecordPending = false;
    _pqRootInFlight = false;
    _pqRootStore = const PqRootStore();
    _pqRootStoreUnreadable = false;
    _pqLastPublishMs = 0;
    _pqSelfSignedAnnouncement = null;
    _pqDevices = const [];
    _pqRootWaitTimer?.cancel();
    _pqRootWaitTimer = null;
    _pqRootWaiters.clear();
    _pqRootCandidate = null;
  }

  /// Persists the root through the vault; false on failure, which must not count as adopted.
  Future<bool> _persistPqRoot(Uint8List root, {bool dropLegacy = false}) async {
    final pubkey = _identity?.pubkey;
    if (pubkey == null) return false;
    final ok = await _writePqRootStore(
        _pqRootStore.withCode(pubkey, pqRootToCode(root), dropLegacy: dropLegacy));
    if (!ok) return false;
    _pqRoot = root;
    _pqRootLocked = false;
    return true;
  }

  /// Generation and adoption (spec §6), once the boot settings read settles.
  Future<void> _ensurePqRoot() async {
    final sync = _storageSync;
    if (sync == null || _identity == null) return;
    if (PanicWipe.inProgress) return;
    // Re-ask until settled; an offline launch must not leave the session rootless.
    if (_pqRootSettled &&
        !_pqRootRecordPending &&
        (_pqRoot != null || _pqRootLocked)) {
      return;
    }
    // One run at a time, or overlapping runs could mint rival roots.
    if (_pqRootInFlight) return;
    _pqRootInFlight = true;
    try {
      await _ensurePqRootLocked(sync);
    } finally {
      _pqRootInFlight = false;
    }
  }

  bool _pqRootInFlight = false;
  bool _pqRootRecordPending = false;

  Future<void> _ensurePqRootLocked(StorageSync sync) async {
    // The decision lives in the pure, tested [pqRootDecide]; a visible row proves a root exists even if unparseable.
    _pqRootRetryTimer?.cancel();
    _pqRootRetryTimer = null;
    final record = sync.pqRootRecord;
    final recordReadable = record != null && record.isValid;
    final rowPresent = sync.pqRootRowPresent;
    var held = _pqRoot;
    if (held == null && sync.pqRootLoadSucceeded) {
      final legacy = _pqRootLegacy;
      if (legacy != null) {
        if (recordReadable && record.matches(legacy)) {
          if (await _persistPqRoot(legacy, dropLegacy: true)) held = legacy;
        } else if (!rowPresent) {
          if (await _persistPqRoot(legacy, dropLegacy: true)) held = legacy;
        }
      }
    }
    final matches = recordReadable && held != null && record.matches(held);
    if (held == null && !recordReadable && _pqRootStoreUnreadable) {
      _pqRootSettled = true;
      _pqRootLocked = true;
      sync.pqRootLocked = true;
      return;
    }

    final action = pqRootDecide(
      throwawayKeypair: _ref
          .read(keyValueStoreProvider)
          .getBool(StorageKeys.randomKeypairPerSession, defaultValue: false),
      recordLoadSucceeded: sync.pqRootLoadSucceeded,
      recordPresent: rowPresent,
      recordReadable: recordReadable,
      holdRoot: held != null,
      recordMatchesHeldRoot: matches,
    );

    if (action != PqRootAction.wait) {
      _pqRootSettled = true;
      _pqRootRecordPending = false;
    }
    // Anything but awaitLink means we hold or will hold the root.
    if (action != PqRootAction.awaitLink && action != PqRootAction.wait) {
      sync.pqRootLocked = false;
    }

    switch (action) {
      case PqRootAction.wait:
        return;
      case PqRootAction.ready:
        // The boot announcement had no key; publish the real one.
        _pushPqKeysToPeers();
        if (sync.pqRootRowHybrid && held != null) {
          await sync.pqRootRecordSet(PqRootRecord.forRoot(held));
        }
        await publishPqAnnouncement(force: true);
        return;

      case PqRootAction.publishRecord:
        // A previous launch couldn't publish the record; publish it now or another device mints a rival root.
        final held = _pqRoot;
        if (held == null) return;
        await _createPqRoot(sync, existing: held);
        return;

      case PqRootAction.awaitLink:
        // Lets decode tell "can't read yet" from "can't read ever".
        sync.pqRootLocked = true;
        // §6.3: a root that doesn't open this account's record is dropped; prompt to link.
        if (recordReadable && !matches) _pqRoot = null;
        _pqRootLocked = true;
        if (!recordReadable && _signer is! LocalSigner) {
          _pqRootSettled = false;
          _schedulePqRootRetry(sync);
        }
        return;

      case PqRootAction.generate:
        // §6.4: persist first, publish second; an unpublished root is retried by publishRecord.
        final candidate = _pqRootCandidate;
        _pqRootCandidate = null;
        await _createPqRoot(sync, existing: candidate);
        return;
    }
  }

  Future<void> _createPqRoot(StorageSync sync, {Uint8List? existing}) async {
    final root = existing ?? pq.pqGenerateRoot();
    final held = _pqRoot;
    if (held == null || !_sameBytes(held, root)) {
      if (!await _persistPqRoot(root)) return;
    }
    // Best-effort; publishRecord recovers a failure.
    await sync.pqRootRecordSet(PqRootRecord.forRoot(root));
    if (existing == null) await _armPqRootBackupNotice();
    _pushPqKeysToPeers();
    await publishPqAnnouncement(force: true);
  }

  Future<void> _armPqRootBackupNotice() async {
    try {
      await _ref
          .read(keyValueStoreProvider)
          .setString(StorageKeys.pqRootBackupNotice, 'pending');
    } catch (_) {}
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Uint8List? _pqRootCandidate;
  ({String pubkey, Uint8List root})? _pqRootForNewKey;

  Future<void> _seedNewKeyPqRoot(Identity identity,
      {required bool freshKey}) async {
    final pending = _pqRootForNewKey;
    _pqRootForNewKey = null;
    final seed = pqRootSeedForKey(
      holdRoot: _pqRoot != null,
      localKey: identity.privkey != null,
      throwawayKeypair: _ref
          .read(keyValueStoreProvider)
          .getBool(StorageKeys.randomKeypairPerSession, defaultValue: false),
      pendingForThisKey: pending != null && pending.pubkey == identity.pubkey,
      freshKey: freshKey,
    );
    final Uint8List root;
    switch (seed) {
      case PqRootSeed.none:
        return;
      case PqRootSeed.pending:
        root = pending!.root;
      case PqRootSeed.generate:
        root = pq.pqGenerateRoot();
    }
    if (!await _persistPqRoot(root)) return;
    _pqRootSettled = true;
    _pqRootRecordPending = true;
    await _armPqRootBackupNotice();
  }

  static const List<Duration> _pqRootRetryDelays = [
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
  ];
  Timer? _pqRootRetryTimer;
  int _pqRootRetryCount = 0;

  void _schedulePqRootRetry(StorageSync sync) {
    if (_pqRootRetryTimer != null) return;
    final n = _pqRootRetryCount;
    if (n >= _pqRootRetryDelays.length) return;
    _pqRootRetryCount = n + 1;
    _pqRootRetryTimer = Timer(_pqRootRetryDelays[n], () async {
      _pqRootRetryTimer = null;
      if (_pqRootSettled || _storageSync != sync) return;
      try {
        await _mergeRemoteSettings(sync);
      } catch (_) {}
      await _ensurePqRoot();
    });
  }

  bool get pqRootRowUnreadable => _storageSync?.pqRootRowUnreadable ?? false;

  String pqRootLinkVerdict(String code) {
    final root = pqRootFromCode(code.trim());
    if (root == null) return 'invalid';
    final record = _storageSync?.pqRootRecord;
    if (record != null && record.isValid && !record.matches(root)) {
      return 'mismatch';
    }
    return 'ok';
  }

  Future<bool> linkPqRootFromCode(String code) async {
    final root = pqRootFromCode(code.trim());
    if (root == null) return false;

    // Check against the record's fingerprint, which is epoch-free; our epoch counter may have drifted from the announcer's.
    final record = _storageSync?.pqRootRecord;
    if (record != null && record.isValid) {
      if (!record.matches(root)) return false;
    } else {
      // No record: fall back to the announced key at the announcement's own epoch.
      final self = _identity?.pubkey;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final announced = self == null
          ? null
          : _pqRegistry.keyFor(self, nowSec: nowSec, enabled: true);
      if (announced != null) {
        final epoch = _pqRegistry.epochFor(self!) ?? _pqEpoch;
        if (!pqRootMatchesAnnouncedKey(root, announced, epoch)) return false;
      }
    }

    if (!await _persistPqRoot(root)) return false;
    _pqRootRetryTimer?.cancel();
    _pqRootRetryTimer = null;
    _pqRootLocked = false;
    _pqRootSettled = true;
    final sync = _storageSync;
    if (sync != null && (record == null || !record.isValid) && sync.pqRootRowPresent) {
      sync.pqRootLocked = false;
      await sync.pqRootRecordSet(PqRootRecord.forRoot(root));
    }
    _pushPqKeysToPeers();
    await publishPqAnnouncement(force: true);
    // Re-read settings sealed to the root-derived key, or they stay on defaults.
    await _reloadSettingsAfterLink();
    return true;
  }

  Future<bool> replacePqRootWithCode(String code) async {
    final root = pqRootFromCode(code.trim());
    if (root == null) return false;
    final sync = _storageSync;
    if (sync == null || _identity == null) return false;
    if (!await _persistPqRoot(root)) return false;
    _pqRootRetryTimer?.cancel();
    _pqRootRetryTimer = null;
    _pqRootLocked = false;
    _pqRootSettled = true;
    sync.pqRootLocked = false;
    sync.clearSettingsHashes();
    if (!await sync.pqRootRecordSet(PqRootRecord.forRoot(root))) return false;
    _pushPqKeysToPeers();
    await publishPqAnnouncement(force: true);
    await _reloadSettingsAfterLink();
    return true;
  }

  /// Re-runs the settings restore after a link so previously unreadable rows apply now.
  Future<void> _reloadSettingsAfterLink() async {
    final sync = _storageSync;
    if (sync == null) return;
    try {
      sync.pqRootLocked = false;
      sync.clearSettingsHashes();
      await _mergeRemoteSettings(sync);
    } catch (_) {
      // A failed re-read leaves the next scheduled pull to catch up.
    }
  }

  /// Re-pushes our ML-KEM keys so a mid-session link doesn't leave paths on the nsec-derived key.
  void _pushPqKeysToPeers() {
    final candidates = pqCapable
        ? pqSelfCandidateKeys()
        : const <({Uint8List kemSk, Uint8List kemPk})>[];
    _service?.setPqSelfKeys(candidates);
    _storageSync?.setPqSelfKeys(candidates);
  }

  PqPmPlan _pmPlanFor(Identity identity, String recipientPubkey) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final pqOn = PqPolicy.enabled(privkey: identity.privkey, mode: _pqMode);
    PqPmPlan plan;
    try {
      plan = PqPmPlan.decide(
        recipientKemKey:
            _pqRegistry.keyFor(recipientPubkey, nowSec: nowSec, enabled: pqOn),
        knownBitchat: _bitchatUsers.contains(recipientPubkey),
        knownNym: _nymUsers.contains(recipientPubkey),
        provenNymchat:
            _pqRegistry.isKnownNymchatClient(recipientPubkey, nowSec: nowSec),
        recipientAcceptsLayered: _pqRegistry.acceptsLayered(recipientPubkey,
            nowSec: nowSec, enabled: pqOn),
        bitchatSeenAtSec: _bitchatSeenAt[recipientPubkey] ?? 0,
        announcedAtSec:
            _pqRegistry.announcedAtFor(recipientPubkey, nowSec: nowSec),
      );
    } catch (e) {
      debugPrint('[PQ] send plan failed, falling back to dual-send: $e');
      plan = const PqPmPlan(kemPublicKey: null, bitchat: true, nym: true);
    }
    return plan;
  }

  /// Publishes a PM in the formats the peer understands: Bitchat, NIP-17, or both when unknown; self-copy is NIP-17.
  Future<void> _publishDualPm({
    required UnsignedEvent rumor,
    required String recipientPubkey,
    void Function(NostrEvent wrap)? onWrap,
  }) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;

    // Look up the announcement once before deciding; a lookup failure must never abort the send.
    try {
      await ensurePqAnnouncement(recipientPubkey);
    } catch (_) {}

    final plan = _pmPlanFor(identity, recipientPubkey);

    // One rumor per chunk: Bitchat drops TLV values over 255 bytes.
    final bitchatRumors = <UnsignedEvent>[];
    if (plan.bitchat) {
      for (final chunk in bitchat.chunkBitchatContent(rumor.content)) {
        final encoded = bitchat.encodeBitchatMessage(
          chunk,
          identity.pubkey,
          recipientPubkey: recipientPubkey,
        );
        // No tags: Bitchat 1.7.1+ drops any inner rumor whose tags aren't empty or exactly [["p", recipient]].
        bitchatRumors.add(UnsignedEvent(
          pubkey: identity.pubkey,
          createdAt: rumor.createdAt,
          kind: EventKind.dmRumor,
          tags: const [],
          content: encoded.content,
        ));
      }
    }

    // Update the on-screen echo with the encryption that actually went out.
    for (final t in rumor.tags) {
      if (t.length > 1 && t[0] == 'x') {
        _ref.read(appStateProvider.notifier).markOwnMessagePq(t[1],
            pqEncrypted: plan.pq,
            pqRoot: plan.pq && pqSealIsRootSeeded(recipientPubkey));
        break;
      }
    }

    final supportToken = pmSupportTokenFor(recipientPubkey);
    await service.publishPM(
      rumor: PmLogic.withSupportToken(rumor, supportToken),
      recipientPubkey: recipientPubkey,
      settings: _msgSettings,
      onWrap: onWrap,
      bitchatRumors: bitchatRumors,
      sendNymWrap: plan.nym,
      recipientKemPublicKey: plan.kemPublicKey,
      selfKemPublicKey: pqSelfKey(),
      recipientLayered: plan.layered,
      // Our own copy: layered unless a live device on this account only opens the combined format.
      selfLayered: pqSelfUsesLayered(),
      wrapTags: PmLogic.supportWrapTags(supportToken),
    );
  }

  PmSupportTokens? _pmSupportTokens;
  String? _pmSupportOwner;

  PmSupportTokens _pmSupportStore() {
    final owner = _service?.selfPubkey ??
        _identity?.pubkey ??
        _ref.read(appStateProvider).selfPubkey;
    final cached = _pmSupportTokens;
    if (cached != null && _pmSupportOwner == owner) return cached;
    final loaded = PmSupportTokens.decode(_ref
        .read(keyValueStoreProvider)
        .getString(StorageKeys.pmSupportTokensFor(owner)));
    _pmSupportTokens = loaded;
    _pmSupportOwner = owner;
    _publishPmSupportPeers(loaded);
    return loaded;
  }

  void _publishPmSupportPeers(PmSupportTokens store) {
    final notifier = _ref.read(pmSupportPeersProvider.notifier);
    final peers = store.peers;
    if (!setEquals(notifier.state, peers)) notifier.state = peers;
  }

  String? pmSupportTokenFor(String pubkey) =>
      _pmSupportStore().newestFor(pubkey);

  static String? _supportReplyRecipient(List<List<String>> tags, String? self) {
    for (final t in tags) {
      if (t.length > 1 && t[0] == 'p' && t[1] != self) return t[1];
    }
    return null;
  }

  void _notePmSupportToken(String sender, Map<String, dynamic> rumor) {
    final token = PmLogic.supportTokenOf(rumor);
    if (token == null) return;
    final store = _pmSupportStore();
    final owner = _pmSupportOwner;
    final peer = sender == owner
        ? _supportReplyRecipient(_tags(rumor), owner)
        : sender;
    if (peer == null || peer == owner) return;
    final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
    if (!store.record(peer, token, ts)) return;
    unawaited(_ref.read(keyValueStoreProvider).setString(
        StorageKeys.pmSupportTokensFor(_pmSupportOwner ?? ''),
        store.encode()));
    _publishPmSupportPeers(store);
  }

  /// Queues a sent PM for receipt-driven auto-retry and starts the checker if idle.
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

  /// True once the PM has a delivery status past `sent`.
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

  /// Retry tick: drop acked or maxed entries, re-publish the rest past cooldown, stop when empty.
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

  /// On reconnect, re-send every unacked PM, bypassing cooldown and cap.
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

  List<List<String>> _contentTags(String content) => [
        ..._ref.read(liveCustomEmojiProvider.notifier).emojiTagsForContent(content),
        ...media_notes.imetaTagsForContent(
            content, _ref.read(mediaFallbacksProvider).fallbacksFor),
      ];

  Future<void> sendViewOnceOpened({
    required String onceId,
    required String senderPubkey,
    String? groupId,
  }) async {
    final identity = _identity;
    final service = _service;
    if (identity == null || service == null || senderPubkey.isEmpty) return;
    final ek = groupId == null ? null : _groups?.keysFor(groupId);
    await service.publishReceipt(
      messageIds: [onceId],
      receiptType: media_notes.MediaNoteKeys.receiptOpened,
      recipientPubkey: senderPubkey,
      encryptToPubkey: ek?.encryptionPubkeyFor(senderPubkey, identity.pubkey),
    );
    if (senderPubkey != identity.pubkey) {
      await service.publishReceipt(
        messageIds: [onceId],
        receiptType: media_notes.MediaNoteKeys.receiptOpened,
        recipientPubkey: identity.pubkey,
      );
    }
  }

  bool _onOnceOpenedReceipt(Map<String, dynamic> rumor) {
    final tags = _tags(rumor);
    if (_tagValue(tags, 'receipt') != media_notes.MediaNoteKeys.receiptOpened) {
      return false;
    }
    final from = rumor['pubkey'] as String? ?? '';
    if (from.isEmpty) return true;
    final self = _identity?.pubkey;
    final store = _ref.read(onceStoreProvider);
    var changed = false;
    for (final t in tags) {
      if (t.length < 2 || t[0] != 'x') continue;
      if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(t[1])) continue;
      final hit = from == self
          ? store.markOpened(t[1])
          : store.markRemoteOpened(t[1], from);
      changed = changed || hit;
    }
    if (changed) _ref.read(onceRevisionProvider.notifier).state++;
    return true;
  }

  /// Publishes [content] to the active conversation without command interception (e.g. `/me` output).
  Future<void> sendMediaNoteContent(ChatView view, String content,
          {String? threadRoot}) =>
      _sendMessageContent(content, threadRoot: threadRoot, viewOverride: view);

  Future<void> _sendMessageContent(String content,
      {String? threadRoot, ChatView? viewOverride}) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    // Every send marks us active and throttle-broadcasts presence.
    recordOwnActivity();
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final identity = _identity;
    final view = viewOverride ?? state.view;
    _markDirty(view.storageKey);

    // In a thread view, reply into the thread only if its root belongs to this conversation.
    if (threadRoot == null) {
      final at = _ref.read(activeThreadProvider);
      if (at != null && at.view == view && appThreadsEnabled) {
        threadRoot = at.rootId;
      }
    }

    // Offline sends go over the mesh (and mesh-only peers always do); online everything goes to Nostr.
    final meshBridge = _ref.read(meshControllerProvider.notifier).bridge;
    if (meshBridge != null && meshBridge.shouldSendOverMesh(view)) {
      await meshBridge.sendFromComposer(view, trimmed, threadRoot: threadRoot);
      return;
    }

    if (view.kind == ViewKind.channel) {
      // Optimistic local echo with a temp `_optim_*` id.
      final echo = appState.sendLocal(trimmed,
          threadRoot: threadRoot, viewOverride: view);
      if (service == null || identity == null) return;
      final isGeo = state.channels
          .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
      try {
        await _awaitAttestBadge();
        final signed = await service.publishChannelMessage(
          channelKey: view.id,
          content: trimmed,
          nym: identity.nym,
          geohash: isGeo ? view.id : null,
          emojiTags: _contentTags(trimmed),
          // Clamped up to the Nymchat floor by the service.
          powDifficulty: _ref.read(settingsProvider.notifier).powDifficulty,
          threadRoot: threadRoot,
        );
        // Swap in the real id and register it so the relay echo dedups; without a signer the echo just stays.
        if (signed != null && echo != null) {
          appState.replaceOptimistic(
            echo.id,
            signed.id,
            realCreatedAt: signed.createdAt,
            realMs: int.tryParse(signed.tagValue('ms') ?? ''),
            powTarget: EventMapper.powTargetOf(signed),
          );
        }
        // Hardcore mode rotates identity after the publish, so this message used the old one.
        await _rotateHardcoreIdentityIfNeeded();
      } catch (_) {
        if (echo != null) appState.markOptimisticFailed(echo.id);
      }
      return;
    }

    if (view.kind == ViewKind.pm) {
      // Bot `?` control commands are handled on-device and never encrypted, published, shown or stored.
      if (isVerifiedBot(view.id)) {
        if (botPMCommandRe.hasMatch(canonicalizeCommandInput(trimmed))) {
          unawaited(_ref
              .read(botChatControllerProvider.notifier)
              .handleBotPMCommand(trimmed));
          return;
        }
        // Route through the engine so exactly one bot-addressed wrap is published and its id rides the paid request.
        unawaited(_ref
            .read(botChatControllerProvider.notifier)
            .sendUserBotPM(trimmed));
        return;
      }
      final nymMessageId = PmLogic.generateSharedEventId();
      final echo = appState.sendLocal(trimmed,
          nymMessageId: nymMessageId,
          threadRoot: threadRoot,
          viewOverride: view);
      echo?.expiresAt = _msgSettings
          .expirationFor(DateTime.now().millisecondsSinceEpoch ~/ 1000);
      if (service == null || identity == null) return;
      final base = PmLogic.buildPmRumor(
        selfPubkey: identity.pubkey,
        recipientPubkey: view.id,
        content: trimmed,
        nymMessageId: nymMessageId,
        // Thread reply marker rides inside the encrypted rumor.
        extraTags: [
          if (threadRoot != null && threadRoot.isNotEmpty)
            ['nymthread', threadRoot],
        ],
      );
      // Append NIP-30 declarations for known custom shortcodes in the body.
      final emojiTags = _contentTags(trimmed);
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
        // Queue for auto-retry until a receipt acks it; the verified bot never sends receipts, so its PMs aren't queued.
        if (!isVerifiedBot(view.id)) {
          _trackPendingDm(
            nymMessageId: nymMessageId,
            rumor: rumor,
            recipientPubkey: view.id,
          );
        }
      } catch (_) {
        // Publish failed: flip the bubble to failed.
        if (echo != null) appState.markOptimisticFailed(echo.id);
      }
      return;
    }

    if (view.kind == ViewKind.group) {
      final group = appState.groupById(view.id);
      if (service == null || identity == null || group == null) {
        appState.sendLocal(trimmed, viewOverride: view);
        return;
      }
      final blocked =
          _ref.read(groupToolsProvider).sendBlockedReason(group.id, trimmed);
      if (blocked != null) {
        _emitSystemMessage(blocked);
        return;
      }
      // Build and send first so we know the shared id, then echo with it.
      final ek = _groups!.keysFor(group.id);
      final next = ek.rotateSelf();
      _applyEphemeralKeys();
      // After a self-key rotation: persist, re-REQ the ephemeral sub, and sync so other devices can decrypt.
      _afterSelfKeyRotation();
      final nymMessageId = GroupLogic.generateGroupId();
      final groupEcho = appState.sendLocal(trimmed,
          nymMessageId: nymMessageId,
          threadRoot: threadRoot,
          viewOverride: view);
      groupEcho?.expiresAt = _msgSettings
          .expirationFor(DateTime.now().millisecondsSinceEpoch ~/ 1000);
      final rumor = GroupLogic.buildGroupMessageRumor(
        group: group,
        selfPubkey: identity.pubkey,
        content: trimmed,
        nymMessageId: nymMessageId,
        ephemeralPk: next.pk,
        // NIP-30 declarations, the owner's metadata piggyback, and the thread marker.
        extraTags: [
          if (threadRoot != null && threadRoot.isNotEmpty)
            ['nymthread', threadRoot],
          ..._contentTags(trimmed),
          ...GroupLogic.groupMetaPiggybackTags(group, identity.pubkey),
        ],
      );
      await service.publishGroupMessage(
        rumor: rumor,
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
        settings: _msgSettings,
        onWrap: _archiveSentWrap,
        kemKeyFor: _pqGroupKeyFor,
        layeredFor: _pqGroupLayeredFor,
        // Partial PQ coverage must not read as protected, so the badge carries the count.
        rootSeededFor: pqPeerIsRootSeeded,
        onCoverage: (pq, total, root) => appState.markOwnMessagePq(nymMessageId,
            coverage: (pq: pq, total: total),
            // Our root matters too: the self-archive copy is sealed to it.
            pqRoot:
                total > 0 && pq == total && root == total && _pqRoot != null),
      );
    }
  }

  /// Random/hardcore removes the saved session nsec; persistent saves the current one if none is stored.
  Future<void> _onKeypairModeChanged(String mode) async {
    final identity = _identity;
    // Durable logins never touch the ephemeral session key.
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
      // Best-effort.
    }
  }

  /// In hardcore ephemeral mode, swaps in a fresh keypair and nym after a send, keeping relay connections.
  Future<void> _rotateHardcoreIdentityIfNeeded() async {
    final current = _identity;
    final oldService = _service;
    if (current == null || oldService == null || current.loginMethod != null) {
      return;
    }
    if (_ref.read(settingsProvider.notifier).keypairMode != 'hardcore') return;

    final kv = _ref.read(keyValueStoreProvider);
    final identityService = IdentityService(
      kv: kv,
      secure: SecureStore(),
      secretWrite: _ref.read(identityVaultProvider).secretSet,
    );
    final rotated = await identityService.rotateEphemeral(current);
    // Guard against a no-op rotation.
    if (identical(rotated, current) || rotated.pubkey == current.pubkey) return;

    final signer =
        rotated.privkey != null ? LocalSigner(rotated.privkey!) : null;

    // Swap the key in place; rebuilding the service would reconnect every relay per message.
    oldService.rotateIdentity(rotated, signer);
    _identity = rotated;
    _signer = signer;
    // Re-scope per-pubkey settings reads to the new identity.
    _ref.read(settingsProvider.notifier).activePubkey = rotated.pubkey;

    // Refresh the sidebar without resetting the store (not goLive).
    _ref
        .read(appStateProvider.notifier)
        .setIdentity(rotated.pubkey, rotated.nym);

    // Re-assert presence under the new identity.
    recordOwnActivity();
  }

  // Command effects.

  /// `/join`: sanitize, block-check, add and switch; geohash channels register their geohash.
  void cmdJoin(String rawChannel) {
    var channel = rawChannel.trim().toLowerCase();
    if (channel.startsWith('#')) channel = channel.substring(1);
    // Only letters (incl. international) and digits.
    channel = channel.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    if (channel.isEmpty) {
      _emitSystemMessage(
          tr('Invalid channel name. Only letters and numbers are allowed.'));
      return;
    }
    final blocked = _ref.read(appStateProvider).blockedChannels;
    if (blocked.contains(channel)) {
      _emitSystemMessage(tr(
          'Channel #{channel} is blocked. Use /unblock #{channel} to unblock it first.',
          {'channel': channel}));
      return;
    }
    final geohash = isChannelGeohash(channel) ? channel : '';
    addChannel(channel, geohash: geohash);
    switchChannel(channel, geohash: geohash);
  }

  /// `/leave` for channels; PM/group leave is wired via [setCommandHooks].
  void cmdLeave() {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return;
    final key = state.view.id.toLowerCase();
    if (key == 'nymchat') {
      _emitSystemMessage(tr('Cannot leave the default #nymchat channel'));
      return;
    }
    removeChannel(key);
    // `key` is the bare geohash/name, never '#'-prefixed.
    _emitSystemMessage(tr('Left channel #{key}', {'key': key}));
  }

  /// `/who`: current-channel users active within 300s.
  void cmdWho() {
    final state = _ref.read(appStateProvider);
    final key = state.view.id.toLowerCase();
    final now = DateTime.now().millisecondsSinceEpoch;
    final names = state.users.values
        .where((u) => u.channels.contains(key))
        .where((u) => now - u.lastSeen < kActiveThresholdMs)
        .map((u) => '${stripPubkeySuffix(u.nym)}#${getPubkeySuffix(u.pubkey)}')
        .toList()
      ..sort();
    _emitFeedMessage(tr('Online nyms in this channel: {names}',
        {'names': names.isEmpty ? tr('none') : names.join(', ')}));
  }

  /// `/nick`: trim and cap at 20; reserved nicks need the dev-nsec challenge; persists across relaunch.
  Future<void> cmdNick(String newNym) async {
    final trimmed = newNym.trim();
    if (trimmed.isEmpty) {
      _emitSystemMessage(tr('Usage: /nick newnym'));
      return;
    }
    final next = trimmed.length > 20 ? trimmed.substring(0, 20) : trimmed;
    if (stripPubkeySuffix(_identity?.nym ?? '') == next) {
      _emitSystemMessage(tr('That is already your current nym'));
      return;
    }
    if (isReservedNick(next)) {
      final challenge = _dispatcher.hooks.openDevNsecChallenge;
      if (challenge != null) {
        challenge();
        return;
      }
      _emitSystemMessage(tr('Nickname change canceled.'));
      return;
    }
    await saveProfile(name: next);
    _emitSystemMessage(tr(
        "Your nym's new nick is now {nick}", {'nick': _identity?.nym ?? next}));
  }

  Future<void> cmdSetAway(String message) async {
    await publishPresence('away', awayMessage: message);
    _emitSystemMessage(
        tr('Away message set: "{message}"', {'message': message}));
    _emitSystemMessage(
        tr('You will auto-reply to mentions in ALL channels while away'));
  }

  Future<void> cmdBack() async {
    await publishPresence('online');
    _emitSystemMessage(tr('Away message cleared - you are back!'));
  }

  /// TODO(verify): a real clear needs an app_state clear API.
  void cmdClear() => _emitSystemMessage(tr('Chat cleared'));

  void cmdShare() {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return;
    _emitFeedMessage('https://app.nym.bar/#${state.view.id}');
  }

  /// `/quit`: stops the service and clears the saved dev nsec and pubkey-scoped lightning address.
  void cmdQuit() {
    _emitSystemMessage(tr('Disconnecting from Nymchat...'));
    final pubkey = _identity?.pubkey;
    if (pubkey != null && pubkey.isNotEmpty) {
      unawaited(_ref
          .read(keyValueStoreProvider)
          .remove(StorageKeys.lightningAddressFor(pubkey)));
    }
    unawaited(SecureStore().remove(SecretKeys.devNsec));
    unawaited(_service?.stop());
  }

  /// `/block`: block a #channel or a user.
  void cmdBlock(String arg) {
    final state = _ref.read(appStateProvider);
    final target = arg.trim();
    if (target.isEmpty) {
      if (state.view.kind != ViewKind.channel) {
        _emitSystemMessage(tr(
            'Usage: /block nym, /block nym#xxxx, /block [pubkey], or /block #channel'));
        return;
      }
      final key = state.view.id.toLowerCase();
      if (key == 'nymchat') {
        _emitSystemMessage(tr('Cannot block the default #nymchat channel'));
        return;
      }
      if (blockChannel(key)) {
        _emitSystemMessage(isChannelGeohash(key)
            ? tr('Blocked geohash channel #{key}', {'key': key})
            : tr('Blocked channel #{key}', {'key': key}));
        switchChannel('nymchat');
      }
      return;
    }
    if (target.startsWith('#')) {
      final name = target.substring(1).toLowerCase();
      if (name == 'nymchat') {
        _emitSystemMessage(tr('Cannot block the default #nymchat channel'));
        return;
      }
      if (blockChannel(name)) {
        _emitSystemMessage(isChannelGeohash(name)
            ? tr('Blocked geohash channel #{name}', {'name': name})
            : tr('Blocked channel #{name}', {'name': name}));
      }
      return;
    }
    final t = resolveTarget(target, state.users);
    if (t == null) {
      _emitSystemMessage(tr('User {target} not found', {'target': target}));
      return;
    }
    blockUser(t.pubkey);
  }

  /// `/unblock`: unblock a #channel or a user.
  void cmdUnblock(String arg) {
    final state = _ref.read(appStateProvider);
    final target = arg.trim();
    if (target.startsWith('#')) {
      final name = target.substring(1).toLowerCase();
      if (state.blockedChannels.contains(name)) {
        unblockChannelEffect(name);
        _emitSystemMessage(isChannelGeohash(name)
            ? tr('Unblocked geohash channel #{name}', {'name': name})
            : tr('Unblocked channel #{name}', {'name': name}));
      } else {
        _emitSystemMessage(
            tr('Channel #{name} is not blocked', {'name': name}));
      }
      return;
    }
    final t = resolveTarget(target, state.users);
    if (t == null || !state.blockedUsers.contains(t.pubkey)) {
      _emitSystemMessage(
          tr('User {target} not found or is not blocked', {'target': target}));
      return;
    }
    unblockUser(t.pubkey);
  }

  /// Unblocks [key] and persists.
  void unblockChannelEffect(String key) {
    _ref.read(appStateProvider.notifier).unblockChannel(key);
    _persistSet(StorageKeys.blockedChannels,
        _ref.read(appStateProvider).blockedChannels);
  }

  /// Whether [key] is a geohash channel (valid geohash, non-default).
  bool isChannelGeohash(String key) => isValidGeohash(key) && key != 'nymchat';

  /// Opens or creates a PM with [peerPubkey], canonicalized to lowercase hex so every entry point hits the same thread.
  void startPM(String peerPubkey, {String? nym}) {
    var peer = peerPubkey.trim();
    // Accept hex, npub or nprofile.
    final normalized = normalizePubkeyInput(peer);
    if (normalized != null) {
      peer = normalized;
    } else if (RegExp(r'^(npub|nprofile)1', caseSensitive: false)
        .hasMatch(peer)) {
      return; // malformed bech32 key — nothing to open
    }
    if (peer.isEmpty) return;
    final appState = _ref.read(appStateProvider.notifier);
    appState.ensurePMConversation(peer, nym: nym);
    appState.switchView(ChatView.pm(peer));
    // Resolve the peer's kind-0 so a brand-new PM shows their avatar and nym.
    ensureProfiles([peer]);
  }

  /// Creates a group, registers it and switches; optional extras flow into the bootstrap invite.
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
    // Each message costs one gift wrap per member, so bound fan-out.
    if ({...memberPubkeys, identity.pubkey}.length > kMaxGroupMembers) {
      _emitSystemMessage(tr(
          'Groups are limited to {n} members (every message is encrypted separately for each member).',
          {'n': '$kMaxGroupMembers'}));
      return null;
    }
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

  /// Joiner side of an invite link: gift-wraps a `group-join-request` to the sharer; opens the group if already known.
  Future<void> joinGroupViaInvite(GroupInviteToken token) async {
    final appState = _ref.read(appStateProvider.notifier);
    // Already a member: just open it.
    if (appState.groupById(token.groupId) != null) {
      appState.switchView(ChatView.group(token.groupId));
      return;
    }
    final identity = _identity;
    final service = _service;
    // Our own invite link.
    if (identity != null && token.approver == identity.pubkey) {
      _emitSystemMessage(tr('That is your own invite link.'));
      return;
    }
    final sanitized = _sanitizeGroupName(token.name);
    final name = sanitized.isEmpty ? tr('this group') : sanitized;
    if (identity == null || service == null || !service.canSign) {
      _emitSystemMessage(tr(
          'Pick a nym or log in to join "{name}", then you\'ll be added.',
          {'name': name}));
      return;
    }
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
    final pending =
        _ref.read(groupToolsProvider).rememberPendingJoin(token.toPayload());
    try {
      await service.publishGiftWrappedRumor(
        rumor: rumor,
        recipients: [token.approver],
      );
      if (pending.approval) {
        _emitSystemMessage(tr(
            'Join request sent for "{name}". Waiting for approval from an admin.',
            {'name': name}));
        return;
      }
      _emitSystemMessage(tr(
          'Join request sent for "{name}". You\'ll be added once a member is online.',
          {'name': name}));
    } catch (_) {
      _emitSystemMessage(tr('Failed to send join request. Please try again.'));
    }
  }

  /// Sends [body] as a gift-wrapped PM (plus self-copy) to the verified developer; false when empty or unable to send.
  Future<bool> sendContactMessage(String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return false;
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null || !service.canSign) return false;

    recordOwnActivity();

    final nymMessageId = PmLogic.generateSharedEventId();
    final rumor = PmLogic.buildPmRumor(
      selfPubkey: identity.pubkey,
      recipientPubkey: verifiedDeveloperPubkey,
      content: trimmed,
      nymMessageId: nymMessageId,
    );
    try {
      final peerKem = _pqLayeredPeerKey(verifiedDeveloperPubkey);
      return await service.publishPM(
        rumor: rumor,
        recipientPubkey: verifiedDeveloperPubkey,
        settings: _msgSettings,
        recipientKemPublicKey: peerKem,
        recipientLayered: peerKem != null,
        selfKemPublicKey: pqSelfKey(),
        selfLayered: pqSelfUsesLayered(),
      );
    } catch (_) {
      return false;
    }
  }

  /// Gift-wraps our nickname, avatar and transferable settings to [recipientPubkey]; true if published.
  Future<bool> sendSettingsTransfer(String recipientPubkey) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null || !service.canSign) return false;

    recordOwnActivity();

    // Flatten section payloads and drop per-section `v` markers to match the PWA's flat shape.
    final settings = _ref.read(settingsProvider);
    final transferSettings = <String, dynamic>{};
    StorageSync.buildSectionPayloads(settings).forEach((_, fields) {
      fields.forEach((k, v) {
        if (k == 'v') return;
        transferSettings[k] = v;
      });
    });
    // Strip the device-local keys the PWA deletes before sending.
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

  // Cache size / clear; both no-op before [init].

  /// On-disk cache size in bytes; 0 before the cache opens.
  Future<int> cacheSizeBytes() async {
    final cache = _cache;
    if (cache == null || !cache.isOpen) return 0;
    return cache.totalBytes();
  }

  /// Clears the on-disk cache and mirrors the wipe in the open session.
  Future<void> clearCache() async {
    final cache = _cache;
    if (cache == null || !cache.isOpen) return;
    // Cancel the pending flush so we don't re-write what we're dropping.
    _flushTimer?.cancel();
    _flushScheduled = false;
    _dirtyChannelKeys.clear();
    _dirtyPmKeys.clear();
    await cache.wipe();
    final appState = _ref.read(appStateProvider);
    appState.messages.clear();
    appState.reactions.clear();
    for (final u in appState.users.values) {
      u.profile?.about = null;
    }
    // Clear session dedup sets so relay backlog can re-ingest the wiped conversations.
    _ref.read(appStateProvider.notifier).clearSessionDedup();
    // An empty hydrate republishes state so open conversations re-render empty.
    _ref.read(appStateProvider.notifier).hydrateReactions(const {});
  }

  /// Wipes the on-device PM/group cache when "Cache PMs & Group Chats" is turned off.
  Future<void> clearPmGroupCache() async {
    final cache = _cache;
    if (cache == null || !cache.isOpen) return;
    _dirtyPmKeys.clear();
    await cache.clearPms();
  }

  // Moderation entry points (role-checked).

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

  /// Promotes [targetPubkey] to moderator (owner-only); the role rides the `mod` tag.
  Future<bool> promoteModerator(String groupId, String targetPubkey) =>
      _sendModRoleControl(groupId, targetPubkey, GroupControlType.promoteMod,
          ['mod', targetPubkey]);

  /// Revokes [targetPubkey]'s moderator role (owner-only); uses the `mod` tag.
  Future<bool> revokeModerator(String groupId, String targetPubkey) =>
      _sendModRoleControl(groupId, targetPubkey, GroupControlType.revokeMod,
          ['mod', targetPubkey]);

  /// Transfers ownership to [targetPubkey] (owner-only); the new owner rides the `owner` tag.
  Future<bool> transferOwner(String groupId, String targetPubkey) =>
      _sendModRoleControl(groupId, targetPubkey, GroupControlType.transferOwner,
          ['owner', targetPubkey]);

  Future<bool> promoteAdmin(String groupId, String targetPubkey) =>
      _sendModRoleControl(groupId, targetPubkey, GroupControlType.promoteAdmin,
          ['admin', targetPubkey]);

  Future<bool> revokeAdmin(String groupId, String targetPubkey) =>
      _sendModRoleControl(groupId, targetPubkey, GroupControlType.revokeAdmin,
          ['admin', targetPubkey]);

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
    final spec = groupRoleEvents[type];
    if (spec != null) {
      if (!GroupLogic.roleEventAuthorized(
          group, spec, identity.pubkey, targetPubkey)) {
        return false;
      }
    } else if (!GroupLogic.isOwner(group, identity.pubkey)) {
      return false; // transfer stays owner-only
    }
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

  final Map<String, int> _rosterReplyTs = {};
  final Map<String, int> _rosterRepairTs = {};

  Future<void> _maybeRepairRoster(
      String groupId, String advertised, String senderPubkey) async {
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    final identity = _identity;
    final groups = _groups;
    if (group == null || identity == null || groups == null) return;
    if (GroupLogic.rosterHash(groupId, group.members) == advertised) return;
    if (!GroupLogic.isBareShell(group, identity.pubkey) &&
        !group.members.contains(senderPubkey)) {
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if ((_rosterRepairTs[groupId] ?? 0) >
        nowMs - kGroupRosterRepairCooldownMs) {
      return;
    }
    _rosterRepairTs[groupId] = nowMs;
    await groups.sendControl(
      group: group,
      selfPubkey: identity.pubkey,
      type: GroupControlType.rosterReq,
      extraTags: const [],
      recipients: [senderPubkey],
    );
  }

  final Map<String, int> _ephAnnounceMs = {};

  Future<void> announceGroupEphemeralKey(String groupId) async {
    final identity = _identity;
    final groups = _groups;
    final group = _ref.read(appStateProvider.notifier).groupById(groupId);
    if (identity == null || groups == null || group == null) return;
    if (group.members.where((pk) => pk != identity.pubkey).isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if ((_ephAnnounceMs[groupId] ?? 0) >
        nowMs - kGroupResyncCooldownSec * 1000) {
      return;
    }
    _ephAnnounceMs[groupId] = nowMs;
    await groups.sendKeyResyncRequest(
      group: group,
      selfPubkey: identity.pubkey,
      settings: _msgSettings,
    );
    _afterSelfKeyRotation();
  }

  Future<bool> unbanFromGroup(String groupId, String pubkey) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.canModerate(group, identity.pubkey)) return false;
    if (!group.banned.contains(pubkey)) return false;
    final extraTags = [
      ['unban', pubkey]
    ];
    final recipients = <String>{...group.members, pubkey}
        .where((pk) => pk != identity.pubkey)
        .toList();
    final ok = recipients.isEmpty ||
        await groups.sendControl(
          group: group,
          selfPubkey: identity.pubkey,
          type: GroupControlType.unban,
          extraTags: extraTags,
          recipients: recipients,
        );
    appState.applyGroupControl(
      groupId: groupId,
      type: GroupControlType.unban,
      tags: extraTags,
      senderPubkey: identity.pubkey,
      ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      eventId: GroupLogic.generateGroupId(),
    );
    return ok;
  }

  /// Publishes a mod/owner `group-delete-message` and removes the message locally.
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
    // Inbound handlers read `['e', targetId]` and `['target_pubkey', author]`.
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
    appState.removeMessage(messageId,
        author: authorPubkey, storageKey: GroupLogic.groupStorageKey(group.id));
    if (ok) _emitSystemMessage(tr('Message deleted'));
    return ok;
  }

  // Group owner / membership controls.

  /// Leaves [groupId]: notifies members, then drops the group locally and switches away if open.
  Future<bool> leaveGroup(String groupId, {bool quiet = false}) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || group == null) return false;
    if (groups == null && !quiet) return false;

    // Notify the other members (best-effort; needs a signer).
    final suffix = getPubkeySuffix(identity.pubkey);
    final leaveContent =
        '${stripPubkeySuffix(identity.nym)}#$suffix left the group.';
    if (!quiet) {
      await groups!.sendLeave(
        group: group,
        selfPubkey: identity.pubkey,
        content: leaveContent,
        settings: _msgSettings,
      );
    }

    // Remove the group's ephemeral keys after the leave wrap (which uses them) and before the persist below.
    groups?.removeGroup(groupId);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final selfModTs = group.modTsByTarget[identity.pubkey] ?? 0;

    // Drop locally via the always-authorized self-removal path, which persists and syncs the leave.
    appState.applyGroupControl(
      groupId: groupId,
      type: GroupControlType.removeMember,
      tags: [
        ['kick', identity.pubkey],
      ],
      senderPubkey: identity.pubkey,
      ts: selfModTs > nowSec ? selfModTs : nowSec,
      eventId: GroupLogic.generateGroupId(),
    );

    // Security: tombstone the group's D1 key blob so its ephemeral secrets aren't recoverable; history shards are kept.
    final sync = _storageSync;
    if (sync != null) {
      unawaited(sync.groupSyncSet(
        groupConversations: const {},
        ephemeralKeysByGroup: {groupId: const <String, dynamic>{}},
        historyByConvKey: const {},
      ));
    }

    // Stamp the read watermark and drop the badge so a re-invite can't resurrect a stale count.
    appState.clearUnread(GroupLogic.groupStorageKey(groupId));

    // Fall back to the default channel if the group was open.
    if (_ref.read(appStateProvider).view.kind == ViewKind.group &&
        _ref.read(appStateProvider).view.id == groupId) {
      appState.switchView(ChatView.channel('nymchat'));
    }
    return true;
  }

  /// Owner-only metadata update and broadcast; null leaves a field unchanged, empty clears avatar/banner.
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

  /// Owner-only toggle for member invites; broadcasts `group-metadata`; true if changed.
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
        ? tr('Group members can now add new users.')
        : tr('Only the group owner can add new users now.'));
    return true;
  }

  /// Owner-only toggle for sharing history with new members; every member needs the policy; true if changed.
  Future<bool> setGroupShareHistory(String groupId, bool enabled) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.isOwner(group, identity.pubkey)) {
      _emitSystemMessage(tr('Only the group owner can change this setting.'));
      return false;
    }
    if (enabled == group.shareHistory) return false;

    group.shareHistory = enabled;
    group.metaUpdatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    appState.upsertGroup(group);
    await groups.sendMetadata(
      group: group,
      selfPubkey: identity.pubkey,
      settings: _msgSettings,
    );
    _emitSystemMessage(enabled
        ? tr('New members will now receive recent chat history when they join.')
        : tr('New members will no longer receive chat history.'));
    return true;
  }

  /// Sends recent plain chat history to a new member as one blob; the receiver marks it unverified.
  Future<void> _sendGroupHistoryTo(Group group, String memberPubkey) async {
    final identity = _identity;
    final groups = _groups;
    if (identity == null || groups == null || !group.shareHistory) return;
    final key = GroupLogic.groupStorageKey(group.id);
    final list = _ref.read(appStateProvider).messages[key] ?? const <Message>[];
    const maxMsgs = 50;
    const maxJson = 32000; // stay well under the NIP-44 plaintext cap
    final picked = <Map<String, dynamic>>[];
    for (var i = list.length - 1; i >= 0 && picked.length < maxMsgs; i--) {
      final m = list[i];
      if (m.kind != MessageKind.normal) continue;
      if (m.content.isEmpty || m.isFileOffer) continue;
      final x = m.nymMessageId;
      if (m.pubkey.isEmpty || x == null || x.isEmpty) continue;
      picked.add({
        'p': m.pubkey,
        'c': m.content.length > 2000 ? m.content.substring(0, 2000) : m.content,
        't': m.createdAt,
        'x': x,
      });
    }
    if (picked.isEmpty) return;
    var payload = picked.reversed.toList(); // oldest first
    while (payload.length > 1 && jsonEncode(payload).length > maxJson) {
      payload = payload.sublist((payload.length / 4).ceil());
    }
    try {
      await groups.sendControl(
        group: group,
        selfPubkey: identity.pubkey,
        type: GroupControlType.history,
        extraTags: const [],
        recipients: [memberPubkey],
        content: jsonEncode(payload),
      );
    } catch (_) {}
  }

  /// Shared-history blobs waiting for their group to exist.
  final Map<String, _PendingGroupHistory> _pendingGroupHistory = {};

  /// Folds in a shared history blob: sharing on, sender a member, first blob, and our copy still empty.
  void _handleGroupHistoryShare(
      String groupId, String senderPubkey, Map<String, dynamic> rumor) {
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (group == null) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      _pendingGroupHistory
          .removeWhere((_, e) => nowMs - e.stashedAtMs > 600000);
      if (_pendingGroupHistory.length < 8 &&
          !_pendingGroupHistory.containsKey(groupId)) {
        _pendingGroupHistory[groupId] = _PendingGroupHistory(
            senderPubkey: senderPubkey, rumor: rumor, stashedAtMs: nowMs);
      }
      return;
    }
    if (!group.shareHistory || group.historyReceived) return;
    final isMemberSender =
        group.createdBy == senderPubkey || group.members.contains(senderPubkey);
    if (!isMemberSender) return;
    final key = GroupLogic.groupStorageKey(groupId);
    // Only fresh joiners: if we already hold history, this blob isn't for us.
    final existing = _ref.read(appStateProvider).messages[key];
    if (existing != null && existing.length > 3) return;

    final content = rumor['content'];
    if (content is! String || content.isEmpty) return;
    List<dynamic> entries;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! List) return;
      entries = decoded;
    } catch (_) {
      return;
    }
    if (entries.length > 100) entries = entries.sublist(0, 100);

    final hexRe = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final self = _identity?.pubkey ?? '';
    var added = 0;
    for (final e in entries) {
      if (e is! Map) continue;
      final p = e['p'];
      final c = e['c'];
      final x = e['x'];
      if (p is! String || !hexRe.hasMatch(p)) continue;
      if (c is! String || c.isEmpty) continue;
      if (x is! String || !hexRe.hasMatch(x)) continue;
      var t = (e['t'] as num?)?.toInt() ?? 0;
      if (t <= 0) continue;
      if (t > nowSec) t = nowSec;
      final pk = p.toLowerCase();
      final landed = appState.ingestGroupMessage(Message(
        id: x,
        author: _nymDisplayFor(pk),
        pubkey: pk,
        content: c.length > 4000 ? c.substring(0, 4000) : c,
        createdAt: t,
        isOwn: pk == self,
        isGroup: true,
        groupId: groupId,
        conversationKey: key,
        eventKind: EventKind.giftWrap,
        isHistorical: true,
        // Forwarded by another member; the original seal isn't verifiable.
        senderVerified: false,
        nymMessageId: x,
        deliveryStatus: DeliveryStatus.delivered,
      ));
      if (landed) {
        added++;
        _maybeBackfillProfiles(pk);
      }
    }
    if (added == 0) return;
    group.historyReceived = true;
    appState.upsertGroup(group);
    appState.addSystemMessage(
      tr('{count} earlier messages shared by {name}.',
          {'count': '$added', 'name': _nymDisplayFor(senderPubkey)}),
      storageKey: key,
    );
  }

  void _processPendingGroupHistory(String groupId) {
    final pending = _pendingGroupHistory.remove(groupId);
    if (pending == null) return;
    _handleGroupHistoryShare(groupId, pending.senderPubkey, pending.rumor);
  }

  // Key-resync heartbeat: after a long offline gap, re-exchange current keys since expired rotations leave stale ones.

  int _offlineGapSec = 0;
  bool _lastOnlineTrackingStarted = false;
  Timer? _lastOnlineTimer;
  final Map<String, int> _keyResyncReplyMs = {};

  /// Tracks last-online time (refreshed every 2 minutes) and returns the offline gap at boot.
  int _initLastOnlineTracking() {
    if (_lastOnlineTrackingStarted) return _offlineGapSec;
    _lastOnlineTrackingStarted = true;
    final kv = _ref.read(keyValueStoreProvider);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final stored = int.tryParse(kv.getString('nym_last_online_ts') ?? '') ?? 0;
    final gap = stored > 0 ? nowSec - stored : 0;
    _offlineGapSec = gap > 0 ? gap : 0;
    void write() => kv.setString('nym_last_online_ts',
        '${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
    write();
    _lastOnlineTimer =
        Timer.periodic(const Duration(minutes: 2), (_) => write());
    return _offlineGapSec;
  }

  /// After catch-up, if offline longer than [kGroupResyncOfflineGapSec], request a key resync per group, rate-limited.
  Future<void> _maybeSendGroupKeyResyncs() async {
    try {
      final gap = _initLastOnlineTracking();
      final identity = _identity;
      final groups = _groups;
      final service = _service;
      if (identity == null ||
          groups == null ||
          service == null ||
          !service.canSign) {
        return;
      }
      if (gap < kGroupResyncOfflineGapSec) return;
      final st = _ref.read(appStateProvider);
      if (st.groups.isEmpty) return;
      final kv = _ref.read(keyValueStoreProvider);
      Map<String, dynamic> cooldowns = {};
      try {
        final raw = kv.getString('nym_group_resync_ts');
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) cooldowns = decoded.cast<String, dynamic>();
        }
      } catch (_) {}
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      var sentAny = false;
      for (final group in List<Group>.from(st.groups)) {
        final others =
            group.members.where((pk) => pk != identity.pubkey).toList();
        if (others.isEmpty) continue;
        final last = (cooldowns[group.id] as num?)?.toInt() ?? 0;
        if (last > nowSec - kGroupResyncCooldownSec) continue;
        cooldowns[group.id] = nowSec;
        await groups.sendKeyResyncRequest(
          group: group,
          selfPubkey: identity.pubkey,
          settings: _msgSettings,
        );
        sentAny = true;
      }
      try {
        kv.setString('nym_group_resync_ts', jsonEncode(cooldowns));
      } catch (_) {}
      // ensureSelf may have minted keys — persist and re-arm the ephemeral REQ.
      if (sentAny) _afterSelfKeyRotation();
    } catch (_) {}
  }

  /// Replies to a key-resync request with our current key, rate-limited to 1h per group and requester.
  Future<void> _maybeReplyKeyResync(String groupId, String requester) async {
    try {
      final identity = _identity;
      final groups = _groups;
      if (identity == null || groups == null) return;
      final group = _ref.read(appStateProvider.notifier).groupById(groupId);
      if (group == null) return;
      final isMemberSender =
          group.createdBy == requester || group.members.contains(requester);
      if (!isMemberSender) return;
      if (!group.members.contains(identity.pubkey)) return;
      final rlKey = '$groupId:$requester';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if ((_keyResyncReplyMs[rlKey] ?? 0) > nowMs - 3600000) return;
      _keyResyncReplyMs[rlKey] = nowMs;
      await groups.sendKeyResyncReply(
        group: group,
        selfPubkey: identity.pubkey,
        requesterPubkey: requester,
        settings: _msgSettings,
      );
      _persistGroupStore();
    } catch (_) {}
  }

  /// Owner-only toggle for invite-link joins; broadcasts `group-metadata`; true if changed.
  Future<bool> setGroupInviteEnabled(String groupId, bool enabled) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.isOwner(group, identity.pubkey)) {
      _emitSystemMessage(tr('Only the group owner can change this setting.'));
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
        ? tr('Joining via invite link is now enabled.')
        : tr('Joining via invite link is now disabled.'));
    return true;
  }

  /// Owner-only: rotates the invite epoch, revoking all invite links.
  Future<bool> rotateGroupInviteEpoch(String groupId) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.isOwner(group, identity.pubkey)) {
      _emitSystemMessage(tr('Only the group owner can reset the invite link.'));
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
        tr('Previous invite links revoked. A new link is now active.'));
    return true;
  }

  /// Adds members and broadcasts one `group-add-member`; banned users need a moderator; true if any added.
  Future<bool> addGroupMembers(String groupId, List<String> pubkeys,
      {bool viaJoin = false}) async {
    final identity = _identity;
    final groups = _groups;
    final testSend = addMembersSenderForTest;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || group == null) return false;
    if (groups == null && testSend == null) return false;
    if (!GroupLogic.canAddMembers(group, identity.pubkey)) {
      _emitSystemMessage(tr(
          'Only the group owner or an admin can add new members to this group.'));
      return false;
    }

    final canMod = GroupLogic.canModerate(group, identity.pubkey);
    final wanted = <String>[];
    var bannedRefused = false;
    for (final pk in pubkeys) {
      if (pk.isEmpty || pk == identity.pubkey) continue;
      if (group.members.contains(pk) || wanted.contains(pk)) continue;
      if (group.banned.contains(pk) && !canMod) {
        bannedRefused = true;
        continue;
      }
      wanted.add(pk);
    }
    if (bannedRefused) {
      _emitSystemMessage(tr(
          'That user was removed from this group and can only be re-invited by the group owner or a moderator.'));
    }
    final room = kMaxGroupMembers - group.members.length;
    final fit = wanted.take(room > 0 ? room : 0).toList();
    final skipped = wanted.skip(fit.length).toList();
    if (skipped.isNotEmpty) {
      final groupName = group.name.isEmpty ? tr('Group') : group.name;
      if (viaJoin) {
        for (final pk in skipped) {
          _emitSystemMessage(tr('{group} is full, so {nym} couldn\'t join.',
              {'group': groupName, 'nym': _nymDisplayFor(pk)}));
          unawaited(_sendJoinDeclinedFull(group, pk));
        }
      } else {
        _emitSystemMessage(tr(
            '{group} is full, so these weren\'t added: {names}.', {
          'group': groupName,
          'names': skipped.map(_nymDisplayFor).join(', '),
        }));
      }
    }
    if (fit.isEmpty) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final pk in fit) {
      group.banned.remove(pk);
    }
    final admit =
        GroupLogic.admitMembers(group, {for (final pk in fit) pk: nowSec});
    final added = admit.added;
    if (added.isEmpty) return false;
    (_ownGroupAdds[groupId] ??= <String>{}).addAll(added);
    appState.upsertGroup(group);

    final inviter = '${stripPubkeySuffix(identity.nym)}#'
        '${getPubkeySuffix(identity.pubkey)}';
    final names = added.map((pk) => _nymDisplayFor(pk)).join(', ');
    final content = added.length == 1
        ? '$names was added by $inviter.'
        : '$names were added by $inviter.';
    if (testSend != null) {
      await testSend(group, content, nowSec);
    } else {
      await groups!.addMembers(
        group: group,
        selfPubkey: identity.pubkey,
        content: content,
        settings: _msgSettings,
        nowSec: nowSec,
        newMembers: added,
      );
    }
    if (group.shareHistory && groups != null) {
      for (final pk in added) {
        unawaited(_sendGroupHistoryTo(group, pk));
      }
    }
    _emitFeedMessage(content);
    return true;
  }

  final Map<String, Set<String>> _ownGroupAdds = {};

  int _joinAt(int createdAt) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return createdAt < nowSec ? createdAt : nowSec;
  }

  bool _admitBootstrapRoster(Group group, Map<String, int> members) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    GroupLogic.admitMembers(group, members, respectRemovals: false);
    if (self.isEmpty || group.members.contains(self)) return true;
    final name = group.name.isEmpty ? tr('Group') : group.name;
    _emitSystemMessage(
        tr('{group} is full, so you couldn\'t join.', {'group': name}));
    return false;
  }

  Future<bool> _sendJoinDeclinedFull(Group group, String joiner) {
    final tags = GroupLogic.joinDeclinedFullTags(
      joiner: joiner,
      groupId: group.id,
      groupName: group.name,
      sharedEventId: PmLogic.generateSharedEventId(),
    );
    return gtSendDirect(
        joiner, tags.sublist(1), GroupLogic.joinDeclinedFullContent);
  }

  void _onGroupMembersEvicted(String groupId, List<String> evicted) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    final group = _ref.read(appStateProvider.notifier).groupById(groupId);
    final own = _ownGroupAdds[groupId];
    if (group != null && own != null) {
      final name = group.name.isEmpty ? tr('Group') : group.name;
      for (final pk in evicted) {
        if (pk == self || !own.remove(pk)) continue;
        _emitSystemMessage(tr('{group} is full, so {nym} wasn\'t added.',
            {'group': name, 'nym': _nymDisplayFor(pk)}));
        unawaited(_sendJoinDeclinedFull(group, pk));
      }
    }
    if (self.isNotEmpty && evicted.contains(self)) {
      scheduleMicrotask(() => _leaveFullGroupLocally(groupId));
    }
  }

  bool _lostJoinRace(String groupId, List<List<String>> tags,
      String senderPubkey, AppStateNotifier appState) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    final group = appState.groupById(groupId);
    if (group == null || self.isEmpty || senderPubkey == self) return false;
    if (_tagValue(tags, 'p') != self) return false;
    if (!group.members.contains(self)) return false;
    if (_ref.read(groupToolsProvider).isPendingJoin(groupId)) return false;
    return senderPubkey == group.joinedVia ||
        GroupLogic.isOwner(group, senderPubkey) ||
        GroupLogic.isAdmin(group, senderPubkey);
  }

  void _leaveFullGroupLocally(String groupId) {
    final group = _ref.read(appStateProvider.notifier).groupById(groupId);
    if (group == null || _leavingFull.contains(groupId)) return;
    _leavingFull.add(groupId);
    final name = group.name.isEmpty ? tr('Group') : group.name;
    _emitSystemMessage(
        tr('{group} is full, so you couldn\'t join.', {'group': name}));
    unawaited(leaveGroup(groupId, quiet: true)
        .whenComplete(() => _leavingFull.remove(groupId)));
  }

  final Set<String> _leavingFull = <String>{};

  /// Strips control chars, collapses whitespace, caps at 40.
  static String _sanitizeGroupName(String name) {
    final collapsed = name
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return collapsed.length > 40 ? collapsed.substring(0, 40) : collapsed;
  }

  /// Keeps newlines, strips other control chars, collapses 3+ newlines, caps at 150.
  static String _sanitizeGroupDescription(String description) {
    final cleaned = description
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return cleaned.length > 150 ? cleaned.substring(0, 150) : cleaned;
  }

  // Social / moderation.

  bool toggleFriend(String pubkey) {
    if (pubkey.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final nowFriend = appState.toggleFriend(pubkey);
    _persistSet(StorageKeys.friends, _ref.read(appStateProvider).friends);
    final nymHtml = _nymDisplayFor(pubkey);
    _emitSystemMessage(nowFriend
        ? tr('Added {nym} as a friend', {'nym': nymHtml})
        : tr('Removed {nym} from friends', {'nym': nymHtml}));
    return nowFriend;
  }

  bool blockUser(String pubkey) {
    if (pubkey.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final added = appState.blockUser(pubkey);
    if (added) {
      _persistSet(
          StorageKeys.blocked, _ref.read(appStateProvider).blockedUsers);
      // The bell badge stops counting a blocked sender immediately.
      _ref
          .read(notificationHistoryProvider.notifier)
          .setBlocked(_ref.read(appStateProvider).blockedUsers);
      _emitSystemMessage(tr('Blocked {nym}', {'nym': _nymDisplayFor(pubkey)}));
      // Blocking mid-call ends a 1:1 call or drops the peer from a group call.
      _ref.read(callServiceProvider).onUserBlocked(pubkey);
    }
    return added;
  }

  bool unblockUser(String pubkey) {
    final appState = _ref.read(appStateProvider.notifier);
    if (appState.clearAutoMute(pubkey)) {
      _persistAutoMuted();
    }
    final removed = appState.unblockUser(pubkey);
    if (removed) {
      _persistSet(
          StorageKeys.blocked, _ref.read(appStateProvider).blockedUsers);
      // Unblocked senders' notifications count again.
      _ref
          .read(notificationHistoryProvider.notifier)
          .setBlocked(_ref.read(appStateProvider).blockedUsers);
      _emitSystemMessage(
          tr('Unblocked {nym}', {'nym': _nymDisplayFor(pubkey)}));
    }
    return removed;
  }

  bool toggleBlockUser(String pubkey) {
    final blocked = _ref.read(appStateProvider).blockedUsers.contains(pubkey);
    return blocked ? !unblockUser(pubkey) : blockUser(pubkey);
  }

  bool addBlockedKeyword(String keyword) {
    final appState = _ref.read(appStateProvider.notifier);
    final kw = appState.addBlockedKeyword(keyword);
    if (kw == null) return false;
    _persistSet(StorageKeys.blockedKeywords,
        _ref.read(appStateProvider).blockedKeywords);
    _emitSystemMessage(tr('Blocked keyword: "{keyword}"', {'keyword': kw}));
    return true;
  }

  bool removeBlockedKeyword(String keyword) {
    final appState = _ref.read(appStateProvider.notifier);
    final removed = appState.removeBlockedKeyword(keyword);
    if (removed) {
      _persistSet(StorageKeys.blockedKeywords,
          _ref.read(appStateProvider).blockedKeywords);
      _emitSystemMessage(tr('Unblocked keyword: "{keyword}"',
          {'keyword': keyword.toLowerCase()}));
    }
    return removed;
  }

  // Message edit / delete.

  /// Re-publishes [messageId] with an `['edit', originalId]` tag and rewrites it locally; true if attempted.
  Future<bool> editMessage(String messageId, String newContent) async {
    final trimmed = newContent.trim();
    if (messageId.isEmpty || trimmed.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final identity = _identity;
    final view = state.view;

    // Local rewrite first (optimistic).
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

    if (view.kind == ViewKind.pm) {
      final base = PmLogic.buildPmRumor(
        selfPubkey: identity.pubkey,
        recipientPubkey: view.id,
        content: trimmed,
        nymMessageId: PmLogic.generateSharedEventId(),
      );
      final peerKem = _pqLayeredPeerKey(view.id);
      await service.publishPM(
        rumor: _withEditTag(base, messageId),
        recipientPubkey: view.id,
        settings: _msgSettings,
        recipientKemPublicKey: peerKem,
        recipientLayered: peerKem != null,
        selfKemPublicKey: pqSelfKey(),
        selfLayered: pqSelfUsesLayered(),
      );
      return true;
    }

    if (view.kind == ViewKind.group) {
      final group = appState.groupById(view.id);
      if (group == null) return false;
      final ek = _groups!.keysFor(group.id);
      final next = ek.rotateSelf();
      _applyEphemeralKeys();
      // After a self-key rotation: persist, re-REQ the ephemeral sub, and sync so other devices can decrypt.
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
        kemKeyFor: _pqGroupKeyFor,
        layeredFor: _pqGroupLayeredFor,
      );
      return true;
    }
    return false;
  }

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

  /// Publishes a kind-5 deletion (`e`, `k` tags) and removes the message locally; [originalKind] defaults from the view.
  Future<bool> deleteMessage(String messageId, {String? originalKind}) async {
    if (messageId.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final identity = _identity;
    final view = state.view;

    final kind = originalKind ?? _viewDeletionKind(state);

    // Find the message's channel before removal so the D1 purge can name it.
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

    // Mirror the deletion into D1 or the message resurrects on rehydration.
    final sync = _storageSync;
    if (sync != null) {
      if (channelName != null) {
        unawaited(sync.channelDelete(channelName, signed.toJson()));
      }
      // Gate on the same archive-allowed check used when archiving.
      if (kind == '${EventKind.giftWrap}' && sync.durableIdentity) {
        unawaited(sync.pmDelete([messageId]));
      }
    }
    _emitSystemMessage(tr('Deletion request sent to relays'));
    return true;
  }

  /// 1059 for PM/group, else the channel wire kind.
  String _viewDeletionKind(AppState state) {
    final view = state.view;
    if (view.kind != ViewKind.channel) return '${EventKind.giftWrap}';
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    return '${isGeo ? EventKind.geoChannel : EventKind.namedChannel}';
  }

  String _nymDisplayFor(String pubkey) {
    // The PWA never renders 'anon'.
    final u = _ref.read(appStateProvider).users[pubkey];
    final base = stripPubkeySuffix(u?.nym ?? 'nym');
    return '$base#${getPubkeySuffix(pubkey)}';
  }

  // Presence / typing / receipts.

  /// Last public presence broadcast (ms), throttled to ≤1/60s.
  int _lastPresenceBroadcast = 0;

  static const int _presenceBroadcastThrottleMs = 60000;

  PresenceStatusMode get _statusMode =>
      presenceStatusModeFrom(_ref.read(settingsProvider).showStatus);

  /// Publishes our presence, always with the avatar tag; [shopUpdate] adds the one-off shop cache-bust flag.
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

    // Friends-only: the public event went out as hidden; deliver the real status privately to friends.
    if (_statusMode == PresenceStatusMode.friends) {
      unawaited(_sendFriendPresence(status, awayMessage: awayMessage));
    }
  }

  /// Gift-wraps our real presence to each friend; best-effort.
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

  /// Records local activity and broadcasts presence (≤1/60s); no heartbeat, skipped while away or disabled.
  void recordOwnActivity() {
    final identity = _identity;
    if (identity == null) return;
    final appState = _ref.read(appStateProvider.notifier);
    final now = DateTime.now().millisecondsSinceEpoch;

    final existing = _ref.read(appStateProvider).users[identity.pubkey];
    final away =
        existing?.awayMessage != null && existing!.awayMessage!.isNotEmpty;
    // Mark ourselves recently seen.
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

  void _armTypingStop(String key, ChatView view) {
    _typingStopTimers.remove(key)?.cancel();
    _typingStopTimers[key] =
        Timer(const Duration(milliseconds: _typingStopDelayMs), () {
      _typingStopTimers.remove(key);
      _typingStartTimers.remove(key)?.cancel();
      if (!_typingStartedFor.remove(key)) return;
      unawaited(_sendTypingStop(view));
    });
  }

  Future<void> _sendTypingStop(ChatView view) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;
    if (view.kind == ViewKind.pm) {
      if (anonSuppressSendTo(view.id)) return;
      await service.publishTyping(status: 'stop', recipients: [view.id]);
      return;
    }
    if (view.kind != ViewKind.group) return;
    final group = _ref.read(appStateProvider.notifier).groupById(view.id);
    if (group == null) return;
    final ek = _groups!.keysFor(group.id);
    final others = group.members.where((p) => p != identity.pubkey).toList();
    if (others.isEmpty) return;
    await service.publishTyping(
      status: 'stop',
      recipients: others,
      groupId: group.id,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
    );
  }

  Future<void> sendTypingStart() async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;
    final state = _ref.read(appStateProvider);
    final view = state.view;
    // Typing scope: 'pms' / 'groups' / 'pms-groups' limit surfaces, 'disabled' suppresses; channels need 'everywhere'.
    final scope = _ref.read(settingsProvider).typingIndicatorsScope;
    final ctx = view.kind == ViewKind.pm
        ? 'pm'
        : view.kind == ViewKind.group
            ? 'group'
            : 'channel';
    if (!_indicatorScopeAllows(scope, ctx)) return;

    final key = view.storageKey;
    final now = DateTime.now().millisecondsSinceEpoch;
    _armTypingStop(key, view);
    if (_typingStartedFor.contains(key)) {
      if (now - (_typingThrottle[key] ?? 0) < _typingSendIntervalMs) return;
      _typingThrottle[key] = now;
    } else {
      if (_typingStartTimers.containsKey(key)) return;
      _typingStartTimers[key] =
          Timer(const Duration(milliseconds: _typingStartDebounceMs), () {
        _typingStartTimers.remove(key);
        _typingStartedFor.add(key);
        _typingThrottle[key] = DateTime.now().millisecondsSinceEpoch;
        unawaited(sendTypingStart());
      });
      return;
    }

    if (view.kind == ViewKind.channel) {
      // Named channels use the `d` tag, geohash channels `g`; we send for both.
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
      if (anonSuppressSendTo(view.id)) return;
      await service.publishTyping(
          status: 'start', recipients: [view.id], ttlSec: _typingTtlSec);
    } else {
      final group = _ref.read(appStateProvider.notifier).groupById(view.id);
      if (group == null) return;
      final ek = _groups!.keysFor(group.id);
      final others = group.members.where((p) => p != identity.pubkey).toList();
      await service.publishTyping(
        status: 'start',
        recipients: others,
        groupId: group.id,
        ttlSec: _typingTtlSec,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
      );
    }
  }

  /// 'pms', 'groups' or 'pms-groups' limit contexts, 'disabled' suppresses, anything else allows all.
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

  /// PM nymMessageIds already read-receipted; capped at 2000, trimmed to 1500.
  final Set<String> _sentPmReadReceipts = <String>{};

  /// Sends a PM read receipt once per message, gated by the read-receipt scope.
  Future<void> sendReadReceipt(String messageId, String peerPubkey) async {
    if (!_indicatorScopeAllows(
        _ref.read(settingsProvider).readReceiptsScope, 'pm')) {
      return;
    }
    if (messageId.isEmpty || peerPubkey.isEmpty) return;
    final service = _service;
    if (service == null) return;
    if (anonSuppressSendTo(peerPubkey)) return;
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

  /// Read-receipts every loaded non-own message in the open PM.
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

  // Public channel read receipts (kind 24421).

  /// Channel message ids already read-receipted; capped at 2000, trimmed to 1500.
  final Set<String> _sentChannelReadReceipts = <String>{};

  bool _channelReceiptAllowed() => _indicatorScopeAllows(
      _ref.read(settingsProvider).readReceiptsScope, 'channel');

  /// Publishes a channel read receipt once per message, never for our own; [isGeohash] picks `g` vs `d`.
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
      final keep = _sentChannelReadReceipts
          .toList()
          .sublist(_sentChannelReadReceipts.length - 1500);
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

  /// Catch-up read receipts for visible, fresh, non-own messages in the open channel.
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
    // Match the PWA's tail window of one channel page (100).
    final tail = messages.length > 100
        ? messages.sublist(messages.length - 100)
        : messages;
    for (final m in tail) {
      if (m.isOwn || m.isHistorical) continue;
      if (!_isChannelMessageId(m.id)) continue;
      // Named channels always use the channel key as the `d` value.
      final key = isGeohash
          ? ((m.geohash ?? '').isNotEmpty ? m.geohash! : channelKey)
          : channelKey;
      unawaited(
          sendChannelReadReceipt(m.id, m.pubkey, key, isGeohash: isGeohash));
    }
  }

  /// 64-hex channel-message id.
  static final RegExp _channelMessageIdRe =
      RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
  bool _isChannelMessageId(String id) => _channelMessageIdRe.hasMatch(id);

  // Group read receipts show as reader avatars, so only 'read' is sent, to the sender's ephemeral key.

  /// nymMessageIds already read-receipted in groups.
  final Set<String> _sentGroupReadReceipts = <String>{};

  /// Publishes a group read receipt to the author's ephemeral key once per message, never for our own.
  Future<void> sendGroupReadReceipt(
      dynamic messageId, String authorPubkey, String groupId) async {
    if (!_indicatorScopeAllows(
        _ref.read(settingsProvider).readReceiptsScope, 'group')) {
      return;
    }
    final wanted = messageId is List<String>
        ? messageId
        : (messageId is String && messageId.isNotEmpty
            ? [messageId]
            : const <String>[]);
    if (wanted.isEmpty || authorPubkey.isEmpty) return;
    final identity = _identity;
    final service = _service;
    if (identity == null || service == null) return;
    if (authorPubkey == identity.pubkey) return;
    final ids = [
      for (final id in wanted)
        if (_sentGroupReadReceipts.add(id)) id
    ];
    if (ids.isEmpty) return;
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
      messageIds: ids,
      receiptType: 'read',
      recipientPubkey: authorPubkey,
      encryptToPubkey: ek?.encryptionPubkeyFor(authorPubkey, identity.pubkey),
    );
  }

  /// Catch-up read receipts for loaded non-own messages in the open group.
  void markVisibleGroupMessagesRead(String groupId) {
    if (groupId.isEmpty) return;
    if (!_indicatorScopeAllows(
        _ref.read(settingsProvider).readReceiptsScope, 'group')) {
      return;
    }
    final messages = _ref
        .read(appStateProvider)
        .messages[GroupLogic.groupStorageKey(groupId)];
    if (messages == null || messages.isEmpty) return;
    final byAuthor = <String, List<String>>{};
    for (final m in messages) {
      if (m.isOwn || m.isHistorical) continue;
      final id = m.nymMessageId;
      if (id == null || id.isEmpty) continue;
      (byAuthor[m.pubkey] ??= <String>[]).add(id);
    }
    byAuthor.forEach((author, ids) {
      unawaited(sendGroupReadReceipt(ids, author, groupId));
    });
  }

  /// Routes an inbound channel typing indicator, skipping own, disallowed, stale (>5s) and blocked signals.
  void _onChannelTypingEvent(NostrEvent event, AppStateNotifier appState) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (event.pubkey == self) return;
    // Channel typing only shows with the 'everywhere' scope.
    final scope = _ref.read(settingsProvider).typingIndicatorsScope;
    if (!_indicatorScopeAllows(scope, 'channel')) return;
    // Drop signals older than 5s, matching the TTL.
    final ageMs =
        DateTime.now().millisecondsSinceEpoch - event.createdAt * 1000;
    if (ageMs > 5000) return;
    if (_ref.read(appStateProvider).blockedUsers.contains(event.pubkey)) return;

    final status = event.tagValue('typing');
    final geohash = event.tagValue('g') ?? event.tagValue('d');
    if (status == null || geohash == null || !isValidChannelTag(geohash)) {
      return;
    }

    // `typing: false` clears the entry; the `n` tag names senders we've never seen.
    appState.setTyping(
      storageKey: '#${geohash.toLowerCase()}',
      pubkey: event.pubkey,
      typing: status == 'start',
      nym: event.tagValue('n'),
    );
  }

  /// Routes an inbound channel read receipt, skipping own and stale (>5 min) ones.
  void _onChannelReadReceipt(NostrEvent event) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (event.pubkey == self) return;
    final ageMs =
        DateTime.now().millisecondsSinceEpoch - event.createdAt * 1000;
    if (ageMs > 5 * 60 * 1000) return;

    final messageId = event.tagValue('e');
    final geohash = event.tagValue('g') ?? event.tagValue('d');
    if (messageId == null ||
        messageId.isEmpty ||
        geohash == null ||
        !isValidChannelTag(geohash)) {
      return;
    }

    final appState = _ref.read(appStateProvider);
    if (appState.blockedUsers.contains(event.pubkey)) return;

    // A read receipt attests the reader runs Nymchat.
    _observeNymchatPubkey(event.pubkey);

    // Reader name: the receipt's `n` tag, else the known nym, with the pubkey suffix.
    final rawNym = event.tagValue('n');
    final base = !isPlaceholderNym(rawNym)
        ? stripPubkeySuffix(rawNym!)
        : pickDisplayNym(appState.users[event.pubkey]?.nym, 'nym');
    final readerNym = '$base#${getPubkeySuffix(event.pubkey)}';

    _ref.read(appStateProvider.notifier).applyChannelReader(
          messageId: messageId,
          readerPubkey: event.pubkey,
          readerNym: readerNym,
        );
  }

  // Reactions (kind 7 public / gift-wrapped private).

  /// Toggles our [emoji] reaction optimistically, rate-limited to 3 per 30s; false when limited or unable to sign.
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

    final existing = state.reactions[messageId] ?? const [];
    final reacted = existing.any((r) => r.emoji == emoji && r.userReacted);
    final remove = reacted;

    appState.applyReaction(
      messageId: messageId,
      emoji: emoji,
      reactor: self,
      removed: remove,
      reactorNym: state.selfNym,
    );

    // Reactions in mesh conversations go out over BLE.
    final meshBridge = _ref.read(meshControllerProvider.notifier).bridge;
    if (meshBridge != null && meshBridge.shouldSendOverMesh(state.view)) {
      final wireId = (kind == '1059' || kind == '14')
          ? (appState.messageById(messageId)?.nymMessageId ?? messageId)
          : messageId;
      meshBridge.sendReaction(state.view, wireId, emoji, remove: remove);
      return true;
    }

    final service = _service;
    if (service == null || !service.canSign) return false;

    // Private reactions reference the shared `nymMessageId`; the local update stays keyed on the wrap id.
    if (kind == '1059' || kind == '14') {
      final shareId =
          appState.messageById(messageId)?.nymMessageId ?? messageId;
      return _sendPrivateReaction(shareId, emoji, target, remove);
    }

    // Resolve the channel context from the active view.
    String? geohash;
    String? channel;
    if (state.view.kind == ViewKind.channel) {
      final entry =
          state.channels.where((c) => c.key == state.view.id.toLowerCase());
      if (entry.isNotEmpty && entry.first.isGeohash) {
        geohash = entry.first.geohashKey;
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

  final Map<String, List<Map<String, String>>> _groupReactionQueue = {};
  final Map<String, Timer> _groupReactionTimers = {};

  void queueGroupReaction(
      String groupId, String messageId, String emoji, bool remove) {
    final q = _groupReactionQueue[groupId] ??= <Map<String, String>>[];
    q.removeWhere((e) => e['e'] == messageId && e['c'] == emoji);
    q.add({'e': messageId, 'c': emoji, 'a': remove ? 'remove' : 'add'});
    if (q.length > 64) q.removeAt(0);
    if (_groupReactionTimers.containsKey(groupId)) return;
    _groupReactionTimers[groupId] =
        Timer(const Duration(milliseconds: kGroupReactionBatchMs), () {
      _groupReactionTimers.remove(groupId);
      unawaited(flushGroupReactions(groupId));
    });
  }

  void flushPendingGroupReactions() {
    for (final groupId in _groupReactionQueue.keys.toList()) {
      _groupReactionTimers.remove(groupId)?.cancel();
      unawaited(flushGroupReactions(groupId));
    }
  }

  void flushPendingDeposits() {
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return;
    unawaited(sync.flushDeposits());
  }

  Future<bool> flushGroupReactions(String groupId) async {
    final q = _groupReactionQueue[groupId];
    if (q == null || q.isEmpty) return false;
    _groupReactionQueue[groupId] = <Map<String, String>>[];
    final service = _service;
    final identity = _identity;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (service == null || identity == null || group == null) return false;
    final ek = _groups!.keysFor(group.id);
    final primary = q.last;
    final rest = q.sublist(0, q.length - 1);
    final emojiNotifier = _ref.read(liveCustomEmojiProvider.notifier);
    final emojiTags = <List<String>>[
      for (final it in q) ...emojiNotifier.emojiTagsForContent(it['c']!)
    ];
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: EventKind.reaction,
      tags: [
        ['g', group.id],
        ['e', primary['e']!],
        ['k', '14'],
        if (primary['a'] == 'remove') ['action', 'remove'],
        ...emojiTags,
        if (rest.isNotEmpty) ['batch', jsonEncode(rest)],
      ],
      content: primary['c']!,
    );
    return service.publishGiftWrappedRumor(
      rumor: rumor,
      recipients: group.members,
      encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
      onWrap: _archiveSentWrap,
    );
  }

  Future<bool> _sendPrivateReaction(
      String messageId, String emoji, String target, bool remove) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return false;
    if (anonSuppressSendTo(target)) return true;
    final appState = _ref.read(appStateProvider.notifier);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // NIP-30 declarations for a custom `:shortcode:` reaction, add and remove alike.
    final emojiTags =
        _ref.read(liveCustomEmojiProvider.notifier).emojiTagsForContent(emoji);

    // Group reaction: gift-wrap to all members with ['g', groupId].
    final view = _ref.read(appStateProvider).view;
    if (view.kind == ViewKind.group) {
      final group = appState.groupById(view.id);
      if (group == null) return false;
      queueGroupReaction(group.id, messageId, emoji, remove);
      return true;
    }

    // 1:1 reaction: gift-wrap to self and peer with ['p', target], ['k', '1059'].
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
      // Archive our copy and deposit the peer's so PM reactions restore from D1 on both sides.
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

  // Polls (kind 30078), channel-only.

  /// Creates a poll in the current geohash channel; null when not in a channel or unable to sign.
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

  /// Casts our vote once; true if sent.
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

  // Profile save (kind 0).

  /// Publishes a kind-0; durable logins merge into the cached profile so unmanaged fields survive.
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
      // A null param leaves a field untouched; an empty string clears it.
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
      // Later saves merge against the latest state.
      _cachedKind0Profile = Map<String, dynamic>.of(profile);
    } else {
      // Ephemeral mode publishes only the passed fields.
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
    // Keep the kind-0 cache in step with what was published.
    _adoptSelfKind0(signed);

    if (name != null && name.isNotEmpty) {
      identity.nym = getNymFromPubkey(name, identity.pubkey);
      // Persist the chosen nick: `nym_custom_nick` enables the D1 mirror, the auto-ephemeral nick survives relaunch.
      final kv = _ref.read(keyValueStoreProvider);
      kv.setString(StorageKeys.customNick, name);
      if (identity.loginMethod == null) {
        kv.setString(StorageKeys.autoEphemeralNick, name);
      }
    }
    final appState = _ref.read(appStateProvider.notifier);
    appState.setIdentity(identity.pubkey, identity.nym);
    appState.ingestEvent(signed); // routes kind-0 → _ingestProfile
    // Refresh the instant-restore cache with the new name/avatar.
    _syncSelfNymFromProfile();

    // Mirror to D1; the recorded id makes the relay echo a no-op.
    _mirrorOwnProfileToD1(signed);
    return true;
  }

  /// Resolves [pubkeys] D1-first, then falls back to relays for any D1 lacked; best-effort.
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
              .where((ev) =>
                  ev.isNotEmpty &&
                  (ev['content']?.toString() ?? '').contains('"picture"'))
              .length;
          debugPrint('[avatar-pop] resolve req=${pubkeys.length} '
              'd1Found=${found.length} d1WithPicture=$withPics');
          return true;
        }());
        if (found.isNotEmpty) {
          final profiles = await verifiedRows(
              found.values.where((ev) => ev.isNotEmpty), _verifyArchived);
          // One emit for the whole D1 batch.
          appState.runBatched(() {
            for (final parsed in profiles) {
              try {
                appState.ingestEvent(parsed);
                // Cache the full self kind-0 here too, or the next save drops unmanaged fields.
                if (parsed.kind == EventKind.profile &&
                    parsed.pubkey == _identity?.pubkey) {
                  _adoptSelfKind0(parsed);
                }
              } catch (_) {}
            }
          });
          // Relay-fallback for anyone without a resolved avatar, not just D1 misses; re-read after the batched ingest.
          final users = _ref.read(appStateProvider).users;
          missing = pubkeys.where((pk) {
            final low = pk.toLowerCase();
            if (!found.containsKey(low)) return true; // D1 miss
            final u = users[low] ?? users[pk];
            final pic = u?.profile?.picture;
            // D1/cache had no avatar, or no display name.
            if (pic == null || pic.isEmpty) return true;
            return isPlaceholderNym(u?.nym);
          }).toList();
        }
      } catch (_) {
        // Fall through to relays.
      }
    }
    if (missing.isEmpty) return;
    service?.fetchProfiles(missing);
  }

  // Channel management; persists to KV list sets.

  /// Switches to [channel] (adding it if unknown), persists joined channels, and subscribes its typing feed.
  void switchChannel(String channel, {String geohash = ''}) {
    final appState = _ref.read(appStateProvider.notifier);
    appState.switchChannel(channel, geohash: geohash);
    _persistJoinedChannels();
    _subscribeActiveChannelTyping();
    // Connect the closest geo relays for a geohash channel.
    final gh = geohash.isNotEmpty ? geohash : channel;
    if (isChannelGeohash(gh)) {
      unawaited(_service?.connectGeoRelaysForGeohash(gh) ?? Future.value());
    }
  }

  ChannelEntry addChannel(String channel, {String geohash = ''}) {
    final entry = _ref
        .read(appStateProvider.notifier)
        .addChannel(channel, geohash: geohash);
    _persistJoinedChannels();
    return entry;
  }

  /// Opens a column without switching views: register, restore history, connect geo relays; typing only if focused.
  void subscribeChannelColumn(String channel, {String geohash = ''}) {
    addChannel(channel, geohash: geohash);
    final key = geohash.isNotEmpty ? geohash : channel;
    // D1 archive restore; throttled, idempotent, no-op pre-boot.
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

  /// Removes [key] (not `#nymchat`) and persists.
  bool removeChannel(String key) {
    final ok = _ref.read(appStateProvider.notifier).removeChannel(key);
    if (ok) _persistJoinedChannels();
    return ok;
  }

  bool togglePin(String key) {
    final nav = _ref.read(chatNavProvider);
    final pk = pinKey('channel', key);
    if (pk.isEmpty) return false;
    nav.togglePin(pk);
    return nav.isChatPinned(pk);
  }

  void applyPinnedChannels(List<String> channels, bool persist) {
    final appState = _ref.read(appStateProvider);
    final before = appState.pinnedChannels.toList().join('\n');
    _ref.read(appStateProvider.notifier).hydrateChannelState(
          pinned: channels.toSet(),
          replace: true,
        );
    if (before == channels.join('\n')) return;
    _persistSet(StorageKeys.pinnedChannels, channels.toSet());
    if (persist) syncSettings();
  }

  bool hideChannel(String key) {
    final ok = _ref.read(appStateProvider.notifier).hideChannel(key);
    _persistSet(
        StorageKeys.hiddenChannels, _ref.read(appStateProvider).hiddenChannels);
    return ok;
  }

  /// Un-hides [key] and persists; use this rather than [AppStateNotifier.unhideChannel] so it survives relaunch.
  void unhideChannel(String key) {
    _ref.read(appStateProvider.notifier).unhideChannel(key);
    _persistSet(
        StorageKeys.hiddenChannels, _ref.read(appStateProvider).hiddenChannels);
  }

  /// Blocks [key] (not `#nymchat`) and persists.
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
    _ref
        .read(keyValueStoreProvider)
        .setString(key, jsonEncode(values.toList()));
  }

  /// Applies a synced `channelLastRead` map with a monotonic max per key.
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

  /// Merges synced favorite GIFs: dedup by url, local first, capped at 100; entries must be `{url, title}`.
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

  /// Merges synced recent emojis: remote first, deduped, capped at 24.
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

  /// Reads a persisted JSON string-array set; empty if missing or malformed.
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

  void _wireAutoMute(AppStateNotifier appState) {
    appState.hydrateAutoMuted(_readAutoMuted());
    appState.onAutoMuted = (_, _) => _persistAutoMuted();
  }

  Map<String, int> _readAutoMuted() {
    final raw =
        _ref.read(keyValueStoreProvider).getString(StorageKeys.autoMuted);
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final out = <String, int>{};
        decoded.forEach((k, v) {
          if (k is String && v is num) out[k] = v.toInt();
        });
        return out;
      }
    } catch (_) {}
    return <String, int>{};
  }

  void _persistAutoMuted() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final live = <String, int>{};
    _ref.read(appStateProvider).autoMutedUsers.forEach((k, v) {
      if (v > now) live[k] = v;
    });
    _ref
        .read(keyValueStoreProvider)
        .setString(StorageKeys.autoMuted, jsonEncode(live));
  }

  /// Hydrates friends, blocked users and blocked keywords from KV at boot.
  void _hydrateSocialState(AppStateNotifier appState) {
    appState.hydrateSocialState(
      friends: _readSet(StorageKeys.friends),
      blockedUsers: _readSet(StorageKeys.blocked),
      blockedKeywords: _readSet(StorageKeys.blockedKeywords),
      // Restore channel preferences too, or they revert on relaunch.
      pinnedChannels: _readSet(StorageKeys.pinnedChannels),
      hiddenChannels: _readSet(StorageKeys.hiddenChannels),
      blockedChannels: _readSet(StorageKeys.blockedChannels),
    );
  }

  /// Persists closed PMs and close times so stale backlog can't re-open them after relaunch.
  void _persistClosedPMs() {
    final appState = _ref.read(appStateProvider.notifier);
    _persistSet(StorageKeys.closedPms, appState.closedPMs);
    _ref.read(keyValueStoreProvider).setString(
        StorageKeys.closedPmTimes, jsonEncode(appState.closedPmTimes));
  }

  /// Hydrates closed PMs and close times from KV at boot.
  void _hydrateClosedPMs(AppStateNotifier appState) {
    final closed = _readSet(StorageKeys.closedPms);
    final times = <String, int>{};
    final raw =
        _ref.read(keyValueStoreProvider).getString(StorageKeys.closedPmTimes);
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

  /// Merges KV left groups and leave times into the live store (boot and post-sync).
  void _hydrateLeftGroups(AppStateNotifier appState) {
    final ids = _decodeIdSet(_leftGroupCache[StorageKeys.leftGroups]);
    final times = _decodeTimes(_leftGroupCache[StorageKeys.leftGroupTimes]);
    if (ids.isNotEmpty || times.isNotEmpty) {
      appState.mergeLeftGroups(ids, times);
    }
  }

  final Map<String, String> _leftGroupCache = <String, String>{};
  bool _leftGroupsLoaded = false;
  bool _leftGroupsLocked = false;
  bool _leftGroupsRetrying = false;

  static Set<String> _decodeIdSet(String? raw) {
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toSet();
    } catch (_) {}
    return <String>{};
  }

  static Map<String, int> _decodeTimes(String? raw) {
    final times = <String, int>{};
    if (raw == null || raw.isEmpty) return times;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          final t = v is num ? v.toInt() : int.tryParse('$v');
          if (t != null) times['$k'] = t;
        });
      }
    } catch (_) {}
    return times;
  }

  Future<bool> _readLeftGroupStore() async {
    final store = _groupStoreFor(_ref.read(keyValueStoreProvider));
    final ids = await store.readDetailed(StorageKeys.leftGroups);
    final times = await store.readDetailed(StorageKeys.leftGroupTimes);
    if (ids.locked || times.locked) return false;
    _leftGroupCache.remove(StorageKeys.leftGroups);
    _leftGroupCache.remove(StorageKeys.leftGroupTimes);
    final idsValue = ids.value;
    final timesValue = times.value;
    if (idsValue != null && idsValue.isNotEmpty) {
      _leftGroupCache[StorageKeys.leftGroups] = idsValue;
    }
    if (timesValue != null && timesValue.isNotEmpty) {
      _leftGroupCache[StorageKeys.leftGroupTimes] = timesValue;
    }
    return true;
  }

  Future<void> _loadLeftGroupStore() async {
    _leftGroupCache.clear();
    try {
      _leftGroupsLocked = !await _readLeftGroupStore();
    } catch (_) {
      _leftGroupsLocked = true;
    }
    _leftGroupsLoaded = true;
  }

  Future<void> _retryLockedLeftGroups() async {
    if (_leftGroupsRetrying || !_leftGroupsLocked) return;
    _leftGroupsRetrying = true;
    try {
      final live = Map<String, String>.of(_leftGroupCache);
      if (!await _readLeftGroupStore()) return;
      final appState = _ref.read(appStateProvider.notifier);
      _hydrateLeftGroups(appState);
      final liveIds = _decodeIdSet(live[StorageKeys.leftGroups]);
      final liveTimes = _decodeTimes(live[StorageKeys.leftGroupTimes]);
      if (liveIds.isNotEmpty || liveTimes.isNotEmpty) {
        appState.mergeLeftGroups(liveIds, liveTimes);
      }
      _leftGroupsLocked = false;
      _persistLeftGroups();
    } catch (_) {
    } finally {
      _leftGroupsRetrying = false;
    }
  }

  void _writeLeftGroupValue(String key, String value) {
    _leftGroupCache[key] = value;
    if (!_leftGroupsLoaded) return;
    if (_leftGroupsLocked) {
      unawaited(_retryLockedLeftGroups());
      return;
    }
    _groupStoreFor(_ref.read(keyValueStoreProvider)).write(key, value);
  }

  /// Persists left-group state, which feeds the outbound settings payload and the boot resurrection guard.
  void _persistLeftGroups() {
    final appState = _ref.read(appStateProvider.notifier);
    _writeLeftGroupValue(
        StorageKeys.leftGroups, jsonEncode(appState.leftGroups.toList()));
    _writeLeftGroupValue(
        StorageKeys.leftGroupTimes, jsonEncode(appState.leftGroupTimes));
  }

  /// Persists the group store (with device-local extras) and ephemeral keys so an offline launch still works.
  void _persistGroupStore() {
    final identity = _identity;
    if (identity == null || _retired) return;
    final kv = _ref.read(keyValueStoreProvider);
    try {
      final st = _ref.read(appStateProvider);
      final data = <String, dynamic>{};
      for (final g in st.groups) {
        data[g.id] = _serializeGroupForLocal(g, st);
      }
      _groupStoreFor(kv).write(
          StorageKeys.groupStoreFor(identity.pubkey), jsonEncode(data));
    } catch (_) {}
    try {
      final groups = _groups;
      if (groups != null) {
        // Ephemeral secret keys go in the platform keystore, not plaintext SharedPreferences.
        unawaited(SecureStore().set('nym_ephemeral_keys_${identity.pubkey}',
            jsonEncode(groups.ephemeralKeysForSync())));
        // Drop the legacy plaintext copy.
        if (kv.getString('nym_ephemeral_keys_${identity.pubkey}') != null) {
          kv.remove('nym_ephemeral_keys_${identity.pubkey}');
        }
      }
    } catch (_) {}
  }

  SealedKeyValue? _sealedGroupStore;

  SealedKeyValue _groupStoreFor(KeyValueStore kv) {
    final existing = _sealedGroupStore;
    if (existing != null && identical(existing.kv, kv)) return existing;
    return _sealedGroupStore =
        SealedKeyValue(kv, blocked: () => PanicWipe.inProgress);
  }

  /// Restores the group store and ephemeral keys at boot through the same additive apply as the D1 restore.
  Future<void> _hydrateGroupStore() async {
    final identity = _identity;
    if (identity == null) return;
    final kv = _ref.read(keyValueStoreProvider);
    final appState = _ref.read(appStateProvider.notifier);
    try {
      final raw = await _groupStoreFor(kv)
          .read(StorageKeys.groupStoreFor(identity.pubkey));
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
      if (groups == null) return;
      // Keystore first, then the legacy plaintext blob, which migrates on the next persist.
      String? raw;
      try {
        raw = await SecureStore().get('nym_ephemeral_keys_${identity.pubkey}');
      } catch (_) {}
      raw ??= kv.getString('nym_ephemeral_keys_${identity.pubkey}');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((gid, entry) {
            if (entry is Map) {
              try {
                groups.mergeEphemeralKeys(
                    '$gid', entry.cast<String, dynamic>());
              } catch (_) {
                // Skip a malformed key entry.
              }
            }
          });
          _applyEphemeralKeys();
        }
      }
    } catch (_) {}
  }

  /// After a group key rotation: persist, re-REQ the ephemeral sub, and schedule the cross-device key sync.
  void _afterSelfKeyRotation() {
    _persistGroupStore();
    _refreshEphemeralSubscriptions();
    syncSettings();
  }

  /// Persists the read watermark so a relaunch backfill isn't counted as unread.
  void _persistChannelLastRead() {
    _ref.read(keyValueStoreProvider).setString(
          StorageKeys.channelLastRead,
          jsonEncode(_ref.read(appStateProvider.notifier).channelLastRead),
        );
  }

  /// Debounced local persist of the group store; the cross-device publish is debounced separately.
  void _scheduleGroupStorePersist() {
    _groupStorePersistTimer?.cancel();
    _groupStorePersistTimer = Timer(const Duration(seconds: 2), () {
      _groupStorePersistTimer = null;
      _persistGroupStore();
      _persistLeftGroups();
    });
  }

  /// Debounced local persist of the read watermark.
  void _scheduleChannelLastReadPersist() {
    _channelLastReadPersistTimer?.cancel();
    _channelLastReadPersistTimer = Timer(const Duration(seconds: 2), () {
      _channelLastReadPersistTimer = null;
      _persistChannelLastRead();
    });
  }

  /// Flushes pending local writes so teardown never drops the latest group or read state.
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
    // Read-receipt messages that piled up while away.
    markVisibleChannelMessagesRead();
  }

  // Zaps (Nostr side only; the LNURL flow is the UI's job).

  /// Builds, signs and publishes a NIP-57 zap request for the LNURL callback; [originalKind] is null for profile zaps.
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

  /// Announces a paid message zap: gift-wrapped for PM/group, a signed public receipt for channels; deduped by bolt11.
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
      // Group rumor tags: g/e/k('14')/p/bolt11 → group members.
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
      // PM rumor tags: e/p/k('1059')/bolt11 → [self, peer].
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

    // Only geohash/named channel kinds are publishable; infer the kind from the view if absent.
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
      // Ignore our own receipt's echo; the self-record already counted it.
      _ownPublishedZapIds.add(signed.id);
      if (_ownPublishedZapIds.length > 500) {
        _ownPublishedZapIds.remove(_ownPublishedZapIds.first);
      }
      // Archive our published receipt so other clients' backfill sees it.
      _zapArchive?.archive(signed);
    }
  }

  /// Resolves [pubkey]'s lightning address, fetching the profile if needed and waiting up to [timeout]; null if none.
  Future<String?> resolveLightningAddressForZap(
    String pubkey, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    String? cached() =>
        _ref.read(appStateProvider).users[pubkey]?.profile?.lightningAddress;
    final existing = cached();
    if (existing != null && existing.isNotEmpty) return existing;

    // Trigger a D1-first profile fetch and poll the store for the address.
    unawaited(resolveProfiles([pubkey]));
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final addr = cached();
      if (addr != null && addr.isNotEmpty) return addr;
    }
    return cached();
  }

  // Persistence hydration / flush.

  Future<void> _hydrateFromCache(AppStateNotifier appState) async {
    try {
      final cache = CacheStore();
      await cache.open();
      _cache = cache;
      _eventTimeCeilings.onChanged = _schedulePersistEventTimeCeilings;
      EventMapper.ceilings = _eventTimeCeilings;
      // PMs hydrate only when caching is enabled; otherwise wipe the store.
      final cachePms = _ref.read(settingsProvider).cachePMs;
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
      // Hydrate cached history before the D1/relay backfills so the view paints instantly and replays dedup.
      if (channelMsgs.isNotEmpty || pmMsgs.isNotEmpty) {
        appState.hydrateAllMessages({...channelMsgs, ...pmMsgs});
      }
      // Seed the unwrap and verify skip-caches from restored plaintext so replays don't redo the crypto.
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
      // Channel history is a rolling 24-hour window, and a long-running session crosses it, so also sweep on a timer.
      _startChannelWindowPrune();

      final verifiedIds =
          await cache.loadMetaSet(CacheStore.metaVerifiedEventIds);
      if (verifiedIds.isNotEmpty) NostrService.seedVerifiedIds(verifiedIds);
      NostrService.onVerifiedIdsChanged = _schedulePersistVerifiedIds;
      if (!cachePms) unawaited(cache.clearPms());
      // Reactions hydrate after messages; rows whose target is gone (e.g. aged out) are deleted.
      if (reactions.isNotEmpty) {
        final held = <String>{};
        for (final list in [...channelMsgs.values, ...pmMsgs.values]) {
          for (final m in list) {
            if (m.id.isNotEmpty) held.add(m.id);
            final shared = m.nymMessageId;
            if (shared != null && shared.isNotEmpty) held.add(shared);
          }
        }
        final orphans =
            reactions.keys.where((id) => !held.contains(id)).toList();
        if (orphans.isNotEmpty) {
          reactions.removeWhere((id, _) => !held.contains(id));
          unawaited(cache.deleteReactionsFor(orphans).catchError((_) {}));
        }
        if (reactions.isNotEmpty) appState.hydrateReactions(reactions);
      }
      // Restore the web-of-trust sets so the spam gate isn't cold on launch.
      final trust = await Future.wait([
        cache.loadMetaSet(CacheStore.metaNymchatPubkeys),
        cache.loadMetaSet(CacheStore.metaNymchatVouches),
        cache.loadMetaSet(CacheStore.metaTrustedPubkeys),
        cache.loadMetaSet(CacheStore.metaDeletedEventIds),
      ]);
      appState.hydrateTrustSets(trust[0], trust[1], trust[2]);
      // NIP-09 deleted ids survive relaunch so replays can't resurrect deleted messages.
      appState.hydrateDeletedIds(trust[3]);
      appState.onDeletedIdsChanged = _schedulePersistDeletedIds;
      // Restore peers' ML-KEM keys so the first message after relaunch is PQ; bounded by announcement expiry.
      final pqKeys = await cache.loadMetaMap(CacheStore.metaPqKeys);
      if (pqKeys.isNotEmpty) {
        _pqRegistry.hydrate(pqKeys,
            nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000);
      }
      // Restore before the relay layer starts so the replay reuses last session's correction.
      final ceilings =
          await cache.loadMetaMap(CacheStore.metaEventTimeCeilings);
      if (ceilings.isNotEmpty) _eventTimeCeilings.hydrate(ceilings);
    } catch (e) {
      debugPrint('hydrateFromCache failed: $e');
    }
  }

  /// Debounced (5s) persist of the NIP-09 deleted-id set; best-effort.
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

  /// Marks [storageKey] dirty and schedules a debounced flush.
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
    // Never re-arm persistence during a panic wipe.
    if (PanicWipe.inProgress) return;
    if (_flushScheduled) return;
    _flushScheduled = true;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 6), () {
      _flushScheduled = false;
      unawaited(_flush());
    });
  }

  /// Profiles as of their last persist (by identity), so a flush writes only changed ones.
  final Map<String, UserProfile> _lastPersistedProfile = {};

  /// Encoded reaction rows as of their last persist, so unchanged ones are skipped.
  final Map<String, String> _lastPersistedReactionJson = {};

  Future<void> _flush() async {
    // A flush scheduled before the panic must not re-persist into the shredded cache.
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

      // Assemble here, encode in a worker isolate, then write, keeping serialization off the main thread.
      final channelPayload = <String, List<Message>>{};
      for (final key in channelKeys) {
        final msgs = state.messages[key];
        if (msgs == null) continue;
        // Never persist unreconciled `_optim_*` rows; they'd re-hydrate as stale placeholders.
        channelPayload[key] = _capChannel(msgs
            .where((m) => !m.optimistic && !m.id.startsWith('_optim_'))
            .toList());
      }
      final pmPayload = <String, List<Message>>{};
      if (cachePms) {
        for (final key in pmKeys) {
          final msgs = state.messages[key];
          if (msgs == null) continue;
          // Transient Nymbot info bubbles and unreconciled rows never persist.
          pmPayload[key] = _capPm(msgs
              .where((m) =>
                  !m.optimistic &&
                  !m.id.startsWith('_optim_') &&
                  !m.id.startsWith('nymbot-info-') &&
                  !m.id.startsWith('nymbot-help-') &&
                  m.id != 'nymbot-welcome')
              .toList());
        }
      }
      // Only profiles that changed since their last persist.
      final profilePayload = <String, UserProfile>{};
      for (final entry in state.users.entries) {
        final p = entry.value.profile;
        if (p == null) continue;
        if (identical(_lastPersistedProfile[entry.key], p)) continue;
        profilePayload[entry.key] = p;
      }

      final encoded = await compute(
          encodeCacheFlush,
          CacheFlushPayload(
            channels: channelPayload,
            pms: pmPayload,
            profiles: profilePayload,
            reactions: reactionEntries,
          ));

      final changedReactions = <String, String>{};
      encoded.reactions.forEach((id, json) {
        if (_lastPersistedReactionJson[id] != json) {
          changedReactions[id] = json;
        }
      });

      // One transaction per flush; dirty sets are cleared only after it succeeds.
      await cache.runInTransaction((txn) async {
        for (final e in encoded.channels.entries) {
          await cache.saveChannelMessagesJson(e.key, e.value, txn);
        }
        for (final e in encoded.pms.entries) {
          await cache.savePmMessagesJson(e.key, e.value, txn);
        }
        for (final e in encoded.profiles.entries) {
          await cache.saveProfileJson(
              e.key, e.value, encoded.profileKind0Ts[e.key] ?? 0, txn);
        }
        for (final e in changedReactions.entries) {
          await cache.saveReactionsJson(e.key, e.value, txn);
        }
      });
      _dirtyChannelKeys.clear();
      _dirtyPmKeys.clear();
      profilePayload.forEach((pk, p) => _lastPersistedProfile[pk] = p);
      changedReactions.forEach((id, j) => _lastPersistedReactionJson[id] = j);
      await cache.enforceLruLimits();
    } catch (e) {
      debugPrint('cache flush failed: $e');
    }
  }

  Timer? _channelWindowPruneTimer;

  /// Debounce for an out-of-band sweep so a backfill batch is swept once.
  Timer? _channelWindowPruneSoonTimer;

  void _scheduleChannelWindowPrune() {
    if (_channelWindowPruneSoonTimer != null) return;
    _channelWindowPruneSoonTimer = Timer(const Duration(milliseconds: 600), () {
      _channelWindowPruneSoonTimer = null;
      _runChannelWindowPrune();
    });
  }

  Future<void> _runChannelWindowPrune() async {
    if (PanicWipe.inProgress) return;
    final notifier = _ref.read(appStateProvider.notifier);
    Set<String> dropped;
    try {
      dropped = notifier.pruneChannelHistoryWindow();
    } catch (e) {
      debugPrint('channel window prune failed: $e');
      return;
    }
    if (dropped.isEmpty) return;
    try {
      await _cache?.deleteReactionsFor(dropped);
    } catch (e) {
      debugPrint('channel window reaction prune failed: $e');
    }
    // Rewrite the pruned conversations on disk too.
    for (final key in _ref.read(appStateProvider).messages.keys) {
      if (key.startsWith('pm-') || key.startsWith('group-')) continue;
      _dirtyChannelKeys.add(key);
    }
    _scheduleFlush();
  }

  void _startChannelWindowPrune() {
    _channelWindowPruneTimer?.cancel();
    _ref.read(appStateProvider.notifier).onAgedChannelMessage =
        _scheduleChannelWindowPrune;
    Future<void> run() async {
      await _runChannelWindowPrune();
    }

    run();
    _channelWindowPruneTimer =
        Timer.periodic(const Duration(minutes: 15), (_) => run());
  }

  // Cross-device storage sync (`/api/storage`); every call is lazy and failure-tolerant.

  /// Builds [StorageSync] and wires NIP-98 auth; only durable identities use the PM archive.
  void _initStorageSync(Identity identity, EventSigner? signer) {
    // Defer outbound saves until this identity's boot restore settles, so defaults can't clobber D1.
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
    // NIP-98 auth via the active signer (local or NIP-46); non-sensitive auth is cached 90s.
    sync.setAuthBuilder((action) => Nip98Auth.buildSigned(
          action: action,
          url: StorageSync.storageUrl(),
          signer: signer,
        ));
    sync.setWriteAuthBuilder((action, payload) => Nip98Auth.buildWrite(
          action: action,
          url: StorageSync.storageUrl(),
          signer: signer,
          payload: payload,
        ));
    // Pulled rather than handed over so the root reaches the launch's first settings read.
    sync.setPqRootProvider(_loadPqRoot);
    sync.setPqEpochProvider(() => _pqEpoch);

    // WS-first storage transport with HTTP fallback on any socket failure; unauthenticated if signing fails.
    api.setApiSocketAuthBuilder(() => Nip98Auth.buildSigned(
          action: 'api-ws',
          url: _apiWsAuthUrl(),
          signer: signer,
          sensitive: true,
        ));
    api.activateApiSocket();
    // The bot ledger shares the same authed `/api` socket.
    _ref.read(nymbotServiceProvider).setApiSocketRequest(api.botSocketRequest);
    sync.setDepositStore(
      save: (state) async {
        final cache = _cache;
        if (cache == null || !cache.isOpen) return;
        await cache.saveMetaMap(kPmDepositStoreKey, state);
      },
      load: () async {
        final cache = _cache;
        if (cache == null || !cache.isOpen) return <String, dynamic>{};
        return cache.loadMetaMap(kPmDepositStoreKey);
      },
    );
    _storageSync = sync;
    // Every synced category is written to D1 and also pushed live to our other devices as a gift wrap.
    sync.setSyncWrapPublisher((payload, dTag) async {
      await _service?.publishNymSyncWrap(payload: payload, dTag: dTag);
    });
    _zapArchive?.dispose();
    _zapArchive = ZapArchive(sync, verify: _verifyArchived);

    // Republish the read-state wrap when the seen map grows; uses the debounced sync.
    _ref.read(notificationHistoryProvider.notifier).onSeenChanged =
        syncSettings;

    // The other-users shop fetcher must never query our own pubkey.
    _ref.read(otherUsersShopProvider.notifier).selfPubkey =
        identity.pubkey.toLowerCase();

    // Broadcast `shop-update` presence after our shop items change so peers re-fetch.
    final shop = _ref.read(shopControllerProvider.notifier);
    shop.onActiveItemsPublished =
        () => unawaited(publishPresence('online', shopUpdate: true));

    // Publish the server's pre-signed gift DM so the recipient learns immediately.
    shop.giftEventPublisher = (giftEvent) {
      try {
        final ev = NostrEvent.fromJson(giftEvent);
        _service?.publishDmQueued(ev);
      } catch (_) {
        // Malformed gift event — dropped.
      }
    };

    // Surface shop reconciliation results as system lines.
    shop.onSystemMessage = _emitSystemMessage;

    // Debounced encrypted-settings publish on every synced change.
    _rememberSyncedBaseline();
    _ref.read(settingsProvider.notifier).onSyncedChange = syncSettings;

    // Backfill D1 history on open; best-effort, idempotent.
    _ref.read(appStateProvider.notifier).onViewOpened = _onViewOpened;

    // Persist inbound and engine-injected PM/group messages on insert, including the Nymbot thread.
    _ref.read(appStateProvider.notifier).onPmMessageIngested = _markDirty;

    _startChatTools();
    _startGroupTools();
    _startChatNav();

    // Persist closed PMs so deletions survive relaunch.
    _ref.read(appStateProvider.notifier).onClosedPmsChanged = _persistClosedPMs;
    // Persist the watermark and schedule the read-state sync so reads clear badges on other devices.
    _ref.read(appStateProvider.notifier).onChannelReadChanged = () {
      _scheduleChannelLastReadPersist();
      syncSettings();
    };
    // Reading a conversation marks its bell entries viewed; routes use the bare id, so strip the prefix.
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

    // Persist and sync the group store on every mutation; unchanged groups dedup by content hash.
    _ref.read(appStateProvider.notifier).onGroupStoreChanged = () {
      _scheduleGroupStorePersist();
      syncSettings();
    };
  }

  /// NIP-98 `u` URL for the `/api` socket's `api-ws` auth: `https://<host>/api/WS`.
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

  /// Fetches the opened conversation's D1 archive (channels and groups; PMs restore at boot); best-effort.
  void _onViewOpened(ChatView view) {
    rememberLastView(_ref.read(keyValueStoreProvider), view);
    // Reading a conversation clears its bell entries without opening the modal.
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _ref
        .read(notificationHistoryProvider.notifier)
        .markConversationSeen(view.id, tsSec: nowSec);
    // Also dismiss its OS notifications.
    unawaited(_clearOsNotificationsFor(view));
    // The geo-relay keep-alive runs only while a geohash channel is the active view.
    if (view.kind == ViewKind.channel && isChannelGeohash(view.id)) {
      _service?.startGeoRelayKeepAlive(view.id);
    } else {
      _service?.stopGeoRelayKeepAlive();
    }
    switch (view.kind) {
      case ViewKind.channel:
        unawaited(_backfillChannelArchive(view.id));
        // Catch up read receipts for loaded messages; new ones are receipted on ingest.
        markVisibleChannelMessagesRead();
      case ViewKind.group:
        unawaited(_backfillGroupArchive());
        // Catch up group read receipts so senders see our avatar.
        markVisibleGroupMessagesRead(view.id);
        // PM-scope zap badges for the loaded group backlog.
        _backfillZapReceiptsFor(view.storageKey, scope: 'pm');
      case ViewKind.pm:
        // Read-receipt the peer's loaded messages; scope-gated and deduped.
        markVisiblePmMessagesRead(view.id);
        // PM-scope zap badges for the loaded conversation.
        _backfillZapReceiptsFor(view.storageKey, scope: 'pm');
    }
  }

  /// Dismisses OS notifications for an opened conversation, keyed `<historyType>:<route>`.
  Future<void> _clearOsNotificationsFor(ChatView view) async {
    final service = NotificationService();
    Future<void> clear(String type) => service.cancelConversation(
          notificationConversationKey(historyType: type, route: view.id),
        );
    switch (view.kind) {
      case ViewKind.channel:
        await clear('channel');
      case ViewKind.group:
        await clear('group');
      case ViewKind.pm:
        for (final type in const ['pm', 'reaction', 'mention']) {
          await clear(type);
        }
    }
  }

  /// Backfills zap receipts for loaded messages; [scope] is 'pm' or 'channel'; PMs also query the nymMessageId.
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

  /// On foreground: top up the open view from D1, re-check shop purchases, and clear the focused column's unread.
  void onAppResumed() {
    _service?.probePool();
    _appInForeground = true;
    _onViewOpened(_ref.read(appStateProvider).view);
    // Re-pull the full D1 backlog on every resume, even if the socket never dropped; throttled and idempotent.
    if (_liveGap.pending) {
      unawaited(_catchUpLiveGap());
    } else {
      unawaited(_backfillFromD1OnReconnect());
    }
    _ref.read(appStateProvider.notifier).markVisibleColumnsRead();
    unawaited(_reconcileShopPurchases());
    unawaited(_reconcilePendingZaps());
  }

  /// Pauses the geo-relay keep-alive unless [keepConnectionsAlive], and flushes a pending settings publish.
  void onAppPaused({bool keepConnectionsAlive = false}) {
    _appInForeground = false;
    _liveGap.note();
    if (!keepConnectionsAlive) {
      _service?.stopGeoRelayKeepAlive();
    }
    // Only when queued, since this also runs on transient `inactive` states.
    if (_settingsSyncTimer != null) flushSettingsSyncNow();
  }

  /// During a background catch-up, the timestamp a message must beat to notify; null otherwise.
  int? _catchUpAlertCutoffMs;

  static Future<T?> awaitBootValue<T>(
    T? Function() read, {
    required bool Function() booting,
    required Duration limit,
    Duration poll = const Duration(milliseconds: 100),
  }) async {
    var value = read();
    final polls = limit.inMilliseconds ~/ poll.inMilliseconds;
    for (var i = 0; value == null && booting() && i < polls; i++) {
      await Future<void>.delayed(poll);
      value = read();
    }
    return value;
  }

  Future<bool> runBackgroundCatchUp({
    Duration budget = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(budget);
    if (!hasChosenIdentity(_ref.read(keyValueStoreProvider))) return false;
    final sync = await awaitBootValue<StorageSync>(
      () => _storageSync,
      booting: () => _started,
      limit: budget * 0.6,
    );
    // Not booted: nothing to pull; the next window retries.
    if (sync == null) return false;
    if (!_ref.read(settingsProvider).notificationsEnabled) return false;

    final kv = _ref.read(keyValueStoreProvider);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final storedSec =
        kv.getInt(StorageKeys.backgroundCatchUpTs, defaultValue: 0);
    _catchUpAlertCutoffMs = catchUpCutoffMs(
      storedWatermarkMs: storedSec > 0 ? storedSec * 1000 : 0,
      nowMs: nowMs,
    );
    // A catch-up is by definition off screen; a cold background launch hasn't set this yet.
    _appInForeground = false;

    /// Runs a stage only if [needs] remains; [cap] bounds its share so a slow stage can't starve later ones.
    Future<void> stage(
      Future<void> Function() work, {
      required Duration needs,
      Duration? cap,
    }) async {
      final left = deadline.difference(DateTime.now());
      if (left < needs) return;
      final slice = (cap != null && cap < left) ? cap : left;
      try {
        await work().timeout(slice);
      } catch (_) {
        // Out of budget or failed; what landed is already ingested; the rest waits.
      }
    }

    try {
      await stage(
        () => Future.wait([
          _restorePmArchive(sync),
          _backfillGroupArchive(),
        ]),
        needs: const Duration(seconds: 2),
        cap: budget * 0.6,
      );
      await stage(
        _catchUpChannelMentions,
        needs: const Duration(seconds: 4),
        cap: budget * 0.3,
      );
      await stage(
        _catchUpProfileZaps,
        needs: const Duration(seconds: 2),
      );
    } finally {
      _catchUpAlertCutoffMs = null;
      // Stamp the run's start so mid-run events are covered next time; replay guards prevent re-alerts.
      await kv.setInt(StorageKeys.backgroundCatchUpTs, nowMs ~/ 1000);
    }
    return true;
  }

  /// Restores joined channels and routes each restored event to [_maybeNotifyChannel] via [onRestored].
  Future<void> _catchUpChannelMentions() async {
    final joined = <String>{
      for (final c in _ref.read(appStateProvider).channels)
        if (c.key.isNotEmpty) c.key,
    };
    if (joined.isEmpty) return;
    await _backfillChannelArchivesFor(
      joined,
      // Forced, or the 60s freshness window could skip the fetch entirely.
      force: true,
      onRestored: (ev) {
        if (ev.kind != EventKind.geoChannel &&
            ev.kind != EventKind.namedChannel) {
          return;
        }
        _maybeNotifyChannel(ev);
      },
    );
  }

  /// Profile zap receipts, cheapest and least urgent, so last.
  Future<void> _catchUpProfileZaps() async {
    final selfPk = _identity?.pubkey;
    final zapArchive = _zapArchive;
    if (selfPk == null || zapArchive == null) return;
    final appState = _ref.read(appStateProvider.notifier);
    await zapArchive.backfill(
      [selfPk],
      'profile',
      (receipt) => _onPublicZapReceipt(receipt, appState),
    );
  }

  /// In-flight backfill per channel, so concurrent triggers share it; empty results let a waiter re-run.
  final Map<String, Future<bool>> _channelBackfillInFlight =
      <String, Future<bool>>{};

  // D1 profile backfill.

  /// Pubkeys queued for a batched `profile-get`, deduped per flush window.
  final List<String> _profileBackfillQueue = <String>[];
  final Set<String> _profileBackfillQueued = <String>{};
  Timer? _profileBackfillTimer;

  /// Resolves D1 profiles for a list of pubkeys so each row shows its avatar.
  void ensureProfiles(Iterable<String> pubkeys) {
    for (final pk in pubkeys) {
      _maybeBackfillProfiles(pk);
    }
  }

  /// Queues [pubkey] for a debounced (~400ms) batched D1 profile fetch; no-op when unneeded.
  void _maybeBackfillProfiles(String? pubkey) {
    if (pubkey == null || pubkey.length != 64) return;
    if (_storageSync == null) return;
    final self = _service?.selfPubkey ?? _identity?.pubkey;
    if (pubkey == self) return;
    // Key on the avatar, not profile existence, so picture-less stubs don't block backfill.
    final known = _ref.read(appStateProvider).users[pubkey];
    final pic = known?.profile?.picture;
    if (pic != null && pic.isNotEmpty && !isPlaceholderNym(known?.nym)) return;
    // Re-attempt avatar-less users at most every 5 minutes.
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _profileBackfillAttemptedAt[pubkey];
    if (last != null && now - last < 5 * 60 * 1000) return;
    _profileBackfillAttemptedAt[pubkey] = now;
    if (_profileBackfillAttemptedAt.length > 5000) {
      _profileBackfillAttemptedAt
          .remove(_profileBackfillAttemptedAt.keys.first);
    }
    if (!_profileBackfillQueued.add(pubkey)) return;
    _profileBackfillQueue.add(pubkey);
    _profileBackfillTimer ??= Timer(
      const Duration(milliseconds: 400),
      _flushProfileBackfill,
    );
  }

  /// Per-pubkey last backfill attempt (ms).
  final Map<String, int> _profileBackfillAttemptedAt = {};

  /// Drains the queue through [resolveProfiles]; best-effort.
  void _flushProfileBackfill() {
    _profileBackfillTimer = null;
    if (_profileBackfillQueue.isEmpty) return;
    final batch = List<String>.from(_profileBackfillQueue);
    _profileBackfillQueue.clear();
    _profileBackfillQueued.clear();
    unawaited(resolveProfiles(batch));
  }

  /// Replays a channel's D1 archive through live ingest; [force] skips the 60s window; [onRestored] sees each event.
  Future<void> _backfillChannelArchive(String channelKey,
      {bool force = true,
      int sinceSec = 0,
      void Function(NostrEvent event)? onRestored}) async {
    final sync = _storageSync;
    if (sync == null || channelKey.isEmpty) return;
    final name = channelKey.toLowerCase();
    final inFlight = _channelBackfillInFlight[name];
    if (inFlight != null) {
      // Await the running fetch; on empty/failed results re-run unless another waiter already did.
      final produced = await inFlight;
      if (produced || _channelBackfillInFlight.containsKey(name)) return;
    }
    final run = _runChannelBackfill(name, channelKey, sync,
        force: force, sinceSec: sinceSec, onRestored: onRestored);
    _channelBackfillInFlight[name] = run;
    try {
      await run;
    } finally {
      // Clear only our own entry; a re-running waiter may have replaced it.
      if (identical(_channelBackfillInFlight[name], run)) {
        _channelBackfillInFlight.remove(name);
      }
    }
  }

  /// One `channel-get` attempt; returns whether it produced events; never throws.
  Future<bool> _runChannelBackfill(
      String name, String channelKey, StorageSync sync,
      {required bool force,
      int sinceSec = 0,
      void Function(NostrEvent event)? onRestored}) async {
    try {
      // Time-bound the fetch (10s → empty) so an orphaned request can't pin the slot; empty tells waiters to retry.
      final events = await sync
          .channelGet([name], force: force, sinceSec: sinceSec)
          .timeout(
        const Duration(seconds: 10),
        onTimeout: () => const <Map<String, dynamic>>[],
      );
      final selfPk = _identity?.pubkey;
      final restored = (await verifiedRows(events, _verifyArchived))
          .where((ev) => !archivedSpam(ev, selfPk,
              enabled: appSpamFilterEnabled,
              aggressive: appSpamFilterAggressive))
          .toList();
      final appState = _ref.read(appStateProvider.notifier);
      // One emit for the whole archive page.
      appState.runBatched(() {
        for (final ev in restored) {
          try {
            eventProvenance.recordLocal(ev, 'NYMCHAT ARCHIVE');
            // Historical by provenance.
            appState.ingestEvent(ev, historical: true);
            // Observe trust like the live path, or the spam gate hides restored history.
            if (ev.kind == EventKind.geoChannel ||
                ev.kind == EventKind.namedChannel) {
              _observeMessageTrust(ev);
              // Backfill restored authors' profiles, or historical avatars stay identicons; batched.
              _maybeBackfillProfiles(ev.pubkey);
            }
            if (onRestored != null) {
              try {
                onRestored(ev);
              } catch (_) {
                // A hook failure must not abort the archive replay.
              }
            }
          } catch (_) {
            // Skip a malformed archived event.
          }
        }
      });
      // Zap badges for restored history, including older cached messages.
      _backfillZapReceiptsFor('#$channelKey', scope: 'channel');
      return events.isNotEmpty;
    } catch (_) {
      // Best-effort: live subscription continues regardless.
      return false;
    }
  }

  /// Restores other members' group messages from the ephemeral-key D1 inbox; one pass at a time, idempotent.
  Future<void> _backfillGroupArchive() async {
    final sync = _storageSync;
    final groups = _groups;
    final service = _service;
    if (sync == null || groups == null || service == null) return;
    if (_groupBackfillInFlight) return;
    _groupBackfillInFlight = true;
    try {
      final ephPks = [...groups.allEphemeralPubkeys(), ..._anonBotPubkeys()];
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

  /// Completes once the boot settings restore settles, so onboarding sees synced flags before deciding.
  Future<void> get settingsHydrated => _settingsHydratedC.future;

  /// Starts completed so tests never block; [init] re-arms it synchronously before any await.
  Completer<void> _settingsHydratedC = Completer<void>()..complete();
  Timer? _settingsHydratedFallback;

  /// Merges cross-device settings, then restores the PM backlog for durable identities; best-effort.
  Future<void> _bootStorageSync() async {
    final sync = _storageSync;
    if (sync == null) {
      // No durable login means no remote settings; onboarding may proceed.
      _markSettingsHydrated();
      return;
    }
    // 10s fallback releases only the onboarding gate, never the save gate, so defaults can't clobber D1.
    _settingsHydratedFallback ??=
        Timer(const Duration(seconds: 10), _releaseOnboardingGate);
    // `_mergeRemoteSettings` marks hydration in its own `finally`.
    await _mergeRemoteSettingsWithRetry(sync);
    // Needs a settled settings read to tell "no record" from "could not look".
    await _ensurePqRoot();
    await _restorePmArchive(sync);
    unawaited(sync.restoreDeposits());
    // Profile zap receipts are keyed on the recipient pubkey.
    final selfPk = _identity?.pubkey;
    if (selfPk != null && _zapArchive != null) {
      final appState = _ref.read(appStateProvider.notifier);
      unawaited(_zapArchive!.backfill(
        [selfPk],
        'profile',
        (receipt) => _onPublicZapReceipt(receipt, appState),
      ));
    }
    // Restore D1-archived emoji packs that are no longer on relays.
    unawaited(_restoreEmojiFromD1(sync));
    // Load our own shop record so cosmetics apply on a fresh device; any signable identity qualifies.
    final id = _identity;
    final signer = _signer;
    if (id != null && (signer != null || id.privkey != null)) {
      unawaited(_ref.read(shopControllerProvider.notifier).loadFromServer(
          ShopIdentity(
              pubkey: id.pubkey, privkey: id.privkey, signer: signer)));
      // Finalize shop purchases that settled while closed.
      unawaited(_reconcileShopPurchases());
      unawaited(_reconcilePendingZaps());
    }
  }

  // Shop NIP-57 receipt fallback.

  Subscription? _shopReceiptSub;
  Timer? _shopReceiptTimer;
  Completer<Object>? _shopReceiptCompleter;

  /// Waits for a zap receipt matching [bolt11] for shop buys without a verify URL; the receipt JSON, or false after 180s.
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
    // 180s timeout
    _shopReceiptTimer = Timer(const Duration(seconds: 180), () {
      if (_shopReceiptCompleter == completer && !completer.isCompleted) {
        clearShopReceiptWait(result: false);
      }
    });
    return completer.future;
  }

  /// Cancels the receipt wait; [result] resolves any in-flight [listenForShopReceipt].
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

  /// Re-verifies persisted pending zap invoices that may have settled while the process was evicted.
  Future<void> _reconcilePendingZaps() async {
    final identity = _identity;
    if (identity == null) return;
    List<Map<String, dynamic>> entries;
    try {
      entries = _ref
          .read(shopControllerProvider.notifier)
          .pendingPurchasesOfKind('zap');
    } catch (_) {
      return;
    }
    if (entries.isEmpty) return;
    final api = ApiClient();
    try {
      for (final entry in entries) {
        final pr = entry['pr']?.toString() ?? '';
        final messageId = entry['messageId']?.toString() ?? '';
        final invoiceId = entry['invoiceId']?.toString() ?? '';
        if (pr.isEmpty || messageId.isEmpty || invoiceId.isEmpty) continue;
        bool paid;
        try {
          paid = await api.zapVerify(
            pr: pr,
            verifyUrl: entry['verify']?.toString(),
            providerPubkey: entry['providerPubkey']?.toString(),
          );
        } catch (_) {
          continue; // Leave it for the next foreground.
        }
        if (!paid) continue;
        try {
          _ref
              .read(shopControllerProvider.notifier)
              .removePendingPurchase(invoiceId);
        } catch (_) {}
        final amount = (entry['amount'] as num?)?.toInt() ?? 0;
        if (amount <= 0) continue;
        final recipient = entry['recipientPubkey']?.toString() ?? '';
        _ref.read(appStateProvider.notifier).recordMessageZap(
              messageId: messageId,
              zapperPubkey: identity.pubkey,
              amountSats: amount,
              dedupKey: ZapLogic.dedupKey(bolt11: pr, eventId: ''),
            );
        if (recipient.isEmpty) continue;
        unawaited(announceMessageZap(
          messageId: messageId,
          recipientPubkey: recipient,
          bolt11: pr,
          originalKind: entry['originalKind']?.toString(),
        ));
      }
    } finally {
      api.dispose();
    }
  }

  Future<void> _reconcileShopPurchases() async {
    final id = _identity;
    final signer = _signer;
    if (id == null || (signer == null && id.privkey == null)) return;
    try {
      await _ref
          .read(shopControllerProvider.notifier)
          .reconcilePendingPurchases(
            ShopIdentity(
                pubkey: id.pubkey, privkey: id.privkey, signer: signer),
            gifterNym: id.nym,
          );
    } catch (_) {
      // Left for the next foreground.
    }
  }

  /// True when the last `settings-get` failed or hasn't run; reconnect retries it, as groups and keys depend on it.
  bool _settingsGetFailed = true;

  /// Retries for a failed boot `settings-get`, backing off 2s, 4s, 8s, 16s.
  static const int _settingsLoadMaxRetries = 4;

  /// Boot settings restore with bounded retries, since the save gate stays shut (dropping edits) until a load succeeds.
  Future<void> _mergeRemoteSettingsWithRetry(StorageSync sync) async {
    for (var attempt = 0; attempt <= _settingsLoadMaxRetries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(
            Duration(milliseconds: 2000 << (attempt - 1)));
        // A logout or identity switch replaced the sync client; don't restore the old account over it.
        if (_storageSync != sync) return;
      }
      await _mergeRemoteSettings(sync);
      if (!_settingsGetFailed) return;
    }
  }

  Future<void> _mergeRemoteSettings(StorageSync sync) async {
    try {
      final result = await sync.settingsGet();
      if (result == null) {
        // Load failed: keep the save gate shut so defaults can't overwrite unread D1 rows; release only onboarding.
        _settingsGetFailed = true;
        _releaseOnboardingGate();
        return;
      }
      _settingsGetFailed = false;
      // Every completed read re-asks §6; cheap once settled.
      unawaited(_ensurePqRoot());
      // Merge notification read-state before the settings ts gate.
      final notif = result.notificationsPayload;
      if (notif != null) {
        _applyNotificationsSync(notif);
      }
      // Merge read watermarks (monotonic max) before the gate so badges sync without a core change.
      final readState = result.readStatePayload;
      if (readState != null) {
        _applyChannelLastRead(readState['channelLastRead']);
      }
      // Apply per-group categories before the gate so a fresh device restores groups, keys and backlog.
      _applyGroupSync(result);
      final saved = result.savedMessages;
      if (saved != null) {
        try {
          _ref.read(chatToolsProvider).applyRemoteSaved(saved);
        } catch (_) {}
      }
      final pinnedChats = result.pinnedChats;
      if (pinnedChats != null) {
        try {
          _ref.read(chatNavProvider).applyRemotePinned(pinnedChats);
        } catch (_) {}
      }
      final lockedChats = result.lockedChats;
      if (lockedChats != null) {
        try {
          _ref.read(chatLockProvider).applyRemote(lockedChats);
        } catch (_) {}
      }
      // Core sections apply unconditionally to heal local drift.
      if (result.payload.isNotEmpty) {
        _applySyncedSettingsAdditive(result.payload);
        _applySyncedSettings(result.payload);
      }
      final kv = _ref.read(keyValueStoreProvider);
      final lastTs =
          int.tryParse(kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ??
              0;
      // Stored ts is seconds, newestTs is ms; only ever advance.
      final newestSec = result.newestTs ~/ 1000;
      if (newestSec > lastTs) {
        kv.setString(StorageKeys.lastSettingsSyncTs, '$newestSec');
      }
      // Load succeeded: only now open the outbound-save gate.
      _markSettingsHydrated();
    } catch (_) {
      // Best-effort; retried on reconnect with the save gate still closed.
      _settingsGetFailed = true;
      _releaseOnboardingGate();
    }
  }

  /// Applies per-group sync (conversations, ephemeral keys, history) from a settings-get; idempotent.
  void _applyGroupSync(SettingsLoadResult result) {
    _applyGroupSyncMaps(
      conversations: result.groupConversations,
      ephemeralKeys: result.groupEphemeralKeys,
      history: result.groupMessageHistory,
    );
    final anon = result.botAnon;
    if (anon != null) applyBotAnonSync(anon);
  }

  void applyBotAnonSync(Map<String, dynamic> payload) {
    try {
      _ref.read(botChatControllerProvider.notifier).anon.applySynced(payload);
    } catch (_) {}
  }

  /// Shared apply for the per-group maps, used by the boot merge and live sync wraps.
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

    // 2) Ephemeral keys → decryption; left groups are skipped so stale blobs can't resurrect deleted keys.
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
      _applyEphemeralKeys();
    }

    // 3) Group message history → message store.
    if (history != null && history.isNotEmpty) {
      try {
        appState.applyGroupHistorySync(history);
      } catch (_) {
        // Best-effort.
      }
    }

    // Persist restored groups and keys so a relaunch works offline.
    if (groupsChanged || keysAdded) _persistGroupStore();

    // New self keys: re-REQ the ephemeral sub and recover the backlog they unlock.
    if (keysAdded) {
      _refreshEphemeralSubscriptions();
      unawaited(_backfillGroupArchive());
    }
  }

  /// Live 1059 REQ over our ephemeral pubkeys, since the main filter only has `#p:[self]`; reopened on key changes.
  late final OwnEphemeralSubscription _ownEph = OwnEphemeralSubscription(
    subscribe: _openOwnEphemeralSub,
    pubkeys: _ownEphemeralPubkeys,
  );

  /// Re-registers the ephemeral key set and reopens its REQ; used by Ghost Mode after rotation.
  void refreshEphemeralSubscriptions() => _refreshEphemeralSubscriptions();

  bool anonSuppressSendTo(String pubkey) {
    if (pubkey.isEmpty || !isVerifiedBot(pubkey)) return false;
    try {
      return _ref.read(botChatControllerProvider.notifier).anon.enabled;
    } catch (_) {
      return false;
    }
  }

  bool _isAnonBotPubkey(Object? pubkey) =>
      pubkey is String &&
      pubkey.isNotEmpty &&
      _anonBotPubkeys().contains(pubkey);

  List<String> _anonBotPubkeys() {
    try {
      return _ref.read(botChatControllerProvider.notifier).anon.pubkeys;
    } catch (_) {
      return const <String>[];
    }
  }

  List<({Uint8List sk, Uint8List kemSk, Uint8List kemPk})> _anonBotKeys() {
    try {
      final anon = _ref.read(botChatControllerProvider.notifier).anon;
      final out = <({Uint8List sk, Uint8List kemSk, Uint8List kemPk})>[];
      final st = anon.state;
      if (st == null) return out;
      for (final id in [if (st.current != null) st.current!, ...st.prev]) {
        final kem = anon.kemFor(id);
        if (kem != null) {
          out.add((sk: id.sk, kemSk: kem.secretKey, kemPk: kem.publicKey));
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  void _applyEphemeralKeys() {
    final service = _service;
    final groups = _groups;
    if (service == null || groups == null) return;
    service.setEphemeralKeys([
      ...groups.allEphemeralSecretKeys(),
      ..._ref.read(ghostModeProvider).secretKeys,
    ]);
    service.setAnonBotKeys(_anonBotKeys());
    // Refreshed alongside the ephemeral keys so rotations and login changes apply on the same tick.
    service.setPqSelfKeys(pqCapable ? pqSelfCandidateKeys() : const []);

    // The D1 settings blob mirrors the relay wrap, so it takes the same keys.
    _storageSync?.setPqSelfKeys(pqCapable ? pqSelfCandidateKeys() : const []);
    // Keyed by the member's real pubkey, not the rotating ephemeral key.
    groups.kemKeyFor = (memberPubkey) {
      final key = _pqRegistry.keyFor(
        memberPubkey,
        nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        enabled: pqEnabled,
      );
      // Look up unknown members in the background; this message still goes classical to them and reports partial coverage.
      if (key == null) unawaited(ensurePqAnnouncement(memberPubkey));
      return key;
    };
    groups.rootSeededFor = pqPeerIsRootSeeded;
    // A signer login strips the layered format's outer layer itself with the root-derived key.
    _service?.selfKemForUnwrap = () {
      final k = _pqSelfKeys();
      return k == null ? null : (kemSk: k.secretKey, kemPk: k.publicKey);
    };
    groups.layeredFor = (memberPubkey) => _pqRegistry.acceptsLayered(
          memberPubkey,
          nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          enabled: pqEnabled,
        );
  }

  void _refreshEphemeralSubscriptions() {
    if (_service == null || _groups == null) return;
    _applyEphemeralKeys();
    _ownEph.refresh();
  }

  void _ensureOwnEphemeralSub() {
    if (_service == null || _groups == null) return;
    _applyEphemeralKeys();
    _ownEph.ensure();
  }

  List<String> _ownEphemeralPubkeys() => [
        ...?_groups?.allEphemeralPubkeys(),
        ..._ref.read(ghostModeProvider).pubkeys,
        ..._anonBotPubkeys(),
      ];

  Subscription _openOwnEphemeralSub(List<String> pks) {
    final service = _service!;
    final d1Mode = service.isProxyMode;
    final sub = service.subscribeEphemeral(
      pks,
      limit: d1Mode ? 1 : 200 * pks.length,
      since: d1Mode
          ? null
          : DateTime.now().millisecondsSinceEpoch ~/ 1000 - 604800,
    );
    sub.events.listen(service.unwrapLiveWrap, onError: (_) {});
    return sub;
  }

  /// The idempotent, additive half of the settings apply, shared by boot, live wraps and offer accepts.
  void _applySyncedSettingsAdditive(Map<String, dynamic> s) =>
      _quietSyncedApply(() => _applySyncedSettingsAdditiveNow(s));

  void _applySyncedSettingsAdditiveNow(Map<String, dynamic> s) {
    // Cross-device notification read state and bell history.
    _applyNotificationsSync(s);
    // Closed PMs: set union plus an independent per-key max time merge.
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
        // The outbound payload reads from KV, so persist or the next save republishes the pre-merge set.
        _persistClosedPMs();
      } catch (_) {}
    }
    // Left-group state: KV union plus live-store merge.
    _mergeLeftGroupsFromSync(s['leftGroups'], s['leftGroupTimes']);
    // Per-conversation read watermarks.
    _applyChannelLastRead(s['channelLastRead']);
    final saved = s['savedMessages'];
    if (saved is Map) {
      try {
        _ref.read(chatToolsProvider).applyRemoteSaved(saved);
      } catch (_) {}
    }
    final pinnedChats = s['pinnedChats'];
    if (pinnedChats is Map) {
      try {
        _ref.read(chatNavProvider).applyRemotePinned(pinnedChats);
      } catch (_) {}
    }
    final lockedChats = s['lockedChats'];
    if (lockedChats is Map) {
      try {
        _ref.read(chatLockProvider).applyRemote(lockedChats);
      } catch (_) {}
    }
    // Per-group categories.
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

  /// Applies inbound notification read state (seen keys, last-read time, history); idempotent, never republishes.
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
          // The answered status is the tombstone for a synced missed call.
          isCallAnswered: (callId) =>
              _ref.read(callServiceProvider).seenCallStatus(callId) ==
              'answered',
        );
      }
    } catch (_) {
      // History store may be unavailable in teardown.
    }
  }

  /// Merges synced left groups into KV and the live store: union ids, newest leave time, drop now-left groups.
  void _mergeLeftGroupsFromSync(dynamic leftGroups, dynamic rawLeftTimes) {
    final appState = _ref.read(appStateProvider.notifier);
    if (leftGroups is List) {
      try {
        final merged = _decodeIdSet(_leftGroupCache[StorageKeys.leftGroups])
          ..addAll(leftGroups.whereType<String>().where((s) => s.isNotEmpty));
        _writeLeftGroupValue(
            StorageKeys.leftGroups, jsonEncode(merged.toList()));
      } catch (_) {}
    }
    if (rawLeftTimes is Map) {
      try {
        final merged =
            _decodeTimes(_leftGroupCache[StorageKeys.leftGroupTimes]);
        rawLeftTimes.forEach((k, v) {
          final t = v is num ? v.toInt() : int.tryParse('$v');
          if (t == null || t <= 0) return;
          if (t > (merged['$k'] ?? 0)) merged['$k'] = t;
        });
        _writeLeftGroupValue(StorageKeys.leftGroupTimes, jsonEncode(merged));
      } catch (_) {}
    }
    // Apply to the live store too, reading back the KV just written.
    if (leftGroups is List || rawLeftTimes is Map) {
      _hydrateLeftGroups(appState);
    }
  }

  Set<String>? _dirtySyncedKeysCache;

  Map<String, String>? _syncedBaseline;

  bool _applyingSynced = false;

  Set<String> get _dirtySyncedKeys {
    final held = _dirtySyncedKeysCache;
    if (held != null) return held;
    final out = <String>{};
    try {
      final raw = _ref
          .read(keyValueStoreProvider)
          .getString(StorageKeys.settingsDirtyKeys);
      final list = raw == null ? null : jsonDecode(raw);
      if (list is List) out.addAll(list.whereType<String>());
    } catch (_) {}
    return _dirtySyncedKeysCache = out;
  }

  void _saveDirtySyncedKeys() {
    try {
      final kv = _ref.read(keyValueStoreProvider);
      final keys = _dirtySyncedKeys;
      if (keys.isEmpty) {
        kv.remove(StorageKeys.settingsDirtyKeys);
      } else {
        kv.setString(
            StorageKeys.settingsDirtyKeys, jsonEncode(keys.toList()..sort()));
      }
    } catch (_) {}
  }

  Map<String, String>? _syncedFlat() {
    try {
      final out = <String, String>{};
      StorageSync.buildSectionPayloads(
        _ref.read(settingsProvider),
        kv: _ref.read(keyValueStoreProvider),
        selfPubkey: _identity?.pubkey,
      ).forEach((_, fields) {
        fields.forEach((k, v) {
          if (k != 'v') out[k] = jsonEncode(v);
        });
      });
      return out;
    } catch (_) {
      return null;
    }
  }

  void _rememberSyncedBaseline() {
    _syncedBaseline = _syncedFlat() ?? _syncedBaseline;
  }

  void _markSettingsDirty() {
    if (_applyingSynced) return;
    final dirty = _dirtySyncedKeys;
    final base = _syncedBaseline;
    final now = _syncedFlat();
    if (base == null || now == null) {
      for (final keys in StorageSync.syncedSectionKeys.values) {
        dirty.addAll(keys);
      }
    } else {
      for (final key in {...base.keys, ...now.keys}) {
        if (base[key] != now[key]) dirty.add(key);
      }
    }
    _saveDirtySyncedKeys();
  }

  @visibleForTesting
  void markSettingsDirtyForTest() => _markSettingsDirty();

  @visibleForTesting
  void processGiftWrapForTest(GiftWrapUnwrapped u) => _processGiftWrap(u);

  @visibleForTesting
  void setIdentityForTest(Identity identity) => _identity = identity;

  @visibleForTesting
  Future<bool> Function(Group group, String content, int nowSec)?
      addMembersSenderForTest;

  @visibleForTesting
  Future<NostrEvent?> Function(
          String content, LocalSigner signer, String nym, String? threadRoot)?
      pseudonymousPublishForTest;

  @visibleForTesting
  Future<void> Function(NostrEvent event)? botReplyPublishForTest;

  @visibleForTesting
  set apiForTest(ApiClient api) => _api = api;

  @visibleForTesting
  Future<bool> Function(String to, List<List<String>> tags, String content)?
      sendDirectForTest;

  @visibleForTesting
  void onGiftWrapForTest(GiftWrapUnwrapped u) => _onGiftWrap(u);

  @visibleForTesting
  Future<void> get giftWrapDrainForTest =>
      _giftWrapDrain ?? Future<void>.value();

  @visibleForTesting
  void onEventForTest(NostrEvent event) => _onEvent(event);

  /// Test seam: applies an inbound payload like a real settings-get.
  @visibleForTesting
  void applySyncedSettingsForTest(Map<String, dynamic> p) {
    _applySyncedSettingsAdditive(p);
    _applySyncedSettings(p);
  }

  Map<String, dynamic> _withoutLocallyDirtyKeys(Map<String, dynamic> p) {
    final drop = _dirtySyncedKeys;
    if (drop.isEmpty) return p;
    return {
      for (final e in p.entries)
        if (!drop.contains(e.key)) e.key: e.value,
    };
  }

  void _quietSyncedApply(void Function() body) {
    final was = _applyingSynced;
    _applyingSynced = true;
    try {
      body();
    } finally {
      _applyingSynced = was;
      if (!was) _rememberSyncedBaseline();
    }
  }

  void _applySyncedSettings(
    Map<String, dynamic> pRaw, {
    bool userAcceptedTransfer = false,
  }) {
    if (userAcceptedTransfer) {
      _applySyncedSettingsNow(pRaw, userAcceptedTransfer: true);
    } else {
      _quietSyncedApply(() => _applySyncedSettingsNow(pRaw));
    }
  }

  void _applySyncedSettingsNow(
    Map<String, dynamic> pRaw, {
    bool userAcceptedTransfer = false,
  }) {
    // An accepted transfer is a deliberate overwrite, so it outranks pending local edits.
    final p = userAcceptedTransfer ? pRaw : _withoutLocallyDirtyKeys(pRaw);
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

    // Unknown theme ids fall back to bitchat.
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
    boolean('threadsEnabled', c.setThreadsEnabled);
    str('nickStyle', c.setNickStyle);
    str('wallpaperType', c.setWallpaperType);
    // Out-of-range text sizes (outside 12–28) are ignored, not clamped.
    final textSize = p['textSize'];
    if (textSize is num && textSize >= 12 && textSize <= 28) {
      try {
        c.setTextSize(textSize.toInt());
      } catch (_) {}
    }
    boolean('transparencyEnabled', c.setTransparencyEnabled);
    boolean('dmForwardSecrecyEnabled', c.setDmForwardSecrecy);
    integer('dmTTLSeconds', c.setDmTtlSeconds);
    // Scopes are validated, with the legacy `*Enabled` boolean fallback.
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
    // Synced as a `{type,geohash}` object; re-encode to the JSON the setter expects.
    final landing = p['pinnedLandingChannel'];
    if (landing is Map &&
        landing['geohash'] is String &&
        (landing['geohash'] as String).isNotEmpty) {
      try {
        // Migrate the legacy `{geohash:'nym'}` default to `nymchat`.
        final migrated = landing['geohash'] == 'nym'
            ? const {'type': 'geohash', 'geohash': 'nymchat'}
            : landing;
        c.setPinnedLandingChannel(jsonEncode(migrated));
      } catch (_) {}
    }
    boolean('gesturesEnabled', c.setGesturesEnabled);
    // Swipe settings apply only when valid (known action, threshold 30–120, emoji 1–8 chars).
    const validSwipeActions = [
      'quote',
      'translate',
      'copy',
      'react',
      'zap',
      'slap',
      'hug',
      'none',
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
    // Quick React emoji is last-writer-wins by pick time; refuse older blobs and republish ours.
    final swipeEmoji = p['swipeReactEmoji'];
    if (swipeEmoji is String) {
      final rawEmojiTs = p['swipeReactEmojiTs'];
      final remoteEmojiTs = rawEmojiTs is num ? rawEmojiTs.toInt() : 0;
      // An accepted transfer applies as if picked here and now.
      if (userAcceptedTransfer
          ? isValidSwipeReactEmoji(swipeEmoji)
          : shouldApplySyncedSwipeReactEmoji(
              value: swipeEmoji,
              remoteTs: remoteEmojiTs,
              localTs: c.swipeReactEmojiTs,
            )) {
        try {
          c.setSwipeReactEmoji(
            swipeEmoji,
            remoteTs: userAcceptedTransfer ? null : remoteEmojiTs,
          );
        } catch (_) {}
      } else if (isValidSwipeReactEmoji(swipeEmoji) &&
          swipeEmoji != _ref.read(settingsProvider).swipeReactEmoji) {
        // Republish ours so the stale blob is healed.
        syncSettings();
      }
    }
    boolean('sortByProximity', c.setSortByProximity);
    boolean('lowDataMode', c.setLowDataMode);
    boolean('backgroundConnectivity', c.setBackgroundConnectivity);
    boolean('cachePMs', c.setCachePMs);
    // Replace the favorite lists so an unfavorite propagates.
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
    // showStatus arrives as bool|'friends'.
    final ss = p['showStatus'];
    if (ss is bool) {
      c.setShowStatus(ss ? 'true' : 'false');
    } else if (ss == 'friends') {
      c.setShowStatus('friends');
    }
    // A call answered elsewhere stops re-ringing and retracts our missed-call notification.
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

    // KV-backed synced prefs, mirroring the PWA's field names, shapes and merge rules.
    final appState = _ref.read(appStateProvider.notifier);
    final selfPk = _ref.read(appStateProvider).selfPubkey;

    final columnsLayout = p['columnsLayout'];
    if (columnsLayout is List) {
      try {
        kvStore.setString(StorageKeys.columnsLayout, jsonEncode(columnsLayout));
      } catch (_) {}
    }
    // Paired with `wallpaperType` so a synced custom wallpaper keeps its URL.
    final wallpaperUrl = p['wallpaperCustomUrl'];
    if (wallpaperUrl is String && wallpaperUrl.isNotEmpty) {
      try {
        kvStore.setString(StorageKeys.wallpaperCustomUrl, wallpaperUrl);
      } catch (_) {}
    }
    // Global and per-pubkey lightning address, applied on every sync.
    final lightning = p['lightningAddress'];
    if (lightning is String && lightning.isNotEmpty) {
      try {
        kvStore.setString(StorageKeys.lightningAddressGlobal, lightning);
        if (selfPk.isNotEmpty) {
          kvStore.setString(StorageKeys.lightningAddressFor(selfPk), lightning);
        }
      } catch (_) {}
    }
    final pow = p['powDifficulty'];
    if (pow is num) {
      try {
        c.setPowDifficulty(pow.toInt());
      } catch (_) {}
    }
    boolean('hideNonPinned', c.setHideNonPinned);
    // true | false | 'friends'; writes global and per-pubkey keys.
    final blur = p['blurOthersImages'];
    if (blur is bool || blur == 'friends') {
      try {
        final v =
            blur == 'friends' ? 'friends' : (blur == true ? 'true' : 'false');
        c.setBlurImages(v, pubkey: selfPk.isEmpty ? null : selfPk);
      } catch (_) {}
    }
    final sidebar = p['sidebarSectionOrder'];
    if (sidebar is List) {
      try {
        kvStore.setString(StorageKeys.sidebarSectionOrder,
            jsonEncode(sidebar.whereType<String>().toList()));
      } catch (_) {}
    }
    // Replace the favorite translation languages.
    final translateFavs = p['translateFavoriteLanguages'];
    if (translateFavs is List) {
      try {
        kvStore.setString(StorageKeys.translateFavorites,
            jsonEncode(translateFavs.whereType<String>().toList()));
      } catch (_) {}
    }
    // Typed state plus KV, like the notifications panel.
    final notif = p['notificationsEnabled'];
    if (notif is bool) {
      try {
        c.update((s) => s.copyWith(notificationsEnabled: notif));
        kvStore.setString(StorageKeys.notificationsEnabled, '$notif');
      } catch (_) {}
    }
    // KV booleans read as the strings 'true'/'false'.
    final groupMentions = p['groupNotifyMentionsOnly'];
    if (groupMentions is bool) {
      try {
        kvStore.setString(
            StorageKeys.groupNotifyMentionsOnly, '$groupMentions');
      } catch (_) {}
    }
    final threadMentions = p['threadNotifyMentionsOnly'];
    if (threadMentions is bool) {
      try {
        kvStore.setString(
            StorageKeys.threadNotifyMentionsOnly, '$threadMentions');
      } catch (_) {}
    }
    final friendsOnly = p['notifyFriendsOnly'];
    if (friendsOnly is bool) {
      try {
        kvStore.setString(StorageKeys.notifyFriendsOnly, '$friendsOnly');
      } catch (_) {}
    }
    final mls = p['syncMLSHistory'];
    if (mls is bool) {
      try {
        c.update((s) => s.copyWith(syncMLSHistory: mls));
        kvStore.setBool(StorageKeys.syncMlsHistory, mls);
      } catch (_) {}
    }
    // Merge favorite GIFs: dedupe by url, cap 100.
    final favGifs = p['favoriteGifs'];
    if (favGifs is List && favGifs.isNotEmpty) {
      _mergeFavoriteGifs(kvStore, favGifs);
    }
    // Merge recent emojis: most recent first, dedupe, cap 24.
    final recent = p['recentEmojis'];
    if (recent is List && recent.isNotEmpty) {
      _mergeRecentEmojis(kvStore, recent);
    }

    // Friends / blocked users / keywords are replaced via add/remove diffs so removals propagate; KV is persisted.
    final friends = p['friends'];
    if (friends is List) {
      try {
        final incoming =
            friends.whereType<String>().where((s) => s.isNotEmpty).toSet();
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
        final incoming =
            blockedUsers.whereType<String>().where((s) => s.isNotEmpty).toSet();
        final current = {..._ref.read(appStateProvider).blockedUsers};
        for (final pk in incoming.difference(current)) {
          appState.blockUser(pk);
        }
        for (final pk in current.difference(incoming)) {
          appState.unblockUser(pk);
        }
        final blocked = _ref.read(appStateProvider).blockedUsers;
        _persistSet(StorageKeys.blocked, blocked);
        // Keep the bell badge's blocked-sender exclusion in sync.
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

    // Pinned/blocked/hidden are replaced so removals propagate; joined stays additive; 'nym' migrates to 'nymchat'.
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
          if (k != kDefaultChannel)
            ChannelEntry(channel: k, geohash: isChannelGeohash(k) ? k : ''),
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
          try {
            _ref.read(chatNavProvider).afterLegacyChange();
          } catch (_) {}
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

    // Closed PMs are a set union (no invented times); closed and leave times merge by per-key max.
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
        // As in the additive twin: persist, or the next save republishes the pre-merge set.
        _persistClosedPMs();
      } catch (_) {}
    }

    _mergeLeftGroupsFromSync(p['leftGroups'], p['leftGroupTimes']);

    // Monotonic max per conversation so a new device doesn't re-surface read history.
    _applyChannelLastRead(p['channelLastRead']);

    // `tutorialSeen` / `botPmWelcomed` only flip on; `botPmClearedAt` is monotonic.
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
    final botMaxRuns = p['botMaxRuns'];
    if (botMaxRuns is num) {
      try {
        _ref
            .read(botChatControllerProvider.notifier)
            .setMaxRuns(botMaxRuns.toInt(), fromSync: true);
      } catch (_) {}
    }
    // Monotonic, persisted on every inbound apply path.
    if (p['encryptAtRestPreferred'] == true) {
      try {
        kvStore.setBool(StorageKeys.encryptAtRestPref, true);
      } catch (_) {}
    }
  }

  // Cross-device settings sections are auto-applied, never offered; the pending list is for user-to-user transfers.

  /// Auto-applies D1 sections newer than our last sync ts, oldest first, and advances the ts; best-effort.
  Future<void> refreshPendingSettingsTransfers() async {
    final sync = _storageSync;
    if (sync == null) return;
    try {
      final sinceMs = _lastSettingsSyncMs();
      final sections = await sync.settingsTransfersSince(sinceMs);
      if (sections.isEmpty) return;
      // Oldest first so the newest values win.
      final ordered = [...sections]
        ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      var newestSec = 0;
      for (final s in ordered) {
        // Additive merge, then replace-style apply per section.
        _applySyncedSettingsAdditive(s.payload);
        _applySyncedSettings(s.payload);
        final sec = s.updatedAt ~/ 1000;
        if (sec > newestSec) newestSec = sec;
      }
      final kv = _ref.read(keyValueStoreProvider);
      final lastSec =
          int.tryParse(kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ??
              0;
      if (newestSec > lastSec) {
        kv.setString(StorageKeys.lastSettingsSyncTs, '$newestSec');
      }
      // The offer list stays empty for our own sections.
      _ref.read(pendingSettingsTransfersProvider.notifier).clear();
    } catch (_) {
      // Best-effort.
    }
  }

  /// Applies a pending transfer, advances the sync ts so it isn't re-offered, and removes it; true if applied.
  bool acceptSettingsTransfer(String id) {
    final notifier = _ref.read(pendingSettingsTransfersProvider.notifier);
    final offer = notifier.removeById(id);
    if (offer == null) return false;
    // Additive merge, then replace-style apply.
    _applySyncedSettingsAdditive(offer.payload);
    _applySyncedSettings(offer.payload);
    // Advance the sync ts (seconds) so the section isn't re-surfaced.
    final kv = _ref.read(keyValueStoreProvider);
    final lastSec =
        int.tryParse(kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ?? 0;
    final offerSec = offer.updatedAt ~/ 1000;
    if (offerSec > lastSec) {
      kv.setString(StorageKeys.lastSettingsSyncTs, '$offerSec');
    }
    return true;
  }

  /// Drops a pending transfer unapplied; true if present; a newer publish may resurface it.
  bool declineSettingsTransfer(String id) {
    return _ref
            .read(pendingSettingsTransfersProvider.notifier)
            .removeById(id) !=
        null;
  }

  int _lastSettingsSyncMs() {
    final kv = _ref.read(keyValueStoreProvider);
    final sec =
        int.tryParse(kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ?? 0;
    return sec * 1000;
  }

  Timer? _chatToolsTimer;

  void _startGroupTools() {
    final gt = _ref.read(groupToolsProvider);
    final app = _ref.read(appStateProvider.notifier);
    app.absorbLiveHook = gt.absorbLive;
    app.slowmodeHook = (gid, list, sender) {
      gt.applySlowmode(gid, list, sender);
    };
    gt.armReminders();
    unawaited(gt.resumeLive());
  }

  String? groupSendBlockReason(String content) {
    final view = _ref.read(appStateProvider).view;
    if (view.kind != ViewKind.group) return null;
    if (isCommandLine(content.trim())) return null;
    return _ref.read(groupToolsProvider).sendBlockedReason(view.id, content);
  }

  Future<bool> gtSendGroupControl(Group g, String type,
      List<List<String>> extraTags, List<String> recipients,
      {String content = ''}) async {
    final identity = _identity;
    final groups = _groups;
    if (identity == null || groups == null || recipients.isEmpty) return false;
    return groups.sendControl(
      group: g,
      selfPubkey: identity.pubkey,
      type: type,
      extraTags: extraTags,
      recipients: recipients,
      content: content,
    );
  }

  Future<bool> gtSendDirect(
      String to, List<List<String>> tags, String content) async {
    final testSend = sendDirectForTest;
    if (testSend != null) return testSend(to, tags, content);
    final identity = _identity;
    final service = _service;
    if (identity == null || service == null || !service.canSign) return false;
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: EventKind.dmRumor,
      tags: [
        ['p', to],
        ...tags,
      ],
      content: content,
    );
    try {
      return await service.publishGiftWrappedRumor(
          rumor: rumor, recipients: [to]);
    } catch (_) {
      return false;
    }
  }

  Future<bool> dpSendControl(
      UnsignedEvent rumor, List<String> recipients, String? groupId) async {
    final identity = _identity;
    final service = _service;
    if (identity == null || service == null || !service.canSign) return false;
    try {
      if (groupId != null) {
        final groups = _groups;
        final g = _ref.read(appStateProvider.notifier).groupById(groupId);
        if (groups == null || g == null) return false;
        return await groups.sendRumor(
          group: g,
          selfPubkey: identity.pubkey,
          rumor: rumor,
          recipients: recipients,
        );
      }
      return await service.publishGiftWrappedRumor(
          rumor: rumor, recipients: recipients);
    } catch (_) {
      return false;
    }
  }

  Future<bool> gtBroadcastMetadata(Group g) async {
    final identity = _identity;
    final groups = _groups;
    if (identity == null || groups == null) return false;
    return groups.sendMetadata(
        group: g, selfPubkey: identity.pubkey, settings: _msgSettings);
  }

  Future<bool> gtSendGroupContent(String groupId, String content) async {
    final reason =
        _ref.read(groupToolsProvider).sendBlockedReason(groupId, content);
    if (reason != null) {
      _emitSystemMessage(reason);
      return false;
    }
    await _sendMessageContent(content, viewOverride: ChatView.group(groupId));
    return true;
  }

  Future<bool> gtSendPmContent(String pubkey, String content) async {
    await _sendMessageContent(content, viewOverride: ChatView.pm(pubkey));
    return true;
  }

  Future<bool> gtSendMeshPm(String pubkey, String content) async {
    final bridge = _ref.read(meshControllerProvider.notifier).bridge;
    if (bridge == null) return false;
    await bridge.sendFromComposer(ChatView.pm(pubkey), content);
    return true;
  }

  void gtNotify(
      {required String title,
      required String body,
      required String route,
      required String type}) {
    _dispatchNotification(
      title: title,
      body: body,
      senderPubkey: type == 'call' ? route : '',
      isFriend: false,
      isMention: false,
      isGroup: type == 'group',
      historyType: type,
      route: route,
      eventId: 'gt-${DateTime.now().microsecondsSinceEpoch}',
      tsMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  String gtNym(String pubkey) {
    final raw = pubkey == _identity?.pubkey ? _identity!.nym : _nymFor(pubkey);
    return raw.replaceFirst(RegExp(r'(#[0-9a-fA-F]{4})+$'), '');
  }

  Future<Map<String, dynamic>?> gtSign(Map<String, dynamic> template) async {
    final signer = _signer;
    if (signer == null) return null;
    try {
      final ev = await signer.sign(UnsignedEvent(
        pubkey: template['pubkey'] as String,
        createdAt: template['created_at'] as int,
        kind: template['kind'] as int,
        tags: [
          for (final t in template['tags'] as List)
            [for (final x in t as List) x.toString()]
        ],
        content: template['content'] as String,
      ));
      return ev.toJson();
    } catch (_) {
      return null;
    }
  }

  Timer? _chatNavTimer;

  void _startChatNav() {
    final nav = _ref.read(chatNavProvider);
    final notifier = _ref.read(appStateProvider.notifier);
    notifier.onViewEntering = (from, to, columns) {
      if (!columns && from.isNotEmpty && from != to) nav.release(from);
      nav.capture(to);
    };
    notifier.onNavReadMarked = nav.pruneRemoteRead;
    nav.afterLegacyChange();
    _chatNavTimer?.cancel();
    _chatNavTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (nav.pinPending) unawaited(nav.syncPins());
    });
    Timer(const Duration(seconds: 4), () {
      if (_started) unawaited(nav.refreshScheduled());
    });
  }

  void _chatNavReconnect() {
    try {
      final nav = _ref.read(chatNavProvider);
      if (nav.pinPending) unawaited(nav.syncPins());
      unawaited(nav.refreshScheduled());
    } catch (_) {}
  }

  void _startChatTools() {
    final tools = _ref.read(chatToolsProvider);
    _ref.read(appStateProvider.notifier).onBeforeEdit =
        (m, next, at) => tools.noteEdit(m, next, at);
    _ref.read(appStateProvider.notifier).onStaleEdit =
        (m, text, at) => tools.noteStaleEdit(m, text, at);
    _chatToolsTimer?.cancel();
    _chatToolsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _ref
          .read(appStateProvider.notifier)
          .sweepExpiredMessages((m) => chatToolsHidden(m));
      if (tools.savedPending) unawaited(tools.syncSaved());
      unawaited(tools.flushKeepOutbox());
    });
  }

  bool get savesHydrated => _settingsHydrated;

  bool get savedSyncAllowed {
    if (_identity?.loginMethod == null) {
      final mode = _ref.read(settingsProvider.notifier).keypairMode;
      if (mode == 'random' || mode == 'hardcore') return false;
    }
    return true;
  }

  Future<bool> publishSavedMessages(Map<String, dynamic> saved) async {
    final sync = _storageSync;
    if (sync == null) return false;
    return sync.savedSyncSet(saved);
  }

  Future<bool> publishPinnedChats(Map<String, dynamic> pinned) async {
    final sync = _storageSync;
    if (sync == null) return false;
    return sync.pinnedSyncSet(pinned);
  }

  Future<bool> publishLockedChats(Map<String, dynamic> locked) async {
    final sync = _storageSync;
    if (sync == null) return false;
    return sync.lockedSyncSet(locked);
  }

  Future<Map<String, dynamic>> scheduleApi(
      String action, Map<String, dynamic> body) async {
    final sync = _storageSync;
    if (sync == null) {
      throw ScheduleApiError(tr(ChatNavStrings.serverBlocked));
    }
    try {
      return await sync.scheduleAction(action, body);
    } on ApiException catch (e) {
      throw ScheduleApiError(e.body, code: e.code, status: e.statusCode);
    }
  }

  ChatView? chatViewForKey(String key) {
    if (key.startsWith('pm-')) return ChatView.pm(key.substring(3));
    if (key.startsWith('group-')) return ChatView.group(key.substring(6));
    if (key.startsWith('#')) return ChatView.channel(key.substring(1));
    return key.isEmpty ? null : ChatView.channel(key);
  }

  ChatNavBlockContext scheduleBlockContext(String key) {
    final view = chatViewForKey(key);
    final bridge = _ref.read(meshControllerProvider.notifier).bridge;
    final meshOnly =
        view != null && bridge != null && bridge.shouldSendOverMesh(view);
    return ChatNavBlockContext(
      meshOnly: meshOnly,
      server: _storageSync != null && _identity != null,
      online: _ref.read(appStateProvider).connectedRelays > 0,
      localKey: _identity?.privkey != null,
    );
  }

  Future<String?> encryptScheduleNote(String json) async {
    final service = _service;
    final identity = _identity;
    final sig = service?.signer;
    if (sig == null || identity == null) return null;
    return sig.nip44Encrypt(identity.pubkey, json);
  }

  Future<String?> decryptScheduleNote(String blob) async {
    final service = _service;
    final identity = _identity;
    final sig = service?.signer;
    if (sig == null || identity == null) return null;
    return sig.nip44Decrypt(identity.pubkey, blob);
  }

  Future<bool> sendScheduledText(String key, String text) async {
    final view = chatViewForKey(key);
    if (view == null) return false;
    await _sendMessageContent(text, viewOverride: view);
    return true;
  }

  Future<NostrEvent> _scheduledWrap(
    UnsignedEvent rumor,
    Uint8List sk,
    String to,
    Uint8List? kem,
    bool layered,
    int? expiration,
    List<List<String>> extraTags,
    int at,
  ) async {
    final off = await CryptoWorker.instance.wrapOne(
      rumor: rumor,
      senderPrivkey: sk,
      recipientPubkey: to,
      expiration: expiration,
      recipientKemPk: kem,
      layered: layered,
      extraTags: extraTags,
      at: at,
    );
    if (off != null) return off;
    if (kem == null) {
      return giftwrap.nip59Wrap(
          rumor: rumor,
          senderPrivkey: sk,
          recipientPubkey: to,
          expiration: expiration,
          extraTags: extraTags,
          at: at);
    }
    if (layered) {
      return giftwrap.pq2Nip59Wrap(
          rumor: rumor,
          senderPrivkey: sk,
          recipientPubkey: to,
          recipientKemPublicKey: kem,
          expiration: expiration,
          extraTags: extraTags,
          at: at);
    }
    return giftwrap.pqNip59Wrap(
        rumor: rumor,
        senderPrivkey: sk,
        recipientPubkey: to,
        recipientKemPublicKey: kem,
        expiration: expiration,
        extraTags: extraTags,
        at: at);
  }

  Future<ScheduleBuild> buildScheduledEvents(
      String key, String text, int at, String? threadRoot) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) throw StateError('session');
    final atMs = at * 1000;
    final expiration = _msgSettings.expirationFor(at);
    if (key.startsWith('pm-') || key.startsWith('group-')) {
      final sk = identity.privkey;
      if (sk == null) throw StateError('signer');
      final events = <Map<String, dynamic>>[];
      if (key.startsWith('pm-')) {
        final peer = key.substring(3).toLowerCase();
        try {
          await ensurePqAnnouncement(peer);
        } catch (_) {}
        final plan = _pmPlanFor(identity, peer);
        final base = PmLogic.buildPmRumor(
          selfPubkey: identity.pubkey,
          recipientPubkey: peer,
          content: text,
          nymMessageId: PmLogic.generateSharedEventId(),
          nowSec: at,
          nowMs: atMs,
          extraTags: [
            if (threadRoot != null && threadRoot.isNotEmpty)
              ['nymthread', threadRoot],
            ..._contentTags(text),
          ],
        );
        final support = pmSupportTokenFor(peer);
        final rumor = PmLogic.withSupportToken(base, support);
        final wrapTags = PmLogic.supportWrapTags(support);
        if (plan.bitchat) {
          for (final chunk in bitchat.chunkBitchatContent(text)) {
            final encoded = bitchat.encodeBitchatMessage(
                chunk, identity.pubkey,
                recipientPubkey: peer);
            final w = await giftwrap.bitchatWrap(
              rumor: UnsignedEvent(
                pubkey: identity.pubkey,
                createdAt: at,
                kind: EventKind.dmRumor,
                tags: const [],
                content: encoded.content,
              ),
              senderPrivkey: sk,
              recipientPubkey: peer,
              at: at,
            );
            events.add({'e': w.toJson(), 'r': 'pub'});
          }
        }
        if (plan.nym) {
          final w = await _scheduledWrap(rumor, sk, peer, plan.kemPublicKey,
              plan.layered, expiration, wrapTags, at);
          events.add({'e': w.toJson(), 'r': 'dep'});
        }
        final selfKem = pqSelfKey();
        final selfWrap = await _scheduledWrap(rumor, sk, identity.pubkey,
            selfKem, selfKem != null && pqSelfUsesLayered(), expiration,
            wrapTags, at);
        events.add({'e': selfWrap.toJson(), 'r': 'self'});
      } else {
        final gid = key.substring(6);
        final group = _ref.read(appStateProvider.notifier).groupById(gid);
        if (group == null) throw StateError('group');
        final rumor = UnsignedEvent(
          pubkey: identity.pubkey,
          createdAt: at,
          kind: EventKind.dmRumor,
          tags: [
            ['g', gid],
            ...groupSubjectTags(group.name),
            ['x', GroupLogic.generateGroupId()],
            ['ms', '$atMs'],
            ..._contentTags(text),
            if (threadRoot != null && threadRoot.isNotEmpty)
              ['nymthread', threadRoot],
          ],
          content: text,
        );
        final members = <String>{...group.members, identity.pubkey};
        final jobs = <Future<NostrEvent>>[];
        for (final pk in members) {
          final self = pk == identity.pubkey;
          final kem = self ? pqSelfKey() : _pqGroupKeyFor(pk);
          final layered = kem != null &&
              (self ? pqSelfUsesLayered() : _pqGroupLayeredFor(pk));
          jobs.add(_scheduledWrap(
              rumor, sk, pk, kem, layered, expiration, const [], at));
        }
        final wraps = await Future.wait(jobs);
        var i = 0;
        for (final pk in members) {
          final self = pk == identity.pubkey;
          events.add({'e': wraps[i++].toJson(), 'r': self ? 'self' : 'dep'});
        }
      }
      return (
        events: events,
        relays: scheduleRelays(RelayConfig.defaultRelays),
      );
    }
    final channelKey = key.startsWith('#') ? key.substring(1) : key;
    final isGeo = _ref
        .read(appStateProvider)
        .channels
        .any((c) => c.key == channelKey.toLowerCase() && c.isGeohash);
    await _awaitAttestBadge();
    final signed = await service.publishChannelMessage(
      buildOnly: true,
      channelKey: channelKey,
      content: text,
      nym: identity.nym,
      geohash: isGeo ? channelKey : null,
      emojiTags: _contentTags(text),
      powDifficulty: _ref.read(settingsProvider.notifier).powDifficulty,
      threadRoot: threadRoot,
      createdAtSec: at,
    );
    if (signed == null) throw StateError('sign');
    final relays = <String>[
      if (isGeo) ...service.closestGeoRelays(channelKey).map((r) => r.url),
      ...RelayConfig.defaultRelays,
    ];
    return (
      events: [
        {'e': signed.toJson(), 'r': 'pub'}
      ],
      relays: scheduleRelays(relays),
    );
  }

  Future<bool> publishKeepControl(
      String storageKey, String nid, bool kept, int at) async {
    final service = _service;
    final identity = _identity;
    final online = _ref.read(appStateProvider).connectedRelays > 0;
    if (storageKey.startsWith('group-')) {
      final groupId = storageKey.substring(6);
      final group = _ref.read(appStateProvider.notifier).groupById(groupId);
      if (!online || service == null || identity == null || group == null) {
        return false;
      }
      final ek = _groups?.keysFor(groupId);
      var any = false;
      for (final pk in group.members) {
        final ok = await service.publishControlRumor(
          tags: chat_tools.keepTags([nid], kept, null, groupId),
          recipientPubkey: pk,
          encryptToPubkey: ek?.encryptionPubkeyFor(pk, identity.pubkey),
          createdAt: at,
        );
        any = any || ok;
      }
      return any;
    }
    if (!storageKey.startsWith('pm-')) return false;
    final peer = storageKey.substring(3);
    final bridge = _ref.read(meshControllerProvider.notifier).bridge;
    if (bridge != null &&
        (bridge.isMeshOnlyPubkey(peer) || bridge.isGhostPinned(peer))) {
      return bridge.sendKeep(peer, nid, kept);
    }
    if (!online || service == null || identity == null) return false;
    var any = false;
    for (final to in {peer, identity.pubkey}) {
      final ok = await service.publishControlRumor(
        tags: chat_tools.keepTags([nid], kept, to, null),
        recipientPubkey: to,
        createdAt: at,
      );
      any = any || ok;
    }
    return any;
  }

  /// True once the boot restore settles; saves are deferred until then so defaults can't clobber whole D1 rows.
  bool _settingsHydrated = false;
  bool _settingsSavePending = false;

  /// Opens the save gate (flushing one suppressed save) and releases the onboarding gate.
  void _markSettingsHydrated() {
    _releaseOnboardingGate();
    if (_settingsHydrated) return;
    _settingsHydrated = true;
    if (_settingsSavePending) {
      _settingsSavePending = false;
      syncSettings();
    }
  }

  /// Releases only the onboarding gate, leaving saves closed until a load succeeds.
  void _releaseOnboardingGate() {
    _settingsHydratedFallback?.cancel();
    _settingsHydratedFallback = null;
    if (!_settingsHydratedC.isCompleted) _settingsHydratedC.complete();
  }

  /// Debounced (5s) settings publish; skipped without sync or for random/hardcore ephemeral keys; deferred until hydrated.
  void syncSettings() {
    // Mark dirty before any early return; the edit is already in KV.
    _markSettingsDirty();
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

  /// Publishes pending settings now, under [syncSettings]'s gates, for changes made just before closing.
  void flushSettingsSyncNow() {
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
    _settingsSyncTimer = null;
    unawaited(_flushSettingsSync(sync));
  }

  Future<void> _flushSettingsSync(StorageSync sync) async {
    try {
      // Keep the inbound PoW filter in step with the saved setting.
      appPowFilterBits = pow.normalizePowDifficulty(
          _ref.read(settingsProvider.notifier).powDifficulty);
      appVerifiedFilter =
          _ref.read(settingsProvider.notifier).appVerifiedFilter;
      unawaited(FilterPacks.setActive(
          _ref.read(settingsProvider.notifier).filterPacks));
      // The landing channel is KV-only, so thread it into the `channels` section explicitly.
      final appState = _ref.read(appStateProvider.notifier);
      // Cleared before the write so an edit made in flight re-marks and survives.
      _dirtySyncedKeys.clear();
      _saveDirtySyncedKeys();
      _rememberSyncedBaseline();
      await sync.settingsSet(
        _ref.read(settingsProvider),
        pinnedLandingChannelJson:
            _ref.read(settingsProvider.notifier).pinnedLandingChannelJson,
        // Seen calls ride the `messaging` section.
        seenCalls: _ref.read(callServiceProvider).seenCallsForSync(),
        // Use live left-group state; the KV fallback can lag the fire-and-forget persist.
        extras: {
          'leftGroups': appState.leftGroups.toList(),
          'leftGroupTimes': Map<String, dynamic>.from(appState.leftGroupTimes),
        },
        // Lets the channels-section trimmer drop least-recently-active channels first when oversized.
        channelActivity: Map<String, int>.from(
            _ref.read(appStateProvider).channelLastActivity),
      );
      // Publish notification read state with the live history and watermark; no-op when unchanged.
      final notifHistory = _ref.read(notificationHistoryProvider.notifier);
      await sync.notificationsWrapSet(
        notifHistory.seenNotificationsForSync(),
        notificationHistory: notifHistory.historyForSync(),
        notificationLastReadTime: notifHistory.notificationLastReadTime,
      );
      // Publish read watermarks so other devices restore them; no-op when unchanged.
      await sync.readStateSet(
        _ref.read(appStateProvider.notifier).channelLastRead,
      );
      // Per-group sync (conversations, keys, history); no-op per category when unchanged.
      await _flushGroupSync(sync);
    } catch (_) {
      // Best-effort.
    }
  }

  /// Builds and publishes the per-group sync payloads; optimistic echoes and system pills are excluded.
  Future<void> _flushGroupSync(StorageSync sync) async {
    final groups = _groups;
    if (groups == null) return;
    final appState = _ref.read(appStateProvider.notifier);
    final st = _ref.read(appStateProvider);

    // Sync shape only; device-local extras ride the local blob instead.
    final conversations = <String, Map<String, dynamic>>{};
    for (final g in st.groups) {
      conversations[g.id] = _serializeGroupForSync(g);
    }

    // Serialized per-group ephemeral keys.
    final ephemeralKeys = groups.ephemeralKeysForSync();

    // Group message backlog per conversation key.
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
    try {
      final anonPayload =
          _ref.read(botChatControllerProvider.notifier).anon.syncPayload();
      if (anonPayload != null) await sync.botAnonSyncSet(anonPayload);
    } catch (_) {}
  }

  /// Serializes a [Group] for `nymchat-groups` without the local-only fields; modLog capped to 50.
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
      // The apply side stays absence-safe for older devices' blobs.
      'allowMemberInvites': g.allowMemberInvites,
      'inviteEnabled': g.inviteEnabled == true,
      'inviteEpoch': g.inviteEpoch,
      'shareHistory': g.shareHistory == true,
      'metaUpdatedAt': g.metaUpdatedAt,
      'modLog': [for (final e in modLog) e.toJson()],
      if (g.memberAt.isNotEmpty) 'memberAt': g.memberAt,
      if (g.memberRemovedAt.isNotEmpty) 'memberRemovedAt': g.memberRemovedAt,
    };
  }

  /// Serializes a [Group] for the local blob: sync fields plus device-local extras.
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
    data['modTsByTarget'] = g.modTsByTarget;
    data['modSeenIds'] = g.modSeenIds.length > 100
        ? g.modSeenIds.sublist(g.modSeenIds.length - 100)
        : g.modSeenIds;
    data['historyReceived'] = g.historyReceived;
    if (g.joinedVia != null) data['joinedVia'] = g.joinedVia;
    return data;
  }

  /// Hydrates custom emoji from D1, verifying each event and routing through the live ingest handlers; best-effort.
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
      // Verify the cohort off the main isolate in one batch; newest-wins dedup makes order irrelevant.
      final service = _service;
      final oks = service != null
          ? await Future.wait(
              [for (final ev in parsed) service.verifyEvent(ev)])
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

  Future<void> _restorePmArchive(StorageSync sync) async {
    if (!sync.durableIdentity) return;
    try {
      final wraps = await sync.pmRestoreFromD1();
      for (final w in wraps) {
        _replayArchivedWrap(w);
      }
    } catch (_) {
      // Best-effort.
    }
  }

  bool canLoadOlderArchive(String storageKey) {
    if (!storageKey.startsWith('pm-') && !storageKey.startsWith('group-')) {
      return false;
    }
    final sync = _storageSync;
    return sync != null && sync.durableIdentity && sync.pmArchiveHasOlder;
  }

  Future<int> loadOlderArchive(String storageKey) => loadOlderPmArchive();

  /// Loads the next older page of archived PMs; returns the number of wraps replayed.
  Future<int> loadOlderPmArchive() async {
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return 0;
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

  /// Unwraps an archived wrap and routes it like a live one, minus re-archiving.
  void _replayArchivedWrap(Map<String, dynamic> wrap) {
    final service = _service;
    if (service == null) return;
    try {
      service.unwrapArchivedWrap(NostrEvent.fromJson(wrap));
    } catch (_) {
      // Skip a malformed or undecryptable archived wrap.
    }
  }

  /// Archives a sent wrap: self copy via `pm-put`, recipient copies via `pm-deposit` (the only path to offline peers).
  void _archiveSentWrap(NostrEvent wrap) {
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return;
    final raw = wrap.toJson();
    unawaited(sync.pmPut([raw]));
    sync.enqueueDeposit(raw,
        tier: _service?.sentWrapTier(wrap.id) ?? WrapTier.critical);
  }

  /// The wrap's single `p` recipient, or null.
  static String? _wrapRecipient(Map<String, dynamic> raw) {
    final tags = raw['tags'];
    if (tags is! List) return null;
    for (final t in tags) {
      if (t is List && t.length >= 2 && t[0] == 'p') {
        return '${t[1]}'.toLowerCase();
      }
    }
    return null;
  }

  void _archiveGiftWrap(GiftWrapUnwrapped u) {
    // Never re-upload a wrap that came from the archive.
    if (u.fromArchive) return;
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return;
    final raw = u.rawWrap;
    if (raw == null) return;
    // Never archive wraps to Ghost Mode keys; the authed upload would link the ghost key to this account.
    final to = _wrapRecipient(raw);
    if (to != null && _ref.read(ghostModeProvider).pubkeys.contains(to)) {
      return;
    }
    final self = _identity?.pubkey;
    if (self == null) return;
    // Addressed to us → our inbox; to someone else → deposit into theirs.
    unawaited(sync.pmPut([raw]));
    sync.enqueueDeposit(raw, tier: WrapTier.normal);
  }

  /// Caps a channel list to the runtime limit before saving.
  List<Message> _capChannel(List<Message> msgs) =>
      msgs.length > _channelMessageLimit
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
    // `nym#xxxx` fallback, never 'anon'.
    final suffix =
        pubkey.length >= 4 ? pubkey.substring(pubkey.length - 4) : '????';
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

  // Composer attachments: Blossom upload and P2P file share.

  static String blossomAuthHeader(String hashHex, int nowSec) {
    final sk = keys.generatePrivateKey();
    final signed = schnorr.finalizeEvent(
      UnsignedEvent(
        pubkey: keys.getPublicKeyHex(sk),
        createdAt: nowSec,
        kind: EventKind.blossomAuth,
        tags: [
          ['t', 'upload'],
          ['x', hashHex],
          ['expiration', '${nowSec + 600}'],
        ],
        content: 'Uploading blob with SHA-256 hash',
      ),
      sk,
    );
    return 'Nostr ${base64.encode(utf8.encode(jsonEncode(signed.toJson())))}';
  }

  Future<String?> uploadImage(
    Uint8List bytes, {
    required String contentType,
    void Function(double progress)? onProgress,
  }) async {
    final identity = _identity;
    final sig = _signer;
    if (identity == null || sig == null) return null;

    onProgress?.call(0.15);
    // SHA-256 for the BUD-02 `x` tag.
    final hashHex = sha256Hex(bytes);
    onProgress?.call(0.55);

    final authHeader = blossomAuthHeader(
        hashHex, DateTime.now().millisecondsSinceEpoch ~/ 1000);

    final api = ApiClient();
    try {
      final done = await _blossomUploader.upload(kBlossomServers, contentType,
          (server, type) async {
        final data =
            await api.uploadBlob(bytes, server, authHeader, contentType: type);
        final url = data['url'];
        return url is String ? url : null;
      }, size: bytes.length);
      if (done == null) {
        lastUploadFailure = _blossomUploader.lastFailure;
        return null;
      }
      lastUploadFailure = '';
      onProgress?.call(1.0);
      final fallbacks = _ref.read(mediaFallbacksProvider);
      fallbacks.recordPredictedMirrors(done.url, [
        for (final s in kBlossomServers)
          if (s != done.server) predictMirrorUrl(s, hashHex, done.url),
      ]);
      unawaited(_mirrorBlobBackground(done.url, done.server, authHeader)
          .then((mirrors) => fallbacks.recordConfirmedMirrors(done.url, mirrors)));
      return done.url;
    } finally {
      api.dispose();
    }
  }

  final BlossomUploader _blossomUploader = BlossomUploader();
  String lastUploadFailure = '';

  /// Mirrors a blob to the other Blossom servers via the proxy with the same upload auth; best-effort.
  Future<List<String>> _mirrorBlobBackground(
    String primaryUrl,
    String excludeServer,
    String authHeader,
  ) async {
    final remaining = kBlossomServers.where((s) => s != excludeServer).toList();
    final mirrors = <String>[];
    if (remaining.isEmpty) return mirrors;
    final api = ApiClient();
    try {
      await Future.wait(remaining.map((server) async {
        try {
          final data = await api.mirrorBlob(primaryUrl, server, authHeader);
          final url = data['url'];
          if (url is String && url.isNotEmpty) mirrors.add(url);
        } catch (e) {
          debugPrint('Blossom mirror to $server failed: $e');
        }
      }));
    } finally {
      api.dispose();
    }
    return mirrors;
  }

  /// Shares [bytes] as a P2P file and announces the offer in the active conversation.
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

    // PM/group offers gift-wrap a normal message with the `offer` tag; the echo carries the shared nymMessageId.
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
      // buildPmRumor has no extra-tag seam, so append the offer tag here.
      final rumor = UnsignedEvent(
        pubkey: base.pubkey,
        createdAt: base.createdAt,
        kind: base.kind,
        tags: [...base.tags, fileOfferTag(offer)],
        content: base.content,
      );
      try {
        final peerKem = _pqLayeredPeerKey(view.id);
        final supportToken = pmSupportTokenFor(view.id);
        await service.publishPM(
          rumor: PmLogic.withSupportToken(rumor, supportToken),
          recipientPubkey: view.id,
          settings: _msgSettings,
          onWrap: _archiveSentWrap,
          recipientKemPublicKey: peerKem,
          recipientLayered: peerKem != null,
          selfKemPublicKey: pqSelfKey(),
          selfLayered: pqSelfUsesLayered(),
          wrapTags: PmLogic.supportWrapTags(supportToken),
        );
      } catch (_) {
        // The echo id isn't exposed here; leave the bubble as sent.
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
      _applyEphemeralKeys();
      // After a self-key rotation: persist, re-REQ the ephemeral sub, and sync so other devices can decrypt.
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
        extraTags: [fileOfferTag(offer)],
      );
      await service.publishGroupMessage(
        rumor: rumor,
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
        settings: _msgSettings,
        onWrap: _archiveSentWrap,
        kemKeyFor: _pqGroupKeyFor,
        layeredFor: _pqGroupLayeredFor,
      );
      return;
    }

    // Channel: local echo, then publish with the offer tag.
    final echo = appState.sendLocal(content, fileOffer: offer.toJson());
    if (identity == null || service == null) return;
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    // Hand-built so the offer tag can be appended to the base channel tags.
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
    // Reconcile the echo with the real id so the relay echo dedups.
    if (echo != null) {
      _ref.read(appStateProvider.notifier).replaceOptimistic(
            echo.id,
            signed.id,
            realCreatedAt: signed.createdAt,
            realMs: nowMs,
            powTarget: EventMapper.powTargetOf(signed),
          );
    }
  }

  // P2P signaling transport: plain kinds 25051/25052.

  Subscription? _p2pSub;

  /// Subscribes to plain P2P events p-tagged to us; returns an unsubscribe callback.
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

  /// Signs and publishes a plain (not gift-wrapped) P2P event.
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

  /// Publishes a NIP-56 report for [pubkey] (optionally [messageId]) and surfaces a system message.
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
      _emitSystemMessage(tr('Report submitted successfully'));
      return true;
    } catch (_) {
      _emitSystemMessage(tr('Failed to submit report'));
      return false;
    }
  }

  // Nymbot interception (`?` / @Nymbot).

  static const String nymbotPubkey =
      'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2';

  /// Used for the "Nymchat Developer" verified badge.
  static const String verifiedDeveloperPubkey =
      'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';

  bool isVerifiedDeveloper(String pubkey) => pubkey == verifiedDeveloperPubkey;

  /// Case-insensitive, so legacy-encoded ids still count for every bot-routing gate.
  bool isVerifiedBot(String pubkey) =>
      pubkey == nymbotPubkey || pubkey.toLowerCase() == nymbotPubkey;

  /// True when a channel message should route to Nymbot: `?` command, @Nymbot mention, or a reply to Nymbot.
  bool shouldRouteToBot(String text) {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return false;
    final canonical = canonicalizeCommandInput(text);
    if (isBotCommand(canonical) || isNymbotMention(text)) return true;
    final body = canonicalizeCommandInput(_quoteBody(text));
    if (body != text.trim() && (isBotCommand(body) || isNymbotMention(body))) {
      return true;
    }
    if (_quotedNymbotAuthor(text) != null && body.isNotEmpty) return true;
    // A plain reply in a thread Nymbot rooted or last spoke in continues that conversation.
    return body.isNotEmpty && _threadBotTarget() != null;
  }

  /// The open thread's root when replying in the current channel, else null, so sends are never mis-threaded.
  String? _composerThreadRoot() {
    if (!appThreadsEnabled) return null;
    final view = _ref.read(appStateProvider).view;
    if (view.kind != ViewKind.channel) return null;
    final at = _ref.read(activeThreadProvider);
    return (at != null && at.view == view) ? at.rootId : null;
  }

  /// The Nymbot message the open thread's next plain reply answers, or null; read before publishing.
  Message? _threadBotTarget() {
    final rootId = _composerThreadRoot();
    if (rootId == null) return null;
    final state = _ref.read(appStateProvider);
    return threadBotReplyTarget(state, state.view.storageKey, rootId);
  }

  /// Every line not starting with `>`, joined and trimmed.
  static String _quoteBody(String text) =>
      text.split('\n').where((l) => !l.startsWith('>')).join('\n').trim();

  /// The quoted author when replying to a Nymbot message, else null.
  static String? _quotedNymbotAuthor(String text) {
    final m = RegExp(r'^>\s*@([^:]+):').firstMatch(text);
    if (m == null) return null;
    final author = m.group(1)!.trim();
    return RegExp(r'^nymbot(#[a-f0-9]{4})?$', caseSensitive: false)
            .hasMatch(author)
        ? author
        : null;
  }

  /// Parses leading `> @Author: text` quote lines into `[{author, text}]` context for `?ask` / `?guess`.
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
    // Strip the wire envelope from Nymbot's own turns; the model writes it itself.
    final out = <Map<String, String>>[];
    for (final e in conversation) {
      final isBot = _rxNymbotAuthor.hasMatch((e['author'] ?? '').trim());
      final text = isBot
          ? threadEntryText(e['text'] ?? '', isBot: true)
          : (e['text'] ?? '');
      if (text.trim().isEmpty) continue;
      out.add({'author': e['author']!, 'text': text});
    }
    return out;
  }

  static final RegExp _rxNymbotAuthor =
      RegExp(r'^nymbot(?:#[0-9a-f]{4})?$', caseSensitive: false);

  /// Routes a channel message to Nymbot and publishes the worker-signed reply verbatim.
  Future<void> routeToBot(String rawText) async {
    final state = _ref.read(appStateProvider);
    final view = state.view;
    if (view.kind != ViewKind.channel) {
      await _sendMessageContent(rawText);
      return;
    }
    final request = await _botChannelRequest(rawText, _threadBotTarget());
    await _sendMessageContent(rawText);
    if (request == null) return;

    final identity = _identity;
    final senderNym = identity != null
        ? '${stripPubkeySuffix(identity.nym)}#${getPubkeySuffix(identity.pubkey)}'
        : null;
    final storageKey = view.storageKey;
    _setBotChannelThinking(storageKey, true);
    try {
      await _postBotChannelRequest(
          {...request, 'senderNym': ?senderNym}, storageKey);
    } catch (e) {
      _setBotChannelThinking(storageKey, false);
      debugPrint('Nymbot command failed: $e');
      _emitSystemMessage(tr('Nymbot is unavailable right now.'));
    }
  }

  static String? _quotedAuthor(String text) {
    final m = RegExp(r'^>\s*@([^:]+):').firstMatch(text);
    return m?.group(1)?.trim();
  }

  Future<Map<String, dynamic>?> _botChannelRequest(
      String rawText, Message? threadTarget,
      {bool anon = false}) async {
    final view = _ref.read(appStateProvider).view;
    final body = _quoteBody(rawText);
    var content =
        canonicalizeCommandInput(body.isNotEmpty ? body : rawText.trim());

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

    final threadRoot = _composerThreadRoot();
    final gameTokenRe = RegExp(r'\[gc:[A-Za-z0-9+/=]+\]');
    if (_quotedNymbotAuthor(rawText) != null && !content.startsWith('?')) {
      content = (gameTokenRe.hasMatch(rawText) ? '?guess ' : '?ask ') + content;
    } else if (threadTarget != null && !content.startsWith('?')) {
      content =
          (gameTokenRe.hasMatch(threadTarget.content) ? '?guess ' : '?ask ') +
              content;
    }

    final parsed = parseBotCommand(content);
    if (parsed == null) return null;

    final channelKey = view.id.startsWith('#') ? view.id.substring(1) : view.id;
    final storageKey = view.storageKey;
    final cmd = parsed.name;

    var conversation = const <Map<String, String>>[];
    if (cmd == 'ask' || cmd == 'guess') {
      if (threadRoot != null) {
        conversation = threadBotConversation(
            _ref.read(appStateProvider), storageKey, threadRoot,
            exclude: rawText);
      }
      if (conversation.isEmpty) conversation = _extractQuoteChain(rawText);
    }

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
      final ctxState = _ref.read(appStateProvider);
      channelMessages = _botChannelMessages(ctxState, contextKeys,
          allChannels: memoryCommands.contains(cmd), markPending: anon);
      activeUsers = _botActiveUsers(ctxState, contextKeys,
          allUsers: memoryCommands.contains(cmd));
      if (anon) {
        final scrubbed = anonNymbotScrubContext(
          messages: channelMessages,
          users: activeUsers,
          self: [?_identity?.pubkey, ctxState.selfPubkey],
        );
        channelMessages = scrubbed.messages;
        activeUsers = scrubbed.users;
      }
    }

    return {
      'command': cmd,
      'args': parsed.args,
      'geohash': channelKey,
      'conversation': conversation,
      'publishedContent': rawText,
      'channelMessages': channelMessages,
      'activeUsers': activeUsers,
      'threadRoot': ?threadRoot,
      'lang': LocalizationService.instance.language,
    };
  }

  Future<bool> _postBotChannelRequest(
      Map<String, dynamic> body, String storageKey) async {
    final api = _api ??= ApiClient();
    final data = await api.botAction(body);
    final event = data['event'];
    if (event is! Map) return false;
    final botEvent = NostrEvent.fromJson(Map<String, dynamic>.from(event));
    if (EventMapper.channelKeyOf(botEvent) == null) {
      _setBotChannelThinking(storageKey, false);
      return false;
    }
    final hook = botReplyPublishForTest;
    if (hook != null) {
      await hook(botEvent);
    } else {
      await _service?.pool.publish(botEvent);
    }
    return true;
  }

  /// Shows or clears the bot in a channel's typing strip (45s auto-expiry).
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

  /// Resolves `#channel` references in `?ask` args to storage keys, fetching unknown ones from D1 with a bounded wait.
  Future<Set<String>> _resolveReferencedChannels(String args) async {
    final names = <String>[];
    final refRx =
        RegExp(r'(?:^|[^a-z0-9])#([a-z0-9_-]+)', caseSensitive: false);
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
        // The sidebar may know a channel with no stored messages yet.
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
      // Brief bounded wait for the archive fetch.
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

  /// Newest messages per referenced channel for AI commands; in-memory commands send all stored messages.
  static const int _kBotContextMsgLimit = 100;

  List<Map<String, dynamic>> _botChannelMessages(
      AppState state, Set<String> keys,
      {required bool allChannels, bool markPending = false}) {
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
          if (markPending &&
              (m.optimistic || m.deliveryStatus == DeliveryStatus.failed))
            'pending': true,
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
    out.sort(
        (a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int));
    // Multi-channel merge keeps only the newest 100 overall.
    if (!allChannels && keys.length > 1 && out.length > _kBotContextMsgLimit) {
      return out.sublist(out.length - _kBotContextMsgLimit);
    }
    return out;
  }

  /// Active users for the bot context; AI commands include shop flair and style, in-memory commands bare entries.
  List<Map<String, dynamic>> _botActiveUsers(AppState state, Set<String> keys,
      {required bool allUsers}) {
    final rawNames = [
      for (final k in keys) k.startsWith('#') ? k.substring(1) : k,
    ];
    final out = <Map<String, dynamic>>[];
    state.users.forEach((pubkey, user) {
      final inChannel = allUsers ||
          user.channels.any((c) => rawNames
              .any((r) => c == r || c.startsWith(r) || r.startsWith(c)));
      if (inChannel && user.nym.isNotEmpty) {
        final entry = <String, dynamic>{
          'nym': '${stripPubkeySuffix(user.nym)}#${getPubkeySuffix(pubkey)}',
          'pubkey': pubkey,
        };
        if (!allUsers) {
          final items = _shopItemsFor(pubkey);
          entry['flair'] = (items != null && items.flair.isNotEmpty)
              ? items.flair.map((f) => f.replaceFirst('flair-', '')).join(',')
              : null;
          entry['style'] =
              (items != null && items.style != null && items.style!.isNotEmpty)
                  ? items.style!.replaceFirst('style-', '')
                  : null;
        }
        out.add(entry);
      }
    });
    return out;
  }

  /// A user's active shop items for the bot context: self from live state, others from the shop-status cache.
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

  /// Binds the private Nymbot chat to the live identity; returns whether it bound.
  bool bindBotChat() {
    final identity = _identity;
    if (identity == null) return false;
    // The privkey enables per-action NIP-98 auth; delegated signers fall back to the pre-supplied blob.
    final bot = _ref.read(botChatControllerProvider.notifier);
    bot.bind(
      pubkey: identity.pubkey,
      privkey: identity.privkey,
    );
    // `?clear` also purges the D1 PM archive and syncs the cleared-at/welcomed markers.
    bot.pmArchivePurger = purgeBotPmArchive;
    bot.settingsSyncRequester = syncSettings;
    bot.anonKeysChanged = _refreshEphemeralSubscriptions;
    _applyEphemeralKeys();
    return true;
  }

  /// Best-effort purge of the Nymbot thread's wraps from the D1 archive so a clear can't be restored anywhere.
  Future<void> purgeBotPmArchive(List<String> wrapIds) async {
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return;
    await sync.pmDelete(wrapIds);
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _liveInboundTimer?.cancel();
    _liveInboundTimer = null;
    _liveInboundBuffer.clear();
    // Drop buffered unwrapped gift-wraps; the session is tearing down.
    _cancelGiftWrapInbound();
    _settingsSyncTimer?.cancel();
    _profileBackfillTimer?.cancel();
    _pqRootWaitTimer?.cancel();
    _pqRootWaitTimer = null;
    _pqRootWaiters.clear();
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

/// Blossom upload servers in fallback order.
const List<String> kBlossomServers = [
  'https://blossom.band',
  'https://blossom.primal.net',
  'https://nostr.download',
];

final p2pServiceProvider = Provider<P2PService>((ref) {
  final controller = ref.read(nostrControllerProvider);
  final service = P2PService(_ControllerP2PTransport(controller));
  // Route transfer status into the conversation and subscribe now so a pure receiver is listening.
  service.onSystemMessage = (m) {
    try {
      showToast(m);
    } catch (_) {}
  };
  service.start();
  ref.onDispose(service.dispose);
  return service;
});

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

/// Bridges the pure [CommandDispatcher] to the controller's engine methods.
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
  void feedMessage(String text) => _c._emitFeedMessage(text);

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

/// Per-(messageId, emoji) timestamps within the window, plus cooldown-until ms.
class _ReactionRateTracker {
  final List<int> timestamps = [];
  int cooldownUntil = 0;
}

/// Edit re-publish tags: `['n', nym], [wire.tag, key], ['edit', id]`, where wire.tag is 'g' or 'd'.
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

/// Kind-5 deletion tags: `['e', id], ['k', origKind]`.
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

/// Boot generation; bumping it remounts a fresh [BootGate], standing in for the PWA's page reload.
final bootEpochProvider = StateProvider<int>((ref) => 0);

/// Cross-device settings sections awaiting accept/decline in settings.
final pendingSettingsTransfersProvider = StateNotifierProvider<
    PendingSettingsTransfersNotifier, List<SettingsTransferOffer>>((ref) {
  return PendingSettingsTransfersNotifier();
});

/// Holds offers newest-first.
class PendingSettingsTransfersNotifier
    extends StateNotifier<List<SettingsTransferOffer>> {
  PendingSettingsTransfersNotifier() : super(const []);

  void setOffers(List<SettingsTransferOffer> offers) {
    state = List.unmodifiable(offers);
  }

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

  void clear() => state = const [];
}

/// An inbound user-to-user settings transfer awaiting accept/reject.
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

  /// The gift-wrap event id, the key for accept/reject/dismiss.
  final String eventId;

  /// Sender pubkey (64-hex), verified against the rumor author.
  final String fromPubkey;

  /// Falls back to `<first8>...` of the pubkey.
  final String fromNym;

  final String? nickname;

  final String? avatarUrl;

  /// Flat transferable settings, minus device-local keys.
  final Map<String, dynamic> settings;

  /// Sender wall clock (unix seconds).
  final int transferredAt;
}

/// User-to-user settings transfers awaiting Accept/Reject.
final pendingUserSettingsTransfersProvider = StateNotifierProvider<
    PendingUserSettingsTransfersNotifier, List<UserSettingsTransfer>>((ref) {
  return PendingUserSettingsTransfersNotifier();
});

class PendingUserSettingsTransfersNotifier
    extends StateNotifier<List<UserSettingsTransfer>> {
  PendingUserSettingsTransfersNotifier() : super(const []);

  bool containsEventId(String eventId) =>
      state.any((t) => t.eventId == eventId);

  /// Appends a pending transfer; dedup is the caller's job.
  void add(UserSettingsTransfer transfer) {
    state = List.unmodifiable([...state, transfer]);
  }

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

  void clear() => state = const [];
}

/// Shared NIP-46 transport instance, reused so socket and pending-request state are shared.
final nip46ServiceProvider = Provider<Nip46Service>((ref) {
  final svc = Nip46Service(
    kv: _Nip46KvAdapter(ref.read(keyValueStoreProvider)),
    secure: _Nip46SecureAdapter(SecureStore()),
    // Lazily route NIP-46 through the shared relay pool when it covers the relay.
    poolProvider: () => ref.read(nostrControllerProvider).pool,
  );
  ref.onDispose(svc.dispose);
  return svc;
});

/// Dart abstract classes aren't structurally satisfied, hence the adapter.
class _Nip46KvAdapter implements Nip46KeyValueStore {
  _Nip46KvAdapter(this._kv);
  final KeyValueStore _kv;
  @override
  String? getString(String key) => _kv.getString(key);
  @override
  Future<void> setString(String key, String value) => _kv.setString(key, value);
}

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

/// A shared-history blob waiting for its group's bootstrap.
class _PendingGroupHistory {
  _PendingGroupHistory({
    required this.senderPubkey,
    required this.rumor,
    required this.stashedAtMs,
  });
  final String senderPubkey;
  final Map<String, dynamic> rumor;
  final int stashedAtMs;
}

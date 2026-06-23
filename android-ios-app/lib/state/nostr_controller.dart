import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/event_kinds.dart';
import '../core/constants/relays.dart';
import '../core/constants/storage_keys.dart';
import '../core/utils/nym_utils.dart';
import '../features/commands/action_rate_limit.dart';
import '../features/commands/command_handler.dart';
import '../features/commands/command_registry.dart';
import '../features/groups/group_logic.dart';
import '../features/groups/group_manager.dart';
import '../features/notifications/notifications_service.dart';
import '../features/shop/shop_controller.dart';
import '../features/nymbot/bot_commands.dart';
import '../features/nymbot/nymbot_providers.dart';
import '../features/nymbot/nymbot_service.dart';
import '../features/p2p/p2p_models.dart';
import '../features/p2p/p2p_service.dart';
import '../features/pms/pm_logic.dart';
import '../features/polls/poll_logic.dart';
import '../features/zaps/zap_logic.dart';
import '../services/api/api_client.dart';
import '../services/api/storage_sync.dart';
import '../services/relay/relay_message.dart';
import '../services/relay/relay_pool.dart';
import '../models/channel.dart';
import '../models/group.dart';
import '../models/message.dart';
import '../models/nostr_event.dart';
import '../models/poll.dart';
import '../models/user.dart';
import '../features/identity/nip46_service.dart';
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

  /// Shared [ApiClient] for the storage-sync paths (one instance, reused).
  ApiClient? _api;

  /// Debounce for the encrypted settings publish (settings.js
  /// `_debouncedNostrSettingsSave`, 5s).
  Timer? _settingsSyncTimer;

  /// Throttle: pubkey/groupId-scoped last typing-start send time (ms).
  final Map<String, int> _typingThrottle = {};

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

      final appState = _ref.read(appStateProvider.notifier);
      appState.goLive(identity.pubkey, identity.nym);

      // Restore friends / blocked users / blocked keywords from KV.
      _hydrateSocialState(appState);

      // Hydrate channel/profile/reaction caches before connecting (raced
      // ≤1500ms so a slow disk never blocks boot — mirrors app.js
      // `Promise.race([hydrateFromCache(), 1500ms])`).
      await _hydrateFromCache(appState).timeout(
        const Duration(milliseconds: 1500),
        onTimeout: () {},
      );

      final service = NostrService(identity: identity, signer: signer);
      _service = service;
      _groups = GroupManager(service);
      await service.start(NostrHandlers(
        onEvent: _onEvent,
        onConnectionChanged: appState.setConnectedRelays,
        onGiftWrap: _onGiftWrap,
      ));

      // Broadcast presence on connect, then re-assert on a timer
      // (nostr-core.js: presence on connect + on a 60s cadence).
      recordOwnActivity();
      _startPresenceTimer();

      // Cross-device storage sync (`/api/storage`). Durable = logged-in
      // (loginMethod != null, the PWA's `isNostrLoggedIn()`); ephemeral
      // identities skip the durable PM archive. All calls are best-effort.
      _initStorageSync(identity, signer);
      unawaited(_bootStorageSync());
    } catch (e, st) {
      // Stay on seed/offline data if boot fails (e.g. no secure storage).
      debugPrint('NostrController.init failed: $e\n$st');
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

  MessagingSettings get _msgSettings {
    final s = _ref.read(settingsProvider);
    return MessagingSettings(
      dmForwardSecrecyEnabled: s.dmForwardSecrecyEnabled,
      dmTtlSeconds: s.dmTtlSeconds,
    );
  }

  bool _readReceiptsAllowed() =>
      _ref.read(settingsProvider).readReceiptsScope != 'disabled';
  bool _typingAllowed() =>
      _ref.read(settingsProvider).typingIndicatorsScope != 'disabled';

  // ---------------------------------------------------------------------------
  // Inbound routing
  // ---------------------------------------------------------------------------

  void _onEvent(NostrEvent event) {
    final appState = _ref.read(appStateProvider.notifier);
    if (event.kind == EventKind.appData) {
      _ingestPresence(event);
      return;
    }
    // A live kind-0 from relays refreshes the D1 profile cache so we don't
    // re-issue a `profile-get` for a profile we just received (mirrors the PWA's
    // `profileFetchedAt` freshness gate).
    if (event.kind == EventKind.profile) {
      _storageSync?.markProfileCached(event.pubkey);
    }
    appState.ingestEvent(event);
    // Channel-message notification: a public channel message that @-mentions us
    // (nostr-core.js channel `shouldNotify`). Runs after ingest so the store is
    // current; gating happens in `_maybeNotifyChannel`.
    if (event.kind == EventKind.geoChannel ||
        event.kind == EventKind.namedChannel) {
      _maybeNotifyChannel(event);
    }
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
    final notify = shouldNotify(
      kind: NotifyKind.channel,
      isOwn: isOwn,
      isHistorical: _isHistorical(e.createdAt),
      notificationsEnabled: _notificationsEnabled,
      isMention: mention,
      isFriend: appState.isFriend(e.pubkey),
      isBlocked: isBlocked,
      isActiveView: key != null && _isActiveView(key),
      friendsOnly: _notifyFriendsOnly,
    );
    if (!notify) return;
    _dispatchNotification(
      title: _nymDisplayFor(e.pubkey),
      body: e.content,
      senderPubkey: e.pubkey,
      isFriend: appState.isFriend(e.pubkey),
      isMention: mention,
    );
  }

  /// PM/group notification gate for an ingested [Message] (mirrors the PWA's
  /// PM/group `showNotification` calls). PMs always notify; group messages
  /// notify unless mentions-only is on and the message isn't a mention.
  void _maybeNotifyMessage(Message m, {required bool isGroup}) {
    final appState = _ref.read(appStateProvider);
    final mention = _mentionsSelf(m.content);
    final key = m.conversationKey ??
        (isGroup
            ? GroupLogic.groupStorageKey(m.groupId ?? '')
            : (m.conversationPubkey != null
                ? PmLogic.pmStorageKey(m.conversationPubkey!)
                : ''));
    final notify = shouldNotify(
      kind: isGroup ? NotifyKind.group : NotifyKind.pm,
      isOwn: m.isOwn,
      isHistorical: _isHistorical(m.createdAt),
      notificationsEnabled: _notificationsEnabled,
      isMention: mention,
      isFriend: appState.isFriend(m.pubkey),
      isBlocked: appState.blockedUsers.contains(m.pubkey),
      isActiveView: _isActiveView(key),
      friendsOnly: _notifyFriendsOnly,
      groupMentionsOnly: _groupNotifyMentionsOnly,
    );
    if (!notify) return;
    _dispatchNotification(
      title: _nymDisplayFor(m.pubkey),
      body: m.content,
      senderPubkey: m.pubkey,
      isFriend: appState.isFriend(m.pubkey),
      isMention: mention,
      isGroup: isGroup,
    );
  }

  /// Fires the notification (sound + local) via the notifications service.
  void _dispatchNotification({
    required String title,
    required String body,
    required String senderPubkey,
    required bool isFriend,
    required bool isMention,
    bool isGroup = false,
  }) {
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
          ),
        ));
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
    // Shop cosmetics: the PWA's `shop-update` tag is a cache-bust flag and the
    // real items come from the backend; the native build reads the inlined
    // shop-style/flair/supporter tags (see PresenceCosmetics). When a
    // `shop-update` arrives without inlined tags, the cosmetics are cleared.
    final hasShopUpdate =
        e.tagsNamed('shop-update').any((t) => t.length > 1 && t[1] == '1');
    _ref.read(appStateProvider.notifier).setUserPresence(
          pubkey: e.pubkey,
          status: userStatusFromString(statusStr),
          nym: nym,
          awayMessage: away,
          lastSeenMs: e.createdAt * 1000,
          avatarUrl: avatar,
          hasAvatarTag: avatar != null,
          shopUpdate: hasShopUpdate,
          shopStyle: e.tagValue('shop-style'),
          shopFlair: e.tagValue('shop-flair'),
          isSupporter: e.tagsNamed('shop-supporter')
              .any((t) => t.length > 1 && t[1] == '1'),
        );
  }

  /// Per-pubkey newest presence timestamp (users.js `presenceTimestamps`) so a
  /// redelivered/older replaceable presence event can't clobber a newer one.
  final Map<String, int> _presenceTimestamps = {};

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
        _onPrivateZap(rumor, appState);
      case EventKind.callSignaling: // 25053 — call signaling transport
        if (u.senderVerified) _callSignalHandler?.call(rumor);
      case EventKind.friendPresence: // 25054 — friends-only private presence
        if (u.senderVerified) _onFriendPresence(rumor, appState);
      default:
        break;
    }
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
  }

  void _onRumorMessage(
      GiftWrapUnwrapped u, AppStateNotifier appState, String self) {
    final rumor = u.rumor;
    final tags = _tags(rumor);
    final groupId = _tagValue(tags, 'g');
    final type = _tagValue(tags, 'type');
    final senderPubkey = rumor['pubkey'] as String? ?? '';

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

    // Group message.
    if (groupId != null) {
      if (!u.senderVerified) return;
      final m = _mapGroupMessage(rumor, u, self, groupId);
      if (m == null) return;
      appState.ingestGroupMessage(m);
      _maybeNotifyMessage(m, isGroup: true);
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
    appState.ingestPMMessage(m);
    _maybeNotifyMessage(m, isGroup: false);
    // Delivery receipt back to the sender (not for our own self-copy).
    if (!m.isOwn && m.nymMessageId != null) {
      _service?.publishReceipt(
        messageId: m.nymMessageId!,
        receiptType: 'delivered',
        recipientPubkey: m.pubkey,
      );
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
    // Bootstrap invite: create the local group if we don't have it yet.
    if (type == GroupControlType.invite) {
      if (appState.groupById(groupId) != null) return;
      final members = tags
          .where((t) => t.length > 1 && t[0] == 'p')
          .map((t) => t[1])
          .toList();
      final owner = _tagValue(tags, 'owner') ?? senderPubkey;
      final name = _tagValue(tags, 'subject') ?? '';
      appState.upsertGroup(Group(
        id: groupId,
        name: name,
        members: members,
        createdBy: owner,
        allowMemberInvites: _tagValue(tags, 'allow_invites') != '0',
        inviteEnabled: _tagValue(tags, 'invite_enabled') == '1',
        inviteEpoch: int.tryParse(_tagValue(tags, 'invite_epoch') ?? '') ?? 0,
        lastMessageTime: DateTime.now().millisecondsSinceEpoch,
      ));
      return;
    }

    final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
    appState.applyGroupControl(
      groupId: groupId,
      type: type,
      tags: tags,
      senderPubkey: senderPubkey,
      ts: ts,
      eventId: u.wrapId,
    );
  }

  void _onReceiptOrTyping(
      Map<String, dynamic> rumor, AppStateNotifier appState) {
    if (PmLogic.isTyping(rumor)) {
      final info = PmLogic.parseTyping(rumor);
      if (info == null || info.pubkey == null) return;
      // Stale typing indicators are dropped.
      final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 -
          ((rumor['created_at'] as num?)?.toInt() ?? 0);
      if (age > 8) return;
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
      if (info != null) appState.applyReceipt(info);
    }
  }

  void _onPrivateReaction(
      Map<String, dynamic> rumor, AppStateNotifier appState) {
    // Reactions land in app_state's reaction store via a synthetic event.
    final tags = _tags(rumor);
    final target = _tagValue(tags, 'e');
    if (target == null) return;
    final pubkey = rumor['pubkey'] as String? ?? '';
    final content = rumor['content'] as String? ?? '';
    final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
    final action = tags.any((t) => t.length > 1 && t[0] == 'action' && t[1] == 'remove');
    final synthetic = NostrEvent(
      pubkey: pubkey,
      createdAt: ts,
      kind: EventKind.reaction,
      tags: [
        ['e', target],
        ['p', pubkey],
        if (action) ['action', 'remove'],
      ],
      content: content,
    );
    appState.ingestEvent(synthetic);
  }

  /// Routes a gift-wrapped private zap announcement (kind 9735 rumor, sent to
  /// PM/group members). Accrues sats to the zapped message's aggregate. The
  /// rumor carries an `['e', msgId]`, `['p', recipient]`, `['bolt11', …]`.
  void _onPrivateZap(Map<String, dynamic> rumor, AppStateNotifier appState) {
    final tags = _tags(rumor);
    final messageId = _tagValue(tags, 'e');
    final bolt11 = _tagValue(tags, 'bolt11');
    if (messageId == null || bolt11 == null) return;
    final amount = ZapLogic.parseAmountFromBolt11(bolt11);
    if (amount == null) return;
    appState.recordMessageZap(
      messageId: messageId,
      zapperPubkey: rumor['pubkey'] as String? ?? '',
      amountSats: amount,
      dedupKey: ZapLogic.dedupKey(bolt11: bolt11, eventId: ''),
    );
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
  Future<bool> sendCallSignal({
    required String to,
    required Map<String, dynamic> payload,
  }) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.callSignaling,
      tags: [
        ['p', to],
      ],
      content: jsonEncode(payload),
    );
    return service.publishGiftWrappedRumor(rumor: rumor, recipients: [to]);
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
      appState.sendLocal(trimmed);
      if (service == null || identity == null) return;
      final isGeo = state.channels
          .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
      await service.publishChannelMessage(
        channelKey: view.id,
        content: trimmed,
        nym: identity.nym,
        geohash: isGeo ? view.id : null,
      );
      return;
    }

    if (view.kind == ViewKind.pm) {
      final nymMessageId = PmLogic.generateSharedEventId();
      appState.sendLocal(trimmed, nymMessageId: nymMessageId);
      if (service == null || identity == null) return;
      final rumor = PmLogic.buildPmRumor(
        selfPubkey: identity.pubkey,
        recipientPubkey: view.id,
        content: trimmed,
        nymMessageId: nymMessageId,
      );
      await service.publishPM(
        rumor: rumor,
        recipientPubkey: view.id,
        settings: _msgSettings,
      );
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
      final nymMessageId = GroupLogic.generateGroupId();
      appState.sendLocal(trimmed, nymMessageId: nymMessageId);
      final rumor = GroupLogic.buildGroupMessageRumor(
        group: group,
        selfPubkey: identity.pubkey,
        content: trimmed,
        nymMessageId: nymMessageId,
        ephemeralPk: next.pk,
      );
      await service.publishGroupMessage(
        rumor: rumor,
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
        settings: _msgSettings,
      );
    }
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
  /// shell's job.
  void cmdQuit() {
    _emitSystemMessage('Disconnecting from Nymchat...');
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
  void startPM(String peerPubkey, {String? nym}) {
    final appState = _ref.read(appStateProvider.notifier);
    appState.ensurePMConversation(peerPubkey, nym: nym);
    appState.switchView(ChatView.pm(peerPubkey));
  }

  /// Creates a group with [memberPubkeys], registers it locally, and switches.
  Future<Group?> createGroup(String name, List<String> memberPubkeys) async {
    final service = _service;
    final identity = _identity;
    final groups = _groups;
    if (service == null || identity == null || groups == null) return null;
    final group = await groups.createGroup(
      selfPubkey: identity.pubkey,
      name: name,
      memberPubkeys: memberPubkeys,
      settings: _msgSettings,
    );
    if (group == null) return null;
    final appState = _ref.read(appStateProvider.notifier);
    appState.upsertGroup(group);
    appState.switchView(ChatView.group(group.id));
    return group;
  }

  /// Stub: join via an invite link (parsed token). Wired in a later slice — the
  /// approver-side `group-join-request` flow is not yet implemented.
  Future<void> joinGroupViaInvite(GroupInviteToken token) async {
    debugPrint('joinGroupViaInvite not yet implemented: ${token.groupId}');
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
  /// `promoteModerator` → `group-promote-mod`.
  Future<bool> promoteModerator(String groupId, String targetPubkey) =>
      _sendModRoleControl(
          groupId, targetPubkey, GroupControlType.promoteMod, ['promote', targetPubkey]);

  /// Revokes [targetPubkey]'s moderator role (owner-only). users.js
  /// `revokeModerator` → `group-revoke-mod`.
  Future<bool> revokeModerator(String groupId, String targetPubkey) =>
      _sendModRoleControl(
          groupId, targetPubkey, GroupControlType.revokeMod, ['revoke', targetPubkey]);

  /// Transfers ownership to [targetPubkey] (owner-only). users.js
  /// `transferOwner` → `group-transfer-owner`.
  Future<bool> transferOwner(String groupId, String targetPubkey) =>
      _sendModRoleControl(groupId, targetPubkey, GroupControlType.transferOwner,
          ['new_owner', targetPubkey]);

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
    final extraTags = [
      ['delete', messageId],
      ['p', authorPubkey],
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
      _emitSystemMessage('Blocked ${_nymDisplayFor(pubkey)}');
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
    final u = _ref.read(appStateProvider).users[pubkey];
    final base = stripPubkeySuffix(u?.nym ?? 'anon');
    return '$base#${getPubkeySuffix(pubkey)}';
  }

  // --- presence / typing / receipts -----------------------------------------

  /// Last public presence broadcast (ms). Throttles `recordOwnActivity` relay
  /// broadcasts to ≤1/60s (nostr-core.js `_lastPresenceBroadcast`).
  int _lastPresenceBroadcast = 0;

  /// Periodic presence re-assertion timer (nostr-core.js broadcasts presence on
  /// a timer + on activity). Cancelled on dispose.
  Timer? _presenceTimer;

  static const int _presenceBroadcastThrottleMs = 60000;

  /// The status-visibility mode from `nym_show_status`
  /// ('true'|'friends'|'false') → PresenceStatusMode (PWA `_statusMode`).
  PresenceStatusMode get _statusMode =>
      presenceStatusModeFrom(_ref.read(settingsProvider).showStatus);

  /// The self user's active shop cosmetics, read from the shop controller so a
  /// presence `shop-update` carries renderable flair (see PresenceCosmetics).
  PresenceCosmetics _selfCosmetics() {
    final active = _ref.read(shopControllerProvider).active;
    return PresenceCosmetics(
      style: active.style,
      flair: active.flair.isNotEmpty ? active.flair.last : null,
      supporter: active.supporter,
    );
  }

  /// Publishes our presence (kind-30078 nym-presence). [status] is our real
  /// status; the service computes the public status from [_statusMode]. Always
  /// carries the avatar + shop-update tags so others can render our latest
  /// avatar/flair from the single replaceable event.
  Future<void> publishPresence(String status, {String awayMessage = ''}) async {
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
      shopUpdate: true,
      cosmetics: _selfCosmetics(),
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
  /// see us as recently active. Called on connect, on every send, and on the
  /// presence timer. Throttles relay broadcasts to ≤1/60s; skipped while away or
  /// when status is disabled (nostr-core.js `recordOwnActivity`).
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

  /// Starts the periodic presence re-assertion timer (idempotent).
  void _startPresenceTimer() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(
      const Duration(milliseconds: _presenceBroadcastThrottleMs),
      (_) => recordOwnActivity(),
    );
  }

  /// Signals typing in the current PM/group view (throttled ~1/s).
  Future<void> sendTypingStart() async {
    if (!_typingAllowed()) return;
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;
    final state = _ref.read(appStateProvider);
    final view = state.view;
    if (view.kind == ViewKind.channel) return;

    final key = view.storageKey;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_typingThrottle[key] ?? 0) < 1000) return;
    _typingThrottle[key] = now;

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

  /// Sends a read receipt for [messageId] to [peerPubkey] (PM scope-gated).
  Future<void> sendReadReceipt(String messageId, String peerPubkey) async {
    if (!_readReceiptsAllowed()) return;
    final service = _service;
    if (service == null) return;
    await service.publishReceipt(
      messageId: messageId,
      receiptType: 'read',
      recipientPubkey: peerPubkey,
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

    // Mirror the signed kind-0 to D1 (`profile-set`) in addition to the relay
    // publish, so other clients get a fast public read (`_saveProfileToD1`,
    // nostr-core.js:194). Only durable identities mirror (the PWA gates on
    // `_hasCustomProfileData`; durable = logged-in is the native analogue).
    final sync = _storageSync;
    if (sync != null && sync.durableIdentity) {
      unawaited(sync.profileSet(signed.toJson()));
    }
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
  }

  /// Adds [channel] to the registry + persists (`addChannel`).
  ChannelEntry addChannel(String channel, {String geohash = ''}) {
    final entry =
        _ref.read(appStateProvider.notifier).addChannel(channel, geohash: geohash);
    _persistJoinedChannels();
    return entry;
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

  void _subscribeActiveChannelTyping() {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return;
    final entry =
        state.channels.where((c) => c.key == state.view.id.toLowerCase());
    if (entry.isEmpty || !entry.first.isGeohash) return;
    _service?.subscribeChannelTyping(entry.first.geohash);
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

  // ---------------------------------------------------------------------------
  // Persistence hydration / flush
  // ---------------------------------------------------------------------------

  Future<void> _hydrateFromCache(AppStateNotifier appState) async {
    try {
      final cache = CacheStore();
      await cache.open();
      _cache = cache;
      // Load stores in parallel (mirrors hydrateFromCache's Promise.all).
      final results = await Future.wait([
        cache.loadAllProfiles(),
        cache.loadAllReactions(),
      ]);
      final profiles = results[0] as Map<String, UserProfile>;
      final reactions = results[1] as Map<String, List<dynamic>>;
      if (profiles.isNotEmpty) appState.hydrateProfiles(profiles);
      if (reactions.isNotEmpty) appState.hydrateReactions(reactions);
      // Channel/PM message rehydration happens lazily as channels are opened
      // (loadChannelMessages); the cache is wired so saves persist 1000 caps.
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
    if (_flushScheduled) return;
    _flushScheduled = true;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 6), () {
      _flushScheduled = false;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    final cache = _cache;
    if (cache == null) return;
    final state = _ref.read(appStateProvider);
    final cachePms = _ref.read(settingsProvider).cachePMs;
    try {
      for (final key in _dirtyChannelKeys.toList()) {
        final msgs = state.messages[key];
        if (msgs != null) {
          await cache.saveChannelMessages(key, _capChannel(msgs));
        }
      }
      _dirtyChannelKeys.clear();
      for (final key in _dirtyPmKeys.toList()) {
        final msgs = state.messages[key];
        if (msgs != null) {
          await cache.savePmMessages(key, _capPm(msgs), enabled: cachePms);
        }
      }
      _dirtyPmKeys.clear();
      // Profiles + reactions.
      for (final entry in state.users.entries) {
        final p = entry.value.profile;
        if (p != null) await cache.saveProfile(entry.key, p);
      }
      final reactionEntries =
          _ref.read(appStateProvider.notifier).reactionEntriesSnapshot();
      for (final e in reactionEntries.entries) {
        await cache.saveReactions(e.key, e.value);
      }
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
    // Local-key auth builder: sign a kind-27235 event bound to the storage URL +
    // action (Nip98Auth mirrors `_signBotAuth`). Only the local-key path can
    // sign synchronously; a NIP-46 remote signer returns null (auth omitted →
    // the worker rejects, tolerated as best-effort for remote-signer accounts).
    final local = signer is LocalSigner ? signer : null;
    sync.setAuthBuilder((action) {
      final l = local;
      if (l == null) return null;
      return Nip98Auth.build(
        action: action,
        url: StorageSync.storageUrl(),
        privkey: l.privkey,
        pubkey: identity.pubkey,
      );
    });
    _storageSync = sync;

    // Fire a debounced encrypted-settings publish whenever a synced setting
    // changes (the PWA's `nostrSettingsSave()` peppered through every setter).
    _ref.read(settingsProvider.notifier).onSyncedChange = syncSettings;
  }

  /// Boot-time sync: merge cross-device encrypted settings (honoring
  /// `nym_last_settings_sync_ts`), then restore the PM backlog from D1 for
  /// durable identities (gated by `cachePMs`). Both best-effort.
  Future<void> _bootStorageSync() async {
    final sync = _storageSync;
    if (sync == null) return;
    await _mergeRemoteSettings(sync);
    await _restorePmArchive(sync);
  }

  /// `settings-get` → merge into the local [Settings] when the remote blob is
  /// newer than the stored sync ts (settings.js `settingsLoadFromD1`).
  Future<void> _mergeRemoteSettings(StorageSync sync) async {
    try {
      final result = await sync.settingsGet();
      if (result == null) return;
      final kv = _ref.read(keyValueStoreProvider);
      final lastTs = int.tryParse(
              kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ??
          0;
      // The stored ts is in seconds (PWA); newestTs is ms. Compare in seconds.
      final newestSec = result.newestTs ~/ 1000;
      if (newestSec <= lastTs) return;
      _applySyncedSettings(result.payload);
      kv.setString(StorageKeys.lastSettingsSyncTs, '$newestSec');
    } catch (_) {
      // Best-effort.
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
    integer('textSize', c.setTextSize);
    boolean('transparencyEnabled', c.setTransparencyEnabled);
    boolean('dmForwardSecrecyEnabled', c.setDmForwardSecrecy);
    integer('dmTTLSeconds', c.setDmTtlSeconds);
    str('readReceiptsScope', c.setReadReceiptsScope);
    str('typingIndicatorsScope', c.setTypingIndicatorsScope);
    str('acceptPMs', c.setAcceptPMs);
    str('acceptCalls', c.setAcceptCalls);
    boolean('groupChatPMOnlyMode', c.setGroupChatPMOnlyMode);
    str('translateLanguage', c.setTranslateLanguage);
    boolean('gesturesEnabled', c.setGesturesEnabled);
    str('swipeLeftAction', c.setSwipeLeftAction);
    str('swipeRightAction', c.setSwipeRightAction);
    integer('swipeThreshold', c.setSwipeThreshold);
    str('swipeReactEmoji', c.setSwipeReactEmoji);
    boolean('sortByProximity', c.setSortByProximity);
    boolean('lowDataMode', c.setLowDataMode);
    boolean('cachePMs', c.setCachePMs);
    // showStatus arrives as bool|'friends' (settings.js normalization).
    final ss = p['showStatus'];
    if (ss is bool) {
      c.setShowStatus(ss ? 'true' : 'false');
    } else if (ss == 'friends') {
      c.setShowStatus('friends');
    }
  }

  /// Debounced encrypted-settings publish (`_debouncedNostrSettingsSave`, 5s).
  /// Call after any synced-setting change. No-op when storage sync is
  /// unavailable. The PWA also skips ephemeral random/hardcore keypair modes;
  /// here a missing signer (no local/remote auth) simply no-ops the upload.
  void syncSettings() {
    final sync = _storageSync;
    if (sync == null) return;
    _settingsSyncTimer?.cancel();
    _settingsSyncTimer = Timer(const Duration(seconds: 5), () {
      unawaited(_flushSettingsSync(sync));
    });
  }

  Future<void> _flushSettingsSync(StorageSync sync) async {
    try {
      await sync.settingsSet(_ref.read(settingsProvider));
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
    // Lightweight fallback display name when no profile is known.
    final suffix = pubkey.length >= 4 ? pubkey.substring(pubkey.length - 4) : '????';
    return 'anon#$suffix';
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
      kind: EventKind.httpAuth, // 24242 BUD auth (event_kinds.dart)
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

    final state = _ref.read(appStateProvider);
    final view = state.view;
    final content =
        'Sharing file through Nymchat: ${offer.name} (${formatFileSize(offer.size)})';

    // Local echo as a file-offer message (displayMessage isFileOffer path).
    _ref.read(appStateProvider.notifier).sendLocal(content);

    if (identity == null || service == null) return;
    if (view.kind != ViewKind.channel) {
      // PM/group offers gift-wrap the message with the offer tag; not yet wired
      // for the native PM path. TODO(verify): carry ['offer', …] on the PM rumor.
      return;
    }
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

  // ---------------------------------------------------------------------------
  // Nymbot interception (`?`/@Nymbot) — commands.js `_handleBotCommand`
  // ---------------------------------------------------------------------------

  /// The verified Nymbot pubkey (`verifiedBot.pubkey`, app.js:1096).
  static const String nymbotPubkey =
      'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2';

  /// True when [text] in a CHANNEL view should be routed to Nymbot instead of
  /// published as a normal message: a `?` command or an `@Nymbot` mention
  /// (messages.js:2381). PM/group views never intercept (the channel bot
  /// commands aren't wired for the paid PM surface — commands.js:438).
  bool shouldRouteToBot(String text) {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return false;
    return isBotCommand(text) || isNymbotMention(text);
  }

  /// Routes a channel message to Nymbot: resolves `@Nymbot …` to `?ask …`
  /// (commands.js:14), gathers the channel geohash + recent messages + active
  /// users for the AI-aware commands, POSTs via [NymbotService.sendPublicCommand],
  /// and surfaces the reply as a bot message in the channel.
  ///
  /// In the PWA the worker returns a *signed* event the client publishes to
  /// relays, so the reply arrives back through the channel subscription. Here we
  /// surface the reply text directly. TODO(verify): the native worker contract
  /// returns `{event}`; if a future flow needs the relay round-trip, publish the
  /// returned event instead of injecting locally.
  Future<void> routeToBot(String rawText) async {
    final state = _ref.read(appStateProvider);
    final view = state.view;
    if (view.kind != ViewKind.channel) {
      await _sendMessageContent(rawText);
      return;
    }

    // @Nymbot mention → ?ask <question> (commands.js:14).
    var content = rawText.trim();
    if (!isBotCommand(content) && isNymbotMention(content)) {
      final question = stripNymbotMention(content);
      if (question.isEmpty) {
        await _sendMessageContent(rawText); // nothing to ask
        return;
      }
      content = '?ask $question';
    }

    final parsed = parseBotCommand(content);
    if (parsed == null) {
      await _sendMessageContent(rawText);
      return;
    }

    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    final geohash = isGeo ? view.id : null;
    final storageKey = view.storageKey;
    final cmd = parsed.name;

    // Channel context for the AI-aware commands (commands.js:46-191).
    List<Map<String, dynamic>>? channelMessages;
    List<Map<String, dynamic>>? activeUsers;
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
      final service = _ref.read(nymbotServiceProvider);
      final reply = await service.sendPublicCommand(
        cmd,
        parsed.args,
        geohash: geohash,
        senderNym: senderNym,
        publishedContent: rawText,
        channelMessages: channelMessages,
        activeUsers: activeUsers,
      );
      _injectBotReply(reply, geohash: geohash, channelKey: view.id);
    } catch (e) {
      debugPrint('Nymbot command failed: $e');
      _emitSystemMessage('Nymbot is unavailable right now.');
    }
  }

  /// Injects Nymbot's reply as a verified-bot channel message via the public
  /// `ingestEvent` path (a synthetic signed-looking event from [nymbotPubkey]).
  void _injectBotReply(String reply,
      {String? geohash, required String channelKey}) {
    if (reply.trim().isEmpty) return;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final isGeo = geohash != null && geohash.isNotEmpty;
    final event = NostrEvent(
      pubkey: nymbotPubkey,
      createdAt: nowSec,
      kind: isGeo ? EventKind.geoChannel : EventKind.namedChannel,
      tags: [
        ['n', 'Nymbot'],
        [isGeo ? 'g' : 'd', isGeo ? geohash : channelKey],
      ],
      content: reply,
    );
    event.id = event.computeId();
    _ref.read(appStateProvider.notifier).ingestEvent(event);
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

  /// Active users in the channel mapped to `{nym,pubkey}` (commands.js:155/185).
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
        out.add({
          'nym':
              '${stripPubkeySuffix(user.nym)}#${getPubkeySuffix(pubkey)}',
          'pubkey': pubkey,
        });
      }
    });
    return out;
  }

  /// Binds the private Nymbot chat to the live identity (so the paid PM surface
  /// can authenticate) and returns whether a bind happened. The composer calls
  /// this before opening `BotChatScreen`.
  bool bindBotChat() {
    final identity = _identity;
    if (identity == null) return false;
    _ref.read(botChatControllerProvider.notifier).bind(pubkey: identity.pubkey);
    return true;
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _presenceTimer?.cancel();
    _settingsSyncTimer?.cancel();
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

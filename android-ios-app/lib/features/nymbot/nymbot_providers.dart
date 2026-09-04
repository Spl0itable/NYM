/// Riverpod wiring for the Nymbot feature: the [NymbotService] singleton, the
/// private-chat engine, and the `?`/`@Nymbot` interception helpers.
///
/// The private Nymbot conversation lives in the CANONICAL PM store
/// (`AppState.messages['pm-<botPubkey>']`), exactly like the PWA keeps it in
/// `pmMessages` (pms.js:1291-1339) — so the bot thread renders through the same
/// message pipeline as every other PM (sidebar row, unread counts, receipts,
/// reactions, system messages, typing indicator). [BotChatController] is the
/// port of the PWA's `_handleBotPM` / `_handleBotGitCommand` /
/// `_handleBotModelCommand` / `_handleBotTransferCommand` engine (pms.js).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/crypto/key_format.dart' show normalizePubkeyInput;
import '../../core/crypto/gift_wrap.dart' as giftwrap;
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../models/nostr_event.dart';
import '../../services/api/api_client.dart' show Nip98Auth;
import '../../services/nostr/event_signer.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart' show nostrControllerProvider;
import '../../state/settings_provider.dart';
import '../../widgets/context_menu/interaction_hooks.dart'
    show giftCreditsRequestProvider;
import '../i18n/localization_service.dart';
import '../i18n/i18n.dart';
import '../pms/pm_logic.dart';
import '../shop/shop_controller.dart' show shopControllerProvider;
import '../commands/command_i18n.dart';
import 'bot_commands.dart';
import 'nymbot_models.dart';
import '../../services/storage/secure_store.dart';
import 'anon_bot.dart';
import 'nymbot_service.dart';

// =============================================================================
// Interception helpers (pure — safe to call from the composer hot path)
// =============================================================================

/// True when [text] is a Nymbot public command, i.e. begins with `?` followed
/// by a non-space character. (`?` alone, or `? foo`, is not a command.)
///
/// Matches the worker/PWA rule: a leading `?` then a command token.
bool isBotCommand(String text) {
  final t = text.trimLeft();
  return t.length >= 2 && t[0] == '?' && !_isSpace(t[1]);
}

/// True when [text] mentions `@Nymbot` (case-insensitive), which routes the
/// message to `?ask` (README line 179: also triggered via an `@Nymbot`
/// mention followed by the question). The mention may appear anywhere.
bool isNymbotMention(String text) => _nymbotMention.hasMatch(text);

/// `@Nymbot` as a word (not part of a longer handle like `@Nymbotz`),
/// optionally carrying the `#xxxx` pubkey discriminator the mention flair now
/// serializes on the wire (`@Nymbot#4bb2`, autocomplete_queries.dart). Without
/// swallowing that suffix, [stripNymbotMention] left `#4bb2` behind and the bot
/// answered its own discriminator instead of the intended question.
final RegExp _nymbotMention = RegExp(
    r'(^|[^A-Za-z0-9_])@Nymbot(?:#[0-9a-f]{4})?\b',
    caseSensitive: false);

/// Strips a leading `@Nymbot` mention (and its optional `#xxxx` discriminator)
/// and returns the remaining question text, for turning `@Nymbot what is nostr`
/// into the `?ask` args `what is nostr`. A bare `@Nymbot#4bb2` (mention only)
/// yields the empty string so [routeToBot] falls back to the quoted text.
String stripNymbotMention(String text) =>
    text.replaceFirst(_nymbotMention, '').trim();

bool _isSpace(String ch) => ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';

/// The bot-PM control commands that are handled entirely ON-DEVICE — they are
/// never encrypted, published to relays, shown as message bubbles, or stored
/// (`?git` can carry an access token). A 1:1 port of the interception regex in
/// the PWA's `sendPM` (pms.js:1584-1591).
final RegExp botPMCommandRe = RegExp(
    r'^\s*\?(github|git|help|commands|balance|buy|clear|transfer|gift|model|anon)\b',
    caseSensitive: false);

// =============================================================================
// Service provider
// =============================================================================

/// The lazy Nymbot HTTP service. No network until a method is called.
final nymbotServiceProvider = Provider<NymbotService>((ref) {
  final service = NymbotService();
  ref.onDispose(service.dispose);
  return service;
});

// =============================================================================
// `?buy` modal mailbox
// =============================================================================

/// A pending request to open the bot-credits BUY modal (the PWA's
/// `showBotCreditsModal(null, tier)` from `?buy` and the noCredits path,
/// pms.js:2413/2478). The engine posts here; the bot-chat surface (and the
/// shell) listens, opens [BotCreditsModal] with [tier] preselected, then
/// consumes.
class BotBuyRequest {
  const BotBuyRequest({required this.tier});
  final CreditTier tier;
}

class BotBuyRequestHooks extends StateNotifier<BotBuyRequest?> {
  BotBuyRequestHooks() : super(null);

  void request(CreditTier tier) => state = BotBuyRequest(tier: tier);

  /// Clears the pending request once the modal has opened.
  void consume() => state = null;
}

/// The `?buy` mailbox. The engine writes; the bot-chat screen reads.
final botBuyRequestProvider =
    StateNotifierProvider<BotBuyRequestHooks, BotBuyRequest?>(
  (ref) => BotBuyRequestHooks(),
);

class BotAnonRequestHooks extends StateNotifier<bool> {
  BotAnonRequestHooks() : super(false);

  void request() => state = true;

  void consume() => state = false;
}

final botAnonRequestProvider =
    StateNotifierProvider<BotAnonRequestHooks, bool>(
  (ref) => BotAnonRequestHooks(),
);

// =============================================================================
// Private bot-chat engine state
// =============================================================================

/// Immutable snapshot of the private Nymbot chat controls. The conversation
/// itself lives in the canonical PM store (`AppState.messages['pm-<bot>']`).
class BotChatState {
  const BotChatState({
    this.proModel,
    this.git,
    this.balance = BotBalance.empty,
    this.balanceKnown = false,
    this.balanceUnavailable = false,
    this.sending = false,
    this.clearedAtSec = 0,
    this.infoMessages = const <Message>[],
    this.anonEnabled = false,
    this.anonPubkey,
  });

  /// The pinned Pro model (`?model <name>`), or null for standard routing.
  final ProModel? proModel;

  /// Connected git provider config (`?git`), or null when never configured.
  final GitConfig? git;

  final BotBalance balance;

  /// True once a balance response has landed (the header shows
  /// "checking credits…" until then — PWA `channelMeta` initial text).
  final bool balanceKnown;

  /// True when a balance check failed before any count ever landed — the
  /// header meta shows 'credits unavailable' (PWA `_refreshBotCreditMeta`,
  /// pms.js:2382-2389). Cleared the moment any balance arrives.
  final bool balanceUnavailable;

  final bool sending;

  /// The `?clear` watermark (seconds), 0 = never cleared. A cleared chat is
  /// empty but NOT new — the welcome bubble is suppressed (PWA
  /// `_getBotPmClearedAt`, pms.js:1692-1703 / 3072-3075).
  final int clearedAtSec;

  /// Transient bot-styled info bubbles (welcome, `?help` guide, command
  /// outputs). LOCAL-ONLY: they never enter the shared PM store, so they never
  /// bump the sidebar conversation, are never persisted, and vanish on restart
  /// — the PWA's `_displayBotInfoMessage` is "local-only and never persisted"
  /// (pms.js:1773-1776). The bot chat screen merges them into the rendered
  /// thread by timestamp.
  final List<Message> infoMessages;

  final bool anonEnabled;

  final String? anonPubkey;

  bool get isPro => proModel != null;

  BotChatState copyWith({
    Object? proModel = _sentinel,
    Object? git = _sentinel,
    BotBalance? balance,
    bool? balanceKnown,
    bool? balanceUnavailable,
    bool? sending,
    int? clearedAtSec,
    List<Message>? infoMessages,
    bool? anonEnabled,
    Object? anonPubkey = _sentinel,
  }) =>
      BotChatState(
        proModel: identical(proModel, _sentinel)
            ? this.proModel
            : proModel as ProModel?,
        git: identical(git, _sentinel) ? this.git : git as GitConfig?,
        balance: balance ?? this.balance,
        balanceKnown: balanceKnown ?? this.balanceKnown,
        balanceUnavailable: balanceUnavailable ?? this.balanceUnavailable,
        sending: sending ?? this.sending,
        clearedAtSec: clearedAtSec ?? this.clearedAtSec,
        infoMessages: infoMessages ?? this.infoMessages,
        anonEnabled: anonEnabled ?? this.anonEnabled,
        anonPubkey: identical(anonPubkey, _sentinel)
            ? this.anonPubkey
            : anonPubkey as String?,
      );

  static const _sentinel = Object();
}

/// Engine for the private Nymbot chat — the native `_handleBotPM` (pms.js:2393).
///
/// Owns the pinned Pro model, the git config (PAT on-device only, persisted in
/// prefs like the PWA's `nym_botpm_git` localStorage blob), the credit balance,
/// and the command/reply flows. Messages are read from / written into the
/// canonical PM store so the conversation persists in shared state, surfaces in
/// the sidebar, and renders through the canonical chat widgets.
///
/// The actual `pubkey`/`auth` blob comes from the parent identity layer — the
/// app sets it via [bind] before sending. Until bound, sends are refused so this
/// stays decoupled from shared identity state.
class BotChatController extends StateNotifier<BotChatState> {
  BotChatController(this._ref, this._service) : super(const BotChatState()) {
    _hydrate();
    // Anything already in the thread (restored history) is not a new send.
    _primeHandled(_thread);
    // The stored pin may name a model only the live catalog knows, which
    // hydrates asynchronously — re-resolve it the moment that list arrives so
    // the pin isn't silently dropped back to standard routing.
    _ref.listen<ProModelCatalog>(proModelCatalogProvider, (_, next) {
      if (!mounted || _pendingModelKey.isEmpty) return;
      final m = next.byKey(_pendingModelKey);
      if (m == null) return;
      _pendingModelKey = '';
      state = state.copyWith(proModel: m);
    });
  }

  /// A pinned `?model` key that no catalog available at hydrate time knew.
  String _pendingModelKey = '';

  final Ref _ref;
  final NymbotService _service;

  late final AnonBotManager anon = _buildAnon();

  AnonBotManager _buildAnon() {
    final mgr = AnonBotManager(_service);
    mgr.persist = (json) async {
      final pk = _pubkey;
      if (pk == null) return;
      try {
        await SecureStore().set('nym_botanon_$pk', json);
      } catch (_) {}
    };
    mgr.onKeysChanged = () {
      anonKeysChanged?.call();
      if (mounted) {
        state = state.copyWith(
            anonEnabled: mgr.enabled, anonPubkey: mgr.pubkey);
      }
    };
    mgr.requestSync = () => settingsSyncRequester?.call();
    return mgr;
  }

  void Function()? anonKeysChanged;

  String? _pubkey;
  Map<String, dynamic>? _auth;
  Uint8List? _privkey;
  EventSigner? _signer;

  /// Own-message ids already routed to the bot (or pre-existing history), so
  /// the app-state observer never double-fires a request.
  final Set<String> _handledIds = <String>{};
  bool _primed = false;
  int _lastLen = -1;
  String _lastLastId = '';

  /// Message ids of the transient bot-styled info bubbles (welcome, `?help`
  /// guide, command outputs — PWA `_displayBotInfoMessage`), local-only.
  int _infoSeq = 0;

  // --- Persistence (the PWA's nym_botpm_* localStorage keys) ----------------

  static const _kProModelPref = 'nym_botpm_pro_model';
  static const _kGitPref = 'nym_botpm_git';
  static const _kClearedAtPref = 'nym_botpm_cleared_at';
  static const _kWelcomedPref = 'nym_botpm_welcomed';
  static const _kAnonPref = 'nym_botanon_enabled';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<void> _hydrate() async {
    try {
      final p = await _prefs;
      if (!mounted) return;
      final modelKey = p.getString(_kProModelPref) ?? '';
      // Resolve through the live catalog first so a key pinned before a
      // version bump ("claude-opus") still finds its model ("claude-opus-5").
      final model = _catalog.byKey(modelKey) ??
          kProModelCatalogFallback.byKey(modelKey);
      // Unknown for now: hold the key so the listener above can resolve it
      // once the live catalog loads.
      _pendingModelKey = (model == null && modelKey.isNotEmpty) ? modelKey : '';
      GitConfig? git;
      final rawGit = p.getString(_kGitPref);
      if (rawGit != null && rawGit.isNotEmpty) {
        try {
          git = GitConfig.fromJson(
              (jsonDecode(rawGit) as Map).cast<String, dynamic>());
        } catch (_) {}
      }
      final clearedAt = int.tryParse(p.getString(_kClearedAtPref) ?? '') ?? 0;
      if (p.getString(_kAnonPref) == 'true') anon.setEnabled(true);
      // Monotonic: a synced remote marker ([applySyncedMarkers]) may have
      // landed before prefs hydrated — never regress it to the older on-disk
      // value.
      state = state.copyWith(
          proModel: model,
          git: git,
          clearedAtSec:
              clearedAt > state.clearedAtSec ? clearedAt : state.clearedAtSec);
      // A cache restore may have landed before the watermark hydrated — drop
      // any already-loaded bot-thread messages at or before it
      // (`displayMessage`'s clearedAt guard, pms.js:1121-1124).
      if (clearedAt > 0) _purgeCleared(clearedAt);
    } catch (_) {
      // Prefs unavailable (tests) — stay with in-memory defaults.
    }
  }

  /// Removes bot-thread messages stamped at or before the `?clear` watermark
  /// from the canonical store — the ingest-time filter the PWA applies in
  /// `handleGiftWrapDM` (pms.js:1121-1124), so relay backlog / D1 restore /
  /// the local cache can't resurrect a cleared thread.
  void _purgeCleared(int clearedAtSec) {
    final stale = <String>[
      for (final m in _thread)
        if (!m.isSystemRow && m.createdAt <= clearedAtSec) m.id,
    ];
    for (final id in stale) {
      _handledIds.add(id);
      _app.removeMessage(id);
    }
  }

  void _persistProModel(ProModel? model) {
    unawaited(_prefs.then((p) => model == null
        ? p.remove(_kProModelPref)
        : p.setString(_kProModelPref, model.key)));
  }

  void _persistGit(GitConfig? git) {
    unawaited(_prefs.then((p) => git == null
        ? p.remove(_kGitPref)
        : p.setString(_kGitPref, jsonEncode(git.toJson()))));
  }

  void _setClearedAt(int sec) {
    state = state.copyWith(clearedAtSec: sec);
    unawaited(_prefs.then((p) => p.setString(_kClearedAtPref, '$sec')));
  }

  /// Inbound leg of the synced bot-PM markers (`applyNostrSettings`,
  /// app.js:6083-6098): `botPmWelcomed` only ever flips ON (once the user was
  /// welcomed on any device the proactive PM stays suppressed everywhere) and
  /// `botPmClearedAt` is monotonic — take the newest clear time seen on any
  /// device so a `?clear` elsewhere hides this device's pre-clear Nymbot
  /// history too. Called from the settings-merge path
  /// ([NostrController._applySyncedSettings]).
  void applySyncedMarkers({bool welcomed = false, int clearedAtSec = 0}) {
    if (welcomed) {
      unawaited(_prefs.then((p) => p.setString(_kWelcomedPref, 'true')));
    }
    if (clearedAtSec > 0 && clearedAtSec > state.clearedAtSec) {
      _setClearedAt(clearedAtSec);
      // Drop the already-loaded pre-clear thread from the canonical store —
      // the ingest-time guard the PWA applies in `handleGiftWrapDM`
      // (pms.js:1121-1124) keyed off the freshly-advanced watermark.
      _purgeCleared(clearedAtSec);
    }
  }

  // --- Identity ---------------------------------------------------------------

  /// Wires in the user's identity for paid requests. Called by the parent app
  /// (`bindBotChat`). Pass [signer] (the active [EventSigner] — local OR remote)
  /// so auth signs through the generic dispatch like the PWA's `_signBotAuth`;
  /// with only a [privkey] a [LocalSigner] is built from it. [auth] remains an
  /// override hook for tests / delegated signers that pre-sign.
  void bind({
    required String pubkey,
    Map<String, dynamic>? auth,
    Uint8List? privkey,
    EventSigner? signer,
  }) {
    _pubkey = pubkey;
    _auth = auth;
    _privkey = privkey;
    _signer = signer ?? (privkey != null ? LocalSigner(privkey) : null);
    anon.reset(pubkey);
    anon.bindAccount(pubkey, _authFor);
    unawaited(_hydrateAnon(pubkey));
  }

  Future<void> _hydrateAnon(String pubkey) async {
    String? blob;
    try {
      blob = await SecureStore().get('nym_botanon_$pubkey');
    } catch (_) {
      blob = null;
    }
    if (_pubkey != pubkey) return;
    if (blob != null && blob.isNotEmpty) {
      anon.hydrate(blob);
    } else {
      anon.markLoaded();
    }
    if (anon.enabled) anon.ensureIdentity();
    if (mounted) {
      state = state.copyWith(
          anonEnabled: anon.enabled, anonPubkey: anon.pubkey);
    }
    anonKeysChanged?.call();
    unawaited(anon.flush());
  }

  /// Late-attaches the ACTIVE [EventSigner] (local key OR NIP-46 remote) on
  /// top of [bind], so per-action NIP-98 auth signs through the generic
  /// dispatch like the PWA's `_signBotAuth` (pms.js:1649-1679) — a
  /// remote-signer account gets a FRESH single-use signature per money action
  /// instead of a static pre-bound auth blob. Keeps the bound privkey (the
  /// local reply-unwrap path) intact.
  void attachSigner(EventSigner? signer) {
    if (signer != null) {
      _signer = signer;
    }
  }

  /// `_purgeBotPMArchive` seam (pms.js:1881-1891): batch `pm-delete` of the
  /// cleared thread's wrap ids from the D1 archive so no device can restore it.
  /// Wired by [NostrController.bindBotChat] (the storage-sync slice owns the
  /// authed transport); null before boot → the purge is skipped best-effort.
  Future<void> Function(List<String> wrapIds)? pmArchivePurger;

  /// Debounced encrypted-settings publish (`_debouncedNostrSettingsSave(2000)`,
  /// pms.js:1878/1903) so the cleared-at watermark / welcomed flag reach the
  /// user's other devices immediately. Wired by [NostrController.bindBotChat].
  void Function()? settingsSyncRequester;

  bool get isBound => _pubkey != null;

  /// The worker's single-use ledger actions — signed FRESH every time
  /// (`_signBotAuth`'s `MONEY` set + `clear-history`, pms.js:1655-1658; the
  /// worker enforces single-use replay for them).
  static const Set<String> _sensitiveActions = {
    'transfer-credits',
    'create-invoice',
    'claim-credits',
    'clear-history',
  };

  /// Per-action NIP-98 auth for [action], signed via the generic signer path
  /// ([Nip98Auth.buildSigned]) so NIP-46 accounts authenticate exactly like a
  /// local key: money actions sign fresh (single-use replay gate), routine
  /// actions reuse the shared 90s cache. Falls back to a pre-supplied [_auth]
  /// blob when no signer is bound.
  Future<Map<String, dynamic>?> _authFor(String action) async {
    final signer = _signer;
    if (signer != null) {
      final auth = await Nip98Auth.buildSigned(
        action: action,
        url: _service.baseUrl,
        signer: signer,
        sensitive: _sensitiveActions.contains(action),
      );
      if (auth != null) return auth;
    }
    return _auth;
  }

  // --- Canonical-store plumbing -----------------------------------------------

  /// The bot conversation's storage key (`pm-<botPubkey>`).
  static final String conversationKey = PmLogic.pmStorageKey(kNymbotPubkey);

  AppStateNotifier get _app => _ref.read(appStateProvider.notifier);
  AppState get _appState => _ref.read(appStateProvider);

  List<Message> get _thread =>
      _appState.messages[conversationKey] ?? const <Message>[];

  /// The bot's base display nym ('Nymbot' — seeded user, app.js:1103-1111).
  String get _botNym =>
      stripPubkeySuffix(_appState.users[kNymbotPubkey]?.nym ?? 'Nymbot');

  /// Centered system line in the bot conversation (PWA `displaySystemMessage`).
  ///
  /// Localized at the sink: every caller builds an English sentence (often with
  /// interpolated costs / model labels / nyms), so routing it through [tr] here
  /// localizes all of them into the active UI language without threading a
  /// template + args through ~40 call sites. `tr` is a synchronous no-op for
  /// English and returns the source immediately for other languages while the
  /// translation caches in the background.
  void _system(String text) =>
      _app.addSystemMessage(tr(text), storageKey: conversationKey);

  /// A transient bot-styled info bubble (welcome, `?help` guide, command
  /// outputs) that looks like a message from Nymbot — the PWA's
  /// `_displayBotInfoMessage` (pms.js:1776-1813). LOCAL-ONLY like the PWA
  /// ("local-only and never persisted"): appended to [BotChatState.infoMessages]
  /// instead of the shared PM store, so it never bumps the sidebar conversation,
  /// is never persisted, and vanishes on restart. A repeated [id] (the welcome
  /// on every open of an empty thread) replaces the old bubble with a fresh
  /// timestamp, like the PWA's per-open re-render.
  void _displayBotInfoMessage(String text, {String? id, int? createdAtMs}) {
    final nowMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch;
    final msgId = id ?? 'nymbot-info-$nowMs-${_infoSeq++}';
    _appendInfo(Message(
      id: msgId,
      author: _botNym,
      pubkey: kNymbotPubkey,
      content: text,
      createdAt: nowMs ~/ 1000,
      ms: nowMs,
      timestamp: nowMs,
      isPM: true,
      conversationKey: conversationKey,
      conversationPubkey: kNymbotPubkey,
      eventKind: 1059,
      isBot: true,
      senderVerified: true,
    ));
  }

  /// A transient, LOCAL-ONLY centered system line in the bot thread. The PWA's
  /// 'Start of private message' / `?clear` confirmation are `displaySystemMessage`
  /// DOM rows that never enter `pmMessages` (they vanish on every re-render,
  /// pms.js:3065-3082 / 1908-1916) — so here they ride [BotChatState.infoMessages]
  /// instead of the persisted canonical store. A repeated [id] replaces the old
  /// row with a fresh timestamp (the per-open re-render).
  void _displayTransientSystem(String text, {String? id}) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _appendInfo(Message(
      id: id ?? 'nymbot-sys-$nowMs-${_infoSeq++}',
      author: '',
      pubkey: '',
      content: text,
      createdAt: nowMs ~/ 1000,
      ms: nowMs,
      timestamp: nowMs,
      conversationKey: conversationKey,
      kind: MessageKind.system,
    ));
  }

  /// Appends [msg] to the transient info layer, replacing any older row with
  /// the same id (the welcome/start line re-rendered fresh on every open).
  void _appendInfo(Message msg) {
    state = state.copyWith(infoMessages: [
      for (final m in state.infoMessages)
        if (m.id != msg.id) m,
      msg,
    ]);
  }

  /// Show/clear the synthetic "Nymbot is thinking" indicator in the bot PM —
  /// `_setBotTyping` (pms.js:1980-1995): 30s auto-expiry, rendered by the
  /// shared typing-indicator strip (verb 'thinking' for the bot).
  void _setBotTyping(bool on) {
    _app.setTyping(
      storageKey: conversationKey,
      pubkey: kNymbotPubkey,
      typing: on,
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 30000,
    );
  }

  /// Advances sent→delivered→read receipts on our own messages in the Nymbot
  /// chat (`_markBotPMReceipts`, pms.js:2062-2081). Never regresses; failed
  /// messages are skipped.
  void _markBotPMReceipts(String receiptType) {
    final target = PmLogic.deliveryFromReceipt(receiptType);
    for (final m in _thread) {
      if (!m.isOwn ||
          m.deliveryStatus == DeliveryStatus.failed ||
          m.nymMessageId == null) {
        continue;
      }
      if (PmLogic.statusOrder(target) > PmLogic.statusOrder(m.deliveryStatus)) {
        _app.applyReceipt(
            ReceiptInfo(messageId: m.nymMessageId!, receiptType: receiptType));
      }
    }
  }

  /// Marks every message currently in the thread as already-handled so the
  /// observer only reacts to NEW sends.
  void _primeHandled(List<Message> list) {
    for (final m in list) {
      _handledIds.add(m.id);
    }
    _primed = true;
    _lastLen = list.length;
    _lastLastId = list.isNotEmpty ? list.last.id : '';
  }

  /// App-state observer: routes NEW own messages in the bot thread (e.g. sent
  /// through the canonical PM composer) into the bot engine, so the bot replies
  /// no matter which surface sent the message. `?` control commands are pulled
  /// back out of the thread (the PWA never shows them as bubbles,
  /// pms.js:1584-1591) and executed on-device.
  void onAppState(AppState app) {
    final list = app.messages[conversationKey];
    if (list == null) return;
    if (!_primed) {
      _primeHandled(list);
      return;
    }
    // Cheap no-change guard (app state updates are frequent).
    if (list.length == _lastLen &&
        (list.isEmpty || list.last.id == _lastLastId)) {
      return;
    }
    _lastLen = list.length;
    _lastLastId = list.isNotEmpty ? list.last.id : '';

    final fresh = <Message>[];
    for (final m in list) {
      if (_handledIds.add(m.id)) fresh.add(m);
    }
    // `?clear` watermark: relay backlog / archive restore must never resurrect
    // a cleared thread (pms.js:1121-1124 drops bot-thread rumors with
    // `created_at <= clearedAt` at ingest).
    final clearedAt = state.clearedAtSec;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final m in fresh) {
      if (clearedAt > 0 && !m.isSystemRow && m.createdAt <= clearedAt) {
        _app.removeMessage(m.id);
        continue;
      }
      if (!m.isOwn || m.kind != MessageKind.normal || m.isFileOffer) continue;
      // Only LIVE sends trigger the bot — restored/backlogged history must
      // never re-bill (the PWA gates its reply flow on the live send path).
      if (m.isHistorical || nowMs - m.timestamp > 15000) continue;
      final content = m.content;
      if (botPMCommandRe.hasMatch(canonicalizeCommandInput(content))) {
        // Control commands never render as bubbles (PWA intercepts them before
        // publish); pull the echo back out, then run the command.
        _app.removeMessage(m.id);
        unawaited(handleBotPMCommand(content));
      } else {
        unawaited(_runBotExchange(m));
      }
    }
  }

  // --- Intro / welcome ----------------------------------------------------------

  /// Renders the empty-conversation intro when the bot PM opens with no
  /// messages: the 'Start of private message' system line, the welcome bubble
  /// (only when the chat was never `?clear`-ed), and a silent credit refresh —
  /// `loadPMMessages`'s empty branch (pms.js:3065-3082).
  void ensureIntro() {
    final list = _thread;
    if (!_primed) _primeHandled(list);
    if (list.isNotEmpty) {
      // A non-empty conversation re-renders exclusively from the persisted
      // store on every open (`loadPMMessages`, pms.js:3040-3086) — all
      // transient `_displayBotInfoMessage` DOM (welcome, `?help` guide,
      // `?balance`/`?git` cards) is dropped on a conversation switch.
      if (state.infoMessages.isNotEmpty) {
        state = state.copyWith(infoMessages: const <Message>[]);
      }
      return;
    }
    // The PWA re-renders the WHOLE empty conversation as transient DOM on
    // EVERY open (`loadPMMessages`'s empty branch, pms.js:3065-3082): the
    // 'Start of private message' line, the welcome bubble (only when the chat
    // was never `?clear`-ed), and a silent credit refresh. Nothing persists —
    // reset the transient layer to exactly that intro so a restart with a
    // still-empty thread re-greets like the PWA (no start line ever enters
    // the persisted canonical store).
    state = state.copyWith(infoMessages: const <Message>[]);
    _displayTransientSystem('Start of private message', id: 'nymbot-start');
    if (state.clearedAtSec == 0) {
      // Rendered fresh (current timestamp) after the start line, matching the
      // PWA's DOM append order.
      _displayBotInfoMessage(botWelcomeText, id: 'nymbot-welcome');
    }
    unawaited(checkBotCredits(display: false));
  }

  /// Brand-new users get a proactive PM from Nymbot so a highlighted
  /// conversation appears in their sidebar from the start. Sent locally, once
  /// per device — `_maybeSendBotWelcomePM` (pms.js:1840-1879).
  Future<void> maybeSendBotWelcomePM() async {
    SharedPreferences p;
    try {
      p = await _prefs;
    } catch (_) {
      return;
    }
    if (p.getString(_kWelcomedPref) == 'true') return;
    if (_appState.selfPubkey.isEmpty) return;
    if (_thread.isNotEmpty) {
      await p.setString(_kWelcomedPref, 'true');
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nowSec = nowMs ~/ 1000;
    _app.ingestPMMessage(Message(
      id: 'nymbot-welcome-$nowSec',
      author: _botNym,
      pubkey: kNymbotPubkey,
      content: botFirstContactText,
      createdAt: nowSec,
      ms: nowMs,
      timestamp: nowSec * 1000,
      isPM: true,
      conversationKey: conversationKey,
      conversationPubkey: kNymbotPubkey,
      eventKind: 1059,
      isBot: true,
      senderVerified: true,
    ));
    await p.setString(_kWelcomedPref, 'true');
    // Push the welcomed flag to synced settings so the user's other devices
    // skip the proactive PM too (`_debouncedNostrSettingsSave(2000)`,
    // pms.js:1878).
    settingsSyncRequester?.call();
  }

  // --- Local controls --------------------------------------------------------

  /// Directly pins/clears the Pro model (the premium picker sheet). Persisted
  /// like the PWA's `nym_botpm_pro_model`.
  void setModelDirect(ProModel? model) {
    state = state.copyWith(proModel: model);
    _persistProModel(model);
  }

  /// Connects a git repo (the premium connect modal). The PAT lives only in
  /// [GitConfig.token] + prefs here — wiped by [wipeOnPanic].
  void connectGit(GitConfig config) {
    state = state.copyWith(git: config);
    _persistGit(config);
  }

  void disconnectGit() {
    state = state.copyWith(git: null);
    _persistGit(null);
  }

  /// Panic Mode hook: wipe the on-device PAT + git config.
  void wipeOnPanic() {
    state = state.copyWith(git: null);
    _persistGit(null);
  }

  void setBalance(BotBalance b) => state =
      state.copyWith(balance: b, balanceKnown: true, balanceUnavailable: false);

  // --- Command dispatch (the PWA `_handleBotPM` command branches) -------------

  /// Executes a `?` control command typed in the bot PM. On-device only — never
  /// published, never billed (pms.js:2393-2445).
  Future<void> handleBotPMCommand(String content) async {
    // A command typed in the user's language is folded back to its canonical
    // English token before any of the ?command matching below.
    final trimmed = canonicalizeCommandInput(content.trim());
    _markBotPMReceipts('delivered');
    _markBotPMReceipts('read');
    if (RegExp(r'^\?(help|commands)\b', caseSensitive: false)
        .hasMatch(trimmed)) {
      _displayBotPmHelp();
      return;
    }
    if (RegExp(r'^\?balance\b', caseSensitive: false).hasMatch(trimmed)) {
      await checkBotCredits(display: true);
      return;
    }
    if (RegExp(r'^\?buy\b', caseSensitive: false).hasMatch(trimmed)) {
      _ref
          .read(botBuyRequestProvider.notifier)
          .request(state.isPro ? CreditTier.pro : CreditTier.standard);
      return;
    }
    if (RegExp(r'^\?model\b', caseSensitive: false).hasMatch(trimmed)) {
      handleModelCommand(trimmed);
      return;
    }
    if (RegExp(r'^\?anon\b', caseSensitive: false).hasMatch(trimmed)) {
      _ref.read(botAnonRequestProvider.notifier).request();
      return;
    }
    if (RegExp(r'^\?clear\b', caseSensitive: false).hasMatch(trimmed)) {
      await clearBotPMHistory();
      return;
    }
    if (RegExp(r'^\?transfer\b', caseSensitive: false).hasMatch(trimmed)) {
      await handleTransferCommand(trimmed);
      return;
    }
    if (RegExp(r'^\?gift\b', caseSensitive: false).hasMatch(trimmed)) {
      _handleGiftCommand(trimmed);
      return;
    }
    if (RegExp(r'^\?(github|git)\b', caseSensitive: false).hasMatch(trimmed)) {
      await handleGitCommand(trimmed);
      return;
    }
  }

  /// Sends one user message from the bot-chat composer: control commands run
  /// on-device (no bubble); everything else is published as a REAL NIP-17 PM
  /// (a gift wrap to the bot + a self-copy, `sendPM` → `sendNIP17PM`,
  /// pms.js:1594-1599), echoed into the canonical PM store, and routed to the
  /// worker with the published wrap's id (`_handleBotPM(content, wrapped)`).
  Future<void> sendUserBotPM(String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    if (botPMCommandRe.hasMatch(trimmed)) {
      await handleBotPMCommand(trimmed);
      return;
    }
    final app = _appState;
    final selfPubkey = _pubkey ?? app.selfPubkey;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nymMessageId = PmLogic.generateSharedEventId();

    // A send while the bot conversation's thread view is open replies into
    // that thread: the root's shared id rides inside the encrypted rumor
    // (`nymthread`), the worker scopes its context to the thread and files
    // its reply there — same wiring as `_sendMessageContent`.
    String? threadRoot;
    if (appThreadsEnabled) {
      final at = _ref.read(activeThreadProvider);
      if (at != null && at.view == const ChatView.pm(kNymbotPubkey)) {
        threadRoot = at.rootId;
      }
    }

    // Build the kind-14 rumor (with the NIP-30 custom-emoji declarations the
    // PWA spreads in, pms.js:313), wrap it to the bot AND to self, and publish
    // both — the worker fetches the bot-addressed wrap by its id from relays.
    NostrEvent? botWrap;
    NostrEvent? selfWrap;
    final anonSender = anon.enabled ? anon.ensureIdentity() : null;
    if (anon.enabled && anonSender == null) {
      _system('Anonymous Nymbot chat is not ready on this device yet.');
      return;
    }
    if (selfPubkey.isNotEmpty) {
      final rumor = PmLogic.buildPmRumor(
        selfPubkey: anonSender?.pk ?? selfPubkey,
        recipientPubkey: kNymbotPubkey,
        content: content,
        nymMessageId: nymMessageId,
        extraTags: [
          if (threadRoot != null) ['nymthread', threadRoot],
          ..._ref
              .read(liveCustomEmojiProvider.notifier)
              .emojiTagsForContent(content),
        ],
        nowMs: nowMs,
      );
      botWrap = await _wrapRumor(rumor, kNymbotPubkey, sender: anonSender);
      if (botWrap != null && !_publishDmEvent(botWrap.toJson())) {
        botWrap = null;
      }
      if (botWrap != null) {
        selfWrap = anonSender != null
            ? await _wrapRumor(rumor, anonSender.pk,
                sender: anonSender,
                recipientKem: anon.kemFor(anonSender)?.publicKey)
            : await _wrapRumor(rumor, selfPubkey);
        if (selfWrap != null) _publishDmEvent(selfWrap.toJson());
        // `sendPM` records own activity right after `sendNIP17PM`
        // (pms.js:1596): refresh our own lastSeen + the throttled presence
        // broadcast on bot-screen sends like every other send surface.
        try {
          _ref.read(nostrControllerProvider).recordOwnActivity();
        } catch (_) {}
      }
    }

    final msg = Message(
      id: selfWrap?.id ?? 'botpm-own-$nowMs-${_infoSeq++}',
      author: app.selfNym,
      pubkey: selfPubkey,
      content: content,
      createdAt: nowMs ~/ 1000,
      ms: nowMs,
      timestamp: nowMs,
      isOwn: true,
      isPM: true,
      conversationKey: conversationKey,
      conversationPubkey: kNymbotPubkey,
      eventKind: 1059,
      senderVerified: true,
      nymMessageId: nymMessageId,
      threadRoot: threadRoot,
      deliveryStatus:
          botWrap != null ? DeliveryStatus.sent : DeliveryStatus.failed,
    );
    _handledIds.add(msg.id);
    _app.ingestPMMessage(msg);
    await _runBotExchange(msg, wrapId: botWrap?.id);
  }

  // --- Network -----------------------------------------------------------------

  /// Publishes a pre-signed kind-1059 gift wrap to the DM relays — the PWA's
  /// `sendDMToRelays(['EVENT', event])`. Rides the shop controller's
  /// `giftEventPublisher` hook (wired to `pool.publishDm` by the nostr layer,
  /// the same relay leg the PWA uses for every wrap here); returns false when
  /// no publisher is wired yet (pre-login boot).
  bool _publishDmEvent(Map<String, dynamic> event) {
    final publish =
        _ref.read(shopControllerProvider.notifier).giftEventPublisher;
    if (publish == null) return false;
    try {
      publish(event);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Gift-wraps [rumor] to [recipientPubkey] (NIP-59), honoring the DM
  /// forward-secrecy TTL like `publishPM` does. Uses the local key when bound;
  /// a delegated (NIP-46) signer seals through the remote signer.
  Future<NostrEvent?> _wrapRumor(
      UnsignedEvent rumor, String recipientPubkey,
      {AnonBotIdentity? sender, Uint8List? recipientKem}) async {
    final s = _ref.read(settingsProvider);
    final expiration = (s.dmForwardSecrecyEnabled && s.dmTtlSeconds > 0)
        ? DateTime.now().millisecondsSinceEpoch ~/ 1000 + s.dmTtlSeconds
        : null;
    if (sender != null) {
      try {
        var kemPk = recipientKem;
        if (kemPk == null) {
          try {
            kemPk = await _ref
                .read(nostrControllerProvider)
                .pqLayeredWrapKeyFor(recipientPubkey);
          } catch (_) {
            kemPk = null;
          }
        }
        if (kemPk != null) {
          return await giftwrap.pq2Nip59Wrap(
            rumor: rumor,
            senderPrivkey: sender.sk,
            recipientPubkey: recipientPubkey,
            recipientKemPublicKey: kemPk,
            expiration: expiration,
          );
        }
        return giftwrap.nip59Wrap(
          rumor: rumor,
          senderPrivkey: sender.sk,
          recipientPubkey: recipientPubkey,
          expiration: expiration,
        );
      } catch (_) {
        return null;
      }
    }
    try {
      final sk = _privkey;
      if (sk != null) {
        // Hybrid post-quantum whenever the recipient announced a layered
        // ML-KEM key — which the Nymbot worker now does (its keypair derives
        // from the bot's own nympq1 root). Falls back to classical exactly
        // like the canonical PM path; a lookup failure never blocks the send.
        Uint8List? kemPk;
        try {
          kemPk = await _ref
              .read(nostrControllerProvider)
              .pqLayeredWrapKeyFor(recipientPubkey);
        } catch (_) {
          kemPk = null;
        }
        if (kemPk != null) {
          // Awaited inside the try so a seal failure is caught here.
          return await giftwrap.pq2Nip59Wrap(
            rumor: rumor,
            senderPrivkey: sk,
            recipientPubkey: recipientPubkey,
            recipientKemPublicKey: kemPk,
            expiration: expiration,
          );
        }
        return giftwrap.nip59Wrap(
          rumor: rumor,
          senderPrivkey: sk,
          recipientPubkey: recipientPubkey,
          expiration: expiration,
        );
      }
      final signer = _signer;
      if (signer != null) {
        // Awaited (not just returned) so a failure in the remote-signer seal is
        // caught by this try/catch rather than escaping as an unhandled async
        // error.
        return await giftwrap.nip59WrapAsync(
          rumor: rumor,
          senderSigner: signer,
          recipientPubkey: recipientPubkey,
          expiration: expiration,
        );
      }
    } catch (_) {}
    return null;
  }

  List<giftwrap.UnwrapCandidate> anonUnwrapCandidates(NostrEvent wrap) {
    String? pTag;
    for (final t in wrap.tags) {
      if (t.length > 1 && t[0] == 'p') {
        pTag = t[1];
        break;
      }
    }
    if (pTag == null) return const <giftwrap.UnwrapCandidate>[];
    final id = anon.identityForWrap(pTag);
    if (id == null) return const <giftwrap.UnwrapCandidate>[];
    final kem = anon.kemFor(id);
    return [
      if (kem != null)
        (sk: id.sk, bitchat: false, kemSk: kem.secretKey, kemPk: kem.publicKey),
      giftwrap.classicalCandidate(id.sk),
    ];
  }

  /// Unwraps the worker's kind-1059 reply wrap and ingests it into the
  /// canonical thread — the display leg of `handleGiftWrapDM(data.event, {})`
  /// (pms.js:2489-2492), including the leading `<think>` split the PWA does at
  /// decrypt (pms.js:1255-1262). Undecryptable wraps (delegated signer) fall
  /// back to the relay echo of the wrap we just published.
  Future<void> _displayBotReplyWrap(Map<String, dynamic> wrapJson) async {
    final sk = _privkey;
    try {
      final wrap = NostrEvent.fromJson(wrapJson);
      var candidates = anonUnwrapCandidates(wrap);
      if (candidates.isEmpty) {
        if (sk == null) return;
        // The full self candidate set (ML-KEM keypairs first, classical last):
        // once the user announced a key, the worker seals its replies
        // post-quantum, and a classical-only candidate would push every reply
        // onto the slower relay-echo fallback.
        try {
          candidates =
              _ref.read(nostrControllerProvider).selfUnwrapCandidates();
        } catch (_) {}
        if (candidates.isEmpty) {
          candidates = [giftwrap.classicalCandidate(sk)];
        }
      }
      final unwrapped = await giftwrap.unwrapGiftWrap(wrap, candidates);
      if (unwrapped == null || !mounted) return;
      final rumor = unwrapped.rumor;
      final msg = PmLogic.mapPmRumor(
        rumor: rumor,
        wrapId: wrap.id,
        selfPubkey: _pubkey ?? _appState.selfPubkey,
        // Seal signer must match the claimed rumor author (NIP-59).
        senderVerified: unwrapped.seal.pubkey == (rumor['pubkey'] ?? ''),
      );
      if (msg == null) return;
      // Nymbot replies may lead with a <think> reasoning block — split it into
      // its own field so previews/search see only the visible reply
      // (pms.js:1255-1262).
      final tm =
          RegExp(r'^\s*<think>([\s\S]*?)<\/think>\s*', caseSensitive: false)
              .firstMatch(msg.content);
      if (tm != null && msg.content.substring(tm.end).trim().isNotEmpty) {
        msg.thinking = tm.group(1)?.trim();
        msg.content = msg.content.substring(tm.end);
      }
      msg.author = _botNym;
      msg.isBot = true;
      _handledIds.add(msg.id);
      _app.ingestPMMessage(msg);
    } catch (_) {
      // Ciphertext we can't open locally — the published wrap echoes back via
      // the normal relay gift-wrap ingest.
    }
  }

  /// The paid request/reply round-trip for one user message ([m] already in the
  /// canonical store): delivered receipt → typing 'thinking' strip → worker call
  /// (eventId of the published wrap; NO plaintext rides the request) → read
  /// receipt → publish + unwrap `data.event` / republish `data.selfEvent`
  /// (+ cost / low-balance system lines) — `_handleBotPM`'s paid branch
  /// (pms.js:2445-2519).
  ///
  /// [wrapId] is the published bot-addressed gift wrap's id. Messages arriving
  /// via the app-state observer (sent through the canonical PM composer, whose
  /// publish path doesn't surface its wrap ids) get a dedicated wrap built and
  /// published here so the worker has an event to fetch.
  Future<void> _runBotExchange(Message m, {String? wrapId}) async {
    final anonId = anon.ready ? anon.identity : null;
    if (_pubkey == null) {
      _system(
          'Nymbot: could not publish your encrypted message. Please try again.');
      return;
    }
    _markBotPMReceipts('delivered');
    if (wrapId == null) {
      final rumor = PmLogic.buildPmRumor(
        selfPubkey: anonId?.pk ?? _pubkey!,
        recipientPubkey: kNymbotPubkey,
        content: m.content,
        nymMessageId: m.nymMessageId ?? PmLogic.generateSharedEventId(),
        // A message sent from a thread view keeps its thread on the rebuilt
        // wrap too, so the worker sees the same `nymthread` the original
        // rumor carried.
        extraTags: [
          if ((m.threadRoot ?? '').isNotEmpty) ['nymthread', m.threadRoot!],
        ],
      );
      final wrap = await _wrapRumor(rumor, kNymbotPubkey, sender: anonId);
      if (wrap != null && _publishDmEvent(wrap.toJson())) {
        wrapId = wrap.id;
      }
    }
    // The PWA refuses the round-trip without a published wrap id
    // (`if (!wrapId)`, pms.js:2443-2446).
    if (wrapId == null) {
      _system(
          'Nymbot: could not publish your encrypted message. Please try again.');
      return;
    }
    _setBotTyping(true);
    state = state.copyWith(sending: true);
    try {
      // A leading `!` marks a one-off "fresh" message that ignores history
      // (pms.js:2450 `isFresh`); the published wrap keeps the full text.
      final fresh = RegExp(r'^\s*!\s*\S').hasMatch(m.content);
      final pro = state.proModel;
      final git = state.git;
      Map<String, dynamic>? pqAnnouncement;
      if (anonId != null) {
        pqAnnouncement = anon.announcement();
      } else {
        try {
          pqAnnouncement =
              _ref.read(nostrControllerProvider).pqSelfAnnouncementJson;
        } catch (_) {
          pqAnnouncement = null;
        }
      }
      final data = await _service.sendBotMessage(
        pubkey: anonId?.pk ?? _pubkey!,
        anon: anonId != null,
        eventId: wrapId,
        // Signed only on the HTTP fallback leg — the authenticated socket
        // skips per-action auth (shop.js:158-165).
        auth: () => anonId != null ? anon.authFor('pm') : _authFor('pm'),
        proModel: pro?.key,
        fresh: fresh,
        // Repo mode rides only on Pro replies with a connected repo
        // (pms.js:2455-2466).
        git: (pro != null && git != null && git.hasRepo) ? git : null,
        cmdAlias: commandAliasHint(m.content),
        pqAnnouncement: pqAnnouncement,
      );
      if (!mounted) return;
      _setBotTyping(false);
      _markBotPMReceipts('read');

      // The reply is an encrypted kind-1059 gift wrap: publish it to the DM
      // relays and unwrap it locally for display (pms.js:2489-2492).
      final event = data['event'];
      if (event is Map) {
        final wrapJson = event.cast<String, dynamic>();
        _publishDmEvent(wrapJson);
        await _displayBotReplyWrap(wrapJson);
      }
      // Publish the bot's self-addressed copy so the worker can re-fetch and
      // decrypt its own reply as context on later turns (pms.js:2493-2497).
      final selfEvent = data['selfEvent'];
      if (selfEvent is Map &&
          RegExp(r'^[0-9a-f]{64}$', caseSensitive: false)
              .hasMatch((selfEvent['id'] ?? '').toString())) {
        _publishDmEvent(selfEvent.cast<String, dynamic>());
      }

      final balance = (data['balance'] as num?)?.toInt();
      if (balance != null) {
        final isPro = data['pro'] == true;
        _applyLedgerBalance(balance, pro: isPro);
        // Cost notices for heavy replies (pms.js:2499-2512).
        final cost = (data['cost'] as num?)?.toInt() ?? 0;
        if (data['git'] == true && cost > 0) {
          final calls = (data['modelCalls'] as num?)?.toInt() ?? 0;
          _system('Repo task used $cost Pro credit${cost == 1 ? '' : 's'}'
              '${calls > 1 ? ' ($calls model calls)' : ''}. '
              'Pro balance: $balance.');
        } else if (isPro && cost > 0) {
          final sel = state.proModel;
          if (sel != null && cost > sel.baseCredits) {
            _system('Long reply used $cost Pro credits (scales with length). '
                'Pro balance: $balance.');
          }
        } else if (!isPro && cost > 1) {
          _system('${data['taskType'] ?? 'Heavy'} reply used $cost credits. '
              'Balance: $balance.');
        }
        if (data['lowBalance'] == true) {
          _system(isPro
              ? 'Nymbot Pro credits running low: $balance left. '
                  'Type ?buy and switch to Pro to top up.'
              : 'Nymbot credits running low: $balance '
                  'credit${balance == 1 ? '' : 's'} left. '
                  'Type ?buy to top up.');
        }
      }
    } on NymbotInsufficientCredits catch (e) {
      _setBotTyping(false);
      _markBotPMReceipts('read');
      // Out of credits → neutral system line + the buy modal, never a red
      // bubble (pms.js:2470-2483).
      final custom =
          e.message.isNotEmpty && e.message != 'Insufficient credits';
      _system(custom
          ? e.message
          : (e.pro
              ? "You're out of Nymbot Pro credits (${e.balance} left). "
                  'Type ?buy and switch to Pro, or ?model off for standard '
                  'replies.'
              : "You're out of Nymbot credits (${e.balance} left). "
                  'Zap Nymbot or type ?buy to purchase more.'));
      _applyLedgerBalance(e.balance, pro: e.pro);
      _ref
          .read(botBuyRequestProvider.notifier)
          .request(e.pro ? CreditTier.pro : CreditTier.standard);
    } on NymbotException catch (e) {
      _setBotTyping(false);
      // A response DID come back — the PWA advances read receipts before its
      // `status >= 400 || data.error` check (pms.js:2481-2487); only the
      // network-exception catch below skips them.
      _markBotPMReceipts('read');
      // `status >= 400 || data.error` → 'Nymbot: <error|request failed>'
      // (pms.js:2484-2487).
      _system('Nymbot: ${_errorDetail(e) ?? 'request failed'}');
    } catch (_) {
      _setBotTyping(false);
      _system('Nymbot is unavailable right now. Please try again.');
    } finally {
      if (mounted) state = state.copyWith(sending: false);
    }
  }

  /// The worker `error` string carried in a [NymbotException] body (the PWA's
  /// `data.error` reads), or null when the failure had no parseable error.
  static String? _errorDetail(NymbotException e) {
    final body = e.body;
    if (body == null || body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is String) {
        final err = decoded['error'] as String;
        if (err.isNotEmpty) return err;
      }
    } catch (_) {}
    return null;
  }

  void _applyLedgerBalance(int balance, {required bool pro}) {
    final b = state.balance;
    state = state.copyWith(
      balanceKnown: true,
      balanceUnavailable: false,
      balance: pro
          ? BotBalance(
              balance: b.balance,
              totalPurchased: b.totalPurchased,
              totalUsed: b.totalUsed,
              proBalance: balance,
              proTotalPurchased: b.proTotalPurchased,
              proTotalUsed: b.proTotalUsed,
            )
          : BotBalance(
              balance: balance,
              totalPurchased: b.totalPurchased,
              totalUsed: b.totalUsed,
              proBalance: b.proBalance,
              proTotalPurchased: b.proTotalPurchased,
              proTotalUsed: b.proTotalUsed,
            ),
    );
  }

  /// Refreshes the credit balance from the worker; with [display] it also
  /// prints the balance as a bot info bubble — `_checkBotCredits`
  /// (pms.js:2525-2548).
  Future<void> checkBotCredits({required bool display}) async {
    if (_pubkey == null) return;
    try {
      final anonId = anon.ready ? anon.identity : null;
      final b = await _service.balance(
          pubkey: anonId?.pk ?? _pubkey!,
          anon: anonId != null,
          auth: () =>
              anonId != null ? anon.authFor('balance') : _authFor('balance'));
      if (!mounted) return;
      state = state.copyWith(
          balance: b, balanceKnown: true, balanceUnavailable: false);
      if (display) {
        final std = b.balance;
        final pro = b.proBalance;
        _displayBotInfoMessage(
            '${anon.ready ? 'Your anonymous balance' : 'Your balance'}: '
            '**$std** standard credit${std == 1 ? '' : 's'} · '
            '**$pro** Pro credit${pro == 1 ? '' : 's'}.'
            '${anon.ready ? ' Type `?anon` to move more credits across from your nym.' : ''}'
            '${std <= 0 && pro <= 0 ? ' Type `?buy` to purchase more.' : ''}');
      }
    } on NymbotException catch (e) {
      // `'Nymbot: ' + (data.error || 'could not check balance')`
      // (pms.js:2529-2532).
      if (display) {
        _system('Nymbot: ${_errorDetail(e) ?? 'could not check balance'}');
      }
      _markBalanceUnavailable();
    } catch (_) {
      if (display) {
        _system('Could not reach Nymbot to check your balance.');
      }
      _markBalanceUnavailable();
    }
  }

  /// Failed check with no count ever cached → header meta 'credits unavailable'
  /// (`_refreshBotCreditMeta`, pms.js:2382-2389).
  void _markBalanceUnavailable() {
    if (mounted && !state.balanceKnown) {
      state = state.copyWith(balanceUnavailable: true);
    }
  }

  /// Back-compat convenience for the screen's open-time refresh.
  Future<void> refreshBalance() => checkBotCredits(display: false);

  Future<void> setAnonEnabled(bool on) async {
    anon.setEnabled(on);
    unawaited(_prefs.then((p) => p.setString(_kAnonPref, on ? 'true' : 'false')));
    if (mounted) {
      state = state.copyWith(anonEnabled: on, anonPubkey: anon.pubkey);
    }
    if (on) unawaited(anon.flush());
    await checkBotCredits(display: false);
  }

  Future<int> anonMoveCredits(int amount, CreditTier tier) async {
    final moved = await anon.moveCredits(amount, tier.wire);
    await checkBotCredits(display: false);
    return moved;
  }

  Future<int> anonRotate({bool sweep = false}) async {
    final moved = await anon.rotate(sweep: sweep);
    if (mounted) state = state.copyWith(anonPubkey: anon.pubkey);
    await checkBotCredits(display: false);
    return moved;
  }

  Future<BotBalance?> accountBalance() async {
    final pk = _pubkey;
    if (pk == null) return null;
    try {
      return await _service.balance(
          pubkey: pk, auth: () => _authFor('balance'));
    } catch (_) {
      return null;
    }
  }

  // --- ?model (pms.js `_handleBotModelCommand`, :2119-2145) -------------------

  void handleModelCommand(String trimmed) {
    final arg = trimmed
        .replaceFirst(RegExp(r'^\?model\b', caseSensitive: false), '')
        .trim()
        .toLowerCase();
    final current = state.proModel;
    if (arg.isEmpty) {
      unawaited(_ref.read(proModelCatalogProvider.notifier).refresh());
      final all = _catalog.models;
      final groups = _catalog.grouped();
      // The live catalog runs to dozens of models — too many for a chat
      // bubble — so summarise per provider and send the rest to the picker.
      final lines = groups.length > 1
          ? [
              for (final g in groups)
                '• **${g.key}** — ${g.value.take(6).map((m) => '`${m.key}`').join(', ')}'
                    '${g.value.length > 6 ? ' +${g.value.length - 6} more' : ''}',
              '_${all.length} models available. Tap the model button for the '
                  'full list with prices._',
            ]
          : [
              for (final m in all)
                '• `${m.key}`${current?.key == m.key ? ' ✓' : ''} — ${m.label}, ${m.priceLabel}',
            ];
      _displayBotInfoMessage([
        if (current != null)
          'Nymbot Pro model: **${current.label}** (${current.priceLabel}).'
        else
          'Nymbot Pro is off — replies use standard multi-model routing and standard credits.',
        ...lines,
        'Short replies cost the base price; long replies scale with length. The maximum is reserved from your balance per message and only the actual cost is charged.',
        'Use `?model <name>` to select one, or `?model off` for standard routing. Pro credits: `?buy` → Pro.',
      ].join('\n'));
      return;
    }
    if (arg == 'off' || arg == 'standard' || arg == 'none') {
      setModelDirect(null);
      _system(
          'Nymbot Pro off — back to standard multi-model routing (standard credits).');
      return;
    }
    final picked = _catalog.byKey(arg);
    if (picked == null) {
      // Unknown model: KEEP the current pin (pms.js:2139-2142).
      _system(
          'Unknown model "$arg". Type ?model to see the available Pro models.');
      return;
    }
    setModelDirect(picked);
    _system('Nymbot Pro model set to ${picked.label} — every reply now uses '
        'it (${picked.priceLabel}). Type ?model off to switch back.');
  }

  // --- ?clear (pms.js `_clearBotPMHistory`, :1894-1917) -----------------------

  Future<void> clearBotPMHistory() async {
    // Snapshot the thread's wrap ids BEFORE the local wipe — they key the D1
    // archive purge (`_purgeBotPMArchive` collects them from `pmMessages`,
    // pms.js:1885-1887; non-hex local ids are filtered by the purger).
    final ids = [for (final m in _thread) m.id];
    _setClearedAt(DateTime.now().millisecondsSinceEpoch ~/ 1000);
    // Best-effort server-side context wipe (`_clearBotServerThread`).
    if (_pubkey != null) {
      final anonId = anon.ready ? anon.identity : null;
      final pk = anonId?.pk ?? _pubkey!;
      unawaited(_service
          .clearHistory(
              pubkey: pk,
              anon: anonId != null,
              auth: () => anonId != null
                  ? anon.authFor('clear-history')
                  : _authFor('clear-history'))
          .catchError((_) => <String, dynamic>{}));
    }
    // Batch pm-delete of the thread's wraps from the D1 archive so no device
    // can restore the cleared thread (`_purgeBotPMArchive`, pms.js:1900).
    final purge = pmArchivePurger;
    if (purge != null) unawaited(purge(ids));
    // Sync the cleared-at marker so other devices filter the thread too,
    // covering any archived wraps this device didn't know about
    // (`_debouncedNostrSettingsSave(2000)`, pms.js:1901-1903).
    settingsSyncRequester?.call();
    // Wipe the local thread from the canonical store + the transient bubbles.
    for (final id in ids) {
      _app.removeMessage(id);
    }
    _handledIds.clear();
    _lastLen = 0;
    _lastLastId = '';
    // Re-render the empty conversation TRANSIENTLY, like the PWA's
    // `loadPMMessages(conversationKey, true)` + `displaySystemMessage`
    // (pms.js:1908-1916): start line, NO welcome (clearedAt), then the
    // confirmation — none of it enters the persisted store.
    state = state.copyWith(infoMessages: const <Message>[]);
    _displayTransientSystem('Start of private message', id: 'nymbot-start');
    _displayTransientSystem(
        'Nymbot chat cleared — starting fresh. Earlier messages are no '
        'longer used as context.');
  }

  // --- ?help (pms.js `_displayBotPmHelp`, :1733-1770) -------------------------

  /// The live Pro model catalog, or the built-in list when it hasn't loaded.
  ProModelCatalog get _catalog {
    final cat = _ref.read(proModelCatalogProvider);
    return cat.isEmpty ? kProModelCatalogFallback : cat;
  }

  void _displayBotPmHelp() {
    final proModel = state.proModel;
    final git = state.git;
    // ?help lists a sample rather than the whole live catalog, which can run
    // to dozens of models.
    final allModels = _catalog.models;
    final modelLines = [
      for (final m in allModels.take(8))
        '  `${m.key}` — ${m.label}, ${m.priceLabel}',
      if (allModels.length > 8)
        '  …and ${allModels.length - 8} more — type `?model` or tap the model button.',
    ];
    final statusBits = <String>[];
    if (state.balanceKnown) {
      final std = state.balance.balance;
      final pro = state.balance.proBalance;
      statusBits.add('$std standard credit${std == 1 ? '' : 's'}');
      statusBits.add('$pro Pro credit${pro == 1 ? '' : 's'}');
    }
    statusBits.add(proModel != null
        ? 'Pro model: ${proModel.label}'
        : 'Pro model: off (standard routing)');
    if (git != null && git.hasRepo) {
      statusBits.add(
          'repo: ${git.repo}${git.allowWrites ? ' (writes on)' : ' (read-only)'}');
    }
    _displayBotInfoMessage(
        [
          '**📖 Nymbot premium guide**',
          // The status line renders in italics (`<em>`, pms.js:1749).
          '*You right now: ${statusBits.join(' · ')}.*',
          '',
          '**1. Standard premium (this chat)**',
          'Each message is auto-routed to the best AI model for its task. Replies cost **standard credits** (10 sats each, bulk bonuses from 500 sats): 1 credit for general chat, creative writing, or translation; 2 credits for coding or reasoning/math.',
          '',
          '**2. Nymbot Pro**',
          'Pin every reply to a specific frontier model instead of auto-routing. Pro replies spend separate **Pro credits** (100 sats each, bulk bonuses from 5K sats):',
          ...modelLines,
          'Pick with `?model <name>` (e.g. `?model claude-opus`), back to standard with `?model off`. Buy Pro credits via `?buy` → Pro switch.',
          '',
          '**3. Git repos (Pro)**',
          'Connect a repository — GitHub, GitLab, or Gitea/Forgejo (incl. Codeberg & self-hosted) — and Pro replies become a coding agent over your real code: it lists, reads, and searches files, and with writes enabled it commits to a branch (or directly) and opens pull/merge requests.',
          'Setup: `?git provider github|gitlab|gitea [host]` → `?git token <pat>` → `?git repos` → `?git repo owner/name [branch]` → optionally `?git writes on`. Type `?git` anytime for status.',
          "Repo tasks use up to 6 model calls, each at the model's Pro credit price — only calls actually used are charged. Your token stays on this device, is never published to relays, and is never stored server-side.",
          '',
          '**4. Credits**',
          '`?balance` shows both balances · `?buy` purchases over Lightning (Standard/Pro switch) · `?gift @nym#xxxx` gifts credits · `?transfer @nym#xxxx confirm` moves your ENTIRE balance (both pools) to another pubkey.',
          'Credits are tied to your nym — save your nsec (sidebar → your nym → Reveal private key) so they survive a new session.',
          '',
          '**5. Chat tricks**',
          'Start a message with `!` for a one-off answer that ignores history · `?clear` wipes the conversation · quote-reply any message to ask a follow-up about it.',
          '',
          'This guide is free — type `?help` anytime.',
        ].join('\n'),
        id: 'nymbot-help-${DateTime.now().millisecondsSinceEpoch}');
  }

  // --- ?gift (pms.js `_handleBotPM` ?gift branch, :2426-2441) -----------------

  void _handleGiftCommand(String trimmed) {
    final arg = trimmed
        .replaceFirst(RegExp(r'^\?gift\b', caseSensitive: false), '')
        .trim()
        .replaceFirst(RegExp(r'^@'), '');
    if (arg.isEmpty) {
      _system('Usage: ?gift @nym#xxxx — gift Nymbot credits to another user.');
      return;
    }
    final giftPubkey = resolvePubkeyFromNym(arg);
    if (giftPubkey == null) {
      _system('Could not find user "$arg". Try ?gift with their full nym '
          '(e.g. ?gift @cyber_wolf#a3f2).');
      return;
    }
    final giftNym = stripPubkeySuffix(
        _appState.users[giftPubkey]?.nym ?? giftPubkey.substring(0, 8));
    // Open the gift-credit modal prefilled with the recipient
    // (`showBotCreditsModal({pubkey, nym})`) via the shared mailbox the shell
    // listens to.
    _ref
        .read(giftCreditsRequestProvider.notifier)
        .request(pubkey: giftPubkey, nym: giftNym);
  }

  // --- ?transfer (pms.js `_handleBotTransferCommand`, :1919-1976) -------------

  Future<void> handleTransferCommand(String trimmed) async {
    final raw = trimmed
        .replaceFirst(RegExp(r'^\?transfer\b', caseSensitive: false), '')
        .trim();
    final parts = raw.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final confirming =
        parts.isNotEmpty && parts.last.toLowerCase() == 'confirm';
    final targetArg = (confirming ? parts.sublist(0, parts.length - 1) : parts)
        .join(' ')
        .trim()
        .replaceFirst(RegExp(r'^@'), '');
    if (targetArg.isEmpty) {
      _system('Usage: ?transfer @nym#xxxx or ?transfer <npub/hex pubkey> — '
          'moves your entire Nymbot credit balance to another pubkey. Append '
          '"confirm" to execute (e.g. ?transfer @friend#a1b2 confirm).');
      return;
    }
    // A public key in either accepted form — hex, npub or nprofile —
    // otherwise a nym to resolve.
    var targetPubkey = normalizePubkeyInput(targetArg);
    targetPubkey ??= resolvePubkeyFromNym(targetArg);
    if (targetPubkey == null) {
      _system('Could not resolve "$targetArg". Try ?transfer with a full nym '
          '(e.g. ?transfer @friend#a1b2 confirm), an npub, or a 64-char hex '
          'pubkey.');
      return;
    }
    if (targetPubkey == _appState.selfPubkey) {
      _system("You can't transfer credits to your own pubkey.");
      return;
    }
    final targetNym = stripPubkeySuffix(
        _appState.users[targetPubkey]?.nym ?? targetPubkey.substring(0, 8));

    if (!confirming) {
      await checkBotCredits(display: false);
      final have = state.balance.balance;
      final havePro = state.balance.proBalance;
      if (have <= 0 && havePro <= 0) {
        _system('You have no Nymbot credits to transfer.');
        return;
      }
      final segs = <String>[];
      if (have > 0) segs.add('$have credit${have == 1 ? '' : 's'}');
      if (havePro > 0) {
        segs.add('$havePro Pro credit${havePro == 1 ? '' : 's'}');
      }
      _system('Transfer ALL ${segs.join(' and ')} to @$targetNym? This '
          'empties your balance. To confirm, type: ?transfer @$targetNym'
          '#${getPubkeySuffix(targetPubkey)} confirm');
      return;
    }

    try {
      final res = await transferCredits(targetPubkey);
      if (res == null || res['error'] != null) {
        _system('Transfer failed: ${res?['error'] ?? 'request failed'}');
        return;
      }
      final moved = <String>[];
      final transferred = (res['transferred'] as num?)?.toInt() ?? 0;
      final proTransferred = (res['proTransferred'] as num?)?.toInt() ?? 0;
      if (transferred > 0) {
        moved.add('$transferred credit${transferred == 1 ? '' : 's'}');
      }
      if (proTransferred > 0) {
        moved
            .add('$proTransferred Pro credit${proTransferred == 1 ? '' : 's'}');
      }
      _system(
          'Transferred ${moved.isEmpty ? '0 credits' : moved.join(' and ')} '
          'to @$targetNym. Your balance is now 0.');
    } on NymbotException catch (e) {
      // `status >= 400` → `'Transfer failed: ' + (data.error || 'request
      // failed')` (pms.js:1965-1967).
      _system('Transfer failed: ${_errorDetail(e) ?? 'request failed'}');
    } catch (_) {
      _system('Transfer failed. Please try again.');
    }
  }

  /// Resolves a nym argument to a pubkey, mirroring the PWA's
  /// `resolvePubkeyFromNym` priority: exact `base#suffix` first, then a bare
  /// base-nym match (case-insensitive). Returns null when nothing matches.
  String? resolvePubkeyFromNym(String arg) {
    final raw = arg.trim().replaceFirst(RegExp(r'^@'), '');
    if (raw.isEmpty) return null;
    if (RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(raw)) {
      return raw.toLowerCase();
    }
    final users = _appState.users;
    final needle = raw.toLowerCase();
    for (final entry in users.entries) {
      final full =
          '${stripPubkeySuffix(entry.value.nym)}#${getPubkeySuffix(entry.key)}';
      if (full.toLowerCase() == needle) return entry.key;
    }
    for (final entry in users.entries) {
      if (stripPubkeySuffix(entry.value.nym).toLowerCase() == needle) {
        return entry.key;
      }
    }
    return null;
  }

  // --- ?git (pms.js `_handleBotGitCommand`, :2224-2348) -----------------------

  Future<void> handleGitCommand(String trimmed) async {
    final parts = trimmed
        .replaceFirst(RegExp(r'^\?(github|git)\b', caseSensitive: false), '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    final cmd = (parts.isNotEmpty ? parts[0] : 'status').toLowerCase();
    var cfg = state.git ??
        const GitConfig(provider: GitProvider.github, host: 'github.com');
    final provInfo = cfg.provider;

    if (cmd == 'provider') {
      final name = (parts.length > 1 ? parts[1] : '').toLowerCase();
      GitProvider? provider;
      for (final p in GitProvider.values) {
        if (p.wire == name) provider = p;
      }
      if (provider == null) {
        _system('Usage: ?git provider github|gitlab|gitea [host] — e.g. '
            '?git provider gitlab, ?git provider gitea codeberg.org, or a '
            'self-hosted domain like ?git provider gitlab git.mycompany.com. '
            'Switching providers clears the saved token and repo.');
        return;
      }
      var host = (parts.length > 2 ? parts[2] : '').toLowerCase();
      if (host.isEmpty) host = provider.defaultHost;
      if (!RegExp(r'^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$').hasMatch(host)) {
        _system('Invalid host name.');
        return;
      }
      // Switching providers clears the saved token and repo (fresh config).
      connectGit(GitConfig(provider: provider, host: host));
      _system('Provider set to ${provider.label} at $host. Now add a token: '
          '?git token <${provider.tokenHint.split(' (').first}>.');
      return;
    }

    if (cmd == 'token') {
      final token = parts.length > 1 ? parts[1] : '';
      if (!NymbotService.gitTokenValid(cfg, token)) {
        _system("That doesn't look like a valid ${provInfo.label} token. "
            'Create a ${provInfo.tokenHint} scoped to just the repos you want '
            'Nymbot to use, then run ?git token <token>.');
        return;
      }
      cfg = cfg.copyWith(token: token, login: null);
      connectGit(cfg);
      final who = await _service.gitApi(cfg, NymbotService.gitUserPath());
      final login = NymbotService.gitUserLogin(cfg, who.data);
      if (who.ok && login.isNotEmpty) {
        cfg = cfg.copyWith(login: login);
        connectGit(cfg);
        _system('${provInfo.label} token saved for @$login (stored only on '
            'this device). Next: ?git repos to list repos, then '
            '?git repo owner/name.');
      } else {
        _system('${provInfo.label} token saved, but it could not be verified'
            '${who.status != 0 ? ' (HTTP ${who.status})' : ''}. Check that '
            "it's valid and has repo access.");
      }
      return;
    }

    if (cmd == 'repos') {
      if (!cfg.hasToken) {
        _system(
            'No ${provInfo.label} token yet — run ?git token <token> first.');
        return;
      }
      final res = await _service.gitApi(cfg, NymbotService.gitReposPath(cfg));
      final data = res.data;
      if (!res.ok || data is! List) {
        _system('Could not list repos (HTTP '
            '${res.status != 0 ? res.status : '?'}). Check the token with '
            '?git status.');
        return;
      }
      if (data.isEmpty) {
        _system("The token can't see any repos. Grant it repository access "
            'on ${provInfo.label}.');
        return;
      }
      final lines = [
        for (final r in data)
          '• `${NymbotService.gitRepoFullName(cfg, r)}`'
              '${(r is Map && (r['private'] == true || r['visibility'] == 'private')) ? ' 🔒' : ''}',
      ];
      _displayBotInfoMessage([
        'Repos this token can access:',
        ...lines,
        'Select one with `?git repo owner/name [branch]`.',
      ].join('\n'));
      return;
    }

    if (cmd == 'repo') {
      if (!cfg.hasToken) {
        _system(
            'No ${provInfo.label} token yet — run ?git token <token> first.');
        return;
      }
      final repo = (parts.length > 1 ? parts[1] : '').trim();
      if (!NymbotService.gitRepoRe(cfg).hasMatch(repo)) {
        _system('Usage: ?git repo owner/name [branch] (run ?git repos to see '
            'what the token can access).');
        return;
      }
      final res =
          await _service.gitApi(cfg, NymbotService.gitRepoPath(cfg, repo));
      if (!res.ok || res.data == null) {
        _system("Can't access $repo (HTTP "
            "${res.status != 0 ? res.status : '?'}). Check the name and the "
            "token's repo access.");
        return;
      }
      final fullName = NymbotService.gitRepoFullName(cfg, res.data);
      final branchArg = parts.length > 2 ? parts[2] : '';
      final branchOk = branchArg.isNotEmpty &&
          RegExp(r'^[\w./-]{1,100}$').hasMatch(branchArg);
      cfg = cfg.copyWith(
        repo: fullName.isNotEmpty ? fullName : repo,
        branch: branchOk ? branchArg : null,
      );
      connectGit(cfg);
      final defaultBranch =
          (res.data is Map) ? (res.data as Map)['default_branch'] : null;
      final branchLabel =
          branchOk ? branchArg : '${defaultBranch ?? 'default'} (default)';
      _system('Repo connected: ${cfg.repo} on branch $branchLabel, '
          '${cfg.allowWrites ? 'writes enabled' : 'read-only'}. Every Pro '
          'reply now works inside this repo.'
          '${state.proModel == null ? ' ⚠ Pick a Pro model first with ?model — repo mode needs one.' : ''}');
      return;
    }

    if (cmd == 'branch') {
      if (!cfg.hasRepo) {
        _system('Select a repo first: ?git repo owner/name.');
        return;
      }
      final branch = (parts.length > 1 ? parts[1] : '').trim();
      if (branch.isNotEmpty && !RegExp(r'^[\w./-]{1,100}$').hasMatch(branch)) {
        _system('Invalid branch name.');
        return;
      }
      cfg = cfg.copyWith(branch: branch.isEmpty ? null : branch);
      connectGit(cfg);
      _system(branch.isNotEmpty
          ? 'Working branch set to $branch.'
          : 'Working branch reset to the repo default.');
      return;
    }

    if (cmd == 'writes') {
      if (!cfg.hasRepo) {
        _system('Select a repo first: ?git repo owner/name.');
        return;
      }
      final arg = (parts.length > 1 ? parts[1] : '').toLowerCase();
      if (arg != 'on' && arg != 'off') {
        _system('Usage: ?git writes on or ?git writes off.');
        return;
      }
      cfg = cfg.copyWith(allowWrites: arg == 'on');
      connectGit(cfg);
      _system(cfg.allowWrites
          ? 'Writes enabled — Nymbot can now commit files, create branches, '
              'and open pull/merge requests in the connected repo. Make sure '
              'the token has content and pull-request write access.'
          : 'Writes disabled — Nymbot is back to read-only repo access.');
      return;
    }

    if (cmd == 'off') {
      cfg = cfg.copyWith(repo: '', branch: null, allowWrites: false);
      if (cfg.hasToken) {
        connectGit(cfg);
      } else {
        disconnectGit();
      }
      _system('Repo disconnected — Pro replies are back to normal chat. The '
          'token is still saved; ?git disconnect removes it too.');
      return;
    }

    if (cmd == 'disconnect') {
      disconnectGit();
      _system('Git provider disconnected — token and repo selection removed '
          'from this device.');
      return;
    }

    // Bare `?git` (or unknown subcommand) → the status card (pms.js:2339-2348).
    final proModel = state.proModel;
    _displayBotInfoMessage([
      '**Nymbot × Git** — let Pro replies work inside one of your repos, '
          'Claude Code-style: it reads your actual files and, if you allow '
          'writes, commits to a branch (or directly) and opens pull/merge '
          'requests. Supports GitHub, GitLab, and Gitea/Forgejo (incl. '
          'Codeberg and self-hosted).',
      'Provider: **${provInfo.label}** at '
          '**${cfg.host.isNotEmpty ? cfg.host : provInfo.defaultHost}** — '
          'change with `?git provider github|gitlab|gitea [host]`',
      'Token: ${cfg.hasToken ? (cfg.login != null ? 'connected as **@${cfg.login}**' : 'saved') : 'not set — `?git token <token>` (${provInfo.tokenHint})'}',
      'Repo: ${cfg.hasRepo ? '**${cfg.repo}**${cfg.branch != null && cfg.branch!.isNotEmpty ? ' @ ${cfg.branch}' : ''} (${cfg.allowWrites ? 'writes enabled' : 'read-only'})' : 'none — `?git repos` then `?git repo owner/name`'}',
      'Pro model: ${proModel != null ? proModel.label : 'none — repo mode requires one (`?model`)'}',
      '',
      'Commands: `?git provider …` · `?git token <pat>` · `?git repos` · '
          '`?git repo owner/name [branch]` · `?git branch [name]` · '
          '`?git writes on|off` · `?git off` · `?git disconnect`',
      'Pricing: repo tasks run as an agent with up to 6 model calls per '
          'message${proModel != null ? ' (${proModel.label}: ${proModel.priceLabel} per call)' : ''} '
          "— the worst case is reserved from your balance, but you're only "
          'charged for the calls and reply length actually used.',
      'Privacy: the token stays on this device (cleared by Panic Mode), is '
          'sent only to the Nymbot worker with each repo message, and is '
          'never stored server-side or published to relays. Use a token '
          'scoped to just the repos you need — read-only unless you enable '
          'writes.',
    ].join('\n'));
  }

  // --- Purchases ----------------------------------------------------------------

  /// Creates a buy invoice (Standard/Pro). When [recipientPubkey] is set the
  /// credits are gifted to that user (PWA `generateBotCreditInvoice` with
  /// `reqExtra.recipientPubkey`, zaps.js:606). [comment] is attached to the
  /// invoice; [zapRequest] is the signed NIP-57 kind-9734 the worker keeps for
  /// its `canNip57` verify fallback (zaps.js:601-604). Returns null if not
  /// bound.
  Future<BotInvoice?> buy(
    int amountSats,
    CreditTier tier, {
    String? recipientPubkey,
    String? comment,
    Map<String, dynamic>? zapRequest,
  }) async {
    if (_pubkey == null) return null;
    // A gift to my own pubkey is just a normal self-buy (PWA drops the
    // recipient when `giftPk === this.pubkey`, zaps.js:606).
    final recip = (recipientPubkey != null && recipientPubkey != _pubkey)
        ? recipientPubkey
        : null;
    return _service.buy(
      amountSats: amountSats,
      tier: tier,
      pubkey: _pubkey!,
      auth: () => _authFor('create-invoice'),
      recipientPubkey: recip,
      zapRequest: zapRequest,
      comment: comment,
    );
  }

  /// One settlement check for [invoice]: asks the worker whether the invoice is
  /// paid (`check-invoice`) and, once paid, claims the credits (`claim-credits`)
  /// and refreshes the balance. Returns true when the credits have been
  /// claimed. Mirrors the PWA's `_checkBotInvoicePaid` + `_claimBotCredits`
  /// (zaps.js:697-736). Returns false (never throws) when not bound or on a
  /// transient error, so the caller can keep polling.
  Future<bool> checkInvoicePaid(BotInvoice invoice) async {
    if (_pubkey == null || invoice.invoiceId.isEmpty) return false;
    try {
      final check = await _service.checkInvoice(
        invoiceId: invoice.invoiceId,
        pubkey: _pubkey!,
        auth: () => _authFor('check-invoice'),
      );
      if (check['paid'] != true) return false;
      // Paid → claim the credits (idempotent server-side). `gifterNym` names
      // the sender in the recipient's gift DM (zaps.js:755-756).
      final app = _appState;
      final gifterNym = app.selfPubkey.isNotEmpty
          ? '${stripPubkeySuffix(app.selfNym)}#${getPubkeySuffix(app.selfPubkey)}'
          : null;
      final claim = await _service.claimCredits(
        invoiceId: invoice.invoiceId,
        pubkey: _pubkey!,
        auth: () => _authFor('claim-credits'),
        gifterNym: gifterNym,
      );
      if (claim['error'] != null) return false;
      // Publish the server's pre-signed gift DM so a gifted recipient learns
      // of the credits immediately (`sendDMToRelays(['EVENT', data.giftEvent])`,
      // zaps.js:758-760).
      final giftEvent = claim['giftEvent'];
      if (giftEvent is Map) {
        _publishDmEvent(giftEvent.cast<String, dynamic>());
      }
      // Reflect the new balance.
      await refreshBalance();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Transfers ALL of the user's credits (standard + Pro) to [targetPubkey]
  /// (`action: transfer-credits`, PWA `_handleBotTransferCommand`, pms.js:1919).
  /// On success the local balances are zeroed and the worker response (with
  /// `transferred`/`proTransferred`) is returned. Returns null if not bound.
  Future<Map<String, dynamic>?> transferCredits(String targetPubkey) async {
    if (_pubkey == null) return null;
    final res = await _service.transfer(
        pubkey: _pubkey!,
        targetPubkey: targetPubkey,
        auth: () => _authFor('transfer-credits'));
    // Mirror the PWA: zero the displayed balances once the transfer succeeds.
    if (res['error'] == null) {
      final b = state.balance;
      state = state.copyWith(
        balance: BotBalance(
          balance: 0,
          totalPurchased: b.totalPurchased,
          totalUsed: b.totalUsed,
          proBalance: 0,
          proTotalPurchased: b.proTotalPurchased,
          proTotalUsed: b.proTotalUsed,
        ),
      );
    }
    return res;
  }
}

/// The private Nymbot chat engine. Also observes the canonical PM store so a
/// message sent to the bot from ANY surface (bot screen or the canonical PM
/// composer) triggers the paid request/reply flow.
final botChatControllerProvider =
    StateNotifierProvider<BotChatController, BotChatState>((ref) {
  final controller = BotChatController(ref, ref.watch(nymbotServiceProvider));
  ref.listen<AppState>(appStateProvider, (prev, next) {
    controller.onAppState(next);
  });
  return controller;
});

/// Merges the canonical store thread with the controller's transient info
/// bubbles ([BotChatState.infoMessages]), ordered by wall-clock timestamp; at
/// an equal stamp store rows sort first (so the empty-thread welcome lands
/// right after the 'Start of private message' line, matching the PWA's DOM
/// append order). Shared by the single-view `BotChatScreen` message area and
/// the columns deck's bot column — the info bubbles never enter the shared
/// store, so a store-only render would drop them.
List<Message> mergeBotThreadWithInfo(List<Message> store, List<Message> info) {
  if (info.isEmpty) return store;
  final merged = <({Message m, bool isInfo, int idx})>[
    for (var i = 0; i < store.length; i++) (m: store[i], isInfo: false, idx: i),
    for (var i = 0; i < info.length; i++) (m: info[i], isInfo: true, idx: i),
  ];
  merged.sort((a, b) {
    final dt = a.m.timestamp - b.m.timestamp;
    if (dt != 0) return dt;
    if (a.isInfo != b.isInfo) return a.isInfo ? 1 : -1;
    return a.idx - b.idx;
  });
  return [for (final e in merged) e.m];
}

/// Convenience: the catalogue of public `?` commands (for help/autocomplete UI).
final botCommandsProvider = Provider<List<BotCommand>>((_) => kBotCommands);

/// The live Pro model catalog, cached on disk and refreshed in the background.
///
/// Reads the worker's `models` action, which serves whatever the hourly
/// catalog worker mirrored out of Cloudflare's model docs — so a model
/// Cloudflare adds becomes selectable without an app release. Every failure
/// path lands on [kProModelCatalogFallback], the list compiled into the
/// binary, so the picker is never empty.
class ProModelCatalogNotifier extends StateNotifier<ProModelCatalog> {
  ProModelCatalogNotifier(this._service) : super(kProModelCatalogFallback) {
    _hydrate();
  }

  static const _prefKey = 'nym_botpm_model_catalog';
  static const _ttl = Duration(hours: 6);

  final NymbotService _service;
  bool _loading = false;

  Future<void> _hydrate() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefKey);
      if (raw != null && raw.isNotEmpty) {
        final cached = ProModelCatalog.fromJson(
            (jsonDecode(raw) as Map).cast<String, dynamic>());
        if (!cached.isEmpty && mounted) state = cached;
        final age = DateTime.now().millisecondsSinceEpoch - cached.fetchedAt;
        if (age < _ttl.inMilliseconds) return;
      }
    } catch (_) {
      // A corrupt cache is not worth surfacing — refresh over it.
    }
    await refresh();
  }

  /// Fetches the catalog. Safe to call often: overlapping calls collapse, and
  /// a failure leaves whatever list is already showing in place.
  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final cat = await _service.fetchModelCatalog();
      if (cat == null || cat.isEmpty) return;
      if (mounted) state = cat;
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(_prefKey, jsonEncode(cat.toJson()));
      } catch (_) {
        // Cache write failures only cost a refetch next launch.
      }
    } finally {
      _loading = false;
    }
  }
}

final proModelCatalogProvider =
    StateNotifierProvider<ProModelCatalogNotifier, ProModelCatalog>((ref) {
  return ProModelCatalogNotifier(ref.watch(nymbotServiceProvider));
});

/// Convenience: the Pro model list (for the `?model` picker).
final proModelsProvider =
    Provider<List<ProModel>>((ref) => ref.watch(proModelCatalogProvider).models);

// =============================================================================
/// The welcome copy, as the localizer needs to see it.
///
/// These are app copy, not user content, so they localize through the same
/// UI-string cache as every other string (`tr`) rather than through the
/// message auto-translator: the cache persists across launches, works offline
/// once filled, and follows a later language change instead of being frozen
/// into a stored message. [primeBotWelcomeCopy] warms them the moment a
/// language is chosen, so the greeting is usually translated before it is
/// first shown.
List<String> botWelcomeSourceStrings() => const [
      botWelcomeText,
      botFirstContactText,
    ];

/// Pre-translates the welcome copy into the active language. Called when the
/// language is picked at signup — the greeting arrives seconds later, and
/// waiting for it to render before translating it would show English first.
void primeBotWelcomeCopy() {
  LocalizationService.instance.prime(botWelcomeSourceStrings());
}

// Welcome copy (pms.js `_botWelcomeHtml` :1706-1729 / `_botFirstContactText`
// :1822-1838) — verbatim, with the HTML `<strong>`/`<code>` markers as the
// markdown the shared formatter renders.
// =============================================================================

/// The first-person introduction rendered as a bot bubble when a user first
/// opens the premium chat.
const String botWelcomeText =
    "Hey, I'm **Nymbot** 👋 — your private, end-to-end encrypted 1:1 AI assistant.\n"
    '\n'
    "I'm smarter than the free public-channel bot. I read each message, figure out the type of task (coding, reasoning/math, creative writing, translation, or general chat) and route it to the best AI model for the job — so my answers are sharper.\n"
    '\n'
    "**Here's how to get the most out of me:**\n"
    '• `?help` — full guide to premium vs Pro, the git repo integration, and every command (free).\n'
    '• Just type normally — I use our whole conversation as context.\n'
    '• Start a message with `!` to get a one-off answer that ignores all earlier chat history (e.g. `!what is 2+2`).\n'
    "• Quote-reply any message to ask a follow-up about it — I'll see what you're replying to.\n"
    '• `?clear` — wipe this chat and start fresh.\n'
    '• `?balance` — check your credit balance (also shown in the header).\n'
    '• `?buy` — purchase more credits. `?gift @nym#xxxx` — gift credits to someone.\n'
    '• `?model` — go **Pro**: pick a specific frontier model (Claude Fable 5, Claude Opus/Sonnet/Haiku, GPT-5.6 Sol, Gemini, Grok, Kimi K3, Qwen, MiniMax) for every reply, paid with separate Pro credits.\n'
    '• `?image <description>` — generate a picture. On Pro, add `--model <name>` to pick a frontier generator (Nano Banana Pro, Imagen 4, FLUX 2, Seedream, GPT Image 2, Grok Imagine, Recraft) — `?image models` lists them free.\n'
    '• `?speak <text>` — get it read aloud as a voice clip.\n'
    '• Send or link a picture — models that can see will look at the image itself, not just the link.\n'
    '• `?git` — connect a git repo (GitHub, GitLab, Gitea/Codeberg) so Pro replies read your actual code and can even commit, branch, and open PRs — like a chat-based coding agent.\n'
    '• `?transfer @nym#xxxx confirm` — move ALL your credits to another pubkey (great for switching nyms).\n'
    '\n'
    "**Pricing:** general chat, creative writing, and translation replies cost **1 credit**. Coding and reasoning/math replies cost **2 credits** (they use larger models). Pro replies start at **1–2 Pro credits** and scale with reply length (each model's range is in `?model`). `?image` costs **5 credits** (2 Pro) and `?speak` **3 credits** (1 Pro), charged per generation — nothing is charged if it fails. Credits are tied to your nym — save your nsec so you don't lose them.\n"
    '\n'
    'So, what can I help you with?';

/// The slightly-edited welcome used for the proactive first-contact PM that
/// brand-new users receive (a REAL persisted PM in the sidebar thread).
const String botFirstContactText =
    "Welcome to **Nymchat** 👋 — I'm **Nymbot**, your built-in AI assistant.\n"
    '\n'
    'In any public channel you can ask me anything for **free** — just type `?ask <your question>` or mention `@Nymbot`. Type `?help` in a channel to see everything I can do.\n'
    '\n'
    "Right here in our private 1:1 chat is the **premium** tier: it's end-to-end encrypted and I route each message to the best AI model for the job (coding, reasoning/math, creative writing, translation, or general chat). These private replies cost **credits** — general chat, creative writing, and translation cost 1 credit each; coding and reasoning/math cost 2 credits each.\n"
    '\n'
    'Want even more power? **Nymbot Pro** lets you pick a specific frontier model — Claude Fable 5, Claude Opus, GPT-5.1, and more — for every reply. Type `?model` to see them; Pro replies use separate Pro credits. Pro can even connect to a git repo (`?git` — GitHub, GitLab, Gitea/Codeberg) to read your code and ship commits or PRs.\n'
    '\n'
    'Type `?buy` to get credits (Standard or Pro) and `?balance` to check your balance. Credits are tied to your nym, so save your nsec to keep them. Type `?help` here anytime for the full free guide to premium, Pro, and the git integration.\n'
    '\n'
    'So, what can I help you with?';

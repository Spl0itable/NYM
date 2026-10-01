/// Nymbot wiring: service, the private-chat engine over the canonical bot PM thread, and `?`/`@Nymbot` interception.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/event_kinds.dart';
import '../../core/crypto/key_format.dart' show normalizePubkeyInput;
import '../../core/crypto/gift_wrap.dart' as giftwrap;
import '../../core/crypto/schnorr.dart' as schnorr;
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
import 'bot_runs.dart';
import 'nymbot_models.dart';
import '../../services/storage/secure_store.dart';
import 'anon_bot.dart';
import 'nymbot_service.dart';

/// True for `?` followed by a non-space command token.
bool isBotCommand(String text) {
  final t = text.trimLeft();
  return t.length >= 2 && t[0] == '?' && !_isSpace(t[1]);
}

/// True when [text] mentions `@Nymbot` anywhere (case-insensitive), which routes to `?ask`.
bool isNymbotMention(String text) => _nymbotMention.hasMatch(text);

/// `@Nymbot` as a whole word, with its optional `#xxxx` discriminator so stripping doesn't leave it behind.
final RegExp _nymbotMention = RegExp(
    r'(^|[^A-Za-z0-9_])@Nymbot(?:#[0-9a-f]{4})?\b',
    caseSensitive: false);

/// Strips a leading `@Nymbot` mention and discriminator; a bare mention yields '' so [routeToBot] uses the quoted text.
String stripNymbotMention(String text) =>
    text.replaceFirst(_nymbotMention, '').trim();

bool _isSpace(String ch) => ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';

/// Bot-PM control commands handled entirely on-device: never encrypted, published, shown or stored.
final RegExp botPMCommandRe = RegExp(
    r'^\s*\?(help|commands|balance|buy|clear|transfer|gift|model|anon|git|github)\b',
    caseSensitive: false);

/// Lazy Nymbot HTTP service; no network until a method is called.
final nymbotServiceProvider = Provider<NymbotService>((ref) {
  final service = NymbotService();
  ref.onDispose(service.dispose);
  return service;
});

/// Request to open the credits buy modal with [tier] preselected; listeners open it, then consume.
class BotBuyRequest {
  const BotBuyRequest({required this.tier});
  final CreditTier tier;
}

class BotBuyRequestHooks extends StateNotifier<BotBuyRequest?> {
  BotBuyRequestHooks() : super(null);

  void request(CreditTier tier) => state = BotBuyRequest(tier: tier);

  /// Clears the request once the modal has opened.
  void consume() => state = null;
}

/// The `?buy` mailbox.
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

const String kBotPriceUnavailableText =
    "Nymbot can't check the Bitcoin price right now, so it couldn't price "
    'this message. Nothing was charged. Tap Retry to send it again once the '
    'price is back.';

String botSendErrorText(NymbotException e) => e.priceUnavailable
    ? kBotPriceUnavailableText
    : 'Nymbot: ${BotChatController._errorDetail(e) ?? 'request failed'}';

class BotPriceRetry {
  const BotPriceRetry({required this.message, this.wrapId});

  final Message message;
  final String? wrapId;
}

/// Private chat controls; the conversation lives in the canonical PM store.
class BotChatState {
  const BotChatState({
    this.proModel,
    this.balance = BotBalance.empty,
    this.balanceKnown = false,
    this.balanceUnavailable = false,
    this.sending = false,
    this.clearedAtSec = 0,
    this.infoMessages = const <Message>[],
    this.anonEnabled = false,
    this.anonPubkey,
    this.priceRetry,
    this.runsVersion = 0,
  });

  final BotPriceRetry? priceRetry;

  final int runsVersion;

  /// Pinned Pro model, or null for standard routing.
  final ProModel? proModel;

  final BotBalance balance;

  /// True once a balance has landed; until then the header says "checking credits…".
  final bool balanceKnown;

  /// A check failed before any balance landed; cleared when one arrives.
  final bool balanceUnavailable;

  final bool sending;

  /// `?clear` watermark in seconds (0 = never); a cleared chat is empty but gets no welcome.
  final int clearedAtSec;

  /// Local-only info bubbles (welcome, `?help`, command output), never stored; merged into the thread by timestamp.
  final List<Message> infoMessages;

  final bool anonEnabled;

  final String? anonPubkey;

  bool get isPro => proModel != null;

  BotChatState copyWith({
    Object? proModel = _sentinel,
    BotBalance? balance,
    bool? balanceKnown,
    bool? balanceUnavailable,
    bool? sending,
    int? clearedAtSec,
    List<Message>? infoMessages,
    bool? anonEnabled,
    Object? anonPubkey = _sentinel,
    Object? priceRetry = _sentinel,
    int? runsVersion,
  }) =>
      BotChatState(
        proModel: identical(proModel, _sentinel)
            ? this.proModel
            : proModel as ProModel?,
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
        priceRetry: identical(priceRetry, _sentinel)
            ? this.priceRetry
            : priceRetry as BotPriceRetry?,
        runsVersion: runsVersion ?? this.runsVersion,
      );

  static const _sentinel = Object();
}

/// Private Nymbot engine over the canonical PM store; sends are refused until [bind].
class BotChatController extends StateNotifier<BotChatState> {
  BotChatController(this._ref, this._service) : super(const BotChatState()) {
    _hydrate();
    // Restored history isn't a new send.
    _primeHandled(_thread);
    // Re-resolve a pin only the live catalog knows once it loads, so it isn't dropped to standard routing.
    _ref.listen<ProModelCatalog>(proModelCatalogProvider, (_, next) {
      if (!mounted || _pendingModelKey.isEmpty) return;
      final m = next.byKey(_pendingModelKey);
      if (m == null) return;
      _pendingModelKey = '';
      state = state.copyWith(proModel: m);
    });
  }

  /// A pinned key no catalog knew at hydrate time.
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

  /// Own-message ids already routed (or pre-existing), so the observer never double-fires.
  final Set<String> _handledIds = <String>{};
  bool _primed = false;
  int _lastLen = -1;
  String _lastLastId = '';

  /// Ids for local-only info bubbles.
  int _infoSeq = 0;

  static const _kProModelPref = 'nym_botpm_pro_model';
  static const _kClearedAtPref = 'nym_botpm_cleared_at';
  static const _kWelcomedPref = 'nym_botpm_welcomed';
  static const _kAnonPref = 'nym_botanon_enabled';
  static const _kMaxRunsPref = 'nym_botpm_max_runs';
  static const _kInflightPref = 'nym_botpm_inflight_';

  int _maxRuns = 0;

  int get maxRuns => _maxRuns;

  late final BotRunsEngine runsEngine = BotRunsEngine(
    transport: _runsTransport,
    onDelivered: _deliverRun,
    onNoCredits: _onRunNoCredits,
    onPriceUnavailable: (run) {
      if (!mounted) return;
      state = state.copyWith(
          priceRetry: BotPriceRetry(
              message: _ownMessageFor(run.id) ?? _specMessage(run.spec),
              wrapId: run.eventId));
      _system(kBotPriceUnavailableText);
    },
    onOpenBuy: (pro) {
      if (anon.ready) {
        _ref.read(botAnonRequestProvider.notifier).request();
      } else {
        _ref
            .read(botBuyRequestProvider.notifier)
            .request(pro ? CreditTier.pro : CreditTier.standard);
      }
    },
    onChanged: () {
      if (mounted) state = state.copyWith(runsVersion: state.runsVersion + 1);
    },
    onTyping: _setBotTyping,
    onResponse: () => _markBotPMReceipts('read'),
    onPersist: _persistInflight,
    anonNow: () => anon.ready,
    maxRuns: () => _maxRuns,
    setMaxRuns: (n) => setMaxRuns(n),
  );

  Future<BotRunResponse> _runsTransport(String action, Map<String, dynamic> body,
      {Duration? timeout, bool? asAnon}) {
    final pk = _pubkey;
    if (pk == null) {
      return Future.value(
          (status: 0, data: const <String, dynamic>{}));
    }
    final anonId = (asAnon ?? anon.ready) && anon.ready ? anon.identity : null;
    return _service.botAction(
      action,
      body,
      pubkey: anonId?.pk ?? pk,
      anon: anonId != null,
      timeout: timeout,
      signedFor: (payload) async {
        if (action == 'pm') {
          return anonId != null
              ? await anon.authFor('pm', payload)
              : (await _authFor('pm', payload) ?? _auth);
        }
        return anonId != null
            ? await anon.authFor(action, payload)
            : await _authFor(action, payload);
      },
    );
  }

  void setMaxRuns(int n, {bool fromSync = false}) {
    final clean = clampBotMaxRuns(n);
    if (clean == _maxRuns) return;
    _maxRuns = clean;
    if (mounted) state = state.copyWith(runsVersion: state.runsVersion + 1);
    unawaited(_prefs.then((p) => clean > 0
        ? p.setString(_kMaxRunsPref, '$clean')
        : p.remove(_kMaxRunsPref)));
    if (!fromSync) settingsSyncRequester?.call();
  }

  void _persistInflight(List<Map<String, dynamic>> list) {
    final pk = _pubkey;
    if (pk == null) return;
    unawaited(_prefs.then((p) => list.isEmpty
        ? p.remove('$_kInflightPref$pk')
        : p.setString('$_kInflightPref$pk', jsonEncode(list))));
  }

  bool _runsResumed = false;

  Future<void> onChatOpen() async {
    final pk = _pubkey;
    if (pk == null) return;
    if (!_runsResumed) {
      _runsResumed = true;
      try {
        final p = await _prefs;
        final raw = p.getString('$_kInflightPref$pk');
        final list = raw == null ? const <Object?>[] : jsonDecode(raw);
        if (list is List && mounted) runsEngine.resume(list);
      } catch (_) {}
    }
    await pollRuns();
  }

  Future<void> pollRuns() async {
    if (_pubkey == null || !mounted) return;
    await runsEngine.poll();
  }

  bool runsSheetOpen = false;

  bool get runsPollWanted =>
      runsSheetOpen ||
      runsEngine.runs.isNotEmpty ||
      runsEngine.remote.isNotEmpty ||
      runsEngine.watchingSteers;

  void botNotice(String text) => _system(text);

  Message? _ownMessageFor(String nymMessageId) {
    for (final m in _thread) {
      if (m.isOwn && m.nymMessageId == nymMessageId) return m;
    }
    return null;
  }

  Message _specMessage(BotRunSpec spec) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return Message(
      id: spec.eventId,
      author: _appState.selfNym,
      pubkey: _pubkey ?? '',
      content: spec.content,
      createdAt: nowMs ~/ 1000,
      isOwn: true,
      isPM: true,
      nymMessageId: spec.id,
      threadRoot: spec.thread.isEmpty ? null : spec.thread,
    );
  }

  Future<void> stopRun(String id) => runsEngine.stop(id);

  Future<BotSteerOutcome> steerRun(String id, String text) =>
      runsEngine.steer(id, text);

  Future<void> sendAsMessage(String text, String thread) =>
      sendUserBotPM(text, threadRoot: thread);

  Future<void> sendSteerNote(String id) async {
    final note = runsEngine.notes[id.toLowerCase()];
    final text = note?.steerText;
    if (note == null || note.kind != BotRunNoteKind.steerLate || text == null) {
      return;
    }
    runsEngine.dismissNote(id);
    await sendAsMessage(
        text, _ownMessageFor(id)?.threadRoot ?? note.thread ?? '');
  }

  void _onRunNoCredits(Map<String, dynamic> data) {
    final pro = data['pro'] == true;
    final balance = (data['balanceCredits'] as num?)?.toDouble() ??
        (data['balance'] as num?)?.toDouble() ??
        0;
    final err = data['error'];
    final custom =
        err is String && err.isNotEmpty && err != 'Insufficient credits';
    _system(custom
        ? err
        : (pro
            ? "You're out of Nymbot Pro credits (${creditFigure(balance)} left). "
                'Type ?buy and switch to Pro, or ?model off for standard '
                'replies.'
            : "You're out of Nymbot credits (${creditFigure(balance)} left). "
                'Zap Nymbot or type ?buy to purchase more.'));
    _applyLedgerBalance(balance, pro: pro);
    _ref
        .read(botBuyRequestProvider.notifier)
        .request(pro ? CreditTier.pro : CreditTier.standard);
  }

  Future<void> _deliverRun(BotRun run, Map<String, dynamic> data) async {
    if (!mounted) return;
    final linked = data['replyTo'];
    final replyTo = linked is String &&
            RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(linked)
        ? linked.toLowerCase()
        : run.id;
    final event = data['event'];
    if (event is Map) {
      final wrapJson = event.cast<String, dynamic>();
      _publishDmEvent(wrapJson);
      await _displayBotReplyWrap(wrapJson, replyTo: replyTo);
    }
    final selfEvent = data['selfEvent'];
    if (selfEvent is Map &&
        RegExp(r'^[0-9a-f]{64}$', caseSensitive: false)
            .hasMatch((selfEvent['id'] ?? '').toString())) {
      _publishDmEvent(selfEvent.cast<String, dynamic>());
    }
    final balance = (data['balanceCredits'] as num?)?.toDouble() ??
        (data['balance'] as num?)?.toDouble();
    if (balance != null) {
      final isPro = data['pro'] == true;
      _applyLedgerBalance(balance, pro: isPro);
      final cost = (data['costCredits'] as num?)?.toDouble() ??
          (data['cost'] as num?)?.toDouble() ??
          0;
      if (isPro && cost > 0) {
        final sel = state.proModel;
        if (sel != null && cost > sel.baseCredits) {
          _system('Long reply used ${creditFigure(cost)} Pro credits. '
              'Pro balance: ${creditFigure(balance)}.');
        }
      } else if (!isPro && cost > 1) {
        _system('${data['taskType'] ?? 'Heavy'} reply used ${creditFigure(cost)} credits. '
            'Balance: ${creditFigure(balance)}.');
      }
      if (data['lowBalance'] == true) {
        _system(isPro
            ? 'Nymbot Pro credits running low: ${creditFigure(balance)} left. '
                'Type ?buy and switch to Pro to top up.'
            : 'Nymbot credits running low: ${creditFigure(balance)} '
                'credit${balance == 1 ? '' : 's'} left. '
                'Type ?buy to top up.');
      }
    }
  }

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<void> _hydrate() async {
    try {
      final p = await _prefs;
      if (!mounted) return;
      final modelKey = p.getString(_kProModelPref) ?? '';
      // Resolve through the live catalog so older pinned keys find their current model.
      final model = _catalog.byKey(modelKey) ??
          kProModelCatalogFallback.byKey(modelKey);
      // Unknown for now: hold the key until the live catalog loads.
      _pendingModelKey = (model == null && modelKey.isNotEmpty) ? modelKey : '';
      final clearedAt = int.tryParse(p.getString(_kClearedAtPref) ?? '') ?? 0;
      _maxRuns = clampBotMaxRuns(
          int.tryParse(p.getString(_kMaxRunsPref) ?? '') ?? 0);
      if (p.getString(_kAnonPref) == 'true') anon.setEnabled(true);
      // Monotonic: never regress below a synced marker that landed first.
      state = state.copyWith(
          proModel: model,
          clearedAtSec:
              clearedAt > state.clearedAtSec ? clearedAt : state.clearedAtSec);
      // Drop already-loaded messages at or before the watermark.
      if (clearedAt > 0) _purgeCleared(clearedAt);
    } catch (_) {
      // Prefs unavailable (tests): keep in-memory defaults.
    }
  }

  /// Removes bot messages at or before the `?clear` watermark so backlog or restores can't resurrect them.
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

  void _setClearedAt(int sec) {
    state = state.copyWith(clearedAtSec: sec);
    unawaited(_prefs.then((p) => p.setString(_kClearedAtPref, '$sec')));
  }

  /// Applies synced markers: welcomed only turns on, and the newest clear time wins.
  void applySyncedMarkers({bool welcomed = false, int clearedAtSec = 0}) {
    if (welcomed) {
      unawaited(_prefs.then((p) => p.setString(_kWelcomedPref, 'true')));
    }
    if (clearedAtSec > 0 && clearedAtSec > state.clearedAtSec) {
      _setClearedAt(clearedAtSec);
      // Drop the loaded pre-clear thread.
      _purgeCleared(clearedAtSec);
    }
  }

  /// Wires the identity for paid requests; [auth] overrides it for tests.
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

  /// Late-attaches the active signer so money actions get fresh signatures; keeps the bound privkey for reply unwrapping.
  void attachSigner(EventSigner? signer) {
    if (signer != null) {
      _signer = signer;
    }
  }

  /// Batch-deletes a cleared thread's wraps from the D1 archive; null before boot skips it.
  Future<void> Function(List<String> wrapIds)? pmArchivePurger;

  /// Debounced settings publish so clear/welcome markers reach other devices.
  void Function()? settingsSyncRequester;

  bool get isBound => _pubkey != null;

  /// Single-use ledger actions, signed fresh every time.
  static const Set<String> _sensitiveActions = {
    'transfer-credits',
    'create-invoice',
    'claim-credits',
    'clear-history',
  };

  /// NIP-98 auth via the signer: money actions fresh, routine ones from the 90s cache; falls back to [_auth].
  Future<Map<String, dynamic>?> _authFor(String action,
      [String? payload]) async {
    final signer = _signer;
    if (signer != null) {
      final auth = await Nip98Auth.buildSigned(
        action: action,
        url: _service.baseUrl,
        signer: signer,
        sensitive: payload != null || _sensitiveActions.contains(action),
        extraTags: payload == null
            ? const <List<String>>[]
            : <List<String>>[
                ['payload', payload]
              ],
      );
      if (auth != null) return auth;
    }
    return payload == null ? _auth : null;
  }

  /// The bot conversation's storage key (`pm-<botPubkey>`).
  static final String conversationKey = PmLogic.pmStorageKey(kNymbotPubkey);

  AppStateNotifier get _app => _ref.read(appStateProvider.notifier);
  AppState get _appState => _ref.read(appStateProvider);

  List<Message> get _thread =>
      _appState.messages[conversationKey] ?? const <Message>[];

  /// The bot's base display nym.
  String get _botNym =>
      stripPubkeySuffix(_appState.users[kNymbotPubkey]?.nym ?? 'Nymbot');

  /// Centered system line, localized here so every English caller string gets translated.
  void _system(String text) =>
      _app.addSystemMessage(tr(text), storageKey: conversationKey);

  /// Local-only bot-styled info bubble; a repeated [id] replaces the old one with a fresh timestamp.
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

  /// Local-only centered system line; a repeated [id] replaces the old row.
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

  /// Appends [msg], replacing any row with the same id.
  void _appendInfo(Message msg) {
    state = state.copyWith(infoMessages: [
      for (final m in state.infoMessages)
        if (m.id != msg.id) m,
      msg,
    ]);
  }

  /// "Thinking" heartbeat: the 30s expiry is refreshed while a reply (up to 180s) is in flight.
  Timer? _typingHeartbeat;

  void _setBotTyping(bool on) {
    _typingHeartbeat?.cancel();
    _typingHeartbeat = null;
    _pushBotTyping(on);
    if (!on) return;
    _typingHeartbeat = Timer.periodic(const Duration(seconds: 20), (t) {
      if (!mounted) { t.cancel(); return; }
      _pushBotTyping(true);
    });
  }

  void _pushBotTyping(bool on) {
    _app.setTyping(
      storageKey: conversationKey,
      pubkey: kNymbotPubkey,
      typing: on,
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 30000,
    );
  }

  /// Advances receipts on our own messages without regressing; failed ones are skipped.
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

  /// Marks the current thread as handled so only new sends react.
  void _primeHandled(List<Message> list) {
    for (final m in list) {
      _handledIds.add(m.id);
    }
    _primed = true;
    _lastLen = list.length;
    _lastLastId = list.isNotEmpty ? list.last.id : '';
  }

  /// Routes new own messages from any surface to the bot; `?` commands are pulled out of the thread and run on-device.
  void onAppState(AppState app) {
    final list = app.messages[conversationKey];
    if (list == null) return;
    if (!_primed) {
      _primeHandled(list);
      return;
    }
    // Cheap no-change guard.
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
    // Backlog or restores must never resurrect a cleared thread.
    final clearedAt = state.clearedAtSec;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final m in fresh) {
      if (clearedAt > 0 && !m.isSystemRow && m.createdAt <= clearedAt) {
        _app.removeMessage(m.id);
        continue;
      }
      if (!m.isOwn || m.kind != MessageKind.normal || m.isFileOffer) continue;
      // Only local sends may buy a reply; others were already answered on their device.
      if (!m.optimistic) continue;
      // Only live sends trigger the bot; history must never re-bill.
      if (m.isHistorical || nowMs - m.timestamp > 15000) continue;
      final content = m.content;
      if (botPMCommandRe.hasMatch(canonicalizeCommandInput(content))) {
        // Control commands never render; remove the echo, then run the command.
        _app.removeMessage(m.id);
        unawaited(handleBotPMCommand(content));
      } else {
        unawaited(_runBotExchange(m));
      }
    }
  }

  /// Empty-thread intro: start line, welcome (unless cleared), and a silent credit refresh.
  void ensureIntro() {
    final list = _thread;
    if (!_primed) _primeHandled(list);
    if (list.isNotEmpty) {
      // A non-empty conversation drops all transient bubbles on open.
      if (state.infoMessages.isNotEmpty) {
        state = state.copyWith(infoMessages: const <Message>[]);
      }
      return;
    }
    // Reset the transient layer to exactly the intro; nothing persists.
    state = state.copyWith(infoMessages: const <Message>[]);
    _displayTransientSystem('Start of private message', id: 'nymbot-start');
    if (state.clearedAtSec == 0) {
      // Rendered after the start line with a fresh timestamp.
      _displayBotInfoMessage(botWelcomeText, id: 'nymbot-welcome');
    }
    unawaited(checkBotCredits(display: false));
  }

  /// One proactive local welcome PM per device for brand-new users.
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
    // Sync the welcomed flag so other devices skip it.
    settingsSyncRequester?.call();
  }

  /// Pins or clears the Pro model directly; persisted.
  void setModelDirect(ProModel? model) {
    state = state.copyWith(proModel: model);
    _persistProModel(model);
  }

  void setBalance(BotBalance b) => state =
      state.copyWith(balance: b, balanceKnown: true, balanceUnavailable: false);

  /// Runs a `?` control command on-device; never published or billed.
  Future<void> handleBotPMCommand(String content) async {
    // Fold localized commands back to canonical English first.
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
    if (RegExp(r'^\?(git|github)\b', caseSensitive: false).hasMatch(trimmed)) {
      _system('Repositories are in the Nymbot apps, not in Nymchat. Nothing '
          'you typed after ?git was sent. Connect a repository at nymbot.ai.');
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
  }

  /// Control commands run on-device; everything else goes out as a real NIP-17 PM and to the worker by wrap id.
  Future<void> sendUserBotPM(String content, {String? threadRoot}) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    if (botPMCommandRe.hasMatch(trimmed)) {
      await handleBotPMCommand(trimmed);
      return;
    }
    String? thread = threadRoot == null || threadRoot.isEmpty ? null : threadRoot;
    if (threadRoot == null && appThreadsEnabled) {
      final at = _ref.read(activeThreadProvider);
      if (at != null && at.view == const ChatView.pm(kNymbotPubkey)) {
        thread = at.rootId;
      }
    }
    final guardKey = '${thread ?? ''}|$content';
    if (!runsEngine.guardTake(guardKey)) return;
    try {
      await _sendUserBotPMOnce(content, thread);
    } finally {
      runsEngine.guardRelease(guardKey);
    }
  }

  Future<void> _sendUserBotPMOnce(String content, String? threadRoot) async {
    final app = _appState;
    final selfPubkey = _pubkey ?? app.selfPubkey;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nymMessageId = PmLogic.generateSharedEventId();

    // Wrap the kind-14 rumor to the bot and to self and publish both; the worker fetches its wrap by id.
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
        // Record own activity like every other send surface.
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
    unawaited(_runBotExchange(msg, wrapId: botWrap?.id));
  }

  /// Publishes a pre-signed kind-1059 wrap to the DM relays; false before a publisher is wired.
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

  /// NIP-59 wraps [rumor] with the DM forward-secrecy TTL, via the local key or a remote signer.
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
        // Hybrid post-quantum when the bot announced a layered key; falls back to classical, never blocking the send.
        Uint8List? kemPk;
        try {
          kemPk = await _ref
              .read(nostrControllerProvider)
              .pqLayeredWrapKeyFor(recipientPubkey);
        } catch (_) {
          kemPk = null;
        }
        if (kemPk != null) {
          // Awaited inside the try so a seal failure is caught.
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
        // Awaited so a remote-signer seal failure is caught here.
        Uint8List? kemPk;
        try {
          kemPk = await _ref
              .read(nostrControllerProvider)
              .pqLayeredWrapKeyFor(recipientPubkey);
        } catch (_) {
          kemPk = null;
        }
        return await giftwrap.nip59WrapAsync(
          rumor: rumor,
          senderSigner: signer,
          recipientPubkey: recipientPubkey,
          expiration: expiration,
          recipientKemPublicKey: kemPk,
          layered: kemPk != null,
        );
      }
    } catch (_) {}
    return null;
  }

  static bool fromBot(NostrEvent seal, Map<String, dynamic> rumor) =>
      seal.kind == EventKind.seal &&
      seal.pubkey == kNymbotPubkey &&
      rumor['pubkey'] == seal.pubkey &&
      schnorr.verifyEvent(seal);

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

  /// Unwraps the worker's reply into the thread, splitting any leading `<think>`; undecryptable wraps arrive via relay echo.
  Future<void> _displayBotReplyWrap(Map<String, dynamic> wrapJson,
      {String? replyTo}) async {
    final sk = _privkey;
    try {
      final wrap = NostrEvent.fromJson(wrapJson);
      var candidates = anonUnwrapCandidates(wrap);
      if (candidates.isEmpty) {
        if (sk == null) return;
        // Full self candidate set, ML-KEM first, so post-quantum replies unwrap without the slower fallback.
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
      if (!fromBot(unwrapped.seal, rumor)) return;
      final msg = PmLogic.mapPmRumor(
        rumor: rumor,
        wrapId: wrap.id,
        selfPubkey: _pubkey ?? _appState.selfPubkey,
        // Seal signer must match the rumor author (NIP-59).
        senderVerified: unwrapped.seal.pubkey == (rumor['pubkey'] ?? ''),
      );
      if (msg == null) return;
      // Split a leading `<think>` block so previews see only the reply.
      final tm =
          RegExp(r'^\s*<think>([\s\S]*?)<\/think>\s*', caseSensitive: false)
              .firstMatch(msg.content);
      if (tm != null && msg.content.substring(tm.end).trim().isNotEmpty) {
        msg.thinking = tm.group(1)?.trim();
        msg.content = msg.content.substring(tm.end);
      }
      msg.author = _botNym;
      msg.isBot = true;
      msg.replyTo ??= replyTo;
      _handledIds.add(msg.id);
      _app.ingestPMMessage(msg);
    } catch (_) {
      // Can't open it locally; the relay echo will deliver it.
    }
  }

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
        extraTags: [
          if ((m.threadRoot ?? '').isNotEmpty) ['nymthread', m.threadRoot!],
        ],
      );
      final wrap = await _wrapRumor(rumor, kNymbotPubkey, sender: anonId);
      if (wrap != null && _publishDmEvent(wrap.toJson())) {
        wrapId = wrap.id;
      }
    }
    if (wrapId == null) {
      _system(
          'Nymbot: could not publish your encrypted message. Please try again.');
      return;
    }
    if (mounted) state = state.copyWith(priceRetry: null);
    final fresh = RegExp(r'^\s*!\s*\S').hasMatch(m.content);
    final pro = state.proModel;
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
    final cmdAlias = commandAliasHint(m.content);
    final run = runsEngine.start(BotRunSpec(
      id: m.nymMessageId ?? wrapId,
      eventId: wrapId,
      thread: m.threadRoot ?? '',
      content: m.content,
      extra: <String, dynamic>{
        'eventId': wrapId,
        'fresh': fresh,
        if (pro != null) 'proModel': pro.key,
        if (cmdAlias != null) 'cmdAlias': cmdAlias,
        if (pqAnnouncement != null) 'pqAnnouncement': pqAnnouncement,
      },
    ));
    await run?.done;
  }

  Future<void> retryPriceUnavailable() async {
    final retry = state.priceRetry;
    if (retry == null) return;
    state = state.copyWith(priceRetry: null);
    await _runBotExchange(retry.message, wrapId: retry.wrapId);
  }

  void dismissPriceRetry() {
    if (state.priceRetry != null) state = state.copyWith(priceRetry: null);
  }

  /// The worker `error` string from the exception body, or null.
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

  void _applyLedgerBalance(double balance, {required bool pro}) {
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

  /// Refreshes the balance; with [display] it also posts a balance bubble.
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

  /// No count ever cached: show "credits unavailable".
  void _markBalanceUnavailable() {
    if (mounted && !state.balanceKnown) {
      state = state.copyWith(balanceUnavailable: true);
    }
  }

  /// Open-time refresh convenience.
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
      // Too many models for a bubble: summarize per provider and point to the picker.
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
                '• `${m.key}`${current?.key == m.key ? ' ✓' : ''} — ${m.label}, ${_price(m)}',
            ];
      _displayBotInfoMessage([
        if (current != null)
          'Nymbot Pro model: **${current.label}** (${_price(current)}).'
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
      // Unknown model keeps the current pin.
      _system(
          'Unknown model "$arg". Type ?model to see the available Pro models.');
      return;
    }
    setModelDirect(picked);
    _system('Nymbot Pro model set to ${picked.label} — every reply now uses '
        'it (${_price(picked)}). Type ?model off to switch back.');
  }

  Future<void> clearBotPMHistory() async {
    // Snapshot wrap ids before the wipe; they key the archive purge.
    final ids = [for (final m in _thread) m.id];
    _setClearedAt(DateTime.now().millisecondsSinceEpoch ~/ 1000);
    // Best-effort server-side context wipe.
    if (_pubkey != null) {
      final anonId = anon.ready ? anon.identity : null;
      final pk = anonId?.pk ?? _pubkey!;
      unawaited(_service
          .clearHistory(
              pubkey: pk,
              anon: anonId != null,
              signedFor: (payload) async => anonId != null
                  ? await anon.authFor('clear-history', payload)
                  : (await _authFor('clear-history', payload) ?? _auth))
          .catchError((_) => <String, dynamic>{}));
    }
    // Purge the thread's wraps from the D1 archive so no device restores them.
    final purge = pmArchivePurger;
    if (purge != null) unawaited(purge(ids));
    // Sync the cleared-at marker so other devices filter the thread too.
    settingsSyncRequester?.call();
    // Wipe the local thread and transient bubbles.
    for (final id in ids) {
      _app.removeMessage(id);
    }
    _handledIds.clear();
    _lastLen = 0;
    _lastLastId = '';
    // Re-render the empty conversation transiently: start line and confirmation, no welcome.
    state = state.copyWith(infoMessages: const <Message>[]);
    _displayTransientSystem('Start of private message', id: 'nymbot-start');
    _displayTransientSystem(
        'Nymbot chat cleared — starting fresh. Earlier messages are no '
        'longer used as context.');
  }

  @override
  void dispose() {
    _typingHeartbeat?.cancel();
    runsEngine.dispose();
    super.dispose();
  }

  /// Live catalog, or the built-in list before it loads.
  ProModelCatalog get _catalog {
    final cat = _ref.read(proModelCatalogProvider);
    return cat.isEmpty ? kProModelCatalogFallback : cat;
  }

  String _price(ProModel m) {
    final cat = _catalog;
    return m.priceLine(cat.usdPerCredit, cat.minChargeCredits);
  }

  void _displayBotPmHelp() {
    final proModel = state.proModel;
    // List a sample, not the whole catalog.
    final allModels = _catalog.models;
    final modelLines = [
      for (final m in allModels.take(8))
        '  `${m.key}` — ${m.label}, ${_price(m)}',
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
    _displayBotInfoMessage(
        [
          '**📖 Nymbot premium guide**',
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
          '**3. Credits**',
          '`?balance` shows both balances · `?buy` purchases over Lightning (Standard/Pro switch) · `?gift @nym#xxxx` gifts credits · `?transfer @nym#xxxx confirm` moves your ENTIRE balance (both pools) to another pubkey.',
          'Credits are tied to your nym — save your nsec (sidebar → your nym → Reveal private key) so they survive a new session.',
          '',
          '**4. Chat tricks**',
          'Start a message with `!` for a one-off answer that ignores history · `?clear` wipes the conversation · quote-reply any message to ask a follow-up about it.',
          '',
          'This guide is free — type `?help` anytime.',
        ].join('\n'),
        id: 'nymbot-help-${DateTime.now().millisecondsSinceEpoch}');
  }

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
    _ref
        .read(giftCreditsRequestProvider.notifier)
        .request(pubkey: giftPubkey, nym: giftNym);
  }

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
    // hex, npub or nprofile; otherwise a nym to resolve.
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
      _system('Transfer failed: ${_errorDetail(e) ?? 'request failed'}');
    } catch (_) {
      _system('Transfer failed. Please try again.');
    }
  }

  /// Exact `base#suffix` first, then a case-insensitive base match; null if none.
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

  /// Creates a credits invoice; [recipientPubkey] gifts, [zapRequest] backs the worker's NIP-57 fallback. Null if unbound.
  Future<BotInvoice?> buy(
    int amountSats,
    CreditTier tier, {
    String? recipientPubkey,
    String? comment,
    Map<String, dynamic>? zapRequest,
  }) async {
    if (_pubkey == null) return null;
    // A gift to yourself is a normal self-buy.
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

  /// One settlement check that claims and refreshes once paid; never throws, so callers keep polling.
  Future<bool> checkInvoicePaid(BotInvoice invoice) async {
    if (_pubkey == null || invoice.invoiceId.isEmpty) return false;
    try {
      final check = await _service.checkInvoice(
        invoiceId: invoice.invoiceId,
        pubkey: _pubkey!,
        auth: () => _authFor('check-invoice'),
      );
      if (check['paid'] != true) return false;
      // Claim is idempotent; `gifterNym` names the sender in the gift DM.
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
      // Publish the pre-signed gift DM so the recipient learns immediately.
      final giftEvent = claim['giftEvent'];
      if (giftEvent is Map) {
        _publishDmEvent(giftEvent.cast<String, dynamic>());
      }
      await refreshBalance();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Transfers all credits to [targetPubkey], zeroing local balances on success; null if unbound.
  Future<Map<String, dynamic>?> transferCredits(String targetPubkey) async {
    if (_pubkey == null) return null;
    final res = await _service.transfer(
        pubkey: _pubkey!,
        targetPubkey: targetPubkey,
        signedFor: (payload) => _authFor('transfer-credits', payload));
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

/// Private Nymbot engine, observing the PM store so sends from any surface trigger the flow.
final botChatControllerProvider =
    StateNotifierProvider<BotChatController, BotChatState>((ref) {
  final controller = BotChatController(ref, ref.watch(nymbotServiceProvider));
  ref.listen<AppState>(appStateProvider, (prev, next) {
    controller.onAppState(next);
  });
  return controller;
});

/// Store thread merged with transient info bubbles by timestamp (store first on ties), for the screen and the columns deck.
List<Message> mergeBotThreadWithInfo(List<Message> store, List<Message> info) {
  if (info.isEmpty) return store;
  final extras = [
    for (var i = 0; i < info.length; i++) (m: info[i], idx: i),
  ]..sort((a, b) {
      final dt = a.m.timestamp - b.m.timestamp;
      return dt != 0 ? dt : a.idx - b.idx;
    });
  final out = <Message>[];
  var j = 0;
  for (final m in store) {
    while (j < extras.length && extras[j].m.timestamp < m.timestamp) {
      out.add(extras[j++].m);
    }
    out.add(m);
  }
  while (j < extras.length) {
    out.add(extras[j++].m);
  }
  return out;
}

final botCommandsProvider = Provider<List<BotCommand>>((_) => kBotCommands);

/// Disk-cached live Pro catalog refreshed in the background; failures fall back to the built-in list.
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
      // A corrupt cache isn't worth surfacing; refresh over it.
    }
    await refresh();
  }

  /// Overlapping calls collapse, and failures keep the current list.
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

final proModelsProvider =
    Provider<List<ProModel>>((ref) => ref.watch(proModelCatalogProvider).models);

/// Welcome copy localized through the UI string cache, primed as soon as a language is chosen.
List<String> botWelcomeSourceStrings() => const [
      botWelcomeText,
      botFirstContactText,
    ];

/// Pre-translates the welcome copy when the language is picked at signup.
void primeBotWelcomeCopy() {
  LocalizationService.instance.prime(botWelcomeSourceStrings());
}

/// Introduction bubble shown when a user first opens the chat.
const String botWelcomeText =
    "Hey, I'm **Nymbot** 👋 — your private, end-to-end encrypted 1:1 AI assistant.\n"
    '\n'
    "I'm smarter than the free public-channel bot. I read each message, figure out the type of task (coding, reasoning/math, creative writing, translation, or general chat) and route it to the best AI model for the job — so my answers are sharper.\n"
    '\n'
    "**Here's how to get the most out of me:**\n"
    '• `?help` — full guide to premium vs Pro, credits, and every command (free).\n'
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
    '• `?transfer @nym#xxxx confirm` — move ALL your credits to another pubkey (great for switching nyms).\n'
    '\n'
    "**Pricing:** general chat, creative writing, and translation replies cost **1 credit**. Coding and reasoning/math replies cost **2 credits** (they use larger models). Pro replies start at **1–2 Pro credits** and scale with reply length (each model's range is in `?model`). `?image` costs **5 credits** (2 Pro) and `?speak` **3 credits** (1 Pro), charged per generation — nothing is charged if it fails. Credits are tied to your nym — save your nsec so you don't lose them.\n"
    '\n'
    'So, what can I help you with?';

/// Welcome variant for the proactive first-contact PM, a real persisted message.
const String botFirstContactText =
    "Welcome to **Nymchat** 👋 — I'm **Nymbot**, your built-in AI assistant.\n"
    '\n'
    'In any public channel you can ask me anything for **free** — just type `?ask <your question>` or mention `@Nymbot`. Type `?help` in a channel to see everything I can do.\n'
    '\n'
    "Right here in our private 1:1 chat is the **premium** tier: it's end-to-end encrypted and I route each message to the best AI model for the job (coding, reasoning/math, creative writing, translation, or general chat). These private replies cost **credits** — general chat, creative writing, and translation cost 1 credit each; coding and reasoning/math cost 2 credits each.\n"
    '\n'
    'Want even more power? **Nymbot Pro** lets you pick a specific frontier model — Claude Fable 5, Claude Opus, GPT-5.1, and more — for every reply. Type `?model` to see them; Pro replies use separate Pro credits.\n'
    '\n'
    'Type `?buy` to get credits (Standard or Pro) and `?balance` to check your balance. Credits are tied to your nym, so save your nsec to keep them. Type `?help` here anytime for the full free guide to premium, Pro, and credits.\n'
    '\n'
    'So, what can I help you with?';

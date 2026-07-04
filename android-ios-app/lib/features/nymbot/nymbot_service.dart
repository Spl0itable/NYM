import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../services/api/api_client.dart';
import '../../services/api/api_config.dart';
import 'nymbot_models.dart';

/// Thin client for the Nymbot worker (`POST /api/bot`), ported from the call
/// sites in the PWA and the contract in `functions/api/bot.js`.
///
/// Two surfaces share the one endpoint:
///   * Public `?` commands  → body `{command, args, …}` → `{event}` (a signed
///     Nostr event whose `content` is the response text).
///   * Private paid chat    → body `{action, …}` → varies per action.
///
/// Private-chat actions ride the app's ONE identity-authed `/api` WebSocket
/// FIRST when the controller has wired [setApiSocketRequest], falling back to
/// the signed HTTP POST — the PWA's `_botMoneyRequest` (shop.js:155-173), whose
/// WS leg shares the single `_apiSock` with the storage sync. Public `?`
/// commands stay plain HTTP like the PWA's `fetch` in commands.js:196.
///
/// Network is **lazy**: nothing is fetched at construction; every method makes
/// exactly one request when called.
class NymbotService {
  NymbotService({
    http.Client? client,
    String? baseUrl,
    String? userAgent,
  })  : _client = client ?? http.Client(),
        _base = baseUrl ?? _defaultBase,
        _userAgent = userAgent ?? ApiConfig.userAgent;

  final http.Client _client;
  final String _base;
  final String _userAgent;

  // ===========================================================================
  // WS-first transport (`_botMoneyRequest`, shop.js:155-173)
  // ===========================================================================

  /// Per-action socket/HTTP wait (`_apiSocketSend`'s `opts.timeout || 45000`,
  /// shop.js:142). The `pm` action overrides with [_pmTimeout].
  static const Duration _defaultTimeout = Duration(seconds: 45);

  /// "Replies (especially Pro models with repo tool calls) can run long" —
  /// `_botMoneyRequest('pm', …, { timeout: 180000 })` (pms.js:2469-2470).
  static const Duration _pmTimeout = Duration(seconds: 180);

  /// WS-first transport seam: runs one raw ledger [action] over the app's ONE
  /// shared identity-authed `/api` socket — [ApiClient.botSocketRequest], the
  /// PWA's `_apiSocketSend(action, extra, {raw:true, timeout})` on the single
  /// `_apiSock` shared with the storage sync (shop.js:158-161). A null result
  /// (socket unavailable / auth-less / failed) falls back to the signed HTTP
  /// POST. Wired by the controller once the storage socket is up; null keeps
  /// this service HTTP-only (logged out / tests), mirroring the PWA's
  /// `if (this.pubkey)` gate.
  Future<({int status, Map<String, dynamic> data})?> Function(
    String action,
    Map<String, dynamic> extra, {
    Duration? timeout,
  })? _apiSocketRequest;

  /// Registers (or clears, on sign-out/identity teardown) the shared-socket
  /// request seam (see [_apiSocketRequest]). Identity switches need no special
  /// handling here: the socket lives on the controller's per-identity
  /// [ApiClient], which is disposed and rebuilt with the new identity's auth —
  /// the native analogue of the PWA's page reload dropping `_apiSock`.
  void setApiSocketRequest(
    Future<({int status, Map<String, dynamic> data})?> Function(
      String action,
      Map<String, dynamic> extra, {
      Duration? timeout,
    })? request,
  ) {
    _apiSocketRequest = request;
  }

  /// One private-chat/ledger action: WS-first over the shared authenticated
  /// socket (signed ONCE per connection by its owner), falling back to the
  /// signed HTTP POST on any socket failure — a 1:1 port of `_botMoneyRequest`
  /// (raw semantics: resolves `{status, data}` so callers can branch on
  /// `noCredits`/`error` themselves).
  ///
  /// [auth] builds the per-action NIP-98 event and is only invoked on the HTTP
  /// leg, exactly like the PWA signing `_signBotAuth(action)` at fallback time.
  Future<({int status, Map<String, dynamic> data})> _botRequest(
    String action,
    Map<String, dynamic> extra, {
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
    Duration timeout = _defaultTimeout,
  }) async {
    final ws = _apiSocketRequest;
    if (ws != null) {
      // The socket is authenticated once; frames drop pubkey/auth (the worker
      // pins the socket's pubkey). Null → fall back to HTTP (shop.js:162).
      final res = await ws(action, extra, timeout: timeout);
      if (res != null) return res;
    }
    final authEvent = auth == null ? null : await auth();
    return _postRaw(
      <String, dynamic>{
        'action': action,
        'pubkey': pubkey,
        if (authEvent != null) 'auth': authEvent,
        ...extra,
      },
      timeout: timeout,
    );
  }

  /// `https://<host>/api/bot` — the PWA hits a same-origin `/api/bot`
  /// (`_getApiHost()`); natively the host is the fixed [ApiConfig.apiHost],
  /// exactly like `ApiClient.botUrl`.
  static final String _defaultBase = 'https://${ApiConfig.apiHost}/api/bot';

  /// The `/api/bot` URL requests go to — also the `['u', url]` a NIP-98 auth
  /// event must bind to (`_signBotAuth`, pms.js:1651-1652).
  String get baseUrl => _base;

  // ===========================================================================
  // Public `?` commands
  // ===========================================================================

  /// Sends a public `?` command and returns its plain-text response.
  ///
  /// [command] is the keyword without `?` (e.g. `ask`); [args] the remainder.
  /// [geohash] scopes the channel (kind-20000 geohash channels); [conversation]
  /// is the optional reply-chain history (≤6 msgs). [channelMessages] and
  /// [activeUsers] feed the context-aware commands (`?ask`/`?summarize`/`?who`).
  ///
  /// The worker returns `{event}`; we surface `event.content` (the reply text).
  Future<String> sendPublicCommand(
    String command,
    String args, {
    String? geohash,
    List<dynamic>? conversation,
    String? senderNym,
    String? publishedContent,
    List<dynamic>? channelMessages,
    List<dynamic>? activeUsers,
  }) async {
    final body = <String, dynamic>{
      'command': command,
      'args': args,
      if (geohash != null) 'geohash': geohash,
      if (conversation != null) 'conversation': conversation,
      if (senderNym != null) 'senderNym': senderNym,
      if (publishedContent != null) 'publishedContent': publishedContent,
      if (channelMessages != null) 'channelMessages': channelMessages,
      if (activeUsers != null) 'activeUsers': activeUsers,
    };
    final json = await _post(body);
    return _extractEventContent(json);
  }

  // ===========================================================================
  // Private paid chat
  // ===========================================================================

  /// Sends a private 1:1 chat turn to Nymbot (`action: pm`).
  ///
  /// The worker's `pm` action **never accepts plaintext** (bot.js:1428-1583):
  /// the client first gift-wraps the user's message (kind 1059 to the bot),
  /// publishes it, then sends only the published wrap's [eventId] (400
  /// `"Missing message event id"` without it). [fresh] mirrors the PWA's
  /// `!`-prefixed one-off flag; [proModel] pins a Pro frontier model; [git]
  /// enables repo mode (only on Pro replies, pms.js:2455-2466). Waits up to
  /// 180s (`{ timeout: 180000 }`, pms.js:2470) on both transports.
  ///
  /// Returns the decoded response map: `{event, selfEvent, balance, cost,
  /// taskType, pro, proModel, git, modelCalls, lowBalance}` where
  /// `event`/`selfEvent` are **gift-wrapped kind-1059 replies** the caller must
  /// publish to relays and NIP-44-unwrap to display (pms.js:2489-2497). There
  /// is no plaintext `reply` field.
  ///
  /// On insufficient credits the worker returns `{noCredits, pro, balance,
  /// required, error}` — checked BEFORE the status like the PWA (pms.js:2473,
  /// the atomic-spend race 402 carries it too, bot.js:1562) and surfaced as a
  /// [NymbotInsufficientCredits] exception.
  Future<Map<String, dynamic>> sendBotMessage({
    required String pubkey,
    required String eventId,
    Future<Map<String, dynamic>?> Function()? auth,
    String? proModel,
    bool fresh = false,
    GitConfig? git,
  }) async {
    final res = await _botRequest(
      'pm',
      <String, dynamic>{
        'eventId': eventId,
        'fresh': fresh,
        if (proModel != null) 'proModel': proModel,
        if (git != null) 'git': git.toWire(),
      },
      pubkey: pubkey,
      auth: auth,
      timeout: _pmTimeout,
    );
    final json = res.data;

    if (json['noCredits'] == true) {
      throw NymbotInsufficientCredits(
        pro: json['pro'] == true,
        balance: _asInt(json['balance']),
        required: _asInt(json['required']),
        message: json['error']?.toString() ?? 'Insufficient credits',
      );
    }
    // `status >= 400 || !data || data.error` are one failure branch
    // (pms.js:2486-2487).
    _throwOnError(res);
    return json;
  }

  /// Fetches the user's standard + Pro credit balances (`action: balance`).
  Future<BotBalance> balance({
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
  }) async {
    final res = await _botRequest(
      'balance',
      const <String, dynamic>{},
      pubkey: pubkey,
      auth: auth,
    );
    // Never zero-fill from an `{error}`/error-status body — the PWA shows
    // `'Nymbot: ' + (data.error || 'could not check balance')` instead
    // (`_checkBotCredits`, pms.js:2529-2532).
    _throwOnError(res);
    return BotBalance.fromJson(res.data);
  }

  /// Creates a Lightning invoice to buy credits (`action: create-invoice`).
  ///
  /// [tier] picks Standard (10 sats/credit) or Pro (100 sats/credit).
  /// [recipientPubkey] gifts the credits to another user. [zapRequest] is an
  /// optional NIP-57 zap request the worker attaches.
  Future<BotInvoice> buy({
    required int amountSats,
    required CreditTier tier,
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
    String? recipientPubkey,
    Map<String, dynamic>? zapRequest,
    String? comment,
  }) async {
    final res = await _botRequest(
      'create-invoice',
      <String, dynamic>{
        'amountSats': amountSats,
        'tier': tier.wire,
        if (recipientPubkey != null) 'recipientPubkey': recipientPubkey,
        if (zapRequest != null) 'zapRequest': zapRequest,
        if (comment != null) 'comment': comment,
      },
      pubkey: pubkey,
      auth: auth,
    );
    _throwOnStatus(res);
    return BotInvoice.fromJson(res.data, tier: tier, amountSats: amountSats);
  }

  /// Polls invoice settlement (`action: check-invoice`). Returns the raw map so
  /// callers can read `{paid, settled, …}` (worker shape).
  /// TODO(verify): exact field names of the check-invoice response.
  Future<Map<String, dynamic>> checkInvoice({
    required String invoiceId,
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
  }) async {
    final res = await _botRequest(
      'check-invoice',
      <String, dynamic>{'invoiceId': invoiceId},
      pubkey: pubkey,
      auth: auth,
    );
    _throwOnStatus(res);
    return res.data;
  }

  /// Claims credits once an invoice is paid (`action: claim-credits`).
  /// [gifterNym] is `<nym>#<suffix>` so a gifted recipient's DM names the
  /// sender (`_claimBotCredits`, zaps.js:752-756).
  Future<Map<String, dynamic>> claimCredits({
    required String invoiceId,
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
    Map<String, dynamic>? receipt,
    String? gifterNym,
  }) async {
    final res = await _botRequest(
      'claim-credits',
      <String, dynamic>{
        'invoiceId': invoiceId,
        if (receipt != null) 'receipt': receipt,
        if (gifterNym != null && gifterNym.isNotEmpty) 'gifterNym': gifterNym,
      },
      pubkey: pubkey,
      auth: auth,
    );
    _throwOnStatus(res);
    return res.data;
  }

  /// Selects/changes the pinned Pro model for the chat. This is a pure local
  /// preference in the PWA (`?model <name>` flips a setting that becomes the
  /// `proModel` field on the next `pm`). Returns the resolved [ProModel], or
  /// null for `?model off`. No network.
  ProModel? selectModel(String arg) => lookupProModel(arg);

  /// Gifts credits to [recipientPubkey] (a paid buy with `recipientPubkey` set).
  /// `?gift @nym` resolves the nym to a pubkey upstream, then funds via Lightning
  /// like [buy].
  Future<BotInvoice> gift({
    required int amountSats,
    required CreditTier tier,
    required String pubkey,
    required String recipientPubkey,
    Future<Map<String, dynamic>?> Function()? auth,
    String? comment,
  }) =>
      buy(
        amountSats: amountSats,
        tier: tier,
        pubkey: pubkey,
        auth: auth,
        recipientPubkey: recipientPubkey,
        comment: comment,
      );

  /// Transfers all of the user's credits (standard + Pro) to another user
  /// (`action: transfer-credits`).
  Future<Map<String, dynamic>> transfer({
    required String pubkey,
    required String targetPubkey,
    Future<Map<String, dynamic>?> Function()? auth,
  }) async {
    final res = await _botRequest(
      'transfer-credits',
      <String, dynamic>{'targetPubkey': targetPubkey},
      pubkey: pubkey,
      auth: auth,
    );
    _throwOnStatus(res);
    return res.data;
  }

  /// Clears the private chat history server-side (`action: clear-history`).
  Future<Map<String, dynamic>> clearHistory({
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
  }) async {
    final res = await _botRequest(
      'clear-history',
      const <String, dynamic>{},
      pubkey: pubkey,
      auth: auth,
    );
    _throwOnStatus(res);
    return res.data;
  }

  // ===========================================================================
  // Git provider APIs (client-side, PAT never leaves the device except to the
  // provider itself) — ports of the PWA's `_gitApi*` helpers (pms.js:2159-2222)
  // used by the in-chat `?git token/repos/repo` flows.
  // ===========================================================================

  /// Whether [token] plausibly matches the provider's PAT shape
  /// (`_gitTokenValid`, pms.js:2177-2182): github.com enforces the
  /// `ghp_/gho_/…/github_pat_` prefixes; everything else takes any 8-255 char
  /// non-space token.
  static bool gitTokenValid(GitConfig cfg, String token) {
    if (cfg.provider == GitProvider.github && cfg.host == 'github.com') {
      return RegExp(r'^(gh[a-z]_|github_pat_)[A-Za-z0-9_]{16,255}$')
          .hasMatch(token);
    }
    return RegExp(r'^\S{8,255}$').hasMatch(token);
  }

  /// The provider's REST base (`_gitApiBase`, pms.js:2184-2190).
  static String gitApiBase(GitConfig cfg) {
    final host = cfg.host.isNotEmpty ? cfg.host : cfg.provider.defaultHost;
    switch (cfg.provider) {
      case GitProvider.gitlab:
        return 'https://$host/api/v4';
      case GitProvider.gitea:
        return 'https://$host/api/v1';
      case GitProvider.github:
        return host == 'github.com'
            ? 'https://api.github.com'
            : 'https://$host/api/v3';
    }
  }

  /// One authenticated GET against the provider API (`_gitApi`,
  /// pms.js:2192-2206). Returns `(ok, status, data)`; network errors become
  /// `(false, 0, null)` like the PWA.
  Future<({bool ok, int status, Object? data})> gitApi(
      GitConfig cfg, String path) async {
    if (!cfg.hasToken) return (ok: false, status: 0, data: null);
    try {
      final headers = <String, String>{
        'Authorization': 'Bearer ${cfg.token}',
        'Accept': 'application/json',
      };
      if (cfg.provider == GitProvider.github) {
        headers['Accept'] = 'application/vnd.github+json';
        headers['X-GitHub-Api-Version'] = '2022-11-28';
      }
      final res = await _client.get(Uri.parse(gitApiBase(cfg) + path),
          headers: headers);
      Object? data;
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      } catch (_) {
        data = null;
      }
      return (
        ok: res.statusCode >= 200 && res.statusCode < 300,
        status: res.statusCode,
        data: data,
      );
    } catch (_) {
      return (ok: false, status: 0, data: null);
    }
  }

  /// `_gitUserPath` (pms.js:2209).
  static String gitUserPath() => '/user';

  /// `_gitUserLogin` (pms.js:2210): GitLab exposes `username`, the rest `login`.
  static String gitUserLogin(GitConfig cfg, Object? data) {
    if (data is! Map) return '';
    final v = cfg.provider == GitProvider.gitlab ? data['username'] : data['login'];
    return v?.toString() ?? '';
  }

  /// `_gitReposPath` (pms.js:2211-2215).
  static String gitReposPath(GitConfig cfg) {
    switch (cfg.provider) {
      case GitProvider.gitlab:
        return '/projects?membership=true&per_page=30&order_by=last_activity_at';
      case GitProvider.gitea:
        return '/user/repos?limit=30';
      case GitProvider.github:
        return '/user/repos?per_page=30&sort=pushed';
    }
  }

  /// `_gitRepoFullName` (pms.js:2216).
  static String gitRepoFullName(GitConfig cfg, Object? repo) {
    if (repo is! Map) return '';
    final v = cfg.provider == GitProvider.gitlab
        ? repo['path_with_namespace']
        : repo['full_name'];
    return v?.toString() ?? '';
  }

  /// `_gitRepoPath` (pms.js:2217-2219).
  static String gitRepoPath(GitConfig cfg, String repo) =>
      cfg.provider == GitProvider.gitlab
          ? '/projects/${Uri.encodeComponent(repo)}'
          : '/repos/$repo';

  /// `_gitRepoRe` (pms.js:2220-2225): GitLab allows nested groups (up to 4
  /// segments); the others are `owner/name`.
  static RegExp gitRepoRe(GitConfig cfg) => cfg.provider == GitProvider.gitlab
      ? RegExp(r'^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+){1,3}$')
      : RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');

  // ===========================================================================
  // Auth (shared NIP-98 kind-27235, same builder as the shop)
  // ===========================================================================

  /// Builds the NIP-98 `auth` map for a mutating bot [action] bound to this
  /// service's `/api/bot` URL (`_signBotAuth`, pms.js:1649). Returns null when
  /// the identity has no signable privkey. Pass the result as the `auth:`
  /// argument to [buy] / [claimCredits] / [transfer] / etc.
  Map<String, dynamic>? buildAuth({
    required String action,
    required String pubkey,
    Uint8List? privkey,
  }) {
    if (privkey == null) return null;
    return Nip98Auth.build(
      action: action,
      url: _base,
      privkey: privkey,
      pubkey: pubkey,
    );
  }

  // ===========================================================================
  // Plumbing
  // ===========================================================================

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final res = await _client.post(
      Uri.parse(_base),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': _userAgent,
      },
      body: jsonEncode(body),
    );
    // `allowMalformed` mirrors TextDecoder / `response.json()` (U+FFFD
    // replacement, never throwing) like `ApiClient._utf8Body`.
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw NymbotException(
        'Nymbot request failed (${res.statusCode})',
        statusCode: res.statusCode,
        body: utf8.decode(res.bodyBytes, allowMalformed: true),
      );
    }
    final decoded =
        jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (decoded is! Map<String, dynamic>) {
      throw const NymbotException('Unexpected Nymbot response shape');
    }
    return decoded;
  }

  /// The raw HTTP leg of [_botRequest]: resolves `{status, data}` without
  /// throwing on an error status (the PWA's `resp.json().catch(() => ({}))`,
  /// shop.js:171-172), bounded by [timeout].
  Future<({int status, Map<String, dynamic> data})> _postRaw(
    Map<String, dynamic> body, {
    required Duration timeout,
  }) async {
    final res = await _client
        .post(
          Uri.parse(_base),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': _userAgent,
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);
    Map<String, dynamic> data;
    try {
      final decoded =
          jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      data = <String, dynamic>{};
    }
    return (status: res.statusCode, data: data);
  }

  /// Rejects an error-status result — the pre-WS `_post` contract callers of
  /// the raw-map actions rely on (their `res['error']` reads cover the 2xx
  /// error bodies). The re-encoded body rides along for `data.error` reads.
  static void _throwOnStatus(({int status, Map<String, dynamic> data}) res) {
    if (res.status < 200 || res.status >= 300) {
      throw NymbotException(
        'Nymbot request failed (${res.status})',
        statusCode: res.status,
        body: jsonEncode(res.data),
      );
    }
  }

  /// Rejects the PWA's single failure branch `status >= 400 || data.error`
  /// (pms.js:2486-2487 / 2530-2531). The re-encoded body rides along so
  /// callers can surface the exact error text (the `data.error` reads).
  static void _throwOnError(({int status, Map<String, dynamic> data}) res) {
    final err = res.data['error'];
    if (err is String && err.isNotEmpty) {
      throw NymbotException(err,
          statusCode: res.status, body: jsonEncode(res.data));
    }
    _throwOnStatus(res);
  }

  /// Pulls the reply text out of the public-command `{event}` envelope.
  String _extractEventContent(Map<String, dynamic> json) {
    final content = _maybeEventContent(json);
    if (content != null) return content;
    // Tolerate a flat `{response}` shape if the worker/contract ever changes.
    if (json['response'] is String) return json['response'] as String;
    throw const NymbotException('Nymbot response missing event content');
  }

  String? _maybeEventContent(Map<String, dynamic> json) {
    final event = json['event'];
    if (event is Map && event['content'] is String) {
      return event['content'] as String;
    }
    return null;
  }

  void dispose() {
    _apiSocketRequest = null;
    _client.close();
  }
}

int _asInt(Object? v) => _asNullableInt(v) ?? 0;

int? _asNullableInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// Thrown when a Nymbot request fails at the transport/shape level.
class NymbotException implements Exception {
  const NymbotException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() => 'NymbotException: $message';
}

/// Thrown by [NymbotService.sendBotMessage] when the user lacks credits
/// (worker `{noCredits, pro, balance, required, error}`).
class NymbotInsufficientCredits implements Exception {
  const NymbotInsufficientCredits({
    required this.pro,
    required this.balance,
    required this.required,
    required this.message,
  });

  /// True when the shortfall is on the Pro credit ledger.
  final bool pro;
  final int balance;
  final int required;
  final String message;

  @override
  String toString() => 'NymbotInsufficientCredits($message)';
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../services/api/api_client.dart';
import 'nymbot_models.dart';

/// Thin client for the Nymbot worker (`POST /api/bot`), ported from the call
/// sites in the PWA and the contract in `docs/specs/04-features.md` §11 +
/// `functions/api/bot.js`.
///
/// Two surfaces share the one endpoint:
///   * Public `?` commands  → body `{command, args, …}` → `{event}` (a signed
///     Nostr event whose `content` is the response text).
///   * Private paid chat    → body `{action, …}` → varies per action.
///
/// Network is **lazy**: nothing is fetched at construction; every method makes
/// exactly one request when called.
///
/// TODO(verify): the project ships a shared `lib/services/api/api_client.dart`
/// (being built in parallel). When present, replace [_post] / [_base] / the
/// User-Agent with the shared ApiClient so base URL + UA stay centralised.
class NymbotService {
  NymbotService({
    http.Client? client,
    String? baseUrl,
    String? userAgent,
  })  : _client = client ?? http.Client(),
        _base = baseUrl ?? _defaultBase,
        _userAgent = userAgent ?? _defaultUserAgent;

  final http.Client _client;
  final String _base;
  final String _userAgent;

  // TODO(verify): the PWA hits a same-origin `/api/bot`; the live host is
  // `web.nymchat.app`. Confirm the production base + that the app shell does not
  // route this through a proxy. Mirrors `NymchatApp/<ver>` UA token used by the
  // WebView shell (`lib/screens/webview_screen.dart`).
  static const String _defaultBase = 'https://web.nymchat.app/api/bot';
  static const String _defaultUserAgent = 'NymchatApp/1.0';

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

  /// Sends a private 1:1 chat message to Nymbot (`action: pm`).
  ///
  /// [auth] is the per-request auth blob `{id, sig, url}` the worker expects
  /// (spec §11.2). [proModel] pins a Pro frontier model (null → standard
  /// auto-routing). [git] enables repo mode. Returns a [BotReply] with the
  /// reasoning already split out of `<think>…</think>`.
  ///
  /// On insufficient credits the worker returns `{noCredits, pro, balance,
  /// required, error}` — surfaced as a [NymbotInsufficientCredits] exception.
  Future<BotReply> sendBotMessage(
    String text, {
    required String pubkey,
    Map<String, dynamic>? auth,
    String? eventId,
    String? proModel,
    bool fresh = false,
    GitConfig? git,
  }) async {
    final body = <String, dynamic>{
      'action': 'pm',
      'pubkey': pubkey,
      'text': text,
      if (auth != null) 'auth': auth,
      if (eventId != null) 'eventId': eventId,
      if (proModel != null) 'proModel': proModel,
      if (fresh) 'fresh': true,
      if (git != null) 'git': git.toWire(),
    };
    final json = await _post(body);

    if (json['noCredits'] == true) {
      throw NymbotInsufficientCredits(
        pro: json['pro'] == true,
        balance: _asInt(json['balance']),
        required: _asInt(json['required']),
        message: json['error']?.toString() ?? 'Insufficient credits',
      );
    }

    // The reply text lives in `reply` (spec §11.2) or, on some paths, inside a
    // returned event's `content` — accept either for robustness.
    final raw = (json['reply'] ?? _maybeEventContent(json) ?? '').toString();
    return splitReasoning(
      raw,
      taskType: json['taskType']?.toString(),
      modelCalls: _asNullableInt(json['modelCalls']),
      outputTokens: _asNullableInt(json['outputTokens']),
      cost: _asNullableInt(json['cost']),
      balance: _asNullableInt(json['balance']),
      pro: json['pro'] == true,
      proModel: json['proModel']?.toString(),
      git: json['git'] == true,
      lowBalance: json['lowBalance'] == true,
    );
  }

  /// Fetches the user's standard + Pro credit balances (`action: balance`).
  Future<BotBalance> balance({
    required String pubkey,
    Map<String, dynamic>? auth,
  }) async {
    final json = await _post({
      'action': 'balance',
      'pubkey': pubkey,
      if (auth != null) 'auth': auth,
    });
    return BotBalance.fromJson(json);
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
    Map<String, dynamic>? auth,
    String? recipientPubkey,
    Map<String, dynamic>? zapRequest,
    String? comment,
  }) async {
    final json = await _post({
      'action': 'create-invoice',
      'pubkey': pubkey,
      'amountSats': amountSats,
      'tier': tier.wire,
      if (auth != null) 'auth': auth,
      if (recipientPubkey != null) 'recipientPubkey': recipientPubkey,
      if (zapRequest != null) 'zapRequest': zapRequest,
      if (comment != null) 'comment': comment,
    });
    return BotInvoice.fromJson(json, tier: tier, amountSats: amountSats);
  }

  /// Polls invoice settlement (`action: check-invoice`). Returns the raw map so
  /// callers can read `{paid, settled, …}` (worker shape).
  /// TODO(verify): exact field names of the check-invoice response.
  Future<Map<String, dynamic>> checkInvoice({
    required String invoiceId,
    required String pubkey,
    Map<String, dynamic>? auth,
  }) =>
      _post({
        'action': 'check-invoice',
        'invoiceId': invoiceId,
        'pubkey': pubkey,
        if (auth != null) 'auth': auth,
      });

  /// Claims credits once an invoice is paid (`action: claim-credits`).
  Future<Map<String, dynamic>> claimCredits({
    required String invoiceId,
    required String pubkey,
    Map<String, dynamic>? auth,
    Map<String, dynamic>? receipt,
  }) =>
      _post({
        'action': 'claim-credits',
        'invoiceId': invoiceId,
        'pubkey': pubkey,
        if (auth != null) 'auth': auth,
        if (receipt != null) 'receipt': receipt,
      });

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
    Map<String, dynamic>? auth,
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
    Map<String, dynamic>? auth,
  }) =>
      _post({
        'action': 'transfer-credits',
        'pubkey': pubkey,
        'targetPubkey': targetPubkey,
        if (auth != null) 'auth': auth,
      });

  /// Clears the private chat history server-side (`action: clear-history`).
  Future<Map<String, dynamic>> clearHistory({
    required String pubkey,
    Map<String, dynamic>? auth,
  }) =>
      _post({
        'action': 'clear-history',
        'pubkey': pubkey,
        if (auth != null) 'auth': auth,
      });

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
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw NymbotException(
        'Nymbot request failed (${res.statusCode})',
        statusCode: res.statusCode,
        body: res.body,
      );
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw const NymbotException('Unexpected Nymbot response shape');
    }
    return decoded;
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

  void dispose() => _client.close();
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

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../services/api/api_client.dart';
import '../../services/api/api_config.dart';
import 'nymbot_models.dart';

/// Nymbot worker client: public `?` commands over HTTP, private-chat actions WS-first with signed HTTP fallback; lazy network.
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

  /// Per-action socket/HTTP wait; `pm` uses [_pmTimeout].
  static const Duration _defaultTimeout = Duration(seconds: 45);

  static const Duration _pmTimeout = Duration(seconds: 180);

  /// Runs a raw ledger action over the shared authed `/api` socket; null falls back to HTTP, and unset keeps this HTTP-only.
  Future<({int status, Map<String, dynamic> data})?> Function(
    String action,
    Map<String, dynamic> extra, {
    Duration? timeout,
  })? _apiSocketRequest;

  /// Registers or clears the shared-socket seam; identity switches rebuild the socket's [ApiClient] elsewhere.
  void setApiSocketRequest(
    Future<({int status, Map<String, dynamic> data})?> Function(
      String action,
      Map<String, dynamic> extra, {
      Duration? timeout,
    })? request,
  ) {
    _apiSocketRequest = request;
  }

  /// WS-first over the authed socket, else signed HTTP; [auth] is only built for the HTTP leg. Resolves `{status, data}`.
  Future<({int status, Map<String, dynamic> data})> _botRequest(
    String action,
    Map<String, dynamic> extra, {
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
    Future<Map<String, dynamic>?> Function(String payload)? signedFor,
    Duration timeout = _defaultTimeout,
    bool anon = false,
  }) async {
    final ws = anon ? null : _apiSocketRequest;
    if (ws != null) {
      // The socket is authed once, so frames omit pubkey/auth; null falls back to HTTP.
      final res = await ws(action, extra, timeout: timeout);
      if (res != null) return res;
    }
    final body = <String, dynamic>{
      'action': action,
      'pubkey': pubkey,
      ...extra,
    };
    final authEvent = signedFor != null
        ? await signedFor(Nip98Auth.payloadHashHex(body))
        : (auth == null ? null : await auth());
    if (authEvent != null) body['auth'] = authEvent;
    return _postRaw(body, timeout: timeout);
  }

  /// Fixed native host, like `ApiClient.botUrl`.
  static final String _defaultBase = 'https://${ApiConfig.apiHost}/api/bot';

  /// Request URL, which a NIP-98 auth event must bind in its `u` tag.
  String get baseUrl => _base;

  /// Returns the reply text; [conversation] is optional reply-chain history (max 6).
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

  /// Public, unauthenticated model catalog; null on failure so callers use [kProModelCatalogFallback].
  Future<ProModelCatalog?> fetchModelCatalog() async {
    try {
      final json = await _post(<String, dynamic>{'action': 'models'});
      final cat = ProModelCatalog.fromJson(json);
      return cat.isEmpty ? null : cat;
    } catch (_) {
      return null;
    }
  }

  /// Sends only the published gift wrap's [eventId], never plaintext, and waits up to 180s for the reply.
  Future<Map<String, dynamic>> sendBotMessage({
    required String pubkey,
    required String eventId,
    Future<Map<String, dynamic>?> Function()? auth,
    Future<Map<String, dynamic>?> Function(String payload)? signedFor,
    String? proModel,
    bool fresh = false,
    Map<String, String>? cmdAlias,
    Map<String, dynamic>? pqAnnouncement,
    bool anon = false,
  }) async {
    final extra = <String, dynamic>{
      'eventId': eventId,
      'fresh': fresh,
      if (proModel != null) 'proModel': proModel,
      // Lets the worker read a command typed in the user's language.
      if (cmdAlias != null) 'cmdAlias': cmdAlias,
      // Our signed nym-pq announcement, so the worker seals its reply post-quantum without a lookup race.
      if (pqAnnouncement != null) 'pqAnnouncement': pqAnnouncement,
    };

    // `pending` means an earlier attempt at this message is still generating; re-ask with the same id rather than paying twice.
    late ({int status, Map<String, dynamic> data}) res;
    for (var tries = 0;; tries++) {
      res = await _botRequest(
        'pm',
        extra,
        pubkey: pubkey,
        auth: auth,
        signedFor: signedFor,
        timeout: _pmTimeout,
        anon: anon,
      );
      if (res.data['pending'] != true || tries >= 5) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    final json = res.data;

    if (json['pending'] == true) {
      throw NymbotStillGenerating(json['message']?.toString() ??
          'Nymbot is still working on that message — its reply will arrive '
              'shortly.');
    }
    if (json['noCredits'] == true) {
      throw NymbotInsufficientCredits(
        pro: json['pro'] == true,
        balance: (json['balanceCredits'] as num?)?.toDouble()
            ?? _asInt(json['balance']).toDouble(),
        required: _asInt(json['required']),
        message: json['error']?.toString() ?? 'Insufficient credits',
      );
    }
    // `status >= 400 || !data || data.error` is one failure branch.
    _throwOnError(res);
    return json;
  }

  /// Standard and Pro credit balances.
  Future<BotBalance> balance({
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
    bool anon = false,
  }) async {
    final res = await _botRequest(
      'balance',
      const <String, dynamic>{},
      pubkey: pubkey,
      auth: auth,
      anon: anon,
    );
    // Never zero-fill from an error body.
    _throwOnError(res);
    return BotBalance.fromJson(res.data);
  }

  /// Creates a credits invoice; [recipientPubkey] gifts, [zapRequest] is an optional NIP-57 request.
  Future<BotInvoice> buy({
    required int amountSats,
    required CreditTier tier,
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
    String? recipientPubkey,
    Map<String, dynamic>? zapRequest,
    String? comment,
    bool anon = false,
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
      anon: anon,
    );
    _throwOnStatus(res);
    return BotInvoice.fromJson(res.data, tier: tier, amountSats: amountSats);
  }

  /// Polls settlement, returning the raw `{paid, settled, …}` map.
  Future<Map<String, dynamic>> checkInvoice({
    required String invoiceId,
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
    bool anon = false,
  }) async {
    final res = await _botRequest(
      'check-invoice',
      <String, dynamic>{'invoiceId': invoiceId},
      pubkey: pubkey,
      auth: auth,
      anon: anon,
    );
    _throwOnStatus(res);
    return res.data;
  }

  /// Claims credits for a paid invoice; [gifterNym] (`<nym>#<suffix>`) names the sender in a gift DM.
  Future<Map<String, dynamic>> claimCredits({
    required String invoiceId,
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
    Map<String, dynamic>? receipt,
    String? gifterNym,
    bool anon = false,
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
      anon: anon,
    );
    _throwOnStatus(res);
    return res.data;
  }

  /// Local Pro model preference for the next `pm`; null for `?model off`.
  ProModel? selectModel(String arg) => lookupProModel(arg);

  /// Paid buy with [recipientPubkey] set.
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

  Future<Map<String, dynamic>> voucherKeys() async {
    final res = await _postRaw(
      const <String, dynamic>{'action': 'voucher-keys'},
      timeout: _defaultTimeout,
    );
    _throwOnError(res);
    return res.data;
  }

  Future<Map<String, dynamic>> voucherIssue({
    required String pubkey,
    required String tier,
    required String reqId,
    required List<Map<String, dynamic>> outputs,
    Future<Map<String, dynamic>?> Function(String payload)? signedFor,
    bool anon = false,
  }) async {
    final res = await _botRequest(
      'voucher-issue',
      <String, dynamic>{'tier': tier, 'reqId': reqId, 'outputs': outputs},
      pubkey: pubkey,
      signedFor: signedFor,
      anon: anon,
    );
    _throwOnError(res);
    return res.data;
  }

  Future<Map<String, dynamic>> voucherRedeem({
    required String pubkey,
    required String tier,
    required String redeemId,
    required List<Map<String, dynamic>> tokens,
    Future<Map<String, dynamic>?> Function()? auth,
  }) async {
    final res = await _botRequest(
      'voucher-redeem',
      <String, dynamic>{'tier': tier, 'redeemId': redeemId, 'tokens': tokens},
      pubkey: pubkey,
      auth: auth,
      anon: true,
    );
    _throwOnError(res);
    return res.data;
  }

  /// Transfers all standard and Pro credits to another user.
  Future<Map<String, dynamic>> transfer({
    required String pubkey,
    required String targetPubkey,
    Future<Map<String, dynamic>?> Function(String payload)? signedFor,
    bool anon = false,
  }) async {
    final res = await _botRequest(
      'transfer-credits',
      <String, dynamic>{'targetPubkey': targetPubkey},
      pubkey: pubkey,
      signedFor: signedFor,
      anon: anon,
    );
    _throwOnStatus(res);
    return res.data;
  }

  Future<Map<String, dynamic>> clearHistory({
    required String pubkey,
    Future<Map<String, dynamic>?> Function()? auth,
    Future<Map<String, dynamic>?> Function(String payload)? signedFor,
    bool anon = false,
  }) async {
    final res = await _botRequest(
      'clear-history',
      const <String, dynamic>{},
      pubkey: pubkey,
      auth: auth,
      signedFor: signedFor,
      anon: anon,
    );
    _throwOnStatus(res);
    return res.data;
  }

  /// NIP-98 `auth` map bound to this `/api/bot` URL, or null without a signable privkey.
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

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final res = await _client.post(
      Uri.parse(_base),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': _userAgent,
      },
      body: jsonEncode(body),
    );
    // `allowMalformed` so bad UTF-8 becomes U+FFFD instead of throwing.
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

  /// Raw HTTP leg: resolves `{status, data}` without throwing on error status, bounded by [timeout].
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

  /// Throws on an error status, carrying the re-encoded body for `data.error` reads.
  static void _throwOnStatus(({int status, Map<String, dynamic> data}) res) {
    if (res.status < 200 || res.status >= 300) {
      throw NymbotException(
        'Nymbot request failed (${res.status})',
        statusCode: res.status,
        body: jsonEncode(res.data),
      );
    }
  }

  /// Throws on `status >= 400 || data.error`, carrying the body so callers can show the error text.
  static void _throwOnError(({int status, Map<String, dynamic> data}) res) {
    final err = res.data['error'];
    if (err is String && err.isNotEmpty) {
      throw NymbotException(err,
          statusCode: res.status, body: jsonEncode(res.data));
    }
    _throwOnStatus(res);
  }

  /// Reply text from the public-command `{event}` envelope.
  String _extractEventContent(Map<String, dynamic> json) {
    final content = _maybeEventContent(json);
    if (content != null) return content;
    // Tolerate a flat `{response}` shape.
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

/// A transport- or shape-level Nymbot failure.
class NymbotException implements Exception {
  const NymbotException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  bool get priceUnavailable {
    final raw = body;
    if (statusCode != 503 || raw == null || raw.isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map && decoded['priceUnavailable'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  String toString() => 'NymbotException: $message';
}

/// Worker answered `pending`: an earlier attempt still holds the turn, so no second reply was generated.
class NymbotStillGenerating implements Exception {
  const NymbotStillGenerating(this.message);

  final String message;

  @override
  String toString() => 'NymbotStillGenerating($message)';
}

/// Worker reported insufficient credits.
class NymbotInsufficientCredits implements Exception {
  const NymbotInsufficientCredits({
    required this.pro,
    required this.balance,
    required this.required,
    required this.message,
  });

  /// True when the shortfall is on the Pro ledger.
  final bool pro;
  final double balance;
  final int required;
  final String message;

  @override
  String toString() => 'NymbotInsufficientCredits($message)';
}

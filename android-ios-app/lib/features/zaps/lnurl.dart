import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/nostr_event.dart';
import '../../services/api/api_client.dart';

/// Pure helpers + lazy HTTP for the LNURL-pay zap flow (zaps.js
/// `fetchLightningInvoice`, lines 95-162). No network is touched until
/// [fetchInvoice] is called.
///
/// Every fetch rides the `/api/proxy?action=json` privacy proxy
/// ([ApiClient.proxiedJsonFetch], the PWA's `proxiedJsonFetch`,
/// relays.js:3192) so the Lightning provider only ever sees Cloudflare IPs;
/// the direct URL is fetched only when the proxy itself is unreachable.
class Lnurl {
  Lnurl._();

  /// Splits a lightning address `name@domain` into its `.well-known/lnurlp`
  /// metadata URL. Returns null when the address is malformed.
  static Uri? lnurlpUrl(String lightningAddress) {
    final parts = lightningAddress.split('@');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
    return Uri.parse('https://${parts[1]}/.well-known/lnurlp/${parts[0]}');
  }

  /// Builds the LNURL-pay callback URL (zaps.js lines 121-137): sets
  /// `amount` in **millisats**, an optional `comment` (clamped to the
  /// provider's `commentAllowed`), and the `nostr=<zap request JSON>` param when
  /// the provider `allowsNostr` and advertises a `nostrPubkey`.
  ///
  /// Pure and synchronous — given a parsed [LnurlPayParams] and an already-built
  /// (signed) [zapRequest], it returns the exact URL the PWA fetches.
  static Uri buildCallbackUrl({
    required LnurlPayParams params,
    required int amountSats,
    String comment = '',
    NostrEvent? zapRequest,
  }) {
    final amountMillisats = amountSats * 1000;
    final base = Uri.parse(params.callback);
    final qp = Map<String, String>.from(base.queryParameters);
    qp['amount'] = '$amountMillisats';
    if (comment.isNotEmpty && params.commentAllowed > 0) {
      final max = params.commentAllowed;
      qp['comment'] = comment.length > max ? comment.substring(0, max) : comment;
    }
    if (params.allowsNostr &&
        params.nostrPubkey != null &&
        zapRequest != null) {
      qp['nostr'] = jsonEncode(zapRequest.toJson());
    }
    return base.replace(queryParameters: qp);
  }

  /// Builds the proxy-riding [ApiClient] for a call: an injected [api] wins;
  /// otherwise one is wrapped around the (possibly injected) [http.Client] so
  /// tests with a MockClient still intercept every request.
  static ApiClient _api(ApiClient? api, http.Client client) =>
      api ?? ApiClient(client: client);

  /// Fetches the LNURL-pay metadata for [lightningAddress] (lazy network),
  /// through the JSON privacy proxy (zaps.js:106).
  static Future<LnurlPayParams> fetchPayParams(String lightningAddress,
      {http.Client? client, ApiClient? api}) async {
    final url = lnurlpUrl(lightningAddress);
    if (url == null) {
      throw const LnurlException('Invalid lightning address format');
    }
    final c = client ?? http.Client();
    try {
      final resp = await _api(api, c).proxiedJsonFetch(url.toString());
      if (resp.statusCode != 200) {
        throw const LnurlException('Failed to fetch LNURL endpoint');
      }
      return LnurlPayParams.fromJson(
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>);
    } finally {
      if (client == null) c.close();
    }
  }

  /// Resolves a bolt11 invoice for [amountSats] (and optional [comment] / zap
  /// request) against [params] (lazy network). Returns the invoice + the
  /// LUD-21 `verify` URL when present.
  static Future<LnInvoice> fetchInvoice({
    required LnurlPayParams params,
    required int amountSats,
    String comment = '',
    NostrEvent? zapRequest,
    http.Client? client,
    ApiClient? api,
  }) async {
    final amountMillisats = amountSats * 1000;
    if (amountMillisats < params.minSendable ||
        amountMillisats > params.maxSendable) {
      throw LnurlException(
          'Amount must be between ${params.minSendable ~/ 1000} and '
          '${params.maxSendable ~/ 1000} sats');
    }
    final url = buildCallbackUrl(
      params: params,
      amountSats: amountSats,
      comment: comment,
      zapRequest: zapRequest,
    );
    final c = client ?? http.Client();
    try {
      // Invoice callback rides the privacy proxy too (zaps.js:140).
      final resp = await _api(api, c).proxiedJsonFetch(url.toString());
      if (resp.statusCode != 200) {
        throw const LnurlException('Failed to fetch invoice');
      }
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final pr = data['pr'] as String?;
      if (pr == null || pr.isEmpty) {
        throw const LnurlException('No payment request in response');
      }
      return LnInvoice(
        pr: pr,
        verify: data['verify'] as String?,
        // The provider's Nostr pubkey lets the backend validate a NIP-57
        // receipt (zaps.js:153 `providerPubkey: lnurlData.nostrPubkey`).
        providerPubkey: params.nostrPubkey,
        amountSats: amountSats,
      );
    } finally {
      if (client == null) c.close();
    }
  }

  /// Polls the LUD-21 `verify` URL once (through the JSON privacy proxy, like
  /// the PWA's proxied verify poll — shop.js:1264); true when the invoice is
  /// settled (`{settled|paid: true}`).
  static Future<bool> checkPaid(String verifyUrl,
      {http.Client? client, ApiClient? api}) async {
    final c = client ?? http.Client();
    try {
      final resp = await _api(api, c).proxiedJsonFetch(verifyUrl);
      if (resp.statusCode != 200) return false;
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      return data['settled'] == true || data['paid'] == true;
    } catch (_) {
      return false;
    } finally {
      if (client == null) c.close();
    }
  }
}

/// Parsed LNURL-pay metadata (the subset zaps.js reads).
class LnurlPayParams {
  const LnurlPayParams({
    required this.callback,
    required this.minSendable,
    required this.maxSendable,
    this.commentAllowed = 0,
    this.allowsNostr = false,
    this.nostrPubkey,
  });

  final String callback;
  final int minSendable; // millisats
  final int maxSendable; // millisats
  final int commentAllowed;
  final bool allowsNostr;
  final String? nostrPubkey;

  factory LnurlPayParams.fromJson(Map<String, dynamic> j) {
    return LnurlPayParams(
      callback: j['callback'] as String,
      minSendable: (j['minSendable'] as num?)?.toInt() ?? 0,
      maxSendable: (j['maxSendable'] as num?)?.toInt() ?? 0,
      commentAllowed: (j['commentAllowed'] as num?)?.toInt() ?? 0,
      allowsNostr: j['allowsNostr'] == true,
      nostrPubkey: j['nostrPubkey'] as String?,
    );
  }
}

/// A resolved bolt11 invoice plus optional LUD-21 verify URL.
class LnInvoice {
  const LnInvoice({
    required this.pr,
    this.verify,
    this.providerPubkey,
    required this.amountSats,
  });
  final String pr;
  final String? verify;

  /// The LNURL provider's Nostr pubkey (for NIP-57 receipt validation in the
  /// backend zap-verify path).
  final String? providerPubkey;
  final int amountSats;

  /// Lowercased bolt11 — the canonical zap dedup key (zaps.js:1250
  /// `'b:' + bolt11.toLowerCase()`).
  String get dedupKey => pr.toLowerCase();
}

class LnurlException implements Exception {
  const LnurlException(this.message);
  final String message;
  @override
  String toString() => message;
}

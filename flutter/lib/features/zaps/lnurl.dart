import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/nostr_event.dart';
import '../../services/api/api_client.dart';
import 'zap_logic.dart';

/// LNURL-pay helpers; every fetch goes via the JSON privacy proxy, falling back to direct only if the proxy is down.
class Lnurl {
  Lnurl._();

  /// `.well-known/lnurlp` URL for `name@domain`, or null when malformed.
  static Uri? lnurlpUrl(String lightningAddress) {
    final parts = lightningAddress.split('@');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
    return Uri.parse('https://${parts[1]}/.well-known/lnurlp/${parts[0]}');
  }

  /// LNURL-pay callback URL: amount in millisats, clamped comment, and `nostr=` when the provider allows it.
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
      qp['comment'] =
          comment.length > max ? comment.substring(0, max) : comment;
    }
    if (params.allowsNostr &&
        params.nostrPubkey != null &&
        zapRequest != null) {
      qp['nostr'] = jsonEncode(zapRequest.toJson());
    }
    return base.replace(queryParameters: qp);
  }

  /// An injected [api] wins; otherwise wrap [client] so MockClient tests still intercept.
  static ApiClient _api(ApiClient? api, http.Client client) =>
      api ?? ApiClient(client: client);

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
      // `allowMalformed` so bad UTF-8 becomes U+FFFD instead of throwing.
      return LnurlPayParams.fromJson(
          jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true))
              as Map<String, dynamic>);
    } finally {
      if (client == null) c.close();
    }
  }

  /// Resolves a bolt11 invoice, plus the LUD-21 `verify` URL when present.
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
      final resp = await _api(api, c).proxiedJsonFetch(url.toString());
      if (resp.statusCode != 200) {
        throw const LnurlException('Failed to fetch invoice');
      }
      final data = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true))
          as Map<String, dynamic>;
      final pr = data['pr'] as String?;
      if (pr == null || pr.isEmpty) {
        throw const LnurlException('No payment request in response');
      }
      if (ZapLogic.parseAmountFromBolt11(pr) != amountSats) {
        throw const LnurlException(
            'The invoice is not for the amount you chose');
      }
      return LnInvoice(
        pr: pr,
        verify: data['verify'] as String?,
        // Lets the backend validate the NIP-57 receipt.
        providerPubkey: params.nostrPubkey,
        amountSats: amountSats,
      );
    } finally {
      if (client == null) c.close();
    }
  }

  /// Polls the LUD-21 `verify` URL once; true when settled.
  static Future<bool> checkPaid(String verifyUrl,
      {http.Client? client, ApiClient? api}) async {
    final c = client ?? http.Client();
    try {
      final resp = await _api(api, c).proxiedJsonFetch(verifyUrl);
      if (resp.statusCode != 200) return false;
      final data = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true))
          as Map<String, dynamic>;
      return data['settled'] == true || data['paid'] == true;
    } catch (_) {
      return false;
    } finally {
      if (client == null) c.close();
    }
  }
}

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

class LnInvoice {
  const LnInvoice({
    required this.pr,
    this.verify,
    this.providerPubkey,
    required this.amountSats,
  });
  final String pr;
  final String? verify;

  /// Provider's Nostr pubkey, for backend NIP-57 receipt validation.
  final String? providerPubkey;
  final int amountSats;

  /// Lowercased bolt11, the canonical zap dedup key.
  String get dedupKey => pr.toLowerCase();
}

class LnurlException implements Exception {
  const LnurlException(this.message);
  final String message;
  @override
  String toString() => message;
}

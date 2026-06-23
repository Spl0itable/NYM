import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;

import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';
import 'api_config.dart';

/// Default Giphy API key (PWA `this.giphyApiKey`, app.js:679). Mirrors the
/// existing `kGiphyApiKey` in features/emoji/gif_picker.dart.
const String kApiGiphyApiKey = 'G6neFEExTMBM0h3hM2QjQg4vG8jMMLa9';

/// An OpenGraph link-preview result (`/api/proxy?action=unfurl`).
/// Shape mirrors proxy.js: `{url,title,description,image,siteName,type,favicon}`.
class UnfurlResult {
  const UnfurlResult({
    required this.url,
    this.title,
    this.description,
    this.image,
    this.siteName,
    this.type,
    this.favicon,
  });

  final String url;
  final String? title;
  final String? description;
  final String? image;
  final String? siteName;
  final String? type;
  final String? favicon;

  factory UnfurlResult.fromJson(Map<String, dynamic> j) => UnfurlResult(
        url: (j['url'] ?? '').toString(),
        title: j['title']?.toString(),
        description: j['description']?.toString(),
        image: j['image']?.toString(),
        siteName: j['siteName']?.toString(),
        type: j['type']?.toString(),
        favicon: j['favicon']?.toString(),
      );
}

/// A translation result (`/api/proxy?action=translate`).
/// proxy.js returns `{translatedText, detectedLanguage}`.
class TranslateResult {
  const TranslateResult({
    required this.translatedText,
    required this.detectedLanguage,
  });

  final String translatedText;
  final String detectedLanguage;

  factory TranslateResult.fromJson(Map<String, dynamic> j) => TranslateResult(
        translatedText: (j['translatedText'] ?? '').toString(),
        detectedLanguage: (j['detectedLanguage'] ?? 'auto').toString(),
      );
}

/// A geo relay entry (`/api/proxy?action=geo-relays`).
/// proxy.js returns `{relays:[{url,lat,lng}]}`.
class GeoRelay {
  const GeoRelay({required this.url, required this.lat, required this.lng});

  final String url;
  final double lat;
  final double lng;

  factory GeoRelay.fromJson(Map<String, dynamic> j) => GeoRelay(
        url: (j['url'] ?? '').toString(),
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
      );
}

/// Builds the NIP-98-style kind-27235 auth event the nym backend expects for
/// mutating `/api/storage` and `/api/bot` actions (`_signBotAuth`, pms.js:1649;
/// server `verifyClientAuth`, _shared.js:2656).
///
/// The PWA sends the *full signed event object* as `body.auth` (NOT a base64
/// `Authorization: Nostr <…>` header — that header form is only the Blossom
/// kind-24242 upload path). Tags mirror the PWA exactly:
///   `['domain','nymbot-pm'], ['method','POST'], ['u', url], ['action', action]`
/// content is the literal string `'nymbot-pm-auth'`, created_at is unix seconds.
///
/// The server checks: `kind === 27235`, `|now - created_at| <= 120`,
/// `getEventHash(auth) === auth.id`, schnorr sig, and the `action` / `method` /
/// `u` (origin+pathname) tag binding. The optional `['payload', …]` tag is NOT
/// emitted by the PWA (the server only enforces it when present), so we omit it
/// too for byte-for-byte parity.
///
/// This is pure (no network): give it the identity privkey + pubkey and it
/// returns the signed event. Callers that hold the [Identity] (the zap/shop
/// modals, nymbot UI) build it and pass it down as the `auth` map.
class Nip98Auth {
  Nip98Auth._();

  /// The literal `content` field the PWA signs (pms.js:1672).
  static const String content = 'nymbot-pm-auth';

  /// Builds + signs the kind-27235 auth event for [action] against [url],
  /// returning the full signed event as a JSON map (the `body.auth` value).
  ///
  /// [privkey] is the 32-byte identity secret key; [pubkey] its 64-hex public
  /// key. [createdAt] defaults to now (unix seconds) and is injectable for
  /// deterministic tests.
  static Map<String, dynamic> build({
    required String action,
    required String url,
    required Uint8List privkey,
    required String pubkey,
    int? createdAt,
  }) {
    final ts = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tags = <List<String>>[
      ['domain', 'nymbot-pm'],
      ['method', 'POST'],
      if (url.isNotEmpty) ['u', url],
      if (action.isNotEmpty) ['action', action],
    ];
    final unsigned = UnsignedEvent(
      pubkey: pubkey,
      createdAt: ts,
      kind: 27235,
      tags: tags,
      content: content,
    );
    final signed = schnorr.finalizeEvent(unsigned, privkey);
    return signed.toJson();
  }

  /// Optional `['payload', sha256hex(canonicalBody)]` tag value. The nym backend
  /// canonicalizes by dropping the `auth` key and sorting the remaining keys,
  /// then `JSON.stringify`, sha256, lowercase hex (`canonicalAuthBody` +
  /// `authPayloadHashHex`, _shared.js:2644). Exposed for completeness/tests; the
  /// PWA does not attach it.
  static String payloadHashHex(Map<String, dynamic> body) {
    final canonical = <String, dynamic>{};
    final keys = body.keys.where((k) => k != 'auth').toList()..sort();
    for (final k in keys) {
      canonical[k] = body[k];
    }
    final text = jsonEncode(canonical);
    return sha256.convert(utf8.encode(text)).toString();
  }
}

/// Typed client for the backend proxy endpoints (spec §6).
///
/// Every request carries the `isNymchatClient` UA header
/// ([ApiConfig.userAgent]). Construction performs NO network — calls are lazy.
/// The `http.Client` is injectable for tests.
class ApiClient {
  ApiClient({http.Client? client, String? baseUrl, String giphyApiKey = kApiGiphyApiKey})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? ApiConfig.proxyBaseUrl(),
        _giphyApiKey = giphyApiKey;

  final http.Client _client;
  final String _baseUrl;
  final String _giphyApiKey;

  // ---------------------------------------------------------------------------
  // URL builders (pure — used directly by media widgets and unit tests).
  // ---------------------------------------------------------------------------

  /// `GET /api/proxy?url=<encoded>` (optional `&emoji=1`).
  /// Mirrors `getProxiedMediaUrl` / `getProxiedEmojiUrl` (users.js:485/493).
  String mediaProxyUrl(String url, {bool emoji = false}) {
    final enc = Uri.encodeComponent(url);
    return emoji ? '$_baseUrl?emoji=1&url=$enc' : '$_baseUrl?url=$enc';
  }

  /// `GET /api/proxy?action=unfurl&url=<encoded>` (ui-context.js:693).
  String unfurlUrl(String url) =>
      '$_baseUrl?action=unfurl&url=${Uri.encodeComponent(url)}';

  /// `GET /api/proxy?action=geo-relays` (relays.js:16).
  String geoRelaysUrl() => '$_baseUrl?action=geo-relays';

  /// `GET /api/proxy?action=geocode&lat&lng&zoom&lang` (relays.js:3210).
  String geocodeUrl(double lat, double lng, {int zoom = 10, String lang = 'en'}) =>
      '$_baseUrl?action=geocode&lat=$lat&lng=$lng&zoom=$zoom&lang=$lang';

  /// `GET /api/proxy?action=giphy&q=<q>&api_key=<key>` (relays.js:3221).
  String giphySearchUrl(String query) =>
      '$_baseUrl?action=giphy&q=${Uri.encodeComponent(query)}&api_key=${Uri.encodeComponent(_giphyApiKey)}';

  /// `GET /api/proxy?action=giphy&trending=1&api_key=<key>` (relays.js:3221).
  String giphyTrendingUrl() =>
      '$_baseUrl?action=giphy&trending=1&api_key=${Uri.encodeComponent(_giphyApiKey)}';

  /// `PUT /api/proxy?action=upload&server=<encoded>` (users.js:499).
  String blossomUploadUrl(String server) =>
      '$_baseUrl?action=upload&server=${Uri.encodeComponent(server)}';

  /// `POST /api/proxy?action=zap-verify` (zaps.js:979 `_serverVerifyZapPaid`).
  String zapVerifyUrl() => '$_baseUrl?action=zap-verify';

  /// `https://<host>/api/storage` — shop-* mutating actions (shop.js:187).
  /// Derived from the proxy base by swapping the trailing path segment so the
  /// `u`-tag binding in NIP-98 auth matches the actual request URL.
  String get storageUrl => _siblingApi('storage');

  /// `https://<host>/api/bot` — Nymbot credit actions (bot.js).
  String get botUrl => _siblingApi('bot');

  /// Rewrites the proxy base (`…/api/proxy[?…]`) to a sibling `…/api/<name>`.
  String _siblingApi(String name) {
    final u = Uri.parse(_baseUrl);
    final segs = List<String>.from(u.pathSegments);
    if (segs.isNotEmpty) {
      segs[segs.length - 1] = name;
    } else {
      segs.add(name);
    }
    // Build a query-less URI (replace(query: '') leaves a trailing '?').
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      pathSegments: segs,
    ).toString();
  }

  // ---------------------------------------------------------------------------
  // Network calls (lazy).
  // ---------------------------------------------------------------------------

  Map<String, String> _headers([Map<String, String>? extra]) => {
        ...ApiConfig.defaultHeaders,
        if (extra != null) ...extra,
      };

  /// POST translate `{text, source, target}` -> `{translatedText, detectedLanguage}`.
  /// `source` defaults to `'auto'` (proxy.js:504).
  Future<TranslateResult> translate(
    String text,
    String target, {
    String source = 'auto',
  }) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl?action=translate'),
      headers: _headers({'Content-Type': 'application/json'}),
      body: jsonEncode({'text': text, 'source': source, 'target': target}),
    );
    if (res.statusCode != 200) {
      throw ApiException('translate', res.statusCode, res.body);
    }
    return TranslateResult.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// GET unfurl (OpenGraph preview).
  Future<UnfurlResult> unfurl(String url) async {
    final res = await _client.get(Uri.parse(unfurlUrl(url)), headers: _headers());
    if (res.statusCode != 200) {
      throw ApiException('unfurl', res.statusCode, res.body);
    }
    return UnfurlResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// PUT a Blossom blob through the proxy. [authHeader] is the full
  /// `Authorization` value (e.g. `Nostr <base64-event>`, kind-24242 BUD auth).
  /// Returns the parsed Blossom JSON (caller reads `data['url']`).
  Future<Map<String, dynamic>> uploadBlob(
    Uint8List bytes,
    String server,
    String authHeader, {
    String contentType = 'application/octet-stream',
  }) async {
    final res = await _client.put(
      Uri.parse(blossomUploadUrl(server)),
      headers: _headers({
        'Authorization': authHeader,
        'Content-Type': contentType,
      }),
      body: bytes,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('upload', res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// GET the geo relay list -> `[{url,lat,lng}]`. Filters out non-finite coords
  /// (relays.js:20). Returns an empty list on a non-200 so the caller can fall
  /// back to the bitchat CSV.
  Future<List<GeoRelay>> geoRelays() async {
    final res = await _client.get(Uri.parse(geoRelaysUrl()), headers: _headers());
    if (res.statusCode != 200) return const [];
    final data = jsonDecode(res.body);
    if (data is! Map || data['relays'] is! List) return const [];
    final out = <GeoRelay>[];
    for (final r in data['relays'] as List) {
      if (r is! Map) continue;
      final url = r['url'];
      final lat = r['lat'];
      final lng = r['lng'];
      if (url is! String || url.isEmpty) continue;
      if (lat is! num || lng is! num) continue;
      if (!lat.isFinite || !lng.isFinite) continue;
      out.add(GeoRelay(url: url, lat: lat.toDouble(), lng: lng.toDouble()));
    }
    return out;
  }

  /// GET reverse geocode -> raw Nominatim JSON (passed through by proxy.js).
  Future<Map<String, dynamic>> geocode(
    double lat,
    double lng, {
    int zoom = 10,
    String lang = 'en',
  }) async {
    final res = await _client.get(
      Uri.parse(geocodeUrl(lat, lng, zoom: zoom, lang: lang)),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw ApiException('geocode', res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// GET Giphy search -> raw Giphy JSON.
  Future<Map<String, dynamic>> giphySearch(String query) async {
    final res =
        await _client.get(Uri.parse(giphySearchUrl(query)), headers: _headers());
    if (res.statusCode != 200) {
      throw ApiException('giphy', res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// GET Giphy trending -> raw Giphy JSON.
  Future<Map<String, dynamic>> giphyTrending() async {
    final res =
        await _client.get(Uri.parse(giphyTrendingUrl()), headers: _headers());
    if (res.statusCode != 200) {
      throw ApiException('giphy', res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------------
  // Payment settlement (zaps / shop / bot).
  // ---------------------------------------------------------------------------

  /// `POST /api/proxy?action=zap-verify` — server-side confirmation that a zap
  /// invoice was paid (zaps.js `_serverVerifyZapPaid`, proxy.js `handleZapVerify`).
  ///
  /// Body mirrors the PWA exactly: `{pr, verifyUrl, providerPubkey, receipt}`
  /// (any may be null). Unauthenticated. Returns `data.paid === true`; any
  /// transport error resolves to `false` so polling can simply retry.
  Future<bool> zapVerify({
    required String pr,
    String? verifyUrl,
    String? providerPubkey,
    Map<String, dynamic>? receipt,
  }) async {
    try {
      final res = await _client.post(
        Uri.parse(zapVerifyUrl()),
        headers: _headers({'Content-Type': 'application/json'}),
        body: jsonEncode({
          'pr': pr,
          'verifyUrl': verifyUrl,
          'providerPubkey': providerPubkey,
          'receipt': receipt,
        }),
      );
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body);
      return data is Map && data['paid'] == true;
    } catch (_) {
      return false;
    }
  }

  /// `POST /api/storage` — the shop-* mutating actions (shop.js `_storageApiRequest`).
  ///
  /// [body] must already carry `action` and, for authenticated actions,
  /// `pubkey` + `auth` (build the latter with [Nip98Auth.build], `url:`
  /// [storageUrl]). Returns the decoded JSON map. Throws [ApiException] on a
  /// non-2xx so the caller can surface the server `error` (e.g. "Payment not
  /// confirmed yet." → retry).
  Future<Map<String, dynamic>> storageAction(Map<String, dynamic> body) async {
    final res = await _client.post(
      Uri.parse(storageUrl),
      headers: _headers({'Content-Type': 'application/json'}),
      body: jsonEncode(body),
    );
    final decoded = _decodeJson(res);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
        (body['action'] ?? 'storage').toString(),
        res.statusCode,
        decoded['error']?.toString() ?? res.body,
      );
    }
    return decoded;
  }

  /// `POST /api/storage` for the NDJSON-streaming reads (`profile-get`,
  /// `pm-get`). The worker streams `application/x-ndjson` (one JSON value per
  /// line) for these actions instead of a JSON object (storage.js:636/932), so
  /// the JSON-object [storageAction] path can't be used. Mirrors the PWA's
  /// `_storageApiStream` + `_readNdjsonStream` (shop.js:211/241).
  ///
  /// [body] must already carry `action` and (for the authenticated `pm-get`)
  /// `pubkey` + `auth`. `profile-get` is an unauthenticated public read. Returns
  /// the parsed per-line JSON values plus the `X-Has-More` header flag the PM
  /// pager reads. Throws [ApiException] on a non-2xx.
  Future<StorageStream> storageStream(Map<String, dynamic> body) async {
    final res = await _client.post(
      Uri.parse(storageUrl),
      headers: _headers({'Content-Type': 'application/json'}),
      body: jsonEncode(body),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final decoded = _decodeJson(res);
      throw ApiException(
        (body['action'] ?? 'storage').toString(),
        res.statusCode,
        decoded['error']?.toString() ?? res.body,
      );
    }
    final items = <dynamic>[];
    for (final line in const LineSplitter().convert(res.body)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        items.add(jsonDecode(trimmed));
      } catch (_) {
        // Skip malformed lines (mirrors `_readNdjsonStream`'s try/catch).
      }
    }
    final hasMore = (res.headers['x-has-more'] ?? '') == '1';
    return StorageStream(items: items, hasMore: hasMore);
  }

  /// `POST /api/bot` — the Nymbot credit actions (`create-invoice`,
  /// `check-invoice`, `claim-credits`, `transfer-credits`, …). Same auth contract
  /// as [storageAction] but bound to [botUrl]. Returns the decoded JSON map;
  /// throws [ApiException] on a non-2xx.
  Future<Map<String, dynamic>> botAction(Map<String, dynamic> body) async {
    final res = await _client.post(
      Uri.parse(botUrl),
      headers: _headers({'Content-Type': 'application/json'}),
      body: jsonEncode(body),
    );
    final decoded = _decodeJson(res);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
        (body['action'] ?? 'bot').toString(),
        res.statusCode,
        decoded['error']?.toString() ?? res.body,
      );
    }
    return decoded;
  }

  Map<String, dynamic> _decodeJson(http.Response res) {
    try {
      final d = jsonDecode(res.body);
      return d is Map<String, dynamic> ? d : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void dispose() => _client.close();
}

/// The parsed result of a streaming `/api/storage` read ([ApiClient.storageStream]).
/// [items] are the per-line JSON values; [hasMore] is the `X-Has-More` flag the
/// PM pager uses to decide whether an older page exists (storage.js:936).
class StorageStream {
  const StorageStream({required this.items, required this.hasMore});
  final List<dynamic> items;
  final bool hasMore;
}

/// Thrown on a non-success backend response.
class ApiException implements Exception {
  ApiException(this.action, this.statusCode, this.body);
  final String action;
  final int statusCode;
  final String body;
  @override
  String toString() => 'ApiException($action: HTTP $statusCode)';
}

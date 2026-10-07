import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/crypto/keys.dart' show bytesToHex, randomBytes;
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../core/crypto/pow.dart';
import '../../models/nostr_event.dart';
import '../nostr/event_signer.dart';
import '../relay/relay_stats.dart';
import 'api_config.dart';
import 'proxy_reachability.dart';

/// Opens the `/api` socket; overridable in tests.
typedef ApiSocketFactory = WebSocketChannel Function(Uri url);

/// Native `/api` socket factory carrying the `NymchatApp/<ver>` UA the backend gate requires.
WebSocketChannel defaultApiSocketFactory(Uri url) => IOWebSocketChannel.connect(
      url,
      headers: ApiConfig.socketHeadersFor(url),
      customClient: ApiConfig.socketClient(),
    );

/// Default Giphy API key, as the PWA's `giphyApiKey`.
const String kApiGiphyApiKey = 'G6neFEExTMBM0h3hM2QjQg4vG8jMMLa9';

/// OpenGraph preview from `/api/proxy?action=unfurl`.
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

/// Translation result from `/api/proxy?action=translate`.
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

/// Geo relay entry from `/api/proxy?action=geo-relays`.
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

/// Kind-27235 auth event sent whole as `body.auth` for mutating storage/bot actions; tags match the PWA exactly.
class Nip98Auth {
  Nip98Auth._();

  /// The literal `content` the PWA signs.
  static const String content = 'nymbot-pm-auth';

  /// Builds and signs the auth event for [action] against [url]; [createdAt] is injectable for tests.
  static Map<String, dynamic> build({
    required String action,
    required String url,
    required Uint8List privkey,
    required String pubkey,
    int? createdAt,
    String? payload,
  }) {
    final ts = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tags = <List<String>>[
      ['domain', 'nymbot-pm'],
      ['method', 'POST'],
      if (url.isNotEmpty) ['u', url],
      if (action.isNotEmpty) ['action', action],
      if (payload != null) ['payload', payload],
      ['nonce', bytesToHex(randomBytes(16))],
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

  /// Signs via [EventSigner] (local or NIP-46), caching non-[sensitive] auth 90s; null when signing fails.
  static Future<Map<String, dynamic>?> buildSigned({
    required String action,
    required String url,
    required EventSigner signer,
    bool sensitive = false,
    int? createdAt,
    List<List<String>> extraTags = const [],
    int powBits = 0,
  }) async {
    final pubkey = signer.pubkey;
    final now = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cacheKey = '$pubkey|$action|$url';
    if (!sensitive) {
      final cached = _authCache[cacheKey];
      // Validate the signed event's created_at against 90s, inside the worker's 120s tolerance.
      if (cached != null &&
          cached.pubkey == pubkey &&
          (now - cached.createdAt) < 90) {
        return cached.auth;
      }
    }
    final tags = <List<String>>[
      ['domain', 'nymbot-pm'],
      ['method', 'POST'],
      if (url.isNotEmpty) ['u', url],
      if (action.isNotEmpty) ['action', action],
      ...extraTags,
      if (sensitive && powBits <= 0) ['nonce', bytesToHex(randomBytes(16))],
    ];
    var unsigned = UnsignedEvent(
      pubkey: pubkey,
      createdAt: now,
      kind: 27235,
      tags: tags,
      content: content,
    );
    // Mine before signing, since the nonce tag is part of the id.
    if (powBits > 0) unsigned = await mineNonce(unsigned, powBits);
    try {
      final signed = await signer.sign(unsigned);
      final auth = signed.toJson();
      if (!sensitive) {
        final ts = (auth['created_at'] as num?)?.toInt() ?? now;
        _authCache[cacheKey] = _CachedAuth(pubkey, ts, auth);
      }
      return auth;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> buildWrite({
    required String action,
    required String url,
    required EventSigner signer,
    required String payload,
  }) =>
      buildSigned(
        action: action,
        url: url,
        signer: signer,
        sensitive: true,
        extraTags: [
          ['payload', payload],
        ],
      );

  /// 90s non-sensitive auth cache, shared process-wide.
  static final Map<String, _CachedAuth> _authCache = {};

  /// Call on sign-out or identity switch so a new identity never reuses stale auth.
  static void clearAuthCache() => _authCache.clear();

  /// Optional `['payload', sha256(canonical body)]` value, matching the backend's `canonicalAuthBody`; unused by the PWA.
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

class _CachedAuth {
  _CachedAuth(this.pubkey, this.createdAt, this.auth);
  final String pubkey;
  final int createdAt;
  final Map<String, dynamic> auth;
}

/// One `/api` socket result: [status], [data] for single responses, or streamed [items] plus has-more.
class ApiSocketResult {
  ApiSocketResult({
    required this.status,
    required this.data,
    required this.items,
    required this.hasMore,
  });
  final int status;
  final Map<String, dynamic> data;
  final List<dynamic> items;
  final bool hasMore;
}

/// Persistent multiplexed `/api` socket for D1 storage ops; failures trip a cooldown and fall back to HTTP.
class ApiSocket {
  ApiSocket({
    required this._url,
    this._factory = defaultApiSocketFactory,
    this._connectTimeout = const Duration(seconds: 12),
    this._requestTimeout = const Duration(seconds: 45),
    this._failureCooldown = const Duration(seconds: 5),
    this.onTraffic,
  });

  final Uri _url;
  final ApiSocketFactory _factory;
  final Duration _connectTimeout;
  final Duration _requestTimeout;
  final Duration _failureCooldown;

  /// Per-frame byte tally by action for network stats; null when HTTP-only.
  final void Function(String action, {int sent, int recv})? onTraffic;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _open = false;
  bool _authed = false;
  int _nextId = 1;
  Completer<void>? _connecting;
  DateTime _failedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  final Map<int, _Pending> _pending = {};

  bool get isOpen => _open;
  bool get isAuthenticated => _authed;

  /// Connects, authenticating when [authEvent] is set; throws and trips the cooldown on failure.
  Future<void> ensureConnected({Map<String, dynamic>? authEvent}) async {
    final needAuth = authEvent != null;
    if (_open && (_authed || !needAuth)) return;
    if (_connecting != null) return _connecting!.future;
    if (DateTime.now().isBefore(_failedUntil)) {
      throw StateError('api socket cooling down');
    }
    final completer = Completer<void>();
    _connecting = completer;
    try {
      _resetChannel();
      final ch = _factory(_url);
      _channel = ch;
      var ready = false;
      Timer? timer;
      void fail(Object err) {
        if (!ready) _failedUntil = DateTime.now().add(_failureCooldown);
        _failAllPending(err);
        _teardown();
        if (!completer.isCompleted) completer.completeError(err);
      }

      void markReady() {
        ready = true;
        _open = true;
        timer?.cancel();
        if (!completer.isCompleted) completer.complete();
      }

      _sub = ch.stream.listen(
        (raw) => _onFrame(raw, markReady, fail, needAuth),
        onError: (Object e) => fail(e),
        onDone: () => fail(StateError('api socket closed')),
        cancelOnError: true,
      );
      timer =
          Timer(_connectTimeout, () => fail(StateError('api socket timeout')));

      if (needAuth) {
        final sent = _send(['AUTH', authEvent]);
        onTraffic?.call('auth', sent: sent);
      } else {
        // Ready only once the connection is really up; the `_channel == ch` guard skips stale callbacks.
        unawaited(ch.ready.then((_) {
          if (_channel == ch) markReady();
        }, onError: (Object e) {
          if (_channel == ch) fail(e);
        }));
      }
      await completer.future;
    } finally {
      _connecting = null;
    }
  }

  void _onFrame(
    dynamic raw,
    void Function() markReady,
    void Function(Object) fail,
    bool needAuth,
  ) {
    // Frame byte count for the network stats.
    final recvLen = raw is String ? raw.length : (raw is List ? raw.length : 0);
    dynamic msg;
    try {
      msg = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
    } catch (_) {
      onTraffic?.call('other', recv: recvLen);
      return;
    }
    if (msg is! List || msg.isEmpty) {
      onTraffic?.call('other', recv: recvLen);
      return;
    }
    final t = msg[0];
    if (t == 'AUTH_OK') {
      onTraffic?.call('auth', recv: recvLen);
      _authed = true;
      markReady();
      return;
    }
    if (t == 'AUTH_ERR') {
      onTraffic?.call('auth', recv: recvLen);
      fail(StateError(msg.length > 1 ? '${msg[1]}' : 'Authentication failed'));
      return;
    }
    if (msg.length < 2) {
      onTraffic?.call('other', recv: recvLen);
      return;
    }
    final id = msg[1];
    final p = _pending[id];
    // Tally received bytes before dispatch removes the pending entry.
    onTraffic?.call(p?.action ?? 'other', recv: recvLen);
    if (p == null) return;
    if (t == 'RES') {
      _pending.remove(id);
      final status =
          (msg.length > 2 && msg[2] is num) ? (msg[2] as num).toInt() : 200;
      final data = (msg.length > 3 && msg[3] is Map)
          ? (msg[3] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      // A stream request answered by an error RES must reject so the caller retries over HTTP.
      if (p.stream && (status >= 400 || data['error'] != null)) {
        p.completeError(ApiException(
            p.action,
            status,
            data['error']?.toString() ?? 'Request failed ($status)',
            '',
            retryAfterFrom(null, data['retryAfter'])));
        return;
      }
      p.complete(ApiSocketResult(
          status: status, data: data, items: const [], hasMore: false));
    } else if (t == 'ITEM') {
      if (msg.length > 2) p.items.add(msg[2]);
    } else if (t == 'END') {
      _pending.remove(id);
      final hdrs = (msg.length > 3 && msg[3] is Map) ? msg[3] as Map : const {};
      final hasMore =
          '${hdrs['x-has-more'] ?? hdrs['X-Has-More'] ?? ''}' == '1';
      p.complete(ApiSocketResult(
          status: 200, data: const {}, items: p.items, hasMore: hasMore));
    }
  }

  /// Sends a REQ and resolves its result; rejects on close or timeout so the caller falls back to HTTP.
  Future<ApiSocketResult> request(
    String action,
    Map<String, dynamic> extra, {
    bool stream = false,
    Duration? timeout,
  }) {
    if (!_open || _channel == null) {
      return Future.error(StateError('api socket not ready'));
    }
    final id = _nextId++;
    final p = _Pending(stream: stream, action: action);
    _pending[id] = p;
    p.timer = Timer(timeout ?? _requestTimeout, () {
      if (_pending.remove(id) != null) {
        p.completeError(StateError('api request timeout'));
      }
    });
    try {
      final sent = _send(['REQ', id, action, extra]);
      onTraffic?.call(action, sent: sent);
    } catch (e) {
      _pending.remove(id);
      p.completeError(e);
    }
    return p.future;
  }

  /// Sends [frame] and returns its JSON byte length for [onTraffic].
  int _send(List<dynamic> frame) {
    final ch = _channel;
    if (ch == null) throw StateError('api socket not ready');
    final encoded = jsonEncode(frame);
    ch.sink.add(encoded);
    return encoded.length;
  }

  void _failAllPending(Object err) {
    for (final p in _pending.values) {
      p.completeError(err);
    }
    _pending.clear();
  }

  /// Fails in-flight requests before teardown, which suppresses the onDone that would report the close.
  void _resetChannel() {
    _failAllPending(StateError('api socket reconnecting'));
    _teardown();
  }

  void _teardown() {
    _open = false;
    _authed = false;
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try {
        unawaited(ch.sink.close());
      } catch (_) {}
    }
  }

  void dispose() {
    _failAllPending(StateError('api socket disposed'));
    _teardown();
  }
}

class _Pending {
  _Pending({required this.stream, required this.action});
  final bool stream;

  /// The request action, for tallying frame bytes.
  final String action;
  final List<dynamic> items = [];
  final Completer<ApiSocketResult> _completer = Completer<ApiSocketResult>();
  Timer? timer;

  Future<ApiSocketResult> get future => _completer.future;

  void complete(ApiSocketResult r) {
    timer?.cancel();
    if (!_completer.isCompleted) _completer.complete(r);
  }

  void completeError(Object e) {
    timer?.cancel();
    if (!_completer.isCompleted) _completer.completeError(e);
  }
}

const String kOwnMediaApex = 'nymchat.app';

bool isOwnMediaUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  return host == kOwnMediaApex || host.endsWith('.$kOwnMediaApex');
}

class ApiClient {
  ApiClient({
    http.Client? client,
    String? baseUrl,
    this._giphyApiKey = kApiGiphyApiKey,
    ApiSocket? apiSocket,
    ApiSocketFactory? apiSocketFactory,
  })  : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? ApiConfig.proxyBaseUrl(),
        _injectedSocket = apiSocket,
        _socketFactory = apiSocketFactory,
        // Off until [activateApiSocket] or an injected socket, so plain clients stay HTTP-only for tests.
        _socketEnabled = apiSocket != null || apiSocketFactory != null;

  final http.Client _client;
  final String _baseUrl;
  final String _giphyApiKey;

  /// Whether the WS-first `/api/storage` transport is active.
  bool _socketEnabled;
  final ApiSocket? _injectedSocket;
  final ApiSocketFactory? _socketFactory;
  ApiSocket? _socket;

  /// Turns on WS-first storage with HTTP fallback (call once at boot); [factory] is for tests.
  void activateApiSocket({ApiSocketFactory? factory}) {
    _socketEnabled = true;
    if (factory != null && _socket == null && _injectedSocket == null) {
      _socket = ApiSocket(
        url: _apiSocketUri(),
        factory: factory,
        onTraffic: _trackApiData,
      );
    }
  }

  /// Builds the signed `api-ws` socket auth, or null for an unauthenticated public-read socket.
  Future<Map<String, dynamic>?> Function()? _apiSocketAuthBuilder;

  void setApiSocketAuthBuilder(
    Future<Map<String, dynamic>?> Function()? builder,
  ) {
    _apiSocketAuthBuilder = builder;
  }

  /// `wss://<host>/api`, derived from the proxy base.
  Uri _apiSocketUri() {
    final u = Uri.parse(_baseUrl);
    final segs = List<String>.from(u.pathSegments);
    if (segs.isNotEmpty) {
      segs.removeLast(); // Drop `proxy`, leaving `…/api`.
    }
    return Uri(
      scheme: u.scheme == 'http' ? 'ws' : 'wss',
      host: u.host,
      port: u.hasPort ? u.port : null,
      pathSegments: segs,
    );
  }

  ApiSocket _ensureSocketObject() {
    return _socket ??= _injectedSocket ??
        ApiSocket(
          url: _apiSocketUri(),
          factory: _socketFactory ?? defaultApiSocketFactory,
          onTraffic: _trackApiData,
        );
  }

  /// Tries [action] over the socket when authed or a public read; null on any failure, including error frames.
  Future<ApiSocketResult?> _trySocket(
    String action,
    Map<String, dynamic> body, {
    required bool stream,
  }) async {
    if (!_socketEnabled) return null;
    final authed = body.containsKey('auth');
    // Authed requests need a signable identity; otherwise go straight to HTTP.
    final authBuilder = _apiSocketAuthBuilder;
    if (authed && authBuilder == null) return null;
    try {
      final socket = _ensureSocketObject();
      // Authenticate whenever an identity exists, even for public reads, so an upgrade doesn't orphan pending reads.
      Map<String, dynamic>? authEvent;
      if (authBuilder != null && !socket.isAuthenticated) {
        authEvent = await authBuilder();
        // Signing failed: skip the socket for this request too.
        if (authEvent == null) return null;
      }
      // Give the handshake only a brief window, then use HTTP while it keeps connecting.
      final connecting = socket.ensureConnected(authEvent: authEvent);
      // Swallow a post-timeout connect failure.
      unawaited(connecting.catchError((_) {}));
      await connecting.timeout(const Duration(milliseconds: 800));
      // The socket is authenticated once, so strip pubkey/auth from per-request bodies.
      final extra = <String, dynamic>{
        for (final e in body.entries)
          if (e.key != 'action' && e.key != 'auth' && e.key != 'pubkey')
            e.key: e.value,
      };
      final result = await socket.request(action, extra, stream: stream);
      if (!stream && result.status == 429) {
        throw ApiException(
          action,
          429,
          result.data['error']?.toString() ?? 'Request failed (429)',
          result.data['code']?.toString() ?? '',
          retryAfterFrom(null, result.data['retryAfter']),
        );
      }
      // An error frame also falls back to HTTP, whose response is authoritative.
      if (!stream &&
          (result.status < 200 ||
              result.status >= 300 ||
              result.data['error'] != null)) {
        return null;
      }
      return result;
    } on ApiException catch (e) {
      if (!stream && e.statusCode == 429) rethrow;
      return null;
    } catch (_) {
      return null; // Fall back to HTTP.
    }
  }

  /// Runs a bot/ledger [action] over the shared authed socket with raw status semantics; null means use HTTP.
  Future<({int status, Map<String, dynamic> data})?> botSocketRequest(
    String action,
    Map<String, dynamic> extra, {
    Duration? timeout,
  }) async {
    if (!_socketEnabled) return null;
    final authBuilder = _apiSocketAuthBuilder;
    if (authBuilder == null) return null;
    try {
      final socket = _ensureSocketObject();
      Map<String, dynamic>? authEvent;
      if (!socket.isAuthenticated) {
        authEvent = await authBuilder();
        // No signable identity: the bot ledger can't ride the socket.
        if (authEvent == null) return null;
      }
      await socket.ensureConnected(authEvent: authEvent);
      final res = await socket.request(action, extra, timeout: timeout);
      return (status: res.status, data: res.data);
    } catch (_) {
      return null; // Fall back to HTTP.
    }
  }

  /// Process-wide /api traffic sink for Network Stats; null in tests.
  static RelayStats? apiStatsSink;

  static void _trackApiData(String action, {int sent = 0, int recv = 0}) {
    apiStatsSink?.recordApiData(action, sent: sent, recv: recv);
  }

  /// Request body size in bytes for the tally; 0 for null or other types.
  static int _bodyLen(Object? body) {
    if (body is String) return utf8.encode(body).length;
    if (body is List<int>) return body.length;
    return 0;
  }

  // URL builders

  /// `GET /api/proxy?url=<encoded>` (optional `&emoji=1`).
  String mediaProxyUrl(String url, {bool emoji = false}) {
    if (ApiConfig.directMedia) return url;
    final enc = Uri.encodeComponent(url);
    return emoji ? '$_baseUrl?emoji=1&url=$enc' : '$_baseUrl?url=$enc';
  }

  /// `GET /api/proxy?action=unfurl&url=<encoded>`
  String unfurlUrl(String url) =>
      '$_baseUrl?action=unfurl&url=${Uri.encodeComponent(url)}';

  /// `GET /api/proxy?action=geo-relays`
  String geoRelaysUrl() => '$_baseUrl?action=geo-relays';

  /// `GET /api/proxy?action=geocode&lat&lng&zoom&lang`
  String geocodeUrl(double lat, double lng,
          {int zoom = 10, String lang = 'en'}) =>
      '$_baseUrl?action=geocode&lat=$lat&lng=$lng&zoom=$zoom&lang=$lang';

  /// `GET /api/proxy?action=giphy&q=<q>&api_key=<key>`
  String giphySearchUrl(String query) => ApiConfig.directMedia
      ? 'https://api.giphy.com/v1/gifs/search?api_key=${Uri.encodeComponent(_giphyApiKey)}&q=${Uri.encodeComponent(query)}&limit=20&rating=g'
      : '$_baseUrl?action=giphy&q=${Uri.encodeComponent(query)}&api_key=${Uri.encodeComponent(_giphyApiKey)}';

  /// `GET /api/proxy?action=giphy&trending=1&api_key=<key>`
  String giphyTrendingUrl() => ApiConfig.directMedia
      ? 'https://api.giphy.com/v1/gifs/trending?api_key=${Uri.encodeComponent(_giphyApiKey)}&limit=20&rating=g'
      : '$_baseUrl?action=giphy&trending=1&api_key=${Uri.encodeComponent(_giphyApiKey)}';

  /// `PUT /api/proxy?action=upload&server=<encoded>`
  String blossomUploadUrl(String server) => ApiConfig.directMedia
      ? '${server.replaceFirst(RegExp(r'/+$'), '')}/upload'
      : '$_baseUrl?action=upload&server=${Uri.encodeComponent(server)}';

  /// `PUT /api/proxy?action=mirror&server=<encoded>`: asks a Blossom server to pull an uploaded blob.
  String blossomMirrorUrl(String server) => ApiConfig.directMedia
      ? '${server.replaceFirst(RegExp(r'/+$'), '')}/mirror'
      : '$_baseUrl?action=mirror&server=${Uri.encodeComponent(server)}';

  /// `GET|POST /api/proxy?action=json&url=<encoded>`, the JSON privacy proxy.
  String jsonProxyUrl(String url) =>
      '$_baseUrl?action=json&url=${Uri.encodeComponent(url)}';

  /// `POST /api/proxy?action=zap-verify`
  String zapVerifyUrl() => '$_baseUrl?action=zap-verify';

  /// `https://<host>/api/storage`, derived so the NIP-98 `u` tag matches the request URL.
  String get storageUrl => _siblingApi('storage');

  /// `https://<host>/api/bot`
  String get botUrl => _siblingApi('bot');

  /// Rewrites the proxy base to a sibling `…/api/<name>`.
  String _siblingApi(String name) {
    final u = Uri.parse(_baseUrl);
    final segs = List<String>.from(u.pathSegments);
    if (segs.isNotEmpty) {
      segs[segs.length - 1] = name;
    } else {
      segs.add(name);
    }
    // Build a query-less URI; replace(query: '') leaves a trailing '?'.
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      pathSegments: segs,
    ).toString();
  }

  // Network calls

  Map<String, String> _headers([Map<String, String>? extra]) => {
        ...ApiConfig.defaultHeaders,
        ...?extra,
      };

  /// Response body decoded as UTF-8, since package:http defaults charset-less responses to Latin-1.
  static String _utf8Body(http.Response res) =>
      utf8.decode(res.bodyBytes, allowMalformed: true);

  /// Case-insensitive header lookup; MockClient preserves header casing.
  static String? _header(http.Response res, String name) {
    final direct = res.headers[name];
    if (direct != null) return direct;
    final lower = name.toLowerCase();
    for (final e in res.headers.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }

  static http.Response _utf8Response(http.Response res) {
    final ct = _header(res, 'content-type');
    if (ct != null && ct.toLowerCase().contains('charset=')) return res;
    return http.Response.bytes(
      res.bodyBytes,
      res.statusCode,
      headers: {
        ...res.headers,
        'content-type': '${ct ?? 'application/json'}; charset=utf-8',
      },
      request: res.request,
      reasonPhrase: res.reasonPhrase,
      isRedirect: res.isRedirect,
      persistentConnection: res.persistentConnection,
    );
  }

  /// Translates [text]; `source` defaults to 'auto'.
  Future<TranslateResult> translate(
    String text,
    String target, {
    String source = 'auto',
  }) async {
    final payload =
        jsonEncode({'text': text, 'source': source, 'target': target});
    final res = await _client.post(
      Uri.parse('$_baseUrl?action=translate'),
      headers: _headers({'Content-Type': 'application/json'}),
      body: payload,
    );
    _trackApiData('translate',
        sent: _bodyLen(payload), recv: _bodyLen(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException('translate', res.statusCode, _utf8Body(res));
    }
    return TranslateResult.fromJson(
        jsonDecode(_utf8Body(res)) as Map<String, dynamic>);
  }

  /// Process-wide unfurl cache; failures are cached briefly and concurrent callers share one request.
  static final Map<String, ({DateTime at, UnfurlResult? data})> _unfurlCache =
      {};
  static final Map<String, Future<UnfurlResult>> _unfurlInflight = {};
  static const Duration _unfurlTtl = Duration(days: 7);
  static const Duration _unfurlMissTtl = Duration(hours: 1);
  static const int _unfurlCacheMax = 200;

  /// Synchronous cache peek so an unfurled card paints on its first frame.
  UnfurlResult? unfurlCached(String url) {
    final hit = _unfurlCache[url];
    if (hit == null || hit.data == null) return null;
    if (DateTime.now().difference(hit.at) > _unfurlTtl) return null;
    return hit.data;
  }

  Future<UnfurlResult> unfurl(String url) {
    final hit = _unfurlCache[url];
    if (hit != null) {
      final ttl = hit.data != null ? _unfurlTtl : _unfurlMissTtl;
      if (DateTime.now().difference(hit.at) <= ttl) {
        final data = hit.data;
        if (data == null) {
          return Future.error(ApiException('unfurl', 0, 'cached failure'));
        }
        return Future.value(data);
      }
      _unfurlCache.remove(url);
    }
    final pending = _unfurlInflight[url];
    if (pending != null) return pending;
    final f = _unfurlFetch(url).then((r) {
      _putUnfurl(url, r);
      return r;
    }, onError: (Object e) {
      _putUnfurl(url, null);
      throw e;
      // Block body on purpose: an arrow would make whenComplete await its own future and deadlock.
    }).whenComplete(() {
      _unfurlInflight.remove(url);
    });
    _unfurlInflight[url] = f;
    return f;
  }

  void _putUnfurl(String url, UnfurlResult? data) {
    _unfurlCache[url] = (at: DateTime.now(), data: data);
    while (_unfurlCache.length > _unfurlCacheMax) {
      _unfurlCache.remove(_unfurlCache.keys.first);
    }
  }

  Future<UnfurlResult> _unfurlFetch(String url) async {
    if (ApiConfig.directMedia) return _unfurlDirect(url);
    final u = unfurlUrl(url);
    final res = await _client.get(Uri.parse(u), headers: _headers());
    _trackApiData('unfurl', sent: _bodyLen(u), recv: _bodyLen(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException('unfurl', res.statusCode, _utf8Body(res));
    }
    return UnfurlResult.fromJson(
        jsonDecode(_utf8Body(res)) as Map<String, dynamic>);
  }

  Future<UnfurlResult> _unfurlDirect(String url) async {
    final uri = Uri.parse(url);
    final res = await _client.get(uri, headers: {
      'Accept': 'text/html,application/xhtml+xml',
      'User-Agent': ApiConfig.userAgentFor(uri),
    });
    final type = (res.headers['content-type'] ?? '').toLowerCase();
    if (res.statusCode != 200 || !type.contains('text/html')) {
      throw ApiException('unfurl', res.statusCode, 'no page preview');
    }
    return openGraphFromHtml(_utf8Body(res), url);
  }

  static UnfurlResult openGraphFromHtml(String html, String pageUrl) {
    String? meta(String attr, String key) {
      final k = RegExp.escape(key);
      final a = RegExp('<meta[^>]+$attr=["\']$k["\'][^>]+content=["\']([^"\']+)["\']',
              caseSensitive: false)
          .firstMatch(html);
      if (a != null) return a.group(1);
      final b = RegExp('<meta[^>]+content=["\']([^"\']+)["\'][^>]+$attr=["\']$k["\']',
              caseSensitive: false)
          .firstMatch(html);
      return b?.group(1);
    }

    String? get(String p) => meta('property', 'og:$p') ?? meta('name', 'twitter:$p');
    String decode(String s) => s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&');
    String resolve(String? raw) {
      if (raw == null || raw.isEmpty) return '';
      try {
        final u = Uri.parse(pageUrl).resolve(raw);
        return (u.scheme == 'http' || u.scheme == 'https') ? u.toString() : '';
      } catch (_) {
        return '';
      }
    }

    String clip(String s, int n) => s.length > n ? s.substring(0, n) : s;
    final title = get('title') ??
        RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false)
            .firstMatch(html)
            ?.group(1) ??
        '';
    final description = get('description') ?? meta('name', 'description') ?? '';
    final fav = RegExp(
                r'''<link[^>]+rel=["'](?:icon|shortcut icon)["'][^>]+href=["']([^"']+)["']''',
                caseSensitive: false)
            .firstMatch(html)
            ?.group(1) ??
        RegExp(r'''<link[^>]+href=["']([^"']+)["'][^>]+rel=["'](?:icon|shortcut icon)["']''',
                caseSensitive: false)
            .firstMatch(html)
            ?.group(1);
    return UnfurlResult(
      url: pageUrl,
      title: clip(decode(title), 300),
      description: clip(decode(description), 500),
      image: resolve(get('image')),
      siteName: decode(get('site_name') ?? ''),
      type: get('type') ?? '',
      favicon: resolve(fav),
    );
  }

  static bool blossomTypeAllowed(String type) =>
      type == 'application/octet-stream' ||
      const ['image/', 'video/', 'audio/'].any(type.startsWith);

  Map<String, String> _blossomHeaders(Uri uri, Map<String, String> extra) =>
      ApiConfig.directMedia
          ? {'User-Agent': ApiConfig.userAgentFor(uri), 'Accept': 'application/json', ...extra}
          : _headers(extra);

  /// PUTs a Blossom blob via the proxy with a kind-24242 [authHeader]; returns the Blossom JSON.
  Future<Map<String, dynamic>> uploadBlob(
    Uint8List bytes,
    String server,
    String authHeader, {
    String contentType = 'application/octet-stream',
  }) async {
    final type = contentType.split(';').first.trim().toLowerCase();
    if (!blossomTypeAllowed(type)) {
      throw ApiException('upload', 415, 'Content type not allowed: $type');
    }
    final uri = Uri.parse(blossomUploadUrl(server));
    final res = await _client.put(
      uri,
      headers: _blossomHeaders(uri, {
        'Authorization': authHeader,
        'Content-Type': contentType,
      }),
      body: bytes,
    );
    if (!ApiConfig.directMedia) {
      _trackApiData('upload', sent: bytes.length, recv: _bodyLen(res.bodyBytes));
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final reason = (res.headers['x-reason'] ?? '').trim();
      throw ApiException(
          'upload', res.statusCode, reason.isNotEmpty ? reason : _utf8Body(res));
    }
    return jsonDecode(_utf8Body(res)) as Map<String, dynamic>;
  }

  /// Asks [server] to mirror the blob at [sourceUrl] via the proxy; returns the Blossom JSON.
  Future<Map<String, dynamic>> mirrorBlob(
    String sourceUrl,
    String server,
    String authHeader,
  ) async {
    final payload = jsonEncode({'url': sourceUrl});
    final uri = Uri.parse(blossomMirrorUrl(server));
    final res = await _client.put(
      uri,
      headers: _blossomHeaders(uri, {
        'Authorization': authHeader,
        'Content-Type': 'application/json',
      }),
      body: payload,
    );
    if (!ApiConfig.directMedia) {
      _trackApiData('mirror',
          sent: _bodyLen(payload), recv: _bodyLen(res.bodyBytes));
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('mirror', res.statusCode, _utf8Body(res));
    }
    return jsonDecode(_utf8Body(res)) as Map<String, dynamic>;
  }

  /// Fetches JSON through the privacy proxy so upstream hosts only see Cloudflare IPs; GET or POST.
  Future<http.Response> proxiedJsonFetch(
    String targetUrl, {
    String method = 'GET',
    String? body,
    String? contentType,
  }) async {
    Future<http.Response> run(Uri uri, Map<String, String>? headers) =>
        method == 'POST'
            ? _client.post(uri, headers: headers, body: body)
            : _client.get(uri, headers: headers);
    Future<http.Response> direct() async => _utf8Response(await run(
          Uri.parse(targetUrl),
          contentType != null ? {'Content-Type': contentType} : null,
        ));
    if (_baseUrl.isEmpty) return direct();
    final http.Response res;
    try {
      res = await run(
        Uri.parse(jsonProxyUrl(targetUrl)),
        _headers({'Content-Type': ?contentType}),
      );
    } catch (e) {
      if (proxyUnreachable(e)) return direct();
      rethrow;
    }
    _trackApiData('json', sent: _bodyLen(body), recv: _bodyLen(res.bodyBytes));
    if (proxyUnreachable(res)) return direct();
    return _utf8Response(res);
  }

  /// Geo relays with finite coords; empty on a non-200 so the caller can fall back to the CSV.
  Future<List<GeoRelay>> geoRelays() async =>
      (await geoRelayDirectories()).upstream;

  /// Both geo-relay directories: `upstream` (bitchat-android) and `vetted` (bitchat iOS).
  Future<({List<GeoRelay> upstream, List<GeoRelay> vetted})>
      geoRelayDirectories() async {
    final u = geoRelaysUrl();
    final res = await _client.get(Uri.parse(u), headers: _headers());
    _trackApiData('geo-relays',
        sent: _bodyLen(u), recv: _bodyLen(res.bodyBytes));
    const empty = (upstream: <GeoRelay>[], vetted: <GeoRelay>[]);
    if (res.statusCode != 200) return empty;
    final data = jsonDecode(_utf8Body(res));
    if (data is! Map || data['relays'] is! List) return empty;
    return (
      upstream: _parseGeoRelayList(data['relays']),
      vetted: _parseGeoRelayList(data['vetted']),
    );
  }

  /// Filters out non-finite coords.
  static List<GeoRelay> _parseGeoRelayList(Object? raw) {
    if (raw is! List) return const [];
    final out = <GeoRelay>[];
    for (final r in raw) {
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

  /// Reverse geocode, returning raw Nominatim JSON.
  Future<Map<String, dynamic>> geocode(
    double lat,
    double lng, {
    int zoom = 10,
    String lang = 'en',
  }) async {
    final u = geocodeUrl(lat, lng, zoom: zoom, lang: lang);
    final res = await _client.get(Uri.parse(u), headers: _headers());
    _trackApiData('geocode', sent: _bodyLen(u), recv: _bodyLen(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException('geocode', res.statusCode, _utf8Body(res));
    }
    return jsonDecode(_utf8Body(res)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> giphySearch(String query) async {
    final u = giphySearchUrl(query);
    final res = await _client.get(Uri.parse(u), headers: _headers());
    _trackApiData('giphy', sent: _bodyLen(u), recv: _bodyLen(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException('giphy', res.statusCode, _utf8Body(res));
    }
    return jsonDecode(_utf8Body(res)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> giphyTrending() async {
    final u = giphyTrendingUrl();
    final res = await _client.get(Uri.parse(u), headers: _headers());
    _trackApiData('giphy', sent: _bodyLen(u), recv: _bodyLen(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException('giphy', res.statusCode, _utf8Body(res));
    }
    return jsonDecode(_utf8Body(res)) as Map<String, dynamic>;
  }

  // Payment settlement

  /// Server-side zap payment check; any transport error resolves false so polling can retry.
  Future<bool> zapVerify({
    required String pr,
    String? verifyUrl,
    String? providerPubkey,
    Map<String, dynamic>? receipt,
  }) async {
    try {
      final payload = jsonEncode({
        'pr': pr,
        'verifyUrl': verifyUrl,
        'providerPubkey': providerPubkey,
        'receipt': receipt,
      });
      final res = await _client.post(
        Uri.parse(zapVerifyUrl()),
        headers: _headers({'Content-Type': 'application/json'}),
        body: payload,
      );
      _trackApiData('zap-verify',
          sent: _bodyLen(payload), recv: _bodyLen(res.bodyBytes));
      if (res.statusCode != 200) return false;
      final data = jsonDecode(_utf8Body(res));
      return data is Map && data['paid'] == true;
    } catch (_) {
      return false;
    }
  }

  /// `POST /api/storage` for shop-* actions; [body] carries `action` and any auth. Throws [ApiException] on non-2xx.
  Future<Map<String, dynamic>> storageAction(Map<String, dynamic> body,
      {bool socket = true}) async {
    final action = (body['action'] ?? 'other').toString();
    // WS-first; a non-null socket result is already a 2xx with no `error`.
    final ws = socket ? await _trySocket(action, body, stream: false) : null;
    if (ws != null) return ws.data;
    final payload = jsonEncode(body);
    final res = await _client.post(
      Uri.parse(storageUrl),
      headers: _headers({'Content-Type': 'application/json'}),
      body: payload,
    );
    _trackApiData(action,
        sent: _bodyLen(payload), recv: _bodyLen(res.bodyBytes));
    final decoded = _decodeJson(res);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
        (body['action'] ?? 'storage').toString(),
        res.statusCode,
        decoded['error']?.toString() ?? _utf8Body(res),
        decoded['code']?.toString() ?? '',
        retryAfterFrom(_header(res, 'retry-after'), decoded['retryAfter']),
      );
    }
    return decoded;
  }

  /// `POST /api/storage` for NDJSON-streamed reads (`profile-get`, `pm-get`); throws [ApiException] on non-2xx.
  Future<StorageStream> storageStream(Map<String, dynamic> body) async {
    final action = (body['action'] ?? 'other').toString();
    // WS-first: streaming actions collect ITEM frames before the HTTP fallback.
    final ws = await _trySocket(action, body, stream: true);
    if (ws != null) {
      return StorageStream(items: ws.items, hasMore: ws.hasMore);
    }
    final payload = jsonEncode(body);
    final res = await _client.post(
      Uri.parse(storageUrl),
      headers: _headers({'Content-Type': 'application/json'}),
      body: payload,
    );
    _trackApiData(action,
        sent: _bodyLen(payload), recv: _bodyLen(res.bodyBytes));
    // Reject even a 2xx that isn't NDJSON, or a JSON error body would be split into bogus items.
    final contentType = _header(res, 'content-type') ?? '';
    if (res.statusCode < 200 ||
        res.statusCode >= 300 ||
        !contentType.contains('application/x-ndjson')) {
      final decoded = _decodeJson(res);
      throw ApiException(
        (body['action'] ?? 'storage').toString(),
        res.statusCode,
        decoded['error']?.toString() ?? _utf8Body(res),
        '',
        retryAfterFrom(_header(res, 'retry-after'), decoded['retryAfter']),
      );
    }
    final items = <dynamic>[];
    for (final line in const LineSplitter().convert(_utf8Body(res))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        items.add(jsonDecode(trimmed));
      } catch (_) {
        // Skip malformed lines.
      }
    }
    final hasMore = (_header(res, 'x-has-more') ?? '') == '1';
    return StorageStream(items: items, hasMore: hasMore);
  }

  /// `POST /api/bot` for Nymbot credit actions; same auth contract as [storageAction], bound to [botUrl].
  Future<Map<String, dynamic>> botAction(Map<String, dynamic> body) async {
    final action = (body['action'] ?? 'other').toString();
    final payload = jsonEncode(body);
    final res = await _client.post(
      Uri.parse(botUrl),
      headers: _headers({'Content-Type': 'application/json'}),
      body: payload,
    );
    _trackApiData(action,
        sent: _bodyLen(payload), recv: _bodyLen(res.bodyBytes));
    final decoded = _decodeJson(res);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
        (body['action'] ?? 'bot').toString(),
        res.statusCode,
        decoded['error']?.toString() ?? _utf8Body(res),
      );
    }
    return decoded;
  }

  Map<String, dynamic> _decodeJson(http.Response res) {
    try {
      final d = jsonDecode(_utf8Body(res));
      return d is Map<String, dynamic> ? d : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void dispose() {
    _socket?.dispose();
    _client.close();
  }
}

/// Streamed `/api/storage` read: per-line [items] and the `X-Has-More` flag.
class StorageStream {
  const StorageStream({required this.items, required this.hasMore});
  final List<dynamic> items;
  final bool hasMore;
}

/// Thrown on a non-success backend response.
class ApiException implements Exception {
  ApiException(this.action, this.statusCode, this.body,
      [this.code = '', this.retryAfter]);
  final String action;
  final int statusCode;
  final String body;
  final String code;
  final Duration? retryAfter;
  @override
  String toString() => 'ApiException($action: HTTP $statusCode)';
}

Duration? retryAfterFrom(String? header, Object? bodyValue, [DateTime? now]) {
  final h = header?.trim() ?? '';
  if (h.isNotEmpty) {
    final secs = num.tryParse(h);
    if (secs != null && secs.isFinite && secs >= 0) {
      return Duration(milliseconds: (secs * 1000).round());
    }
    if (secs == null) {
      try {
        final ms = HttpDate.parse(h)
            .difference(now ?? DateTime.now())
            .inMilliseconds;
        return Duration(milliseconds: ms < 0 ? 0 : ms);
      } catch (_) {}
    }
  }
  final v = bodyValue is num
      ? bodyValue
      : (bodyValue is String ? num.tryParse(bodyValue.trim()) : null);
  if (v == null || !v.isFinite || v < 0) return null;
  return Duration(milliseconds: (v * 1000).round());
}

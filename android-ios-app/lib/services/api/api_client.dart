import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';
import '../nostr/event_signer.dart';
import '../relay/relay_stats.dart';
import 'api_config.dart';

/// Factory that opens a [WebSocketChannel] to the `/api` socket. Overridable in
/// tests so no real socket is opened (mirrors `WebSocketChannelFactory` in
/// relay_connection.dart). The native factory attaches the `User-Agent` header
/// the backend `isNymchatClient` gate recognizes — the headers-less
/// `WebSocketChannel.connect` would send a default Dart UA.
typedef ApiSocketFactory = WebSocketChannel Function(Uri url);

/// The real native `/api` socket factory: an [IOWebSocketChannel] carrying the
/// `NymchatApp/<ver>` UA (same gate the relay sockets pass).
WebSocketChannel defaultApiSocketFactory(Uri url) =>
    IOWebSocketChannel.connect(
      url,
      headers: {'User-Agent': ApiConfig.userAgent},
    );

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

  /// Signer-based async variant: builds the kind-27235 event and signs it via
  /// the active [EventSigner], so a NIP-46 remote signer authenticates exactly
  /// like a local key. Mirrors the PWA's `_signBotAuth`, which signs through the
  /// generic `signEvent` dispatch (local OR remote) and caches non-[sensitive]
  /// auth for 90s keyed by `pubkey|action|url` (`_botAuthCache`, pms.js:1659) so
  /// a remote signer isn't round-tripped per request. Returns null when signing
  /// fails (remote unreachable/declined) — the caller then proceeds best-effort
  /// (unauthenticated), exactly as before for accounts that can't sign.
  static Future<Map<String, dynamic>?> buildSigned({
    required String action,
    required String url,
    required EventSigner signer,
    bool sensitive = false,
    int? createdAt,
  }) async {
    final pubkey = signer.pubkey;
    final now = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cacheKey = '$pubkey|$action|$url';
    if (!sensitive) {
      final cached = _authCache[cacheKey];
      // Match the PWA: validate the *signed* event's created_at (a remote signer
      // may stamp its own clock) against a 90s window, well inside the worker's
      // 120s tolerance.
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
    ];
    final unsigned = UnsignedEvent(
      pubkey: pubkey,
      createdAt: now,
      kind: 27235,
      tags: tags,
      content: content,
    );
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

  /// 90s non-sensitive auth cache (the PWA's `_botAuthCache`). Static so it is
  /// shared across the storage + api-ws builders for one process identity.
  static final Map<String, _CachedAuth> _authCache = {};

  /// Drops all cached auth. Call on sign-out / identity switch so a new identity
  /// never reuses the previous one's signed auth.
  static void clearAuthCache() => _authCache.clear();

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

/// A cached signed auth event with the timestamp its 90s validity is judged by
/// (see [Nip98Auth.buildSigned]).
class _CachedAuth {
  _CachedAuth(this.pubkey, this.createdAt, this.auth);
  final String pubkey;
  final int createdAt;
  final Map<String, dynamic> auth;
}

/// The parsed result of a single `/api` socket request: the HTTP-equivalent
/// [status] code, the decoded JSON [data] (single-response actions), and the
/// per-line [items] for a streaming (NDJSON) action with the `X-Has-More` flag
/// recovered from the `END` frame headers.
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

/// One persistent, multiplexed `/api` WebSocket that carries every D1 storage op
/// so the client doesn't open an HTTP request (and sign an auth event) per
/// fetch/put — the native port of the PWA's `_ensureApiSocket` / `_apiSocketSend`
/// (shop.js:12-151).
///
/// Framing matches the worker byte-for-byte:
///   * client → `['AUTH', authEvent]` on open (only when authenticated), then
///     `['REQ', id, action, extra]` per request;
///   * server → `['AUTH_OK']` / `['AUTH_ERR', msg]`, `['RES', id, status, data]`
///     (single), or `['ITEM', id, item]…['END', id, headers]` (streaming).
///
/// Logged-in callers authenticate the socket once (so per-request signatures are
/// skipped — the worker pins `context._wsAuthedPubkey`); logged-out callers open
/// an unauthenticated socket usable for public reads (channel/profile/shop-status).
/// A connect/auth failure trips a short cooldown so a broken endpoint doesn't add
/// a connect-timeout to every call (shop.js `_apiSockFailedUntil`); the caller
/// then falls back to HTTP.
class ApiSocket {
  ApiSocket({
    required Uri url,
    ApiSocketFactory factory = defaultApiSocketFactory,
    Duration connectTimeout = const Duration(seconds: 12),
    Duration requestTimeout = const Duration(seconds: 45),
    Duration failureCooldown = const Duration(seconds: 5),
    this.onTraffic,
  })  : _url = url,
        _factory = factory,
        _connectTimeout = connectTimeout,
        _requestTimeout = requestTimeout,
        _failureCooldown = failureCooldown;

  final Uri _url;
  final ApiSocketFactory _factory;
  final Duration _connectTimeout;
  final Duration _requestTimeout;
  final Duration _failureCooldown;

  /// Per-frame byte tally (sent/received JSON frame length, attributed to the
  /// request action), wired to the network-stats sink. Mirrors the PWA's
  /// `_trackApiData` calls in `_ensureApiSocket`/`_apiSocketSend` (shop.js:60-70,
  /// 147). Null in HTTP-only clients and the test default.
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

  /// Ensures the socket is connected (and authenticated when [authEvent] is
  /// non-null). Resolves when ready; throws on connect/auth failure (and trips
  /// the cooldown). [authEvent] is the signed `api-ws` kind-27235 event the
  /// worker's `AUTH` handler verifies (built by the caller exactly like the
  /// other storage auth, but bound to the `…/api` WS URL).
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
      timer = Timer(_connectTimeout, () => fail(StateError('api socket timeout')));

      if (needAuth) {
        final sent = _send(['AUTH', authEvent]);
        onTraffic?.call('auth', sent: sent);
      } else {
        // Mirror `ws.onopen` (shop.js:58): an unauthenticated socket is ready
        // only once the underlying connection is actually up — not merely once
        // the listener is attached — so requests are never framed into (and
        // left pending on) a socket that never opened. The `_channel == ch`
        // guard skips a stale ready/error racing a timeout-driven teardown.
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
    // Frame byte count for the network stats (PWA: string `event.data.length`,
    // else `byteLength`). Attributed to the action below, like `_trackApiData`.
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
    // Attribute received bytes to the request's action (else 'other') before any
    // dispatch removes the pending entry — mirrors the PWA's recv tally.
    onTraffic?.call(p?.action ?? 'other', recv: recvLen);
    if (p == null) return;
    if (t == 'RES') {
      _pending.remove(id);
      final status = (msg.length > 2 && msg[2] is num) ? (msg[2] as num).toInt() : 200;
      final data = (msg.length > 3 && msg[3] is Map)
          ? (msg[3] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      // A stream request answered by an error RES (the worker rejects before
      // any ITEM/END) must REJECT — the PWA's non-raw `_apiSocketSend` rejects
      // on `status >= 400 || data.error` (shop.js:88-95), which the caller's
      // catch turns into an HTTP retry — never resolve as an empty item list.
      // Non-stream error RES keeps resolving; [_trySocket] gates its status.
      if (p.stream && (status >= 400 || data['error'] != null)) {
        p.completeError(ApiException(p.action, status,
            data['error']?.toString() ?? 'Request failed ($status)'));
        return;
      }
      p.complete(ApiSocketResult(
          status: status, data: data, items: const [], hasMore: false));
    } else if (t == 'ITEM') {
      if (msg.length > 2) p.items.add(msg[2]);
    } else if (t == 'END') {
      _pending.remove(id);
      final hdrs = (msg.length > 3 && msg[3] is Map) ? msg[3] as Map : const {};
      final hasMore = '${hdrs['x-has-more'] ?? hdrs['X-Has-More'] ?? ''}' == '1';
      p.complete(ApiSocketResult(
          status: 200, data: const {}, items: p.items, hasMore: hasMore));
    }
  }

  /// Sends a `REQ` for [action] with [extra] and resolves the result. [stream]
  /// collects `ITEM` frames until `END`; otherwise a single `RES`. Rejects on a
  /// closed socket or a per-request timeout (so the caller falls back to HTTP).
  Future<ApiSocketResult> request(
    String action,
    Map<String, dynamic> extra, {
    bool stream = false,
  }) {
    if (!_open || _channel == null) {
      return Future.error(StateError('api socket not ready'));
    }
    final id = _nextId++;
    final p = _Pending(stream: stream, action: action);
    _pending[id] = p;
    p.timer = Timer(_requestTimeout, () {
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

  /// Encodes [frame], sends it, and returns the JSON byte length sent (so the
  /// caller can tally it via [onTraffic], matching the PWA's per-frame
  /// `_trackApiData(action, frame.length, 0)`).
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

  /// Tears down the current channel, failing every in-flight request FIRST —
  /// the PWA's `onclose` → `fail` rejects all `sock.pending` (shop.js:38-46,
  /// 105) — so a request orphaned by a reconnect (e.g. the unauth→auth upgrade)
  /// falls back to HTTP immediately instead of waiting out the 45s request
  /// timeout. Must run before [_teardown] cancels the stream listener, which
  /// suppresses the onDone that would otherwise report the close.
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

  /// Closes the socket and fails any in-flight requests.
  void dispose() {
    _failAllPending(StateError('api socket disposed'));
    _teardown();
  }
}

/// An in-flight `/api` socket request awaiting its `RES`/`END` frame.
class _Pending {
  _Pending({required this.stream, required this.action});
  final bool stream;

  /// The request action, so a received RES/ITEM/END frame's bytes are tallied
  /// under it (the PWA looks this up from `sock.pending`).
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

/// Typed client for the backend proxy endpoints (spec §6).
///
/// Every request carries the `isNymchatClient` UA header
/// ([ApiConfig.userAgent]). Construction performs NO network — calls are lazy.
/// The `http.Client` is injectable for tests.
class ApiClient {
  ApiClient({
    http.Client? client,
    String? baseUrl,
    String giphyApiKey = kApiGiphyApiKey,
    ApiSocket? apiSocket,
    ApiSocketFactory? apiSocketFactory,
  })  : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? ApiConfig.proxyBaseUrl(),
        _giphyApiKey = giphyApiKey,
        _injectedSocket = apiSocket,
        _socketFactory = apiSocketFactory,
        // The socket is OFF until [activateApiSocket] (or an injected socket /
        // factory) turns it on, so a plain ApiClient — the unit-test default and
        // the shop controller's own client — stays HTTP-only and a [MockClient]
        // still sees every request. Production wires it on at boot.
        _socketEnabled = apiSocket != null || apiSocketFactory != null;

  final http.Client _client;
  final String _baseUrl;
  final String _giphyApiKey;

  /// Whether the WS-first transport for `/api/storage` is active. The PWA always
  /// rides a persistent socket and falls back to HTTP (shop.js:181-202/215-238);
  /// natively this is enabled once the controller calls [activateApiSocket] (or
  /// an `apiSocket`/`apiSocketFactory` is injected), and otherwise HTTP-only.
  bool _socketEnabled;
  final ApiSocket? _injectedSocket;
  final ApiSocketFactory? _socketFactory;
  ApiSocket? _socket;

  /// Turns on the WS-first storage transport (call once at boot). [factory]
  /// overrides the native socket factory (tests pass a fake). After this, every
  /// [storageAction]/[storageStream] tries the socket first per the PWA gating
  /// and falls back to HTTP on any socket failure.
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

  /// Builds the signed `api-ws` auth event for the socket's AUTH handshake, or
  /// null when there's no signable identity (an unauthenticated socket is then
  /// opened for public reads). Wired by the controller, mirroring the PWA's
  /// `_signBotAuth('api-ws', 'WS')` (shop.js:30). When unset the socket is never
  /// authenticated, so only public reads ride it.
  Future<Map<String, dynamic>?> Function()? _apiSocketAuthBuilder;

  /// Registers the `api-ws` socket auth builder (see [_apiSocketAuthBuilder]).
  void setApiSocketAuthBuilder(
    Future<Map<String, dynamic>?> Function()? builder,
  ) {
    _apiSocketAuthBuilder = builder;
  }

  /// `wss://<host>/api` — the multiplexed storage socket (`_apiWsUrl`, shop.js:5).
  /// Derived from the proxy base by swapping scheme→wss and the trailing path
  /// segment to the bare `/api`.
  Uri _apiSocketUri() {
    final u = Uri.parse(_baseUrl);
    final segs = List<String>.from(u.pathSegments);
    if (segs.isNotEmpty) {
      segs.removeLast(); // drop `proxy` → leaves `…/api`
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

  /// Attempts to run a storage [action] over the `/api` socket, returning the
  /// `(status, data, items, hasMore)` result, or null when the socket is
  /// skipped/unavailable so the caller falls back to HTTP. Gating mirrors the
  /// PWA exactly (`if (this.pubkey || !withAuth)`, shop.js:181/215): the socket
  /// is tried when the request is authenticated ([authed]) OR is a public read
  /// (`withAuth === false`). Any connect/auth/request failure — including a
  /// server *error frame* (a non-2xx single RES or a `data.error`) — resolves to
  /// null so the caller transparently falls back to HTTP (the PWA reject→retry).
  Future<ApiSocketResult?> _trySocket(
    String action,
    Map<String, dynamic> body, {
    required bool stream,
  }) async {
    if (!_socketEnabled) return null;
    final authed = body.containsKey('auth');
    // Public reads ride the socket even logged out; authed requests need a
    // signable identity (the auth builder). Otherwise skip straight to HTTP.
    final authBuilder = _apiSocketAuthBuilder;
    if (authed && authBuilder == null) return null;
    try {
      final socket = _ensureSocketObject();
      // Authenticate the socket whenever a signable identity exists — the PWA's
      // `needAuth = !!this.pubkey` (shop.js:14) — even when THIS request is a
      // public read. Otherwise a boot-time public read (profile-get/channel-get)
      // opens an unauthenticated socket that the first signed request then tears
      // down and re-opens with AUTH, orphaning every read pending on it. Sign
      // only when the socket isn't already authenticated (the PWA signs once
      // per connection, shop.js:30).
      Map<String, dynamic>? authEvent;
      if (authBuilder != null && !socket.isAuthenticated) {
        authEvent = await authBuilder();
        // Signing failed (remote signer unreachable/declined): the PWA's
        // `_signBotAuth` rejection lands in the callers' catch → HTTP retry,
        // so skip the socket for this request too.
        if (authEvent == null) return null;
      }
      // Don't stall a request for seconds on the socket handshake — at boot the
      // first channel backfill (e.g. #nymchat) waited ~5s for the socket to open
      // instead of loading over HTTP. Give the socket only a brief window to come
      // up; if it doesn't, fall back to HTTP NOW while the connection keeps going
      // in the background, so the next request rides the (by then) connected
      // socket (which is why clicking away + back already loaded instantly). An
      // already-open socket resolves instantly, so steady-state still rides it.
      final connecting = socket.ensureConnected(authEvent: authEvent);
      // Swallow a post-timeout connect failure so it isn't an unhandled async
      // error (the await below stops listening once the timeout fires).
      unawaited(connecting.catchError((_) {}));
      await connecting.timeout(const Duration(milliseconds: 800));
      // The socket is authenticated once; per-request bodies drop pubkey/auth
      // (the worker pins the socket's pubkey — shop.js comment at :273). Public
      // reads never carried them. Strip them from the `extra` we frame.
      final extra = <String, dynamic>{
        for (final e in body.entries)
          if (e.key != 'action' && e.key != 'auth' && e.key != 'pubkey')
            e.key: e.value,
      };
      final result = await socket.request(action, extra, stream: stream);
      // SAFETY/parity: a server *error frame* (non-2xx RES, or a `data.error`)
      // is a fallback trigger too. The PWA's non-`raw` `_apiSocketSend` REJECTS
      // on `status >= 400 || data.error` (shop.js:89), which its callers'
      // try/catch turns into an HTTP retry (`_storageApiRequest`/`_storageApiStream`
      // shop.js:182-185/216-219). So we return null here to make the caller fall
      // back to HTTP rather than surfacing the socket's error — HTTP always gets
      // a turn, and its (re-signed) response is the authoritative one the caller
      // sees. A streaming read's error arrives as an error RES that [_onFrame]
      // rejects (the throw lands in the catch below → null → HTTP fallback), so
      // this status gate only sees single-response actions.
      if (!stream &&
          (result.status < 200 ||
              result.status >= 300 ||
              result.data['error'] != null)) {
        return null;
      }
      return result;
    } catch (_) {
      return null; // fall back to HTTP
    }
  }

  /// Process-wide /api traffic sink for the Network Stats "App data" section.
  /// Mirrors the PWA's single shared `nym.relayStats` that `_trackApiData`
  /// writes to (shop.js:113): every [ApiClient] (shop, zaps, profiles, geo,
  /// media, …) tallies its request/response bytes per action here. Set once at
  /// boot ([NostrService] wires it to its persistent stats); null = not tracked
  /// (the default in tests, so unit tests stay isolated).
  static RelayStats? apiStatsSink;

  /// Record an /api request of [action] that sent [sent] request bytes and
  /// received [recv] response bytes into [apiStatsSink] (no-op when unset).
  /// Mirrors `_trackApiData` (shop.js:113).
  static void _trackApiData(String action, {int sent = 0, int recv = 0}) {
    apiStatsSink?.recordApiData(action, sent: sent, recv: recv);
  }

  /// Best-effort byte size of a request body for the App-data tally: a String
  /// body counts its UTF-8 length; a byte body its length; null/other → 0.
  static int _bodyLen(Object? body) {
    if (body is String) return utf8.encode(body).length;
    if (body is List<int>) return body.length;
    return 0;
  }

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

  /// `PUT /api/proxy?action=mirror&server=<encoded>` (users.js:511) — asks a
  /// Blossom server to pull an already-uploaded blob from its primary URL.
  String blossomMirrorUrl(String server) =>
      '$_baseUrl?action=mirror&server=${Uri.encodeComponent(server)}';

  /// `GET|POST /api/proxy?action=json&url=<encoded>` — the JSON privacy proxy
  /// (`proxiedJsonFetch`, relays.js:3192; worker `handleJsonProxy`, proxy.js:180).
  String jsonProxyUrl(String url) =>
      '$_baseUrl?action=json&url=${Uri.encodeComponent(url)}';

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

  /// UTF-8 text of an HTTP response body. NEVER use `res.body` for wire text:
  /// package:http picks the charset from the Content-Type header and silently
  /// falls back to LATIN-1 when the header carries no `charset=` — and the nym
  /// worker sends charset-less `application/json` / `application/x-ndjson`
  /// (storage.js:199/638). Every UTF-8 byte then decodes as one Latin-1 char,
  /// so multibyte nyms/emoji arrive as mojibake ('ð£…' instead of '🅃…').
  /// The PWA's `response.json()` / TextDecoder always decodes UTF-8 (with
  /// U+FFFD replacement, never throwing), so mirror that here.
  static String _utf8Body(http.Response res) =>
      utf8.decode(res.bodyBytes, allowMalformed: true);

  /// Re-wrap a JSON response whose Content-Type lacks a `charset=` so that
  /// downstream `res.body` readers (the LNURL flows consume the raw response
  /// from [proxiedJsonFetch]) decode UTF-8 instead of package:http's Latin-1
  /// default. JSON is UTF-8 by spec (RFC 8259 §8.1), and the PWA's
  /// `response.json()` always decodes UTF-8.
  static http.Response _utf8Response(http.Response res) {
    final ct = res.headers['content-type'];
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

  /// POST translate `{text, source, target}` -> `{translatedText, detectedLanguage}`.
  /// `source` defaults to `'auto'` (proxy.js:504).
  Future<TranslateResult> translate(
    String text,
    String target, {
    String source = 'auto',
  }) async {
    final payload = jsonEncode({'text': text, 'source': source, 'target': target});
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

  /// GET unfurl (OpenGraph preview).
  Future<UnfurlResult> unfurl(String url) async {
    final u = unfurlUrl(url);
    final res = await _client.get(Uri.parse(u), headers: _headers());
    _trackApiData('unfurl', sent: _bodyLen(u), recv: _bodyLen(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException('unfurl', res.statusCode, _utf8Body(res));
    }
    return UnfurlResult.fromJson(
        jsonDecode(_utf8Body(res)) as Map<String, dynamic>);
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
    _trackApiData('upload', sent: bytes.length, recv: _bodyLen(res.bodyBytes));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('upload', res.statusCode, _utf8Body(res));
    }
    return jsonDecode(_utf8Body(res)) as Map<String, dynamic>;
  }

  /// PUT a Blossom mirror request through the proxy (`action=mirror`,
  /// proxy.js:334): asks [server] to pull the already-uploaded blob at
  /// [sourceUrl] instead of re-uploading the bytes (`_mirrorBlobBackground`,
  /// users.js:640-655). [authHeader] is the same `Nostr <base64>` kind-24242
  /// value as the primary upload — the PWA signs the mirror auth with
  /// `t: 'upload'` too (users.js:642). Body is `{"url": <sourceUrl>}`.
  /// Returns the parsed Blossom JSON (caller reads `data['url']`).
  Future<Map<String, dynamic>> mirrorBlob(
    String sourceUrl,
    String server,
    String authHeader,
  ) async {
    final payload = jsonEncode({'url': sourceUrl});
    final res = await _client.put(
      Uri.parse(blossomMirrorUrl(server)),
      headers: _headers({
        'Authorization': authHeader,
        'Content-Type': 'application/json',
      }),
      body: payload,
    );
    _trackApiData('mirror',
        sent: _bodyLen(payload), recv: _bodyLen(res.bodyBytes));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('mirror', res.statusCode, _utf8Body(res));
    }
    return jsonDecode(_utf8Body(res)) as Map<String, dynamic>;
  }

  /// Fetches a JSON resource through the `/api/proxy?action=json` privacy
  /// proxy so the upstream host (e.g. an LNURL Lightning provider) only ever
  /// sees Cloudflare IPs, mirroring `proxiedJsonFetch` (relays.js:3192-3200).
  ///
  /// The worker passes through GET and POST (any other method is coerced to
  /// GET, proxy.js:195), forwards the request `Content-Type` + body on POST,
  /// and returns the upstream body + status. Like the PWA, the direct fetch of
  /// [targetUrl] happens ONLY when the proxied request itself fails at the
  /// transport level — a non-2xx proxied response is returned as-is (the
  /// upstream status rides through). The direct fallback deliberately omits
  /// the Nymchat headers (a third-party host shouldn't see the app UA).
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
    try {
      final res = await run(
        Uri.parse(jsonProxyUrl(targetUrl)),
        _headers({if (contentType != null) 'Content-Type': contentType}),
      );
      _trackApiData('json',
          sent: _bodyLen(body), recv: _bodyLen(res.bodyBytes));
      return _utf8Response(res);
    } catch (_) {
      return _utf8Response(await run(
        Uri.parse(targetUrl),
        contentType != null ? {'Content-Type': contentType} : null,
      ));
    }
  }

  /// GET the geo relay list -> `[{url,lat,lng}]`. Filters out non-finite coords
  /// (relays.js:20). Returns an empty list on a non-200 so the caller can fall
  /// back to the bitchat CSV.
  Future<List<GeoRelay>> geoRelays() async {
    final u = geoRelaysUrl();
    final res = await _client.get(Uri.parse(u), headers: _headers());
    _trackApiData('geo-relays', sent: _bodyLen(u), recv: _bodyLen(res.bodyBytes));
    if (res.statusCode != 200) return const [];
    final data = jsonDecode(_utf8Body(res));
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
    final u = geocodeUrl(lat, lng, zoom: zoom, lang: lang);
    final res = await _client.get(Uri.parse(u), headers: _headers());
    _trackApiData('geocode', sent: _bodyLen(u), recv: _bodyLen(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException('geocode', res.statusCode, _utf8Body(res));
    }
    return jsonDecode(_utf8Body(res)) as Map<String, dynamic>;
  }

  /// GET Giphy search -> raw Giphy JSON.
  Future<Map<String, dynamic>> giphySearch(String query) async {
    final u = giphySearchUrl(query);
    final res = await _client.get(Uri.parse(u), headers: _headers());
    _trackApiData('giphy', sent: _bodyLen(u), recv: _bodyLen(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException('giphy', res.statusCode, _utf8Body(res));
    }
    return jsonDecode(_utf8Body(res)) as Map<String, dynamic>;
  }

  /// GET Giphy trending -> raw Giphy JSON.
  Future<Map<String, dynamic>> giphyTrending() async {
    final u = giphyTrendingUrl();
    final res = await _client.get(Uri.parse(u), headers: _headers());
    _trackApiData('giphy', sent: _bodyLen(u), recv: _bodyLen(res.bodyBytes));
    if (res.statusCode != 200) {
      throw ApiException('giphy', res.statusCode, _utf8Body(res));
    }
    return jsonDecode(_utf8Body(res)) as Map<String, dynamic>;
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

  /// `POST /api/storage` — the shop-* mutating actions (shop.js `_storageApiRequest`).
  ///
  /// [body] must already carry `action` and, for authenticated actions,
  /// `pubkey` + `auth` (build the latter with [Nip98Auth.build], `url:`
  /// [storageUrl]). Returns the decoded JSON map. Throws [ApiException] on a
  /// non-2xx so the caller can surface the server `error` (e.g. "Payment not
  /// confirmed yet." → retry).
  Future<Map<String, dynamic>> storageAction(Map<String, dynamic> body) async {
    final action = (body['action'] ?? 'other').toString();
    // WS-first (PWA `_storageApiRequest`): ride the socket when authed OR public.
    // A non-null result here is already a 2xx with no `error` — [_trySocket]
    // converts an error frame into a null so we fall through to HTTP below.
    final ws = await _trySocket(action, body, stream: false);
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
    final action = (body['action'] ?? 'other').toString();
    // WS-first (PWA `_storageApiStream`): streaming actions collect ITEM frames
    // over the socket (`{stream:true}` → `_wsItems`) before the HTTP fallback.
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
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final decoded = _decodeJson(res);
      throw ApiException(
        (body['action'] ?? 'storage').toString(),
        res.statusCode,
        decoded['error']?.toString() ?? _utf8Body(res),
      );
    }
    final items = <dynamic>[];
    for (final line in const LineSplitter().convert(_utf8Body(res))) {
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

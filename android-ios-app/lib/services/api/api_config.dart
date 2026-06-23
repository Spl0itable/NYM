/// Centralized backend API host + headers for the native app.
///
/// The PWA derives its API host from `window.location.host` (`_getApiHost`),
/// which only resolves when served over http(s). A native Flutter app has no
/// page origin, so per spec §4.2 (Flutter note) it targets a FIXED host and
/// always sends a `User-Agent` that satisfies the backend `isNymchatClient`
/// gate (`_shared.js`: `/NymchatApp\//i` OR `/\bNYMApp\b/`).
class ApiConfig {
  ApiConfig._();

  /// Fixed API host the native app targets (spec §4.2 Flutter note).
  ///
  /// Mirrors the PWA's `_getApiHost()` result, but hardcoded because there is
  /// no `window.location.host` natively.
  ///
  /// Confirmed against the PWA's own canonical-host assertion: `build-verify.js`
  /// declares `OFFICIAL_HOSTS = ['web.nymchat.app']` (the host the served build
  /// attestation is anchored to), and `bot.js` documents the PWA at
  /// `web.nymchat.app`. This is the host the relay-pool / proxy / storage / bot
  /// workers are deployed under.
  static const String apiHost = 'web.nymchat.app';

  /// App version, used in the User-Agent. Keep in sync with pubspec `version`.
  static const String appVersion = '1.0.1';

  /// User-Agent that passes the backend `isNymchatClient` UA gate.
  ///
  /// `_shared.js:isNymchatClient` matches `/NymchatApp\//i`. We send
  /// `NymchatApp/<ver>`.
  static const String userAgent = 'NymchatApp/$appVersion';

  /// `wss://<host>/api/relay-pool` — the multiplexed relay-pool socket
  /// (`_getRelayPoolUrl`, spec §4.2).
  static String relayPoolUrl() => 'wss://$apiHost/api/relay-pool';

  /// `wss://<host>/api/relay?relay=<encoded wss url>` — single-relay privacy
  /// proxy (`_getProxiedRelayUrl`, spec §4.2). Provided for completeness.
  static String singleRelayUrl(String relayUrl) =>
      'wss://$apiHost/api/relay?relay=${Uri.encodeComponent(relayUrl)}';

  /// `https://<host>/api/proxy` — HTTP proxy base used by the API client
  /// (`_getProxyBaseUrl`, spec §4.2 / §6).
  static String proxyBaseUrl() => 'https://$apiHost/api/proxy';

  /// Default headers sent on every backend API request. The UA header is what
  /// satisfies the `isNymchatClient` gate.
  static Map<String, String> get defaultHeaders => {
        'User-Agent': userAgent,
      };
}

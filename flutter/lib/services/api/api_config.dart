import 'dart:io';

/// Fixed backend host and a User-Agent that passes the backend `isNymchatClient` gate.
class ApiConfig {
  ApiConfig._();

  /// Fixed API host, since a native app has no page origin.
  static const String apiHost = 'web.nymchat.app';

  /// Keep in sync with pubspec `version`.
  static const String appVersion = '3.75.545';

  /// Matches the backend's `/Nym(?:chat|bot)App\//i` client gate.
  static const String appUserAgent = 'NymchatApp/$appVersion';

  static final String dartUserAgent = HttpOverrides.runWithHttpOverrides(
        () => HttpClient().userAgent,
        _PlainHttpOverrides(),
      ) ??
      'Dart (dart:io)';

  static final String userAgent = '$dartUserAgent, $appUserAgent';

  static HttpClient socketClient() => HttpClient()..userAgent = null;

  static bool isOwnHost(String host) {
    final h = host.toLowerCase();
    return h == 'nymchat.app' || h.endsWith('.nymchat.app');
  }

  static String userAgentFor(Uri url) =>
      isOwnHost(url.host) ? userAgent : dartUserAgent;

  static Map<String, String> socketHeadersFor(Uri url) =>
      {'User-Agent': userAgentFor(url)};

  /// Multiplexed relay-pool socket.
  static String relayPoolUrl() => 'wss://$apiHost/api/relay-pool';

  /// Single-relay privacy proxy.
  static String singleRelayUrl(String relayUrl) =>
      'wss://$apiHost/api/relay?relay=${Uri.encodeComponent(relayUrl)}';

  /// HTTP proxy base used by the API client.
  static String proxyBaseUrl() => 'https://$apiHost/api/proxy';

  static bool directMedia = false;

  /// The UA header is what satisfies the `isNymchatClient` gate.
  static Map<String, String> get defaultHeaders => {'User-Agent': userAgent};
}

class _PlainHttpOverrides extends HttpOverrides {}

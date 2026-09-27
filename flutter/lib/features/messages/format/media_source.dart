import '../../../services/api/proxy_reachability.dart';
import 'message_content.dart' show proxiedMedia;

typedef MediaSourceOpener = Future<bool> Function(String url);

typedef MediaProxyProbe = Future<bool> Function(String proxiedUrl);

Future<String?> openMediaSource(
  List<String> urls,
  MediaSourceOpener open, {
  MediaProxyProbe probe = mediaProxyUnreachable,
}) async {
  bool? unreachable;
  for (final url in urls) {
    final proxied = proxiedMedia(url);
    if (await open(proxied)) return proxied;
    if (proxied == url) continue;
    unreachable ??= await probe(proxied);
    if (unreachable && await open(url)) return url;
  }
  return null;
}

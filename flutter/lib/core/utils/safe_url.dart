// Scheme guard for URLs that arrive from other people — message text, unfurled
// page metadata, profile fields. Only these are ever handed to the platform.
//
// url_launcher forwards an arbitrary scheme to the OS, where `intent:` can
// reach another app's exported components and `file:`/`content:` can read local
// paths. Nothing carried by a message needs that reach.

import 'package:url_launcher/url_launcher.dart';

const Set<String> _allowedSchemes = {'http', 'https', 'mailto', 'tel'};

/// Characters a URL parser skips, so they must not hide inside a scheme.
final RegExp _stripRe = RegExp(
    '[\\u0000-\\u0020\\u00a0\\u1680\\u2000-\\u200d'
    '\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]');

/// Parses [url] and returns it only when the scheme is one a message may use.
Uri? safeExternalUri(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url.replaceAll(_stripRe, ''));
  if (uri == null || !uri.hasScheme) return null;
  if (!_allowedSchemes.contains(uri.scheme.toLowerCase())) return null;
  return Uri.tryParse(url) ?? uri;
}

/// Opens [url] externally when its scheme is allowed. Returns false otherwise.
Future<bool> launchSafeUrl(String? url,
    {LaunchMode mode = LaunchMode.externalApplication}) async {
  final uri = safeExternalUri(url);
  if (uri == null) return false;
  try {
    return await launchUrl(uri, mode: mode);
  } catch (_) {
    return false;
  }
}

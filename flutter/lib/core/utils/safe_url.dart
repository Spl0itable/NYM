// Scheme guard for untrusted URLs: the OS would let `intent:`, `file:` or `content:` reach other apps or local files.

import 'package:url_launcher/url_launcher.dart';

const Set<String> _allowedSchemes = {'http', 'https', 'mailto', 'tel'};

/// Characters a URL parser skips, so they must not hide inside a scheme.
final RegExp _stripRe = RegExp(
    '[\\u0000-\\u0020\\u00a0\\u1680\\u2000-\\u200d'
    '\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]');

/// Returns [url] parsed only when its scheme is one a message may use.
Uri? safeExternalUri(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url.replaceAll(_stripRe, ''));
  if (uri == null || !uri.hasScheme) return null;
  if (!_allowedSchemes.contains(uri.scheme.toLowerCase())) return null;
  return Uri.tryParse(url) ?? uri;
}

/// Opens [url] externally when its scheme is allowed; returns false otherwise.
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

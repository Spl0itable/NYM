// NIP-92 `imeta` media-fallback registry — a 1:1 port of the PWA's
// `mediaFallbacks` map on the Users module (js/modules/users.js):
//   * `imetaTagsForContent` (users.js:591-609) — builds the outbound
//     `['imeta', 'url <primary>', 'fallback <mirror>', …]` tags for every media
//     URL in a message body that has recorded Blossom mirrors. Attached to
//     every channel (nostr-core.js:2432-2435, 2563-2566), PM (pms.js:314) and
//     group (groups.js:1701-1703) message.
//   * `ingestImetaTags` (users.js:611-631) — registers the mirror URLs carried
//     on inbound events/rumors/archived events (nostr-core.js:484-486,
//     pms.js:901-903, groups.js:679-681, channels.js:1148).
//   * upload-side recording (users.js:1031-1043) — the predicted mirror URLs
//     are stored as soon as the primary upload lands, then replaced/merged
//     with the confirmed mirror URLs when `_mirrorBlobBackground` settles.
//
// Render-time consumers (`_MediaTile` / `VideoMessage`) read [fallbacksFor]
// and retry each mirror when the primary fails — the PWA's
// `data-media-fallbacks` + `_attachMediaFallbacks` (message-format.js:146-151,
// messages.js:1154-1187).

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The media-URL matcher the PWA scans message content with
/// (users.js:594): http(s) URLs ending in an image/video extension, with an
/// optional query string.
final RegExp _rxImetaMediaUrl = RegExp(
  r'(https?://[^\s]+\.(?:jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(?:\?[^\s]*)?)',
  caseSensitive: false,
);

/// Primary media URL → Blossom mirror URLs (the PWA's `this.mediaFallbacks`
/// Map). Keys are the RAW (unproxied) URLs as they appear in message content;
/// consumers proxy at render time, exactly like `buildFallbackAttr` proxies
/// each mirror (message-format.js:147-149).
class MediaFallbacksRegistry {
  final Map<String, List<String>> _mirrorsByUrl = {};

  /// The recorded mirror URLs for [url] (empty when none). Returned list is a
  /// copy — safe to transform at the call site.
  List<String> fallbacksFor(String url) =>
      List.unmodifiable(_mirrorsByUrl[url] ?? const <String>[]);

  /// `imetaTagsForContent` (users.js:591-609): one
  /// `['imeta', 'url <primary>', 'fallback <mirror>', …]` tag per distinct
  /// media URL in [content] that has recorded mirrors.
  List<List<String>> imetaTagsForContent(String content) {
    if (_mirrorsByUrl.isEmpty || content.isEmpty) return const [];
    final tags = <List<String>>[];
    final seen = <String>{};
    for (final m in _rxImetaMediaUrl.allMatches(content)) {
      final url = m[1]!;
      if (!seen.add(url)) continue;
      final mirrors = _mirrorsByUrl[url];
      if (mirrors == null || mirrors.isEmpty) continue;
      tags.add(['imeta', 'url $url', for (final mu in mirrors) 'fallback $mu']);
    }
    return tags;
  }

  /// `ingestImetaTags` (users.js:611-631): registers the `url `/`fallback `
  /// parts of every `imeta` tag in [tags], merging (deduplicated, existing
  /// first) into any mirrors already recorded for the primary URL.
  void ingestImetaTags(List<List<String>> tags) {
    if (tags.isEmpty) return;
    for (final tag in tags) {
      if (tag.isEmpty || tag[0] != 'imeta') continue;
      String? primary;
      final fallbacks = <String>[];
      for (var i = 1; i < tag.length; i++) {
        final part = tag[i];
        if (part.startsWith('url ')) {
          primary = part.substring(4).trim();
        } else if (part.startsWith('fallback ')) {
          fallbacks.add(part.substring(9).trim());
        }
      }
      if (primary != null && fallbacks.isNotEmpty) {
        final existing = _mirrorsByUrl[primary] ?? const <String>[];
        _mirrorsByUrl[primary] =
            {...existing, ...fallbacks}.toList(growable: false);
      }
    }
  }

  /// Upload-side: store the PREDICTED mirror URLs the moment the primary
  /// upload lands (`this.mediaFallbacks.set(u.url, predicted)`,
  /// users.js:1031-1034) — overwrites any previous entry for [url].
  void recordPredictedMirrors(String url, List<String> predicted) {
    if (predicted.isEmpty) return;
    _mirrorsByUrl[url] = List.of(predicted, growable: false);
  }

  /// Upload-side: merge the CONFIRMED mirror URLs when the background
  /// `_mirrorBlobBackground` settles — confirmed mirrors FIRST, then whatever
  /// was already recorded, deduplicated (`set(u.url, unique([...mirrors,
  /// ...existing]))`, users.js:1036-1043).
  void recordConfirmedMirrors(String url, List<String> mirrors) {
    if (mirrors.isEmpty) return;
    final existing = _mirrorsByUrl[url] ?? const <String>[];
    _mirrorsByUrl[url] = {...mirrors, ...existing}.toList(growable: false);
  }
}

/// App-wide registry instance. A plain [Provider]: the map mutates in place
/// (like the PWA's module-level Map) and is READ at message render time — the
/// PWA likewise bakes `data-media-fallbacks` in at format time from whatever
/// has been ingested so far, with no reactive re-render on later ingests.
final mediaFallbacksProvider =
    Provider<MediaFallbacksRegistry>((ref) => MediaFallbacksRegistry());

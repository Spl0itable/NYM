// NIP-92 `imeta` media-fallback registry: builds outbound mirror tags, ingests inbound ones, records upload mirrors.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// http(s) URLs ending in an image/video extension, with an optional query string.
final RegExp _rxImetaMediaUrl = RegExp(
  r'(https?://[^\s]+\.(?:jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(?:\?[^\s]*)?)',
  caseSensitive: false,
);

/// Primary media URL -> Blossom mirror URLs; keys are raw URLs, proxied at render time.
class MediaFallbacksRegistry {
  final Map<String, List<String>> _mirrorsByUrl = {};

  /// Recorded mirror URLs for [url] (a copy; empty when none).
  List<String> fallbacksFor(String url) =>
      List.unmodifiable(_mirrorsByUrl[url] ?? const <String>[]);

  /// One `['imeta', 'url …', 'fallback …', …]` tag per media URL in [content] with recorded mirrors.
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

  /// Registers every `imeta` tag's url/fallback parts, merged after existing mirrors and deduplicated.
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

  /// Stores predicted mirror URLs when the primary upload lands, overwriting any previous entry.
  void recordPredictedMirrors(String url, List<String> predicted) {
    if (predicted.isEmpty) return;
    _mirrorsByUrl[url] = List.of(predicted, growable: false);
  }

  /// Merges confirmed mirrors first, then existing ones, deduplicated.
  void recordConfirmedMirrors(String url, List<String> mirrors) {
    if (mirrors.isEmpty) return;
    final existing = _mirrorsByUrl[url] ?? const <String>[];
    _mirrorsByUrl[url] = {...mirrors, ...existing}.toList(growable: false);
  }
}

/// A plain [Provider]: the map mutates in place and is read at render time with no reactive re-render.
final mediaFallbacksProvider =
    Provider<MediaFallbacksRegistry>((ref) => MediaFallbacksRegistry());

// NIP-92 `imeta` media-fallback registry: builds outbound mirror tags, ingests inbound ones, records upload mirrors.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/api/api_client.dart' show ApiException;
import '../i18n/i18n.dart';
import '../media_notes/media_notes.dart' show blossomFailureText, blossomRejectsType;

/// http(s) URLs ending in an image/video extension, with an optional query string.
final RegExp _rxImetaMediaUrl = RegExp(
  r'(https?://[^\s]+\.(?:jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov|m4a|mp3|aac|opus|wav|oga|flac)(?:\?[^\s]*)?)',
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
          primary = part.substring(4).trim().split('#nym:').first;
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

String predictMirrorUrl(String server, String hashHex, String primaryUrl) {
  final base = server.replaceAll(RegExp(r'/$'), '');
  final m = RegExp(r'\.([a-z0-9]{2,5})(?:\?|$)', caseSensitive: false)
      .firstMatch(primaryUrl);
  final ext = m == null ? '' : '.${m[1]!.toLowerCase()}';
  return '$base/$hashHex$ext';
}

String blossomContentType(String? type) {
  final t = (type ?? '').split(';').first.trim().toLowerCase();
  return t.isEmpty ? 'application/octet-stream' : t;
}

const Duration kUploadHostTimeout = Duration(seconds: 45);
const int kUploadMinBytesPerMs = 50;

Duration uploadHostTimeout(int size) {
  final bySize = Duration(milliseconds: (size / kUploadMinBytesPerMs).ceil());
  return bySize > kUploadHostTimeout ? bySize : kUploadHostTimeout;
}

class BlossomUploader {
  BlossomUploader({this.hostTimeout});

  final Duration? hostTimeout;
  final Set<String> _rejects = {};
  String lastFailure = '';

  Future<({String url, String server})?> upload(
    List<String> servers,
    String contentType,
    Future<String?> Function(String server, String contentType) put, {
    int size = 0,
  }) async {
    final type = blossomContentType(contentType);
    final open = servers.where((s) => !_rejects.contains('$s $type')).toList();
    final failures = <String>[];
    final limit = hostTimeout ?? uploadHostTimeout(size);
    for (final server in open.isEmpty ? servers : open) {
      final host = server.replaceFirst(RegExp(r'^https?://'), '');
      try {
        final url = await put(server, type).timeout(limit);
        if (url != null && url.isNotEmpty) {
          lastFailure = '';
          return (url: url, server: server);
        }
        failures.add('$host ($type): no URL in response');
      } on TimeoutException {
        final secs = (limit.inMilliseconds / 1000).round();
        debugPrint('[upload] $host timed out after $secs s');
        failures.add('$host ($type): ${tr('timed out after {s} s', {'s': '$secs'})}');
      } on ApiException catch (e) {
        final text = blossomFailureText(e.statusCode, '', e.body);
        if (blossomRejectsType(e.statusCode, text)) _rejects.add('$server $type');
        failures.add('$host ($type): $text');
      } catch (e) {
        failures.add('$host ($type): $e');
      }
    }
    lastFailure = failures.join('; ');
    return null;
  }
}

/// A plain [Provider]: the map mutates in place and is read at render time with no reactive re-render.
final mediaFallbacksProvider =
    Provider<MediaFallbacksRegistry>((ref) => MediaFallbacksRegistry());

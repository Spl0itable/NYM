// Local cache for the custom chat wallpaper.
//
// The custom wallpaper is stored in settings as a REMOTE url, because that is
// what has to travel to the user's other devices through the settings sync (and
// the web client stores the same value). But rendering it straight from that url
// means a request to a third-party Blossom host every time the image cache is
// cold — and Flutter's ImageCache is memory-only, so that is EVERY cold start.
//
// So the url stays the synced identity of the wallpaper, and the bytes live on
// disk next to it: written directly at upload time (no round trip at all on the
// device that chose it), or fetched once on a device that received the url from
// sync. After that the wallpaper paints from the local file, offline included.
// This mirrors the web client, which persists the blob into its `meta` store and
// renders from an object url (`_ensureWallpaperCached`, users.js).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class WallpaperCache {
  WallpaperCache._();

  static const String _dirName = 'wallpaper';

  /// In-flight/settled lookups keyed by url, so N widget rebuilds asking for the
  /// same wallpaper cause ONE fetch.
  static final Map<String, Future<File?>> _inflight = {};

  /// Memoised results, so the common case is a map hit rather than a stat call
  /// on every paint.
  static final Map<String, File> _resolved = {};

  static String _fileNameFor(String url) =>
      '${sha256.convert(utf8.encode(url)).toString().substring(0, 32)}.img';

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// The cached file for [url], or null when it has not been cached yet.
  /// Synchronous so `build` can use it without a FutureBuilder flash.
  static File? cached(String url) => _resolved[url];

  /// Writes [bytes] as the cached copy of [url]. Called at upload time so the
  /// device that picked the image never fetches it back.
  static Future<File?> store(String url, Uint8List bytes) async {
    if (url.isEmpty || bytes.isEmpty) return null;
    try {
      final file = File('${(await _dir()).path}/${_fileNameFor(url)}');
      await file.writeAsBytes(bytes, flush: true);
      _resolved[url] = file;
      _inflight[url] = Future.value(file);
      return file;
    } catch (_) {
      // Cache is an optimisation; failing to write just means we paint from the
      // network as before.
      return null;
    }
  }

  /// Resolves [url] to a local file, adopting an already-written one or
  /// fetching once. Concurrent callers share a single fetch.
  static Future<File?> resolve(
    String url, {
    Future<Uint8List?> Function(String url)? fetch,
  }) {
    if (url.isEmpty) return Future.value(null);
    final hit = _resolved[url];
    if (hit != null) return Future.value(hit);
    return _inflight.putIfAbsent(url, () => _resolveUncached(url, fetch));
  }

  static Future<File?> _resolveUncached(
    String url,
    Future<Uint8List?> Function(String url)? fetch,
  ) async {
    try {
      final file = File('${(await _dir()).path}/${_fileNameFor(url)}');
      if (await file.exists() && await file.length() > 0) {
        _resolved[url] = file;
        return file;
      }
      if (fetch == null) return null;
      final bytes = await fetch(url);
      if (bytes == null || bytes.isEmpty) {
        // Let a later attempt retry rather than caching the failure.
        _inflight.remove(url);
        return null;
      }
      await file.writeAsBytes(bytes, flush: true);
      _resolved[url] = file;
      return file;
    } catch (_) {
      _inflight.remove(url);
      return null;
    }
  }

  /// Deletes every cached wallpaper except [keepUrl] — called when the wallpaper
  /// changes so a replaced image does not linger on disk forever.
  static Future<void> pruneExcept(String? keepUrl) async {
    try {
      final keep = (keepUrl != null && keepUrl.isNotEmpty)
          ? _fileNameFor(keepUrl)
          : null;
      final dir = await _dir();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name == keep) continue;
        try {
          await entity.delete();
        } catch (_) {
          // Best-effort.
        }
      }
      _resolved.removeWhere((k, _) => k != keepUrl);
      _inflight.removeWhere((k, _) => k != keepUrl);
    } catch (_) {
      // Best-effort.
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _resolved.clear();
    _inflight.clear();
  }

  @visibleForTesting
  static String fileNameForTest(String url) => _fileNameFor(url);
}

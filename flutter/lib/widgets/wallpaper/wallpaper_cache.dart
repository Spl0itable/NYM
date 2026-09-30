// Disk cache for the custom wallpaper; the synced remote url stays its identity.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class WallpaperCache {
  WallpaperCache._();

  static const String _dirName = 'wallpaper';

  /// In-flight lookups keyed by url, so repeated rebuilds cause one fetch.
  static final Map<String, Future<File?>> _inflight = {};

  static final Map<String, File> _resolved = {};

  static String _fileNameFor(String url) =>
      '${sha256.convert(utf8.encode(url)).toString().substring(0, 32)}.img';

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Synchronous so `build` can use it without a FutureBuilder flash.
  static File? cached(String url) => _resolved[url];

  /// Called at upload time so the picking device never fetches the image back.
  static Future<File?> store(String url, Uint8List bytes) async {
    if (url.isEmpty || bytes.isEmpty) return null;
    try {
      final file = File('${(await _dir()).path}/${_fileNameFor(url)}');
      await file.writeAsBytes(bytes, flush: true);
      _resolved[url] = file;
      _inflight[url] = Future.value(file);
      return file;
    } catch (_) {
      // Caching is best-effort; on failure we paint from the network.
      return null;
    }
  }

  /// Concurrent callers share a single fetch.
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

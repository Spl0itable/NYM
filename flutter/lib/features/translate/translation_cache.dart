import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'translate_service.dart';

/// Manual translation results keyed by (text, target), outliving row State that list re-keying tears down.
class TranslationCache {
  /// Bounded so a long session doesn't grow this forever.
  static const int max = 500;

  final Map<String, Future<TranslationResult>> _entries = {};

  /// Settled results, so builders can be seeded synchronously instead of flashing a waiting frame.
  final Map<String, TranslationResult> _settled = {};

  static String keyFor(String text, String targetLang) => '$targetLang $text';

  /// True when [text] to [targetLang] is already translated or in flight.
  bool has(String text, String targetLang) =>
      _entries.containsKey(keyFor(text, targetLang));

  /// The finished translation, or null if never asked, in flight, or failed.
  TranslationResult? settled(String text, String targetLang) =>
      _settled[keyFor(text, targetLang)];

  /// Cached request, started via [start] on a miss; [onStarted] runs only for a real request.
  Future<TranslationResult> resolve(
    String text,
    String targetLang,
    Future<TranslationResult> Function() start, {
    void Function(Future<TranslationResult> future)? onStarted,
  }) {
    final key = keyFor(text, targetLang);
    final existing = _entries[key];
    if (existing != null) {
      // Re-insert so eviction stays least-recently-used.
      _entries.remove(key);
      _entries[key] = existing;
      return existing;
    }
    final future = start();
    _entries[key] = future;
    // Failures aren't cached so the next attempt re-requests; swallowed here to avoid a second unhandled error.
    future.then<void>((TranslationResult result) {
      if (identical(_entries[key], future)) _settled[key] = result;
    }, onError: (Object _) {
      if (identical(_entries[key], future)) _entries.remove(key);
    });
    while (_entries.length > max) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest);
      _settled.remove(oldest);
    }
    onStarted?.call(future);
    return future;
  }

  void clear() {
    _entries.clear();
    _settled.clear();
  }
}

/// A plain [Provider] because reading a cache must never schedule a rebuild.
final translationCacheProvider =
    Provider<TranslationCache>((ref) => TranslationCache());

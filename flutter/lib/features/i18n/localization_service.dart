import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../services/api/api_client.dart';
import '../../services/storage/key_value_store.dart';
import '../translate/translate_service.dart';

/// Runtime UI localization via the translate proxy; misses return English and repaint via [onChanged].
class LocalizationService {
  LocalizationService._();

  /// Plain singleton rather than a provider so [tr] can be a bare top-level function.
  static final LocalizationService instance = LocalizationService._();

  /// Per-language cache key prefix; the blob maps English source to translation.
  static const String _cachePrefix = 'nym_ui_i18n_';

  KeyValueStore? _kv;
  TranslateService? _translator;

  /// Active UI language code; empty or `en` shows the English source verbatim.
  String _lang = '';
  String get language => _lang;

  bool get isActive => _lang.isNotEmpty && _lang != 'en';

  /// English source -> translation for the loaded [_lang].
  final Map<String, String> _cache = {};

  /// Every source ever requested, so a language switch can re-translate what's on screen.
  final Set<String> _seen = {};

  /// High-priority lane: misses rendered on screen, not yet requested.
  final Set<String> _pending = {};

  /// Sources already requested this language session, never re-requested.
  final Set<String> _requested = {};

  /// Middle-priority lane: [prime]d strings not yet on screen (the tutorial).
  final Set<String> _primePending = {};

  /// Low-priority lane: the full-app catalog [sweep], drained last.
  final Set<String> _sweepPending = {};

  Timer? _debounce;
  bool _flushing = false;
  int _inFlight = 0;

  /// Sources that failed every attempt, parked for delayed retry rounds; cleared on a language switch.
  final Set<String> _failed = {};
  Timer? _retryTimer;
  int _retryRounds = 0;

  /// In-line attempts with backoff before a source is parked in [_failed].
  static const int _attemptsPerString = 3;

  /// Delayed retry rounds for parked failures (10s, 20s, 30s, 40s apart).
  static const int _maxRetryRounds = 4;

  /// Strings per chunk before persisting and repainting, so a sweep localizes progressively.
  static const int _chunkSize = 40;

  /// Fires after a batch is cached so the root widget can rebuild.
  VoidCallback? onChanged;

  /// Wires the store and translator and loads [language]'s cache; idempotent per language.
  void configure({
    required KeyValueStore kv,
    required String language,
    ApiClient? apiClient,
  }) {
    _kv = kv;
    // An explicit [apiClient] forces a fresh translator (tests); otherwise create one lazily.
    if (apiClient != null) {
      _translator = TranslateService(api: apiClient, gated: false);
    } else {
      _translator ??= TranslateService(api: ApiClient(), gated: false);
    }
    setLanguage(language);
  }

  /// Loads [code]'s cache and re-translates already-seen sources; `''`/`en` returns to English instantly.
  void setLanguage(String code) {
    final next = code.trim();
    if (next == _lang) return;
    _lang = next;
    _cache.clear();
    _requested.clear();
    _pending.clear();
    _primePending.clear();
    _sweepPending.clear();
    _failed.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryRounds = 0;
    if (!isActive) {
      // English: nothing to load or translate; just repaint.
      onChanged?.call();
      return;
    }
    _loadCache();
    // Load the bundled pack first; it usually answers the whole sweep.
    unawaited(_primeFromPack(next));
    // Re-translate anything already rendered so the switch is visible at once.
    for (final s in _seen) {
      if (!_cache.containsKey(s)) _pending.add(s);
    }
    _scheduleFlush();
    onChanged?.call();
  }

  /// Languages whose pack was already loaded this session.
  final Set<String> _packed = {};

  /// Test-only: the singleton would otherwise let one test's load suppress the next.
  @visibleForTesting
  void resetPackStateForTest() => _packed.clear();

  /// Reads one bundled pack; injectable so tests need no asset bundle.
  Future<String> Function(String assetKey) packLoader = rootBundle.loadString;

  /// Merges the bundled `assets/i18n/<lang>.json` pack (works offline); on-device entries win and gaps use the runtime queues.
  Future<void> _primeFromPack(String code) async {
    if (code.isEmpty || code == 'en' || !_packed.add(code)) return;
    try {
      final raw = await packLoader('assets/i18n/$code.json');
      // The language switched while the asset loaded.
      if (_lang != code) return;
      final map = jsonDecode(raw);
      if (map is! Map) return;
      var added = 0;
      map.forEach((k, v) {
        if (k is! String || v is! String || v.isEmpty) return;
        if (_cache.containsKey(k)) return;
        _cache[k] = v;
        // Nothing stays queued for a string the pack answered.
        _pending.remove(k);
        _primePending.remove(k);
        _sweepPending.remove(k);
        added++;
      });
      if (added == 0) return;
      _persist();
      onChanged?.call();
    } catch (_) {
      // Missing or malformed pack: the runtime queues handle it.
    }
  }

  final Map<String, String> _sources = {};

  String sourceOf(String text) => _sources[text] ?? text;

  /// Synchronous: returns the cached translation or the English [source] and queues a miss; `{name}` args apply afterwards.
  String translate(String source, [Map<String, Object?>? args]) {
    if (source.isEmpty) return source;
    _seen.add(source);
    if (!isActive) return _subst(source, args);
    final hit = _cache[source];
    if (hit != null) {
      final out = _subst(hit, args);
      if (out != source) {
        _sources.remove(out);
        _sources[out] = source;
        if (_sources.length > 200) _sources.remove(_sources.keys.first);
      }
      return out;
    }
    if (!_requested.contains(source) && !_failed.contains(source)) {
      // Rendered strings jump to the top lane; parked failures are skipped so they can't starve the sweep.
      _sweepPending.remove(source);
      _primePending.remove(source);
      _pending.add(source);
      _scheduleFlush();
    }
    // English fallback until the translation lands.
    return _subst(source, args);
  }

  /// Queues uncached [sources] in the middle lane before they render, for static overlays like the tutorial.
  void prime(Iterable<String> sources) {
    for (final s in sources) {
      if (s.isEmpty) continue;
      _seen.add(s);
      if (isActive &&
          !_cache.containsKey(s) &&
          !_requested.contains(s) &&
          !_pending.contains(s)) {
        // Middle lane: ahead of the sweep, behind on-screen strings.
        _sweepPending.remove(s);
        _primePending.add(s);
      }
    }
    if (_primePending.isNotEmpty) _scheduleFlush();
  }

  /// Low-priority, non-blocking, resumable background translation of the full catalog; no-op for English.
  void sweep(Iterable<String> catalog) {
    for (final s in catalog) {
      if (s.isEmpty) continue;
      _seen.add(s);
      if (isActive &&
          !_cache.containsKey(s) &&
          !_requested.contains(s) &&
          !_pending.contains(s) &&
          !_primePending.contains(s)) {
        _sweepPending.add(s);
      }
    }
    if (_sweepPending.isNotEmpty) _scheduleFlush();
  }

  /// Replaces `{key}` tokens from [args], leaving missing keys intact.
  static String _subst(String text, Map<String, Object?>? args) {
    if (args == null || args.isEmpty || !text.contains('{')) return text;
    return text.replaceAllMapped(_rxPlaceholder, (m) {
      final key = m.group(1)!;
      return args.containsKey(key) ? '${args[key]}' : m.group(0)!;
    });
  }

  static final RegExp _rxPlaceholder = RegExp(r'\{(\w+)\}');

  void _loadCache() {
    final kv = _kv;
    if (kv == null) return;
    final raw = kv.getString('$_cachePrefix$_lang');
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      map.forEach((k, v) {
        if (v is String) _cache[k] = v;
      });
    } catch (_) {
      // Corrupt blob: discard and rebuild on demand.
    }
  }

  void _persist() {
    final kv = _kv;
    if (kv == null || !isActive) return;
    try {
      kv.setString('$_cachePrefix$_lang', jsonEncode(_cache));
    } catch (_) {}
  }

  bool get _anyPending =>
      _pending.isNotEmpty ||
      _primePending.isNotEmpty ||
      _sweepPending.isNotEmpty;

  /// Drives the sidebar progress row; must not read [_flushing] or failed strings would re-queue in a loop.
  bool get isTranslating => isActive && (_anyPending || _inFlight > 0);

  void _scheduleFlush() {
    if (_flushing || !_anyPending) return;
    _debounce?.cancel();
    // Coalesce a screen's many `tr()` calls into one batch.
    _debounce = Timer(const Duration(milliseconds: 200), _flush);
  }

  Future<void> _flush() async {
    if (_flushing || !isActive) return;
    _flushing = true;
    final lang = _lang;
    try {
      // Drain in chunks by lane priority (on-screen, primed, sweep), persisting and repainting after each.
      while (_anyPending && lang == _lang) {
        final queue = _pending.isNotEmpty
            ? _pending
            : (_primePending.isNotEmpty ? _primePending : _sweepPending);
        final chunk = queue.take(_chunkSize).toList();
        queue.removeAll(chunk);
        chunk.forEach(_requested.add);
        _inFlight += chunk.length;
        try {
          await _mapPooled(chunk, 8, _translateOne);
        } finally {
          _inFlight -= chunk.length;
        }
        if (lang != _lang) return; // language switched mid-flight
        _persist();
        onChanged?.call();
      }
    } finally {
      _flushing = false;
    }
    if (lang != _lang) return;
    if (_anyPending) {
      _scheduleFlush();
    } else if (_failed.isNotEmpty) {
      // Everything reachable is cached; give parked failures a delayed retry.
      _scheduleFailedRetry();
    }
  }

  /// Translates one source with placeholders shielded, retrying with backoff; parks it in [_failed] if all attempts fail.
  Future<void> _translateOne(String source) async {
    final translator = _translator;
    if (translator == null) return;
    final lang = _lang;
    final shielded = _shieldPlaceholders(source);
    for (var attempt = 0; attempt < _attemptsPerString; attempt++) {
      if (lang != _lang) return; // language changed under us
      try {
        final res = await translator.translate(shielded.text, lang);
        if (lang != _lang) return;
        _cache[source] =
            _restorePlaceholders(res.translatedText, shielded.tokens);
        _failed.remove(source);
        return;
      } catch (_) {
        // Backoff 300ms, 600ms, …; the last attempt falls through to parking.
        if (attempt + 1 < _attemptsPerString) {
          await Future<void>.delayed(
              Duration(milliseconds: 300 * (1 << attempt)));
        }
      }
    }
    if (lang != _lang) return;
    _requested.remove(source);
    _failed.add(source);
  }

  /// Re-queues parked failures after increasing delays, up to [_maxRetryRounds]; reset on a language switch.
  void _scheduleFailedRetry() {
    if (_failed.isEmpty || _retryTimer != null) return;
    if (_retryRounds >= _maxRetryRounds) return;
    _retryRounds++;
    _retryTimer = Timer(Duration(seconds: 10 * _retryRounds), () {
      _retryTimer = null;
      if (!isActive) return;
      final retry = _failed.where((s) => !_cache.containsKey(s)).toList();
      _failed.clear();
      _pending.addAll(retry);
      _scheduleFlush();
    });
  }

  /// Runs [action] over [items] with at most [concurrency] in flight.
  static Future<void> _mapPooled<T>(
    List<T> items,
    int concurrency,
    Future<void> Function(T) action,
  ) async {
    var index = 0;
    Future<void> worker() async {
      while (index < items.length) {
        final i = index++;
        await action(items[i]);
      }
    }

    final workers = <Future<void>>[];
    for (var i = 0; i < concurrency && i < items.length; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);
  }

  /// Replaces `{name}` tokens with a sentinel (`__NYMPH0__`) that survives machine translation.
  static _Shield _shieldPlaceholders(String text) {
    if (!text.contains('{')) return _Shield(text, const []);
    final tokens = <String>[];
    final shielded = text.replaceAllMapped(_rxPlaceholder, (m) {
      final idx = tokens.length;
      tokens.add(m.group(0)!);
      return '__NYMPH${idx}__';
    });
    return _Shield(shielded, tokens);
  }

  static final RegExp _rxSentinel = RegExp(r'__NYMPH(\d+)__');

  static String _restorePlaceholders(String text, List<String> tokens) {
    if (tokens.isEmpty) return text;
    return text.replaceAllMapped(_rxSentinel, (m) {
      final idx = int.parse(m.group(1)!);
      return (idx >= 0 && idx < tokens.length) ? tokens[idx] : m.group(0)!;
    });
  }
}

class _Shield {
  const _Shield(this.text, this.tokens);
  final String text;
  final List<String> tokens;
}

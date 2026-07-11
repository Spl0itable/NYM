import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../models/settings.dart';
import 'translate_service.dart';

/// Lifecycle of a single message's auto-translation.
enum AutoTranslateStatus {
  /// Translation request is in flight; render the original meanwhile.
  loading,

  /// Translated text is ready and differs from the original — show it.
  ready,

  /// The message is already in the target language (or there was nothing to
  /// translate). Render the original with NO translation icon and, crucially,
  /// no "already in language" notice — auto-translate stays silent for these.
  noop,

  /// The request failed; fall back to the original silently.
  error,
}

/// One cached auto-translation, keyed by message id in [AutoTranslateNotifier].
class AutoTranslateEntry {
  const AutoTranslateEntry({
    required this.status,
    required this.source,
    required this.target,
    this.translated = '',
    this.detected = 'auto',
  });

  final AutoTranslateStatus status;

  /// The original message content this entry was computed from — lets the
  /// notifier invalidate when a message is edited.
  final String source;

  /// The target language this was translated into — lets the notifier
  /// invalidate when the user changes their translation language.
  final String target;

  /// The translated text (only meaningful when [status] is [ready]).
  final String translated;

  /// The upstream-detected source language (`auto` when unknown).
  final String detected;

  bool get isReady => status == AutoTranslateStatus.ready;
}

/// Automatically translates incoming messages in the active conversation into
/// the user's [Settings.translateLanguage], caching each result by message id
/// so a given message is only ever sent to the proxy once (scrolling back does
/// not re-request it).
///
/// Rows drive it lazily: a [MessageRow] that is eligible (auto-translate on,
/// the message's conversation type gated in, not the user's own message) calls
/// [ensure] as it builds, so only messages actually on screen in the viewed
/// conversation are translated — this is what keeps the proxy from being asked
/// to translate entire channel histories at once.
class AutoTranslateNotifier
    extends StateNotifier<Map<String, AutoTranslateEntry>> {
  AutoTranslateNotifier({TranslateService? service})
      : _service = service ?? TranslateService(),
        super(const {});

  final TranslateService _service;

  /// Keys (`id::target`) with a request in flight, so concurrent rebuilds of
  /// the same row don't fire duplicate proxy calls.
  final Set<String> _inflight = {};

  /// At most this many message translations run at once, so entering a channel
  /// (or a backfill) with many messages doesn't fire a burst of proxy calls.
  static const int _maxConcurrent = 5;
  int _active = 0;
  final List<_Job> _queue = [];

  /// The cached entry for [messageId], but only if it still matches the current
  /// [target] language and [source] content; otherwise null (stale → re-fetch).
  AutoTranslateEntry? entryFor(String messageId, String target, String source) {
    final e = state[messageId];
    if (e == null) return null;
    if (e.target != target || e.source != source) return null;
    return e;
  }

  /// Ensures [message] is (or is being) translated into [target]. A no-op when
  /// there's no target, nothing to translate, or a matching cache entry already
  /// exists. Safe to call every build.
  void ensure(Message message, String target) {
    if (target.isEmpty) return;
    final source = message.content;
    if (source.trim().isEmpty) return;
    final existing = state[message.id];
    if (existing != null &&
        existing.target == target &&
        existing.source == source) {
      return; // already cached (or loading) for this exact input
    }
    final key = '${message.id}::$target';
    if (_inflight.contains(key)) return;
    _inflight.add(key);
    state = {
      ...state,
      message.id: AutoTranslateEntry(
        status: AutoTranslateStatus.loading,
        source: source,
        target: target,
      ),
    };
    _queue.add(_Job(message.id, source, target, key));
    _pump();
  }

  /// Ensures auto-translation for the loaded messages of the conversation being
  /// viewed — called on channel/PM/group entry, on backfill/reload, and as new
  /// messages arrive — so visible messages localize without waiting for each row
  /// to scroll into view. Only eligible messages ([autoTranslateAppliesTo]) are
  /// queued, capped to the most recent [max] (the visible/backfilled window) to
  /// bound proxy load; already-cached messages are skipped.
  void ensureForView(
    List<Message> messages,
    String target,
    Settings settings, {
    int max = 60,
  }) {
    if (target.isEmpty || !settings.autoTranslate) return;
    final eligible = <Message>[
      for (final m in messages)
        if (autoTranslateAppliesTo(m, settings)) m,
    ];
    // messagesForCurrentViewProvider is oldest-first, so the tail is the most
    // recent (what the user sees at the bottom on entry).
    final start = eligible.length > max ? eligible.length - max : 0;
    for (var i = start; i < eligible.length; i++) {
      ensure(eligible[i], target);
    }
  }

  /// Starts queued jobs up to the [_maxConcurrent] limit.
  void _pump() {
    while (_active < _maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      _active++;
      _run(job.id, job.source, job.target, job.key).whenComplete(() {
        _active--;
        _pump();
      });
    }
  }

  /// In-line attempts (with backoff) before a message translation is marked
  /// failed. The message keeps rendering its original meanwhile.
  static const int _attempts = 3;

  Future<void> _run(
    String messageId,
    String source,
    String target,
    String key,
  ) async {
    // `_service.translate` preserves `@mention` tokens verbatim (it never sends
    // them upstream), so user nicknames are never translated — only the prose
    // between mentions is.
    try {
      for (var attempt = 0; attempt < _attempts; attempt++) {
        try {
          final res = await _translateQuoteAware(source, target);
          final translated = res.translatedText.trim();
          // "Already in the target language" — detected == target, or the
          // upstream returned the input unchanged. Treated as a silent no-op
          // (no icon, no error), so a same-language message just renders as-is.
          final noop = translated.isEmpty ||
              translated == source.trim() ||
              (res.detectedLanguage != 'auto' &&
                  res.detectedLanguage == target);
          _set(
            messageId,
            AutoTranslateEntry(
              status:
                  noop ? AutoTranslateStatus.noop : AutoTranslateStatus.ready,
              source: source,
              target: target,
              translated: res.translatedText,
              detected: res.detectedLanguage,
            ),
          );
          return;
        } catch (_) {
          if (attempt + 1 < _attempts) {
            await Future<void>.delayed(
                Duration(milliseconds: 400 * (1 << attempt)));
          }
        }
      }
      // Every attempt failed — fall back to the original silently.
      _set(
        messageId,
        AutoTranslateEntry(
          status: AutoTranslateStatus.error,
          source: source,
          target: target,
        ),
      );
    } finally {
      _inflight.remove(key);
    }
  }

  /// Translates [source] into [target] while keeping quoted lines (those the
  /// message parser treats as a blockquote — i.e. starting with `>` at column
  /// 0) **verbatim**, translating only the non-quote reply text.
  ///
  /// A quote reply's header line is `> @author: …`. Sending it through the proxy
  /// can drop/shift the leading `>` or reflow the line, after which the parser
  /// no longer sees a blockquote and renders `@author` as a bare @mention (the
  /// reported bug). Preserving quote lines byte-for-byte keeps the blockquote —
  /// and the author mention inside it — intact. Each contiguous run of reply
  /// lines is translated as one call (usually just one), so this stays cheap.
  Future<TranslationResult> _translateQuoteAware(
    String source,
    String target,
  ) async {
    final lines = source.split('\n');
    // Fast path: no quote lines → translate the whole thing in one call.
    if (!lines.any((l) => l.startsWith('>'))) {
      return _service.translate(source, target);
    }
    final out = <String>[];
    var detected = 'auto';
    var i = 0;
    while (i < lines.length) {
      if (lines[i].startsWith('>')) {
        out.add(lines[i]); // quote line: keep exactly as authored
        i++;
        continue;
      }
      final seg = <String>[];
      while (i < lines.length && !lines[i].startsWith('>')) {
        seg.add(lines[i]);
        i++;
      }
      final segText = seg.join('\n');
      if (segText.trim().isEmpty) {
        out.add(segText); // blank separators between quote and reply
      } else {
        final res = await _service.translate(segText, target);
        if (detected == 'auto' &&
            res.detectedLanguage.isNotEmpty &&
            res.detectedLanguage != 'auto') {
          detected = res.detectedLanguage;
        }
        out.add(res.translatedText);
      }
    }
    return TranslationResult(
      translatedText: out.join('\n'),
      detectedLanguage: detected,
    );
  }

  /// Commits an entry only if it still reflects the latest requested input —
  /// guards against a stale in-flight result clobbering a newer edit/target.
  void _set(String messageId, AutoTranslateEntry entry) {
    if (!mounted) return;
    final current = state[messageId];
    if (current != null &&
        current.status == AutoTranslateStatus.loading &&
        (current.source != entry.source || current.target != entry.target)) {
      return;
    }
    state = {...state, messageId: entry};
  }
}

/// A queued message-translation job (see [AutoTranslateNotifier._pump]).
class _Job {
  const _Job(this.id, this.source, this.target, this.key);
  final String id;
  final String source;
  final String target;
  final String key;
}

final autoTranslateProvider =
    StateNotifierProvider<AutoTranslateNotifier, Map<String, AutoTranslateEntry>>(
  (ref) => AutoTranslateNotifier(),
);

/// The language auto-translate should translate incoming messages INTO.
///
/// Prefers the explicit message-translation target ([Settings.translateLanguage],
/// shared with the manual "Translate" action); when that's unset it falls back
/// to the app's UI language ([Settings.uiLanguage]) so a user who chose an app
/// language but never set a separate translation language still gets messages
/// auto-translated into the language they're using the app in. Empty ⇒ no
/// target (English/unset) ⇒ auto-translate stays off.
String autoTranslateTargetFor(Settings settings) {
  if (settings.translateLanguage.isNotEmpty) return settings.translateLanguage;
  final ui = settings.uiLanguage;
  return (ui.isNotEmpty && ui != 'en') ? ui : '';
}

/// Whether auto-translate is enabled AND gated in for [message]'s conversation
/// type (public channel / PM / group), per [settings]. Own messages and
/// system/action rows are never auto-translated. Callers must still check that
/// a target language is set (see [autoTranslateTargetFor]).
bool autoTranslateAppliesTo(Message message, Settings settings) {
  if (message.isOwn) return false;
  if (message.isSystemRow) return false;
  // The Nymbot welcome always localizes to the user's chosen language — even
  // when the general auto-translate toggle is off — so a brand-new user is
  // greeted in the language they picked. (Callers still require a target
  // language via [autoTranslateTargetFor], so English users see the original.)
  if (message.id.startsWith(kNymbotWelcomeIdPrefix)) return true;
  if (!settings.autoTranslate) return false;
  if (message.isGroup) return settings.autoTranslateGroups;
  if (message.isPM) return settings.autoTranslatePMs;
  // Neither PM nor group ⇒ a public channel message.
  return settings.autoTranslateChannels;
}

/// Message-id prefix of Nymbot's welcome messages (the transient premium
/// welcome `nymbot-welcome` and the persisted first-contact PM
/// `nymbot-welcome-<ts>`), which always auto-translate to the chosen language.
const String kNymbotWelcomeIdPrefix = 'nymbot-welcome';

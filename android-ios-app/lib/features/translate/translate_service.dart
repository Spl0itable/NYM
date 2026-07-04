import '../../services/api/api_client.dart';

/// On-demand message translation routed through the backend `/api/proxy`
/// worker (`?action=translate`), exactly like the PWA (`translate.js`
/// `_doTranslate`, lines 332-359). The PWA ALWAYS proxies translation to hide
/// the user's IP from Google Translate, so we mirror that and drop the direct
/// `translate.googleapis.com` path. The proxy worker itself forwards to the
/// Google `gtx` endpoint server-side (`proxy.js` `handleTranslate`).
///
/// [translate] mirrors the PWA's `_translatePreservingMentions`
/// (`translate.js:292-328`) — the function BOTH the inline message-translate
/// (`translateMessage`) and the in-composer translate (`translateInputText`)
/// route through. It (1) shields emoji behind `EMJ<n>EMJ` placeholders so the
/// upstream can't drop/reorder them (`_shieldEmojis`, `translate.js:275-290`),
/// then (2) splits on `@mention` tokens and translates only the non-mention
/// chunks so handles survive verbatim, restoring per-chunk edge whitespace that
/// Google strips.
///
/// Lazy network: nothing runs until [translate] is awaited. The [ApiClient] is
/// injectable for tests (it accepts a mock `http.Client`).
class TranslateService {
  TranslateService({ApiClient? api}) : _api = api;
  final ApiClient? _api;

  /// One emoji "unit" (the PWA's `_shieldEmojis` regex, `translate.js:278`;
  /// identical to `_EMOJI_UNIT` ported at `message_content.dart:308-314`): a
  /// flag pair, a keycap, or a presentation/pictographic glyph with optional
  /// VS / skin-tone / ZWJ sequences and tags.
  static const String _emojiUnit =
      r'(?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]\u{FE0F}?\u{20E3})|'
      r'(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
      r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?'
      r'(?:\u{200D}(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
      r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?)*)'
      r'(?:[\u{E0020}-\u{E007E}]+\u{E007F})?';

  static final RegExp _rxEmoji = RegExp(_emojiUnit, unicode: true);

  /// `EMJ<n>EMJ` placeholder restore (`translate.js:288-290`).
  static final RegExp _rxEmojiPlaceholder = RegExp(r'EMJ(\d+)EMJ');

  /// `@nym` token (`translate.js:298` — `/(@[^\s@]+)/`).
  static final RegExp _rxMention = RegExp(r'@[^\s@]+');

  /// Per-chunk leading/trailing whitespace capture (`translate.js:305`).
  static final RegExp _rxEdgeWhitespace = RegExp(r'^(\s*)([\s\S]*?)(\s*)$');

  /// Translates [text] into [targetLang] (auto-detected source). Returns the
  /// translated text and the detected source language. Throws on failure.
  ///
  /// Mirrors `_translatePreservingMentions` (`translate.js:292-328`): emoji are
  /// shielded, `@mentions` are kept verbatim, only the in-between text chunks
  /// are sent upstream, edge whitespace is preserved, and the first non-`auto`
  /// detected language wins. When there is nothing translatable (the whole
  /// string is mentions/whitespace) the original [text] is returned with an
  /// `'auto'` detection, exactly like the PWA (`translate.js:309-311`).
  Future<TranslationResult> translate(String text, String targetLang) async {
    // 1. Shield emoji so the upstream can't strip/reorder them.
    final shield = _shieldEmojis(text);

    // 2. Split into interleaved non-mention / mention parts. JS `split` with a
    //    capturing group interleaves the delimiters; Dart's `String.split`
    //    drops them, so build the same even=text / odd=mention list by hand
    //    from the mention matches (`translate.js:298`).
    final parts = _splitOnMentions(shield.text);

    // 3. Collect the translatable (even-index, non-blank) chunks, capturing the
    //    leading/trailing whitespace Google would otherwise strip
    //    (`translate.js:302-307`).
    final translatable = <_Chunk>[];
    for (var i = 0; i < parts.length; i++) {
      if (i.isOdd) continue; // odd indices are @mentions — leave verbatim.
      final part = parts[i];
      if (part.trim().isEmpty) continue;
      final m = _rxEdgeWhitespace.firstMatch(part)!;
      translatable.add(_Chunk(
        index: i,
        lead: m.group(1) ?? '',
        content: m.group(2) ?? '',
        trail: m.group(3) ?? '',
      ));
    }

    // Nothing to translate (e.g. text was only mentions/whitespace): return the
    // ORIGINAL text untouched, like the PWA (`translate.js:309-311`).
    if (translatable.isEmpty) {
      return TranslationResult(translatedText: text, detectedLanguage: 'auto');
    }

    // 4. One ApiClient, reused across every chunk call, disposed once.
    final api = _api ?? ApiClient();
    try {
      final results = await Future.wait(
        translatable.map((c) => _translateChunk(api, c.content, targetLang)),
      );

      // 5. Reassemble, preserving each chunk's edge whitespace; merge the first
      //    non-auto detected language (`translate.js:317-324`).
      var detected = 'auto';
      for (var i = 0; i < translatable.length; i++) {
        final c = translatable[i];
        final res = results[i];
        parts[c.index] = c.lead + res.translatedText + c.trail;
        if (detected == 'auto' &&
            res.detectedLanguage.isNotEmpty &&
            res.detectedLanguage != 'auto') {
          detected = res.detectedLanguage;
        }
      }

      // 6. Re-join and restore the shielded emoji (`translate.js:326`).
      final joined = _restoreEmojis(parts.join(''), shield.emojis);
      return TranslationResult(
        translatedText: joined,
        detectedLanguage: detected,
      );
    } finally {
      if (_api == null) api.dispose();
    }
  }

  /// One upstream translation call for a single text [chunk]
  /// (the PWA's `_doTranslate`, `translate.js:332-359`). The proxy worker
  /// slices to 5000 chars server-side, but mirror the PWA's pre-slice so the
  /// request stays bounded (`translate.js:446`).
  Future<TranslationResult> _translateChunk(
    ApiClient api,
    String chunk,
    String targetLang,
  ) async {
    final body = chunk.length > 5000 ? chunk.substring(0, 5000) : chunk;
    try {
      final res = await api.translate(body, targetLang, source: 'auto');
      return TranslationResult(
        translatedText: res.translatedText,
        detectedLanguage:
            res.detectedLanguage.isEmpty ? 'auto' : res.detectedLanguage,
      );
    } on ApiException catch (e) {
      throw TranslateException('Translation failed: HTTP ${e.statusCode}');
    }
  }

  /// Replaces every emoji unit with an `EMJ<n>EMJ` placeholder so the upstream
  /// translator can't drop or reorder it (the PWA's `_shieldEmojis`,
  /// `translate.js:275-286`). Returns the placeholdered text plus the ordered
  /// list of removed emoji for [_restoreEmojis].
  static _ShieldResult _shieldEmojis(String text) {
    final emojis = <String>[];
    final shielded = text.replaceAllMapped(_rxEmoji, (m) {
      final idx = emojis.length;
      emojis.add(m.group(0)!);
      return 'EMJ${idx}EMJ';
    });
    return _ShieldResult(shielded, emojis);
  }

  /// Restores `EMJ<n>EMJ` placeholders to their original emoji
  /// (the PWA's `_restoreEmojis`, `translate.js:288-290`). An out-of-range
  /// index restores to empty, matching the PWA's `|| ''`.
  static String _restoreEmojis(String text, List<String> emojis) {
    return text.replaceAllMapped(_rxEmojiPlaceholder, (m) {
      final idx = int.parse(m.group(1)!);
      return (idx >= 0 && idx < emojis.length) ? emojis[idx] : '';
    });
  }

  /// Builds the same interleaved `parts` list JS produces from
  /// `text.split(/(@[^\s@]+)/)`: even indices are non-mention text (possibly
  /// empty), odd indices are the `@mention` tokens, in source order. Dart's
  /// `String.split` discards capture-group delimiters, so reconstruct it from
  /// the mention matches.
  static List<String> _splitOnMentions(String text) {
    final parts = <String>[];
    var last = 0;
    for (final m in _rxMention.allMatches(text)) {
      parts.add(text.substring(last, m.start)); // leading text (may be empty)
      parts.add(m.group(0)!); // the @mention
      last = m.end;
    }
    parts.add(text.substring(last)); // trailing text (may be empty)
    return parts;
  }

  /// Strips quoted lines (`> …` prefixed) so only the user's own reply text is
  /// translated (translate.js `translateMessage`, lines 207-219).
  static String stripQuotes(String content) {
    final lines = content
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('>'))
        .join('\n')
        .trim();
    // Strip a trailing timestamp like "12:34 PM" / "23:59".
    return lines
        .replaceAll(RegExp(r'\s*\d{1,2}:\d{2}\s*(AM|PM)?\s*$', caseSensitive: false), '')
        .trim();
  }
}

/// A single translatable text chunk plus the edge whitespace to restore after
/// translation (the PWA's `{ index, lead, content, trail }`, `translate.js:306`).
class _Chunk {
  const _Chunk({
    required this.index,
    required this.lead,
    required this.content,
    required this.trail,
  });
  final int index;
  final String lead;
  final String content;
  final String trail;
}

/// Result of [TranslateService._shieldEmojis]: the placeholdered text plus the
/// ordered emoji to restore.
class _ShieldResult {
  const _ShieldResult(this.text, this.emojis);
  final String text;
  final List<String> emojis;
}

class TranslationResult {
  const TranslationResult({
    required this.translatedText,
    required this.detectedLanguage,
  });
  final String translatedText;
  final String detectedLanguage;
}

class TranslateException implements Exception {
  const TranslateException(this.message);
  final String message;
  @override
  String toString() => message;
}

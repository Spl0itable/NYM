import 'dart:async';
import 'dart:convert';

import '../../services/api/api_client.dart';

/// Message translation via our own proxy only; emoji, mentions and URLs pass through untouched.
class TranslateService {
  TranslateService({ApiClient? api}) : _api = api;
  final ApiClient? _api;

  /// One emoji unit: flag pair, keycap, or pictographic glyph with optional VS, skin tone, ZWJ and tags.
  static const String _emojiUnit =
      r'(?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]\u{FE0F}?\u{20E3})|'
      r'(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
      r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?'
      r'(?:\u{200D}(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
      r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?)*)'
      r'(?:[\u{E0020}-\u{E007E}]+\u{E007F})?';

  static final RegExp _rxEmoji = RegExp(_emojiUnit, unicode: true);

  static final RegExp _rxEmojiPlaceholder = RegExp(r'EMJ(\d+)EMJ');

  /// Tokens passed through untranslated, code first, then URLs, @mentions and `:shortcode:` emoji.
  static final RegExp _rxPreserve =
      RegExp(r'`[^`\n]*`|https?://[^\s]+|@[^\s@]+|:[a-zA-Z0-9_+\-]+:');

  /// Per-chunk leading/trailing whitespace capture.
  static final RegExp _rxEdgeWhitespace = RegExp(r'^(\s*)([\s\S]*?)(\s*)$');

  /// Translates [text] with auto-detected source; returns [text] with `'auto'` when nothing is translatable; throws on failure.
  Future<TranslationResult> translate(String text, String targetLang) async {
    // Shield emoji so the upstream can't strip or reorder them.
    final shield = _shieldEmojis(text);

    // Dart's `split` drops delimiters, so build the even=text, odd=preserved list by hand.
    final parts = _splitOnPreserved(shield.text);

    // Capture edge whitespace the upstream would otherwise strip.
    final translatable = <_Chunk>[];
    for (var i = 0; i < parts.length; i++) {
      if (i.isOdd) continue;
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

    // Nothing to translate: return the original text untouched.
    if (translatable.isEmpty) {
      return TranslationResult(translatedText: text, detectedLanguage: 'auto');
    }

    final api = _api ?? ApiClient();
    try {
      final results = await Future.wait(
        translatable.map((c) => _translateChunk(api, c.content, targetLang)),
      );

      // Reassemble with edge whitespace; the first non-auto detected language wins.
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

      final joined = _restoreEmojis(parts.join(''), shield.emojis);
      return TranslationResult(
        translatedText: joined,
        detectedLanguage: detected,
      );
    } finally {
      if (_api == null) api.dispose();
    }
  }

  /// One proxy call per chunk, pre-sliced to keep the request bounded.
  Future<TranslationResult> _translateChunk(
    ApiClient api,
    String chunk,
    String targetLang,
  ) async {
    final body = chunk.length > 5000 ? chunk.substring(0, 5000) : chunk;
    final TranslateResult res;
    try {
      res = await api.translate(body, targetLang, source: 'auto');
    } on ApiException catch (e) {
      // Surface the backend's human-readable sentence rather than the raw exception.
      throw TranslateException(_backendMessage(e));
    }
    // An empty body with a success status would replace the message with nothing.
    if (res.translatedText.trim().isEmpty) {
      throw const TranslateException('Translation failed: empty result');
    }
    return TranslationResult(
      translatedText: res.translatedText,
      detectedLanguage:
          res.detectedLanguage.isEmpty ? 'auto' : res.detectedLanguage,
    );
  }

  /// Human-readable reason from a failed proxy call, or a plain fallback.
  static String _backendMessage(ApiException e) {
    try {
      final decoded = jsonDecode(e.body);
      if (decoded is Map && decoded['error'] is String) {
        final msg = (decoded['error'] as String).trim();
        if (msg.isNotEmpty) return msg;
      }
    } catch (_) {
      // Not JSON: fall through.
    }
    return 'Translation is unavailable right now';
  }

  /// Replaces each emoji with `EMJ<n>EMJ`, returning the text and the removed emoji in order.
  static _ShieldResult _shieldEmojis(String text) {
    final emojis = <String>[];
    final shielded = text.replaceAllMapped(_rxEmoji, (m) {
      final idx = emojis.length;
      emojis.add(m.group(0)!);
      return 'EMJ${idx}EMJ';
    });
    return _ShieldResult(shielded, emojis);
  }

  /// Out-of-range indices restore to empty.
  static String _restoreEmojis(String text, List<String> emojis) {
    return text.replaceAllMapped(_rxEmojiPlaceholder, (m) {
      final idx = int.parse(m.group(1)!);
      return (idx >= 0 && idx < emojis.length) ? emojis[idx] : '';
    });
  }

  /// Even indices are translatable text (maybe empty), odd are preserved tokens, in source order.
  static List<String> _splitOnPreserved(String text) {
    final parts = <String>[];
    var last = 0;
    for (final m in _rxPreserve.allMatches(text)) {
      parts.add(text.substring(last, m.start));
      parts.add(m.group(0)!);
      last = m.end;
    }
    parts.add(text.substring(last));
    return parts;
  }

  /// Strips `> ` quoted lines so only the user's own reply is translated.
  static String stripQuotes(String content) {
    final lines = content
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('>'))
        .join('\n')
        .trim();
    // Strip a trailing timestamp like "12:34 PM" or "23:59".
    return lines
        .replaceAll(
            RegExp(r'\s*\d{1,2}:\d{2}\s*(AM|PM)?\s*$', caseSensitive: false),
            '')
        .trim();
  }
}

/// A translatable chunk plus the edge whitespace to restore.
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

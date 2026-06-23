import '../../services/api/api_client.dart';

/// On-demand message translation routed through the backend `/api/proxy`
/// worker (`?action=translate`), exactly like the PWA (`translate.js`
/// `_doTranslate`, lines 332-359). The PWA ALWAYS proxies translation to hide
/// the user's IP from Google Translate, so we mirror that and drop the direct
/// `translate.googleapis.com` path. The proxy worker itself forwards to the
/// Google `gtx` endpoint server-side (`proxy.js` `handleTranslate`).
///
/// Lazy network: nothing runs until [translate] is awaited. The [ApiClient] is
/// injectable for tests (it accepts a mock `http.Client`).
class TranslateService {
  TranslateService({ApiClient? api}) : _api = api;
  final ApiClient? _api;

  /// Translates [text] into [targetLang] (auto-detected source). Returns the
  /// translated text and the detected source language. Throws on failure.
  Future<TranslationResult> translate(String text, String targetLang) async {
    // The proxy worker slices `text` to 5000 chars server-side, but mirror the
    // PWA's pre-slice so the request stays bounded (translate.js:446).
    final body = text.length > 5000 ? text.substring(0, 5000) : text;
    final api = _api ?? ApiClient();
    try {
      final res = await api.translate(body, targetLang, source: 'auto');
      return TranslationResult(
        translatedText: res.translatedText,
        detectedLanguage:
            res.detectedLanguage.isEmpty ? 'auto' : res.detectedLanguage,
      );
    } on ApiException catch (e) {
      throw TranslateException('Translation failed: HTTP ${e.statusCode}');
    } finally {
      if (_api == null) api.dispose();
    }
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

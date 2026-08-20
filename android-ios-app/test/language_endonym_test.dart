import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/i18n/language_select.dart';
import 'package:nym_bar/features/translate/translate_languages.dart';

void main() {
  group('language endonyms', () {
    test('a language is labelled the way its speakers write it', () {
      expect(languageNative('es'), 'español');
      expect(languageNative('ja'), '日本語');
      expect(languageNative('ar'), 'العربية');
      expect(languageNative('de'), 'Deutsch');
      expect(languageNative('ru'), 'русский');
    });

    test('a language whose endonym matches falls back to the English name', () {
      expect(languageNative('af'), 'Afrikaans');
      expect(languageSubtitle('af'), '',
          reason: 'no point repeating the same word twice');
    });

    test('the English name is kept, not replaced', () {
      expect(languageSubtitle('es'), 'Spanish');
      expect(languageSubtitle('ja'), 'Japanese');
    });

    test('alias codes resolve like their canonical form', () {
      expect(languageNative('iw'), languageNative('he'));
      expect(languageNative('jw'), languageNative('jv'));
      expect(languageNative('zh-cn'), languageNative('zh'));
    });

    test('lookup is case-insensitive and total', () {
      expect(languageNative('ES'), 'español');
      expect(languageNative(''), '');
      expect(languageNative(null), '');
      expect(languageNative('xx'), 'xx', reason: 'an unknown code returns itself');
    });

    test('search matches either spelling', () {
      final key = languageSearchKey('es', 'Spanish');
      expect(key, contains('spanish'));
      expect(key, contains('español'));
      expect(languageSearchKey('ja', 'Japanese'), contains('日本語'));
    });

    test('every offered language resolves to a non-empty label', () {
      for (final e in sortedTranslateLanguages()) {
        expect(languageNative(e.key), isNotEmpty, reason: 'no label for ${e.key}');
      }
    });

    test('most languages gained a real endonym', () {
      final distinct = sortedTranslateLanguages()
          .where((e) => languageSubtitle(e.key).isNotEmpty)
          .length;
      expect(distinct, greaterThan(100),
          reason: '$distinct of ${sortedTranslateLanguages().length}');
    });

    test('the settings row reads in the language it names', () {
      expect(uiLanguageName('es'), 'español — Spanish');
      expect(uiLanguageName('af'), 'Afrikaans');
      expect(uiLanguageName(''), 'English');
      expect(uiLanguageName('en'), 'English');
    });

    test('the picker still lists every language exactly once', () {
      final codes = kUiLanguageOptions.map((o) => o.code).toList();
      expect(codes.toSet().length, codes.length, reason: 'no duplicates');
      expect(codes.first, '', reason: 'English is pinned first');
    });
  });
}

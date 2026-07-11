import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/features/i18n/app_strings_catalog.dart';
import 'package:nym_bar/features/i18n/i18n.dart';
import 'package:nym_bar/features/i18n/language_select.dart';
import 'package:nym_bar/features/i18n/localization_service.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';

void main() {
  group('tr() in English (unconfigured) mode', () {
    test('returns the source string verbatim', () {
      expect(tr('Settings'), 'Settings');
      expect(tr('All set!'), 'All set!');
    });

    test('substitutes {placeholders} from args', () {
      expect(
        tr('Step {n} of {total}', {'n': 1, 'total': 12}),
        'Step 1 of 12',
      );
      expect(tr('{count} votes', {'count': 3}), '3 votes');
    });

    test('leaves unknown placeholders intact', () {
      expect(tr('Hi {name}', {'other': 'x'}), 'Hi {name}');
    });

    test('no-args templates are returned unchanged', () {
      expect(tr('Plain label'), 'Plain label');
      // A literal brace with no args is left as-is (no substitution attempted).
      expect(tr('Use {braces} literally'), 'Use {braces} literally');
    });

    test('String extension mirrors the function', () {
      expect('Language'.tr(), 'Language');
      expect('Hi {name}'.tr({'name': 'Ada'}), 'Hi Ada');
    });
  });

  group('LocalizationService', () {
    test('is inactive for empty / en language codes', () {
      final svc = LocalizationService.instance;
      svc.setLanguage('');
      expect(svc.isActive, isFalse);
      svc.setLanguage('en');
      expect(svc.isActive, isFalse);
    });
  });

  group('UI language options', () {
    test('English is pinned first and stored as an empty code', () {
      expect(kUiLanguageOptions.first.code, '');
      expect(kUiLanguageOptions.first.name, 'English');
    });

    test('includes many languages, none duplicating the English pin', () {
      expect(kUiLanguageOptions.length, greaterThan(100));
      expect(
        kUiLanguageOptions.where((o) => o.code == 'en'),
        isEmpty,
      );
    });

    test('uiLanguageName resolves codes and defaults to English', () {
      expect(uiLanguageName(''), 'English');
      expect(uiLanguageName('en'), 'English');
      expect(uiLanguageName('es'), 'Spanish');
      expect(uiLanguageName('fr'), 'French');
    });
  });

  group('app strings catalog (background sweep source)', () {
    test('is populated with the app\'s direct tr() literals', () {
      expect(kAppStringsCatalog.length, greaterThan(500));
      for (final s in const ['Settings', 'Language', 'Show original']) {
        expect(kAppStringsCatalog, contains(s), reason: s);
      }
    });

    test('has no duplicate or empty entries', () {
      expect(kAppStringsCatalog.toSet().length, kAppStringsCatalog.length);
      expect(kAppStringsCatalog.any((s) => s.trim().isEmpty), isFalse);
    });
  });

  group('LocalizationService sweep pipeline', () {
    test('queues, translates and caches a string via the proxy', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final svc = LocalizationService.instance;
      svc.setLanguage('en'); // reset any state left by earlier tests

      final mock = MockClient((req) async {
        final text = (jsonDecode(req.body)['text'] ?? '').toString();
        return http.Response(
          jsonEncode(
              {'translatedText': text.toUpperCase(), 'detectedLanguage': 'de'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      svc.configure(
        kv: kv,
        language: 'de',
        apiClient: ApiClient(client: mock, baseUrl: 'https://h/api/proxy'),
      );

      // Cache miss ⇒ English fallback now, translation queued.
      expect(svc.translate('Sweep me please'), 'Sweep me please');
      // Debounced flush (200ms) + mock round-trip.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(svc.translate('Sweep me please'), 'SWEEP ME PLEASE');

      svc.setLanguage('en'); // cleanup so the singleton doesn't leak state
    });

    test('drains lanes by priority: on-screen → primed → swept', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final svc = LocalizationService.instance;
      svc.setLanguage('en'); // reset

      final order = <String>[];
      final mock = MockClient((req) async {
        final text = (jsonDecode(req.body)['text'] ?? '').toString();
        order.add(text);
        return http.Response(
          jsonEncode(
              {'translatedText': text.toUpperCase(), 'detectedLanguage': 'de'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      svc.configure(
        kv: kv,
        language: 'de',
        apiClient: ApiClient(client: mock, baseUrl: 'https://h/api/proxy'),
      );

      // Feed the lanes in REVERSE priority to prove priority — not insertion
      // order — decides what translates first.
      svc.sweep(['ZZ sweep one', 'ZZ sweep two']); // low
      svc.prime(['YY primed tutorial']); // middle
      svc.translate('AA on screen now'); // high

      await Future<void>.delayed(const Duration(milliseconds: 700));

      final iScreen = order.indexOf('AA on screen now');
      final iPrimed = order.indexOf('YY primed tutorial');
      final iSweep = order.indexWhere((s) => s.startsWith('ZZ sweep'));
      expect(iScreen, isNonNegative);
      expect(iScreen < iPrimed, isTrue, reason: 'on-screen before primed');
      expect(iPrimed < iSweep, isTrue, reason: 'primed before swept');

      svc.setLanguage('en'); // cleanup
    });
  });
}

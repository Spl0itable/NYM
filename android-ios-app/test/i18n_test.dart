import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/features/i18n/app_strings_catalog.dart';
import 'package:nym_bar/features/i18n/i18n.dart';
import 'package:nym_bar/features/i18n/language_select.dart';
import 'package:nym_bar/features/i18n/localization_service.dart';
import 'package:nym_bar/features/settings/about_screen.dart';
import 'package:nym_bar/features/settings/settings_screen.dart';
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
      // The row leads with the endonym and keeps the English name after it.
      expect(uiLanguageName('es'), 'español — Spanish');
      expect(uiLanguageName('fr'), 'français — French');
    });
  });

  group('app strings catalog (background sweep source)', () {
    test('is populated with the app\'s direct tr() literals', () {
      expect(kAppStringsCatalog.length, greaterThan(500));
      for (final s in const ['Settings', 'Language', 'Show original']) {
        expect(kAppStringsCatalog, contains(s), reason: s);
      }
    });

    test('carries the post-quantum status copy', () {
      // The send-only line is the one that matters: it is the caveat telling a
      // signer-login user what is and is not protected, and a caveat only
      // English speakers can read is not a caveat.
      for (final s in kPqStatusStrings) {
        expect(kAppStringsCatalog, contains(s), reason: s);
      }
    });

    test('carries the build-integrity copy', () {
      // The panel says what the app can't establish about itself; a sentence
      // that isn't in the catalog stays English everywhere else, which would
      // leave that caveat readable only to English speakers.
      for (final s in kBuildIntegrityStrings) {
        expect(kAppStringsCatalog, contains(s), reason: s);
      }
    });

    test('has no duplicate or empty entries', () {
      expect(kAppStringsCatalog.toSet().length, kAppStringsCatalog.length);
      expect(kAppStringsCatalog.any((s) => s.trim().isEmpty), isFalse);
    });
  });

  group('isTranslating (sidebar progress row)', () {
    test('false in English, true while a sweep runs, false once it finishes',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final svc = LocalizationService.instance;
      svc.setLanguage('en');
      expect(svc.isTranslating, isFalse,
          reason: 'English translates nothing, so the row must stay hidden');

      var notifies = 0;
      svc.onChanged = () => notifies++;

      final mock = MockClient((req) async {
        final text = (jsonDecode(req.body)['text'] ?? '').toString();
        // Slow enough that the assertion below lands mid-flight.
        await Future<void>.delayed(const Duration(milliseconds: 40));
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

      svc.sweep(const ['Alpha', 'Beta', 'Gamma']);
      expect(svc.isTranslating, isTrue,
          reason: 'queued work should show immediately, before the flush runs');

      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(svc.isTranslating, isFalse,
          reason: 'the row must clear once the sweep drains');
      expect(notifies, greaterThan(0),
          reason: 'the last per-chunk notify is what repaints the row away');

      svc.onChanged = null;
      svc.setLanguage('en');
    });

    test('a notify that re-requests a failed string cannot starve the sweep',
        () async {
      // Regression: onChanged bumps i18nVersionProvider, which rebuilds the
      // tree, which calls tr() again. A failed string is un-marked from
      // _requested, so that rebuild re-queues it on the HIGH-priority lane. If
      // completion also notified, the sweep lane never got a turn: nothing
      // translated and the progress row stayed up for good.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final svc = LocalizationService.instance;
      svc.setLanguage('en');

      final mock = MockClient((req) async {
        final text = (jsonDecode(req.body)['text'] ?? '').toString();
        if (text == 'Flaky') return http.Response('nope', 500);
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

      // Stand in for the rebuild: every notify re-reads the failing string.
      svc.onChanged = () => svc.translate('Flaky');

      svc.translate('Flaky');
      svc.sweep(const ['Alpha', 'Beta', 'Gamma']);

      await Future<void>.delayed(const Duration(seconds: 4));

      expect(svc.translate('Alpha'), 'ALPHA',
          reason: 'the sweep lane must still drain behind the retried string');
      expect(svc.translate('Gamma'), 'GAMMA');
      expect(svc.isTranslating, isFalse,
          reason: 'the row must clear even though one string keeps failing');

      svc.onChanged = null;
      svc.setLanguage('en');
    });

    test('switching back to English clears it', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final svc = LocalizationService.instance;
      svc.setLanguage('en');
      final mock = MockClient((req) async => http.Response(
            jsonEncode({'translatedText': 'x', 'detectedLanguage': 'de'}),
            200,
            headers: {'content-type': 'application/json'},
          ));
      svc.configure(
        kv: kv,
        language: 'de',
        apiClient: ApiClient(client: mock, baseUrl: 'https://h/api/proxy'),
      );
      svc.sweep(const ['One', 'Two']);
      expect(svc.isTranslating, isTrue);
      svc.setLanguage('en');
      expect(svc.isTranslating, isFalse,
          reason: 'isActive gates it, so English hides the row at once');
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

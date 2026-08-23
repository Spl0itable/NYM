// How on-demand translation reaches the backend, and what happens when it
// cannot.
//
// This file used to pin a direct-to-Google fallback. That existed because the
// proxy's own upstream WAS Google, which rate-limits by caller IP: a Worker
// egresses from an address shared with every other Worker in its colo, so a
// busy colo returned 502 to everyone behind it while the same request from a
// phone succeeded. The proxy no longer calls out to anyone, so reaching around
// it would have exactly one remaining effect — handing a third party the
// plaintext of a message the user chose to keep private.
//
// So these pin the opposite property: that there is no second path, and that a
// failure is reported rather than routed around or papered over with something
// that merely looks like a translation.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/features/translate/translate_service.dart';
import 'package:nym_bar/services/api/api_client.dart';

/// An ApiClient whose proxy calls answer with [body] at [status].
ApiClient proxyReturning(Object body, {int status = 200, void Function(Map<String, dynamic>)? onCall}) =>
    ApiClient(
      client: MockClient((req) async {
        if (onCall != null) {
          onCall(jsonDecode(req.body) as Map<String, dynamic>);
        }
        return http.Response(
          body is String ? body : jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

void main() {
  group('the happy path', () {
    test('a translation comes back from the proxy', () async {
      final svc = TranslateService(
        api: proxyReturning({'translatedText': 'hola', 'detectedLanguage': 'en'}),
      );
      final r = await svc.translate('hello', 'es');
      expect(r.translatedText, 'hola');
      expect(r.detectedLanguage, 'en');
    });

    test('the request carries the target language and an auto source', () async {
      Map<String, dynamic>? sent;
      final svc = TranslateService(
        api: proxyReturning(
          {'translatedText': 'hola', 'detectedLanguage': 'en'},
          onCall: (b) => sent = b,
        ),
      );
      await svc.translate('hello', 'es');
      expect(sent!['target'], 'es');
      // A message from a stranger has no known source language, and saying so
      // is what routes it to a model that can detect one.
      expect(sent!['source'], 'auto');
    });

    test('long text is truncated before it is sent', () async {
      Map<String, dynamic>? sent;
      final svc = TranslateService(
        api: proxyReturning(
          {'translatedText': 'x', 'detectedLanguage': 'en'},
          onCall: (b) => sent = b,
        ),
      );
      await svc.translate('a' * 6000, 'es');
      expect((sent!['text'] as String).length, 5000);
    });

    test('mentions, emoji and links survive', () async {
      // Echo the input so the emoji placeholders round-trip; a constant would
      // destroy them and prove nothing about the shielding.
      final svc = TranslateService(
        api: ApiClient(
          client: MockClient((req) async {
            final sent = jsonDecode(req.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'translatedText': '[${sent['text']}]',
                'detectedLanguage': 'en',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );
      final r = await svc.translate('hi @bob 🎉 see https://x.test', 'es');
      expect(r.translatedText, contains('@bob'));
      expect(r.translatedText, contains('🎉'));
    });
  });

  group('failures are reported, not routed around', () {
    test('a 502 from the proxy is an error', () async {
      final svc = TranslateService(
        api: proxyReturning(
          {'error': 'Translation is unavailable for this language right now'},
          status: 502,
        ),
      );
      await expectLater(
          svc.translate('hello', 'es'), throwsA(isA<TranslateException>()));
    });

    test('an error body with a 200 is still an error', () async {
      final svc = TranslateService(
        api: proxyReturning({'error': 'nope'}),
      );
      await expectLater(
          svc.translate('hello', 'es'), throwsA(isA<TranslateException>()));
    });

    test('an EMPTY translation is a failure, not a translation', () async {
      // The one that would be silent: a success status with nothing in it
      // would replace the message with blank text on screen.
      final svc = TranslateService(
        api: proxyReturning({'translatedText': '   ', 'detectedLanguage': 'en'}),
      );
      await expectLater(
          svc.translate('hello', 'es'), throwsA(isA<TranslateException>()));
    });

    test('exactly one request is made — there is no second path', () async {
      var calls = 0;
      final api = ApiClient(
        client: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode({'error': 'down'}), 502,
              headers: {'content-type': 'application/json'});
        }),
      );
      final svc = TranslateService(api: api);
      await expectLater(
          svc.translate('hello', 'es'), throwsA(isA<TranslateException>()));
      expect(calls, 1);
    });
  });
}

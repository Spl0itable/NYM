import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/services/api/api_client.dart';

http.Response _og(String title) => http.Response(
      jsonEncode({
        'url': 'https://example.com/post',
        'title': title,
        'description': 'd',
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('unfurl cache', () {
    test('a second call for the same URL does not hit the network', () async {
      var calls = 0;
      final api = ApiClient(
        client: MockClient((_) async {
          calls++;
          return _og('first');
        }),
        baseUrl: 'https://h/api/proxy',
      );
      const url = 'https://example.com/cache-hit';
      expect((await api.unfurl(url)).title, 'first');
      expect((await api.unfurl(url)).title, 'first');
      expect(calls, 1, reason: 're-entering a channel must repaint from cache');
    });

    test('unfurlCached lets a card paint on its first frame', () async {
      final api = ApiClient(
        client: MockClient((_) async => _og('warm')),
        baseUrl: 'https://h/api/proxy',
      );
      const url = 'https://example.com/warm';
      expect(api.unfurlCached(url), isNull, reason: 'cold cache has nothing');
      await api.unfurl(url);
      expect(api.unfurlCached(url)?.title, 'warm');
    });

    test('concurrent callers share one request', () async {
      var calls = 0;
      final api = ApiClient(
        client: MockClient((_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _og('shared');
        }),
        baseUrl: 'https://h/api/proxy',
      );
      const url = 'https://example.com/concurrent';
      final results = await Future.wait([
        api.unfurl(url),
        api.unfurl(url),
        api.unfurl(url),
      ]);
      expect(calls, 1, reason: 'one card per message must not mean one request each');
      expect(results.every((r) => r.title == 'shared'), isTrue);
    });

    test('a failure is cached briefly instead of refetching every mount',
        () async {
      var calls = 0;
      final api = ApiClient(
        client: MockClient((_) async {
          calls++;
          return http.Response('nope', 502);
        }),
        baseUrl: 'https://h/api/proxy',
      );
      const url = 'https://example.com/broken';
      await expectLater(api.unfurl(url), throwsA(isA<ApiException>()));
      await expectLater(api.unfurl(url), throwsA(isA<ApiException>()));
      expect(calls, 1, reason: 'a dead link must not be retried on every render');
    });

    test('an in-flight entry is cleared, so a later call still resolves',
        () async {
      // Regression: removing the in-flight entry with an arrow body made
      // whenComplete await the very future it was completing.
      var calls = 0;
      final api = ApiClient(
        client: MockClient((_) async {
          calls++;
          return _og('n$calls');
        }),
        baseUrl: 'https://h/api/proxy',
      );
      await api.unfurl('https://example.com/a').timeout(const Duration(seconds: 2));
      await api.unfurl('https://example.com/b').timeout(const Duration(seconds: 2));
      expect(calls, 2);
    });
  });
}

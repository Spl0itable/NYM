import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/features/channels/geohash_place_cache.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _addr(Map<String, dynamic> address) => http.Response(
      jsonEncode({'address': address}),
      200,
      headers: {'content-type': 'application/json'},
    );

Future<KeyValueStore> _kv([Map<String, Object> seed = const {}]) async {
  SharedPreferences.setMockInitialValues(seed);
  return KeyValueStore(await SharedPreferences.getInstance());
}

void main() {
  group('GeohashPlaceCache', () {
    test('a named place is cached and persisted', () async {
      final kv = await _kv();
      var calls = 0;
      final cache = GeohashPlaceCache(
        kv: kv,
        api: ApiClient(
          client: MockClient((_) async {
            calls++;
            return _addr({'city': 'Paris', 'country': 'France'});
          }),
          baseUrl: 'https://h/api/proxy',
        ),
      );
      expect(await cache.resolve('u09t'), 'Paris, France');
      expect(await cache.resolve('u09t'), 'Paris, France');
      expect(calls, 1, reason: 'a resolved place must not be re-geocoded');
      expect(cache.cached('u09t'), 'Paris, France');
    });

    test('an empty geocode is a miss, never a cached place', () async {
      final kv = await _kv();
      final cache = GeohashPlaceCache(
        kv: kv,
        api: ApiClient(
          client: MockClient((_) async => _addr({})),
          baseUrl: 'https://h/api/proxy',
        ),
      );
      expect(await cache.resolve('9q8y'), '');
      expect(cache.cached('9q8y'), isNull,
          reason: 'caching "Unknown location" is what pinned a row to it');
      expect(cache.retryAt('9q8y'), isNotNull,
          reason: 'one empty answer must not be final');
    });

    test('a poisoned entry from an earlier build is dropped on load', () async {
      final kv = await _kv({
        kGeohashPlaceKey: jsonEncode({
          '9q8y': kGeohashPlacePoison,
          'u09t': 'Paris, France',
        }),
      });
      final cache = GeohashPlaceCache(
        kv: kv,
        api: ApiClient(
          client: MockClient((_) async => _addr({})),
          baseUrl: 'https://h/api/proxy',
        ),
      );
      expect(cache.cached('9q8y'), isNull, reason: 'the stuck row can resolve again');
      expect(cache.cached('u09t'), 'Paris, France', reason: 'real places survive');
    });

    test('a miss backs off, then is accepted as having no name', () async {
      final kv = await _kv();
      var calls = 0;
      final cache = GeohashPlaceCache(
        kv: kv,
        api: ApiClient(
          client: MockClient((_) async {
            calls++;
            return _addr({});
          }),
          baseUrl: 'https://h/api/proxy',
        ),
      );
      // Forced retries stand in for the passage of time.
      for (var i = 0; i < kGeohashPlaceMaxAttempts; i++) {
        await cache.resolve('7zzz', force: true);
      }
      // One ATTEMPT is a walk over the cell's probe points, and this mock
      // answers nothing anywhere, so every attempt exhausts the walk. What is
      // being asserted is the number of attempts, not of requests.
      expect(calls, kGeohashPlaceMaxAttempts * kGeohashPlaceProbes);
      expect(cache.retryAt('7zzz'), isNull,
          reason: 'a genuinely unnamed cell stops being retried');
      expect(cache.shouldRetry('7zzz'), isFalse);
      expect(cache.shouldRetry('7zzz', force: true), isTrue,
          reason: 'reopening the app still gets one more attempt');
    });

    test('an unexpired miss is not hammered', () async {
      final kv = await _kv();
      var calls = 0;
      final cache = GeohashPlaceCache(
        kv: kv,
        api: ApiClient(
          client: MockClient((_) async {
            calls++;
            return _addr({});
          }),
          baseUrl: 'https://h/api/proxy',
        ),
      );
      await cache.resolve('dr5r');
      await cache.resolve('dr5r');
      await cache.resolve('dr5r');
      // ONE attempt got made — the other two were held by the backoff. That
      // attempt walked the cell's probe points because nothing answered
      // anywhere in it.
      expect(calls, kGeohashPlaceProbes,
          reason: 'the backoff must hold between attempts');
    });

    test('a network failure is a retryable miss too', () async {
      final kv = await _kv();
      final cache = GeohashPlaceCache(
        kv: kv,
        api: ApiClient(
          client: MockClient((_) async => http.Response('boom', 500)),
          baseUrl: 'https://h/api/proxy',
        ),
      );
      expect(await cache.resolve('gcpv'), '');
      expect(cache.cached('gcpv'), isNull);
      expect(cache.retryAt('gcpv'), isNotNull);
    });

    test('a later success clears the miss', () async {
      final kv = await _kv();
      var calls = 0;
      final cache = GeohashPlaceCache(
        kv: kv,
        api: ApiClient(
          client: MockClient((_) async {
            calls++;
            // The whole FIRST attempt misses — every probe point in the cell —
            // and the retry then finds a name.
            return calls <= kGeohashPlaceProbes
                ? _addr({})
                : _addr({'city': 'Berlin', 'country': 'Germany'});
          }),
          baseUrl: 'https://h/api/proxy',
        ),
      );
      expect(await cache.resolve('u33d'), '');
      expect(await cache.resolve('u33d', force: true), 'Berlin, Germany');
      expect(cache.retryAt('u33d')?.millisecondsSinceEpoch, 0,
          reason: 'no miss is recorded once it resolves');
      expect(cache.cached('u33d'), 'Berlin, Germany');
    });
  });
}

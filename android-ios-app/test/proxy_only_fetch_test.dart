import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/features/mesh/mesh_controller.dart';
import 'package:nym_bar/features/messages/format/media_source.dart';
import 'package:nym_bar/features/messages/format/message_content.dart';
import 'package:nym_bar/features/settings/about_screen.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/api/api_config.dart';
import 'package:nym_bar/services/api/proxy_reachability.dart';

const _proxy = 'https://web.nymchat.app/api/proxy';
const _cors = {'access-control-allow-origin': '*'};

http.Response _worker(int status, {Object? body}) => http.Response(
      jsonEncode(body ?? {'error': 'x'}),
      status,
      headers: {..._cors, 'content-type': 'application/json'},
    );

http.Response _edge(int status) => http.Response(
      '<html>error</html>',
      status,
      headers: {'content-type': 'text/html'},
    );

void main() {
  group('proxyUnreachable', () {
    test('a connection that never reaches the worker counts', () {
      expect(proxyUnreachable(const SocketException('no route')), isTrue);
      expect(proxyUnreachable(const HandshakeException('bad cert')), isTrue);
      expect(proxyUnreachable(http.ClientException('closed')), isTrue);
      expect(proxyUnreachable(const HttpException('closed')), isTrue);
    });

    test('a slow answer or a local bug does not', () {
      expect(proxyUnreachable(TimeoutException('slow')), isFalse);
      expect(proxyUnreachable(const FormatException('bad')), isFalse);
      expect(proxyUnreachable(StateError('bug')), isFalse);
    });

    test('an edge failure page in place of the worker counts', () {
      for (final s in [502, 503, 520, 521, 522, 523, 524, 525, 526, 527]) {
        expect(proxyUnreachable(_edge(s)), isTrue, reason: '$s');
      }
    });

    test('an answer that is not from the worker at all counts', () {
      expect(
          proxyUnreachable(http.Response('<html>login</html>', 200)), isTrue);
    });

    test('the worker refusing or failing on the target does not', () {
      for (final s in [400, 403, 413, 415, 500, 502, 503, 504]) {
        expect(proxyUnreachable(_worker(s)), isFalse, reason: '$s');
      }
      expect(proxyUnreachable(_worker(200, body: {'ok': true})), isFalse);
    });

    test('a worker JSON error without the CORS headers does not', () {
      expect(
          proxyUnreachable(http.Response(
              jsonEncode({'error': 'Forbidden'}), 403,
              headers: {'content-type': 'application/json'})),
          isFalse);
    });

    test('header names are matched in any case', () {
      expect(
          proxyUnreachable(http.Response('', 502,
              headers: {'Access-Control-Allow-Origin': '*'})),
          isFalse);
    });
  });

  group('proxiedJsonFetch', () {
    const target = 'https://wallet.example.com/.well-known/lnurlp/alice';

    Future<(http.Response, List<http.Request>)> fetch(
        FutureOr<http.Response> Function() proxyAnswer,
        {String baseUrl = _proxy}) async {
      final seen = <http.Request>[];
      final api = ApiClient(
        baseUrl: baseUrl,
        client: MockClient((req) async {
          seen.add(req);
          if (req.url.toString() == target) {
            return http.Response('{"direct":true}', 200);
          }
          return proxyAnswer();
        }),
      );
      return (await api.proxiedJsonFetch(target), seen);
    }

    test('goes direct when the worker cannot be reached', () async {
      final (res, seen) =
          await fetch(() => throw const SocketException('unreachable'));
      expect(seen.map((r) => r.url.toString()),
          ['$_proxy?action=json&url=${Uri.encodeComponent(target)}', target]);
      expect(res.body, '{"direct":true}');
      expect(seen.last.headers['User-Agent'], isNull);
    });

    test('goes direct when the edge answers for a down worker', () async {
      final (res, seen) = await fetch(() => _edge(503));
      expect(seen.length, 2);
      expect(res.body, '{"direct":true}');
    });

    test('keeps the worker answer when it refused or failed the target',
        () async {
      for (final s in [403, 413, 415, 502, 504]) {
        final (res, seen) = await fetch(() => _worker(s));
        expect(seen.length, 1, reason: '$s');
        expect(res.statusCode, s);
      }
    });

    test('keeps a successful worker answer', () async {
      final (res, seen) =
          await fetch(() => _worker(200, body: {'callback': 'x'}));
      expect(seen.length, 1);
      expect(jsonDecode(res.body), {'callback': 'x'});
      expect(seen.single.headers['User-Agent'], ApiConfig.userAgent);
    });

    test('a slow worker is not a reason to go direct', () async {
      await expectLater(fetch(() => throw TimeoutException('slow')),
          throwsA(isA<TimeoutException>()));
    });

    test('goes direct only when no proxy is configured', () async {
      final (res, seen) = await fetch(() => _worker(200), baseUrl: '');
      expect(seen.map((r) => r.url.toString()), [target]);
      expect(res.body, '{"direct":true}');
    });
  });

  group('mediaProxyUnreachable', () {
    const proxied = '$_proxy?url=https%3A%2F%2Fcdn.example%2Fv.mp4';

    Future<(bool, http.BaseRequest?)> probe(
        FutureOr<http.Response> Function() answer) async {
      http.BaseRequest? seen;
      final result =
          await mediaProxyUnreachable(proxied, client: MockClient((req) async {
        seen = req;
        return answer();
      }));
      return (result, seen);
    }

    test('asks the worker for one byte without following redirects', () async {
      final (_, req) = await probe(() => http.Response('x', 206,
          headers: {..._cors, 'content-type': 'video/mp4'}));
      expect(req!.url.toString(), proxied);
      expect(req.headers['Range'], 'bytes=0-0');
      expect(req.followRedirects, isFalse);
    });

    test('a worker that answered is reachable', () async {
      expect((await probe(() => http.Response('x', 206, headers: _cors))).$1,
          isFalse);
      for (final s in [403, 413, 415, 502, 504]) {
        expect((await probe(() => _worker(s))).$1, isFalse, reason: '$s');
      }
    });

    test('a network failure or an edge page is unreachable', () async {
      expect((await probe(() => throw const SocketException('x'))).$1, isTrue);
      expect((await probe(() => _edge(503))).$1, isTrue);
      expect((await probe(() => _edge(522))).$1, isTrue);
    });

    test('an unmarked worker JSON error is reachable', () async {
      expect(
          (await probe(() => http.Response(
                  jsonEncode({'error': 'Forbidden'}), 403,
                  headers: {'content-type': 'application/json'})))
              .$1,
          isFalse);
    });
  });

  group('openMediaSource', () {
    const raw = 'https://cdn.example/clip.mp4';
    const mirror = 'https://mirror.example/clip.mp4';

    test('plays the proxied URL when it works', () async {
      final tried = <String>[];
      var probes = 0;
      final got = await openMediaSource([raw], (u) async {
        tried.add(u);
        return true;
      }, probe: (_) async {
        probes++;
        return false;
      });
      expect(got, proxiedMedia(raw));
      expect(tried, [proxiedMedia(raw)]);
      expect(probes, 0);
    });

    test('never touches the host when the worker answered', () async {
      final tried = <String>[];
      final got = await openMediaSource([raw, mirror], (u) async {
        tried.add(u);
        return false;
      }, probe: (_) async => false);
      expect(got, isNull);
      expect(tried, [proxiedMedia(raw), proxiedMedia(mirror)]);
    });

    test('goes to the host only when the worker is unreachable', () async {
      final tried = <String>[];
      var probes = 0;
      final got = await openMediaSource([raw, mirror], (u) async {
        tried.add(u);
        return u == mirror;
      }, probe: (_) async {
        probes++;
        return true;
      });
      expect(got, mirror);
      expect(tried, [proxiedMedia(raw), raw, proxiedMedia(mirror), mirror]);
      expect(probes, 1);
    });

    test('our own media host is played as is without a probe', () async {
      const own = 'https://cdn.nymchat.app/a.mp3';
      var probes = 0;
      final got =
          await openMediaSource([own], (_) async => false, probe: (_) async {
        probes++;
        return true;
      });
      expect(got, isNull);
      expect(probes, 0);
    });
  });

  group('app User-Agent', () {
    test('goes to our own hosts', () {
      for (final u in [
        'https://web.nymchat.app/api/proxy',
        'wss://web.nymchat.app/api/relay-pool',
        'wss://relay.nymchat.app',
        'https://nymchat.app/x',
        'https://WEB.NYMCHAT.APP/api/bot',
      ]) {
        expect(ApiConfig.userAgentFor(Uri.parse(u)), ApiConfig.userAgent,
            reason: u);
      }
    });

    test('never goes to anyone else', () {
      for (final u in [
        'wss://relay.damus.io',
        'wss://nos.lol',
        'https://api.github.com/user',
        'https://web.nymchat.app.evil.example/',
        'https://evilnymchat.app/',
      ]) {
        final ua = ApiConfig.userAgentFor(Uri.parse(u));
        expect(ua, ApiConfig.dartUserAgent, reason: u);
        expect(ua, isNot(contains('NymchatApp')), reason: u);
      }
    });

    test('relay socket headers follow the same rule', () {
      expect(ApiConfig.socketHeadersFor(Uri.parse('wss://relay.nymchat.app')),
          {'User-Agent': ApiConfig.userAgent});
      expect(ApiConfig.socketHeadersFor(Uri.parse('wss://relay.damus.io')),
          {'User-Agent': ApiConfig.dartUserAgent});
    });
  });

  group('other device fetches go through the proxy', () {
    test('the warrant canary', () async {
      final seen = <Uri>[];
      await fetchCanaryDocument(
          api: ApiClient(
              baseUrl: _proxy,
              client: MockClient((req) async {
                seen.add(req.url);
                return _worker(200, body: {'content': ''});
              })));
      expect(seen.single.toString(), startsWith('$_proxy?action=json&url='));
      expect(seen.single.queryParameters['url'],
          'https://raw.githubusercontent.com/Spl0itable/NYM/main/canary.json');
    });

    test('the profile picture handed to a mesh peer', () {
      const pic = 'https://pics.example/me.png';
      expect(meshProfileImageUri(pic).toString(),
          '$_proxy?url=${Uri.encodeComponent(pic)}');
    });
  });
}

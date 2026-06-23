// Web-proxy parity tests: every third-party media/translate/giphy/unfurl call
// is routed through the backend `/api/proxy` worker, exactly like the PWA. No
// live network — `MockClient` captures requests and returns canned bodies.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nym_bar/features/emoji/gif_picker.dart';
import 'package:nym_bar/features/messages/format/link_preview.dart';
import 'package:nym_bar/features/messages/format/message_content.dart';
import 'package:nym_bar/features/translate/translate_service.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/widgets/common/nym_avatar.dart';

void main() {
  // ---------------------------------------------------------------------------
  // mediaProxyUrl builder + pass-through rules.
  // ---------------------------------------------------------------------------
  group('mediaProxyUrl', () {
    final client = ApiClient(baseUrl: 'https://h/api/proxy');

    test('builds /api/proxy?url=<enc> for remote media', () {
      expect(
        client.mediaProxyUrl('https://cdn.example/cat.png'),
        'https://h/api/proxy?url=https%3A%2F%2Fcdn.example%2Fcat.png',
      );
    });

    test('adds &emoji=1 for custom emoji', () {
      expect(
        client.mediaProxyUrl('https://cdn.example/e.png', emoji: true),
        'https://h/api/proxy?emoji=1&url=https%3A%2F%2Fcdn.example%2Fe.png',
      );
    });

    test('proxiedMedia passes through data:/blob:/relative unchanged', () {
      expect(proxiedMedia('data:image/png;base64,AAAA'),
          'data:image/png;base64,AAAA');
      expect(proxiedMedia('blob:abcd-1234'), 'blob:abcd-1234');
      expect(proxiedMedia('/local/relative.png'), '/local/relative.png');
      expect(proxiedMedia(''), '');
    });

    test('proxiedMedia proxies remote http(s), once', () {
      final once = proxiedMedia('https://cdn.example/a.png');
      expect(once, contains('/api/proxy?url='));
      // An already-proxied URL is not double-wrapped.
      expect(proxiedMedia(once), once);
    });

    test('proxiedMedia(emoji) adds &emoji=1', () {
      expect(proxiedMedia('https://cdn.example/e.png', emoji: true),
          contains('emoji=1'));
    });

    test('proxiedAvatarUrl proxies remote, passes through data/relative/null',
        () {
      expect(proxiedAvatarUrl(null), isNull);
      expect(proxiedAvatarUrl(''), isNull);
      expect(proxiedAvatarUrl('data:image/png;base64,AA'),
          'data:image/png;base64,AA');
      expect(proxiedAvatarUrl('relative.png'), 'relative.png');
      expect(proxiedAvatarUrl('https://cdn.example/me.png'),
          contains('/api/proxy?url='));
    });
  });

  // ---------------------------------------------------------------------------
  // Translate -> ?action=translate (proxied, no direct Google).
  // ---------------------------------------------------------------------------
  group('TranslateService', () {
    test('routes to ?action=translate with the right body + parses result',
        () async {
      late http.Request captured;
      final mock = MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({'translatedText': 'hola', 'detectedLanguage': 'en'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final svc = TranslateService(
        api: ApiClient(client: mock, baseUrl: 'https://h/api/proxy'),
      );
      final res = await svc.translate('hello', 'es');

      expect(res.translatedText, 'hola');
      expect(res.detectedLanguage, 'en');
      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'https://h/api/proxy?action=translate');
      // Never hits translate.googleapis.com directly.
      expect(captured.url.host, isNot(contains('googleapis')));
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['text'], 'hello');
      expect(body['target'], 'es');
      expect(body['source'], 'auto');
    });

    test('maps a proxy error to a TranslateException', () async {
      final mock = MockClient((_) async => http.Response('nope', 502));
      final svc = TranslateService(
        api: ApiClient(client: mock, baseUrl: 'https://h/api/proxy'),
      );
      expect(() => svc.translate('x', 'es'), throwsA(isA<TranslateException>()));
    });
  });

  // ---------------------------------------------------------------------------
  // Giphy -> ?action=giphy (proxied, no direct api.giphy.com).
  // ---------------------------------------------------------------------------
  group('GiphyService', () {
    String giphyBody() => jsonEncode({
          'data': [
            {
              'title': 'a cat',
              'images': {
                'fixed_height': {'url': 'https://media.giphy.com/cat.gif'},
              },
            },
            // Missing url -> skipped.
            {
              'title': 'broken',
              'images': {'fixed_height': {}},
            },
          ],
        });

    test('search routes to ?action=giphy&q=… and parses the gif list',
        () async {
      late Uri captured;
      final mock = MockClient((req) async {
        captured = req.url;
        return http.Response(giphyBody(), 200,
            headers: {'content-type': 'application/json'});
      });
      final svc = GiphyService(
        api: ApiClient(
            client: mock, baseUrl: 'https://h/api/proxy', giphyApiKey: 'KEY'),
      );
      final gifs = await svc.search('cats');

      expect(captured.queryParameters['action'], 'giphy');
      expect(captured.queryParameters['q'], 'cats');
      expect(captured.host, isNot(contains('api.giphy.com')));
      expect(gifs, hasLength(1));
      expect(gifs.first.url, 'https://media.giphy.com/cat.gif');
      expect(gifs.first.title, 'a cat');
    });

    test('trending routes to ?action=giphy&trending=1', () async {
      late Uri captured;
      final mock = MockClient((req) async {
        captured = req.url;
        return http.Response(giphyBody(), 200,
            headers: {'content-type': 'application/json'});
      });
      final svc = GiphyService(
        api: ApiClient(
            client: mock, baseUrl: 'https://h/api/proxy', giphyApiKey: 'KEY'),
      );
      final gifs = await svc.trending();

      expect(captured.queryParameters['action'], 'giphy');
      expect(captured.queryParameters['trending'], '1');
      expect(gifs, hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------
  // Unfurl -> ?action=unfurl, and the link-preview model.
  // ---------------------------------------------------------------------------
  group('unfurl + LinkPreviewData', () {
    test('unfurl routes to ?action=unfurl and parses {title,description,image}',
        () async {
      late Uri captured;
      final mock = MockClient((req) async {
        captured = req.url;
        return http.Response(
          jsonEncode({
            'url': 'https://example.com/post',
            'title': 'Hello',
            'description': 'A description',
            'image': 'https://example.com/og.png',
            'siteName': 'Example',
            'favicon': 'https://example.com/favicon.ico',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = ApiClient(client: mock, baseUrl: 'https://h/api/proxy');
      final res = await api.unfurl('https://example.com/post');

      expect(captured.queryParameters['action'], 'unfurl');
      expect(captured.queryParameters['url'], 'https://example.com/post');
      expect(res.title, 'Hello');
      expect(res.description, 'A description');
      expect(res.image, 'https://example.com/og.png');

      final model = LinkPreviewData.fromUnfurl(res);
      expect(model.hasContent, isTrue);
      expect(model.title, 'Hello');
      expect(model.description, 'A description');
      expect(model.image, 'https://example.com/og.png');
      // siteName wins over hostname for the header label.
      expect(model.host, 'Example');
    });

    test('LinkPreviewData with no title/description has no content', () {
      final model = LinkPreviewData.fromUnfurl(
        const UnfurlResult(url: 'https://x.com', title: '', description: ''),
      );
      expect(model.hasContent, isFalse);
      // Falls back to hostname when siteName is empty.
      expect(model.host, 'x.com');
    });

    test('isInlineMediaUrl skips embedded media but allows page links', () {
      expect(isInlineMediaUrl('https://x.com/cat.png'), isTrue);
      expect(isInlineMediaUrl('https://x.com/clip.mp4?t=1'), isTrue);
      expect(isInlineMediaUrl('https://x.com/article'), isFalse);
    });
  });
}

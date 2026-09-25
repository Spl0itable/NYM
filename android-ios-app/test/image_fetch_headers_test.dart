import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/messages/inline_network_image.dart';
import 'package:nym_bar/services/api/api_config.dart';

void main() {
  group('image fetch headers', () {
    test('our media proxy is fetched as the app', () {
      final h = InlineNetworkImage.imageHeadersFor(
          'https://${ApiConfig.apiHost}/api/proxy?url=https%3A%2F%2Fi.example%2Fa.png');
      expect(h['User-Agent'], ApiConfig.userAgent);
      expect(h['Accept'], startsWith('image/'));
    });

    test('our host in any case is still ours', () {
      expect(
          InlineNetworkImage.imageHeadersFor(
              'https://WEB.NYMCHAT.APP/api/proxy?url=x')['User-Agent'],
          ApiConfig.userAgent);
    });

    test('a third-party host is fetched as a browser', () {
      final h = InlineNetworkImage.imageHeadersFor('https://i.example/a.png');
      expect(h['User-Agent'], startsWith('Mozilla/5.0'));
    });

    test('a lookalike host is not ours', () {
      expect(
          InlineNetworkImage.imageHeadersFor(
              'https://web.nymchat.app.evil.example/a.png')['User-Agent'],
          startsWith('Mozilla/5.0'));
    });

    test('an unparseable url gets the browser headers', () {
      expect(InlineNetworkImage.imageHeadersFor('::not a url::'),
          InlineNetworkImage.imageFetchHeaders);
    });
  });
}

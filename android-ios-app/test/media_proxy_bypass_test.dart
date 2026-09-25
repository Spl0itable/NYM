import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/features/messages/format/message_content.dart';
import 'package:nym_bar/widgets/common/nym_avatar.dart';

void main() {
  group('a foreign URL that merely looks proxied', () {
    const spoof = 'https://evil.example/api/proxy?x=1/pixel.png';

    test('still goes through the media proxy', () {
      expect(proxiedMedia(spoof),
          'https://web.nymchat.app/api/proxy?url=${Uri.encodeComponent(spoof)}');
      expect(proxiedMedia(spoof, emoji: true),
          startsWith('https://web.nymchat.app/api/proxy?emoji=1&url='));
      expect(proxiedAvatarUrl(spoof),
          'https://web.nymchat.app/api/proxy?url=${Uri.encodeComponent(spoof)}');
    });

    test('a URL already on the proxy is left alone', () {
      final once = proxiedMedia('https://cdn.example/a.png');
      expect(proxiedMedia(once), once);
      expect(proxiedAvatarUrl(once), once);
    });
  });
}

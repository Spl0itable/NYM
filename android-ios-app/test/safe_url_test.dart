import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/utils/safe_url.dart';

void main() {
  group('safeExternalUri', () {
    test('rejects schemes a message must never reach', () {
      const hostile = [
        'javascript:alert(1)',
        'JaVaScRiPt:alert(1)',
        'java\tscript:alert(1)',
        'java\nscript:alert(1)',
        ' javascript:alert(1)',
        'data:text/html;base64,PHNjcmlwdD4=',
        'vbscript:msgbox(1)',
        'file:///etc/passwd',
        'content://com.other/db',
        'intent://x#Intent;package=com.other;end',
        'blob:https://x/y',
        '',
      ];
      for (final u in hostile) {
        expect(safeExternalUri(u), isNull, reason: 'must reject $u');
      }
      expect(safeExternalUri(null), isNull);
    });

    test('keeps the schemes a link legitimately uses', () {
      for (final u in [
        'https://ok.com/a?b=c#d',
        'http://ok.com',
        'mailto:a@b.c',
        'tel:+15551234',
      ]) {
        expect(safeExternalUri(u)?.toString(), u, reason: 'must keep $u');
      }
      // Uri normalises the scheme and host, which is fine — it stays http(s).
      expect(safeExternalUri('HTTPS://OK.COM')?.scheme, 'https');
    });

    test('a scheme-relative URL has no scheme to trust', () {
      expect(safeExternalUri('//evil.com/x'), isNull);
    });
  });
}

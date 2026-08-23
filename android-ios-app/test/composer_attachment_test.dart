// The attachment list decides what media a message carries. It used to be the
// draft text: each upload appended its URL to the input and the strip parsed
// them back out, which is what made a finished upload's preview vanish.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/widgets/chat/composer_format.dart';

ComposerAttachment att(int id, {bool video = false}) => ComposerAttachment(
      id: id,
      isVideo: video,
      contentType: video ? 'video/mp4' : 'image/png',
      bytes: Uint8List.fromList([1, 2, 3]),
    );

List<String> urlsOf(List<ComposerAttachment> l) =>
    [for (final a in l) if (a.isDone) a.url];

void main() {
  group('attachment lifecycle', () {
    test('a fresh attachment is uploading and contributes nothing', () {
      final a = att(1);
      expect(a.status, ComposerAttachmentStatus.uploading);
      expect(a.isDone, isFalse);
      expect(urlsOf([a]), isEmpty);
    });

    test('finishing gives it a URL without discarding the tile', () {
      final a = att(1)
        ..status = ComposerAttachmentStatus.done
        ..url = 'https://h/a.png';
      expect(a.isDone, isTrue);
      expect(urlsOf([a]), ['https://h/a.png']);
    });

    test('done with no URL is not done — it must never reach a message', () {
      final a = att(1)..status = ComposerAttachmentStatus.done;
      expect(a.isDone, isFalse);
      expect(urlsOf([a]), isEmpty);
    });

    test('a failure keeps its bytes, so retry needs no re-pick', () {
      final a = att(1)
        ..status = ComposerAttachmentStatus.failed
        ..error = 'server said no';
      expect(a.bytes, isNotNull);
      expect(a.error, isNotEmpty);
      expect(urlsOf([a]), isEmpty);
    });

    // The point of per-file state: one failure must not cost the whole batch.
    test('a failed sibling does not suppress the successful ones', () {
      final ok1 = att(1)
        ..status = ComposerAttachmentStatus.done
        ..url = 'https://h/1.png';
      final bad = att(2)..status = ComposerAttachmentStatus.failed;
      final ok2 = att(3)
        ..status = ComposerAttachmentStatus.done
        ..url = 'https://h/3.png';
      expect(urlsOf([ok1, bad, ok2]), ['https://h/1.png', 'https://h/3.png']);
    });

    test('URLs keep the order the user added them', () {
      final list = [
        att(1)..status = ComposerAttachmentStatus.done..url = 'https://h/1.png',
        att(2)..status = ComposerAttachmentStatus.done..url = 'https://h/2.png',
      ];
      expect(urlsOf(list), ['https://h/1.png', 'https://h/2.png']);
      expect(urlsOf(list.reversed.toList()),
          ['https://h/2.png', 'https://h/1.png']);
    });

    test('a retry that succeeds joins the message', () {
      final a = att(1)..status = ComposerAttachmentStatus.failed;
      expect(urlsOf([a]), isEmpty);
      a
        ..status = ComposerAttachmentStatus.done
        ..url = 'https://h/a.png'
        ..error = '';
      expect(urlsOf([a]), ['https://h/a.png']);
    });

    test('a video keeps its bytes even though the tile draws no frame', () {
      final a = att(1, video: true);
      expect(a.isVideo, isTrue);
      expect(a.bytes, isNotNull);
    });
  });

  group('send-time composition', () {
    // Mirrors the composer: URLs are appended to the draft at send, separated
    // so a draft ending mid-word cannot glue onto the first URL.
    String compose(String typed, List<String> urls) {
      var out = typed;
      if (urls.isEmpty) return out;
      final needsSpace = out.isNotEmpty && !out.endsWith(' ');
      return '$out${needsSpace ? ' ' : ''}${urls.join(' ')}';
    }

    test('a bare attachment sends with no typed text', () {
      expect(compose('', ['https://h/a.png']), 'https://h/a.png');
    });

    test('text and attachments are separated', () {
      expect(compose('look', ['https://h/a.png']), 'look https://h/a.png');
    });

    test('an existing trailing space is not doubled', () {
      expect(compose('look ', ['https://h/a.png']), 'look https://h/a.png');
    });

    test('several attachments are space-joined', () {
      expect(compose('hi', ['https://h/a.png', 'https://h/b.png']),
          'hi https://h/a.png https://h/b.png');
    });

    test('no attachments leaves the draft untouched', () {
      expect(compose('just text', const []), 'just text');
    });
  });
}

// Guards the composer attachment strip against extension-less media URLs.
//
// Blossom is content-addressed, and several of the servers Nymchat uploads to
// return a bare `https://host/<sha256>` with no file extension. The strip's
// regex can only recognise media by extension, so those uploads fell out of the
// match list the instant the "uploading" placeholder cleared — the preview
// vanished and the user was left looking at a raw URL in the input.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/widgets/chat/composer_format.dart';

const _hash =
    'a3f2b1c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80';
const _bare = 'https://nostr.download/$_hash';
const _withExt = 'https://blossom.band/$_hash.png';

void main() {
  group('extension-bearing URLs (unchanged)', () {
    test('an image URL matches', () {
      final m = composerMediaMatches('look $_withExt ');
      expect(m, hasLength(1));
      expect(m.first.url, _withExt);
      expect(m.first.isVideo, isFalse);
    });

    test('a video URL is flagged as video', () {
      final m = composerMediaMatches('https://blossom.band/$_hash.mp4');
      expect(m, hasLength(1));
      expect(m.first.isVideo, isTrue);
    });
  });

  group('extension-less URLs', () {
    test('are missed without knownMedia — the original bug', () {
      expect(composerMediaMatches('here $_bare '), isEmpty);
    });

    test('are matched once we know we uploaded them', () {
      final m = composerMediaMatches('here $_bare ', knownMedia: {_bare: false});
      expect(m, hasLength(1));
      expect(m.first.url, _bare);
      expect(m.first.isVideo, isFalse);
      expect('here $_bare '.substring(m.first.start, m.first.end), _bare);
    });

    test('carry their video flag', () {
      final m = composerMediaMatches(_bare, knownMedia: {_bare: true});
      expect(m.single.isVideo, isTrue);
    });

    test('a URL we did not upload is still ignored', () {
      expect(
          composerMediaMatches('https://example.com/page',
              knownMedia: {_bare: false}),
          isEmpty);
    });
  });

  group('mixed drafts', () {
    test('both kinds appear, in draft order', () {
      final draft = 'a $_bare b $_withExt c';
      final m = composerMediaMatches(draft, knownMedia: {_bare: false});
      expect(m.map((e) => e.url), [_bare, _withExt]);
    });

    test('the same span is never reported twice', () {
      // A bare URL that is also a prefix of an extension-bearing one must not
      // produce two overlapping chips for one attachment.
      final draft = 'x $_withExt';
      final prefix = _withExt.substring(0, _withExt.length - 4);
      final m = composerMediaMatches(draft, knownMedia: {prefix: false});
      expect(m, hasLength(1));
      expect(m.single.url, _withExt);
    });

    test('a URL repeated in the draft yields one chip each', () {
      final m = composerMediaMatches('$_bare and $_bare',
          knownMedia: {_bare: false});
      expect(m, hasLength(2));
      expect(m[0].start, lessThan(m[1].start));
    });
  });

  group('removal indexes the same list the strip rendered', () {
    test('removing an extension-less attachment removes the right one', () {
      final draft = '$_bare $_withExt ';
      final out = removeComposerMedia(draft, 0, knownMedia: {_bare: false});
      expect(out.text.contains(_bare), isFalse);
      expect(out.text.contains(_withExt), isTrue);
    });

    test('removing the second removes the second', () {
      final draft = '$_bare $_withExt ';
      final out = removeComposerMedia(draft, 1, knownMedia: {_bare: false});
      expect(out.text.contains(_bare), isTrue);
      expect(out.text.contains(_withExt), isFalse);
    });
  });
}

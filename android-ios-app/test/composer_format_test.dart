// Parity tests for the composer's markdown transforms — the same cases the PWA
// module (js/modules/rich-compose.js) is checked against, so the two clients
// can't drift.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/widgets/chat/composer_format.dart';

FormatTool _tool(String id) => kFormatTools.firstWhere((t) => t.id == id);

void main() {
  group('inline wraps', () {
    test('wraps a selection', () {
      final r = applyWrap(const FormatEdit('hello world', 6, 11), '**');
      expect(r.text, 'hello **world**');
      expect(r.start, 8);
      expect(r.end, 13);
    });

    test('a second press unwraps from inside', () {
      var r = applyWrap(const FormatEdit('hello world', 6, 11), '**');
      r = applyWrap(r, '**');
      expect(r.text, 'hello world');
    });

    test('unwraps when the delimiters are inside the selection', () {
      final r = applyWrap(const FormatEdit('hello **world**', 6, 15), '**');
      expect(r.text, 'hello world');
    });

    test('a collapsed caret takes the word under it', () {
      final r = applyWrap(const FormatEdit('hello world', 8, 8), '**');
      expect(r.text, 'hello **world**');
    });

    test('a caret on whitespace inserts empty delimiters', () {
      final r = applyWrap(const FormatEdit('a ', 2, 2), '**');
      expect(r.text, 'a ****');
      expect(r.start, 4);
      expect(r.end, 4);
    });

    test('never swallows edge whitespace', () {
      final r = applyWrap(const FormatEdit('hi there ', 3, 9), '*');
      expect(r.text, 'hi *there* ');
    });

    test('strikethrough round-trips', () {
      var r = applyWrap(const FormatEdit('nope', 0, 4), '~~');
      expect(r.text, '~~nope~~');
      r = applyWrap(r, '~~');
      expect(r.text, 'nope');
    });

    test('inline code', () {
      final r = applyWrap(const FormatEdit('let x = 1', 0, 9), '`');
      expect(r.text, '`let x = 1`');
    });

    test('a reversed selection is normalised', () {
      final r = applyWrap(const FormatEdit('hello world', 11, 6), '**');
      expect(r.text, 'hello **world**');
    });
  });

  group('line prefixes', () {
    test('quotes every line the selection touches', () {
      var r = applyLinePrefix(const FormatEdit('one\ntwo\nthree', 1, 6), '> ');
      expect(r.text, '> one\n> two\nthree');
      r = applyLinePrefix(r, '> ');
      expect(r.text, 'one\ntwo\nthree');
    });

    test('headings replace one another rather than stacking', () {
      const ex = ['### ', '## ', '# '];
      var r = applyLinePrefix(const FormatEdit('Title', 0, 0), '# ',
          exclusive: ex);
      expect(r.text, '# Title');
      r = applyLinePrefix(r, '## ', exclusive: ex);
      expect(r.text, '## Title');
      r = applyLinePrefix(r, '### ', exclusive: ex);
      expect(r.text, '### Title');
      r = applyLinePrefix(r, '### ', exclusive: ex);
      expect(r.text, 'Title');
    });

    test('only touches the selected line', () {
      final r = applyLinePrefix(const FormatEdit('a\nb', 2, 2), '# ',
          exclusive: ['### ', '## ', '# ']);
      expect(r.text, 'a\n# b');
    });
  });

  group('code blocks', () {
    test('fences and unfences the selected lines', () {
      var r = applyCodeBlock(const FormatEdit('foo\nbar', 0, 7), '```');
      expect(r.text, '```\nfoo\nbar\n```');
      r = applyCodeBlock(FormatEdit(r.text, 0, r.text.length), '```');
      expect(r.text, 'foo\nbar');
    });

    test('unfencing drops an opening language tag', () {
      final src = '```js\nlet a=1\n```';
      final r = applyCodeBlock(FormatEdit(src, 0, src.length), '```');
      expect(r.text, 'let a=1');
    });
  });

  group('applyFormatTool dispatch', () {
    test('routes each kind to its transform', () {
      expect(
          applyFormatTool(const FormatEdit('x', 0, 1), _tool('bold')).text,
          '**x**');
      expect(
          applyFormatTool(const FormatEdit('x', 0, 1), _tool('quote')).text,
          '> x');
      expect(
          applyFormatTool(const FormatEdit('x', 0, 1), _tool('codeblock')).text,
          '```\nx\n```');
    });
  });

  group('attachments', () {
    test('finds images and videos with their offsets', () {
      const draft = 'hey https://a.co/x.png and https://b.co/v.mp4 end';
      final m = composerMediaMatches(draft);
      expect(m.length, 2);
      expect(m[0].isVideo, isFalse);
      expect(m[1].isVideo, isTrue);
      expect(m[0].url, 'https://a.co/x.png');
      expect(draft.substring(m[1].start, m[1].end), 'https://b.co/v.mp4');
    });

    test('keeps a query string with the url', () {
      expect(composerMediaMatches('https://a.co/x.jpg?w=1 ')[0].url,
          'https://a.co/x.jpg?w=1');
    });

    test('ignores non-media links', () {
      expect(composerMediaMatches('https://a.co/page'), isEmpty);
    });

    test('removal swallows one adjacent space', () {
      const draft = 'look https://a.co/x.png https://b.co/v.mp4';
      var r = removeComposerMedia(draft, 0);
      expect(r.text, 'look https://b.co/v.mp4');
      r = removeComposerMedia(r.text, 0);
      expect(r.text, 'look');
    });

    test('an out-of-range index is a no-op', () {
      expect(removeComposerMedia('hello', 3).text, 'hello');
    });
  });
}

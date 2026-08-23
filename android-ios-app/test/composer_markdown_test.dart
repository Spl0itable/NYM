// Tests the composer's live formatting: the markdown grammar in
// composer_markdown.dart and the way EmojiSentinelController paints it into the
// message field.
//
// The point of these tests is the caret coordinate system. The field renders
// `**bold**` as bold and hides the asterisks, so what is on screen no longer
// matches the draft — but every offset the rest of the composer hands the field
// (TextSelection, the toolbar's slice arithmetic, `expand` for the wire) still
// addresses the draft. That only holds because a hidden delimiter is painted at
// zero size rather than dropped: the characters stay in the span tree and keep
// their own offsets.
//
// So each case checks the same things: the parse tree covers the draft exactly,
// the painted spans are the same length as the draft, the delimiters actually
// disappear rather than being mis-sized, and a caret inside a run brings them
// back.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/widgets/chat/composer.dart';
import 'package:nym_bar/widgets/chat/composer_markdown.dart';

/// The drafts every structural invariant is checked against.
const List<(String, String)> _drafts = [
  ('plain', 'hello world'),
  ('bold', 'a **bold** b'),
  ('bold at both ends', '**b** and **c**'),
  ('italic', 'a *it* b'),
  ('strike', 'x ~~y~~ z'),
  ('inline code', 'run `flutter test` now'),
  ('nested', '**bold with *italic* inside**'),
  ('nested three deep', '**a ~~b *c* d~~ e**'),
  ('heading', '# Big title'),
  ('heading with bold', '## A **bold** title'),
  ('quote', '> quoted **text**'),
  ('multiline', '# Title\nbody **bold**\n> quote'),
  ('fence', '```\nlet x = 1;\n```'),
  ('fence with language', '```dart\nvar x = 1;\n```'),
  ('unterminated fence', '```dart\nvar x = 1;'),
  ('bare fence', '```'),
  ('empty closed fence', '``````'),
  ('text then a bare fence', 'intro\n```'),
  ('fence then text', '```\ncode\n```\nafter **that**'),
  ('adjacent markers', '**a**~~b~~'),
  ('empty lines', 'a\n\n**b**\n\nc'),
  ('trailing newline', '**bold**\n'),
  ('leading newline', '\n**bold**'),
  ('unmatched markers', '**a * b ~~ c'),
  ('underscore emphasis', 'an _emphasised_ word'),
  ('url in bold', '**see https://x.test/a.png**'),
  ('colon before star', 'time 3:00*x*'),
];

/// Walks [runs] and reports every way the tree fails to cover [text] exactly.
List<String> _coverageProblems(String text, List<RichRun> runs) {
  final problems = <String>[];
  void walk(List<RichRun> nodes, int from, int to) {
    var pos = from;
    for (final n in nodes) {
      if (n.start != pos) problems.add('gap/overlap at ${n.start}, expected $pos');
      if (!n.isText) {
        final innerStart = n.start + n.open.length;
        final innerEnd = n.end - n.close.length;
        if (innerEnd < innerStart) problems.add('negative body at ${n.start}');
        if (text.substring(n.start, innerStart) != n.open) {
          problems.add('open marker mismatch at ${n.start}');
        }
        if (text.substring(innerEnd, n.end) != n.close) {
          problems.add('close marker mismatch at ${n.end}');
        }
        walk(n.children, innerStart, innerEnd);
      }
      pos = n.end;
    }
    if (pos != to) problems.add('tail gap: ended at $pos, expected $to');
  }

  walk(runs, 0, text.length);
  return problems;
}

/// The types present in a tree, innermost last.
List<String> _types(List<RichRun> runs) {
  final out = <String>[];
  void walk(List<RichRun> nodes) {
    for (final n in nodes) {
      if (n.isText) continue;
      out.add(n.type);
      walk(n.children);
    }
  }

  walk(runs);
  return out;
}

/// Everything the user can read: the text of every span that is neither painted
/// at the hidden delimiter's zero size nor in transparent ink (the fences of an
/// empty block keep their width so the block has a box, but stay unreadable).
String _visibleText(TextSpan root) {
  final buf = StringBuffer();
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      final style = span.style;
      final hidden = (style?.fontSize ?? 14) < 1 || style?.color?.a == 0;
      if (span.text != null && !hidden) buf.write(span.text);
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(root);
  return buf.toString();
}

void main() {
  group('grammar', () {
    for (final (label, text) in _drafts) {
      test('$label: the tree covers the draft', () {
        expect(_coverageProblems(text, parseRichFormat(text)), isEmpty);
      });
    }

    test('each construct is recognised', () {
      expect(_types(parseRichFormat('**b**')), ['bold']);
      expect(_types(parseRichFormat('__b__')), ['bold']);
      expect(_types(parseRichFormat('*i*')), ['italic']);
      expect(_types(parseRichFormat('_i_')), ['italic']);
      expect(_types(parseRichFormat('~~s~~')), ['strike']);
      expect(_types(parseRichFormat('`c`')), ['code']);
      expect(_types(parseRichFormat('```\nc\n```')), ['codeblock']);
      expect(_types(parseRichFormat('# h')), ['h1']);
      expect(_types(parseRichFormat('## h')), ['h2']);
      expect(_types(parseRichFormat('### h')), ['h3']);
      expect(_types(parseRichFormat('> q')), ['quote']);
    });

    test('bold wins over italic at the same offset', () {
      expect(_types(parseRichFormat('**b** and *i*')), ['bold', 'italic']);
    });

    test('inline code takes no nested formatting', () {
      expect(_types(parseRichFormat('`**not bold**`')), ['code']);
    });

    test('nesting is preserved', () {
      expect(_types(parseRichFormat('**a *b* c**')), ['bold', 'italic']);
    });

    test('what the renderer leaves alone stays plain', () {
      for (final text in [
        'a * b',
        'a *  b',
        'https://x.test/a_b_c',
        'some_var_name here',
        'not # a heading',
        '#hashtag',
        'ratio 3:4',
      ]) {
        expect(_types(parseRichFormat(text)), isEmpty, reason: text);
      }
    });

    test('a line prefix only counts at a line start', () {
      expect(_types(parseRichFormat('text\n# heading')), ['h1']);
      expect(_types(parseRichFormat('text # not a heading')), isEmpty);
    });

    test('an unterminated fence has no closing marker to hide', () {
      final fence = parseRichFormat('```\ncode').single;
      expect(fence.type, 'codeblock');
      expect(fence.open, '```');
      expect(fence.close, isEmpty);
    });

    test('an empty draft parses to nothing', () {
      expect(parseRichFormat(''), isEmpty);
      expect(hasRichFormat(parseRichFormat('plain text')), isFalse);
      expect(hasRichFormat(parseRichFormat('**bold**')), isTrue);
    });
  });

  group('code blocks', () {
    test('three backticks open a block before there is anything in it', () {
      // Slack's behaviour: the block appears as you type the fence, not once
      // you type the first character of code.
      final runs = parseRichFormat('```');
      expect(_types(runs), ['codeblock']);
      expect(runs.single.emptyBody, isTrue);
      expect(runs.single.close, isEmpty);
    });

    test('the first character lands inside the block', () {
      final runs = parseRichFormat('```x');
      expect(_types(runs), ['codeblock']);
      expect(runs.single.emptyBody, isFalse);
    });

    test('an empty closed block is still empty', () {
      final runs = parseRichFormat('``````');
      expect(runs.single.emptyBody, isTrue);
      expect(runs.single.close, '```');
    });

    test('a fence added in front wraps what follows', () {
      final runs = parseRichFormat('```code here');
      expect(_types(runs), ['codeblock']);
      expect(runs.single.start, 0);
      expect(runs.single.end, 12);
    });

    test('a fence added after closes the block', () {
      final runs = parseRichFormat('```code here```');
      expect(runs.single.close, '```');
    });

    test('text before a fence stays outside it', () {
      final runs = parseRichFormat('intro\n```\ncode');
      expect(_types(runs), ['codeblock']);
      expect(runs.last.start, 6);
    });

    test('two backticks are not a block', () {
      expect(_types(parseRichFormat('``')), isEmpty);
    });
  });

  group('deleting a hidden block marker', () {
    ({String text, int caret})? del(String t, int c, {bool forward = false}) {
      final v = richMarkerDelete(t, c, forward: forward);
      return v == null ? null : (text: v.text, caret: v.selection.baseOffset);
    }

    test('backspace at the start of a heading removes the whole prefix', () {
      expect(del('# Title', 2), (text: 'Title', caret: 0));
      expect(del('### Title', 4), (text: 'Title', caret: 0));
      expect(del('> quoted', 2), (text: 'quoted', caret: 0));
    });

    test('forward-delete at the head of the line removes the prefix', () {
      expect(del('# Title', 0, forward: true), (text: 'Title', caret: 0));
    });

    test('a heading on a later line is found too', () {
      expect(del('intro\n# Title', 8), (text: 'intro\nTitle', caret: 6));
    });

    test('a fence unwraps whole, keeping the code', () {
      expect(del('```', 3), (text: '', caret: 0));
      expect(del('```\ncode\n```', 3), (text: '\ncode\n', caret: 0));
      expect(del('```\ncode\n```', 12), (text: '\ncode\n', caret: 6));
      expect(del('```\ncode\n```', 0, forward: true), (text: '\ncode\n', caret: 0));
      expect(del('```code', 3), (text: 'code', caret: 0));
    });

    test('an inline run unwraps whole, keeping the text', () {
      // Same reason a fence does: the markers are hidden, so a plain Backspace
      // would eat one half of the pair and leave the other as literal text.
      expect(del('a **bold** b', 4), (text: 'a bold b', caret: 2));
      expect(del('a **bold** b', 10), (text: 'a bold b', caret: 6));
      expect(del('a **bold** b', 2, forward: true), (text: 'a bold b', caret: 2));
      expect(del('a **bold** b', 8, forward: true), (text: 'a bold b', caret: 6));
      expect(del('a *it* b', 3), (text: 'a it b', caret: 2));
      expect(del('a ~~s~~ b', 4), (text: 'a s b', caret: 2));
      expect(del('a `c` b', 3), (text: 'a c b', caret: 2));
      // Innermost first: one press drops one level of formatting, not both.
      expect(del('**a *b* c**', 5), (text: '**a b c**', caret: 4));
    });

    test('everywhere else the plain character delete stands', () {
      expect(del('# Title', 4), isNull);
      expect(del('# Title', 7), isNull);
      expect(del('```\ncode\n```', 6), isNull);
      expect(del('hello', 3), isNull);
      expect(del('hello', 0), isNull);
      // Mid-body, with no marker adjacent.
      expect(del('a **bold** b', 6), isNull);
      expect(del('# Title', 99), isNull);
      expect(del('', 0), isNull);
    });
  });

  group('RichMarkerDeleteFormatter', () {
    const f = RichMarkerDeleteFormatter();

    TextEditingValue backspaceAt(String text, int caret) {
      // What the framework hands a formatter for one Backspace press.
      return f.formatEditUpdate(
        TextEditingValue(
            text: text, selection: TextSelection.collapsed(offset: caret)),
        TextEditingValue(
          text: text.substring(0, caret - 1) + text.substring(caret),
          selection: TextSelection.collapsed(offset: caret - 1),
        ),
      );
    }

    test('one press takes the whole marker', () {
      expect(backspaceAt('# Title', 2).text, 'Title');
      // Without the formatter this press would leave "#Title" — the prefix
      // broken but still there, and the heading silently gone.
      expect(backspaceAt('```', 3).text, '');
    });

    test('an ordinary backspace is untouched', () {
      expect(backspaceAt('hello', 5).text, 'hell');
      expect(backspaceAt('# Title', 7).text, '# Titl');
    });

    test('typing is untouched', () {
      const before = TextEditingValue(
          text: '# Titl', selection: TextSelection.collapsed(offset: 6));
      const after = TextEditingValue(
          text: '# Title', selection: TextSelection.collapsed(offset: 7));
      expect(f.formatEditUpdate(before, after), after);
    });

    test('deleting a selection is untouched', () {
      const before = TextEditingValue(
          text: '# Title',
          selection: TextSelection(baseOffset: 0, extentOffset: 2));
      const after = TextEditingValue(
          text: 'Title', selection: TextSelection.collapsed(offset: 0));
      expect(f.formatEditUpdate(before, after), after);
    });
  });

  group('reveal', () {
    test('an inline run never reveals, wherever the caret is', () {
      // It used to reveal from anywhere inside its span [2, 10] — and while
      // you are typing a run the caret is always inside it, so the markers
      // were on screen for the whole time it took to write.
      const text = 'a **bold** b';
      final run = parseRichFormat(text)[1];
      expect(run.type, 'bold');
      for (var i = 0; i <= text.length; i++) {
        expect(run.revealedAt(i, i), isFalse, reason: 'caret $i');
      }
    });

    test('a selection across a run does not reveal it either', () {
      final run = parseRichFormat('a **bold** b')[1];
      expect(run.revealedAt(0, 12), isFalse);
    });

    test('a heading never reveals, wherever the caret is', () {
      // Showing the prefix again would shift the line every time the caret
      // passed the start of it; what a heading is reads off its styling.
      const text = '# A long heading';
      final run = parseRichFormat(text).single;
      for (var i = 0; i <= text.length; i++) {
        expect(run.revealedAt(i, i), isFalse, reason: 'caret $i');
      }
      expect(run.revealedAt(0, text.length), isFalse);
    });

    test('a fence never reveals either', () {
      // Revealing it would undo the empty block the user just opened.
      const text = '```\nlots of code here\n```';
      final run = parseRichFormat(text).single;
      for (var i = 0; i <= text.length; i++) {
        expect(run.revealedAt(i, i), isFalse, reason: 'caret $i');
      }
    });

    test('no caret means nothing is revealed', () {
      final run = parseRichFormat('**bold**').single;
      expect(run.revealedAt(-1, -1), isFalse);
    });
  });

  group('painting', () {
    late BuildContext ctx;
    late TextStyle style;

    Future<void> mount(WidgetTester tester) async {
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );
      await tester.pumpWidget(MaterialApp(
        theme: buildNymThemeData(colors),
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      style = const TextStyle(fontSize: 14);
    }

    TextSpan paint(String text, {TextSelection? selection, bool focused = true}) {
      final c = EmojiSentinelController(text: text);
      c.composerFocused = focused;
      if (selection != null) {
        c.value = c.value.copyWith(text: text, selection: selection);
      }
      return c.buildTextSpan(
          context: ctx, style: style, withComposing: false);
    }

    testWidgets('the painted spans are exactly as long as the draft',
        (tester) async {
      await mount(tester);
      for (final (label, text) in _drafts) {
        final span = paint(text, selection: const TextSelection.collapsed(offset: 0));
        expect(span.toPlainText().length, text.length, reason: label);
      }
    });

    testWidgets('...at every caret position, revealed or not', (tester) async {
      await mount(tester);
      for (final (label, text) in _drafts) {
        for (var i = 0; i <= text.length; i++) {
          final span =
              paint(text, selection: TextSelection.collapsed(offset: i));
          expect(span.toPlainText(), text, reason: '$label at $i');
        }
      }
    });

    testWidgets('the delimiters disappear, whole', (tester) async {
      await mount(tester);
      const cases = [
        ('**bold**', 'bold'),
        ('__bold__', 'bold'),
        ('*it*', 'it'),
        ('_it_', 'it'),
        ('~~gone~~', 'gone'),
        ('`x = 1`', 'x = 1'),
        ('```\nx = 1\n```', '\nx = 1\n'),
        ('```dart\nx\n```', 'dart\nx\n'),
        ('# Title', 'Title'),
        ('## Title', 'Title'),
        ('### Title', 'Title'),
        ('> quoted', 'quoted'),
        ('a **b** c *d* e', 'a b c d e'),
        ('**bold with *italic* inside**', 'bold with italic inside'),
        ('# A **bold** heading', 'A bold heading'),
        ('plain text', 'plain text'),
        ('a * b', 'a * b'),
        ('#hashtag', '#hashtag'),
      ];
      for (final (text, want) in cases) {
        // Caret parked away from every run so nothing is revealed.
        final span = paint(text, selection: const TextSelection.collapsed(offset: -1));
        expect(_visibleText(span), want, reason: text);
      }
    });

    testWidgets('markers stay hidden even with everything selected',
        (tester) async {
      await mount(tester);
      for (final (text, want) in const [
        ('# Title', 'Title'),
        ('> quoted', 'quoted'),
        ('```\ncode\n```', '\ncode\n'),
        // The heading prefix goes, and so do the bold delimiters inside it.
        ('# A **bold** heading', 'A bold heading'),
      ]) {
        final span = paint(text,
            selection: TextSelection(baseOffset: 0, extentOffset: text.length));
        expect(_visibleText(span), want, reason: text);
      }
    });

    testWidgets('no caret position brings a run\'s delimiters back',
        (tester) async {
      await mount(tester);
      const text = 'a **bold** b';
      // The regression this guards: typing "**bold**" leaves the caret at
      // offset 10, inside the run, and the field used to show the asterisks
      // there — so the markers were on screen for the whole time it took to
      // write the run.
      for (final offset in const [0, 3, 5, 6, 10, 12]) {
        final span =
            paint(text, selection: TextSelection.collapsed(offset: offset));
        expect(_visibleText(span), 'a bold b', reason: 'caret at $offset');
        // ...and what the field is holding never changes.
        expect(span.toPlainText(), text, reason: 'caret at $offset');
      }
    });

    testWidgets('an empty block keeps a box the user can see', (tester) async {
      await mount(tester);
      final span = paint('```', selection: const TextSelection.collapsed(offset: 3));
      // Nothing readable...
      expect(_visibleText(span), isEmpty);
      // ...but the fence is still painted at full size in transparent ink, so
      // the block occupies a box instead of collapsing to nothing.
      TextSpan? fence;
      void walk(InlineSpan s) {
        if (s is TextSpan) {
          if (s.text == '```') fence ??= s;
          for (final c in s.children ?? const <InlineSpan>[]) {
            walk(c);
          }
        }
      }

      walk(span);
      expect(fence, isNotNull);
      expect(fence!.style?.fontSize, 14);
      expect(fence!.style?.color?.a, 0);
      expect(span.toPlainText(), '```');
    });

    testWidgets('a block with a body hides its fences outright',
        (tester) async {
      await mount(tester);
      final span = paint('```\ncode\n```',
          selection: const TextSelection.collapsed(offset: 5));
      TextSpan? fence;
      void walk(InlineSpan s) {
        if (s is TextSpan) {
          if (s.text == '```') fence ??= s;
          for (final c in s.children ?? const <InlineSpan>[]) {
            walk(c);
          }
        }
      }

      walk(span);
      expect(fence!.style?.fontSize, lessThan(1));
    });

    testWidgets('an unfocused field reveals nothing', (tester) async {
      await mount(tester);
      const text = '**bold**';
      final span = paint(text,
          selection: const TextSelection.collapsed(offset: 4), focused: false);
      expect(_visibleText(span), 'bold');
    });

    testWidgets('bold is painted bold and code is painted mono',
        (tester) async {
      await mount(tester);
      TextStyle? styleOf(TextSpan root, String text) {
        TextStyle? found;
        void walk(InlineSpan span) {
          if (span is TextSpan) {
            if (span.text == text) found ??= span.style;
            for (final child in span.children ?? const <InlineSpan>[]) {
              walk(child);
            }
          }
        }

        walk(root);
        return found;
      }

      expect(styleOf(paint('**b**'), 'b')?.fontWeight, FontWeight.w700);
      expect(styleOf(paint('*i*'), 'i')?.fontStyle, FontStyle.italic);
      expect(styleOf(paint('~~s~~'), 's')?.decoration,
          TextDecoration.lineThrough);
      expect(styleOf(paint('`c`'), 'c')?.fontFamily, kMonoFont);
      expect(styleOf(paint('# h'), 'h')?.fontWeight, FontWeight.w700);
      expect((styleOf(paint('# h'), 'h')?.fontSize ?? 0), greaterThan(14));
    });

    testWidgets('the draft still reaches the wire unchanged', (tester) async {
      await mount(tester);
      // The whole scheme is only safe if `text` is untouched by the painting.
      for (final (label, text) in _drafts) {
        final c = EmojiSentinelController(text: text);
        c.composerFocused = true;
        c.buildTextSpan(context: ctx, style: style, withComposing: false);
        expect(c.text, text, reason: label);
        expect(c.expand(c.text), text, reason: label);
      }
    });

    testWidgets('a custom emoji inside a formatted run still paints',
        (tester) async {
      await mount(tester);
      final c = EmojiSentinelController();
      c.codeToUrl = {'blob': 'https://x.test/blob.png'};
      c.value = const TextEditingValue(text: '**hi :blob:**');
      c.resolveInput();
      c.composerFocused = true;
      // The shortcode collapsed to one sentinel char, and the bold survived.
      expect(c.text, '**hi \u{E000}**');
      expect(c.expand(c.text), '**hi :blob:**');
      final span =
          c.buildTextSpan(context: ctx, style: style, withComposing: false);
      // A WidgetSpan is one character in the plain text, exactly like the
      // sentinel it replaced.
      expect(span.toPlainText().length, c.text.length);
      expect(_types(parseRichFormat(c.text)), ['bold']);
    });

    testWidgets('nothing is restyled while an IME is composing',
        (tester) async {
      await mount(tester);
      final c = EmojiSentinelController();
      c.composerFocused = true;
      c.value = const TextEditingValue(
        text: '**bold**',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 2, end: 6),
      );
      final span =
          c.buildTextSpan(context: ctx, style: style, withComposing: true);
      // The framework's own span, delimiters and all — an IME has enough to
      // contend with without the field rewriting itself underneath it.
      expect(_visibleText(span), '**bold**');
    });
  });
}

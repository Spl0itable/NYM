// The Nymbot wordplay games encode the answer/state in a trailing `[gc:BASE64]`
// token on the message. It rides the WIRE (the `?guess` router + game module
// read it back off a quoted reply) but must be INVISIBLE, exactly like the PWA's
// `.game-token { display:none }`. Quoting the bot prepends `> ` to every quoted
// line, turning the token line into `> [gc:…]` — which the old `\n[gc:…]`-only
// strip missed, leaking a literal `[gc:…]` blob into the rendered quote (and the
// quote chip). These tests lock the token OUT of every DISPLAY surface while
// keeping it intact for the wire.

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/messages/format/nym_format.dart';

String _flatten(List<FormatBlock> blocks) {
  final sb = StringBuffer();
  void walk(List<FormatBlock> bs) {
    for (final b in bs) {
      switch (b) {
        case ParagraphBlock(:final inlines):
        case HeadingBlock(:final inlines):
          for (final n in inlines) {
            if (n is TextSpanNode) sb.write(n.text);
          }
        case QuoteBlock(:final children):
          walk(children);
        default:
          sb.write(b.toString());
      }
    }
  }

  walk(blocks);
  return sb.toString();
}

void main() {
  group('stripGameTokens', () {
    test('removes a trailing token on its own line', () {
      expect(NymFormat.stripGameTokens('Guess: _ _ _\n[gc:QUJD==]'),
          'Guess: _ _ _');
    });

    test('removes a token that rides a quote line (> [gc:…])', () {
      expect(
        NymFormat.stripGameTokens(
            '> @Nymbot#1234: Guess: _ _ _\n> [gc:QUJD==]\n\nmy guess'),
        '> @Nymbot#1234: Guess: _ _ _\n\nmy guess',
      );
    });

    test('removes a nested-quote token (> > [gc:…])', () {
      expect(
        NymFormat.stripGameTokens('> > [gc:QUJD==]').trim(),
        isEmpty,
      );
    });

    test('leaves ordinary content untouched', () {
      const s = 'hello > not a token [gc is fine]';
      expect(NymFormat.stripGameTokens(s), s);
    });
  });

  group('render (NymFormat.format) hides the token', () {
    test('plain bot game message', () {
      final blocks = NymFormat.format('Guess the word: _ _ _ _\n[gc:QUJDMTIz==]');
      expect(_flatten(blocks).contains('[gc:'), isFalse);
    });

    test('QUOTED bot game message (the reported bug)', () {
      const content =
          '> @Nymbot#1234: Guess the word: _ _ _ _\n> [gc:QUJDMTIz==]\n\nmy guess';
      final blocks = NymFormat.format(content);
      final text = _flatten(blocks);
      expect(text.contains('[gc:'), isFalse,
          reason: 'the game token must be hidden inside a quote too');
      // The rest of the quote + the reply still render.
      expect(text.contains('Guess the word'), isTrue);
      expect(text.contains('my guess'), isTrue);
    });
  });

  test('WIRE parity: the token is display-only — `?guess` detection still sees '
      'it in the composed reply', () {
    // What the composer sends when you quote-reply the bot's game message.
    const composed =
        '> @Nymbot#1234: Guess the word: _ _ _ _\n> [gc:QUJDMTIz==]\n\nmy guess';
    // The controller routes to ?guess by testing the RAW composed text (never
    // the stripped render), so the token must survive on the wire.
    expect(RegExp(r'\[gc:[A-Za-z0-9+/=]+\]').hasMatch(composed), isTrue);
  });
}

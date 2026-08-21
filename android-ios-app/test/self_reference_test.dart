// The two ways an inbound message can be addressed to you, and the ways it
// must NOT count as addressed.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/notifications/self_reference.dart';

void main() {
  const nym = 'luxas';
  const suffix = 'ab12';

  bool refers(String content) =>
      mentionsSelf(content: content, nym: nym, suffix: suffix) ||
      quotesSelf(content: content, nym: nym, suffix: suffix);

  group('mentionsSelf', () {
    test('plain and suffixed mentions', () {
      expect(mentionsSelf(content: 'hey @luxas look', nym: nym, suffix: suffix),
          true);
      expect(
          mentionsSelf(content: 'hey @luxas#ab12', nym: nym, suffix: suffix),
          true);
      expect(mentionsSelf(content: 'HEY @LUXAS', nym: nym, suffix: suffix),
          true);
    });

    test('a same-named stranger does not match', () {
      expect(mentionsSelf(content: 'yo @luxas#ffff', nym: nym, suffix: suffix),
          false);
    });

    test('a mention inside a quote is not addressed to us', () {
      // Someone quoting a message that mentioned us is talking to the person
      // they quoted, not to us.
      expect(
        mentionsSelf(
          content: '> @bob#0001: hi @luxas\n\nagreed',
          nym: nym,
          suffix: suffix,
        ),
        false,
      );
    });
  });

  group('quotesSelf', () {
    // The reported bug: replying by quoting, without typing the name, notified
    // nobody — the only reference lives in the line the mention scan skips.
    test('a quote reply to our message counts', () {
      const content = '> @luxas#ab12: my original message\n\nnice one';
      expect(quotesSelf(content: content, nym: nym, suffix: suffix), true);
      expect(mentionsSelf(content: content, nym: nym, suffix: suffix), false,
          reason: 'which is exactly why quotesSelf has to exist');
      expect(refers(content), true);
    });

    test('multi-line quotes and an unsuffixed label', () {
      expect(
        quotesSelf(
          content: '> @luxas: first line\n> second line\n\nreply',
          nym: nym,
          suffix: suffix,
        ),
        true,
      );
      // The renderer tolerates a doubled suffix, so this must too.
      expect(
        quotesSelf(
          content: '> @luxas#ab12#ab12: hi\n\nreply',
          nym: nym,
          suffix: suffix,
        ),
        true,
      );
    });

    test('quoting someone else is not a reply to us', () {
      expect(
        quotesSelf(
          content: '> @bob#0001: something\n\nreply',
          nym: nym,
          suffix: suffix,
        ),
        false,
      );
      // Same base name, different person.
      expect(
        quotesSelf(
          content: '> @luxas#ffff: something\n\nreply',
          nym: nym,
          suffix: suffix,
        ),
        false,
      );
    });

    test('a nested quote is second-hand and does not notify', () {
      // Bob quoted Carol quoting us: Bob is replying to Carol.
      expect(
        quotesSelf(
          content: '> @carol#0002: > @luxas#ab12: original\n\nreply',
          nym: nym,
          suffix: suffix,
        ),
        false,
      );
      expect(
        quotesSelf(
          content: '>> @luxas#ab12: original\n\nreply',
          nym: nym,
          suffix: suffix,
        ),
        false,
      );
    });

    test('a quote body that merely says our name is not a reply to us', () {
      expect(
        quotesSelf(
          content: '> @bob#0001: I was talking to @luxas earlier\n\nreply',
          nym: nym,
          suffix: suffix,
        ),
        false,
      );
    });

    test('malformed quote lines are ignored, not crashed on', () {
      for (final content in [
        '> no author here\n\nreply',
        '> @luxas no colon\n\nreply',
        '>\n\nreply',
        '> @: empty\n\nreply',
      ]) {
        expect(quotesSelf(content: content, nym: nym, suffix: suffix), false,
            reason: content);
      }
    });
  });
}

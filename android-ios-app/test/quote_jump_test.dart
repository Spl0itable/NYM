// Tapping a quoted block jumps to the message it quotes. The matcher compares
// the quote as PARSED (markdown markers consumed, paragraphs joined) against
// the stored SOURCE text, so for a long time it only ever resolved plain,
// single-line prose — anything bold, multi-line, or code-formatted reported
// its original as missing ("Original message is not available" in the PWA).
// These run real quotes through the real parser and lock in the match.

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/i18n/app_strings_catalog.dart';
import 'package:nym_bar/features/messages/format/message_content.dart';
import 'package:nym_bar/features/messages/format/nym_format.dart';
import 'package:nym_bar/models/message.dart';

const _alicePk =
    '0000000000000000000000000000000000000000000000000000000000001a2b';
const _bobPk =
    '00000000000000000000000000000000000000000000000000000000000099ff';

Message _msg(String id, String pubkey, String author, String content) =>
    Message(
      id: id,
      pubkey: pubkey,
      author: author,
      content: content,
      createdAt: 1700000000,
    );

/// What the composer publishes when Bob quote-replies to one of Alice's
/// messages: her content as `> ` lines under a `> @alice#1a2b:` header.
String _quoting(String original) {
  final lines = original.split('\n');
  final quoted = ['> @alice#1a2b: ${lines[0]}', ...lines.skip(1).map((l) => '> $l')]
      .join('\n');
  return '$quoted\n\nsure thing';
}

/// The top-level QuoteBlock of that reply, as the tapped widget sees it.
QuoteBlock _quoteBlockFor(String original) =>
    NymFormat.format(_quoting(original)).whereType<QuoteBlock>().first;

void main() {
  group('resolveQuotedMessage finds the original', () {
    final cases = <String, String>{
      'plain prose': 'hey what is up',
      'bold mid-sentence': 'this is **really** important',
      'italic and strikethrough': 'a _word_ and ~~gone~~',
      'inline code': 'run `npm test` first',
      'a link': 'see https://example.com/page for details',
      'a suffixed mention': 'hey @bob#99ff can you look',
      'a channel reference': 'meet in #dr5r later',
      'multi-line': 'first line\nsecond line',
      'multi-line with bold': 'alpha\n**beta** here\ngamma',
      'a heading': '# big news everyone',
      'non-Latin with bold': 'это **очень** важно',
      'japanese': 'これは重要です',
      'emoji only': '🎉🎉🎉',
    };

    cases.forEach((label, original) {
      test(label, () {
        final target = _msg('orig', _alicePk, 'alice', original);
        final found = resolveQuotedMessage(
          _quoteBlockFor(original),
          [target, _msg('other', _alicePk, 'alice', 'completely unrelated line')],
          hostMessageId: 'reply',
        );
        expect(found?.id, 'orig', reason: '$label should resolve to its source');
      });
    });
  });

  group('resolveQuotedMessage stays discriminating', () {
    test('an unrelated message by the quoted author is not a match', () {
      final found = resolveQuotedMessage(
        _quoteBlockFor('this is **really** important'),
        [_msg('other', _alicePk, 'alice', 'nothing like it at all')],
      );
      expect(found, isNull);
    });

    test('the same text from a different author is not a match', () {
      final found = resolveQuotedMessage(
        _quoteBlockFor('hey what is up'),
        [_msg('bobs', _bobPk, 'bob', 'hey what is up')],
      );
      expect(found, isNull);
    });

    test('the notice shown when it resolves to nothing is translatable', () {
      // The tap now reports the dead end instead of swallowing it (PWA
      // parity); a notice only English speakers can read is not a notice.
      expect(kAppStringsCatalog, contains('Original message is not available'));
    });

    test('the quoting message itself is excluded', () {
      final original = 'hey what is up';
      final found = resolveQuotedMessage(
        _quoteBlockFor(original),
        [_msg('reply', _alicePk, 'alice', _quoting(original))],
        hostMessageId: 'reply',
      );
      expect(found, isNull);
    });
  });
}

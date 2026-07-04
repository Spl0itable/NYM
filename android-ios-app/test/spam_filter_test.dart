import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/messages/spam_filter.dart';

/// Unit coverage for the heuristic content spam filter
/// (`lib/features/messages/spam_filter.dart`), a 1:1 port of the PWA's
/// `isSpamMessage` / `_spamScore` family (`js/modules/nostr-core.js:806-940`).
///
/// The filter defaults to `enabled: true, aggressive: true` (PWA app.js:559-560).
void main() {
  group('isSpamMessage — gate', () {
    test('returns false when the filter is disabled', () {
      // Even a blatant known-spam string passes when the whole filter is off.
      expect(
        SpamFilter.isSpamMessage(
          'gm joined the channel via bitchat.land',
          enabled: false,
        ),
        isFalse,
      );
    });

    test('non-string content is never spam', () {
      expect(SpamFilter.isSpamMessage(null), isFalse);
      expect(SpamFilter.isSpamMessage(42), isFalse);
      expect(SpamFilter.isSpamMessage(<String>['x']), isFalse);
    });
  });

  group('isSpamMessage — known-spam strings (fire even when aggressive off)', () {
    test('"joined the channel via bitchat.land" is always spam', () {
      expect(SpamFilter.isSpamMessage('joined the channel via bitchat.land'),
          isTrue);
      // The known-spam check sits BEFORE the `aggressive === false` short-circuit.
      expect(
        SpamFilter.isSpamMessage('joined the channel via bitchat.land',
            aggressive: false),
        isTrue,
      );
    });

    test('the chorus client tag is always spam', () {
      expect(SpamFilter.isSpamMessage('["client","chorus"]'), isTrue);
      expect(
        SpamFilter.isSpamMessage('["client","chorus"]', aggressive: false),
        isTrue,
      );
    });

    test('aggressive=false lets everything else through', () {
      // A gibberish token that IS spam in aggressive mode is allowed when the
      // aggressive heuristics are switched off (only the two literals remain).
      expect(
        SpamFilter.isSpamMessage('Xq7zkwjpQmbvxz', aggressive: false),
        isFalse,
      );
    });
  });

  group('isSpamMessage — early-return guards (NOT spam)', () {
    test('a URL is never spam', () {
      expect(SpamFilter.isSpamMessage('check https://example.com/foo'), isFalse);
      expect(SpamFilter.isSpamMessage('www.example.com'), isFalse);
    });

    test('a lightning invoice is never spam', () {
      // lnbc / lntb / lnts prefixes (case-insensitive).
      expect(
        SpamFilter.isSpamMessage(
            'lnbc20m1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypq'),
        isFalse,
      );
      expect(SpamFilter.isSpamMessage('LNTB1234567890ABCDEF'), isFalse);
    });

    test('a cashu token is never spam', () {
      expect(
        SpamFilter.isSpamMessage('cashuAeyJ0b2tlbnMiOlt7InByb29mcyI6W10'),
        isFalse,
      );
    });

    test('a bare nostr identifier is never spam', () {
      expect(
        SpamFilter.isSpamMessage(
            'npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m'),
        isFalse,
      );
    });

    test('a bare 64-hex string is never spam', () {
      expect(
        SpamFilter.isSpamMessage(
            '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d'),
        isFalse,
      );
    });

    test('a fenced or inline code block is never spam', () {
      expect(
        SpamFilter.isSpamMessage('```\nXq7zkwjpQmbvxz hgfzpqkx\n```'),
        isFalse,
      );
      expect(SpamFilter.isSpamMessage('run `Xq7zkwjpQmbvxz` now'), isFalse);
    });

    test('a data:image payload is never spam', () {
      expect(
        SpamFilter.isSpamMessage('data:image/png;base64,iVBORw0KGgoAAAANS'),
        isFalse,
      );
    });

    test('very short content (<6 chars) is never spam', () {
      expect(SpamFilter.isSpamMessage('Xq7zk'), isFalse);
    });
  });

  group('isSpamMessage — normal chat is NOT spam', () {
    test('a plain English sentence is not spam', () {
      expect(
        SpamFilter.isSpamMessage('hey everyone, how is your day going?'),
        isFalse,
      );
    });

    test('a friendly multi-word greeting is not spam', () {
      expect(
        SpamFilter.isSpamMessage('good morning, welcome to the channel!'),
        isFalse,
      );
    });

    test('a lone emoji is normal chat, never spam', () {
      expect(SpamFilter.isSpamMessage('that is hilarious \u{1F602}'), isFalse);
    });

    test('an @mention with a digit suffix does not trip the filter', () {
      // The scrub strips @mentions before scoring, so the digit-heavy #suffix
      // can not push the score up (nostr-core.js:932-934).
      expect(
        SpamFilter.isSpamMessage('thanks @alice#3729 for the help!'),
        isFalse,
      );
    });

    test('a quoted (>-prefixed) line is excluded from scoring', () {
      // The quoted gibberish line is dropped; only "agreed" is scored.
      expect(
        SpamFilter.isSpamMessage('> Xq7zkwjpQmbvxz hgfzpqkx jxzkqp\nagreed'),
        isFalse,
      );
    });
  });

  group('isSpamMessage — gibberish / random tokens ARE spam', () {
    test('a single random alphanumeric token is spam', () {
      // Low vowels + rare bigrams + q-not-u + digit/alpha mix → score >= 3.
      expect(SpamFilter.isSpamMessage('Xq7zkwjpQmbvxz'), isTrue);
    });

    test('a long all-alphanumeric blob (>100 chars) is spam', () {
      final blob = 'a' * 120; // > 100, only-alphanumeric, length > 100
      expect(SpamFilter.isSpamMessage(blob), isTrue);
    });

    test('mostly-gibberish multi-word content is spam', () {
      // All three len>=6 tokens look random → gibberish/analyzable = 1.0 → +3.
      // (Inputs cross-checked against the reference JS `isSpamMessage`.)
      expect(
        SpamFilter.isSpamMessage('jXzKqpWmbv hQzKjxWpbv kXzQjpWmbv'),
        isTrue,
      );
    });
  });

  group('isSpamMessage — repeated-token spam', () {
    test('the same token repeated is spam', () {
      // Identical >=6-char alphanumeric token repeated (nostr-core.js:777-781).
      expect(SpamFilter.isSpamMessage('FREE88 FREE88 FREE88 FREE88'), isTrue);
    });

    test('a token built from a repeated base unit is spam', () {
      // A single 12+ char token that is its own head repeated twice with >=3
      // distinct head chars (nostr-core.js:796-802).
      expect(SpamFilter.isSpamMessage('abcdefabcdef'), isTrue);
    });
  });

  group('isSpamMessage — mixed-script tokens ARE spam', () {
    test('a Latin+Cyrillic homoglyph token is flagged', () {
      // "paypal" with Cyrillic 'а' (U+0430) and 'р' (U+0440) mixed into Latin —
      // a >=4-char token with two scripts and >=60% letters → +2, and combined
      // with another signal crosses the threshold. Pair it with a random token
      // so the score reaches >= 3.
      const cyrA = '\u0430'; // CYRILLIC SMALL A
      const cyrR = '\u0440'; // CYRILLIC SMALL ER
      final token = 'p${cyrA}yp${cyrR}l'; // mixed-script "paypal"
      // Paired with two random tokens (all three analyzable tokens look random
      // -> +3) plus the mixed-script +2, the score reaches 5. (Cross-checked
      // against the reference JS isSpamMessage.)
      expect(
        SpamFilter.isSpamMessage('$token jXzKqpWmbv hQzKjxWpbv'),
        isTrue,
      );
      expect(SpamFilter.spamScore('$token jXzKqpWmbv hQzKjxWpbv'),
          greaterThanOrEqualTo(5));
    });
  });

  group('spamScore — direct probes', () {
    test('a normal short word scores below the threshold', () {
      expect(SpamFilter.spamScore('hello there friend'), lessThan(3));
    });

    test('a random single token scores at or above the threshold', () {
      expect(SpamFilter.spamScore('Xq7zkwjpQmbvxz'),
          greaterThanOrEqualTo(3));
    });

    test('repeated identical tokens add the repeat-spam weight', () {
      expect(SpamFilter.spamScore('FREE88 FREE88 FREE88'),
          greaterThanOrEqualTo(3));
    });

    test('zero-width characters are stripped before scoring', () {
      // Embedding a zero-width space inside a random token must not let it
      // dodge the single-token analysis (the token is reassembled after strip).
        const zwsp = '\u200B'; // ZERO WIDTH SPACE
      expect(
        SpamFilter.spamScore('Xq7zk${zwsp}wjpQmbvxz'),
        greaterThanOrEqualTo(3),
      );
    });

    test('a digit-heavy string adds a point', () {
      // >50% digits over >=8 chars, with at least one letter → +1 (not alone
      // enough to flag, but the score should reflect the signal).
      expect(SpamFilter.spamScore('1234567a'), greaterThanOrEqualTo(1));
    });
  });

  group('isGibberishNym — randomized spam-bot nicknames', () {
    test('null / non-string nyms are never gibberish', () {
      // Mirrors the PWA `typeof nym !== 'string'` guard (nostr-core.js:946).
      expect(SpamFilter.isGibberishNym(null), isFalse);
      expect(SpamFilter.isGibberishNym(42), isFalse);
    });

    test('short nyms (<8 chars after trim) are never gibberish', () {
      // nostr-core.js:948 `if (!n || n.length < 8) return false;`
      expect(SpamFilter.isGibberishNym('alice'), isFalse);
      expect(SpamFilter.isGibberishNym('   '), isFalse); // trims to empty
      expect(SpamFilter.isGibberishNym('aBCDEFG'), isFalse); // 7 chars
    });

    test('an ordinary nym is not gibberish', () {
      // All-lowercase real-word-ish handle: no repeated head, no upper → false.
      expect(SpamFilter.isGibberishNym('goodvibes'), isFalse);
      expect(SpamFilter.isGibberishNym('satoshifan'), isFalse);
    });

    test('a repeated-head random token is gibberish', () {
      // `_looksLikeRandomToken` repeated-head branch (nostr-core.js:753-759):
      // head 'abc' (>=3 distinct) repeated at offset 3.
      expect(SpamFilter.isGibberishNym('abcabcde'), isTrue);
    });

    test('an interior-uppercase random token is gibberish', () {
      // `_looksLikeRandomToken` interior-upper branch (nostr-core.js:761-769):
      // 6 interior uppercase, ratio 6/7 >= 0.3.
      expect(SpamFilter.isGibberishNym('aBCDEFGh'), isTrue);
    });

    test('leading/trailing whitespace is trimmed before the check', () {
      expect(SpamFilter.isGibberishNym('  abcabcde  '), isTrue);
    });

    test('respects the enabled / aggressive gates (both default true)', () {
      // Off when either gate is false, regardless of the nym (nostr-core.js:
      // 944-945).
      expect(SpamFilter.isGibberishNym('abcabcde', enabled: false), isFalse);
      expect(SpamFilter.isGibberishNym('abcabcde', aggressive: false), isFalse);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/messages/format/nym_format.dart';

/// Returns the single paragraph's inline nodes, asserting the result is one
/// [ParagraphBlock].
List<InlineNode> paraInlines(String content, [FormatContext? ctx]) {
  final blocks = NymFormat.format(content, ctx);
  expect(blocks, hasLength(1));
  expect(blocks.first, isA<ParagraphBlock>());
  return (blocks.first as ParagraphBlock).inlines;
}

void main() {
  group('inline markdown', () {
    test('bold parses to BoldNode', () {
      final inlines = paraInlines('a **bold** b');
      expect(inlines.whereType<BoldNode>(), hasLength(1));
      final b = inlines.whereType<BoldNode>().first;
      expect((b.children.single as TextSpanNode).text, 'bold');
    });

    test('__bold__ parses to BoldNode', () {
      final inlines = paraInlines('x __strong__ y');
      expect(inlines.whereType<BoldNode>(), hasLength(1));
    });

    test('italic parses to ItalicNode', () {
      final inlines = paraInlines('a *it* b');
      expect(inlines.whereType<ItalicNode>(), hasLength(1));
      expect(
        (inlines.whereType<ItalicNode>().first.children.single as TextSpanNode)
            .text,
        'it',
      );
    });

    test('strike parses to StrikeNode', () {
      final inlines = paraInlines('a ~~no~~ b');
      expect(inlines.whereType<StrikeNode>(), hasLength(1));
    });

    test('inline code parses to InlineCodeNode', () {
      final inlines = paraInlines('run `git status` now');
      final code = inlines.whereType<InlineCodeNode>();
      expect(code, hasLength(1));
      expect(code.first.code, 'git status');
    });
  });

  group('fenced code', () {
    test('captures lang and body', () {
      final blocks = NymFormat.format('```dart\nvoid main() {}\n```');
      final code = blocks.whereType<CodeBlock>();
      expect(code, hasLength(1));
      expect(code.first.lang, 'dart');
      expect(code.first.code, 'void main() {}');
    });

    test('unterminated fence still captures body', () {
      final blocks = NymFormat.format('```\nhello world');
      final code = blocks.whereType<CodeBlock>();
      expect(code, hasLength(1));
      expect(code.first.code, 'hello world');
    });
  });

  group('quotes', () {
    test('> @alice: hi becomes a QuoteBlock with author alice', () {
      final blocks = NymFormat.format('> @alice: hi');
      expect(blocks, hasLength(1));
      final q = blocks.first as QuoteBlock;
      expect(q.author, 'alice');
      // The quoted body should contain the text "hi".
      final para = q.children.whereType<ParagraphBlock>().first;
      expect(
        para.inlines.whereType<TextSpanNode>().any((t) => t.text.contains('hi')),
        isTrue,
      );
    });

    test('plain > quote has no author', () {
      final blocks = NymFormat.format('> just a quote');
      final q = blocks.first as QuoteBlock;
      expect(q.author, isNull);
    });
  });

  group('mentions and channels', () {
    test('@bob#1a2b -> MentionNode(base @bob, suffix 1a2b)', () {
      final inlines = paraInlines('hi @bob#1a2b there');
      final m = inlines.whereType<MentionNode>().first;
      expect(m.base, '@bob');
      expect(m.suffix, '1a2b');
    });

    test('@carol -> MentionNode without suffix', () {
      final inlines = paraInlines('yo @carol');
      final m = inlines.whereType<MentionNode>().first;
      expect(m.base, '@carol');
      expect(m.suffix, isNull);
    });

    test('multi-word nym with suffix -> ONE mention chip (spaces allowed)', () {
      final inlines = paraInlines('hey @John Doe#a1b2 how are you');
      final mentions = inlines.whereType<MentionNode>().toList();
      expect(mentions.length, 1);
      expect(mentions.first.base, '@John Doe');
      expect(mentions.first.suffix, 'a1b2');
    });

    test('two suffixed mentions on a line each resolve, spaces intact', () {
      final inlines = paraInlines('@al pha#c3fa and @be ta#d15d done');
      final mentions = inlines.whereType<MentionNode>().toList();
      expect(mentions.map((m) => '${m.base}#${m.suffix}'),
          ['@al pha#c3fa', '@be ta#d15d']);
    });

    test('a space right before the #suffix is not swallowed', () {
      // "@John #a1b2" is NOT a suffixed mention (trailing space guard); the
      // bare "@John" still chips as a simple mention.
      final inlines = paraInlines('@John #a1b2');
      final m = inlines.whereType<MentionNode>().first;
      expect(m.base, '@John');
      expect(m.suffix, isNull);
    });

    test('#9q8y -> geohash channel ref', () {
      final inlines = paraInlines('see #9q8y now');
      final ch = inlines.whereType<ChannelRefNode>().first;
      expect(ch.name, '9q8y');
      expect(ch.isGeohash, isTrue);
    });

    test('#bitcoin -> named channel ref', () {
      final inlines = paraInlines('join #bitcoin yo');
      final ch = inlines.whereType<ChannelRefNode>().first;
      expect(ch.name, 'bitcoin');
      expect(ch.isGeohash, isFalse);
    });

    test('active channel detection', () {
      final inlines = paraInlines(
        'in #bitcoin',
        const FormatContext(currentChannel: 'bitcoin'),
      );
      final ch = inlines.whereType<ChannelRefNode>().first;
      expect(ch.isActive, isTrue);
    });

    test('collapses @name#xxxx#xxxx', () {
      final inlines = paraInlines('@dan#abcd#abcd');
      final m = inlines.whereType<MentionNode>().first;
      expect(m.base, '@dan');
      expect(m.suffix, 'abcd');
    });
  });

  group('emoji', () {
    test(':fire: -> EmojiNode unicode', () {
      final inlines = paraInlines('so :fire: hot');
      final e = inlines.whereType<EmojiNode>().first;
      expect(e.unicode, '🔥');
    });

    test('custom :shortcode: -> CustomEmojiNode when not a builtin', () {
      // PWA order (message-format.js:251-257): the builtin emojiMap is tried
      // FIRST; a custom emoji only resolves for a shortcode that is NOT a
      // builtin. `:fire:` is a builtin (🔥) so it would win even with a custom
      // `fire` registered — use a non-builtin code to exercise the custom path.
      final inlines = paraInlines(
        'so :partyblob: hot',
        const FormatContext(
          customEmojis: {'partyblob': 'https://cdn/partyblob.png'},
        ),
      );
      expect(inlines.whereType<CustomEmojiNode>(), hasLength(1));
      expect(inlines.whereType<CustomEmojiNode>().first.url,
          'https://cdn/partyblob.png');
    });

    test('builtin :shortcode: beats a same-named custom emoji (PWA order)', () {
      final inlines = paraInlines(
        'so :fire: hot',
        const FormatContext(
          customEmojis: {'fire': 'https://cdn/fire.png'},
        ),
      );
      expect(inlines.whereType<EmojiNode>().first.unicode, '🔥');
      expect(inlines.whereType<CustomEmojiNode>(), isEmpty);
    });

    test('ASCII smiley :) -> EmojiNode', () {
      final inlines = paraInlines('hello :) world');
      final e = inlines.whereType<EmojiNode>().first;
      expect(e.unicode, '😊');
    });

    test('unknown :shortcode: left as text', () {
      final inlines = paraInlines('a :notanemoji: b');
      expect(inlines.whereType<EmojiNode>(), isEmpty);
      expect(inlines.whereType<CustomEmojiNode>(), isEmpty);
      expect(
        inlines.whereType<TextSpanNode>().any((t) => t.text.contains(':notanemoji:')),
        isTrue,
      );
    });
  });

  group('media and links', () {
    test('image URL -> MediaBlock', () {
      final blocks = NymFormat.format('look https://x.com/a.png');
      final media = blocks.whereType<MediaBlock>();
      expect(media, hasLength(1));
      final item = media.first.items.single;
      expect(item.isVideo, isFalse);
      expect(item.url, 'https://x.com/a.png');
    });

    test('video URL -> MediaBlock video item', () {
      final blocks = NymFormat.format('https://x.com/clip.mp4');
      final item = blocks.whereType<MediaBlock>().first.items.single;
      expect(item.isVideo, isTrue);
    });

    test('adjacent images collapse into a gallery', () {
      final blocks =
          NymFormat.format('https://x.com/a.png https://x.com/b.png');
      final media = blocks.whereType<MediaBlock>();
      expect(media, hasLength(1));
      expect(media.first.items, hasLength(2));
    });

    test('plain URL -> LinkNode', () {
      final inlines = paraInlines('visit https://example.com today');
      final link = inlines.whereType<LinkNode>();
      expect(link, hasLength(1));
      expect(link.first.url, 'https://example.com');
    });

    test('app.nym.bar channel link -> ChannelLinkChip', () {
      final inlines = paraInlines('join https://app.nym.bar/#g:9q8y now');
      final chip = inlines.whereType<ChannelLinkChip>();
      expect(chip, hasLength(1));
      expect(chip.first.ref, 'g:9q8y');
    });
  });

  group('headings', () {
    test('## heading -> HeadingBlock level 2', () {
      final blocks = NymFormat.format('## Title');
      final h = blocks.whereType<HeadingBlock>().first;
      expect(h.level, 2);
      expect((h.inlines.single as TextSpanNode).text, 'Title');
    });
  });

  group('fast path', () {
    test('plain multi-line text -> ONE paragraph preserving newlines', () {
      // PWA fast path (message-format.js:89-91) returns the content as a single
      // run with `\n` -> `<br>` (blank lines preserved as consecutive breaks),
      // NOT split into separate paragraph blocks.
      final blocks = NymFormat.format('line one\n\nline two');
      expect(blocks, hasLength(1));
      final p = blocks.single as ParagraphBlock;
      expect(p.inlines, everyElement(isA<TextSpanNode>()));
      expect((p.inlines.single as TextSpanNode).text, 'line one\n\nline two');
    });

    test('single plain line -> one paragraph', () {
      final blocks = NymFormat.format('just hello world');
      expect(blocks, hasLength(1));
      expect(blocks.first, isA<ParagraphBlock>());
    });
  });
}

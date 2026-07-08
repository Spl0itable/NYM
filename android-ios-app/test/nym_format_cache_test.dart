import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/messages/format/nym_format.dart';

void main() {
  group('parse cache memoization', () {
    test('identical (content,ctx) returns the SAME cached instance', () {
      NymFormat.clearParseCache();
      final a = NymFormat.format('hello **world** @bob:smile:');
      final b = NymFormat.format('hello **world** @bob:smile:');
      expect(identical(a, b), isTrue,
          reason: 'second call must hit the cache and return same list');
    });

    test('different content is not confused across cache entries', () {
      NymFormat.clearParseCache();
      final a = NymFormat.format('a **bold** b');
      final b = NymFormat.format('c *ital* d');
      expect(identical(a, b), isFalse);
      expect((a.first as ParagraphBlock).inlines.whereType<BoldNode>(), hasLength(1));
      expect((b.first as ParagraphBlock).inlines.whereType<ItalicNode>(), hasLength(1));
    });

    test('different customEmojis identity produces a cache miss (fresh parse)', () {
      NymFormat.clearParseCache();
      const content = 'say :smile:';
      final ctx1 = FormatContext(customEmojis: const {'smile': 'https://x/1.png'});
      final ctx2 = FormatContext(customEmojis: {'smile': 'https://x/2.png'});
      final r1 = NymFormat.format(content, ctx1);
      final r2 = NymFormat.format(content, ctx2);
      expect(identical(r1, r2), isFalse,
          reason: 'a different emoji map instance must not reuse the cached parse');
    });

    test('same ctx object reused across calls hits cache', () {
      NymFormat.clearParseCache();
      final ctx = FormatContext(customEmojis: const {'smile': 'https://x/1.png'});
      final r1 = NymFormat.format('hi :smile:', ctx);
      final r2 = NymFormat.format('hi :smile:', ctx);
      expect(identical(r1, r2), isTrue);
    });

    test('cache is bounded (no unbounded growth) — many uniques still parse correctly', () {
      NymFormat.clearParseCache();
      for (var i = 0; i < 2000; i++) {
        final blocks = NymFormat.format('msg number $i with *emphasis*');
        expect(blocks, isNotEmpty);
      }
      // A previously-evicted entry re-parses correctly (not corrupted).
      final again = NymFormat.format('msg number 0 with *emphasis*');
      expect((again.first as ParagraphBlock).inlines.whereType<ItalicNode>(), hasLength(1));
    });
  });
}

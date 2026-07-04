import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/emoji/custom_emoji.dart';
import 'package:nym_bar/features/emoji/emoji_data.dart';
import 'package:nym_bar/features/emoji/emoji_picker.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';

void main() {
  group('emoji_data', () {
    test('categories are non-empty and in the PWA order', () {
      // Order matches `allEmojis` in js/app.js:780.
      expect(kEmojiCategoryOrder, <String>[
        'smileys', 'people', 'gestures', 'hearts', 'symbols', 'objects',
        'clothing', 'nature', 'food', 'activities', 'travel', 'weather', 'flags',
      ]);
      for (final cat in kEmojiCategoryOrder) {
        expect(kEmojisByCategory[cat], isNotNull, reason: '$cat present');
        expect(kEmojisByCategory[cat]!, isNotEmpty, reason: '$cat non-empty');
      }
      // Map iteration order equals the declared category order.
      expect(kEmojisByCategory.keys.toList(), kEmojiCategoryOrder);
    });

    test('known shortcodes and emoji are present', () {
      expect(kEmojisByCategory['smileys']!.first, '😀');
      expect(kEmojiShortcodeMap['smile'], '😊');
      expect(kEmojiShortcodeMap['thumbsup'], '👍');
      expect(kEmojiShortcodeMap['rocket'], '🚀');
      // Built-in unicode set contains a flag and a heart.
      expect(kEmojisByCategory['hearts']!.contains('❤️'), isTrue);
      expect(kEmojisByCategory['flags']!.contains('🇺🇸'), isTrue);
    });

    test('emoji->names reverse index resolves multiple names', () {
      final byEmoji = buildEmojiToNames();
      expect(byEmoji['👍'], contains('thumbsup'));
      expect(byEmoji['😊'], contains('smile'));
    });
  });

  group('recents', () {
    test('addRecentEmoji is most-recent-first and de-duplicates', () {
      var list = <String>[];
      list = addRecentEmoji(list, '😀');
      list = addRecentEmoji(list, '😂');
      list = addRecentEmoji(list, '😀'); // re-adding moves to front
      expect(list, ['😀', '😂']);
    });

    test('addRecentEmoji caps at 24', () {
      var list = <String>[];
      for (var i = 0; i < 40; i++) {
        list = addRecentEmoji(list, 'e$i');
      }
      expect(list.length, kRecentEmojisCap);
      // Newest is at the front.
      expect(list.first, 'e39');
    });

    test('EmojiRecentsStore persists and reloads via SharedPreferences',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = EmojiRecentsStore(prefs);

      expect(store.load(), isEmpty);
      await store.add('😀');
      final after = await store.add('😂');
      expect(after, ['😂', '😀']);

      // A fresh store reads the same persisted list (key nym_recent_emojis).
      expect(EmojiRecentsStore(prefs).load(), ['😂', '😀']);
    });
  });

  group('custom emoji cache', () {
    test('loads loose map + packs, never shadowing built-in shortcodes',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        // [shortcode, url] pairs (nym_custom_emojis).
        'nym_custom_emojis':
            '[["partyparrot","https://e.example/parrot.gif"],'
            // `smile` is a built-in unicode shortcode -> must be ignored.
            '["smile","https://e.example/should-be-ignored.gif"],'
            // invalid url scheme -> ignored.
            '["bad","ftp://nope"]]',
        'nym_custom_emoji_packs':
            '[{"pubkey":"abc","identifier":"pack1","title":"Pack One",'
            '"created_at":100,"emojis":[{"shortcode":"blobcat",'
            '"url":"https://e.example/blob.gif"}]}]',
      });
      final prefs = await SharedPreferences.getInstance();
      final state = loadCustomEmojiState(prefs);

      expect(state.codeToUrl['partyparrot'], 'https://e.example/parrot.gif');
      expect(state.codeToUrl.containsKey('smile'), isFalse);
      expect(state.codeToUrl.containsKey('bad'), isFalse);
      expect(state.codeToUrl['blobcat'], 'https://e.example/blob.gif');
      expect(state.packs, hasLength(1));
      expect(state.packs.single.title, 'Pack One');
    });

    test('proxiedEmojiUrl passes through when no proxy base', () {
      expect(proxiedEmojiUrl('https://x/y.gif', null), 'https://x/y.gif');
      expect(
        proxiedEmojiUrl('https://x/y.gif', 'https://proxy'),
        contains('?emoji=1&url='),
      );
    });
  });

  group('EmojiPicker widget', () {
    testWidgets('renders a category tab and taps an emoji', (tester) async {
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );

      String? captured;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [keyValueStoreProvider.overrideWithValue(kv)],
          child: MaterialApp(
            theme: buildNymThemeData(colors),
            home: Scaffold(
              body: Center(
                child: EmojiPicker(
                  recents: const ['😀'],
                  onSelect: (e) => captured = e,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // A default category title is rendered (uppercased, like the PWA).
      expect(find.text('SMILEYS'), findsOneWidget);
      // Recently Used section appears because a recent was supplied.
      expect(find.text('RECENTLY USED'), findsOneWidget);

      // Tapping the first grinning face fires the insertion callback.
      await tester.tap(find.text('😀').first);
      await tester.pump();
      expect(captured, '😀');
    });

    testWidgets('search filters to matching names', (tester) async {
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [keyValueStoreProvider.overrideWithValue(kv)],
          child: MaterialApp(
            theme: buildNymThemeData(colors),
            home: Scaffold(
              body: Center(
                child: EmojiPicker(recents: const [], onSelect: (_) {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'rocket');
      await tester.pumpAndSettle();

      // Travel category survives (holds 🚀), smileys is filtered out.
      expect(find.text('🚀'), findsWidgets);
      expect(find.text('SMILEYS'), findsNothing);
    });
  });
}

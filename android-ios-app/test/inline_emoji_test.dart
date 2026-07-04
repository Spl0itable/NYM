// Tests for [InlineEmojiText] — the lightweight shortcode→image renderer used by
// reaction badges, the reactors sheet, and the notifications panel. A NIP-30
// `:shortcode:` must resolve to an inline image (not literal text); unicode /
// unknown tokens stay plain text.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/features/emoji/emoji_prefetch.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/emoji/custom_emoji.dart';
import 'package:nym_bar/features/messages/format/message_content.dart';
import 'package:nym_bar/features/messages/inline_network_image.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';

Future<void> _pump(
  WidgetTester tester,
  String text, {
  Map<String, String> customEmojis = const {},
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final kv = KeyValueStore(prefs);
  final colors = resolveNymColors(
    theme: NymThemeKey.bitchat,
    brightness: Brightness.dark,
    solidUi: true,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        nymColorsProvider.overrideWithValue(colors),
        if (customEmojis.isNotEmpty)
          liveCustomEmojiProvider.overrideWith(
            (ref) => _SeededEmojiNotifier(ref, customEmojis),
          ),
      ],
      child: MaterialApp(
        theme: buildNymThemeData(colors),
        home: Scaffold(
          body: InlineEmojiText(
            text: text,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // Custom-emoji ingest arms a module-global deferred prefetch Timer; cancel
  // it so widget tests don't fail on a pending timer at teardown.
  tearDown(resetCustomEmojiPrefetchForTest);
  testWidgets('a known :shortcode: reaction renders an inline image',
      (tester) async {
    await _pump(
      tester,
      ':partyblob: 3',
      customEmojis: {'partyblob': 'https://cdn.example/partyblob.png'},
    );
    // The shortcode resolves to an image; the count stays as text.
    expect(find.byType(InlineNetworkImage), findsOneWidget);
    expect(find.text(':partyblob: 3'), findsNothing);
    resetCustomEmojiPrefetchForTest(); // pending-timer invariant runs pre-tearDown
  });

  testWidgets('a unicode reaction stays a plain Text (no image)',
      (tester) async {
    await _pump(tester, '🔥 2');
    expect(find.byType(InlineNetworkImage), findsNothing);
    expect(find.text('🔥 2'), findsOneWidget);
  });

  testWidgets('an unknown :shortcode: is left as literal text', (tester) async {
    await _pump(
      tester,
      ':mystery: 1',
      customEmojis: {'partyblob': 'https://cdn.example/partyblob.png'},
    );
    // Unknown code → no image; whole string renders verbatim.
    expect(find.byType(InlineNetworkImage), findsNothing);
    expect(find.text(':mystery: 1'), findsOneWidget);
    resetCustomEmojiPrefetchForTest(); // pending-timer invariant runs pre-tearDown
  });
}

/// A [LiveCustomEmojiNotifier] seeded with a fixed shortcode→url map.
class _SeededEmojiNotifier extends LiveCustomEmojiNotifier {
  _SeededEmojiNotifier(super.ref, Map<String, String> seed) {
    seed.forEach(registerEmojiQuiet);
    state = CustomEmojiState(codeToUrl: Map.of(seed));
  }
}

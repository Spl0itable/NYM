// Rendering-layer tests for message bodies (the widget side of
// message_content.dart), covering the three reported bugs:
//   1. custom-emoji `:shortcode:` -> an inline image widget,
//   2. unicode emoji carry the bundled color-emoji font fallback (no tofu),
//   3. inline images are SVG-aware + decode-safe.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/emoji/custom_emoji.dart';
import 'package:nym_bar/features/messages/format/message_content.dart';
import 'package:nym_bar/features/messages/inline_network_image.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';

/// Pumps a [MessageContent] for [content] with the providers it reads stubbed.
/// [customEmojis] seeds the live NIP-30 store so `:shortcode:` resolves.
Future<void> _pumpMessage(
  WidgetTester tester,
  String content, {
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
        currentViewProvider.overrideWithValue(const ChatView.channel('test')),
        nymColorsProvider.overrideWithValue(colors),
        if (customEmojis.isNotEmpty)
          liveCustomEmojiProvider.overrideWith(
            (ref) => _SeededEmojiNotifier(ref, customEmojis),
          ),
      ],
      child: MaterialApp(
        theme: buildNymThemeData(colors),
        home: Scaffold(body: MessageContent(content: content)),
      ),
    ),
  );
  // Let the first frame settle (no real network — images error out quickly).
  await tester.pump();
}

void main() {
  group('isSvgUrl', () {
    test('detects a bare .svg url', () {
      expect(isSvgUrl('https://cdn.example/foo.svg'), isTrue);
      expect(isSvgUrl('https://cdn.example/foo.svg?v=2'), isTrue);
    });

    test('detects an svg behind the media proxy (url= query)', () {
      const proxied =
          'https://app.nym.bar/api/proxy?emoji=1&url=https%3A%2F%2Fcdn%2Fblob.svg';
      expect(isSvgUrl(proxied), isTrue);
    });

    test('does not flag raster urls', () {
      expect(isSvgUrl('https://cdn.example/foo.png'), isFalse);
      expect(isSvgUrl('https://cdn.example/foo.gif?x=1'), isFalse);
      expect(isSvgUrl(''), isFalse);
    });
  });

  group('MessageContent rendering', () {
    testWidgets('custom :shortcode: renders an inline image (not literal text)',
        (tester) async {
      await _pumpMessage(
        tester,
        'party time :partyblob: yay',
        customEmojis: {'partyblob': 'https://cdn.example/partyblob.png'},
      );
      // BUG 1: the shortcode resolves to an InlineNetworkImage WidgetSpan.
      expect(find.byType(InlineNetworkImage), findsOneWidget);
      // The literal `:partyblob:` token must NOT appear as visible text.
      expect(find.textContaining(':partyblob:'), findsNothing);
    });

    test('SVG custom-emoji URL routes through the SVG path (proxied)', () {
      // BUG 3: a custom emoji served as SVG must be recognised AFTER proxying so
      // InlineNetworkImage renders it via flutter_svg rather than the raster
      // decoder (which throws "ImageDecoder unimplemented"). We assert on the
      // proxied URL the renderer feeds the widget — `isSvgUrl` must still see the
      // `.svg` inside the proxy `url=` query. (Avoids a real SVG fetch.)
      final proxied = proxiedMedia('https://cdn.example/vector.svg', emoji: true);
      expect(isSvgUrl(proxied), isTrue);
    });

    testWidgets('unicode emoji text carries the color-emoji font fallback',
        (tester) async {
      await _pumpMessage(tester, 'hello 🔥 world');
      // BUG 2: find the body Text.rich and assert its style chain offers the
      // bundled emoji font as a fallback so emoji render in color (not tofu).
      final richTexts = tester
          .widgetList<RichText>(find.byType(RichText))
          .where((rt) => rt.text.toPlainText().contains('🔥'));
      expect(richTexts, isNotEmpty);
      final span = richTexts.first.text as TextSpan;
      final fallback = _collectFontFallbacks(span);
      expect(fallback, contains(kEmojiFont));
    });

    testWidgets('emoji-only message keeps the enlarge path', (tester) async {
      // 1-6 emoji, no other text -> isEmojiOnly true (enlarged glyphs). Must
      // still render without throwing now that the fallback font is in play.
      await _pumpMessage(tester, '😀🔥');
      expect(tester.takeException(), isNull);
      expect(find.byType(MessageContent), findsOneWidget);
    });
  });
}

/// Walks a [TextSpan] tree collecting every `fontFamilyFallback` entry seen.
Set<String> _collectFontFallbacks(InlineSpan span) {
  final out = <String>{};
  void visit(InlineSpan s) {
    if (s is TextSpan) {
      final fb = s.style?.fontFamilyFallback;
      if (fb != null) out.addAll(fb);
      final kids = s.children;
      if (kids != null) {
        for (final c in kids) {
          visit(c);
        }
      }
    }
  }

  visit(span);
  return out;
}

/// A [LiveCustomEmojiNotifier] seeded with a fixed shortcode->url map so tests
/// don't depend on relays or persisted caches.
class _SeededEmojiNotifier extends LiveCustomEmojiNotifier {
  _SeededEmojiNotifier(super.ref, Map<String, String> seed) {
    seed.forEach(registerEmojiQuiet);
    // Publish the seeded map so readers see it immediately.
    state = CustomEmojiState(codeToUrl: Map.of(seed));
  }
}

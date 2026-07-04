// Tests for inline custom-emoji-while-typing in the message composer
// (02-F-02-E / "custom emoji shortcodes not rendering in all areas").
//
// The composer keeps each rendered custom emoji as exactly ONE Private-Use-Area
// (PUA) sentinel char in [EmojiSentinelController.text] and paints it as the
// emoji <img> via an overridden `buildTextSpan`. The load-bearing invariant is
// WIRE-SAFETY: a sentinel PUA char must NEVER leave the composer — every draft
// read headed for the relay/services/history routes through `expand`
// (= the composer's `_draftText`), which maps each sentinel back to `:code:`.
//
// These tests drive the controller's pure logic directly (the robust path the
// task asks for) plus one widget pump proving the sentinel renders an inline
// image. A "completed `:code:`" is resolved exactly like the PWA's
// `_maybeRenderTypedEmoji` (the closing `:` completes a known token).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/emoji/custom_emoji.dart';
import 'package:nym_bar/features/messages/inline_network_image.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/chat/composer.dart';

/// True when [s] contains any Unicode Private-Use-Area code point (U+E000…U+F8FF)
/// — the sentinel range. The wire-safety invariant requires this to be FALSE for
/// anything that reaches the send path.
bool _hasPua(String s) =>
    s.runes.any((r) => r >= 0xE000 && r <= 0xF8FF);

/// A controller seeded with a fixed shortcode→url map (what the composer feeds in
/// from `liveCustomEmojiProvider.codeToUrl` during `build`).
EmojiSentinelController _controller(Map<String, String> codeToUrl) {
  final c = EmojiSentinelController();
  c.codeToUrl = codeToUrl;
  return c;
}

/// Types [literal] into [c] at the end and runs the resolve-on-input pass, the
/// way the composer's `_onInputChanged` does after every keystroke.
void _typeAndResolve(EmojiSentinelController c, String literal) {
  c.value = TextEditingValue(
    text: literal,
    selection: TextSelection.collapsed(offset: literal.length),
  );
  c.resolveInput();
}

void main() {
  const url = 'https://cdn.example/partyblob.png';
  const url2 = 'https://cdn.example/blobwave.gif';

  group('EmojiSentinelController resolve + expand (wire-safety)', () {
    test('a known :code: collapses to ONE sentinel char; expand restores it',
        () {
      final c = _controller({'partyblob': url});
      _typeAndResolve(c, 'hi :partyblob:');

      // The literal 11-char `:partyblob:` token collapsed to a single sentinel:
      // text is now "hi " + 1 char = 4 chars.
      expect(c.text.length, 4, reason: 'token collapsed to one sentinel char');
      expect(c.text.contains(':partyblob:'), isFalse);
      expect(_hasPua(c.text), isTrue, reason: 'a PUA sentinel is present');

      // expand() (== the composer _draftText) restores the literal shortcode and
      // leaves ZERO PUA chars — exactly what reaches the wire.
      final draft = c.expand(c.text);
      expect(draft, 'hi :partyblob:');
      expect(_hasPua(draft), isFalse);
    });

    test('the content handed to the send path is wire-safe (:code:, no PUA)',
        () {
      final c = _controller({'partyblob': url, 'blobwave': url2});
      // Two DISTINCT emoji + a repeat of the first.
      _typeAndResolve(c, ':partyblob: and :blobwave: :partyblob:');

      // Controller text holds three sentinels (the repeat reuses the first's).
      final sentinels =
          c.text.runes.where((r) => r >= 0xE000 && r <= 0xF8FF).length;
      expect(sentinels, 3);

      // The exact string `_send`/`_sendAnon`/`_translateDraft` would transmit.
      final wire = c.expand(c.text);
      expect(wire, ':partyblob: and :blobwave: :partyblob:');
      expect(_hasPua(wire), isFalse,
          reason: 'NO Private-Use-Area char may ever reach the relay');
    });

    test('an UNKNOWN :code: stays literal (no sentinel allocated)', () {
      final c = _controller({'partyblob': url});
      _typeAndResolve(c, 'hello :mystery:');

      // Unchanged: still the literal token, no PUA char.
      expect(c.text, 'hello :mystery:');
      expect(_hasPua(c.text), isFalse);
      // expand is a no-op when nothing resolved.
      expect(c.expand(c.text), 'hello :mystery:');
    });

    test('an INCOMPLETE token (no closing colon) is not resolved', () {
      final c = _controller({'partyblob': url});
      _typeAndResolve(c, 'hi :partyblo');
      expect(c.text, 'hi :partyblo');
      expect(_hasPua(c.text), isFalse);

      // Completing it then resolves (mirrors _maybeRenderTypedEmoji firing when
      // the closing `:` lands).
      _typeAndResolve(c, 'hi :partyblob:');
      expect(_hasPua(c.text), isTrue);
      expect(c.expand(c.text), 'hi :partyblob:');
    });

    test('backspace over a sentinel removes the WHOLE emoji', () {
      final c = _controller({'partyblob': url});
      _typeAndResolve(c, 'x:partyblob:');
      expect(c.text.length, 2); // 'x' + sentinel
      expect(_hasPua(c.text), isTrue);

      // Backspace = delete the single sentinel char at the caret end (one slot,
      // because the WidgetSpan occupies exactly one character).
      final t = c.text;
      final without = t.substring(0, t.length - 1);
      c.value = TextEditingValue(
        text: without,
        selection: TextSelection.collapsed(offset: without.length),
      );
      expect(c.text, 'x');
      expect(_hasPua(c.text), isFalse);
      expect(c.expand(c.text), 'x'); // nothing emoji-shaped survives
    });

    test('caret stays AFTER the inserted emoji (length delta applied)', () {
      final c = _controller({'partyblob': url});
      // Caret at end of a just-completed token.
      _typeAndResolve(c, 'go :partyblob:');
      // text == "go " + sentinel (4 chars); caret should sit at the end (4).
      expect(c.selection.baseOffset, c.text.length);
      expect(c.selection.baseOffset, 4);
    });

    test('emptying the draft resets the sentinel map (no stale leak)', () {
      final c = _controller({'partyblob': url});
      _typeAndResolve(c, ':partyblob:');
      expect(_hasPua(c.text), isTrue);

      c.clear();
      expect(c.text, isEmpty);
      // A brand-new draft re-uses the LOWEST sentinel (U+E000) and a STALE
      // sentinel from the old draft no longer expands to anything.
      _typeAndResolve(c, ':partyblob:');
      expect(c.text.codeUnitAt(0), 0xE000);
      expect(c.expand(c.text), ':partyblob:');
    });

    test('expand passes plain (sentinel-free) text through verbatim', () {
      final c = _controller({'partyblob': url});
      expect(c.expand('just text :unknown: 🔥'), 'just text :unknown: 🔥');
    });
  });

  group('EmojiSentinelController.buildTextSpan (inline render)', () {
    testWidgets('a resolved sentinel paints an inline image, not a glyph',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final kv = KeyValueStore(prefs);
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );

      final c = _controller({'partyblob': url});
      _typeAndResolve(c, 'hi :partyblob:');
      // Sanity: the wire form is clean even while the field shows an image.
      expect(c.expand(c.text), 'hi :partyblob:');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            keyValueStoreProvider.overrideWithValue(kv),
            nymColorsProvider.overrideWithValue(colors),
            liveCustomEmojiProvider.overrideWith(
              (ref) => _SeededEmojiNotifier(ref, {'partyblob': url}),
            ),
          ],
          child: MaterialApp(
            theme: buildNymThemeData(colors),
            home: Scaffold(
              body: TextField(controller: c),
            ),
          ),
        ),
      );
      await tester.pump();

      // The sentinel renders as the SAME InlineNetworkImage the rendered-message
      // custom emoji uses — not a literal `:partyblob:` and not a PUA glyph.
      expect(find.byType(InlineNetworkImage), findsOneWidget);
      expect(find.text(':partyblob:'), findsNothing);
    });
  });
}

/// A [LiveCustomEmojiNotifier] seeded with a fixed shortcode→url map (mirrors the
/// pattern in inline_emoji_test.dart).
class _SeededEmojiNotifier extends LiveCustomEmojiNotifier {
  _SeededEmojiNotifier(super.ref, Map<String, String> seed) {
    seed.forEach(registerEmojiQuiet);
    state = CustomEmojiState(codeToUrl: Map.of(seed));
  }
}

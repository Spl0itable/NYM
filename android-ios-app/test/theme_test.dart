import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';

void main() {
  group('Theme resolution', () {
    test('Bitchat dark has neon-green accent and near-black bg', () {
      final c = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );
      expect(c.primary, const Color(0xFF00FF00));
      expect(c.bg, const Color(0xFF0A0A0F));
      // solid-ui makes surfaces opaque
      expect(c.bgSecondary, const Color(0xFF14141E));
    });

    test('Amber theme uses amber primary', () {
      final c = resolveNymColors(
        theme: NymThemeKey.amber,
        brightness: Brightness.dark,
        solidUi: false,
      );
      expect(c.primary, const Color(0xFFFFB000));
    });

    test('Cyberpunk uses magenta primary', () {
      final c = resolveNymColors(
        theme: NymThemeKey.cyber,
        brightness: Brightness.dark,
        solidUi: false,
      );
      expect(c.primary, const Color(0xFFFF00FF));
    });

    test('Ghost dark overrides background to #080808', () {
      final c = resolveNymColors(
        theme: NymThemeKey.ghost,
        brightness: Brightness.dark,
        solidUi: false,
      );
      expect(c.primary, const Color(0xFFFFFFFF));
      expect(c.bg, const Color(0xFF080808));
      // applyTheme's inline ghost.dark text-dim (#cccccc) wins over the
      // `body.theme-ghost` CSS class value (#999999).
      expect(c.textDim, const Color(0xFFCCCCCC));
      expect(c.lightning, const Color(0xFFDDDDDD));
      // bg-accent tokens come from the CSS class (not set inline by applyTheme).
      expect(c.warning, const Color(0xFF888888));
      expect(c.blue, const Color(0xFFBBBBBB));
    });

    test('Light mode switches background', () {
      final c = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.light,
        solidUi: false,
      );
      expect(c.bg, const Color(0xFFF5F5F2));
      expect(c.primary, const Color(0xFF007A00));
    });

    test('All six themes resolve in both brightnesses without error', () {
      for (final t in NymThemeKey.values) {
        for (final b in Brightness.values) {
          for (final solid in [true, false]) {
            final c = resolveNymColors(
                theme: t, brightness: b, solidUi: solid);
            expect(c.primary.a, 1.0);
            buildNymThemeData(c); // must not throw
          }
        }
      }
    });
  });
}

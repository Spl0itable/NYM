import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/i18n/language_select.dart';
import 'package:nym_bar/features/identity/setup_modal.dart';
import 'package:nym_bar/features/onboarding/boot_gate.dart';
import 'package:nym_bar/features/onboarding/tutorial_overlay.dart';
import 'package:nym_bar/screens/home_shell.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/columns/columns_deck.dart';
import 'package:nym_bar/widgets/wallpaper/wallpaper_layer.dart';

/// Wraps [child] in the providers + Nymchat theme a widget needs to render.
Widget _host(KeyValueStore kv, Widget child) {
  final colors = resolveNymColors(
    theme: NymThemeKey.bitchat,
    brightness: Brightness.dark,
    solidUi: true,
  );
  return ProviderScope(
    overrides: [keyValueStoreProvider.overrideWithValue(kv)],
    child: MaterialApp(
      theme: buildNymThemeData(colors),
      home: child,
    ),
  );
}

void main() {
  // A roomy desktop surface so the shell exercises its sidebar + content row.
  void roomy(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  // ---------------------------------------------------------------------------
  // 1. Boot gate decision (setup-modal-init.js + checkSavedConnection).
  // ---------------------------------------------------------------------------
  group('BootGate', () {
    testWidgets(
        'shows the setup modal when not logged-in + auto-ephemeral off',
        (tester) async {
      roomy(tester);
      // Language already chosen so the first-run picker (which now leads
      // onboarding) is skipped and we land on the setup modal directly.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.${StorageKeys.uiLanguageChosen}': 'true',
      });
      final kv = await KeyValueStore.open();

      await tester.pumpWidget(_host(kv, const BootGate()));
      await tester.pump();

      expect(find.byType(SetupModal), findsOneWidget);
      expect(find.byType(HomeShell), findsNothing);
      // The "Enter" primary action is present.
      expect(find.byKey(const Key('setupEnterBtn')), findsOneWidget);
    });

    testWidgets('reaches the shell when auto-ephemeral is enabled',
        (tester) async {
      roomy(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.${StorageKeys.autoEphemeral}': 'true',
        'flutter.${StorageKeys.uiLanguageChosen}': 'true',
      });
      final kv = await KeyValueStore.open();

      await tester.pumpWidget(_host(kv, const BootGate()));
      await tester.pumpAndSettle();

      expect(find.byType(SetupModal), findsNothing);
      expect(find.byType(HomeShell), findsOneWidget);
    });

    testWidgets('reaches the shell when a saved Nostr login exists',
        (tester) async {
      roomy(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.${StorageKeys.nostrLoginMethod}': 'nsec',
        'flutter.${StorageKeys.uiLanguageChosen}': 'true',
      });
      final kv = await KeyValueStore.open();

      await tester.pumpWidget(_host(kv, const BootGate()));
      await tester.pumpAndSettle();

      expect(find.byType(SetupModal), findsNothing);
      expect(find.byType(HomeShell), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Wallpaper type -> pattern descriptor (pure mapping).
  // ---------------------------------------------------------------------------
  group('WallpaperPattern.forType', () {
    test('none / null / unknown -> transparent (no paint)', () {
      expect(WallpaperPattern.forType('none').fill, WallpaperFill.none);
      expect(WallpaperPattern.forType(null).fill, WallpaperFill.none);
      expect(WallpaperPattern.forType('bogus').fill, WallpaperFill.none);
      expect(WallpaperPattern.forType('none').paints, isFalse);
    });

    test('the 7 presets map to a painting pattern', () {
      const presets = [
        'geometric',
        'circuit',
        'dots',
        'waves',
        'topography',
        'hexagons',
        'diamonds',
      ];
      for (final type in presets) {
        final p = WallpaperPattern.forType(type);
        expect(p.type, type);
        expect(p.paints, isTrue, reason: '$type should paint');
        expect(p.fill, WallpaperFill.pattern, reason: '$type fill');
      }
      expect(WallpaperPattern.presets.length, 7);
    });

    test('custom uploads classify as the custom fill', () {
      expect(WallpaperPattern.forType('custom').fill, WallpaperFill.custom);
    });
  });

  // ---------------------------------------------------------------------------
  // 3. Columns mode flips the shell to the deck.
  // ---------------------------------------------------------------------------
  group('HomeShell view mode', () {
    testWidgets('single mode renders the chat pane, not the deck',
        (tester) async {
      roomy(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();

      await tester.pumpWidget(_host(kv, const HomeShell()));
      await tester.pumpAndSettle();

      expect(find.byType(ColumnsDeck), findsNothing);
      expect(find.byKey(const Key('columnsStrip')), findsNothing);
    });

    testWidgets('columns mode renders the deck strip', (tester) async {
      roomy(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.${StorageKeys.chatViewMode}': 'columns',
      });
      final kv = await KeyValueStore.open();

      await tester.pumpWidget(_host(kv, const HomeShell()));
      await tester.pumpAndSettle();

      expect(find.byType(ColumnsDeck), findsOneWidget);
      expect(find.byKey(const Key('columnsStrip')), findsOneWidget);
      // The add-column affordance is present.
      expect(find.byKey(const Key('cvAddColumn')), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // 4. Tutorial-seen flag gates the overlay.
  // ---------------------------------------------------------------------------
  group('Tutorial overlay gating', () {
    testWidgets('first run (unseen) shows the tutorial over the shell',
        (tester) async {
      roomy(tester);
      // auto-ephemeral set so the gate reaches the shell; tutorial unseen.
      // uiLanguageChosen set so the first-run language picker doesn't precede
      // the tutorial (that flow is covered by its own test below).
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.${StorageKeys.autoEphemeral}': 'true',
        'flutter.${StorageKeys.uiLanguageChosen}': 'true',
      });
      final kv = await KeyValueStore.open();

      await tester.pumpWidget(_host(kv, const BootGate()));
      await tester.pump(); // shell paints
      await tester.pump(); // hydration gate resolves (no boot → starts open)
      // The PWA's 300ms settle delay before the tutorial starts (app.js:446).
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(TutorialOverlay), findsOneWidget);
      expect(find.byKey(const Key('tutorialCard')), findsOneWidget);
      // Step 1 of 12 is shown.
      expect(find.text('Step 1 of ${kTutorialSteps.length}'), findsOneWidget);
    });

    testWidgets('tutorial-seen suppresses the overlay', (tester) async {
      roomy(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.${StorageKeys.autoEphemeral}': 'true',
        'flutter.${StorageKeys.tutorialSeen}': 'true',
        'flutter.${StorageKeys.uiLanguageChosen}': 'true',
      });
      final kv = await KeyValueStore.open();

      await tester.pumpWidget(_host(kv, const BootGate()));
      await tester.pump();
      await tester.pump();
      // Even past the tutorial's 300ms start delay, the seen flag holds.
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(TutorialOverlay), findsNothing);
    });

    test('there are 12 tutorial steps, matching the PWA', () {
      expect(kTutorialSteps.length, 12);
      expect(kTutorialSteps.first.title, 'Nymchat Tutorial');
      expect(kTutorialSteps.last.title, 'All set!');
    });
  });

  // ---------------------------------------------------------------------------
  // 5. First-run language picker LEADS onboarding (before the welcome modal).
  // ---------------------------------------------------------------------------
  group('First-run language picker', () {
    testWidgets('shows before the tutorial when no language chosen yet',
        (tester) async {
      roomy(tester);
      // Reaches the shell (auto-ephemeral) but the language hasn't been chosen.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.${StorageKeys.autoEphemeral}': 'true',
      });
      final kv = await KeyValueStore.open();

      await tester.pumpWidget(_host(kv, const BootGate()));
      await tester.pump(); // shell paints
      await tester.pump(); // hydration gate resolves

      // The picker is up; the tutorial is held behind it.
      expect(find.byType(LanguageSelectScreen), findsOneWidget);
      expect(find.byType(TutorialOverlay), findsNothing);
    });

    testWidgets('precedes the welcome/setup modal when setup is needed',
        (tester) async {
      roomy(tester);
      // Not logged-in + no auto-ephemeral ⇒ setup is needed, but the language
      // picker must lead so the welcome modal renders in the chosen language.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();

      await tester.pumpWidget(_host(kv, const BootGate()));
      await tester.pump();

      expect(find.byType(LanguageSelectScreen), findsOneWidget);
      expect(find.byType(SetupModal), findsNothing);
    });

    testWidgets('choosing a language then reveals the setup modal',
        (tester) async {
      roomy(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();

      await tester.pumpWidget(_host(kv, const BootGate()));
      await tester.pump();
      expect(find.byType(LanguageSelectScreen), findsOneWidget);

      await tester.tap(find.text('English').first);
      await tester.pumpAndSettle();

      expect(find.byType(LanguageSelectScreen), findsNothing);
      expect(find.byType(SetupModal), findsOneWidget);
      expect(kv.getBool(StorageKeys.uiLanguageChosen), isTrue);
    });

    testWidgets('choosing a language dismisses the picker and starts tutorial',
        (tester) async {
      roomy(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.${StorageKeys.autoEphemeral}': 'true',
      });
      final kv = await KeyValueStore.open();

      await tester.pumpWidget(_host(kv, const BootGate()));
      await tester.pump();
      await tester.pump();
      expect(find.byType(LanguageSelectScreen), findsOneWidget);

      // Pick English (first row) — no network translation, applies instantly.
      await tester.tap(find.text('English').first);
      await tester.pumpAndSettle();
      // Past the tutorial's 300ms start delay.
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(LanguageSelectScreen), findsNothing);
      expect(find.byType(TutorialOverlay), findsOneWidget);
      // The choice was persisted so the picker won't reappear.
      expect(kv.getBool(StorageKeys.uiLanguageChosen), isTrue);
    });
  });
}

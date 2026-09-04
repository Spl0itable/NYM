// The Pro model picker sheet must scroll rather than overflow.
//
// The catalog is served live from the model-catalog worker now, so it grows
// (and shrinks) without an app release and "the rows happen to fit" is not a
// property the layout can rely on. These pump the real sheet widget at a small
// phone surface and assert that a catalog taller than the screen is reachable
// instead of overflowing, on both the built-in list and a fetched one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/nymbot/bot_chat_screen.dart';
import 'package:nym_bar/features/nymbot/nymbot_models.dart';

NymColors _testColors() => resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

Widget _harness({
  ProModel? current,
  ValueChanged<ProModel?>? onSelected,
  ProModelCatalog? catalog,
}) {
  return MaterialApp(
    home: Scaffold(
      // Bottom-aligned so the sheet is laid out the way showModalBottomSheet
      // places it: taking its natural height at the bottom of the screen.
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ProModelPickerSheet(
          colors: _testColors(),
          current: current,
          catalog: catalog,
          onSelected: onSelected ?? (_) {},
        ),
      ),
    ),
  );
}

/// A live catalog shaped like the worker's `models` payload: two providers,
/// blurbs, and capability flags.
ProModelCatalog _liveCatalog() => ProModelCatalog.fromJson({
      'source': 'catalog',
      'models': [
        {
          'key': 'claude-fable-5-1',
          'label': 'Claude Fable 5.1',
          'model': 'anthropic/claude-fable-5.1',
          'credits': 2,
          'max': 16,
          'description': 'Improvements in agentic coding and knowledge work.',
          'author': 'Anthropic',
          'authorSlug': 'anthropic',
          'vision': true,
          'reasoning': true,
          'tools': true,
        },
        {
          'key': 'gemini-3-6-flash',
          'label': 'Gemini 3.6 Flash',
          'model': 'google/gemini-3.6-flash',
          'credits': 1,
          'max': 3,
          'description': 'Frontier intelligence at higher speed and lower cost.',
          'author': 'Google',
          'authorSlug': 'google',
        },
      ],
      'groups': [
        {
          'author': 'Anthropic',
          'authorSlug': 'anthropic',
          'keys': ['claude-fable-5-1'],
        },
        {
          'author': 'Google',
          'authorSlug': 'google',
          'keys': ['gemini-3-6-flash'],
        },
      ],
    });

void main() {
  // A small-but-real phone: shorter than the full catalog is tall.
  const smallPhone = Size(360, 640);

  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('lays out without overflowing a short screen', (tester) async {
    await tester.binding.setSurfaceSize(smallPhone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // A RenderFlex overflow is reported as a framework exception, which is
    // exactly the failure mode a plain Column in the sheet produced.
    expect(tester.takeException(), isNull);
  });

  testWidgets('the whole catalog is reachable by scrolling', (tester) async {
    await tester.binding.setSurfaceSize(smallPhone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // The first row is on screen from the start.
    expect(find.text(kProModels.first.label), findsOneWidget);

    // The last one is not — that is the case the old layout dropped on the
    // floor — but scrolling brings it in.
    final last = find.text(kProModels.last.label);
    await tester.scrollUntilVisible(last, 200,
        scrollable: find.descendant(
            of: find.byKey(proModelListKey), matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    expect(last, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sheet stays within the screen height', (tester) async {
    await tester.binding.setSurfaceSize(smallPhone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final box = tester.getRect(find.byType(ProModelPickerSheet));
    expect(box.height, lessThanOrEqualTo(smallPhone.height));
  });

  testWidgets('tapping a model reports it, and standard reports null',
      (tester) async {
    await tester.binding.setSurfaceSize(smallPhone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final picked = <Object?>[];
    await tester.pumpWidget(_harness(onSelected: picked.add));
    await tester.pumpAndSettle();

    await tester.tap(find.text(kProModels.first.label));
    expect(picked, [kProModels.first]);

    await tester.tap(find.text('Standard (auto-routed)'));
    expect(picked.last, isNull);
  });

  group('live catalog', () {
    testWidgets('renders the fetched models grouped under their provider',
        (tester) async {
      await tester.binding.setSurfaceSize(smallPhone);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_harness(catalog: _liveCatalog()));
      await tester.pumpAndSettle();

      expect(find.text('ANTHROPIC'), findsOneWidget);
      expect(find.text('GOOGLE'), findsOneWidget);
      expect(find.text('Claude Fable 5.1'), findsOneWidget);
      // A built-in model that is NOT in the fetched catalog must not appear:
      // the live list replaces the fallback, it does not merge with it.
      expect(find.text('Claude Opus 5'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows each model\'s blurb and capability tags',
        (tester) async {
      await tester.binding.setSurfaceSize(smallPhone);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_harness(catalog: _liveCatalog()));
      await tester.pumpAndSettle();

      expect(find.textContaining('agentic coding'), findsOneWidget);
      expect(find.textContaining('vision · reasoning · tools'), findsOneWidget);
    });

    testWidgets('search narrows the list and clears back to everything',
        (tester) async {
      await tester.binding.setSurfaceSize(smallPhone);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_harness(catalog: _liveCatalog()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'gemini');
      await tester.pumpAndSettle();
      expect(find.text('Gemini 3.6 Flash'), findsOneWidget);
      expect(find.text('Claude Fable 5.1'), findsNothing);
      // The standard row is hidden while filtering — it is not a search hit.
      expect(find.text('Standard (auto-routed)'), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.text('Claude Fable 5.1'), findsOneWidget);
      expect(find.text('Standard (auto-routed)'), findsOneWidget);
    });

    testWidgets('search matches the provider and the blurb, not just the name',
        (tester) async {
      await tester.binding.setSurfaceSize(smallPhone);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_harness(catalog: _liveCatalog()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'anthropic');
      await tester.pumpAndSettle();
      expect(find.text('Claude Fable 5.1'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'lower cost');
      await tester.pumpAndSettle();
      expect(find.text('Gemini 3.6 Flash'), findsOneWidget);
      expect(find.text('Claude Fable 5.1'), findsNothing);
    });

    testWidgets('a search with no hits says so instead of going blank',
        (tester) async {
      await tester.binding.setSurfaceSize(smallPhone);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_harness(catalog: _liveCatalog()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'zzzznope');
      await tester.pumpAndSettle();
      expect(find.text('No model matches your search.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty catalog falls back to the built-in list',
        (tester) async {
      await tester.binding.setSurfaceSize(smallPhone);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
          _harness(catalog: ProModelCatalog.fromJson(const {'models': []})));
      await tester.pumpAndSettle();

      expect(find.text(kProModels.first.label), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a fetched model reports that model', (tester) async {
      await tester.binding.setSurfaceSize(smallPhone);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final picked = <Object?>[];
      await tester.pumpWidget(
          _harness(catalog: _liveCatalog(), onSelected: picked.add));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Gemini 3.6 Flash'));
      expect(picked, hasLength(1));
      expect((picked.single as ProModel).key, 'gemini-3-6-flash');
    });
  });

  testWidgets('the pinned model is the one showing a check', (tester) async {
    await tester.binding.setSurfaceSize(smallPhone);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness(current: kProModels.first));
    await tester.pumpAndSettle();

    final row = find.ancestor(
      of: find.text(kProModels.first.label),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });
}

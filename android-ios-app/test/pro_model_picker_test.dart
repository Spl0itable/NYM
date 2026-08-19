// The Pro model picker sheet must scroll rather than overflow.
//
// The catalog grows over time (7 models -> 12 when the frontier providers were
// added), so "the rows happen to fit" is not a property the layout can rely on.
// These pump the real sheet widget at a small phone surface and assert that a
// catalog taller than the screen is reachable instead of overflowing.
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

Widget _harness({ProModel? current, ValueChanged<ProModel?>? onSelected}) {
  return MaterialApp(
    home: Scaffold(
      // Bottom-aligned so the sheet is laid out the way showModalBottomSheet
      // places it: taking its natural height at the bottom of the screen.
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ProModelPickerSheet(
          colors: _testColors(),
          current: current,
          onSelected: onSelected ?? (_) {},
        ),
      ),
    ),
  );
}

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
        scrollable: find.byType(Scrollable).first);
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

// A draft taller than the composer's popout box must stay reachable: the box
// may not run under the status bar, the field may not ask for more height than
// the box can give, and a drag inside it must scroll rather than only select.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/chat/composer.dart';

class _FakeController extends NostrController {
  _FakeController(super.ref);
  @override
  bool get isLive => true;
  @override
  Future<void> sendTypingStart() async {}
}

NymColors _testColors() => resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

/// Pumps the composer on a phone-sized screen with the keyboard up.
Future<void> _pumpPhone(
  WidgetTester tester, {
  required Size size,
  required double topPadding,
  required double keyboard,
  double textScale = 1.0,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();

  tester.view.physicalSize = Size(size.width * 3, size.height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        nostrControllerProvider.overrideWith((ref) => _FakeController(ref)),
      ],
      child: MaterialApp(
        theme: buildNymThemeData(_testColors()),
        home: Builder(builder: (ctx) {
          return MediaQuery(
            data: MediaQuery.of(ctx).copyWith(
              viewInsets: EdgeInsets.only(bottom: keyboard),
              padding: EdgeInsets.only(top: topPadding),
              textScaler: TextScaler.linear(textScale),
            ),
            child: const Scaffold(
              body: Column(
                children: [
                  Expanded(child: SizedBox.expand()),
                  Composer(compact: true),
                ],
              ),
            ),
          );
        }),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _longDraft() =>
    List.generate(60, (i) => 'line $i of a really long draft message')
        .join('\n');

ScrollPosition _fieldScroll(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byType(TextField).first,
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable.first).position;
}

void main() {
  // A FINGER drag, on both mobile platforms: a vertical drag inside a text
  // field competes with the field's own selection gestures, and the two
  // platforms wire that arena differently.
  testWidgets('a tall draft scrolls under a finger', (tester) async {
    await _pumpPhone(tester,
        size: const Size(390, 844), topPadding: 47, keyboard: 336);

    final field = find.byType(TextField).first;
    await tester.enterText(field, _longDraft());
    await tester.pumpAndSettle();

    final pos = _fieldScroll(tester);
    expect(pos.maxScrollExtent, greaterThan(0),
        reason: 'the draft is taller than the box');
    expect(pos.pixels, pos.maxScrollExtent,
        reason: 'typing keeps the caret line in view');

    // Drag DOWN to scroll back toward the top of the draft.
    await tester.drag(field, const Offset(0, 150),
        kind: PointerDeviceKind.touch, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(pos.pixels, lessThan(pos.maxScrollExtent),
        reason: 'a finger drag inside the field scrolls it rather than only '
            'selecting text');
  }, variant: TargetPlatformVariant.mobile());

  testWidgets('the popout box stays clear of the status bar', (tester) async {
    // A small screen with OS font scaling: the case where a fixed 12-line
    // field and a 40vh cap both overshot what was actually on screen.
    await _pumpPhone(tester,
        size: const Size(360, 640),
        topPadding: 24,
        keyboard: 300,
        textScale: 1.5);

    await tester.enterText(find.byType(TextField).first, _longDraft());
    await tester.pumpAndSettle();

    final box = tester.renderObject<RenderBox>(find.byType(TextField).first);
    final top = box.localToGlobal(Offset.zero).dy;
    expect(top, greaterThanOrEqualTo(24.0),
        reason: 'the field never grows under the status bar');
    expect(box.size.height, greaterThan(0));
  });

  testWidgets('the popout field never asks for more height than its box',
      (tester) async {
    await _pumpPhone(tester,
        size: const Size(360, 640),
        topPadding: 24,
        keyboard: 300,
        textScale: 1.5);

    await tester.enterText(find.byType(TextField).first, _longDraft());
    await tester.pumpAndSettle();

    // The box caps at min(40vh, 360, available-above-the-composer). The field
    // must FIT that, not be clipped by it, so its viewport plus the field's
    // 20px of vertical padding is the whole rendered height.
    final box = tester.renderObject<RenderBox>(find.byType(TextField).first);
    final pos = _fieldScroll(tester);
    expect(pos.viewportDimension + 20, closeTo(box.size.height, 1.0));
  });

  testWidgets('a short draft still sits flat, with no scroll', (tester) async {
    await _pumpPhone(tester,
        size: const Size(390, 844), topPadding: 47, keyboard: 336);

    await tester.enterText(find.byType(TextField).first, 'hi');
    await tester.pumpAndSettle();

    expect(_fieldScroll(tester).maxScrollExtent, 0);
  });
}

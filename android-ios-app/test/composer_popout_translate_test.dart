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
  bool get isLive => true; // enables the input field (relays "connected")
  @override
  Future<void> sendTypingStart() async {}
}

NymColors _testColors() => resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

void main() {
  testWidgets(
      'translate button opens the language dropdown even after the draft pops out',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();

    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final colors = _testColors();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(kv),
          nostrControllerProvider.overrideWith((ref) => _FakeController(ref)),
        ],
        child: MaterialApp(
          theme: buildNymThemeData(colors),
          home: const Scaffold(
            body: Column(
              children: [
                Expanded(child: SizedBox.expand()),
                Composer(compact: false),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byType(TextField).first;

    // --- Sanity: in the flat (single-row) state the translate button opens
    // the dropdown. ---
    await tester.enterText(field, 'hi');
    await tester.pumpAndSettle();
    expect(find.byTooltip('Translate text'), findsOneWidget,
        reason: 'translate button appears once there is text');
    await tester.tap(find.byTooltip('Translate text'));
    await tester.pumpAndSettle();
    expect(find.text('Search languages...'), findsOneWidget,
        reason: 'flat-state translate dropdown opens');
    // Close it again.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Search languages...'), findsNothing);

    // --- Now grow the draft so it pops out into the floating field. ---
    await tester.enterText(
      field,
      'this is a very long message that will definitely wrap onto more than '
      'one and a half visual lines so the composer floats into its popout box',
    );
    await tester.pumpAndSettle();

    // The translate button still exists in the popout field.
    expect(find.byTooltip('Translate text'), findsOneWidget,
        reason: 'translate button is present in the popout field');

    // THE BUG (regression guard): tapping it in popout mode must open the
    // dropdown, exactly like the flat layout above.
    await tester.tap(find.byTooltip('Translate text'));
    await tester.pumpAndSettle();
    expect(find.text('Search languages...'), findsOneWidget,
        reason: 'popout-state translate dropdown must open too');
  });
}

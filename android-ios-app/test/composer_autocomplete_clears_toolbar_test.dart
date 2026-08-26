// The autocomplete / command palette opens ABOVE the composer's panel stack,
// never over it: the WYSIWYG format toolbar sits between the chip and the
// field, outside the dropdown's anchor, so its height has to be part of the
// dropdown's offset (the PWA's `--ac-offset` sums the same `panelsH`).
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
import 'package:nym_bar/widgets/chat/composer_format.dart';
import 'package:nym_bar/features/commands/command_palette.dart';

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
  testWidgets('the command palette clears the open format toolbar',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();

    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(kv),
          nostrControllerProvider.overrideWith((ref) => _FakeController(ref)),
        ],
        child: MaterialApp(
          theme: buildNymThemeData(_testColors()),
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

    // Open the WYSIWYG toolbar the way a user does.
    await tester.tap(find.byTooltip('Formatting'));
    await tester.pumpAndSettle();
    expect(find.byType(FormatToolbar), findsOneWidget,
        reason: 'the WYSIWYG toolbar is open for this test');

    // `/` opens the command palette above the composer.
    await tester.enterText(find.byType(TextField).first, '/');
    await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsOneWidget,
        reason: 'the slash palette opens');

    final toolbar = tester.getRect(find.byType(FormatToolbar));
    final palette = tester.getRect(find.byType(CommandPalette));

    // THE BUG (regression guard): the palette must sit entirely above the
    // toolbar's top edge, not over it.
    expect(palette.bottom, lessThanOrEqualTo(toolbar.top + 0.5),
        reason: 'palette bottom ${palette.bottom} must clear toolbar top '
            '${toolbar.top} — it was painting over the WYSIWYG toolbar');
  });
}

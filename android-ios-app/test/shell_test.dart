import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/screens/home_shell.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';

void main() {
  testWidgets('HomeShell renders a sample channel and a message', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();

    // A roomy surface so the desktop layout (sidebar + chat pane) is exercised.
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final colors = resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [keyValueStoreProvider.overrideWithValue(kv)],
        child: MaterialApp(
          theme: buildNymThemeData(colors),
          home: const HomeShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Sidebar channel list shows the default channel.
    expect(find.text('#nymchat'), findsWidgets);

    // The chat pane shows seeded messages from the active (#nymchat) view.
    expect(
      find.text('wake up… the messenger has you 🐇'),
      findsOneWidget,
    );

    // Sidebar identity header (also appears as the author of self messages).
    expect(find.text('you#1a2b'), findsWidgets);
  });
}

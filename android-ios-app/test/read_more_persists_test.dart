/// The read-more toggle must survive the row being rebuilt in a new parent —
/// which is what an arriving message does when it joins an existing group (the
/// group's lone MessageRow becomes a Column of them).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/messages/format/message_content.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';

String _longBody() =>
    List.generate(80, (i) => 'paragraph $i of a long message body').join('\n');

void main() {
  testWidgets('an expanded body stays expanded when its row is re-parented',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();

    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final colors = resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

    // `wrapped` stands in for the group growing a second message: the same
    // content lands under a different parent, rebuilding its subtree.
    Widget appWith({required bool wrapped}) {
      final content = MessageContent(
        content: _longBody(),
        hostMessageId: 'msg-1',
      );
      return ProviderScope(
        overrides: [keyValueStoreProvider.overrideWithValue(kv)],
        child: MaterialApp(
          theme: buildNymThemeData(colors),
          home: Scaffold(
            body: SingleChildScrollView(
              child: wrapped
                  ? Column(children: [content, const Text('second message')])
                  : content,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(appWith(wrapped: false));
    await tester.pumpAndSettle();

    expect(find.text('Read more'), findsOneWidget,
        reason: 'a long body is clamped');
    await tester.tap(find.text('Read more'));
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget, reason: 'it expanded');

    // A message arrives and the row is rebuilt under a new parent.
    await tester.pumpWidget(appWith(wrapped: true));
    await tester.pumpAndSettle();

    expect(find.text('second message'), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget,
        reason: 'the expansion survives the arriving message');
    expect(find.text('Read more'), findsNothing);
  });
}

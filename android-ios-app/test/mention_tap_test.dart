import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/chat/message_row.dart';
import 'package:nym_bar/widgets/context_menu/context_menu_panel.dart';

const _alice = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1abcd';
const _rootId =
    'f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0';

Message _msg(String content) => Message(
      id: _rootId,
      author: 'bob#1234',
      pubkey: 'pkOther',
      content: content,
      createdAt: 1000,
      eventKind: 20000,
      geohash: 'u4pruyd',
    );

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  return ProviderContainer(overrides: [
    keyValueStoreProvider.overrideWithValue(kv),
    usersProvider.overrideWithValue({
      _alice: User(pubkey: _alice, nym: 'alice'),
    }),
  ]);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  required String content,
  required String layout,
}) async {
  final colors = resolveNymColors(
    theme: NymThemeKey.bitchat,
    brightness: Brightness.dark,
    solidUi: true,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildNymThemeData(colors),
        home: Scaffold(
          body: MessageRow(
            message: _msg(content),
            settings: Settings(chatLayout: layout),
            reactions: const [],
            scrollKey: '#u4pruyd',
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final layout in ['irc', 'bubbles']) {
    group('$layout layout', () {
      testWidgets('tapping an @mention opens that user\'s context menu',
          (tester) async {
        final container = await _container();
        addTearDown(container.dispose);
        await _pump(tester, container,
            content: 'hey @alice#abcd how are you', layout: layout);

        expect(find.textContaining('@alice'), findsWidgets);
        await tester.tap(find.textContaining('@alice').first,
            warnIfMissed: false);
        await tester.pumpAndSettle();

        expect(find.byType(ContextMenuPanel), findsOneWidget,
            reason: 'the mention should open the context menu');
        expect(container.read(activeThreadProvider), isNull,
            reason: 'and must not open the thread instead');
      });

      testWidgets('tapping the message body still opens its thread',
          (tester) async {
        final container = await _container();
        addTearDown(container.dispose);
        await _pump(tester, container,
            content: 'hey @alice#abcd how are you', layout: layout);

        // Near the left edge, over the leading "hey" — the widget's centre
        // would land on the mention chip itself.
        final body = find.textContaining('how are you').first;
        await tester.tapAt(tester.getTopLeft(body) + const Offset(6, 6));
        await tester.pumpAndSettle();

        expect(container.read(activeThreadProvider)?.rootId, _rootId);
        expect(find.byType(ContextMenuPanel), findsNothing);
      });

      testWidgets('an unresolvable @mention opens neither', (tester) async {
        final container = await _container();
        addTearDown(container.dispose);
        await _pump(tester, container,
            content: 'hey @nobody#9999 there', layout: layout);

        await tester.tap(find.textContaining('@nobody').first,
            warnIfMissed: false);
        await tester.pumpAndSettle();

        expect(find.byType(ContextMenuPanel), findsNothing);
        expect(container.read(activeThreadProvider), isNull);
      });
    });
  }
}

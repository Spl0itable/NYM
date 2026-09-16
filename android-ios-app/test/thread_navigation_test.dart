import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/threads/thread_view.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/widgets/chat/messages_list.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/chat/typing_indicator.dart';

/// A thread rooted at [rootId] in a channel view.
ActiveThread _thread(String rootId) => ActiveThread(
      view: const ChatView.channel('room'),
      rootId: rootId,
    );

Widget _host(KeyValueStore kv, Widget child) {
  final colors = resolveNymColors(
    theme: NymThemeKey.bitchat,
    brightness: Brightness.dark,
    solidUi: true,
  );
  return ProviderScope(
    overrides: [keyValueStoreProvider.overrideWithValue(kv)],
    child: MaterialApp(theme: buildNymThemeData(colors), home: child),
  );
}

void main() {
  group('leaving a thread', () {
    test('the feed remembers where it was, by message rather than by index',
        () {
      final scroller = MessageListScroller();
      scroller.bind(ItemScrollController(), {'a': 4, 'b': 9});

      expect(scroller.takeAnchor(), isNull,
          reason: 'nothing was remembered, so nothing is restored');

      scroller.rememberAnchor('b', 0.25);
      // Messages arrived while the thread was open: the same message is at a
      // different index now, which is why the anchor is not an index.
      scroller.bind(ItemScrollController(), {'a': 7, 'b': 12});
      final anchor = scroller.takeAnchor();
      expect(anchor?.index, 12);
      expect(anchor?.alignment, 0.25);

      expect(scroller.takeAnchor(), isNull,
          reason: 'a restore happens once, not on every later remount');
    });

    test('an anchor whose message is gone restores nothing', () {
      final scroller = MessageListScroller();
      scroller.bind(ItemScrollController(), {'a': 1});
      scroller.rememberAnchor('vanished', 0.5);
      scroller.bind(ItemScrollController(), {'a': 1});
      expect(scroller.takeAnchor(), isNull);
    });

    test('a view switch drops what the old visit remembered', () {
      final scroller = MessageListScroller();
      scroller.bind(ItemScrollController(), {'a': 3});
      scroller.rememberAnchor('a', 0.1);
      scroller.forgetAnchor();
      expect(scroller.takeAnchor(), isNull);
    });
  });

  group('a thread inside a column', () {
    testWidgets('hosts no typing row of its own', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      await tester.pumpWidget(_host(
        kv,
        ThreadView(thread: _thread('root'), showTyping: false),
      ));
      await tester.pump();
      expect(find.byType(TypingIndicatorRow), findsNothing,
          reason: 'the column already hosts one, keyed to ITS conversation');
    });

    testWidgets('while a single-view thread keeps it', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      await tester.pumpWidget(_host(kv, ThreadView(thread: _thread('root'))));
      await tester.pump();
      expect(find.byType(TypingIndicatorRow), findsOneWidget);
    });
  });
}

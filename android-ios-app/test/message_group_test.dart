import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/chat/message_row.dart';
import 'package:nym_bar/widgets/common/nym_avatar.dart';

/// A minimal channel message.
Message _msg({
  required String id,
  String pubkey = 'pkOther',
  bool isOwn = false,
  int createdAt = 1000,
}) {
  return Message(
    id: id,
    author: 'alice#abcd',
    pubkey: pubkey,
    content: 'hello world',
    createdAt: createdAt,
    isOwn: isOwn,
    eventKind: 20000,
    geohash: 'u4pruyd',
  );
}

List<MessageGroupEntry> _entries(List<Message> messages) => [
      for (final m in messages)
        MessageGroupEntry(message: m, reactions: const [], mentioned: false),
    ];

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  return ProviderContainer(
    overrides: [keyValueStoreProvider.overrideWithValue(kv)],
  );
}

Future<void> _pumpGroup(
  WidgetTester tester,
  ProviderContainer container, {
  required List<MessageGroupEntry> entries,
  Settings settings = const Settings(),
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
          body: Center(
            child: SizedBox(
              width: 360,
              child: MessageGroup(entries: entries, settings: settings),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
      'a multi-message others bubble group renders exactly ONE sticky avatar '
      'for the whole run (not one per message)', (tester) async {
    final container = await _container();
    addTearDown(container.dispose);

    await _pumpGroup(
      tester,
      container,
      entries: _entries([
        _msg(id: 'a', createdAt: 1000),
        _msg(id: 'b', createdAt: 1010),
        _msg(id: 'c', createdAt: 1020),
      ]),
    );

    // Three bubbles, one group → a single `.message-group-avatar`.
    expect(find.byType(MessageRow), findsNWidgets(3));
    expect(find.byType(NymAvatar), findsOneWidget);

    // Tear down the widget so the per-row relative-time timers are cancelled.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a self bubble group renders NO avatar (group-self)',
      (tester) async {
    final container = await _container();
    addTearDown(container.dispose);

    await _pumpGroup(
      tester,
      container,
      entries: _entries([
        _msg(id: 'a', pubkey: 'me', isOwn: true, createdAt: 1000),
        _msg(id: 'b', pubkey: 'me', isOwn: true, createdAt: 1010),
      ]),
    );

    expect(find.byType(MessageRow), findsNWidgets(2));
    expect(find.byType(NymAvatar), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'bubble group stack fills the group width (not shrink-wrapped to the '
      'bubble) so translation / read-receipts can span and self can right-align',
      (tester) async {
    final container = await _container();
    addTearDown(container.dispose);

    // Others single-message group.
    await _pumpGroup(
      tester,
      container,
      entries: _entries([_msg(id: 'a')]),
    );
    final groupW = tester.getRect(find.byType(MessageGroup)).width;
    final othersRowW = tester.getRect(find.byType(MessageRow)).width;
    // A shrink-wrapped column would collapse to the ~180px bubble min-width; the
    // stack must instead fill the group minus the avatar gutter + paddings.
    expect(othersRowW, greaterThan(groupW - 80));
    await tester.pumpWidget(const SizedBox());

    // Self single-message group.
    await _pumpGroup(
      tester,
      container,
      entries: _entries([_msg(id: 'b', pubkey: 'me', isOwn: true)]),
    );
    final selfGroupW = tester.getRect(find.byType(MessageGroup)).width;
    final selfRowW = tester.getRect(find.byType(MessageRow)).width;
    expect(selfRowW, greaterThan(selfGroupW - 60));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('IRC layout group renders bare with the inline author avatar',
      (tester) async {
    final container = await _container();
    addTearDown(container.dispose);

    await _pumpGroup(
      tester,
      container,
      entries: _entries([_msg(id: 'a')]),
      settings: const Settings(chatLayout: 'irc'),
    );

    // IRC keeps its 18px inline `.avatar-message` (one per row, no group avatar).
    expect(find.byType(MessageRow), findsOneWidget);
    expect(find.byType(NymAvatar), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}

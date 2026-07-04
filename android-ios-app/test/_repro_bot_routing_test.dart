import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/nymbot/bot_chat_screen.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/chat/chat_pane.dart';
import 'package:nym_bar/widgets/sidebar/pm_list_item.dart';
import 'package:nym_bar/widgets/sidebar/sidebar.dart';

class _FakeController extends NostrController {
  _FakeController(super.ref);
}

NymColors _testColors() => resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

const _self =
    '0000000000000000000000000000000000000000000000000000000000001a2b';

Message _botMsg(int i, {required bool own}) => Message(
      id: 'wrap-$i',
      author: own ? 'you#1a2b' : 'Nymbot',
      pubkey: own ? _self : kNymbotPubkey,
      content: 'msg $i',
      createdAt: 1750000000 + i,
      isOwn: own,
      isPM: true,
      conversationKey: 'pm-$kNymbotPubkey',
      conversationPubkey: kNymbotPubkey,
      eventKind: 1059,
      isBot: !own,
    );

void main() {
  testWidgets('restored bot history: sidebar row tap lands on BotChatScreen',
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
          home: Scaffold(
            body: Row(
              children: const [
                SizedBox(width: 290, child: Sidebar()),
                Expanded(child: ChatPane()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatPane)),
    );
    final n = container.read(appStateProvider.notifier);
    n.goLive(_self, 'you#1a2b');
    // Boot-restore of the cached bot thread (persistence hydration).
    n.hydrateAllMessages({
      'pm-$kNymbotPubkey': [
        _botMsg(1, own: true),
        _botMsg(2, own: false),
      ],
    });
    await tester.pump();

    // Restored conversation row exists.
    final pms = container.read(appStateProvider).pmConversations;
    expect(pms, hasLength(1), reason: 'restored bot row should exist');
    // ignore: avoid_print
    print('restored PM row pubkey: ${pms.first.pubkey}');
    expect(pms.first.pubkey, kNymbotPubkey);

    // Tap the sidebar PM row like a user would.
    final row = find.byType(PMListItem);
    expect(row, findsOneWidget, reason: 'bot PM row should render');
    await tester.tap(row);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('view after tap: ${container.read(appStateProvider).view.storageKey}');
    // ignore: avoid_print
    print('BotChatScreen mounted: '
        '${find.byType(BotChatScreen).evaluate().isNotEmpty}');
    expect(find.byType(BotChatScreen), findsOneWidget,
        reason: 'bot PM must land on BotChatScreen');

    // Drain the emoji-prefetch (3s) + sidebar skeleton (8s) timers so the
    // teardown timer check passes.
    await tester.pump(const Duration(seconds: 9));
  });
}

// The bubble-layout group avatar must bottom-align to the LAST bubble, not drop
// onto the reactions row beneath it (AVATAR-BUBBLE).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/messages/format/message_content.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/services/nostr/identity_service.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/chat/message_row.dart';
import 'package:nym_bar/widgets/common/nym_avatar.dart';

class _IdentityController extends NostrController {
  _IdentityController(super.ref, this._self);
  final String _self;
  @override
  Identity? get identity => Identity(pubkey: _self, privkey: null, nym: 'me');
}

void main() {
  testWidgets('group avatar bottom-aligns to the last bubble, not reactions',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();
    final colors = resolveNymColors(
        theme: NymThemeKey.bitchat, brightness: Brightness.dark, solidUi: true);
    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      nostrControllerProvider
          .overrideWith((ref) => _IdentityController(ref, 'selfpk')),
      usersProvider
          .overrideWithValue({'pkOther': User(pubkey: 'pkOther', nym: 'alice')}),
    ]);
    addTearDown(container.dispose);

    final entry = MessageGroupEntry(
      message: Message(
        id: 'm1',
        author: 'alice#abcd',
        pubkey: 'pkOther',
        content: 'hello there friend',
        createdAt: 1000,
        isOwn: false,
        eventKind: 20000,
        geohash: 'u4pruyd',
      ),
      reactions: const [MessageReaction(emoji: '👍', count: 3)],
      mentioned: false,
    );

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildNymThemeData(colors),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: MessageGroup(
                  entries: [entry],
                  settings: const Settings(chatLayout: 'bubbles')),
            ),
          ),
        ),
      ),
    ));
    // Settle the post-frame tick that measures the bubble anchor.
    await tester.pumpAndSettle();

    final avatarBottom = tester.getRect(find.byType(NymAvatar).first).bottom;
    final bubbleBottom = tester.getRect(find.byType(MessageContent).first).bottom;
    final groupBottom = tester.getRect(find.byType(MessageGroup)).bottom;

    // The avatar bottom should sit near the bubble (within ~the bubble's own
    // padding + time row), and clearly ABOVE the group foot where the reactions
    // row lives.
    expect(avatarBottom, lessThan(groupBottom - 8),
        reason: 'avatar must not drop to the group foot / reactions row');
    expect((avatarBottom - bubbleBottom).abs(), lessThan(40),
        reason: 'avatar bottom should track the last bubble');
  });
}

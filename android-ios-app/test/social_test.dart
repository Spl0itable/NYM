import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/context_menu/context_menu_actions.dart';

const _self = '0000000000000000000000000000000000000000000000000000000000001a2b';
const _other = '11111111111111111111111111111111111111111111111111111111deadbeef';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final container = ProviderContainer(
    overrides: [keyValueStoreProvider.overrideWithValue(kv)],
  );
  // Switch the seeded store to a deterministic live identity.
  container.read(appStateProvider.notifier).goLive(_self, 'you#1a2b');
  return container;
}

/// Seeds a channel message from [pubkey] into the active channel view.
void _seedChannelMessage(
  ProviderContainer c, {
  required String id,
  required String pubkey,
  required String author,
  required String content,
  bool isOwn = false,
}) {
  final notifier = c.read(appStateProvider.notifier);
  final state = c.read(appStateProvider);
  final list = state.messages.putIfAbsent(state.view.storageKey, () => []);
  list.add(Message(
    id: id,
    pubkey: pubkey,
    author: author,
    content: content,
    createdAt: 1000 + list.length,
    isOwn: isOwn,
    channel: state.view.id,
  ));
  // Force a rebuild so providers recompute.
  notifier.touchChannelActivity(state.view.storageKey);
}

void main() {
  group('friends', () {
    test('toggleFriend adds/removes, persists nym_friends, isFriend reflects it',
        () async {
      final c = await _container();
      addTearDown(c.dispose);
      final controller = c.read(nostrControllerProvider);

      expect(c.read(appStateProvider).isFriend(_other), isFalse);

      final added = controller.toggleFriend(_other);
      expect(added, isTrue);
      expect(c.read(appStateProvider).isFriend(_other), isTrue);
      expect(c.read(friendsProvider), contains(_other));

      // Persisted as a JSON array under nym_friends.
      final kv = c.read(keyValueStoreProvider);
      final persisted = jsonDecode(kv.getString(StorageKeys.friends)!) as List;
      expect(persisted, contains(_other));

      final removed = controller.toggleFriend(_other);
      expect(removed, isFalse);
      expect(c.read(appStateProvider).isFriend(_other), isFalse);
      final after = jsonDecode(kv.getString(StorageKeys.friends)!) as List;
      expect(after, isEmpty);
    });

    test('hydrateSocialState restores Sets (keywords lowercased)', () async {
      final c = await _container();
      addTearDown(c.dispose);
      c.read(appStateProvider.notifier).hydrateSocialState(
        friends: {_other},
        blockedUsers: {_other},
        blockedKeywords: {'SPAM'},
      );
      final s = c.read(appStateProvider);
      expect(s.isFriend(_other), isTrue);
      expect(s.isUserBlocked(_other), isTrue);
      // Keywords are lowercased on hydrate.
      expect(s.blockedKeywords, contains('spam'));
    });
  });

  group('user blocking', () {
    test('blockUser hides messages from a channel list; unblock restores',
        () async {
      final c = await _container();
      addTearDown(c.dispose);
      final controller = c.read(nostrControllerProvider);

      _seedChannelMessage(c,
          id: 'mine',
          pubkey: _self,
          author: 'you#1a2b',
          content: 'hello',
          isOwn: true);
      _seedChannelMessage(c,
          id: 'theirs',
          pubkey: _other,
          author: 'satoshi#beef',
          content: 'gm');

      // Both visible initially.
      var msgs = c.read(messagesForCurrentViewProvider);
      expect(msgs.map((m) => m.id), containsAll(['mine', 'theirs']));

      controller.blockUser(_other);
      msgs = c.read(messagesForCurrentViewProvider);
      expect(msgs.map((m) => m.id), contains('mine'));
      expect(msgs.map((m) => m.id), isNot(contains('theirs')));
      // The blocked author is hidden from the user list too.
      expect(c.read(usersProvider).containsKey(_other), isFalse);
      expect(c.read(blockedUsersProvider), contains(_other));

      controller.unblockUser(_other);
      msgs = c.read(messagesForCurrentViewProvider);
      expect(msgs.map((m) => m.id), contains('theirs'));
    });
  });

  group('keyword filtering', () {
    test('matches content OR author nym, case-insensitive; non-match passes',
        () async {
      final c = await _container();
      addTearDown(c.dispose);
      final controller = c.read(nostrControllerProvider);

      _seedChannelMessage(c,
          id: 'badContent',
          pubkey: _other,
          author: 'satoshi#beef',
          content: 'buy my SPAM now');
      _seedChannelMessage(c,
          id: 'badNym',
          pubkey: '2222222222222222222222222222222222222222222222222222222222223c4d',
          author: 'Spammer#3c4d',
          content: 'totally innocent');
      _seedChannelMessage(c,
          id: 'clean',
          pubkey: '33333333333333333333333333333333333333333333333333333333000099ff',
          author: 'trinity#99ff',
          content: 'gm friends');

      controller.addBlockedKeyword('spam');
      final msgs =
          c.read(messagesForCurrentViewProvider).map((m) => m.id).toList();
      // Content match hidden, author-nym match hidden (case-insensitive),
      // unrelated message passes.
      expect(msgs, isNot(contains('badContent')));
      expect(msgs, isNot(contains('badNym')));
      expect(msgs, contains('clean'));

      // hasBlockedKeyword direct checks.
      final s = c.read(appStateProvider);
      expect(s.hasBlockedKeyword('this is SPAM'), isTrue);
      expect(s.hasBlockedKeyword('clean', 'BigSpammer#abcd'), isTrue);
      expect(s.hasBlockedKeyword('clean', 'trinity#99ff'), isFalse);

      controller.removeBlockedKeyword('spam');
      expect(
        c.read(messagesForCurrentViewProvider).map((m) => m.id),
        containsAll(['badContent', 'badNym', 'clean']),
      );
    });

    test('own messages are not keyword-filtered', () async {
      final c = await _container();
      addTearDown(c.dispose);
      final controller = c.read(nostrControllerProvider);
      _seedChannelMessage(c,
          id: 'ownSpam',
          pubkey: _self,
          author: 'you#1a2b',
          content: 'my own spam',
          isOwn: true);
      controller.addBlockedKeyword('spam');
      expect(
        c.read(messagesForCurrentViewProvider).map((m) => m.id),
        contains('ownSpam'),
      );
    });
  });

  group('edit / delete tag builders', () {
    test('editMessage builds the [edit, originalId] tag (channel)', () {
      final tags = buildChannelEditTags(
        nym: 'you#1a2b',
        channelKey: 'nymchat',
        isGeohash: false,
        originalId: 'orig123',
      );
      expect(tags, contains(equals(['n', 'you#1a2b'])));
      expect(tags, contains(equals(['d', 'nymchat'])));
      expect(tags, contains(equals(['edit', 'orig123'])));
    });

    test('geohash channel edit uses a g tag', () {
      final tags = buildChannelEditTags(
        nym: 'you#1a2b',
        channelKey: 'u4pruyd',
        isGeohash: true,
        originalId: 'orig123',
      );
      expect(tags, contains(equals(['g', 'u4pruyd'])));
      expect(tags, contains(equals(['edit', 'orig123'])));
    });

    test('deleteMessage builds kind-5 [e,id],[k,kind] tags', () {
      final tags = buildDeletionTags('evt9', '20000');
      expect(tags, [
        ['e', 'evt9'],
        ['k', '20000'],
      ]);
    });

    test('applyLocalEdit rewrites content + flags edited', () async {
      final c = await _container();
      addTearDown(c.dispose);
      _seedChannelMessage(c,
          id: 'e1',
          pubkey: _self,
          author: 'you#1a2b',
          content: 'old',
          isOwn: true);
      final ok = c.read(appStateProvider.notifier).applyLocalEdit('e1', 'new');
      expect(ok, isTrue);
      final m = c
          .read(messagesForCurrentViewProvider)
          .firstWhere((m) => m.id == 'e1');
      expect(m.content, 'new');
      expect(m.isEdited, isTrue);
    });

    test('removeMessage drops it from the list', () async {
      final c = await _container();
      addTearDown(c.dispose);
      _seedChannelMessage(c,
          id: 'd1', pubkey: _self, author: 'you#1a2b', content: 'bye', isOwn: true);
      expect(
          c.read(messagesForCurrentViewProvider).map((m) => m.id), contains('d1'));
      c.read(appStateProvider.notifier).removeMessage('d1');
      expect(c.read(messagesForCurrentViewProvider).map((m) => m.id),
          isNot(contains('d1')));
    });
  });

  group('reactor nyms accessor', () {
    test('exposes real reactor nyms for the reactors modal', () async {
      final c = await _container();
      addTearDown(c.dispose);
      final notifier = c.read(appStateProvider.notifier);
      notifier.applyReaction(
        messageId: 'm1',
        emoji: '🔥',
        reactor: _other,
        removed: false,
        reactorNym: 'satoshi#beef',
      );
      expect(notifier.reactorNyms('m1', '🔥'), contains('satoshi#beef'));
      expect(notifier.reactorsFor('m1', '🔥'), {_other: 'satoshi#beef'});
    });
  });

  group('context menu action visibility', () {
    CtxTarget t({
      required bool isSelf,
      bool inGroup = false,
      bool iAmOwner = false,
      bool iAmMod = false,
      bool targetIsMember = false,
      bool targetIsOwner = false,
      bool targetIsMod = false,
    }) =>
        CtxTarget(
          pubkey: 'pk',
          nym: 'alice',
          isSelf: isSelf,
          content: 'hello',
          messageId: 'm1',
          inGroup: inGroup,
          iAmOwner: iAmOwner,
          iAmMod: iAmMod,
          targetIsMember: targetIsMember,
          targetIsOwner: targetIsOwner,
          targetIsMod: targetIsMod,
        );

    test('Edit/Delete only for own messages', () {
      final own = buildContextMenuActions(t(isSelf: true));
      expect(own, contains(CtxAction.edit));
      expect(own, contains(CtxAction.delete));

      final other = buildContextMenuActions(t(isSelf: false));
      expect(other, isNot(contains(CtxAction.edit)));
      // No mod role → no delete for someone else's message.
      expect(other, isNot(contains(CtxAction.delete)));
    });

    test('Friend/Block shown for others, not self', () {
      final other = buildContextMenuActions(t(isSelf: false));
      expect(other, contains(CtxAction.friend));
      expect(other, contains(CtxAction.block));

      final own = buildContextMenuActions(t(isSelf: true));
      expect(own, isNot(contains(CtxAction.friend)));
      expect(own, isNot(contains(CtxAction.block)));
    });

    test('mod actions only when the viewer can moderate', () {
      // Plain member viewing another member: no mod actions.
      final member = buildContextMenuActions(t(
        isSelf: false,
        inGroup: true,
        targetIsMember: true,
      ));
      expect(member, isNot(contains(CtxAction.kick)));
      expect(member, isNot(contains(CtxAction.makeMod)));
      expect(member, isNot(contains(CtxAction.delete)));

      // Owner viewing a regular member: kick/ban/promote/transfer + mod-delete.
      final owner = buildContextMenuActions(t(
        isSelf: false,
        inGroup: true,
        iAmOwner: true,
        targetIsMember: true,
      ));
      expect(owner, contains(CtxAction.kick));
      expect(owner, contains(CtxAction.ban));
      expect(owner, contains(CtxAction.makeMod));
      expect(owner, contains(CtxAction.transferOwner));
      expect(owner, contains(CtxAction.delete));

      // A mod can kick + mod-delete, but cannot promote/transfer (owner-only).
      final mod = buildContextMenuActions(t(
        isSelf: false,
        inGroup: true,
        iAmMod: true,
        targetIsMember: true,
      ));
      expect(mod, contains(CtxAction.kick));
      expect(mod, contains(CtxAction.delete));
      expect(mod, isNot(contains(CtxAction.makeMod)));
      expect(mod, isNot(contains(CtxAction.transferOwner)));
    });
  });
}

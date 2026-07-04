import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
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
///
/// Marks [pubkey] into the web-of-trust graph so the message isn't hidden by the
/// `nym-vouch` spam gate ([AppState.isSpamGated], folded into
/// [AppState.isMessageFiltered]); these tests exercise keyword/block filtering,
/// not the spam gate, so the senders stand in for already-trusted participants.
void _seedChannelMessage(
  ProviderContainer c, {
  required String id,
  required String pubkey,
  required String author,
  required String content,
  bool isOwn = false,
}) {
  final notifier = c.read(appStateProvider.notifier);
  if (!isOwn) notifier.markNymchatPubkey(pubkey);
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

    test('an own message that hits a blocked keyword is hidden locally', () async {
      // The PWA hides the user's OWN keyword-matching message from the local
      // view (it was still sent) and posts a "hidden locally" notice
      // (messages.js:638-642). [sendLocal] inserts the echo + the notice; the
      // body is then filtered out by [isMessageFiltered].
      final c = await _container();
      addTearDown(c.dispose);
      final controller = c.read(nostrControllerProvider);
      controller.addBlockedKeyword('spam');
      c.read(appStateProvider.notifier).sendLocal('my own spam message');

      final msgs = c.read(messagesForCurrentViewProvider);
      // The flagged own message body is hidden...
      expect(
        msgs.any((m) => m.content == 'my own spam message'),
        isFalse,
      );
      // ...and a system notice explains it was hidden locally but still sent.
      expect(
        msgs.any((m) =>
            m.kind == MessageKind.system &&
            m.content.contains('hidden locally') &&
            m.content.contains('It was still sent')),
        isTrue,
      );
    });

    test('an own message flagged as spam stays visible with a report action',
        () async {
      // Own heuristic-spam is NOT hidden from the sender — the PWA still shows it
      // (with a self-only notice + "Report false positive" button,
      // messages.js:643-647). A single random alphanumeric token trips the
      // heuristic (cross-checked against the reference JS isSpamMessage).
      final c = await _container();
      addTearDown(c.dispose);
      c.read(appStateProvider.notifier).sendLocal('Xq7zkwjpQmbvxz');

      final msgs = c.read(messagesForCurrentViewProvider);
      // The own spam message is still shown to the sender.
      expect(msgs.any((m) => m.content == 'Xq7zkwjpQmbvxz'), isTrue);
      // A system notice carries the "Report false positive" action.
      final notice = msgs.firstWhere(
        (m) => m.kind == MessageKind.system && m.systemAction != null,
        orElse: () => Message(
            id: '_none', pubkey: '', author: '', content: '', createdAt: 0),
      );
      expect(notice.id, isNot('_none'));
      expect(notice.systemAction!.kind,
          SystemActionKind.reportSpamFalsePositive);
      expect(notice.systemAction!.label, 'Report false positive');
      expect(notice.systemAction!.payload, 'Xq7zkwjpQmbvxz');
      expect(notice.content, contains('flagged by the spam filter'));
    });

    test('an incoming non-own spam message is hidden from the view', () async {
      // The `spamHit` term of the PWA non-own hide branch (messages.js:648):
      // a stranger's gibberish message is filtered out of the list.
      final c = await _container();
      addTearDown(c.dispose);
      _seedChannelMessage(c,
          id: 'cleanGm',
          pubkey: _other,
          author: 'satoshi#beef',
          content: 'gm everyone');
      _seedChannelMessage(c,
          id: 'spamMsg',
          pubkey: _other,
          author: 'satoshi#beef',
          content: 'Xq7zkwjpQmbvxz');
      final ids = c.read(messagesForCurrentViewProvider).map((m) => m.id);
      expect(ids, contains('cleanGm'));
      expect(ids, isNot(contains('spamMsg')));
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

    // The user-reported bug: an incoming edit (event carries ['edit', origId])
    // must REWRITE the original in place, never append a second bubble.
    NostrEvent channelMsg(String id, String content,
            {String? editOf}) =>
        NostrEvent(
          id: id,
          pubkey: _other,
          createdAt: 1000,
          kind: EventKind.namedChannel,
          tags: [
            ['d', 'nymchat'],
            ['n', 'sat#beef'],
            if (editOf != null) ['edit', editOf],
          ],
          content: content,
        );

    test('incoming channel edit rewrites in place (no duplicate)', () async {
      final c = await _container();
      addTearDown(c.dispose);
      final n = c.read(appStateProvider.notifier);
      n.markNymchatPubkey(_other);
      n.ingestEvent(channelMsg('orig', 'hello'));
      // The edit event for the same original must not add a new row.
      n.ingestEvent(channelMsg('editEvt', 'hello (edited)', editOf: 'orig'));
      final msgs = c
          .read(messagesForCurrentViewProvider)
          .where((m) => m.id == 'orig' || m.id == 'editEvt')
          .toList();
      expect(msgs.length, 1, reason: 'edit must not append a second message');
      expect(msgs.single.content, 'hello (edited)');
      expect(msgs.single.isEdited, isTrue);
    });

    test('out-of-order channel edit is buffered then applied on arrival',
        () async {
      final c = await _container();
      addTearDown(c.dispose);
      final n = c.read(appStateProvider.notifier);
      n.markNymchatPubkey(_other);
      // Edit arrives FIRST (original not seen yet) — buffered, not shown.
      n.ingestEvent(channelMsg('editEvt', 'late edit', editOf: 'orig'));
      expect(
          c.read(messagesForCurrentViewProvider).map((m) => m.id),
          isNot(contains('editEvt')));
      // Original lands → the buffered edit is replayed onto it in place.
      n.ingestEvent(channelMsg('orig', 'first text'));
      final msgs = c
          .read(messagesForCurrentViewProvider)
          .where((m) => m.id == 'orig' || m.id == 'editEvt')
          .toList();
      expect(msgs.length, 1);
      expect(msgs.single.content, 'late edit');
      expect(msgs.single.isEdited, isTrue);
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

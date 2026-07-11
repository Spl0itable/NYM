// Regression tests for the three group-chat issues:
//   BUG2 — a custom group avatar/banner set by the owner must converge on a
//          member that learned the group from a backfilled MESSAGE (bare shell,
//          `createdBy == null`), not just on a properly-invited member.
//   BUG3 — `groupsProvider` must yield a fresh value when a group mutates IN
//          PLACE (avatar via metadata, `lastMessageTime` on a new message) so a
//          widget that watches only it (the columns deck) rebuilds and the PM
//          list repositions.
//   BUG1 — an unread group message must be recorded into the bell history and
//          count toward the unread badge, exactly like a PM.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/features/groups/group_logic.dart';
import 'package:nym_bar/models/group.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/state/app_state.dart';

Message _groupMsg({
  required String groupId,
  required String pubkey,
  required String id,
  required int createdAtSec,
  bool isOwn = false,
}) =>
    Message(
      id: id,
      author: 'a#0001',
      pubkey: pubkey,
      content: 'hi',
      createdAt: createdAtSec,
      isOwn: isOwn,
      isGroup: true,
      groupId: groupId,
      conversationKey: GroupLogic.groupStorageKey(groupId),
      nymMessageId: 'nym_$id',
    );

List<List<String>> _piggyback({
  required int metaTs,
  String avatar = '',
  String banner = '',
  String description = '',
}) =>
    [
      ['meta_ts', '$metaTs'],
      ['banner', banner],
      ['avatar', avatar],
      ['description', description],
      ['allow_invites', '1'],
      ['invite_enabled', '0'],
      ['invite_epoch', '0'],
    ];

void main() {
  group('BUG2 — group avatar/banner converges', () {
    test('bare message-shell (createdBy null) heals avatar + owner from the '
        'owner metadata piggyback', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier)
        ..goLive('self', 'me#0001');

      // Member learns the group from a MESSAGE first — a bare shell.
      n.mergeGroupFromMessage(
        groupId: 'gX',
        name: 'Squad',
        memberPubkeys: const ['owner', 'self'],
        timestampMs: 1000,
      );
      expect(n.groupById('gX')!.createdBy, isNull);
      expect(n.groupById('gX')!.avatar, isNull);

      final result = n.applyGroupControl(
        groupId: 'gX',
        type: GroupControlType.metadata,
        tags: _piggyback(
            metaTs: 1700, avatar: 'https://cdn/a.png', banner: 'https://cdn/b.png'),
        senderPubkey: 'owner',
        ts: 1700,
      );
      expect(result, GroupControlResult.applied);
      final g = n.groupById('gX')!;
      expect(g.avatar, 'https://cdn/a.png');
      expect(g.banner, 'https://cdn/b.png');
      expect(g.createdBy, 'owner',
          reason: 'the owner-only metadata establishes the owner on a bare shell');
      expect(g.metaUpdatedAt, 1700);
    });

    test('a NON-owner cannot overwrite a KNOWN owner (anti-spoof preserved)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier)
        ..goLive('self', 'me#0001');
      n.upsertGroup(Group(
        id: 'gX',
        name: 'Squad',
        members: const ['owner', 'imposter', 'self'],
        createdBy: 'owner',
      ));

      final result = n.applyGroupControl(
        groupId: 'gX',
        type: GroupControlType.metadata,
        tags: _piggyback(metaTs: 1700, avatar: 'https://evil/x.png'),
        senderPubkey: 'imposter',
        ts: 1700,
      );
      expect(result, GroupControlResult.noop);
      expect(n.groupById('gX')!.avatar, isNull,
          reason: 'a known owner is never overridden by another member');
      expect(n.groupById('gX')!.createdBy, 'owner');
    });

    test('an invited member (createdBy set) still converges normally', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier)
        ..goLive('self', 'me#0001');
      n.upsertGroup(Group(
        id: 'gX',
        name: 'Squad',
        members: const ['owner', 'self'],
        createdBy: 'owner',
      ));
      n.applyGroupControl(
        groupId: 'gX',
        type: GroupControlType.metadata,
        tags: _piggyback(metaTs: 1700, avatar: 'https://cdn/a.png'),
        senderPubkey: 'owner',
        ts: 1700,
      );
      expect(n.groupById('gX')!.avatar, 'https://cdn/a.png');
    });
  });

  group('BUG3 — groupsProvider reactivity', () {
    test('yields a fresh (non-identical) value after a group mutates in place',
        () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier)
        ..goLive('self', 'me#0001');
      n.upsertGroup(Group(
        id: 'gA',
        name: 'A',
        members: const ['owner', 'self'],
        createdBy: 'owner',
        lastMessageTime: 1000,
      ));

      final before = container.read(groupsProvider);
      final landed = n.ingestGroupMessage(_groupMsg(
        groupId: 'gA',
        pubkey: 'owner',
        id: 'm1',
        createdAtSec: 5, // 5000 ms
      ));
      expect(landed, isTrue);
      expect(n.groupById('gA')!.lastMessageTime, 5000);

      final after = container.read(groupsProvider);
      expect(identical(before, after), isFalse,
          reason: 'a widget watching only groupsProvider must rebuild (BUG3)');
    });

    test('a group avatar change also produces a fresh provider value', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier)
        ..goLive('self', 'me#0001');
      n.upsertGroup(Group(
        id: 'gA',
        name: 'A',
        members: const ['owner', 'self'],
        createdBy: 'owner',
      ));
      final before = container.read(groupsProvider);
      n.applyGroupControl(
        groupId: 'gA',
        type: GroupControlType.metadata,
        tags: _piggyback(metaTs: 1700, avatar: 'https://cdn/a.png'),
        senderPubkey: 'owner',
        ts: 1700,
      );
      final after = container.read(groupsProvider);
      expect(identical(before, after), isFalse);
      expect(after.first.avatar, 'https://cdn/a.png');
    });
  });

  group('BUG1 — group notifications record + count unread', () {
    test('an unread group notification lands in history and bumps the badge, '
        'like a PM', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final hist = container.read(notificationHistoryProvider.notifier);
      // Let the async hydration settle so record() isn't buffered.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final now = DateTime.now().millisecondsSinceEpoch;
      hist.record(
        type: 'pm',
        title: 'bob',
        body: 'hi pm',
        route: 'bob_pk',
        ts: now,
        eventId: 'evtPM',
        senderPubkey: 'bob_pk',
      );
      hist.record(
        type: 'group',
        title: 'alice',
        body: 'hello group',
        route: 'gX',
        ts: now,
        eventId: 'evtGRP',
        senderPubkey: 'owner',
        contextLabel: 'in Squad',
      );

      final state = container.read(notificationHistoryProvider);
      final groupEntries = state.entries.where((e) => e.type == 'group').toList();
      expect(groupEntries.length, 1);
      expect(groupEntries.single.viewed, isFalse,
          reason: 'a fresh unread group notification must not be pre-viewed');
      expect(state.unread, greaterThanOrEqualTo(2),
          reason: 'both the PM and the group notification count as unread');
    });

    test('a historical (silent) but recent group notification still records '
        'unread', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final hist = container.read(notificationHistoryProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 2 minutes old: past the 30s "loud" window (so the controller records it
      // silently) but well within the 24h bell window.
      final ts = DateTime.now().millisecondsSinceEpoch - 2 * 60 * 1000;
      hist.record(
        type: 'group',
        title: 'alice',
        body: 'backlogged group line',
        route: 'gX',
        ts: ts,
        eventId: 'evtOld',
        senderPubkey: 'owner',
        contextLabel: 'in Squad',
      );

      final state = container.read(notificationHistoryProvider);
      expect(state.entries.any((e) => e.type == 'group'), isTrue,
          reason: 'a recent silent group message still enters the bell history');
      expect(state.unread, greaterThanOrEqualTo(1));
    });
  });
}

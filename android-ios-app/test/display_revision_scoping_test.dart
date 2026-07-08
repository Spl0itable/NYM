import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/state/app_state.dart';

NostrEvent _channelMsg(String d, int ts) => NostrEvent(
      id: 'cm_${d}_$ts',
      pubkey: 'alice_pk',
      createdAt: ts,
      kind: EventKind.namedChannel,
      tags: [
        ['d', d],
        ['n', 'alice'],
      ],
      content: 'm$ts',
    );

void main() {
  test('display revision advances on message ingest, holds on ambient typing',
      () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    n.switchView(const ChatView.channel('room'));

    final rev0 = n.state.displayRev;
    n.ingestEvent(_channelMsg('room', 1000));
    expect(n.state.displayRev, greaterThan(rev0),
        reason: 'a rendered change must advance the display revision');

    final revAfterMsg = n.state.displayRev;
    n.setTyping(storageKey: '#room', pubkey: 'bob_pk', typing: true);
    expect(n.state.displayRev, revAfterMsg,
        reason: 'typing must not advance the display revision');
  });

  // A display-revision–scoped provider recomputes (returns a fresh instance)
  // ONLY when its inputs change. Identity comparison of consecutive reads is a
  // synchronous, reliable probe for "did this provider re-run?".
  test('messagesForCurrentViewProvider re-runs on a message, NOT on typing', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(appStateProvider.notifier)
      ..goLive('selfpk', 'me#0001')
      ..switchView(const ChatView.channel('room'));

    final beforeMsg = c.read(messagesForCurrentViewProvider);
    notifier.ingestEvent(_channelMsg('room', 2000));
    final afterMsg = c.read(messagesForCurrentViewProvider);
    expect(identical(beforeMsg, afterMsg), isFalse,
        reason: 'a new message must re-run the message list provider');
    expect(afterMsg.length, 1);

    final beforeTyping = c.read(messagesForCurrentViewProvider);
    notifier.setTyping(storageKey: '#room', pubkey: 'bob_pk', typing: true);
    notifier.setTyping(storageKey: '#room', pubkey: 'bob_pk', typing: false);
    final afterTyping = c.read(messagesForCurrentViewProvider);
    expect(identical(beforeTyping, afterTyping), isTrue,
        reason: 'typing churn must NOT re-run the whole message list provider');
  });

  test('a reaction advances the display revision so the message list rebuilds',
      () {
    // The reactions map is mutated in place (stable identity), so reaction
    // rendering rides on the message-list rebuild. The contract that matters:
    // a reaction bumps displayRev (→ the list re-runs), typing does not.
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    n.switchView(const ChatView.channel('room'));
    n.ingestEvent(_channelMsg('room', 3000));

    final rev = n.state.displayRev;
    n.applyReaction(
      messageId: 'cm_room_3000',
      emoji: '🔥',
      reactor: 'bob_pk',
      removed: false,
    );
    expect(n.state.displayRev, greaterThan(rev),
        reason: 'a reaction must advance the display revision');
  });

  test('a reaction re-runs messagesForCurrentViewProvider (so reactions render)',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(appStateProvider.notifier)
      ..goLive('selfpk', 'me#0001')
      ..switchView(const ChatView.channel('room'));
    notifier.ingestEvent(_channelMsg('room', 3000));

    final before = c.read(messagesForCurrentViewProvider);
    notifier.applyReaction(
      messageId: 'cm_room_3000',
      emoji: '🔥',
      reactor: 'bob_pk',
      removed: false,
    );
    final after = c.read(messagesForCurrentViewProvider);
    expect(identical(before, after), isFalse,
        reason: 'the message list must re-run so the new reaction renders');
  });

  test('the typing indicator provider STILL reflects a typing event', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(appStateProvider.notifier)
      ..goLive('selfpk', 'me#0001')
      ..switchView(const ChatView.channel('room'));

    expect(c.read(typingForCurrentViewProvider), isEmpty);
    notifier.setTyping(storageKey: '#room', pubkey: 'bob_pk', typing: true);
    expect(c.read(typingForCurrentViewProvider), contains('bob_pk'),
        reason: 'ambient typing must still surface in the typing widget');
  });

  group('presence is ambient unless it changes a row-visible field', () {
    test('a bare status change is ambient (no display-revision bump)', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      // Establish the user with a known nym first (this bump is expected).
      n.setUserPresence(
          pubkey: 'bob_pk', status: UserStatus.online, nym: 'bob');
      final rev = n.state.displayRev;

      // Same nym, only the online/away status flips → ambient.
      n.setUserPresence(
          pubkey: 'bob_pk', status: UserStatus.away, nym: 'bob');
      expect(n.state.displayRev, rev,
          reason: 'a bare status change must not rebuild the message list');
      // …but the store still reflects it (sidebar/header read this).
      expect(n.state.users['bob_pk']!.status, UserStatus.away);
    });

    test('a nym change bumps the display revision', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.setUserPresence(
          pubkey: 'bob_pk', status: UserStatus.online, nym: 'bob');
      final rev = n.state.displayRev;
      n.setUserPresence(
          pubkey: 'bob_pk', status: UserStatus.online, nym: 'robert');
      expect(n.state.displayRev, greaterThan(rev),
          reason: 'the author nym is drawn in rows — must rebuild');
    });

    test('an avatar change bumps the display revision', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.setUserPresence(
          pubkey: 'bob_pk', status: UserStatus.online, nym: 'bob');
      final rev = n.state.displayRev;
      n.setUserPresence(
        pubkey: 'bob_pk',
        status: UserStatus.online,
        nym: 'bob',
        hasAvatarTag: true,
        avatarUrl: 'https://example/new.png',
      );
      expect(n.state.displayRev, greaterThan(rev),
          reason: 'the author avatar is drawn in rows — must rebuild');
    });
  });

  test('clearUnread is ambient: clears the badge without rebuilding the list',
      () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    // Active view is elsewhere so an inbound message to #room accrues unread.
    n.switchView(const ChatView.channel('other'));
    n.ingestEvent(_channelMsg('room', 5000));
    expect(n.state.unreadCounts['#room'], 1);

    final rev = n.state.displayRev;
    n.clearUnread('#room');
    expect(n.state.unreadCounts.containsKey('#room'), isFalse,
        reason: 'the badge is cleared');
    expect(n.state.displayRev, rev,
        reason: 'clearing an unread badge must not rebuild the message list');
  });
}

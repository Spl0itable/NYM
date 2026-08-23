// Guards the cross-context reaction leak: a reaction seen in one conversation
// re-appearing on an unrelated message you sent later.
//
// The mechanism was that optimistic message ids came from a per-session counter
// (`_optim_0`, `_optim_1`, …). A reaction landing on your own message before its
// relay echo reconciled was filed under that placeholder id and PERSISTED under
// it, so the next launch — where the counter starts over — grafted it onto
// whatever message happened to be the Nth send, in whatever conversation.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/state/app_state.dart';

const _stranger =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

AppStateNotifier _fresh() {
  final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
  n.switchView(const ChatView.channel('room'));
  return n;
}

void main() {
  test('placeholder ids are unique across sessions', () {
    // Two notifiers stand in for two launches. Before the fix both produced
    // `_optim_0`, which is what let stale state find a new home.
    final first = _fresh().sendLocal('hello');
    final second = _fresh().sendLocal('hello');

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(first!.id, startsWith('_optim_'),
        reason: 'the prefix is load-bearing for the persistence guards');
    expect(first.id, isNot(second!.id),
        reason: 'the same send position in two sessions must not share an id');
  });

  test('placeholder-keyed reactions are never persisted', () {
    final n = _fresh();
    final mine = n.sendLocal('my message')!;

    // A stranger reacts before our own echo reconciles, so it files under the
    // placeholder id.
    n.applyReaction(
      messageId: mine.id,
      emoji: '👍',
      reactor: _stranger,
      removed: false,
      reactorNym: 'them#beef',
    );
    expect(n.state.reactions[mine.id], isNotEmpty,
        reason: 'it should still render in THIS session');

    // But it must not reach disk, because the key means nothing next launch.
    expect(n.reactionEntriesSnapshot().keys, isNot(contains(mine.id)));
  });

  test('a poisoned cache from an older build is discarded on hydrate', () {
    // Shipped builds already wrote these, so restoring must actively drop them
    // rather than merely stopping new ones.
    final n = _fresh();
    n.hydrateReactions({
      '_optim_0': [
        ['👍', [[_stranger, 'them#beef']]]
      ],
    });
    final mine = n.sendLocal('a fresh message')!;
    expect(n.state.reactions[mine.id] ?? const [], isEmpty);
    expect(n.state.reactions['_optim_0'] ?? const [], isEmpty);
  });

  test('a real reaction survives the placeholder -> real id swap', () {
    // The other half: reactions that arrive in the gap must not be orphaned
    // under the placeholder when the row adopts its event id.
    final n = _fresh();
    final mine = n.sendLocal('my message')!;
    final placeholderId = mine.id;

    n.applyReaction(
      messageId: placeholderId,
      emoji: '🎉',
      reactor: _stranger,
      removed: false,
      reactorNym: 'them#beef',
    );

    // The publish await resolves and the row adopts its signed event id.
    n.replaceOptimistic(placeholderId, 'f' * 64);

    expect(n.state.reactions['f' * 64], isNotEmpty,
        reason: 'the reaction belongs to the message, not to the placeholder');
    expect(n.state.reactions[placeholderId] ?? const [], isEmpty);
    expect(n.reactionEntriesSnapshot().keys, contains('f' * 64),
        reason: 'and now it is safe to persist, under a real id');
  });
}

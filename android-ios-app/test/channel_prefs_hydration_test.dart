// Favourited / hidden / blocked channels were persisted on every change but
// never read back at launch, so they silently reverted on the next start. These
// pin the restore.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/state/app_state.dart';

void main() {
  test('pinned, hidden and blocked channels restore', () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    n.hydrateSocialState(
      pinnedChannels: {'bitcoin', 'nostr'},
      hiddenChannels: {'spam'},
      blockedChannels: {'scam'},
    );
    expect(n.state.pinnedChannels, containsAll(<String>['bitcoin', 'nostr']));
    expect(n.state.hiddenChannels, contains('spam'));
    expect(n.state.blockedChannels, contains('scam'));
  });

  test('keys are folded to lowercase on the way in', () {
    // Channel keys are lowercase everywhere else, so a set written by an older
    // build with mixed case must still match at lookup time.
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    n.hydrateSocialState(pinnedChannels: {'Bitcoin', 'NOSTR'});
    expect(n.state.pinnedChannels, containsAll(<String>['bitcoin', 'nostr']));
    expect(n.state.pinnedChannels, isNot(contains('Bitcoin')));
  });

  test('hydration is additive and does not clobber a live set', () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    n.state.pinnedChannels.add('already-here');
    n.hydrateSocialState(pinnedChannels: {'from-disk'});
    expect(n.state.pinnedChannels, containsAll(<String>['already-here', 'from-disk']));
  });

  test('omitted sets leave state untouched', () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    n.state.pinnedChannels.add('keep-me');
    n.hydrateSocialState(friends: {'abc'});
    expect(n.state.pinnedChannels, contains('keep-me'));
  });
}

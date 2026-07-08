import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

NostrEvent _msg(String d, int ts, {String id = ''}) => NostrEvent(
      id: id.isEmpty ? 'cm_${d}_$ts' : id,
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
  test('channelLastActivity only rises — a backfilled OLD message never lowers it',
      () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    // A fresh live message stamps recent activity (stored as createdAt*1000 ms).
    n.ingestEvent(_msg('busy', 2000));
    final tNewest = n.state.channelLastActivity['#busy']!;

    // A D1 backfill replays OLDER history through the same path; it must NOT
    // overwrite the newer activity time (the sidebar-sort regression).
    n.ingestEvent(_msg('busy', 1000));
    n.ingestEvent(_msg('busy', 500));
    expect(n.state.channelLastActivity['#busy'], tNewest,
        reason: 'old backfilled messages must not sink the channel');

    // A genuinely newer message advances it.
    n.ingestEvent(_msg('busy', 3000));
    expect(n.state.channelLastActivity['#busy']! > tNewest, isTrue);
  });

  test('two channels order by their newest activity regardless of backfill order',
      () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    n.ingestEvent(_msg('alpha', 100));
    n.ingestEvent(_msg('beta', 200));
    // Backfill a big OLD page into beta AFTER its recent message.
    for (var ts = 10; ts < 60; ts++) {
      n.ingestEvent(_msg('beta', ts));
    }
    // beta's newest (200) still beats alpha's newest (100).
    expect(n.state.channelLastActivity['#beta']! >
        n.state.channelLastActivity['#alpha']!, isTrue);
  });

  test('index-backed reaction guard: isKnownMessageId tracks ingested ids', () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    expect(n.isKnownMessageId('cm_x_1'), isFalse);
    n.ingestEvent(_msg('x', 1, id: 'cm_x_1'));
    expect(n.isKnownMessageId('cm_x_1'), isTrue);
    // A removed message's id is no longer known (index de-indexed on remove).
    n.removeMessage('cm_x_1');
    expect(n.isKnownMessageId('cm_x_1'), isFalse);
  });
}

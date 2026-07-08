import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

/// A named-channel (kind 23333) message in channel [d] from [pubkey] at [ts].
NostrEvent _msg(String d, int ts, String content) => NostrEvent(
      id: 'cm_$ts',
      pubkey: 'alice_pk',
      createdAt: ts,
      kind: EventKind.namedChannel,
      tags: [
        ['d', d],
        ['n', 'alice'],
      ],
      content: content,
    );

void main() {
  const cap = 1000; // mirrors AppStateNotifier._kChannelHistoryCap
  const key = '#flood';

  test('non-batched ingest caps a public channel to the newest N, oldest dropped',
      () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    final base = 1000000000;
    // Ingest cap + 500 messages one at a time (the non-batched path).
    for (var i = 0; i < cap + 500; i++) {
      n.ingestEvent(_msg('flood', base + i, 'm$i'));
    }
    final list = n.state.messages[key]!;
    expect(list.length, cap, reason: 'in-memory history is bounded to the cap');
    // Sorted oldest-first; the oldest 500 (m0..m499) must have been evicted.
    expect(list.first.content, 'm500');
    expect(list.last.content, 'm${cap + 499}');
  });

  test('batched ingest caps after the deferred sort (newest kept)', () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    final base = 1000000000;
    // Feed messages OUT OF ORDER inside one batch so the deferred sort matters,
    // then confirm the cap keeps the newest by timestamp, not by arrival order.
    n.runBatched(() {
      for (var i = cap + 500 - 1; i >= 0; i--) {
        n.ingestEvent(_msg('flood', base + i, 'm$i'));
      }
    });
    final list = n.state.messages[key]!;
    expect(list.length, cap);
    expect(list.first.content, 'm500');
    expect(list.last.content, 'm${cap + 499}');
    // The list is sorted ascending by timestamp after the batch flush.
    for (var i = 1; i < list.length; i++) {
      expect(list[i - 1].createdAt <= list[i].createdAt, isTrue);
    }
  });

  test('a channel at or under the cap is left untouched', () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    final base = 1000000000;
    for (var i = 0; i < 50; i++) {
      n.ingestEvent(_msg('flood', base + i, 'm$i'));
    }
    expect(n.state.messages[key]!.length, 50);
  });
}

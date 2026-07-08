import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

/// Backfill-coalescing behaviour of [AppStateNotifier.runBatched] and
/// [AppStateNotifier.ingestEvents], plus the sorted-insert that replaced the
/// per-event `list.add(m); list.sort(compareMessages)`.
///
/// The perf fix these lock in: a D1-backfill / relay-connect burst that used to
/// fire one Riverpod rebuild (+ spam/flood re-run + O(n log n) sort) PER event
/// now collapses to a SINGLE notify, and produces the exact same message order
/// as the old per-event add+sort.

/// A named-channel message (kind 23333), the same shape presence_test uses.
NostrEvent _chanMsg(String sender, String channel, int createdAt) => NostrEvent(
      id: 'n_${sender}_${channel}_$createdAt',
      pubkey: sender,
      createdAt: createdAt,
      kind: 23333,
      tags: [
        ['n', 'peer'],
        ['d', channel],
      ],
      content: 'gm',
    );

/// Timestamps of the single populated channel list ([_ingestChannelMessage]
/// only ever writes one `state.messages[key]`), independent of the exact key.
List<int> _channelTimestamps(AppStateNotifier n) {
  final lists = n.state.messages.values.where((l) => l.isNotEmpty).toList();
  expect(lists.length, 1, reason: 'expected exactly one populated channel list');
  return [for (final m in lists.single) m.createdAt];
}

void main() {
  group('runBatched coalesces emission', () {
    test('a batch of N ingests emits exactly once', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      var emits = 0;
      final remove = n.addListener((_) => emits++, fireImmediately: false);

      n.runBatched(() {
        for (var i = 0; i < 5; i++) {
          n.ingestEvent(_chanMsg('alice', 'bitcoin', 1000 + i));
        }
      });

      expect(emits, 1, reason: 'batch must collapse to one notify');
      expect(_channelTimestamps(n), [1000, 1001, 1002, 1003, 1004]);
      remove();
    });

    test('ingestEvents batches the whole iterable into one notify', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      var emits = 0;
      final remove = n.addListener((_) => emits++, fireImmediately: false);

      n.ingestEvents([
        for (var i = 0; i < 4; i++) _chanMsg('alice', 'bitcoin', 1000 + i),
      ]);

      expect(emits, 1);
      remove();
    });

    test('without a batch each ingest still emits (unchanged live behaviour)',
        () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      var emits = 0;
      final remove = n.addListener((_) => emits++, fireImmediately: false);

      for (var i = 0; i < 5; i++) {
        n.ingestEvent(_chanMsg('alice', 'bitcoin', 1000 + i));
      }

      expect(emits, 5, reason: 'live path stays one notify per event');
      remove();
    });

    test('nested batches flush once with the outermost scope', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      var emits = 0;
      final remove = n.addListener((_) => emits++, fireImmediately: false);

      n.runBatched(() {
        n.ingestEvent(_chanMsg('alice', 'bitcoin', 1000));
        n.runBatched(() {
          n.ingestEvent(_chanMsg('alice', 'bitcoin', 1001));
        });
        // The inner scope must NOT have flushed yet.
        expect(emits, 0);
        n.ingestEvent(_chanMsg('alice', 'bitcoin', 1002));
      });

      expect(emits, 1);
      remove();
    });
  });

  group('sorted-insert matches add+sort ordering', () {
    test('batched out-of-order arrivals end up fully sorted', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      n.runBatched(() {
        for (final ts in [1003, 1001, 1005, 1002, 1004]) {
          n.ingestEvent(_chanMsg('alice', 'bitcoin', ts));
        }
      });
      expect(_channelTimestamps(n), [1001, 1002, 1003, 1004, 1005]);
    });

    test('live out-of-order arrivals stay sorted after each insert', () {
      final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
      for (final ts in [1003, 1001, 1005, 1002, 1004]) {
        n.ingestEvent(_chanMsg('alice', 'bitcoin', ts));
      }
      expect(_channelTimestamps(n), [1001, 1002, 1003, 1004, 1005]);
    });

    test('batched and live paths agree for the same event stream', () {
      const stream = [1002, 1000, 1004, 1001, 1003, 1000, 1002];
      final batched = AppStateNotifier()..goLive('selfpk', 'me#0001');
      batched.runBatched(() {
        for (final ts in stream) {
          batched.ingestEvent(_chanMsg('alice', 'bitcoin', ts));
        }
      });
      final live = AppStateNotifier()..goLive('selfpk', 'me#0001');
      for (final ts in stream) {
        live.ingestEvent(_chanMsg('alice', 'bitcoin', ts));
      }
      expect(_channelTimestamps(batched), _channelTimestamps(live));
    });
  });
}

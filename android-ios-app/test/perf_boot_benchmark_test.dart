@Tags(['perf'])
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/core/crypto/keys.dart' as keys;
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

/// Not a pass/fail test — a stopwatch harness that runs the REAL boot/resume
/// hot paths (signature verification, hydration, ingest) at realistic volumes
/// and prints wall-clock timings, so we can see where the main-thread time
/// actually goes. Run with:
///   flutter test test/perf_boot_benchmark_test.dart --dart-define=... (none)
void main() {
  test('BIP340 signature verification throughput (pure-Dart, per event)', () {
    final sk = keys.generatePrivateKey();
    final pk = keys.getPublicKeyHex(sk);

    // Build N distinct signed channel events (what a D1 backlog replay verifies).
    // Kept modest so CI stays fast; per-event cost is what matters (extrapolated).
    const n = 60;
    final events = <NostrEvent>[];
    for (var i = 0; i < n; i++) {
      final e = NostrEvent(
        pubkey: pk,
        createdAt: 1700000000 + i,
        kind: EventKind.namedChannel,
        tags: [
          ['d', 'room'],
          ['n', 'alice'],
        ],
        content: 'benchmark message number $i with some body text',
      );
      e.id = e.computeId();
      e.sig = schnorr.signId(e.id, sk);
      events.add(e);
    }

    final sw = Stopwatch()..start();
    var ok = 0;
    for (final e in events) {
      if (schnorr.verifyEvent(e)) ok++;
    }
    sw.stop();
    expect(ok, n);
    final perMs = sw.elapsedMicroseconds / n / 1000.0;
    // ignore: avoid_print
    print('VERIFY: $n events in ${sw.elapsedMilliseconds}ms '
        '=> ${perMs.toStringAsFixed(2)} ms/event '
        '=> a 1000-event backlog ≈ ${(perMs * 1000).toStringAsFixed(0)} ms of CPU');

    // The cheap integrity check we would run INSTEAD of a full verify on a
    // cache hit: recompute the id (sha256 of the serialized event) and compare.
    final sw2 = Stopwatch()..start();
    var idOk = 0;
    for (final e in events) {
      if (e.computeId() == e.id) idOk++;
    }
    sw2.stop();
    expect(idOk, n);
    final idUs = sw2.elapsedMicroseconds / n;
    // ignore: avoid_print
    print('COMPUTE_ID (cache-hit cost): $n in ${sw2.elapsedMilliseconds}ms '
        '=> ${idUs.toStringAsFixed(1)} us/event '
        '=> a 1000-event replay ≈ ${(idUs).toStringAsFixed(0)} us x1000 = '
        '${(idUs).toStringAsFixed(1)} ms total');
  });

  test('AppState.hydrateAllMessages throughput (cold-boot cache load)', () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    // 40 channels x 400 cached messages = 16k messages (a heavy-but-plausible
    // returning-user cache).
    const channels = 40;
    const perChannel = 400;
    final byKey = <String, List<Message>>{};
    for (var ch = 0; ch < channels; ch++) {
      final list = <Message>[];
      for (var i = 0; i < perChannel; i++) {
        list.add(Message(
          id: 'm_${ch}_$i',
          pubkey: 'pk$ch',
          author: 'nym$ch',
          content: 'cached message $i',
          createdAt: 1700000000 + i,
          isOwn: false,
        ));
      }
      byKey['#chan$ch'] = list;
    }

    final sw = Stopwatch()..start();
    n.hydrateAllMessages(byKey);
    sw.stop();
    // ignore: avoid_print
    print('HYDRATE: ${channels * perChannel} messages across $channels '
        'channels in ${sw.elapsedMilliseconds}ms');
  });

  test('AppState channel-message ingest throughput (live/backfill burst)', () {
    final n = AppStateNotifier()
      ..goLive('selfpk', 'me#0001')
      ..switchView(const ChatView.channel('active'));

    NostrEvent msg(int i) => NostrEvent(
          id: 'im_$i',
          pubkey: 'pk${i % 50}',
          createdAt: 1700000000 + i,
          kind: EventKind.namedChannel,
          tags: [
            ['d', 'active'],
            ['n', 'nym${i % 50}'],
          ],
          content: 'inbound $i',
        );

    const n2 = 2000;
    final events = [for (var i = 0; i < n2; i++) msg(i)];

    final sw = Stopwatch()..start();
    n.ingestEvents(events); // batched path (one emit)
    sw.stop();
    // ignore: avoid_print
    print('INGEST: $n2 channel messages (batched) in ${sw.elapsedMilliseconds}ms '
        '=> ${(sw.elapsedMicroseconds / n2).toStringAsFixed(0)} us/event');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

/// A relay echo of one of OUR channel sends (pubkey == self so isOwn is true).
NostrEvent _echo(String d, String id, String content,
        {required String pubkey, required int createdAtSec, int? ms}) =>
    NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAtSec,
      kind: EventKind.namedChannel,
      tags: [
        ['d', d],
        ['n', 'me'],
        if (ms != null) ['ms', '$ms'],
      ],
      content: content,
    );

int _dupes(AppStateNotifier n, String key, String content) =>
    (n.state.messages[key] ?? const []).where((m) => m.content == content).length;

void main() {
  AppStateNotifier fresh() {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    n.switchView(const ChatView.channel('room'));
    return n;
  }

  test('echo BEFORE replaceOptimistic → single bubble (merge loop path)', () {
    final n = fresh();
    final echo = n.sendLocal('hello')!;
    // Relay echo races ahead of the publish await.
    n.ingestEvent(_echo('room', 'realid1', 'hello',
        pubkey: 'self_pk', createdAtSec: echo.createdAt));
    // Publish await resolves; reconcile runs after.
    n.replaceOptimistic(echo.id, 'realid1', realCreatedAt: echo.createdAt);
    expect(_dupes(n, '#room', 'hello'), 1);
  });

  test('echo AFTER replaceOptimistic → single bubble (_seenIds dedup)', () {
    final n = fresh();
    final echo = n.sendLocal('hello')!;
    n.replaceOptimistic(echo.id, 'realid1', realCreatedAt: echo.createdAt);
    n.ingestEvent(_echo('room', 'realid1', 'hello',
        pubkey: 'self_pk', createdAtSec: echo.createdAt));
    expect(_dupes(n, '#room', 'hello'), 1);
  });

  test('two rapid IDENTICAL-content sends → exactly two bubbles', () {
    final n = fresh();
    final e1 = n.sendLocal('ok')!;
    final e2 = n.sendLocal('ok')!;
    // Echoes in either order.
    n.ingestEvent(_echo('room', 'r1', 'ok',
        pubkey: 'self_pk', createdAtSec: e1.createdAt));
    n.replaceOptimistic(e1.id, 'r1', realCreatedAt: e1.createdAt);
    n.replaceOptimistic(e2.id, 'r2', realCreatedAt: e2.createdAt);
    n.ingestEvent(_echo('room', 'r2', 'ok',
        pubkey: 'self_pk', createdAtSec: e2.createdAt));
    expect(_dupes(n, '#room', 'ok'), 2);
  });

  test('FAILED send then resend same content (echo-first) → single bubble', () {
    final n = fresh();
    final e1 = n.sendLocal('retry me')!;
    n.markOptimisticFailed(e1.id); // publish threw → stays as _optim_* failed
    // User resends the same text; new optimistic + its echo.
    final e2 = n.sendLocal('retry me')!;
    n.ingestEvent(_echo('room', 'r2', 'retry me',
        pubkey: 'self_pk', createdAtSec: e2.createdAt));
    n.replaceOptimistic(e2.id, 'r2', realCreatedAt: e2.createdAt);
    // The merge loop prefers the LIVE placeholder (e2) and, on reconcile, sweeps
    // the stale FAILED twin (e1) — the successful resend supersedes the failed
    // attempt. Net = ONE bubble (no duplicate).
    expect(_dupes(n, '#room', 'retry me'), 1);
  });

  test(
      'FAILED channel send then retyped resend (REAL ordering: publish await '
      'reconciles before the buffered relay echo) → single SENT bubble', () {
    final n = fresh();
    // Attempt 1: the composer send throws (flaky link) and the placeholder is
    // flipped to failed. A failed CHANNEL bubble has no retry-splice affordance
    // (that path is PM-only), so it lingers in the list.
    final e1 = n.sendLocal('gm')!;
    n.markOptimisticFailed(e1.id);
    // Attempt 2: the user retypes the SAME text. In the real app the publish
    // await returns and reconciles here BEFORE the relay echo (which is buffered
    // via _liveInboundBuffer and flushed on a later timer) is ingested — so the
    // merge loop hasn't run yet when replaceOptimistic executes.
    final e2 = n.sendLocal('gm')!;
    n.replaceOptimistic(e2.id, 'realgm', realCreatedAt: e2.createdAt);
    // Before the fix this left [failed _optim_gm, sent realgm] = TWO identical
    // bubbles locally while the recipient only ever received `realgm`. The sweep
    // collapses the stale failed twin.
    expect(_dupes(n, '#room', 'gm'), 1);
    final rows = (n.state.messages['#room'] ?? const [])
        .where((m) => m.content == 'gm')
        .toList();
    expect(rows.single.deliveryStatus, DeliveryStatus.sent);
    expect(rows.single.id, 'realgm');
    // The buffered relay echo lands afterwards and is deduped by _seenIds.
    n.ingestEvent(_echo('room', 'realgm', 'gm',
        pubkey: 'self_pk', createdAtSec: e2.createdAt));
    expect(_dupes(n, '#room', 'gm'), 1);
  });

  test('a DIFFERENT-content failed placeholder is NOT swept by a later send',
      () {
    final n = fresh();
    final e1 = n.sendLocal('first')!;
    n.markOptimisticFailed(e1.id); // genuinely failed, distinct message
    final e2 = n.sendLocal('second')!;
    n.replaceOptimistic(e2.id, 'r2', realCreatedAt: e2.createdAt);
    // The failed 'first' is a separate message the user may still retry — a
    // successful 'second' must not erase it.
    expect(_dupes(n, '#room', 'first'), 1);
    expect(_dupes(n, '#room', 'second'), 1);
  });

  test('echo delivered inside a batched flush (live-inbound path)', () {
    final n = fresh();
    final echo = n.sendLocal('batched')!;
    // Mirror _flushLiveInbound: the echo is ingested inside runBatched.
    n.runBatched(() {
      n.ingestEvent(_echo('room', 'rb', 'batched',
          pubkey: 'self_pk', createdAtSec: echo.createdAt));
    });
    n.replaceOptimistic(echo.id, 'rb', realCreatedAt: echo.createdAt);
    expect(_dupes(n, '#room', 'batched'), 1);
  });

  test('a re-PUBLISHED copy with a DIFFERENT id is NOT deduped (channel gap)',
      () {
    final n = fresh();
    final echo = n.sendLocal('once')!;
    n.replaceOptimistic(echo.id, 'realid1', realCreatedAt: echo.createdAt);
    n.ingestEvent(_echo('room', 'realid1', 'once',
        pubkey: 'self_pk', createdAtSec: echo.createdAt));
    // Same message re-published with a fresh event id (new PoW nonce): channels
    // carry no shared nymMessageId, so nothing correlates it to the original.
    n.ingestEvent(_echo('room', 'realid2_DIFFERENT', 'once',
        pubkey: 'self_pk', createdAtSec: echo.createdAt));
    // Documents current behavior: this DOES duplicate (2). If the app ever
    // re-publishes a channel send, this is the bug surface.
    expect(_dupes(n, '#room', 'once'), 2);
  });
}

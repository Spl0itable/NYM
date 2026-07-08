import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

NostrEvent _chanMsg(String d, int ts, {String? id, String pubkey = 'author_pk'}) =>
    NostrEvent(
      id: id ?? 'cm_${d}_${ts}_$pubkey',
      pubkey: pubkey,
      createdAt: ts,
      kind: EventKind.namedChannel,
      tags: [
        ['d', d],
        ['n', 'alice'],
      ],
      content: 'msg@$ts',
    );

Message _cached(String key, int ts) => Message(
      // Must match _chanMsg's id for the same (channel, ts, default pubkey) so
      // the backfill dedups against the cache.
      id: 'cm_${key.replaceAll('#', '')}_${ts}_author_pk',
      pubkey: 'author_pk',
      author: 'alice',
      content: 'msg@$ts',
      createdAt: ts,
      isOwn: false,
    );

void main() {
  // A safely-PAST base (2023) — event_mapper clamps FUTURE created_at to now.
  const now = 1700000000;

  test('D1 backfill into an EMPTY (uncached) channel renders via the provider',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(appStateProvider.notifier)..goLive('self', 'me#0001');
    n.switchView(const ChatView.channel('news'));
    expect(c.read(messagesForCurrentViewProvider), isEmpty);

    // Simulate _runChannelBackfill: batched ingest of channel-get rows.
    n.ingestEvents([
      _chanMsg('news', now - 100),
      _chanMsg('news', now - 50),
      _chanMsg('news', now),
    ]);

    final msgs = c.read(messagesForCurrentViewProvider);
    expect(msgs.length, 3, reason: 'backfilled channel messages must render');
    expect(msgs.last.createdAt, now, reason: 'newest last');
  });

  test('backfill of NEWER messages shows them even when older ones were cached',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(appStateProvider.notifier)..goLive('self', 'me#0001');

    // Boot hydration seeds the store + _seenIds from the local cache (old msgs).
    n.hydrateAllMessages({
      '#news': [_cached('#news', now - 10000), _cached('#news', now - 9000)],
    });
    n.switchView(const ChatView.channel('news'));
    expect(c.read(messagesForCurrentViewProvider).length, 2);

    // D1 backfill returns the SAME old rows (deduped) PLUS newer ones.
    n.ingestEvents([
      _chanMsg('news', now - 10000), // dup of cached → skipped
      _chanMsg('news', now - 9000), // dup of cached → skipped
      _chanMsg('news', now - 5), // new
      _chanMsg('news', now), // new (most recent)
    ]);

    final msgs = c.read(messagesForCurrentViewProvider);
    expect(msgs.length, 4, reason: 'cached old + backfilled new, deduped');
    expect(msgs.last.createdAt, now,
        reason: 'the most recent backfilled message is newest-last');
    // Sidebar sort key reflects the newest message (ms), not the old cache.
    expect(n.state.channelLastActivity['#news'], now * 1000);
  });

  test('channelLastActivity tracks the newest message across cache+backfill', () {
    final n = AppStateNotifier()..goLive('self', 'me#0001');
    n.hydrateAllMessages({
      '#news': [_cached('#news', now - 10000)],
    });
    // After hydration the activity is the cached msg time.
    expect(n.state.channelLastActivity['#news'], (now - 10000) * 1000);
    // A newer backfilled/live message raises it.
    n.ingestEvent(_chanMsg('news', now));
    expect(n.state.channelLastActivity['#news'], now * 1000);
  });

  // Reproduces the "channel loads nothing despite D1 having messages" report:
  // with the web-of-trust spam gate ON (as main.dart enables it), a D1-backfilled
  // message from an untrusted sender is HIDDEN. It only reveals once the sender
  // is trusted — which the live path does (PoW self-attestation / earned trust)
  // but the D1 backfill path did NOT, so restored history stayed invisible.
  test('WoT gate hides a backfilled untrusted sender; trust reveals it', () {
    final prev = nymVouchSpamGateEnabled;
    nymVouchSpamGateEnabled = true;
    addTearDown(() => nymVouchSpamGateEnabled = prev);

    final n = AppStateNotifier()..goLive('self', 'me#0001');
    n.switchView(const ChatView.channel('room'));
    // Backfill path: ingest straight into the store (no trust observation).
    n.ingestEvent(_chanMsg('room', now, pubkey: 'stranger_pk'));

    expect(visibleMessagesFor(n.state, '#room'), isEmpty,
        reason: 'untrusted sender is spam-gated out of the visible list');

    // Simulate the trust observation the fix restores for backfill (PoW
    // self-attestation adds the Nymchat sender to nymchatPubkeys).
    n.state.nymchatPubkeys.add('stranger_pk');
    expect(visibleMessagesFor(n.state, '#room').length, 1,
        reason: 'once trusted, the backfilled message reveals');
  });
}

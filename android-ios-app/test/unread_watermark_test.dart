import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

/// A named-channel (kind 23333) message in channel [d] from [pubkey] at [ts].
NostrEvent _msg(String d, String pubkey, int ts, String content) => NostrEvent(
      id: 'cm_${pubkey}_$ts',
      pubkey: pubkey,
      createdAt: ts,
      kind: EventKind.namedChannel,
      tags: [
        ['d', d],
        ['n', 'alice'],
      ],
      content: content,
    );

void main() {
  test('D1 backfill of already-read history does NOT re-inflate unread', () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Open #testchan (stamps its read watermark to now), then switch away so it
    // is a NON-active channel whose inbound messages bump the badge.
    n.switchView(const ChatView.channel('testchan'));
    n.switchView(const ChatView.channel('other'));

    // A backfilled OLD message (created long before we last read the channel)
    // must NOT bump the badge — the regression the user reported.
    n.ingestEvent(_msg('testchan', 'alice', nowSec - 100000, 'old history'));
    expect(n.state.unreadCounts['#testchan'] ?? 0, 0,
        reason: 'old backfilled history must not count as unread');

    // A genuinely NEW message (after the read watermark) DOES bump.
    n.ingestEvent(_msg('testchan', 'alice', nowSec + 50, 'fresh'));
    expect(n.state.unreadCounts['#testchan'], 1,
        reason: 'a new message after the watermark counts');
  });

  test('never-opened channel still counts its history as unread', () {
    final n = AppStateNotifier()..goLive('selfpk', 'me#0001');
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Active view is the default channel; #never was never opened (lastRead=0),
    // so even older messages count (PWA: created_at > lastRead=0).
    n.switchView(const ChatView.channel('other'));
    n.ingestEvent(_msg('never', 'alice', nowSec - 5, 'recent-ish'));
    expect(n.state.unreadCounts['#never'], 1);
  });
}

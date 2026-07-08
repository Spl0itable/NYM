import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/features/messages/flood_tracker.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_mapper.dart';
import 'package:nym_bar/state/app_state.dart';

NostrEvent _chan(String d, String id, String content,
        {required String pubkey, required int createdAtSec, int? ms}) =>
    NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAtSec,
      kind: EventKind.namedChannel,
      tags: [
        ['d', d],
        ['n', 'someone'],
        if (ms != null) ['ms', '$ms'],
      ],
      content: content,
    );

void main() {
  const self = 'self_pk';
  const sender = 'sender_pk';
  int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  group('channelMessage historical flag (PWA messageAge > 10000)', () {
    test('a fresh (live) channel event is NOT historical', () {
      final m = EventMapper.channelMessage(
        _chan('room', 'a', 'hello there', pubkey: sender, createdAtSec: nowSec()),
        selfPubkey: self,
      )!;
      expect(m.isHistorical, isFalse);
    });

    test('an aged (>10s backlog) channel event IS historical', () {
      final m = EventMapper.channelMessage(
        _chan('room', 'b', 'hello there',
            pubkey: sender, createdAtSec: nowSec() - 60),
        selfPubkey: self,
      )!;
      expect(m.isHistorical, isTrue);
    });

    test(
        'created_at re-stamped to ~now but a real (old) ms tag → historical, '
        'and timestamp reflects the ms send time (not the re-stamp)', () {
      final realSendMs = DateTime.now().millisecondsSinceEpoch - 180000; // 3m
      final m = EventMapper.channelMessage(
        // The proxy re-broadcast the ephemeral event with created_at ≈ now, but
        // the ms tag still carries the true 3-minute-old send time.
        _chan('room', 'c', 'hello there',
            pubkey: sender, createdAtSec: nowSec(), ms: realSendMs),
        selfPubkey: self,
      )!;
      expect(m.isHistorical, isTrue);
      // Display/flood time comes from the ms tag, so the row reads "3m ago",
      // not "now".
      expect(m.timestamp, realSendMs);
    });
  });

  group('backfill provenance overrides the timestamp-age guess', () {
    AppStateNotifier fresh() {
      final n = AppStateNotifier()..goLive(self, 'me#0001');
      n.switchView(const ChatView.channel('room'));
      return n;
    }

    test('a ≈now event ingested as backfill is historical (not dimmable)', () {
      final n = fresh();
      // The archive re-served this ephemeral event with created_at/ms ≈ now, so
      // the age heuristic alone would call it live — but provenance says backlog.
      n.ingestEvent(
        _chan('room', 'id1', 'hello there',
            pubkey: sender, createdAtSec: nowSec()),
        historical: true,
      );
      expect(n.state.messages['#room']!.single.isHistorical, isTrue);
    });

    test('the SAME ≈now event ingested LIVE is not historical', () {
      final n = fresh();
      n.ingestEvent(
        _chan('room', 'id2', 'hello there',
            pubkey: sender, createdAtSec: nowSec()),
      );
      expect(n.state.messages['#room']!.single.isHistorical, isFalse);
    });
  });

  group('flood tracker exempts backfilled history', () {
    // Three identical 6+char messages from one sender trip the content-flood
    // gate (>= kContentFloodRepeat within the window).
    List<Message> mapped(int createdAtSec, {int? ms}) => [
          for (var i = 0; i < kContentFloodRepeat; i++)
            EventMapper.channelMessage(
              _chan('room', 'evt$createdAtSec$ms$i', 'flood flood',
                  pubkey: sender, createdAtSec: createdAtSec, ms: ms),
              selfPubkey: self,
            )!,
        ];

    test('a LIVE content-flood dims the sender', () {
      final tracker =
          FloodTracker.fromMessages(mapped(nowSec()), selfPubkey: self);
      expect(tracker.isFlooding(sender), isTrue);
    });

    test('the SAME burst arriving as BACKFILL (aged) does not dim anyone', () {
      // Opening a busy channel replays its recent history; every event is now
      // >10s old so the mapper marks it historical and the flood tracker skips
      // it — the false-positive that dimmed legit senders to opacity 0.2.
      final tracker =
          FloodTracker.fromMessages(mapped(nowSec() - 60), selfPubkey: self);
      expect(tracker.isFlooding(sender), isFalse);
    });

    test('re-stamped created_at ≈ now but real old ms tag does not dim', () {
      // The proxy re-broadcast backfill with created_at ≈ now (which would
      // cluster it into a false rate/content flood), but the ms tag exposes the
      // true 3-minute-old send time, so the mapper marks it historical and the
      // tracker skips it.
      final realSendMs = DateTime.now().millisecondsSinceEpoch - 180000;
      final tracker = FloodTracker.fromMessages(
        mapped(nowSec(), ms: realSendMs),
        selfPubkey: self,
      );
      expect(tracker.isFlooding(sender), isFalse);
    });
  });
}

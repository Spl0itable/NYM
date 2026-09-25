import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/features/pms/pm_logic.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/services/nostr/event_mapper.dart';
import 'package:nym_bar/services/nostr/event_time_ceilings.dart';
import 'package:nym_bar/state/app_state.dart';

void main() {
  final self = 'c' * 64;
  final peer = 'a' * 64;

  setUp(() => EventMapper.ceilings = EventTimeCeilings());
  tearDown(() => EventMapper.ceilings = null);

  group('rumorTimes', () {
    test('a future-dated rumor keeps the ceiling it was first given', () {
      final now1 = 1700000000000;
      final first = EventMapper.rumorTimes(
          key: 'x1', createdAtRaw: 1700009999, ms: 0, nowMs: now1);
      expect(first.createdAt, now1 ~/ 1000);
      final later = EventMapper.rumorTimes(
          key: 'x1', createdAtRaw: 1700009999, ms: 0, nowMs: now1 + 3600000);
      expect(later.createdAt, first.createdAt,
          reason: 'a replay an hour later must not re-stamp it to the new now');
      expect(later.timestampMs, first.timestampMs);
    });

    test('a rumor within the clock tolerance is not clamped', () {
      final now = 1700000000000;
      final t = EventMapper.rumorTimes(
          key: 'x2', createdAtRaw: 1700000030, ms: 1700000030500, nowMs: now);
      expect(t.createdAt, 1700000030);
      expect(t.timestampMs, now, reason: 'an ms a little ahead caps at now');
    });

    test('an ms tag far ahead of its own created_at is ignored', () {
      final now = 1700000000000;
      final t = EventMapper.rumorTimes(
          key: 'x3', createdAtRaw: 1699990000, ms: 1799990000000, nowMs: now);
      expect(t.timestampMs, 1699990000 * 1000,
          reason: 'a bogus ms must not make an old message read as now');
    });

    test('a normal rumor passes through untouched', () {
      final t = EventMapper.rumorTimes(
          key: 'x4', createdAtRaw: 1699999000, ms: 1699999000250,
          nowMs: 1700000000000);
      expect(t.createdAt, 1699999000);
      expect(t.timestampMs, 1699999000250);
    });
  });

  test('a PM whose rumor is future-dated maps to the same time on every replay',
      () {
    final futureSec = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200;
    Map<String, dynamic> rumor() => {
          'kind': EventKind.dmRumor,
          'pubkey': peer,
          'content': 'from a clock two hours ahead',
          'created_at': futureSec,
          'tags': [
            ['p', self],
            ['x', 'msg-1'],
          ],
        };
    final a = PmLogic.mapPmRumor(
        rumor: rumor(), wrapId: 'w1', selfPubkey: self, senderVerified: true)!;
    final b = PmLogic.mapPmRumor(
        rumor: rumor(), wrapId: 'w2', selfPubkey: self, senderVerified: true)!;
    expect(b.createdAt, a.createdAt, reason: 'keyed on the message id, not the wrap');
    expect(b.timestamp, a.timestamp);
    expect(a.createdAt, lessThan(futureSec));
  });

  test('a PM the store already holds does not land twice', () {
    final n = AppStateNotifier()..goLive(self, 'me#0001');
    Message pm() => Message(
          id: 'wrap-1',
          author: 'bob',
          pubkey: peer,
          content: 'hello',
          createdAt: 1700000000,
          isPM: true,
          conversationKey: 'pm-$peer',
          conversationPubkey: peer,
          nymMessageId: 'msg-1',
          eventKind: 1059,
          senderVerified: true,
        );
    expect(n.ingestPMMessage(pm()), isTrue);
    expect(n.ingestPMMessage(pm()), isFalse,
        reason: 'the replay is the same message and must not notify again');
    expect(n.isKnownEventId('wrap-1'), isTrue);
    expect(n.isKnownEventId('wrap-9'), isFalse);
  });
}

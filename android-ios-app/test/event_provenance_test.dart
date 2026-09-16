import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_provenance.dart';

NostrEvent ev(String id) => NostrEvent(
      id: id,
      pubkey: 'a' * 64,
      createdAt: 1,
      kind: 20000,
      tags: const [
        ['g', 'u4pruy']
      ],
      content: 'x',
      sig: '0' * 128,
    );

void main() {
  test('every delivery is recorded, not just the first', () {
    // The point of the store: each dedup layer throws away the copies that
    // ARE the relay list, so they are recorded before those layers run.
    final p = EventProvenance();
    p.record(ev('a' * 64), 'wss://one.example');
    p.record(ev('a' * 64), 'wss://two.example');
    p.record(ev('a' * 64), 'wss://three.example');
    expect(p.of('a' * 64)!.relays,
        ['wss://one.example', 'wss://two.example', 'wss://three.example']);
  });

  test('the same relay twice is one entry', () {
    final p = EventProvenance();
    p.record(ev('b' * 64), 'wss://one.example');
    p.record(ev('b' * 64), 'wss://one.example');
    expect(p.of('b' * 64)!.relays.length, 1);
  });

  test('a delivery with no relay is named rather than dropped', () {
    // "We do not know" is a different answer from "no relay", and the panel
    // should not imply the second when it means the first.
    final p = EventProvenance();
    p.record(ev('c' * 64), null);
    expect(p.of('c' * 64)!.relays, ['(UNATTRIBUTED)']);
  });

  test('a real relay replaces the unattributed marker', () {
    final p = EventProvenance();
    p.record(ev('d' * 64), null);
    p.record(ev('d' * 64), 'wss://one.example');
    expect(p.of('d' * 64)!.relays, ['wss://one.example']);
  });

  test('an unknown id yields nothing', () {
    expect(EventProvenance().of('e' * 64), isNull);
  });

  test('a malformed id is not stored', () {
    final p = EventProvenance();
    p.record(ev('short'), 'wss://one.example');
    expect(p.length, 0);
  });

  test('the store is bounded, and evicts by last seen', () {
    final p = EventProvenance(maxEvents: 3);
    for (final c in ['1', '2', '3']) {
      p.record(ev(c * 64), 'wss://one.example');
    }
    // Touching the oldest re-seats it, so the next insert evicts '2'.
    p.record(ev('1' * 64), 'wss://two.example');
    p.record(ev('4' * 64), 'wss://one.example');
    expect(p.length, 3);
    expect(p.of('1' * 64), isNotNull);
    expect(p.of('2' * 64), isNull);
    expect(p.of('4' * 64), isNotNull);
  });

  test('the relay list per event is bounded', () {
    final p = EventProvenance(maxRelaysPerEvent: 2);
    for (var i = 0; i < 5; i++) {
      p.record(ev('f' * 64), 'wss://r$i.example');
    }
    expect(p.of('f' * 64)!.relays.length, 2);
  });

  test('addSource on an event never recorded does nothing', () {
    final p = EventProvenance();
    p.addSource('9' * 64, 'wss://one.example');
    expect(p.length, 0);
  });
}

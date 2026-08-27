// The sender outbox: what the Bluetooth mesh carried while the internet was
// down, held until relays return.
//
// Before this existed, a message sent offline reached whoever was in radio
// range and nobody else — ever. It was never published, never retried, and
// nothing recorded that it hadn't been. These pin the policy that closes that
// gap: what is retained, what is replayed, and the three bounds (TTL, cap,
// attempts) that stop a queue from growing or retrying forever.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/mesh/mesh_outbox.dart';

const _hour = 60 * 60 * 1000;

MeshOutboxEntry _entry(
  String localId, {
  MeshOutboxKind kind = MeshOutboxKind.channel,
  String target = 'nymchat',
  String content = 'hello',
  int createdAtSec = 1700000000,
  String? meshMessageId,
  String? nymMessageId,
  String? threadRoot,
}) =>
    MeshOutboxEntry(
      kind: kind,
      target: target,
      content: content,
      createdAtSec: createdAtSec,
      localId: localId,
      meshMessageId: meshMessageId,
      nymMessageId: nymMessageId,
      threadRoot: threadRoot,
    );

void main() {
  // `createdAtSec` is seconds; the bounds are milliseconds. Anchor "now" to the
  // default entry time so the TTL maths reads plainly.
  const nowMs = 1700000000 * 1000;

  group('retention', () {
    test('a queued send is held and handed back to the flush', () {
      final box = MeshOutbox();
      box.add(_entry('_optim_1'));
      expect(box.length, 1);
      expect(box.due(nowMs).single.localId, '_optim_1');
    });

    test('entries replay oldest first, so a conversation keeps its order', () {
      final box = MeshOutbox();
      box.add(_entry('_optim_1', createdAtSec: 1700000000, content: 'first'));
      box.add(_entry('_optim_2', createdAtSec: 1700000005, content: 'second'));
      expect(box.due(nowMs + 5000).map((e) => e.content), ['first', 'second']);
    });

    test('the same echo is never queued twice', () {
      // A retry path calling enqueue again must not publish the message twice.
      final box = MeshOutbox();
      box.add(_entry('_optim_1'));
      box.add(_entry('_optim_1', content: 'different text, same echo'));
      expect(box.length, 1);
      expect(box.entries.single.content, 'hello');
    });

    test('delivery removes the entry', () {
      final box = MeshOutbox();
      box.add(_entry('_optim_1'));
      expect(box.remove('_optim_1'), isTrue);
      expect(box.isEmpty, isTrue);
      expect(box.remove('_optim_1'), isFalse);
    });
  });

  group('bounds', () {
    test('an entry past the 24h TTL is dropped, and the bubble fails', () {
      final dropped = <String>[];
      final box = MeshOutbox(onDropped: dropped.add);
      box.add(_entry('_optim_old', createdAtSec: 1700000000));
      // 25h later: past the window the mesh's own store-and-forward keeps.
      final due = box.due(nowMs + 25 * _hour);
      expect(due, isEmpty);
      // The user must not be left with a bubble that still looks sent.
      expect(dropped, ['_optim_old']);
    });

    test('an entry inside the TTL survives', () {
      final box = MeshOutbox();
      box.add(_entry('_optim_1', createdAtSec: 1700000000));
      expect(box.due(nowMs + 23 * _hour), hasLength(1));
    });

    test('the cap evicts the oldest, reporting each', () {
      final dropped = <String>[];
      final box = MeshOutbox(onDropped: dropped.add);
      for (var i = 0; i < MeshOutbox.cap + 3; i++) {
        box.add(_entry('_optim_$i'));
      }
      expect(box.length, MeshOutbox.cap);
      expect(dropped, ['_optim_0', '_optim_1', '_optim_2']);
      expect(box.entries.first.localId, '_optim_3');
    });

    test('a publish that keeps failing is given up on, not looped', () {
      final dropped = <String>[];
      final box = MeshOutbox(onDropped: dropped.add);
      box.add(_entry('_optim_1'));
      for (var i = 0; i < MeshOutbox.maxAttempts - 1; i++) {
        expect(box.noteAttempt('_optim_1'), isFalse);
      }
      expect(box.noteAttempt('_optim_1'), isTrue);
      expect(box.isEmpty, isTrue);
      expect(dropped, ['_optim_1']);
    });

    test('an attempt against an entry that is gone is a no-op', () {
      final box = MeshOutbox();
      expect(box.noteAttempt('_optim_missing'), isFalse);
    });

    test('clear drops everything WITHOUT failing bubbles', () {
      // Sign-out / panic discards the messages along with everything else;
      // marking them failed would be UI for a session that no longer exists.
      final dropped = <String>[];
      final box = MeshOutbox(onDropped: dropped.add);
      box.add(_entry('_optim_1'));
      box.clear();
      expect(box.isEmpty, isTrue);
      expect(dropped, isEmpty);
    });
  });

  group('persistence', () {
    test('a queue survives the restart that a mesh send often precedes', () {
      final box = MeshOutbox();
      box.add(_entry(
        '_optim_1',
        kind: MeshOutboxKind.pm,
        target: 'a' * 64,
        content: 'over the radio',
        threadRoot: 'b' * 64,
        meshMessageId: 'mesh-1',
        nymMessageId: 'mesh-1',
      ));
      final restored = MeshOutbox()..decode(box.encode());
      final e = restored.entries.single;
      expect(e.kind, MeshOutboxKind.pm);
      expect(e.target, 'a' * 64);
      expect(e.content, 'over the radio');
      expect(e.threadRoot, 'b' * 64);
      expect(e.meshMessageId, 'mesh-1');
      expect(e.nymMessageId, 'mesh-1');
      expect(e.createdAtSec, 1700000000);
      expect(e.localId, '_optim_1');
    });

    test('attempts already spent survive too', () {
      final box = MeshOutbox();
      box.add(_entry('_optim_1'));
      box.noteAttempt('_optim_1');
      final restored = MeshOutbox()..decode(box.encode());
      expect(restored.entries.single.attempts, 1);
    });

    test('a corrupt blob costs the queue, never a crash on every boot', () {
      final box = MeshOutbox()..decode('not json at all');
      expect(box.isEmpty, isTrue);
      box.decode('{"not":"a list"}');
      expect(box.isEmpty, isTrue);
      box.decode(null);
      expect(box.isEmpty, isTrue);
    });

    test('a corrupt row costs one message, not the whole queue', () {
      final good = _entry('_optim_good').toJson();
      final raw =
          '[{"kind":"channel"},${_json(good)},{"target":"x","content":"y"}]';
      final box = MeshOutbox()..decode(raw);
      expect(box.entries.map((e) => e.localId), ['_optim_good']);
    });

    test('an unknown kind is skipped rather than guessed at', () {
      final box = MeshOutbox()
        ..decode('[{"kind":"telepathy","target":"x","content":"y",'
            '"createdAt":1700000000,"localId":"_optim_1"}]');
      expect(box.isEmpty, isTrue);
    });
  });

  // Gateway mode may already be carrying this exact event to the relays.
  // Republishing the SAME bytes yields the same event id, so the relays treat
  // the second copy as a duplicate; rebuilding it would differ by the
  // proof-of-work nonce alone and put the message on the relays twice.
  group('the event signed at send time', () {
    Map<String, dynamic> event([String id = 'abc']) => <String, dynamic>{
          'id': id,
          'kind': 20000,
          'content': 'hello',
        };

    test('attaches to an entry already queued', () {
      final box = MeshOutbox()..add(_entry('_optim_1'));
      expect(box.entries.single.signedEvent, isNull);
      expect(box.attachSignedEvent('_optim_1', event()), isTrue);
      expect(box.entries.single.signedEvent!['id'], 'abc');
    });

    test('leaves everything else about the entry alone', () {
      final box = MeshOutbox()
        ..add(_entry('_optim_1',
            target: 'u4pruyd',
            threadRoot: 'r' * 64,
            meshMessageId: 'mesh-1',
            nymMessageId: 'nym-1'));
      box.noteAttempt('_optim_1');
      box.attachSignedEvent('_optim_1', event());
      final e = box.entries.single;
      expect(e.target, 'u4pruyd');
      expect(e.threadRoot, 'r' * 64);
      expect(e.meshMessageId, 'mesh-1');
      expect(e.nymMessageId, 'nym-1');
      expect(e.createdAtSec, 1700000000);
      expect(e.attempts, 1);
    });

    test('never overwrites the event already recorded', () {
      final box = MeshOutbox()..add(_entry('_optim_1'));
      expect(box.attachSignedEvent('_optim_1', event('first')), isTrue);
      expect(box.attachSignedEvent('_optim_1', event('second')), isFalse);
      expect(box.entries.single.signedEvent!['id'], 'first');
    });

    test('an entry already gone is ignored rather than resurrected', () {
      final box = MeshOutbox();
      expect(box.attachSignedEvent('_optim_gone', event()), isFalse);
      expect(box.isEmpty, isTrue);
    });

    test('survives the reload, or the whole point is lost', () {
      final box = MeshOutbox()..add(_entry('_optim_1'));
      box.attachSignedEvent('_optim_1', event('deadbeef'));
      final restored = MeshOutbox()..decode(box.encode());
      expect(restored.entries.single.signedEvent!['id'], 'deadbeef');
      expect(restored.entries.single.signedEvent!['kind'], 20000);
    });

    test('an entry written before this existed still decodes', () {
      final box = MeshOutbox()
        ..decode('[{"kind":"channel","target":"nymchat","content":"hi",'
            '"createdAt":1700000000,"localId":"_optim_1"}]');
      expect(box.entries.single.signedEvent, isNull);
    });

    test('a non-map signedEvent is dropped, not carried as junk', () {
      final box = MeshOutbox()
        ..decode('[{"kind":"channel","target":"nymchat","content":"hi",'
            '"createdAt":1700000000,"localId":"_optim_1",'
            '"signedEvent":"not an event"}]');
      expect(box.entries.single.signedEvent, isNull);
    });
  });
}

/// Minimal JSON encoder for the one map the corrupt-row test embeds.
String _json(Map<String, dynamic> m) {
  final parts = <String>[];
  m.forEach((k, v) {
    parts.add(v is String ? '"$k":"$v"' : '"$k":$v');
  });
  return '{${parts.join(',')}}';
}

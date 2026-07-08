import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/core/crypto/isolate_verifier.dart';
import 'package:nym_bar/models/nostr_event.dart';

NostrEvent _event(String content) => NostrEvent(
      pubkey: 'a' * 64,
      createdAt: 1700000000,
      kind: EventKind.namedChannel,
      tags: const [
        ['d', 'room'],
      ],
      content: content,
    );

void main() {
  test('a seeded (already-verified) id skips the BIP340 check', () async {
    final v = IsolateVerifier();
    final e = _event('hello');
    final id = e.computeId();
    e.id = id;
    // Deliberately invalid-but-well-formed signature. Without the cache this
    // would fail; with the id seeded as already-verified it is accepted, proving
    // the expensive signature check was skipped.
    e.sig = '0' * 128;

    v.markVerified([id]);
    expect(await v.verify(e), isTrue,
        reason: 'a content id we already verified is trusted on replay');
  });

  test('the cache is content-bound: tampered content is rejected', () async {
    final v = IsolateVerifier();
    final original = _event('the real message');
    final id = original.computeId();
    v.markVerified([id]);

    // An attacker claims the cached id but ships different content. Because the
    // id is sha256(content), the recomputed id no longer matches → rejected,
    // even though the id is in the cache.
    final tampered = _event('a forged replacement');
    tampered.id = id; // lie about the id
    tampered.sig = '0' * 128;
    expect(await v.verify(tampered), isFalse,
        reason: 'content must still hash to the claimed id');
  });

  test('malformed pubkey/sig are rejected before any cache/isolate work',
      () async {
    final v = IsolateVerifier();
    final e = _event('x');
    e.id = e.computeId();
    e.sig = 'zz'; // wrong length
    expect(await v.verify(e), isFalse);

    final e2 = NostrEvent(
      pubkey: 'short',
      createdAt: 1,
      kind: EventKind.namedChannel,
      tags: const [],
      content: 'y',
    );
    e2.id = e2.computeId();
    e2.sig = '0' * 128;
    expect(await v.verify(e2), isFalse);
  });
}

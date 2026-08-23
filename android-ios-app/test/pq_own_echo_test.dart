// A sent message must carry its own encryption state immediately.
//
// The optimistic echo goes on screen before the send path has looked up the
// recipient's key, and nothing wrote the answer back onto it. So an own message
// read as classical until our SELF-copy round-tripped through the relays and
// was unwrapped -- or, if it never did, until the app was restarted and the
// conversation reopened, which is when the archive re-unwraps it. The PWA sets
// this from the send plan, so only this client showed it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/message.dart';

Message ownEcho(String nymMessageId) => Message(
      id: '_optim_1',
      pubkey: 'a' * 64,
      author: 'me',
      content: 'hi',
      createdAt: 1,
      isOwn: true,
      isPM: true,
      nymMessageId: nymMessageId,
    );

void main() {
  group('own message echo', () {
    test('starts classical, which is what made the badge wrong', () {
      expect(ownEcho('m1').pqEncrypted, isFalse);
    });

    test('the send plan can be written onto it', () {
      final m = ownEcho('m1')..pqEncrypted = true;
      expect(m.pqEncrypted, isTrue);
    });

    test('group coverage can be written onto it', () {
      final m = ownEcho('g1')..pqCoverage = (pq: 8, total: 10);
      expect(m.pqCoverage, isNotNull);
      expect(m.pqCoverage!.pq, 8);
      expect(m.pqCoverage!.total, 10);
    });

    // Partial coverage must never read as protected: one classical copy of the
    // same plaintext is all an attacker needs.
    test('partial coverage is not full coverage', () {
      final partial = ownEcho('g1')..pqCoverage = (pq: 8, total: 10);
      final full = ownEcho('g2')..pqCoverage = (pq: 10, total: 10);
      bool fullyProtected(Message m) =>
          m.pqCoverage != null &&
          m.pqCoverage!.total > 0 &&
          m.pqCoverage!.pq == m.pqCoverage!.total;
      expect(fullyProtected(partial), isFalse);
      expect(fullyProtected(full), isTrue);
    });

    test('both fields survive a cache round-trip', () {
      final m = ownEcho('m1')
        ..pqEncrypted = true
        ..pqCoverage = (pq: 3, total: 4);
      final back = Message.fromJson(m.toJson());
      expect(back.pqEncrypted, isTrue);
      expect(back.pqCoverage?.pq, 3);
      expect(back.pqCoverage?.total, 4);
    });
  });

  // A message whose classical copy arrived first must upgrade in place once its
  // hybrid copy lands -- the same rule the verification lock already follows.
  group('dedup upgrades the shield', () {
    final appState = File('lib/state/app_state.dart').readAsStringSync();

    test('a later post-quantum copy upgrades the row', () {
      expect(appState.contains('m.pqEncrypted && !dup.pqEncrypted'), isTrue);
    });

    test('and coverage carries over when the row had none', () {
      expect(appState.contains('m.pqCoverage != null && dup.pqCoverage == null'),
          isTrue);
    });

    // Upgrade-only: the Bitchat copy of the same text arriving later says
    // nothing about how the Nymchat one was sealed.
    test('it never downgrades', () {
      expect(appState.contains('dup.pqEncrypted = false'), isFalse);
    });
  });

  // The wiring: both send paths must write the result back onto the echo, and
  // the group one must take the fan-out's own count rather than guessing.
  group('send paths write back', () {
    final controller =
        File('lib/state/nostr_controller.dart').readAsStringSync();

    test('the PM path marks its echo from the send plan', () {
      final send = controller.substring(
          controller.indexOf('Future<void> _publishDualPm('),
          controller.indexOf('void _trackPendingDm('));
      expect(send.contains('markOwnMessagePq'), isTrue);
      expect(send.contains('pqEncrypted: plan.pq'), isTrue);
    });

    test('the group path takes coverage from the fan-out', () {
      expect(controller.contains('onCoverage: (pq, total) => appState'), isTrue,
          reason: 'publishGroupMessage counts coverage as it builds the wraps; '
              'the controller has to pass onCoverage to receive it');
    });
  });
}

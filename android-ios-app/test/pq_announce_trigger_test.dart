// The announcement has to actually be published, or nothing downstream matters.
//
// Two defects shipped here, each of which alone made every message classical on
// both ends while everything else looked healthy: the crypto was right, the
// discovery was right, and the key was simply never anywhere to be found.
//
// Neither was reachable from a unit test of the controller (it needs a live
// service, storage sync and relay pool), so these assert the WIRING in the
// source. A structural test is the right shape for a structural bug: what broke
// was which code path the publish hangs off, not what the publish does.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final controller =
      File('lib/state/nostr_controller.dart').readAsStringSync();

  String bodyOf(String signature, String nextSignature) {
    final start = controller.indexOf(signature);
    expect(start, greaterThan(-1), reason: 'not found: $signature');
    final end = controller.indexOf(nextSignature, start);
    expect(end, greaterThan(start), reason: 'not found after: $nextSignature');
    return controller.substring(start, end);
  }

  group('capability announcement is actually published', () {
    // Defect 1: publishing was the LAST statement of _backfillFromD1OnReconnect,
    // so it inherited that function's failure modes wholesale — two early
    // returns (no storage sync; the 30s throttle) and three unguarded awaits
    // that can each throw. Any one of them silently cost us the announcement.
    test('publishing does not depend on the D1 backfill completing', () {
      final backfill = bodyOf('Future<void> _backfillFromD1OnReconnect() async {',
          'Rebuilds the web of trust from D1');
      expect(backfill.contains('unawaited(publishPqAnnouncement())'), isFalse,
          reason: 'publishing must not ride the tail of the D1 backfill: that '
              'function returns early twice and awaits three throwing calls '
              'before ever reaching the announcement');
    });

    // Defect 2: it must hang off the connection edge itself, which is the one
    // event that always happens — including on a FIRST connect, which is
    // exactly the case a brand new account hits.
    test('the connection edge schedules an announcement', () {
      final onChanged = bodyOf('void _onConnectionChanged(int count) {',
          'Timer? _pqAnnounceTimer;');
      expect(onChanged.contains('schedulePqAnnouncement()'), isTrue,
          reason: 'a first connect must announce, not only a reconnect');
    });

    test('scheduling is idempotent, so every connect path can call it', () {
      final sched = bodyOf('void schedulePqAnnouncement() {', '\n  /// ');
      expect(sched.contains('if (_pqAnnounceTimer != null) return;'), isTrue,
          reason: 'without the guard, repeated connect edges stack timers');
    });

    // A timer that outlives the controller republishes under a torn-down
    // identity, so it has to be cancelled with the rest.
    test('the pending timer is cancelled on teardown', () {
      expect(controller.contains('_pqAnnounceTimer?.cancel();'), isTrue);
    });
  });
}

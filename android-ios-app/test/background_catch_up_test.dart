// What an iOS BGAppRefresh window is allowed to notify about.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/notifications/background_catch_up.dart';

void main() {
  const hour = 3600 * 1000;
  final now = DateTime.now().millisecondsSinceEpoch;

  group('catchUpCutoffMs', () {
    test('the first ever run alerts for nothing', () {
      // The device cannot know what the user already read elsewhere, and a day
      // of backlog arriving at once is worse than missing one round.
      expect(catchUpCutoffMs(storedWatermarkMs: 0, nowMs: now), now);
      expect(
        catchUpShouldAlert(
          messageTsMs: now - hour,
          cutoffMs: catchUpCutoffMs(storedWatermarkMs: 0, nowMs: now),
        ),
        false,
      );
    });

    test('later runs cover everything since the previous one', () {
      final cutoff =
          catchUpCutoffMs(storedWatermarkMs: now - 2 * hour, nowMs: now);
      expect(cutoff, now - 2 * hour);
      // Arrived while suspended → alerts, even though it is hours old and would
      // fail the live 30-second rule.
      expect(catchUpShouldAlert(messageTsMs: now - hour, cutoffMs: cutoff),
          true);
      // Older than the last catch-up → already had its chance.
      expect(catchUpShouldAlert(messageTsMs: now - 3 * hour, cutoffMs: cutoff),
          false);
    });

    test('a device that was away for a week only announces the last day', () {
      final cutoff = catchUpCutoffMs(
        storedWatermarkMs: now - 7 * 24 * hour,
        nowMs: now,
      );
      expect(cutoff, now - kCatchUpWindow.inMilliseconds);
      expect(
        catchUpShouldAlert(messageTsMs: now - 48 * hour, cutoffMs: cutoff),
        false,
      );
      expect(
        catchUpShouldAlert(messageTsMs: now - 2 * hour, cutoffMs: cutoff),
        true,
      );
    });

    test('a message exactly on the watermark does not re-alert', () {
      final watermark = now - hour;
      final cutoff =
          catchUpCutoffMs(storedWatermarkMs: watermark, nowMs: now);
      expect(catchUpShouldAlert(messageTsMs: watermark, cutoffMs: cutoff),
          false);
      expect(catchUpShouldAlert(messageTsMs: watermark + 1, cutoffMs: cutoff),
          true);
    });
  });

  group('silentForAlert', () {
    test('outside a catch-up, only a live arrival alerts', () {
      // Channel/reaction/zap window (10s) and the message window (30s).
      expect(silentForAlert(tsMs: now - 5000, nowMs: now), false);
      expect(silentForAlert(tsMs: now - 20000, nowMs: now), true);
      expect(
        silentForAlert(tsMs: now - 20000, nowMs: now, liveWindowMs: 30000),
        false,
      );
      // Backlog provenance is silent whatever its clock says.
      expect(silentForAlert(tsMs: now, nowMs: now, historical: true), true);
    });

    // The regression: a catch-up pulls events that are minutes old BY
    // DEFINITION, so the live rule must not also apply. Keeping both silenced
    // every mention a background window recovered, while PMs — whose rule had
    // been replaced rather than added to — notified normally.
    test('during a catch-up the watermark alone decides', () {
      final cutoff = now - 2 * hour;
      // Five minutes old: far outside every live window, and still alerts.
      expect(
        silentForAlert(
          tsMs: now - 5 * 60 * 1000,
          nowMs: now,
          catchUpCutoffMs: cutoff,
        ),
        false,
      );
      // Older than the last catch-up: silent, as before.
      expect(
        silentForAlert(
          tsMs: now - 3 * hour,
          nowMs: now,
          catchUpCutoffMs: cutoff,
        ),
        true,
      );
      // Backlog provenance does not override the watermark either — an
      // archive replay is how a catch-up receives everything it receives.
      expect(
        silentForAlert(
          tsMs: now - 5 * 60 * 1000,
          nowMs: now,
          catchUpCutoffMs: cutoff,
          historical: true,
        ),
        false,
      );
    });
  });
}

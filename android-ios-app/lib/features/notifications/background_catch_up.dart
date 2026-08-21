/// How far back a background catch-up is allowed to raise notifications.
///
/// Matches the bell history's own window (`notifications.js:135`): nothing
/// older than a day ever alerts, however it reached us.
const Duration kCatchUpWindow = Duration(hours: 24);

/// The timestamp a catch-up must beat before it may alert.
///
/// A catch-up runs while the app is suspended, so by definition everything it
/// pulls is "old" — the live 30-second rule that governs foreground arrivals
/// would silence all of it. What replaces that rule is a watermark: alert for
/// what arrived since the last catch-up, and nothing else.
///
/// * [storedWatermarkMs] is when the previous catch-up ran (0 the first time).
///   The first run deliberately alerts for NOTHING: the device has no idea what
///   the user has already read elsewhere, and a day of backlog arriving as a
///   burst of notifications is worse than missing one round.
/// * Otherwise the watermark is clamped to [window], so a device that has been
///   off for a week does not wake up and announce the whole week.
///
/// Duplicates are not this function's job — a message that already reached the
/// bell history or the persisted seen-map is rejected downstream by
/// `NotificationsService`'s replay guards, which is what makes it safe for a
/// catch-up to re-walk a window it has partly seen.
int catchUpCutoffMs({
  required int storedWatermarkMs,
  required int nowMs,
  Duration window = kCatchUpWindow,
}) {
  if (storedWatermarkMs <= 0) return nowMs;
  final floor = nowMs - window.inMilliseconds;
  return storedWatermarkMs > floor ? storedWatermarkMs : floor;
}

/// Whether a message pulled by a catch-up is new enough to alert, given the
/// [cutoffMs] from [catchUpCutoffMs].
bool catchUpShouldAlert({required int messageTsMs, required int cutoffMs}) =>
    messageTsMs > cutoffMs;

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

/// Whether an event must be recorded SILENTLY — bell history only, no sound or
/// popup. The single rule behind every notification kind.
///
/// Outside a catch-up: silent unless the event is a live arrival — [historical]
/// provenance, or older than [liveWindowMs] (10s for channel/reaction/zap
/// events, 30s for messages, matching each PWA path).
///
/// During a catch-up ([catchUpCutoffMs] non-null): the watermark decides
/// instead, because everything a catch-up pulls is older than any live window —
/// that is what "the app was suspended" means. Applying the live rule ON TOP of
/// the watermark silences the entire catch-up, which is exactly the bug that
/// made background channel mentions never notify while PMs did.
bool silentForAlert({
  required int tsMs,
  required int nowMs,
  int? catchUpCutoffMs,
  bool historical = false,
  int liveWindowMs = 10000,
}) {
  if (catchUpCutoffMs != null) {
    return !catchUpShouldAlert(messageTsMs: tsMs, cutoffMs: catchUpCutoffMs);
  }
  if (historical) return true;
  return nowMs - tsMs > liveWindowMs;
}

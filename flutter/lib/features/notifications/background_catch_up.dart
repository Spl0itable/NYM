import '../../core/constants/storage_keys.dart';
import '../../services/storage/key_value_store.dart';

/// How far back a background catch-up may raise notifications.
const Duration kCatchUpWindow = Duration(hours: 24);

/// Alert only for what arrived since the last catch-up (clamped to [window]); the first run alerts for nothing.
int catchUpCutoffMs({
  required int storedWatermarkMs,
  required int nowMs,
  Duration window = kCatchUpWindow,
}) {
  if (storedWatermarkMs <= 0) return nowMs;
  final floor = nowMs - window.inMilliseconds;
  return storedWatermarkMs > floor ? storedWatermarkMs : floor;
}

/// Whether a catch-up message is new enough to alert.
bool catchUpShouldAlert({required int messageTsMs, required int cutoffMs}) =>
    messageTsMs > cutoffMs;

/// Whether an event is recorded silently; during a catch-up the watermark replaces the live-window rule.
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

bool hasChosenIdentity(KeyValueStore kv) {
  final hasLogin = kv.getString(StorageKeys.nostrLoginMethod) != null;
  final autoEphemeral = kv.getString(StorageKeys.autoEphemeral) == 'true' ||
      kv.getBool(StorageKeys.autoEphemeral, defaultValue: false);
  return hasLogin || autoEphemeral;
}

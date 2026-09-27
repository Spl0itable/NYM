import '../../core/constants/history_window.dart';

/// Remembers, per event id, the instant this device FIRST had to clamp a
/// future-dated event back to "now".
///
/// A sender whose clock runs fast publishes an event whose `created_at` is
/// ahead of ours. Clamping it to the current time is right once, but the clamp
/// was recomputed on every ingest and the replay after each launch re-ingests
/// the same event — so it was re-stamped to each new "now" and the message read
/// `now` forever. Pinning the first clamp makes the correction settle.
///
/// Entries outside [kChannelHistoryMaxAge] are dropped.
class EventTimeCeilings {
  final Map<String, int> _byId = <String, int>{};

  /// Invoked when a new ceiling is recorded, so the owner can schedule a write.
  void Function()? onChanged;

  /// The stable ceiling for [id]. Returns [candidateMs] untouched when it is
  /// not in the future; otherwise the first "now" this event was clamped to.
  int stableCeiling(String id, int candidateMs, int nowMs) {
    if (candidateMs <= nowMs) return candidateMs;
    if (id.isEmpty) return nowMs;
    final prev = _byId[id];
    if (prev != null && prev > 0) return prev;
    _byId[id] = nowMs;
    onChanged?.call();
    return nowMs;
  }

  /// Drops entries older than the channel history window and returns what is
  /// left, in the `{id: ms}` shape the meta store persists.
  Map<String, dynamic> toJson({int? nowMs}) {
    final cutoff = (nowMs ?? DateTime.now().millisecondsSinceEpoch) -
        kChannelHistoryMaxAge.inMilliseconds;
    _byId.removeWhere((_, ms) => ms <= cutoff);
    return Map<String, dynamic>.from(_byId);
  }

  /// Restores ceilings written by a previous session, skipping aged-out ones.
  void hydrate(Map<String, dynamic> map, {int? nowMs}) {
    final cutoff = (nowMs ?? DateTime.now().millisecondsSinceEpoch) -
        kChannelHistoryMaxAge.inMilliseconds;
    map.forEach((id, value) {
      final ms = value is int ? value : int.tryParse('$value') ?? 0;
      if (id.isEmpty || ms <= cutoff) return;
      _byId[id] = ms;
    });
  }

  bool get isEmpty => _byId.isEmpty;

  int get length => _byId.length;
}

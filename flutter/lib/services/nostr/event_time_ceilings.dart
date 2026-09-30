import '../../core/constants/history_window.dart';

/// Pins the first clamp of a future-dated event to now, so replays do not re-stamp it to each new now.
class EventTimeCeilings {
  final Map<String, int> _byId = <String, int>{};

  void Function()? onChanged;

  /// Returns [candidateMs] when not in the future, else the first now this event was clamped to.
  int stableCeiling(String id, int candidateMs, int nowMs) {
    if (candidateMs <= nowMs) return candidateMs;
    if (id.isEmpty) return nowMs;
    final prev = _byId[id];
    if (prev != null && prev > 0) return prev;
    _byId[id] = nowMs;
    onChanged?.call();
    return nowMs;
  }

  /// Drops entries outside the channel history window and returns `{id: ms}`.
  Map<String, dynamic> toJson({int? nowMs}) {
    final cutoff = (nowMs ?? DateTime.now().millisecondsSinceEpoch) -
        kChannelHistoryMaxAge.inMilliseconds;
    _byId.removeWhere((_, ms) => ms <= cutoff);
    return Map<String, dynamic>.from(_byId);
  }

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

import '../../models/channel.dart';

/// User location for proximity sorting.
class UserLocation {
  const UserLocation({required this.lat, required this.lng});
  final double lat;
  final double lng;
}

/// Channel sort inputs; keys are lowercase channel keys (geohash or name).
class ChannelSortContext {
  const ChannelSortContext({
    required this.activeKey,
    required this.pinned,
    required this.lastActivity,
    required this.unreadCounts,
    this.sortByProximity = false,
    this.userLocation,
  });

  /// Currently active channel key; sorts right after #nymchat.
  final String activeKey;

  final Set<String> pinned;

  /// Channel key to last-activity ms.
  final Map<String, int> lastActivity;

  final Map<String, int> unreadCounts;

  /// Proximity ordering applies only when set.
  final bool sortByProximity;

  /// Null when unavailable or permission denied.
  final UserLocation? userLocation;
}

/// Pure channel list logic: sort priority plus add/remove/pin/hide/block over the persisted sets.
class ChannelManager {
  ChannelManager._();

  /// Activity/unread map key: always the `#`-prefixed storage key.
  static String activityKey(ChannelEntry c) => c.storageKey;

  /// Sort: #nymchat, active, pinned band, proximity (if enabled), then activity and unread desc; returns a new list.
  static List<ChannelEntry> sortChannels(
    List<ChannelEntry> channels,
    ChannelSortContext ctx,
  ) {
    final pins = <String, int>{};
    for (final k in ctx.pinned) {
      pins.putIfAbsent(k, () => pins.length);
    }
    final loc = ctx.sortByProximity ? ctx.userLocation : null;
    final keyed = [
      for (final c in channels) _SortKey.of(c, ctx, pins, loc),
    ]..sort(_compare);
    return [for (final k in keyed) k.entry];
  }

  static int _compare(_SortKey a, _SortKey b) {
    if (a.isDefault && !b.isDefault) return -1;
    if (!a.isDefault && b.isDefault) return 1;

    final aPin = a.pin;
    final bPin = b.pin;
    if (aPin >= 0 && bPin >= 0 && aPin != bPin) return aPin - bPin;
    if (aPin >= 0 && bPin < 0) return -1;
    if (aPin < 0 && bPin >= 0) return 1;

    if (a.active && !b.active) return -1;
    if (!a.active && b.active) return 1;

    final da = a.distance;
    final db = b.distance;
    if (da != null && db != null) {
      final cmp = da.compareTo(db);
      if (cmp != 0) return cmp;
    }

    if (a.activity != b.activity) return b.activity - a.activity;
    return b.unread - a.unread;
  }
}

class _SortKey {
  _SortKey(this.entry, this.isDefault, this.pin, this.active, this.distance,
      this.activity, this.unread);

  factory _SortKey.of(
    ChannelEntry entry,
    ChannelSortContext ctx,
    Map<String, int> pins,
    UserLocation? loc,
  ) {
    final key = entry.key;
    final storageKey = ChannelManager.activityKey(entry);
    return _SortKey(
      entry,
      key == kDefaultChannel,
      pins[key] ?? -1,
      key == ctx.activeKey,
      _distance(entry, loc),
      ctx.lastActivity[storageKey] ?? 0,
      ctx.unreadCounts[storageKey] ?? 0,
    );
  }

  final ChannelEntry entry;
  final bool isDefault;
  final int pin;
  final bool active;
  final double? distance;
  final int activity;
  final int unread;

  static double? _distance(ChannelEntry c, UserLocation? loc) {
    if (loc == null || c.geohash.isEmpty || !isValidGeohash(c.geohash)) {
      return null;
    }
    final at = decodeGeohash(c.geohash);
    return calculateDistance(loc.lat, loc.lng, at.lat, at.lng);
  }
}

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
    final out = [...channels];
    out.sort((a, b) => _compare(a, b, ctx));
    return out;
  }

  static int _compare(ChannelEntry a, ChannelEntry b, ChannelSortContext ctx) {
    final aDefault = a.key == kDefaultChannel;
    final bDefault = b.key == kDefaultChannel;
    if (aDefault && !bDefault) return -1;
    if (!aDefault && bDefault) return 1;

    final pins = ctx.pinned.toList();
    final aPin = pins.indexOf(a.key);
    final bPin = pins.indexOf(b.key);
    if (aPin >= 0 && bPin >= 0 && aPin != bPin) return aPin - bPin;
    if (aPin >= 0 && bPin < 0) return -1;
    if (aPin < 0 && bPin >= 0) return 1;

    final aActive = a.key == ctx.activeKey;
    final bActive = b.key == ctx.activeKey;
    if (aActive && !bActive) return -1;
    if (!aActive && bActive) return 1;

    // Proximity: only valid-geohash pairs, only when enabled and located.
    final aGeo = a.geohash.isNotEmpty && isValidGeohash(a.geohash);
    final bGeo = b.geohash.isNotEmpty && isValidGeohash(b.geohash);
    if (ctx.sortByProximity && ctx.userLocation != null && aGeo && bGeo) {
      final ca = decodeGeohash(a.geohash);
      final cb = decodeGeohash(b.geohash);
      final da = calculateDistance(
          ctx.userLocation!.lat, ctx.userLocation!.lng, ca.lat, ca.lng);
      final db = calculateDistance(
          ctx.userLocation!.lat, ctx.userLocation!.lng, cb.lat, cb.lng);
      final cmp = da.compareTo(db);
      if (cmp != 0) return cmp;
    }

    // Fallback: activity desc, then unread desc.
    final aAct = ctx.lastActivity[activityKey(a)] ?? 0;
    final bAct = ctx.lastActivity[activityKey(b)] ?? 0;
    if (aAct != bAct) return bAct - aAct;
    final aUnread = ctx.unreadCounts[activityKey(a)] ?? 0;
    final bUnread = ctx.unreadCounts[activityKey(b)] ?? 0;
    return bUnread - aUnread;
  }
}
